# HydroSentry — Project Memory (AGENTS.md)

> Persistent context file for AI agents working on HydroSentry.
> Updated after each completed phase. **Do not delete — read before every task.**

---

## Project Identity

| Field | Value |
|---|---|
| **Name** | HydroSentry |
| **Domain** | Real-time urban flood monitoring & automated emergency response |
| **Geography** | Delhi NCT, India (initial deployment) |
| **DEM Source** | Copernicus GLO-30 Digital Elevation Model (30 m resolution) |
| **CRS** | WGS-84 (EPSG:4326) |
| **Units** | Strict SI — metres, square metres, cubic metres, mm |

---

## Architecture Overview

HydroSentry monitors urban depression sinks (underpasses, low-lying rail crossings) for
dangerous water accumulation during monsoon events. When rising water at a sink approaches
the **350 mm axle-drowning threshold**, the system may authorize emergency pump dispatch
via a formally verified Cedar authorization policy.

### Core Concepts

| Concept | Description |
|---|---|
| **Sink** | A topographical depression that collects surface runoff (underpass, subway, culvert basin) |
| **Invert Elevation** | The lowest point of the sink basin, from Copernicus DEM |
| **Catchment Area** | The upstream surface area funneling rainwater toward the sink |
| **Runoff Coefficient** | 0.85–0.95 for impervious urban surfaces (concrete/asphalt) |
| **Critical Volume** | Water volume that fills the sink to the 350 mm axle-drowning depth |
| **Baseline Drainage** | Gravity culvert clearance rate under normal (non-emergency) conditions |
| **Geohash Zone** | Precision-6 geohash; all Delhi sinks use the `ttn` prefix |

---

## Phase Completion Log

### Phase 0 — Core Data Model & Authorization ✅ COMPLETE

**Completed:** 2026-10-10
**Deliverables:**

| # | File | Description |
|---|---|---|
| 1 | `schemas/sink.schema.json` | JSON Schema (Draft 2020-12) for topographical sink records |
| 2 | `data/delhi_sinks.yaml` | Seed dataset — 3 high-risk Delhi underpasses |
| 3 | `policies/hydrosentry.cedarschema` | Cedar entity schema (Role, UrbanSink, DispatchEmergencyPump) |
| 4 | `policies/hydrosentry.cedar` | Cedar authorization policy (default-deny, zero wildcards) |

**Validation Gates Passed:**
- [x] JSON Schema strict mode — `additionalProperties: false` on all objects
- [x] Geohash-6 strings verified via algorithmic encoding (all `ttn*` prefix)
- [x] YAML seed data validates against JSON Schema (3/3 sinks PASS)
- [x] Cedar policy uses only `Long` integer comparisons — no floating-point
- [x] Cedar default-deny posture — no wildcard `principal`, `action`, or `resource`
- [x] SI units throughout — metres, sq metres, cubic metres, mm

**Design Decisions:**
1. **`multipleOf` removed from lat/lon** — IEEE-754 rounding makes `multipleOf: 0.00001` fail in standard validators. Precision is convention-enforced via documentation.
2. **Geohash regex** — `^ttn[0-9b-hjkmnp-z]{3}$` enforces Delhi-only scope and excludes invalid base32 characters (`a`, `i`, `l`, `o`).
3. **`runoff_coefficient` clamped [0.85, 0.95]** — reflects the impervious surface assumption for Delhi's concrete/asphalt underpass catchments.
4. **Cedar context uses Long, not Decimal** — `water_depth_mm` in integer millimetres and `time_to_submersion_mins` in integer minutes avoids Cedar's lack of floating-point support.

### Phase 1 — Hazard Compute Engine ✅ COMPLETE

**Completed:** 2026-10-10
**Deliverables:**

| # | File | Description |
|---|---|---|
| 1 | `compute.py` | Single-file hazard compute engine + Cedar mock authorizer + tests |

**Architecture:**

