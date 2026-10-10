"""
HydroSentry — Phase 1: Hazard Compute Engine
=============================================
Single-file hydrology computation and Cedar authorization mock.
Python 3.12, standard library only.

All arithmetic uses decimal.Decimal (ROUND_HALF_UP, 2 dp).
Cedar context integers are derived via floor of unrounded Decimals.

Phase 0 references:
  - Cedar policy:  policies/hydrosentry.cedar
  - Thresholds:    water_depth_mm >= 350, time_to_submersion_mins <= 30
  - Seed data:     data/delhi_sinks.yaml (3 Delhi sinks)
"""
from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal, ROUND_HALF_UP
from typing import Optional


# ── Quantisation ──────────────────────────────────────────────────────────

_TWO_DP = Decimal("0.01")


def _q(value: Decimal) -> Decimal:
    """Quantize a Decimal to 2 decimal places with ROUND_HALF_UP."""
    return value.quantize(_TWO_DP, rounding=ROUND_HALF_UP)


# ── Data Model ────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class SinkProfile:
    """Immutable hydrological profile of a monitored urban depression sink."""

    catchment_area_m2: Decimal
    runoff_coeff: Decimal             # [0, 1]
    baseline_drainage_m3hr: Decimal
    critical_volume_m3: Decimal       # > 0
    critical_depth_cm: Decimal = Decimal("35.0")


@dataclass(frozen=True)
class HazardResult:
    """Immutable output of a single hazard computation."""

    active: bool
    tts_min: Optional[Decimal]        # None when inactive; quantized 2 dp
    volume_m3: Decimal                # quantized 2 dp
    depth_cm: Decimal                 # quantized 2 dp
    horsepower: Decimal               # quantized 2 dp
    # Cedar context integers (floor of unrounded Decimal)
    cedar_depth_mm: int               # floor(raw_depth_cm × 10)
    cedar_tts_min: int                # floor(raw_tts); −1 when inactive


# ── Constants ─────────────────────────────────────────────────────────────

_ZERO = Decimal("0")
_ONE = Decimal("1")
_TEN = Decimal("10")
_SIXTY = Decimal("60")
_THOUSAND = Decimal("1000")
_HP_DENOM = Decimal("270")


# ── Compute Engine ────────────────────────────────────────────────────────

def compute_hazard(
    profile: SinkProfile,
    rainfall_mm_hr: Decimal,
    storm_duration_min: int = 15,
    head_m: Decimal = Decimal("5.0"),
    pump_efficiency: Decimal = Decimal("1.0"),
) -> HazardResult:
    """
    Compute flood-hazard metrics for a single sink under a rainfall event.

    Parameters
    ----------
    profile          : Sink hydrological profile.
    rainfall_mm_hr   : Rainfall intensity in mm/hr.
    storm_duration_min : Storm duration in minutes (default 15).
    head_m           : Pump discharge head in metres (default 5.0).
    pump_efficiency  : Pump efficiency factor, dimensionless (default 1.0).

    Returns
    -------
    HazardResult with quantized (2 dp) display values and integer Cedar
    context values derived from unrounded Decimals.

    Raises
    ------
    ValueError on invalid inputs: negative rainfall, non-positive duration,
    non-positive critical volume, or runoff coefficient outside [0, 1].
    """
    # ── Validate ──
    if rainfall_mm_hr < _ZERO:
        raise ValueError(f"rainfall_mm_hr must be >= 0, got {rainfall_mm_hr}")
    duration = Decimal(storm_duration_min)
    if duration <= _ZERO:
        raise ValueError(f"storm_duration_min must be > 0, got {storm_duration_min}")
    if profile.critical_volume_m3 <= _ZERO:
        raise ValueError(
            f"critical_volume_m3 must be > 0, got {profile.critical_volume_m3}"
        )
    if not (_ZERO <= profile.runoff_coeff <= _ONE):
        raise ValueError(
            f"runoff_coeff must be in [0, 1], got {profile.runoff_coeff}"
        )

    # ── Hydrology (Rational Method: Q = C × I × A) ──
    inflow = (
        rainfall_mm_hr / _THOUSAND
        * profile.catchment_area_m2
        * profile.runoff_coeff
    )
    net = inflow - profile.baseline_drainage_m3hr

    if net <= _ZERO:
        return HazardResult(
            active=False,
            tts_min=None,
            volume_m3=_q(_ZERO),
            depth_cm=_q(_ZERO),
            horsepower=_q(_ZERO),
            cedar_depth_mm=0,
            cedar_tts_min=-1,
        )

    # ── Raw (full-precision) computations ──
    raw_tts = profile.critical_volume_m3 / net * _SIXTY
    raw_volume = min(profile.critical_volume_m3, net * duration / _SIXTY)
    raw_depth_cm = (
        raw_volume / profile.critical_volume_m3 * profile.critical_depth_cm
    )
    raw_hp = net * head_m / _HP_DENOM / pump_efficiency

    # ── Cedar context: floor of unrounded Decimal ──
    #    int() on a positive Decimal truncates toward zero == floor.
    cedar_depth_mm = int(raw_depth_cm * _TEN)
    cedar_tts_min = int(raw_tts)

    return HazardResult(
        active=True,
        tts_min=_q(raw_tts),
        volume_m3=_q(raw_volume),
        depth_cm=_q(raw_depth_cm),
        horsepower=_q(raw_hp),
        cedar_depth_mm=cedar_depth_mm,
        cedar_tts_min=cedar_tts_min,
    )


