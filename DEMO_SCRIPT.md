# HydroSentry - 3:00 Demo Script

Fill the three `{{...}}` slots before recording. Nothing else in the voiceover depends on outside facts.

| Slot | Source |
|---|---|
| `{{AVG_MS}}` | "curl time_total ... avg" line printed by `./test_e2e.sh` (sam local + emulator, **not** AWS) |
| `{{CRITERION_05}}` | Criterion 05 text - not supplied, so beats are not yet aligned (see bottom) |
| Incident | None cited. Add one only with your own source; the hook works without it |

| Timestamp | Visual | Voiceover |
|---|---|---|
| **0:00-0:30** | Title card, then `console.html` full screen, **Dry** scenario: three green sink markers on the Delhi map. | Every monsoon, Delhi's underpasses fill faster than anyone can react. HydroSentry watches those low points. For each one it estimates how fast water is arriving, how many minutes remain before depth reaches 350 millimetres, our axle-drowning threshold, and whether a written policy allows pump dispatch. No guesswork, and no pump sent on a hunch. Today: the console, the backend, and the tests that keep them honest. |
| **0:30-1:15** | Console. Point at the badge "SIMULATED - CEDAR MOCK". Click **3 Cloudburst 65 mm/hr**. Queue re-sorts; Minto Bridge pulse ring, corridor, dashed detour with its "ILLUSTRATIVE - NOT NAVIGATION" label. Zoom on the Cedar line: DISPATCH_DENIED. | This is the operations console, running in offline simulation, as the badge says. Three Delhi underpasses. I switch to a sixty-five millimetre-per-hour cloudburst. Each sink recomputes with the rational runoff method: rain on the catchment, minus what the culvert drains. Minto's catchment is about forty-eight thousand square metres, draining one hundred twenty cubic metres an hour. The queue sorts by minutes to submersion, and Minto Bridge leads at about forty. The detour line is illustrative, not navigation. Notice the policy still says denied. After a fifteen-minute storm, Minto is about one hundred thirty millimetres deep, well short of 350. The system does not cry wolf. |
| **1:15-2:05** | Split terminal, `sam local` running against the emulator. (1) `curl` POST 65 mm/hr, `jq` output. (2) POST 169 mm/hr. (3) SQS-captured event, `jq` showing source / detail-type. (4) `GET /hazards/active` beside a DynamoDB item with `expires_at`; highlight the filter line in `src/app.py`. | Now the real backend, running locally: SAM, Lambda, DynamoDB and EventBridge on an emulator. The API replies with status, depth, time to submersion, pump power and the policy decision. Post sixty-five millimetres: hazard active, 131 millimetres, 39 minutes, roughly 51 horsepower of pump power, dispatch denied. Post one hundred sixty-nine: depth reaches 350 millimetres, 14 minutes remain, dispatch authorized. Repeat the call and the response is identical. That emits an EmergencyDispatchAuthorized event, routed through SNS; here it lands in a queue. State carries an expires_at timestamp, and the active-hazards endpoint filters on it, so stale readings vanish without waiting for TTL deletion. Sink profiles were prepared offline from Copernicus thirty-metre elevation data; nothing reads that data at runtime. |
| **2:05-2:40** | Terminal: `./test_e2e.sh`, scroll through Section B lines (`cedar ALLOW == mock ALLOW`, `DENY == DENY`), then Sections D and E. Show `ctx_*.json` generation line: "generated 37 Cedar contexts ... from compute.py". | When a policy can send equipment, you verify it. This script generates its test cases from the compute engine itself, never typed by hand, and runs them through the real Cedar command line. Every decision is compared with the evaluator the Lambda uses, and exit codes are checked strictly. That includes the exact boundaries: 349 versus 350 millimetres, 30 versus 31 minutes. Then it boots the whole stack and asserts the API contract, identical repeat responses, the stored record, and the delivered event. |
| **2:40-3:00** | Full-screen terminal: `RESULT: PASS  N/N assertions passed` banner and the latency line. End card: HydroSentry. | Result: every assertion passes. Through the local stack a request takes about `{{AVG_MS}}` milliseconds; that is a local figure, not a production claim. The design is serverless, so zero idle cost, and cents at demo scale. HydroSentry: see the water coming, and act before the axles go under. |

## Recording checklist

1. Run `./test_e2e.sh` once off-camera; copy the latency average into `{{AVG_MS}}`. Re-run on camera for the PASS banner.
2. "37 Cedar contexts" is the current count (3 seed sinks); re-read it from the run output before recording.
3. Words per segment (approx. budget 75 / 110 / 125 / 85 / 50): 66 / 105 / 118 / 83 / 48 - recount with `wc -w` if you edit.

## Claims deliberately **not** made

- No live DEM lookup (the DEM is offline provenance only) and no "formally verified" - Cedar is checked by differential testing, not proof.
- The Lambda uses a Python evaluator that mirrors the Cedar policy; real Cedar runs in the test script.
- No real-AWS latency or cost figures; no live TTL deletion; detour is never called a route.
- Console never shows an authorized dispatch (its presets top out at 65 mm/hr); authorization is shown in the terminal at 169 mm/hr.

## Criterion 05 alignment - TODO

Criterion 05 text was not provided (`[paste text]` left in the request). Paste it here and I will map beats to it:

> `{{CRITERION_05}}`

| Beat | Criterion 05 element it should evidence |
|---|---|
| 0:30-1:15 | _pending_ |
| 1:15-2:05 | _pending_ |
| 2:05-2:40 | _pending_ |
