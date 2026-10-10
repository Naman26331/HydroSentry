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

## Setup Runbook

Everything below is run from the project folder (`HydroSentry/`, where `template.yaml` lives).

### 1. Open the app (no install, no build)
Double-click **`console.html`**. It opens in any browser. If no backend is running it shows a clearly-labelled *offline demo* using the same maths as `compute.py`.
Backend address: top of the `<script>` in `console.html`, the line `const API_BASE_URL = "http://127.0.0.1:3000";` (change it to your API Gateway URL after deploying).

### 2. Create your `.env`
1. In the project root (next to `template.yaml`), copy the template: `cp .env.example .env`
2. Open `.env`. For local use leave it as is (`ENVIRONMENT=LOCAL`, `AWS_REGION=ap-south-1`, table `HydroSentry-HazardState`, bus `HydroSentry-EventBus`, `API_GATEWAY_URL=http://127.0.0.1:3000`).
3. For the cloud, set `ENVIRONMENT=AWS` and `API_GATEWAY_URL` to the URL printed by the deploy (step 5).
`.env` is git-ignored. Never commit keys.

### 3. Give the tools your AWS credentials (cloud steps only)
Pick **one**:
- **Normal AWS account:** run `aws configure` and enter Access Key ID, Secret, region `ap-south-1`. They are saved in `~/.aws/credentials` (outside the project).
- **Learner Lab / Builder Center (temporary keys):** copy the three values from the lab's "AWS Details" page and paste them into your terminal:
  ```
  export AWS_ACCESS_KEY_ID=...
  export AWS_SECRET_ACCESS_KEY=...
  export AWS_SESSION_TOKEN=...
  export AWS_DEFAULT_REGION=ap-south-1
  ```
  (Windows PowerShell: `$env:AWS_ACCESS_KEY_ID="..."`, etc.) They expire, so repeat when the lab restarts. Alternatively paste them into the commented lines at the bottom of `.env`.
Deployed Lambdas need no keys: they use their IAM role automatically.

### 4. Run the backend locally (free, no AWS account)
Needs Docker, AWS SAM CLI, and a local AWS emulator on port 4566 (e.g. LocalStack) with the table and event bus created. The automated way, which does all of that for you, is `./test_e2e.sh` (needs `LOCALSTACK_AUTH_TOKEN`). Manual start once an emulator is up:
```
sam build
sam local start-api --env-vars env.json --parameter-overrides LocalEndpointUrl=http://host.docker.internal:4566
```
The API is then at `http://127.0.0.1:3000`, which is what `console.html` expects. `env.json` holds the local variable values (`ENVIRONMENT=LOCAL`, table and bus names).

### 5. Deploy to live AWS (one command)
```
sam build && sam deploy --guided
```
Accept the defaults (stack name `hydrosentry`, region `ap-south-1`, leave `LocalEndpointUrl` empty). Copy the `ApiUrl` output into `API_BASE_URL` in `console.html` and `API_GATEWAY_URL` in `.env`. Delete everything later with `sam delete`.

---

## Project Structure

```
HydroSentry/
├── AGENTS.md               # Technical project memory & validation history
├── README.md               # Project overview (this file)
├── compute.py              # Phase 1: Python hazard engine & test suite
├── console.html            # Google-Maps-style single-file client (offline demo or live API)
├── template.yaml           # Phase 2: AWS SAM serverless cloud template
├── env.json                # Local sam-local variables (ENVIRONMENT=LOCAL)
├── .env.example            # Copy to .env: region, table, bus, API URL, environment
├── test_e2e.sh             # End-to-end verification (LocalStack + sam local + Cedar CLI)
├── DEMO_SCRIPT.md          # 3-minute demo script
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
