# HydroSentry 🌊

HydroSentry is a real-time urban flood monitoring and automated emergency dispatch system built for vulnerable road underpasses in **Delhi NCT, India**.

During heavy monsoon rains, water rapidly fills low-lying underpasses, trapping motorists. HydroSentry calculates flood risk using topographical elevation data and rainfall rates, automatically authorizing emergency pump dispatch before water reaches the critical **350 mm axle-drowning depth**.

---

## What We Have Built So Far

The project is built in structured, verified phases:

### 1. Phase 0 — Core Data Model & Safety Policy
- **Sink Schema:** Defined strict data contracts ([sink.schema.json](file:///e:/HydroSentry/schemas/sink.schema.json)) for underpass depression sinks.
- **Delhi Seed Data:** Configured topographical profiles for 3 notorious flood hotspots ([delhi_sinks.yaml](file:///e:/HydroSentry/data/delhi_sinks.yaml)):
  - **Minto Bridge Underpass** (Central Delhi)
  - **Pul Prahladpur Underpass** (South-East Delhi)
  - **Zakhira Underpass** (West Delhi)
- **Cedar Authorization:** Implemented formal default-deny security policies ([hydrosentry.cedar](file:///e:/HydroSentry/policies/hydrosentry.cedar)) requiring depth >= 350 mm and time-to-submersion <= 30 min for automated pump dispatch.

### 2. Phase 1 — Hazard Compute Engine
- **Deterministic Math:** Pure Python engine ([compute.py](file:///e:/HydroSentry/compute.py)) using high-precision Decimal arithmetic (no floats).
- **Rational Runoff Model:** Computes water inflow, net accumulation, time-to-submersion (TTS), and emergency pump horsepower.
- **Cedar Mock Authorizer:** Evaluates hazard metrics against security policies with deterministic pass/fail tests.

### 3. Phase 2 — Serverless Cloud Infrastructure
- **AWS SAM Template:** Complete AWS Free-Tier architecture ([template.yaml](file:///e:/HydroSentry/template.yaml)).
- **Event-Driven Flow:**
  - **API Gateway (HTTP API):** Ingests live rainfall data (`POST /telemetry/rainfall`).
  - **AWS Lambda (Python 3.12 / ARM64):** Runs hazard computation.
  - **DynamoDB:** Stores current sink hazard states with automated TTL expiration.
  - **EventBridge & SNS:** Broadcasts emergency dispatch alerts via email/webhooks when risk goes from clear to critical.

### 4. Phase 3 — Operations Console
- **Interactive Map:** Single-file operations dashboard ([console.html](file:///e:/HydroSentry/console.html)) with Leaflet maps.
- **Zero-Setup Testing:** Runs directly in any web browser without local build tools or web servers.
- **Features:**
  - One-click scenario simulations (Dry, Moderate, Flash Flood 65 mm/hr, Cloudburst 100 mm/hr).
  - Dynamic hazard zones, detour suggestions, and time-to-submersion countdown queue.
  - Live API integration toggle for real backend telemetry.

---

## Quick Start

### 1. Run the Hazard Compute Tests (Python)
No external packages needed — uses Python's standard library:
```bash
python compute.py
```
*Expected output: All unit tests and scenario validations PASS.*

### 2. Open the Operations Console (Browser)
Simply double-click [console.html](file:///e:/HydroSentry/console.html) or open it in your browser:
```bash
# On Windows
start console.html
```
Click **"Flash Flood (65 mm/h)"** or **"Cloudburst (100 mm/h)"** to see live hazard calculations, pulse alerts, and detour corridors in action.

---

## Project Structure

```
HydroSentry/
├── AGENTS.md               # Technical project memory & validation history
├── README.md               # Project overview (this file)
├── compute.py              # Phase 1: Python hazard engine & test suite
├── console.html            # Phase 3: Interactive single-file operations map
├── template.yaml           # Phase 2: AWS SAM serverless cloud template
├── env.json                # Local testing configuration for AWS SAM
├── data/
│   └── delhi_sinks.yaml    # Topographical data for Delhi underpasses
├── schemas/
│   └── sink.schema.json    # JSON Schema definition for sink profiles
├── policies/
│   ├── hydrosentry.cedar   # Formal Cedar authorization policy
│   └── hydrosentry.cedarschema
└── src/
    ├── app.py              # Lambda handler stub
    └── requirements.txt    # Lambda Python dependencies
```

---

## Key Numbers

| Metric | Value | Description |
|---|---|---|
| **Critical Depth** | `350 mm` | Axle-drowning threshold for standard passenger vehicles |
| **Max Alert Window** | `30 mins` | Required time-to-submersion window to trigger emergency pump |
| **Elevation Reference** | Copernicus GLO-30 | 30-meter resolution Digital Elevation Model |