# ── Cedar Mock Authorizer ────────────────────────────────────────────────
#
# Mirrors the Phase 0 Cedar policy (policies/hydrosentry.cedar):
#
#   permit (
#       principal == HydroSentry::Role::"AutomatedSentinel",
#       action    == HydroSentry::Action::"DispatchEmergencyPump",
#       resource is HydroSentry::UrbanSink
#   ) when {
#       context.water_depth_mm          >= 350 &&
#       context.time_to_submersion_mins <= 30
#   };
#
# The mock adds hazard_active as a Bool guard.  Context fields are
# Cedar-compatible Long/Bool only.  Default deny; any exception -> DENIED.
# ──────────────────────────────────────────────────────────────────────────

_DEPTH_THRESHOLD_MM: int = 350   # Phase 0 axle-drowning threshold
_TTS_THRESHOLD_MIN: int = 30     # Phase 0 submersion urgency window


def _build_cedar_context(result: HazardResult) -> dict[str, int | bool]:
    """Construct Cedar-compatible context record (Long/Bool only)."""
    return {
        "hazard_active": result.active,
        "depth_mm": result.cedar_depth_mm,
        "tts_min": result.cedar_tts_min,
    }


def _evaluate_cedar_policy(ctx: dict[str, int | bool]) -> bool:
    """
    Evaluate the Cedar permit rule against a context record.

    permit when
        hazard_active == true
        && depth_mm   >= 350
        && tts_min    <= 30
    """
    return (
        ctx["hazard_active"] is True
        and isinstance(ctx["depth_mm"], int)
        and isinstance(ctx["tts_min"], int)
        and ctx["depth_mm"] >= _DEPTH_THRESHOLD_MM
        and ctx["tts_min"] <= _TTS_THRESHOLD_MIN
    )


def authorize(result: HazardResult) -> str:
    """
    Authorize emergency pump dispatch via Cedar mock.

    Returns ``"DISPATCH_AUTHORIZED"`` or ``"DISPATCH_DENIED"``.
    Default deny; any exception -> DENIED.
    """
    try:
        ctx = _build_cedar_context(result)
        if _evaluate_cedar_policy(ctx):
            return "DISPATCH_AUTHORIZED"
        return "DISPATCH_DENIED"
    except Exception:
        return "DISPATCH_DENIED"


# ── Tests ─────────────────────────────────────────────────────────────────
#
# Test profile uses the illustrative fixture values from the Phase 1 spec.
# Cedar policy thresholds replaced with Phase 0 values:
#   depth_mm >= 350  (from policies/hydrosentry.cedar)
#   tts_min  <= 30   (from policies/hydrosentry.cedar)
#
# Scenario A:  15 mm/hr -> drainage exceeds inflow   -> INACTIVE  -> DENIED
# Scenario B:  80 mm/hr -> sink fills to capacity     -> ACTIVE    -> AUTHORIZED
# Scenario C:  Negative rainfall                      -> ValueError-> DENIED
# ──────────────────────────────────────────────────────────────────────────

