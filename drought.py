"""
HydroSentry — Phase 6: Dry-Season Water Supply Engine
=====================================================
The drought half of the "Heat and Water" track: too little water, where
compute.py handles too much.  Single file, Python 3.12+, standard library only.

All arithmetic uses decimal.Decimal (ROUND_HALF_UP, 2 dp for display).
Deterministic: the same inputs always give the same day-by-day results.

!! SEED DATA NOTICE !!
The zone numbers and the 90-day rainfall series below are PREPARED OFFLINE
ILLUSTRATIVE ESTIMATES for a Delhi pre-monsoon dry season (1 Mar - 29 May).
They are NOT live data and NOT official measurements.  The same numbers are
kept in data/delhi_dry_season.json; the tests check that both agree.

Daily model (one row per zone per day)
--------------------------------------
  need_m3          = population x demand_lpcd / 1000
                     (135 L/person/day: CPHEEO planning norm for Indian cities
                     with piped sewerage)
  borewell_frac    = clamp((pump_limit - depth) / (pump_limit - full_yield_depth), 0, 1)
                     full yield while the water table is shallow, falling in a
                     straight line to zero when it reaches the pump limit
  supply_m3        = piped_supply + borewell_capacity x borewell_frac
  supply_ratio     = supply_m3 / need_m3
  status           = SAFE                 if ratio >= 0.90
                     WATCH                if ratio >= 0.80
                     WATER_TANKER_NEEDED  if ratio <  0.80   (the safe line)
  tankers_per_day  = ceil((0.80 x need - supply) / 10 m3)   when below the line
                     i.e. the minimum 10,000-litre tankers to get back to the line

Groundwater (depth to water table, metres below ground, bigger = worse)
  depth(day 1)     = start depth
  depth(day d+1)   = max(0, depth(d) + daily_decline - rain_rise(d))
  rain_rise(d)     = rain_mm(d) / 1000 x (1 - runoff_coeff) / specific_yield
                     Only the part of the rain that does NOT run off soaks in.
                     runoff_coeff is the same value used by the flood engine
                     (data/delhi_sinks.yaml), so concrete catchments recharge little.

Dry-day streak: a "rainy day" is >= 2.5 mm (India Meteorological Department
definition); any day below that extends the streak.

The tanker alert is a plain advisory.  It does not use, change, or depend on
the Cedar pump-dispatch policy (policies/hydrosentry.cedar).
"""
from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal, ROUND_CEILING, ROUND_HALF_UP
from typing import Sequence


# ── Quantisation ──────────────────────────────────────────────────────────

_TWO_DP = Decimal("0.01")


def _q(value: Decimal) -> Decimal:
    """Quantize a Decimal to 2 decimal places with ROUND_HALF_UP."""
    return value.quantize(_TWO_DP, rounding=ROUND_HALF_UP)


# ── Constants ─────────────────────────────────────────────────────────────

_ZERO = Decimal("0")
_ONE = Decimal("1")
_HUNDRED = Decimal("100")
_THOUSAND = Decimal("1000")

DEMAND_LPCD = Decimal("135")           # litres per person per day (CPHEEO norm)
SAFE_LINE = Decimal("0.80")            # below this: WATER TANKER NEEDED
WATCH_LINE = Decimal("0.90")           # below this: WATCH
TANKER_CAPACITY_M3 = Decimal("10")     # one 10,000-litre tanker
RAINY_DAY_MM = Decimal("2.5")          # IMD rainy-day threshold
SEASON_DAYS = 90                       # 1 Mar - 29 May

STATUS_SAFE = "SAFE"
STATUS_WATCH = "WATCH"
STATUS_TANKER = "WATER_TANKER_NEEDED"


# ── Data Model ────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class ZoneProfile:
    """Immutable dry-season water profile of the area around a monitored sink."""

    zone_id: str
    name: str
    linked_sink_id: str               # the flood sink in data/delhi_sinks.yaml
    population: int                   # people served
    piped_supply_m3_day: Decimal      # municipal piped supply
    borewell_capacity_m3_day: Decimal # local borewells at full yield
    gw_start_depth_m: Decimal         # depth to water table on day 1
    gw_full_yield_depth_m: Decimal    # borewells give full yield above this depth
    gw_pump_limit_m: Decimal          # borewells run dry at this depth
    gw_decline_m_day: Decimal         # dry-season fall of the water table per day
    runoff_coeff: Decimal             # [0, 1], shared with the flood engine
    specific_yield: Decimal           # (0, 1], drainable water per unit aquifer volume