```
rainfall_mm_hr ──┐
                 ├──▶ compute_hazard(profile, ...) ──▶ HazardResult
SinkProfile ─────┘                                         │
                                                           ▼
                                          authorize(result) ──▶ "DISPATCH_AUTHORIZED"
                                                               "DISPATCH_DENIED"
```

**Compute Formula (Rational Method):**
- `inflow = rainfall_mm_hr / 1000 × catchment_area_m2 × runoff_coeff`
- `net = inflow - baseline_drainage_m3hr`
- If net ≤ 0: inactive (no hazard)
- `tts_min = critical_volume_m3 / net × 60`
- `volume = min(cap, net × duration / 60)`
- `depth_cm = volume / cap × critical_depth_cm`
- `hp = net × head / 270 / efficiency`

**Cedar Mock Policy (mirrors Phase 0):**
- `hazard_active == true && depth_mm >= 350 && tts_min <= 30`
- Context integers via `int()` (floor) of unrounded Decimal
- Default deny; any exception → DENIED

**Validation Gates Passed:**
- [x] All arithmetic via `decimal.Decimal` — zero float operations
- [x] Quantization: ROUND_HALF_UP to 2 decimal places
- [x] Cedar context uses only Long/Bool — no Decimal/float types
- [x] Cedar default-deny — mirrors Phase 0 policy thresholds (350 mm, 30 min)
- [x] Frozen dataclasses for SinkProfile and HazardResult
- [x] Determinism: dual-run assertions verify identical results (==)
- [x] Scenario A: 15 mm/hr → inactive → DENIED
- [x] Scenario B: 80 mm/hr → active, depth=350mm, tts=13min → AUTHORIZED
- [x] Scenario C: negative rainfall → ValueError → DENIED
- [x] Single file, stdlib only, no async/network/DB/disk

**Design Decisions:**
1. **80 mm/hr for Scenario B** — Phase 0 threshold requires `depth_mm >= 350`, which means the sink must fill to capacity. The illustrative 65 mm/hr only fills to 292mm. 80 mm/hr produces volume=capacity, depth=350mm exactly.
2. **`cedar_depth_mm` and `cedar_tts_min` stored in HazardResult** — Pre-computed from unrounded Decimals via `int()` (truncation = floor for positive values), avoiding re-derivation in the authorizer.
3. **`int()` over `math.floor()`** — For positive Decimals, `int()` truncates toward zero, which equals floor. Avoids importing math.
4. **`multipleOf` omitted from Decimal quantization of intermediates** — Full Decimal precision is used for all intermediate steps; only result fields are quantized to 2dp. This prevents error accumulation.

### Phase 2 — Infrastructure as Code ✅ COMPLETE

**Completed:** 2026-10-10
**Deliverables:**

| # | File | Description |
|---|---|---|
| 1 | `template.yaml` | SAM template — single stack, Free Tier, all resources |
| 2 | `src/app.py` | Lambda handler stub (Phase 3 placeholder) |
| 3 | `src/requirements.txt` | Empty dependency file for SAM build |
| 4 | `env.json` | Local env vars for sam local against LocalStack |

**Infrastructure Resources (10 total):**

| Resource | Type | Purpose |
|---|---|---|
| `HazardStateTable` | DynamoDB | PK=sink_id, PAY_PER_REQUEST, TTL on expires_at |
| `HttpApi` | API Gateway v2 | CORS, throttle 10rps/burst20 |
| `ComputeFunction` | Lambda (arm64) | python3.12, 128MB, 10s timeout |
| `ComputeFunctionLogGroup` | CloudWatch Logs | 7-day retention |
| `HydroSentryBus` | EventBridge | Custom event bus |
| `EmergencyDispatchRule` | EventBridge Rule | source=hydrosentry.engine -> SNS |
| `EmergencyAlertsTopic` | SNS | Municipal dispatch notifications |
| `EmergencyAlertsTopicPolicy` | SNS Policy | events.amazonaws.com allowed |
| `AlertEmailSubscription` | SNS (conditional) | Email subscription if param set |
| `AlertHttpsSubscription` | SNS (conditional) | HTTPS webhook if param set |