def _run_tests() -> None:
    """Validation test suite with Phase 0-compatible Cedar thresholds."""

    D = Decimal
    sep = "-" * 62

    # -- Test Profile --
    profile = SinkProfile(
        catchment_area_m2=D("2400"),
        runoff_coeff=D("0.9"),
        baseline_drainage_m3hr=D("40"),
        critical_volume_m3=D("30"),
        # critical_depth_cm defaults to Decimal("35.0")
    )

    # ==================================================================
    # SCENARIO A -- Low rainfall: inflow < drainage -> INACTIVE -> DENIED
    # ==================================================================
    #   inflow = 15/1000 * 2400 * 0.9 = 32.40 m3/hr
    #   net    = 32.40 - 40 = -7.60 m3/hr  (<= 0 -> inactive)
    # ------------------------------------------------------------------
    print(sep)
    print("SCENARIO A | 15 mm/hr rainfall | Expect: INACTIVE, DENIED")
    print(sep)

    r_a1 = compute_hazard(profile, D("15"))
    r_a2 = compute_hazard(profile, D("15"))
    assert r_a1 == r_a2, "Determinism check failed for Scenario A"

    assert r_a1.active is False
    assert r_a1.tts_min is None
    assert r_a1.volume_m3 == D("0.00")
    assert r_a1.depth_cm == D("0.00")
    assert r_a1.horsepower == D("0.00")
    assert r_a1.cedar_depth_mm == 0
    assert r_a1.cedar_tts_min == -1

    auth_a = authorize(r_a1)
    assert auth_a == "DISPATCH_DENIED"

    # Print informational hydrology values
    inflow_a = D("15") / D("1000") * D("2400") * D("0.9")
    net_a = inflow_a - D("40")
    print(f"  inflow     = {_q(inflow_a)} m3/hr")
    print(f"  net        = {_q(net_a)} m3/hr")
    print(f"  active     = {r_a1.active}")
    print(f"  tts_min    = {r_a1.tts_min}")
    print(f"  volume_m3  = {r_a1.volume_m3}")
    print(f"  depth_cm   = {r_a1.depth_cm} ({r_a1.cedar_depth_mm} mm)")
    print(f"  horsepower = {r_a1.horsepower}")
    print(f"  Cedar ctx  = {_build_cedar_context(r_a1)}")
    print(f"  authorize  = {auth_a}")
    print("  [PASS] deterministic, inactive, DENIED")
    print()

    # ==================================================================
    # SCENARIO B -- High rainfall: sink fills to capacity -> AUTHORIZED
    # ==================================================================
    #   inflow = 80/1000 * 2400 * 0.9 = 172.80 m3/hr
    #   net    = 172.80 - 40 = 132.80 m3/hr
    #   tts    = 30 / 132.80 * 60 = 13.55 min  (floor -> 13 <= 30)
    #   volume = min(30, 132.80*15/60) = min(30, 33.20) = 30.00 m3
    #   depth  = 30/30 * 35 = 35.00 cm  (floor -> 350 mm >= 350)
    #   hp     = 132.80 * 5 / 270 / 1 = 2.46 HP
    # ------------------------------------------------------------------
    print(sep)
    print("SCENARIO B | 80 mm/hr rainfall | Expect: ACTIVE, AUTHORIZED")
    print(sep)

    r_b1 = compute_hazard(profile, D("80"))
    r_b2 = compute_hazard(profile, D("80"))
    assert r_b1 == r_b2, "Determinism check failed for Scenario B"

    assert r_b1.active is True
    assert r_b1.tts_min == D("13.55")
    assert r_b1.volume_m3 == D("30.00")
    assert r_b1.depth_cm == D("35.00")
    assert r_b1.horsepower == D("2.46")
    assert r_b1.cedar_depth_mm == 350
    assert r_b1.cedar_tts_min == 13

    auth_b = authorize(r_b1)
    assert auth_b == "DISPATCH_AUTHORIZED"

    inflow_b = D("80") / D("1000") * D("2400") * D("0.9")
    net_b = inflow_b - D("40")
    print(f"  inflow     = {_q(inflow_b)} m3/hr")
    print(f"  net        = {_q(net_b)} m3/hr")
    print(f"  active     = {r_b1.active}")
    print(f"  tts_min    = {r_b1.tts_min} min")
    print(f"  volume_m3  = {r_b1.volume_m3} m3")
    print(f"  depth_cm   = {r_b1.depth_cm} cm ({r_b1.cedar_depth_mm} mm)")
    print(f"  horsepower = {r_b1.horsepower} HP")
    print(f"  Cedar ctx  = {_build_cedar_context(r_b1)}")
    print(f"  authorize  = {auth_b}")
    print("  [PASS] deterministic, active, AUTHORIZED")
    print()

    # ==================================================================
    # SCENARIO C -- Invalid input: negative rainfall -> ValueError -> DENIED
    # ==================================================================
    print(sep)
    print("SCENARIO C | Invalid input     | Expect: ValueError, DENIED")
    print(sep)

    auth_c = "DISPATCH_DENIED"
    try:
        bad_result = compute_hazard(profile, D("-5"))
        auth_c = authorize(bad_result)
        assert False, "Should have raised ValueError"
    except ValueError as exc:
        print(f"  ValueError raised: {exc}")

    assert auth_c == "DISPATCH_DENIED"
    print(f"  authorize  = {auth_c}")
    print("  [PASS] invalid input correctly rejected")
    print()

    # ==================================================================
    print("=" * 62)
    print("ALL TESTS PASSED")
    print("=" * 62)


if __name__ == "__main__":
    _run_tests()