@dataclass(frozen=True)
class DayResult:
    """Immutable water situation of one zone on one day."""

    day: int                          # 1-based
    rain_mm: Decimal
    dry_streak_days: int              # consecutive days below 2.5 mm, incl. today
    gw_depth_m: Decimal               # quantized 2 dp
    need_m3: Decimal                  # quantized 2 dp
    supply_m3: Decimal                # quantized 2 dp
    supply_pct: Decimal               # quantized 2 dp
    status: str                       # SAFE | WATCH | WATER_TANKER_NEEDED
    tankers_per_day: int              # 0 unless WATER_TANKER_NEEDED


# ── Seed data (PREPARED OFFLINE — ILLUSTRATIVE — NOT LIVE) ────────────────
# Mirrors data/delhi_dry_season.json exactly (checked by the tests).

D = Decimal

ZONES: tuple[ZoneProfile, ...] = (
    ZoneProfile(
        zone_id="DELZON001", name="Minto Bridge zone", linked_sink_id="DELSNK001",
        population=38000,
        piped_supply_m3_day=D("4450"), borewell_capacity_m3_day=D("600"),
        gw_start_depth_m=D("16.0"), gw_full_yield_depth_m=D("12.0"),
        gw_pump_limit_m=D("35.0"), gw_decline_m_day=D("0.012"),
        runoff_coeff=D("0.92"), specific_yield=D("0.12"),
    ),
    ZoneProfile(
        zone_id="DELZON002", name="Pul Prahladpur zone", linked_sink_id="DELSNK002",
        population=52000,
        piped_supply_m3_day=D("4000"), borewell_capacity_m3_day=D("3600"),
        gw_start_depth_m=D("30.0"), gw_full_yield_depth_m=D("25.0"),
        gw_pump_limit_m=D("45.0"), gw_decline_m_day=D("0.08"),
        runoff_coeff=D("0.90"), specific_yield=D("0.12"),
    ),
    ZoneProfile(
        zone_id="DELZON003", name="Zakhira zone", linked_sink_id="DELSNK003",
        population=45000,
        piped_supply_m3_day=D("4700"), borewell_capacity_m3_day=D("1200"),
        gw_start_depth_m=D("14.0"), gw_full_yield_depth_m=D("10.0"),
        gw_pump_limit_m=D("30.0"), gw_decline_m_day=D("0.05"),
        runoff_coeff=D("0.88"), specific_yield=D("0.12"),
    ),
)

# Daily rainfall (mm), day 1 = 1 Mar.  Mostly dry, with a few western-
# disturbance / pre-monsoon showers.  Totals: Mar 11.6, Apr 5.8, May 18.2 mm.
_RAIN_DAYS: dict[int, str] = {
    9: "3.2", 10: "6.4", 27: "2.0",      # March
    45: "2.2", 52: "3.6",                # April
    70: "9.4", 71: "3.0", 83: "5.8",     # May
}
RAINFALL_MM: tuple[Decimal, ...] = tuple(
    D(_RAIN_DAYS.get(day, "0")) for day in range(1, SEASON_DAYS + 1)
)

del D


# ── Compute Engine ────────────────────────────────────────────────────────

def _validate(zone: ZoneProfile, rainfall_mm: Sequence[Decimal]) -> None:
    if len(rainfall_mm) < 1:
        raise ValueError("rainfall_mm must contain at least one day")
    if any(r < _ZERO for r in rainfall_mm):
        raise ValueError("rainfall_mm values must be >= 0")
    if zone.population <= 0:
        raise ValueError(f"population must be > 0, got {zone.population}")
    if zone.piped_supply_m3_day < _ZERO or zone.borewell_capacity_m3_day < _ZERO:
        raise ValueError("supply capacities must be >= 0")
    if zone.gw_start_depth_m < _ZERO or zone.gw_decline_m_day < _ZERO:
        raise ValueError("groundwater depth and decline must be >= 0")
    if zone.gw_pump_limit_m <= zone.gw_full_yield_depth_m:
        raise ValueError("gw_pump_limit_m must be deeper than gw_full_yield_depth_m")
    if not (_ZERO <= zone.runoff_coeff <= _ONE):
        raise ValueError(f"runoff_coeff must be in [0, 1], got {zone.runoff_coeff}")
    if not (_ZERO < zone.specific_yield <= _ONE):
        raise ValueError(f"specific_yield must be in (0, 1], got {zone.specific_yield}")