**Event Flow:**
```
POST /telemetry/rainfall
    -> Lambda compute_hazard()
    -> DynamoDB PutItem (hazard state)
    -> EventBridge PutEvents (on INACTIVE->ACTIVE transition)
    -> SNS Publish (EmergencyDispatchAuthorized)
    -> Email / HTTPS webhook

GET /hazards/active
    -> Lambda DynamoDB Scan
    -> JSON response
```

**Validation Gates Passed:**
- [x] Template YAML parses correctly with CF intrinsic functions
- [x] All 10 resources match expected types
- [x] Lambda config: CodeUri=src/, Handler=app.lambda_handler, python3.12, arm64, 128MB, 10s
- [x] DynamoDB: PAY_PER_REQUEST, TTL enabled, PITR disabled
- [x] IAM: granular (PutItem/GetItem/Scan only), EventBridgePutEventsPolicy
- [x] CORS: parameterized origins, never both "*" and specific
- [x] SNS TopicPolicy: ArnEquals scoped to EmergencyDispatchRule
- [x] Optional subscriptions behind Conditions (empty-string default)
- [x] LocalEndpointUrl -> AWS_ENDPOINT_URL via !If/AWS::NoValue
- [x] No nested stacks, Dockerfiles, NAT, or always-on compute

**Design Decisions:**
1. **Fixed resource names** (HydroSentry-*) — Hackathon-grade; single deployment per region. Production would use `!Sub "${AWS::StackName}-*"` for multi-stack.
2. **Explicit LogGroup + LoggingConfig** — Controls 7-day retention instead of Lambda's default infinite retention. Prevents CloudWatch cost creep.
3. **`$default` stage** — HttpApi uses the implicit default stage. No custom domain or stage name needed for hackathon.
4. **CorsAllowOrigins as CommaDelimitedList** — Allows parameter override with `"http://localhost:5173,http://localhost:3000"` for dev, `"*"` for open access.

### Phase 3 — Operations Console ✅ COMPLETE

**Completed:** 2026-10-10
**Deliverables:**

| # | File | Description |
|---|---|---|
| 1 | `console.html` | Self-contained single-file operations console |

**Architecture:**
- Leaflet 1.9.4 (SRI-pinned via unpkg) + OSM tiles, CARTO dark fallback on tileerror
- CSS Grid 70/30 (stacks below 900px), full-height map via ResizeObserver
- `baseGroup` (neutral sink markers, permanent) + `hazardGroup` (cleared on every render)
- Single `render(stateMap)` function, idempotent
- Phase 1 formulas ported to JS (half-up rounding via `Math.floor(v*100+0.5)/100`)
- Cedar mock in JS: same thresholds (depth_mm >= 350, tts_min <= 30)
- Visual states: CLEAR / WATCH / IMMINENT / INUNDATED (display thresholds TTS <= 45 / <= 120)
- API_BASE = "" -> local simulation; badge reads "SIMULATED - CEDAR MOCK"

**Validation Gates Passed:**
- [x] file:// opens with zero uncaught JS exceptions (global error/rejection guards)
- [x] Leaflet 1.9.4 pinned with SRI + crossorigin
- [x] No default Leaflet marker images (circleMarker + divIcon only)
- [x] OSM tile error -> CARTO dark fallback + non-blocking notice
- [x] Overlays render independent of tile availability
- [x] fitBounds over 3 sinks after setView
- [x] ResizeObserver calls invalidateSize()
- [x] Load-time golden assertion: Minto 65 mm/hr matches Phase 1 values
- [x] Click sequence [3,3,2,3,1] -> hazardGroup counts [18,18,0,18,0] = n,n,0,n,0
- [x] Queue sorted ascending by TTS, inactive last, ties by sink_id, aria-live polite
- [x] IMMINENT: pulse ring (prefers-reduced-motion disabled) + circle + polygon + detour
- [x] Detour labeled "ILLUSTRATIVE - NOT NAVIGATION"
- [x] EventBridge payload preview mirrors Phase 2 event schema
- [x] aria-pressed on all scenario buttons
- [x] textContent only for live-API rendered text