def rain_rise_m(zone: ZoneProfile, rain_mm: Decimal) -> Decimal:
    """Water-table rise (m) from one day's rain: only the infiltrated part recharges."""
    return rain_mm / _THOUSAND * (_ONE - zone.runoff_coeff) / zone.specific_yield


def borewell_fraction(zone: ZoneProfile, depth_m: Decimal) -> Decimal:
    """Borewell yield as a fraction of capacity, linear between full yield and pump limit."""
    span = zone.gw_pump_limit_m - zone.gw_full_yield_depth_m
    frac = (zone.gw_pump_limit_m - depth_m) / span
    return max(_ZERO, min(_ONE, frac))


def classify(supply_ratio: Decimal) -> str:
    """SAFE >= 0.90 > WATCH >= 0.80 > WATER_TANKER_NEEDED."""
    if supply_ratio >= WATCH_LINE:
        return STATUS_SAFE
    if supply_ratio >= SAFE_LINE:
        return STATUS_WATCH
    return STATUS_TANKER


def tankers_needed(need_m3: Decimal, supply_m3: Decimal) -> int:
    """Minimum 10 m3 tankers per day to lift supply back to the safe line."""
    gap = SAFE_LINE * need_m3 - supply_m3
    if gap <= _ZERO:
        return 0
    return int((gap / TANKER_CAPACITY_M3).to_integral_value(rounding=ROUND_CEILING))


def simulate_season(
    zone: ZoneProfile,
    rainfall_mm: Sequence[Decimal] = RAINFALL_MM,
) -> tuple[DayResult, ...]:
    """
    Run the dry-season model day by day for one zone.

    Returns one DayResult per rainfall entry.  Raises ValueError on invalid
    inputs (negative rain, impossible aquifer settings, etc.).
    """
    _validate(zone, rainfall_mm)

    need = zone.population * DEMAND_LPCD / _THOUSAND
    depth = zone.gw_start_depth_m
    streak = 0
    out: list[DayResult] = []

    for i, rain in enumerate(rainfall_mm):
        streak = 0 if rain >= RAINY_DAY_MM else streak + 1
        supply = (
            zone.piped_supply_m3_day
            + zone.borewell_capacity_m3_day * borewell_fraction(zone, depth)
        )
        ratio = supply / need
        status = classify(ratio)
        out.append(DayResult(
            day=i + 1,
            rain_mm=rain,
            dry_streak_days=streak,
            gw_depth_m=_q(depth),
            need_m3=_q(need),
            supply_m3=_q(supply),
            supply_pct=_q(ratio * _HUNDRED),
            status=status,
            tankers_per_day=tankers_needed(need, supply) if status == STATUS_TANKER else 0,
        ))
        # Today's rain soaks in overnight; tomorrow starts from the new depth.
        depth = max(_ZERO, depth + zone.gw_decline_m_day - rain_rise_m(zone, rain))

    return tuple(out)


def tanker_alert(result: DayResult) -> str:
    """Advisory alert text for the console / operators."""
    return "WATER TANKER NEEDED" if result.status == STATUS_TANKER else "NO TANKER NEEDED"


# ── Tests ─────────────────────────────────────────────────────────────────