**Design Decisions:**
1. **Visual IMMINENT threshold = TTS <= 45 min** — Phase 0 profiles at 65 mm/hr produce TTS 39-43 min. Cedar's 30-min auth threshold is separate from the UI alert level.
2. **6 layers per IMMINENT sink** — pulse marker + backing circle + corridor polygon + corridor label + detour polyline + detour label. hazardGroup.clearLayers() resets all.
3. **`halfUp2dp = Math.floor(v*100+0.5)/100`** — Portable half-up rounding without Decimal, matching Phase 1 ROUND_HALF_UP to 2dp exactly.
4. **Fixed clock injection** — EventBridge payload uses a static timestamp to ensure reproducibility in offline/demo mode.

---

## Seed Data Reference

| Sink ID | Name | Lat | Lon | Geohash-6 | Invert (m) | Catchment (m²) | C | Vol (m³) | Drain (m³/hr) |
|---|---|---|---|---|---|---|---|---|---|
| DELSNK001 | Minto Bridge Underpass | 28.63361 | 77.21722 | ttnfvh | 210.40 | 48,500 | 0.92 | 1,850 | 120 |
| DELSNK002 | Pul Prahladpur Underpass | 28.49770 | 77.29470 | ttnfng | 203.15 | 62,000 | 0.90 | 2,400 | 95 |
| DELSNK003 | Zakhira Underpass | 28.65900 | 77.16800 | ttngh1 | 213.80 | 41,200 | 0.88 | 1,620 | 80 |

---

## Cedar Authorization Model

```
┌─────────────────────────────────────────────────────────┐
│  DEFAULT DENY — Cedar native architecture               │
│                                                         │
│  PERMIT only when ALL conditions met:                   │
│    Principal  == Role::"AutomatedSentinel"              │
│    Action     == Action::"DispatchEmergencyPump"         │
│    Resource   is UrbanSink                              │
│    context.water_depth_mm          >= 350               │
│    context.time_to_submersion_mins <= 30                │
│                                                         │
│  Everything else → DENY (implicit)                      │
└─────────────────────────────────────────────────────────┘
```

---

## Directory Layout

```
HydroSentry/
├── AGENTS.md                         ← This file (project memory)
├── compute.py                        ← Phase 1: Hazard compute + Cedar mock
├── template.yaml                     ← Phase 2: SAM infrastructure template
├── env.json                          ← Phase 2: Local env vars for sam local
├── console.html                      ← Phase 3: Operations console (single file)
├── src/
│   ├── app.py                        ← Lambda handler (stub; Phase 3)
│   └── requirements.txt              ← Python dependencies for SAM build
├── schemas/
│   └── sink.schema.json              ← JSON Schema (Draft 2020-12)
├── data/
│   └── delhi_sinks.yaml              ← Seed dataset (3 Delhi sinks)
└── policies/
    ├── hydrosentry.cedarschema       ← Cedar entity type definitions
    └── hydrosentry.cedar             ← Cedar authorization policy
```

---

## Constraints for Future Phases

- **Phase 1+:** May introduce application logic, APIs, frontends — but must conform to the data model defined in Phase 0.
- **No third-party spatial DB libraries** were used in Phase 0.
- **Schema is immutable** within a phase — any field additions require a new schema version.
- **Cedar policy must remain default-deny** — no `permit` without explicit principal/action/resource scoping.
- **All new sinks** must have geohash-6 starting with `ttn` (Delhi geographic bound).

---

## Key Technical Notes

1. **Copernicus DEM elevations** are relative to the EGM2008 geoid (≈mean sea level), not WGS-84 ellipsoid height.
2. **350 mm threshold** — derived from the minimum axle-to-ground clearance for standard Indian passenger vehicles (~170 mm) with a 2× safety factor.
3. **Geohash base32 alphabet** excludes `a`, `i`, `l`, `o` to avoid confusion with `0`, `1`. The regex in the schema accounts for this.
4. **Cedar Long type** is a signed 64-bit integer — sufficient for mm-precision depth and minute-precision time without floating-point.