def _run_tests() -> None:
    """Validation test suite for the dry-season engine."""
    import json
    import re
    from pathlib import Path

    D = Decimal
    sep = "-" * 62
    root = Path(__file__).resolve().parent
    minto, prahladpur, zakhira = ZONES

    # ==================================================================
    # TEST 1 -- Seed data in code == data/delhi_dry_season.json
    # ==================================================================
    print(sep)
    print("TEST 1 | Seed data matches data/delhi_dry_season.json")
    print(sep)
    with open(root / "data" / "delhi_dry_season.json", encoding="utf-8") as f:
        seed = json.load(f, parse_float=D)
    assert "NOT LIVE" in seed["_notice"]
    s = seed["season"]
    assert s["days"] == SEASON_DAYS == len(RAINFALL_MM)
    assert D(s["demand_lpcd"]) == DEMAND_LPCD
    assert s["safe_line_fraction"] == SAFE_LINE
    assert s["watch_line_fraction"] == WATCH_LINE
    assert D(s["tanker_capacity_m3"]) == TANKER_CAPACITY_M3
    assert s["rainy_day_threshold_mm"] == RAINY_DAY_MM
    assert tuple(D(r) for r in seed["rainfall_mm"]) == RAINFALL_MM
    assert len(seed["zones"]) == len(ZONES)
    for z_json, z in zip(seed["zones"], ZONES):
        for key, value in z_json.items():
            if key == "area":
                continue
            assert getattr(z, key) == value, f"{z.zone_id}.{key}: {getattr(z, key)} != {value}"
    print("  code constants == JSON seed (3 zones, 90 rainfall days)")
    print("  [PASS]")
    print()

    # ==================================================================
    # TEST 2 -- runoff_coeff shared with the flood seed data
    # ==================================================================
    print(sep)
    print("TEST 2 | runoff_coeff matches data/delhi_sinks.yaml")
    print(sep)
    sinks_text = (root / "data" / "delhi_sinks.yaml").read_text(encoding="utf-8")
    pairs = re.findall(
        r'sink_id:\s*"(\w+)".*?runoff_coefficient:\s*([\d.]+)', sinks_text, re.S
    )
    sink_c = {sid: D(c) for sid, c in pairs}
    for z in ZONES:
        assert sink_c[z.linked_sink_id] == z.runoff_coeff, z.zone_id
        print(f"  {z.name:<22} {z.linked_sink_id}  C = {z.runoff_coeff}")
    print("  [PASS]")
    print()

    # ==================================================================
    # TEST 3 -- Determinism
    # ==================================================================
    print(sep)
    print("TEST 3 | Determinism (two runs identical)")
    print(sep)
    for z in ZONES:
        assert simulate_season(z) == simulate_season(z), z.zone_id
    print("  [PASS] all 3 zones x 90 days identical across runs")
    print()

    # ==================================================================
    # TEST 4 -- Day 1 hand calculations
    # ==================================================================
    #   Minto:      need = 38000 x 135 / 1000 = 5130.00
    #               frac = (35 - 16) / (35 - 12) = 19/23 = 0.826086...
    #               supply = 4450 + 600 x 0.826086 = 4945.65
    #               pct = 4945.652 / 5130 = 96.41 %  -> SAFE
    #   Prahladpur: need = 52000 x 135 / 1000 = 7020.00
    #               frac = (45 - 30) / (45 - 25) = 0.75
    #               supply = 4000 + 3600 x 0.75 = 6700.00
    #               pct = 6700 / 7020 = 95.44 %      -> SAFE
    #   Zakhira:    need = 45000 x 135 / 1000 = 6075.00
    #               frac = (30 - 14) / (30 - 10) = 0.80
    #               supply = 4700 + 1200 x 0.80 = 5660.00
    #               pct = 5660 / 6075 = 93.17 %      -> SAFE
    # ------------------------------------------------------------------
    print(sep)
    print("TEST 4 | Day 1 values match hand calculation")
    print(sep)
    expected_day1 = {
        "DELZON001": (D("5130.00"), D("4945.65"), D("96.41")),
        "DELZON002": (D("7020.00"), D("6700.00"), D("95.44")),
        "DELZON003": (D("6075.00"), D("5660.00"), D("93.17")),
    }
    for z in ZONES:
        d1 = simulate_season(z)[0]
        need, supply, pct = expected_day1[z.zone_id]
        assert (d1.need_m3, d1.supply_m3, d1.supply_pct) == (need, supply, pct), d1
        assert d1.gw_depth_m == _q(z.gw_start_depth_m)
        assert d1.status == STATUS_SAFE and d1.tankers_per_day == 0
        print(f"  {z.name:<22} need {need}  supply {supply}  {pct}%  SAFE")
    print("  [PASS]")
    print()

    # ==================================================================
    # TEST 5 -- Season story: three zones behave differently
    # ==================================================================
    print(sep)
    print("TEST 5 | Season outcomes (day 90)")
    print(sep)
    m_run, p_run, z_run = (simulate_season(z) for z in ZONES)

    assert all(r.status == STATUS_SAFE for r in m_run), "Minto should stay SAFE"
    assert z_run[-1].status == STATUS_WATCH, "Zakhira should end on WATCH"
    assert all(r.status != STATUS_TANKER for r in z_run)
    assert p_run[-1].status == STATUS_TANKER, "Prahladpur should need tankers"
    first_tanker = next(r.day for r in p_run if r.status == STATUS_TANKER)
    assert 60 <= first_tanker <= 85, first_tanker
    for run in (m_run, p_run, z_run):
        depths = [r.gw_depth_m for r in run]
        assert depths[-1] > depths[0], "water table should fall over the season"
        # alert text agrees with status on every day
        assert all((tanker_alert(r) == "WATER TANKER NEEDED") == (r.status == STATUS_TANKER) for r in run)
        assert all((r.tankers_per_day > 0) == (r.status == STATUS_TANKER) for r in run)
    for z, run in zip(ZONES, (m_run, p_run, z_run)):
        last = run[-1]
        print(f"  {z.name:<22} depth {run[0].gw_depth_m} -> {last.gw_depth_m} m  "
              f"{last.supply_pct}%  {last.status}  tankers/day={last.tankers_per_day}")
    print(f"  Pul Prahladpur first needs tankers on day {first_tanker}")
    print("  [PASS]")
    print()

    # ==================================================================
    # TEST 6 -- Rain recharge and dry-day streak
    # ==================================================================
    #   10 mm on Zakhira: 10/1000 x (1 - 0.88) / 0.12 = 0.0100 m rise
    # ------------------------------------------------------------------
    print(sep)
    print("TEST 6 | Rain recharge and dry-day streak")
    print(sep)
    assert rain_rise_m(zakhira, D("10")) == D("0.01")
    wet = simulate_season(zakhira, (D("10"), D("0")))
    dry = simulate_season(zakhira, (D("0"), D("0")))
    assert wet[1].gw_depth_m == D("14.04") and dry[1].gw_depth_m == D("14.05")
    streak = simulate_season(zakhira, (D("0"), D("2.4"), D("2.5"), D("0")))
    assert [r.dry_streak_days for r in streak] == [1, 2, 0, 1]
    print("  10 mm rain raises Zakhira water table by 0.01 m (concrete blocks most)")
    print("  2.4 mm counts as dry, 2.5 mm resets the streak (IMD rainy day)")
    print("  [PASS]")
    print()

    # ==================================================================
    # TEST 7 -- Safe-line boundaries and tanker rounding
    # ==================================================================
    print(sep)
    print("TEST 7 | Safe-line boundaries")
    print(sep)
    assert classify(D("0.90")) == STATUS_SAFE
    assert classify(D("0.8999")) == STATUS_WATCH
    assert classify(D("0.80")) == STATUS_WATCH
    assert classify(D("0.7999")) == STATUS_TANKER
    assert tankers_needed(D("1000"), D("800")) == 0       # exactly on the line
    assert tankers_needed(D("1000"), D("799.99")) == 1    # 0.01 m3 short -> 1 tanker
    assert tankers_needed(D("1000"), D("780")) == 2       # 20 m3 short -> 2 tankers
    assert tankers_needed(D("1000"), D("779.99")) == 3
    print("  0.90 SAFE | 0.80 WATCH | 0.7999 TANKER | ceil to whole tankers")
    print("  [PASS]")
    print()

    # ==================================================================
    # TEST 8 -- Invalid input rejected
    # ==================================================================
    print(sep)
    print("TEST 8 | Invalid input -> ValueError")
    print(sep)
    for bad_rain in ((D("-1"),), ()):
        try:
            simulate_season(minto, bad_rain)
            assert False, "should have raised"
        except ValueError as exc:
            print(f"  ValueError: {exc}")
    print("  [PASS]")
    print()

    print("=" * 62)
    print("ALL DROUGHT TESTS PASSED")
    print("=" * 62)


if __name__ == "__main__":
    _run_tests()
