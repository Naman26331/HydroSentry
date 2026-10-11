#!/bin/sh
# ============================================================================
# HydroSentry - Phase 4 end-to-end verification
# ============================================================================
# POSIX sh (no bashisms, no pipefail). Every wait has a deadline; every curl
# has --max-time. Cedar fixtures and golden values are generated from
# compute.py + data/delhi_sinks.yaml at run time - never hand-typed.
#
# Usage:  ./test_e2e.sh [--keep]
#   --keep   leave emulator, sam local and temp dir up for inspection
#
# Env:
#   LOCALSTACK_AUTH_TOKEN   required unless EMULATOR_ENDPOINT is supplied
#   EMULATOR_ENDPOINT       use an already-running emulator (not started or
#                           stopped by this script)
#   EMULATOR_LAMBDA_ENDPOINT  how Lambda containers reach that emulator
#                           (default http://host.docker.internal:4566)
#   PORT                    sam local port (default 3000)
#   API_DEADLINE_S          wait for sam local (default 60)
# ============================================================================
set -eu

cd "$(dirname "$0")"
REPO="$(pwd)"

# -- Config ------------------------------------------------------------------
PORT="${PORT:-3000}"
API_DEADLINE_S="${API_DEADLINE_S:-60}"
EMU_DEADLINE_S="${EMU_DEADLINE_S:-90}"
SQS_DEADLINE_S="${SQS_DEADLINE_S:-30}"
LOCALSTACK_IMAGE="${LOCALSTACK_IMAGE:-localstack/localstack:latest}"

# Never touch a real AWS account: force dummy credentials and region.
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
AWS_REGION="$AWS_DEFAULT_REGION"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_REGION
unset AWS_PROFILE AWS_SESSION_TOKEN AWS_ENDPOINT_URL 2>/dev/null || true

NET="hydrosentry-e2e-net"
EMU_NAME="hydrosentry-e2e-emulator"
TABLE_NAME="HydroSentry-HazardState"
BUS_NAME="HydroSentry-EventBus"
RULE_NAME="EmergencyDispatchRule"
TOPIC_NAME="HydroSentry-EmergencyAlerts"
QUEUE_NAME="hydrosentry-e2e-capture"
SINK="DELSNK001"

KEEP=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then
  RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; RST='\033[0m'
else
  RED=''; GRN=''; YLW=''; RST=''
fi

PASS=0; FAIL=0
SAM_PID=""
TMP=""
EMU_STARTED=0
NET_CREATED=0
EMULATOR_ENDPOINT="${EMULATOR_ENDPOINT:-}"
EXTERNAL_EMU=0
[ -n "$EMULATOR_ENDPOINT" ] && EXTERNAL_EMU=1

# -- Reporting ---------------------------------------------------------------
section() { printf '\n%b=== %s ===%b\n' "$YLW" "$1" "$RST"; }
pass() { PASS=$((PASS + 1)); printf '%b  [PASS]%b %s\n' "$GRN" "$RST" "$1"; }
fail() {
  FAIL=$((FAIL + 1)); printf '%b  [FAIL]%b %s\n' "$RED" "$RST" "$1"
  [ -n "${2:-}" ] && printf '         %s\n' "$2"
  return 0
}
die() { fail "FATAL: $1" "${2:-}"; exit 1; }

# check_eq LABEL EXPECTED ACTUAL
check_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected='$2' actual='$3'"; fi
}
# check_jq LABEL JSON FILTER   (passes iff jq -e FILTER is truthy)
check_jq() {
  if printf '%s' "$2" | jq -e "$3" >/dev/null 2>&1; then pass "$1"
  else fail "$1" "jq filter false: $3 -- input: $(printf '%s' "$2" | head -c 300)"; fi
}

# wait_until DEADLINE_S INTERVAL_S CMD...   -> 0 if CMD succeeded before deadline
wait_until() {
  _dl=$(( $(date +%s) + $1 )); _iv=$2; shift 2
  while :; do
    if "$@"; then return 0; fi
    if [ "$(date +%s)" -ge "$_dl" ]; then return 1; fi
    sleep "$_iv"
  done
}

awsl() {
  aws --endpoint-url "$EMULATOR_ENDPOINT" --cli-connect-timeout 5 \
      --cli-read-timeout 30 --no-cli-pager "$@"
}

# -- Cleanup (idempotent; runs on EXIT, INT, TERM) ---------------------------
CLEANED=0
cleanup() {
  _rc=$?
  if [ "$CLEANED" = 1 ]; then return 0; fi
  CLEANED=1
  trap '' INT TERM
  set +e
  printf '\n%b[cleanup]%b\n' "$YLW" "$RST"
  if [ "$KEEP" = 1 ]; then
    printf '  --keep: leaving everything up. sam pid/pgid=%s  tmp=%s\n' "${SAM_PID:-none}" "${TMP:-none}"
    printf '  stop later: kill -s TERM -- -%s; docker rm -f %s; docker network rm %s\n' \
      "${SAM_PID:-0}" "$EMU_NAME" "$NET"
  else
    if [ -n "$SAM_PID" ]; then
      # sam runs in its own process group (set -m), so signal the group.
      kill -s TERM -- "-$SAM_PID" 2>/dev/null || kill -s TERM "$SAM_PID" 2>/dev/null
      _i=0
      while [ "$_i" -lt 10 ] && kill -0 "$SAM_PID" 2>/dev/null; do sleep 1; _i=$((_i + 1)); done
      kill -s KILL -- "-$SAM_PID" 2>/dev/null
      wait "$SAM_PID" 2>/dev/null
      SAM_PID=""
    fi
    if [ "$NET_CREATED" = 1 ]; then
      # Lambda containers sam started live on our network; remove them all.
      _ids="$(docker ps -aq --filter "network=$NET" 2>/dev/null)"
      [ -n "$_ids" ] && docker rm -f $_ids >/dev/null 2>&1
    fi
    if [ "$EMU_STARTED" = 1 ]; then docker rm -f "$EMU_NAME" >/dev/null 2>&1; fi
    if [ "$NET_CREATED" = 1 ]; then docker network rm "$NET" >/dev/null 2>&1; fi
    if [ -n "$TMP" ] && [ -d "$TMP" ]; then rm -rf "$TMP"; fi
  fi
  _total=$((PASS + FAIL))
  printf '\n%b================================================%b\n' "$YLW" "$RST"
  if [ "$FAIL" -eq 0 ] && [ "$_rc" -eq 0 ] && [ "$_total" -gt 0 ]; then
    printf '  %bRESULT: PASS%b   %d/%d assertions passed\n' "$GRN" "$RST" "$PASS" "$_total"
  else
    printf '  %bRESULT: FAIL%b   %d passed, %d failed (of %d)\n' "$RED" "$RST" "$PASS" "$FAIL" "$_total"
    [ "$_rc" -eq 0 ] && _rc=1
  fi
  printf '%b================================================%b\n' "$YLW" "$RST"
  exit "$_rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ============================================================================
# A. Preflight + template lint
# ============================================================================
section "A. Preflight and sam validate"

MISSING=""
for c in docker sam cedar jq curl aws python3; do
  command -v "$c" >/dev/null 2>&1 || MISSING="$MISSING $c"
done
if [ -n "$MISSING" ]; then
  printf '%b[preflight]%b missing required tools:%s\n' "$RED" "$RST" "$MISSING" >&2
  exit 2
fi
if [ "$EXTERNAL_EMU" = 0 ] && [ -z "${LOCALSTACK_AUTH_TOKEN:-}" ]; then
  printf '%b[preflight]%b set LOCALSTACK_AUTH_TOKEN (or EMULATOR_ENDPOINT for an existing emulator)\n' "$RED" "$RST" >&2
  exit 2
fi
if ! docker info >/dev/null 2>&1; then
  printf '%b[preflight]%b docker daemon not reachable\n' "$RED" "$RST" >&2
  exit 2
fi
# The docker CLI finds the daemon via its active context, but sam only reads
# DOCKER_HOST (default /var/run/docker.sock, which Docker Desktop on macOS
# does not create unless the "default Docker socket" option is enabled).
if [ -z "${DOCKER_HOST:-}" ] && [ ! -S /var/run/docker.sock ]; then
  DOCKER_HOST="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)" || DOCKER_HOST=""
  [ -n "$DOCKER_HOST" ] && export DOCKER_HOST
fi

port_free() {
  python3 -c 'import socket,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.close()' "$1" 2>/dev/null
}
if ! port_free "$PORT"; then
  printf '%b[preflight]%b port %s already in use (set PORT=...)\n' "$RED" "$RST" "$PORT" >&2
  exit 2
fi
if [ "$EXTERNAL_EMU" = 0 ]; then
  EMULATOR_ENDPOINT="http://127.0.0.1:4566"
  if ! port_free 4566; then
    printf '%b[preflight]%b port 4566 in use; pass EMULATOR_ENDPOINT to reuse an emulator\n' "$RED" "$RST" >&2
    exit 2
  fi
fi
printf '  tools OK, port %s free, emulator=%s\n' "$PORT" "$EMULATOR_ENDPOINT"

TMP="$(mktemp -d)"

if sam validate --lint --template-file template.yaml >"$TMP/validate.log" 2>&1; then
  pass "A: sam validate --lint --template-file template.yaml"
else
  fail "A: sam validate --lint" "$(tail -5 "$TMP/validate.log")"
fi

# ============================================================================
# B. Cedar: fixtures from compute output, strict exit codes, differential test
# ============================================================================
section "B. Cedar policy vs mock evaluator"

cat > "$TMP/gen.py" <<'PYEOF'
"""Generate Cedar fixtures + golden values from compute.py (the oracle)."""
import json, os, re, sys
from decimal import Decimal

mode = sys.argv[1]

if mode == "pattern":
    # Extract Resources.EmergencyDispatchRule...EventPattern from template.yaml
    # (stdlib only; handles the plain key / "- value" shape used there).
    lines = open(sys.argv[2]).read().splitlines()
    start = next(i for i, l in enumerate(lines) if l.strip() == "EventPattern:")
    base = len(lines[start]) - len(lines[start].lstrip())
    pat, key = {}, None
    for l in lines[start + 1:]:
        if not l.strip() or l.strip().startswith("#"):
            continue
        ind = len(l) - len(l.lstrip())
        if ind <= base:
            break
        s = l.strip()
        if s.endswith(":"):
            key = s[:-1]; pat[key] = []
        elif s.startswith("- ") and key:
            pat[key].append(s[2:].strip().strip('"\''))
        else:
            sys.exit("unsupported EventPattern shape: " + s)
    print(json.dumps(pat, separators=(",", ":")))
    sys.exit(0)

repo, out, primary = sys.argv[2], sys.argv[3], sys.argv[4]
sys.path.insert(0, repo)
import compute as C

# -- Sink profiles from the seed YAML (independent of src/app.py constants) --
KEYS = ("sink_id", "catchment_area_sq_m", "runoff_coefficient",
        "critical_volume_capacity_m3", "baseline_drainage_rate_m3_per_hr")
rx = re.compile(r'^\s*(?:-\s+)?(%s):\s*"?([^"\s#]+)"?\s*(?:#.*)?$' % "|".join(KEYS))
sinks, cur = [], None
for line in open(os.path.join(repo, "data", "delhi_sinks.yaml")):
    m = rx.match(line.rstrip("\n"))
    if not m:
        continue
    k, v = m.groups()
    if k == "sink_id":
        cur = {"sink_id": v}; sinks.append(cur)
    elif cur is not None:
        cur[k] = Decimal(v)
for s in sinks:
    if len(s) != len(KEYS):
        sys.exit("incomplete sink record: %r" % s)
if len(sinks) != 3:
    sys.exit("expected 3 sinks, parsed %d" % len(sinks))

def profile(s):
    return C.SinkProfile(
        catchment_area_m2=s["catchment_area_sq_m"],
        runoff_coeff=s["runoff_coefficient"],
        baseline_drainage_m3hr=s["baseline_drainage_rate_m3_per_hr"],
        critical_volume_m3=s["critical_volume_capacity_m3"])

def evaluate(s, rain):
    r = C.compute_hazard(profile(s), Decimal(rain))
    ctx = C._build_cedar_context(r)            # {hazard_active, depth_mm, tts_min}
    mock = C._evaluate_cedar_policy(ctx)
    assert mock == (C.authorize(r) == "DISPATCH_AUTHORIZED"), "mock/authorize disagree"
    return r, ctx, mock

def min_auth_rain(s):
    for rain in range(0, 3000):
        if evaluate(s, rain)[2]:
            return rain
    sys.exit("no authorizing rainfall found for " + s["sink_id"])

cases = []   # (label, cedar_context_dict, mock_bool)
seen = set()
def add(label, ctx, mock):
    key = (ctx["depth_mm"], ctx["tts_min"], ctx["hazard_active"])
    if label in seen:
        return
    seen.add(label)
    cases.append((label, ctx, mock))

for s in sinks:
    m = min_auth_rain(s)
    for rain in sorted({0, 15, 30, 65, 100, 150, 200, 300, m - 1, m, m + 1}):
        _, ctx, mock = evaluate(s, rain)
        add("%s@%dmm/hr" % (s["sink_id"], rain), ctx, mock)

# Threshold-edge contexts built from the mock's own constants.
D, T = C._DEPTH_THRESHOLD_MM, C._TTS_THRESHOLD_MIN
for lbl, d, t in (("edge depth=T tts=T", D, T), ("edge depth=T-1", D - 1, T),
                  ("edge tts=T+1", D, T + 1), ("inactive sentinel", 0, -1)):
    ctx = {"hazard_active": True, "depth_mm": d, "tts_min": t}
    add(lbl, ctx, C._evaluate_cedar_policy(ctx))

os.makedirs(out, exist_ok=True)
with open(os.path.join(out, "cases.tsv"), "w") as tsv:
    for i, (label, ctx, mock) in enumerate(cases):
        path = os.path.join(out, "ctx_%03d.json" % i)
        # Policy/schema attribute names (Phase 0); hazard_active has no Cedar
        # counterpart - inactive results already map to depth 0 / tts -1.
        json.dump({"water_depth_mm": ctx["depth_mm"],
                   "time_to_submersion_mins": ctx["tts_min"]}, open(path, "w"))
        tsv.write("%s\t%s\t%s\n" % (label, path, "ALLOW" if mock else "DENY"))

# -- Golden values for the HTTP assertions ------------------------------------
sink = next(s for s in sinks if s["sink_id"] == primary)
m = min_auth_rain(sink)
def golden(rain):
    r, ctx, _ = evaluate(sink, rain)
    auth = C.authorize(r)
    return {"rain": rain,
            "status": "HAZARD_ACTIVE" if r.active else "CLEAR",
            "depth_mm": r.cedar_depth_mm,
            "tts_min": r.cedar_tts_min if r.active else None,
            "hp": float(r.horsepower) if r.active else 0,
            "auth": auth}
# Highest integer rainfall that the sink's baseline drainage still absorbs.
clear_rain = max(r for r in range(0, m) if not evaluate(sink, r)[0].active)
g = {"sink_id": primary, "deny": golden(65), "allow": golden(m), "clear": golden(clear_rain)}
assert g["deny"]["status"] == "HAZARD_ACTIVE" and g["deny"]["auth"] == "DISPATCH_DENIED"
assert g["allow"]["auth"] == "DISPATCH_AUTHORIZED"
assert g["clear"]["status"] == "CLEAR" and g["clear"]["auth"] == "DISPATCH_DENIED"
json.dump(g, open(os.path.join(out, "golden.json"), "w"), indent=1)
print(len(cases))
PYEOF

FX="$TMP/fx"
if ! NCASES="$(python3 -I "$TMP/gen.py" fixtures "$REPO" "$FX" "$SINK" 2>"$TMP/gen.err")"; then
  die "fixture generation failed" "$(cat "$TMP/gen.err")"
fi
printf '  generated %s Cedar contexts + golden values from compute.py\n' "$NCASES"
GOLD="$FX/golden.json"

cat > "$TMP/entities.json" <<EOF
[
  {"uid": {"type": "HydroSentry::Role", "id": "AutomatedSentinel"}, "attrs": {}, "parents": []},
  {"uid": {"type": "HydroSentry::UrbanSink", "id": "$SINK"}, "attrs": {}, "parents": []}
]
EOF

N_ALLOW=0; N_DENY=0
while IFS="$(printf '\t')" read -r label ctxfile expect; do
  rc=0
  out="$(cedar authorize \
      --policies policies/hydrosentry.cedar \
      --schema policies/hydrosentry.cedarschema \
      --entities "$TMP/entities.json" \
      --principal 'HydroSentry::Role::"AutomatedSentinel"' \
      --action 'HydroSentry::Action::"DispatchEmergencyPump"' \
      --resource "HydroSentry::UrbanSink::\"$SINK\"" \
      --context "$ctxfile" 2>&1)" || rc=$?
  case "$rc" in
    0) got=ALLOW; N_ALLOW=$((N_ALLOW + 1)) ;;
    2) got=DENY;  N_DENY=$((N_DENY + 1)) ;;
    *) fail "B: $label - cedar error rc=$rc" "$out"; continue ;;   # rc 1 is always a failure
  esac
  # exit code, printed decision, and mock evaluator must all agree.
  # cedar-policy-cli 4.x prints a blank line before the decision, so compare
  # against the first non-blank line of output.
  decision="$(printf '%s\n' "$out" | sed -n '/[^[:space:]]/{p;q;}')"
  case "$decision" in
    "$got"*) : ;;
    *) fail "B: $label - rc=$rc but output was not '$got'" "$out"; continue ;;
  esac
  if [ "$got" = "$expect" ]; then pass "B: $label -> cedar $got == mock $expect"
  else fail "B: $label - cedar=$got mock=$expect" "ctx=$(cat "$ctxfile")"; fi
done < "$FX/cases.tsv"

check_eq "B: matrix exercised an ALLOW (rc 0) fixture" "yes" "$([ "$N_ALLOW" -gt 0 ] && echo yes || echo no)"
check_eq "B: matrix exercised a DENY (rc 2) fixture"  "yes" "$([ "$N_DENY"  -gt 0 ] && echo yes || echo no)"

# ============================================================================
# C. Emulator + sam local
# ============================================================================
section "C. Emulator and sam local start-api"

if docker network inspect "$NET" >/dev/null 2>&1; then
  NET_CREATED=1                       # stale from an earlier run; we own it
else
  docker network create "$NET" >/dev/null || die "cannot create docker network $NET"
  NET_CREATED=1
fi

if [ "$EXTERNAL_EMU" = 1 ]; then
  LAMBDA_ENDPOINT="${EMULATOR_LAMBDA_ENDPOINT:-http://host.docker.internal:4566}"
  printf '  using external emulator %s (lambda sees %s)\n' "$EMULATOR_ENDPOINT" "$LAMBDA_ENDPOINT"
else
  docker rm -f "$EMU_NAME" >/dev/null 2>&1 || true
  EMU_STARTED=1
  docker run -d --name "$EMU_NAME" --network "$NET" -p 127.0.0.1:4566:4566 \
    -e "SERVICES=dynamodb,events,sns,sqs" \
    -e "LOCALSTACK_AUTH_TOKEN=${LOCALSTACK_AUTH_TOKEN}" \
    "$LOCALSTACK_IMAGE" >/dev/null || die "cannot start emulator container"
  LAMBDA_ENDPOINT="http://${EMU_NAME}:4566"
fi

emu_ready() {
  curl -s --max-time 3 "$EMULATOR_ENDPOINT/_localstack/health" 2>/dev/null |
    jq -e '[.services.dynamodb,.services.events,.services.sns,.services.sqs]
           | all(. == "available" or . == "running")' >/dev/null 2>&1
}
wait_until "$EMU_DEADLINE_S" 2 emu_ready || die "emulator not healthy within ${EMU_DEADLINE_S}s" "$(docker logs --tail 15 "$EMU_NAME" 2>&1 || true)"
pass "C: emulator healthy"

# DynamoDB table (+TTL on expires_at), mirroring template.yaml
awsl dynamodb create-table --table-name "$TABLE_NAME" \
  --attribute-definitions AttributeName=sink_id,AttributeType=S \
  --key-schema AttributeName=sink_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST >/dev/null || die "create-table failed"
awsl dynamodb update-time-to-live --table-name "$TABLE_NAME" \
  --time-to-live-specification Enabled=true,AttributeName=expires_at >/dev/null || die "update-time-to-live failed"
check_eq "C: table TTL enabled on expires_at" "ENABLED expires_at" \
  "$(awsl dynamodb describe-time-to-live --table-name "$TABLE_NAME" --query 'TimeToLiveDescription.[TimeToLiveStatus,AttributeName]' --output text | sed 's/[[:space:]]\{1,\}/ /')"

# Bus, SNS topic -> SQS capture queue, rule (pattern extracted from template)
awsl events create-event-bus --name "$BUS_NAME" >/dev/null || die "create-event-bus failed"
TOPIC_ARN="$(awsl sns create-topic --name "$TOPIC_NAME" --query TopicArn --output text)" || die "create-topic failed"
QUEUE_URL="$(awsl sqs create-queue --queue-name "$QUEUE_NAME" --query QueueUrl --output text)" || die "create-queue failed"
QUEUE_ARN="$(awsl sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text)" || die "queue arn failed"
cat > "$TMP/qpolicy.json" <<EOF
{"Policy": "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"sns.amazonaws.com\"},\"Action\":\"sqs:SendMessage\",\"Resource\":\"$QUEUE_ARN\",\"Condition\":{\"ArnEquals\":{\"aws:SourceArn\":\"$TOPIC_ARN\"}}}]}"}
EOF
awsl sqs set-queue-attributes --queue-url "$QUEUE_URL" --attributes "file://$TMP/qpolicy.json" >/dev/null || die "queue policy failed"
awsl sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs --notification-endpoint "$QUEUE_ARN" >/dev/null || die "sns subscribe failed"

PATTERN="$(python3 -I "$TMP/gen.py" pattern template.yaml)" || die "cannot extract EventPattern from template.yaml"
check_jq "C: EventPattern from template has source + detail-type" "$PATTERN" \
  '.source == ["hydrosentry.engine"] and .["detail-type"] == ["EmergencyDispatchAuthorized"]'
awsl events put-rule --name "$RULE_NAME" --event-bus-name "$BUS_NAME" --event-pattern "$PATTERN" >/dev/null || die "put-rule failed"
awsl events put-targets --rule "$RULE_NAME" --event-bus-name "$BUS_NAME" \
  --targets "Id=SNSTarget,Arn=$TOPIC_ARN" >/dev/null || die "put-targets failed"

# sam build into the temp dir (no repo pollution). Use a container build when
# python3.12 is not on PATH.
BUILD_FLAGS=""
command -v python3.12 >/dev/null 2>&1 || BUILD_FLAGS="--use-container"
printf '  sam build %s\n' "$BUILD_FLAGS"
# shellcheck disable=SC2086
if ! sam build --template-file template.yaml --build-dir "$TMP/build" $BUILD_FLAGS >"$TMP/build.log" 2>&1; then
  die "sam build failed" "$(tail -10 "$TMP/build.log")"
fi

# Repo env.json hardcodes host.docker.internal and would override the
# parameter; generate one pointing at the endpoint Lambda can actually reach.
cat > "$TMP/env.json" <<EOF
{"ComputeFunction": {"ENVIRONMENT": "LOCAL", "DYNAMODB_TABLE_NAME": "$TABLE_NAME", "EVENT_BUS_NAME": "$BUS_NAME", "AWS_ENDPOINT_URL": "$LAMBDA_ENDPOINT"}}
EOF

set -m                                  # own process group for sam
sam local start-api --template "$TMP/build/template.yaml" \
  --host 127.0.0.1 --port "$PORT" \
  --docker-network "$NET" \
  --env-vars "$TMP/env.json" \
  --parameter-overrides "LocalEndpointUrl=$LAMBDA_ENDPOINT" \
  --warm-containers EAGER >"$TMP/sam.log" 2>&1 &
SAM_PID=$!
set +m

BASE="http://127.0.0.1:${PORT}"
api_up() {
  _c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$BASE/hazards/active" 2>/dev/null)" || true
  [ -n "$_c" ] && [ "$_c" != "000" ]
}
printf '  waiting for sam local (deadline %ss)\n' "$API_DEADLINE_S"
wait_until "$API_DEADLINE_S" 2 api_up || die "sam local not answering within ${API_DEADLINE_S}s" "$(tail -10 "$TMP/sam.log")"
pass "C: sam local answering on :$PORT"

# ============================================================================
# D. HTTP contract + determinism
# ============================================================================
section "D. POST /telemetry/rainfall"

LAT="$TMP/latency.txt"; : > "$LAT"
# post RAIN OUTFILE  -> logs curl time_total, sets HTTP_CODE
post() {
  _r="$(curl -s --max-time 30 -o "$2" -w '%{http_code} %{time_total}' \
        -X POST "$BASE/telemetry/rainfall" -H 'Content-Type: application/json' \
        -d "{\"sink_id\":\"$SINK\",\"rainfall_mm_hr\":$1}")" || _r="000 0"
  HTTP_CODE="${_r% *}"
  printf '  POST %s @ %s mm/hr -> HTTP %s, time_total=%ss\n' "$SINK" "$1" "$HTTP_CODE" "${_r#* }"
  printf '%s\n' "${_r#* }" >> "$LAT"
}

CONTRACT_KEYS='["cedar_authorization","depth_mm","required_pump_hp","sink_id","status","tts_min"]'
g() { jq -r "$1" "$GOLD"; }

# D1: 65 mm/hr -> hazard active but below the 350 mm Cedar threshold
R_DENY="$(g .deny.rain)"; post "$R_DENY" "$TMP/r_deny.json"
BODY="$(cat "$TMP/r_deny.json")"
check_eq "D1: HTTP 200" "200" "$HTTP_CODE"
check_jq "D1: response has exactly the frozen contract keys" "$BODY" "keys == $CONTRACT_KEYS"
check_jq "D1: status == HAZARD_ACTIVE" "$BODY" '.status == "HAZARD_ACTIVE"'
check_jq "D1: depth_mm == golden $(g .deny.depth_mm)" "$BODY" ".depth_mm == $(g .deny.depth_mm)"
check_jq "D1: tts_min == golden $(g .deny.tts_min)" "$BODY" ".tts_min == $(g .deny.tts_min)"
check_jq "D1: required_pump_hp == golden $(g .deny.hp)" "$BODY" ".required_pump_hp == $(g .deny.hp)"
check_jq "D1: cedar_authorization == DISPATCH_DENIED" "$BODY" '.cedar_authorization == "DISPATCH_DENIED"'

# D2: lowest integer rainfall that Cedar authorizes (computed, not typed)
R_ALLOW="$(g .allow.rain)"; post "$R_ALLOW" "$TMP/r_allow1.json"
BODY="$(cat "$TMP/r_allow1.json")"
check_eq "D2: HTTP 200" "200" "$HTTP_CODE"
check_jq "D2: response has exactly the frozen contract keys" "$BODY" "keys == $CONTRACT_KEYS"
check_jq "D2: sink_id echoed" "$BODY" ".sink_id == \"$SINK\""
check_jq "D2: status == HAZARD_ACTIVE" "$BODY" '.status == "HAZARD_ACTIVE"'
check_jq "D2: cedar_authorization == DISPATCH_AUTHORIZED" "$BODY" '.cedar_authorization == "DISPATCH_AUTHORIZED"'
check_jq "D2: depth_mm == golden $(g .allow.depth_mm)" "$BODY" ".depth_mm == $(g .allow.depth_mm)"
check_jq "D2: tts_min == golden $(g .allow.tts_min)" "$BODY" ".tts_min == $(g .allow.tts_min)"
check_jq "D2: required_pump_hp == golden $(g .allow.hp)" "$BODY" ".required_pump_hp == $(g .allow.hp)"

# D3: determinism - repeat identical call, diff with timestamps stripped
post "$R_ALLOW" "$TMP/r_allow2.json"
for n in 1 2; do jq -S 'del(.. | .timestamp?, .ts?)' "$TMP/r_allow$n.json" > "$TMP/n$n.json" 2>/dev/null || cp "$TMP/r_allow$n.json" "$TMP/n$n.json"; done
if diff -u "$TMP/n1.json" "$TMP/n2.json" >"$TMP/diff.txt" 2>&1; then
  pass "D3: repeated call returns identical response (diff empty)"
else
  fail "D3: repeated call differs" "$(head -10 "$TMP/diff.txt")"
fi

# D4: below drainage -> CLEAR, denied
R_CLEAR="$(g .clear.rain)"; post "$R_CLEAR" "$TMP/r_clear.json"
BODY="$(cat "$TMP/r_clear.json")"
check_jq "D4: ${R_CLEAR} mm/hr -> CLEAR + DISPATCH_DENIED" "$BODY" '.status == "CLEAR" and .cedar_authorization == "DISPATCH_DENIED" and .depth_mm == 0'

# D5: input validation
_c="$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' -X POST "$BASE/telemetry/rainfall" \
      -H 'Content-Type: application/json' -d '{"sink_id":"NOPE","rainfall_mm_hr":65}')" || _c=000
check_eq "D5: unknown sink_id -> HTTP 400" "400" "$_c"

# The final state for $SINK is the CLEAR call; re-post the authorizing rain so
# E asserts against a known, authorized state.
post "$R_ALLOW" "$TMP/r_allow3.json"

# ============================================================================
# E. Backend state: DynamoDB, expires_at filter, EventBridge -> SNS -> SQS
# ============================================================================
section "E. DynamoDB and event pipeline"

ITEM="$(awsl dynamodb get-item --table-name "$TABLE_NAME" --key "{\"sink_id\":{\"S\":\"$SINK\"}}" --output json)" || ITEM="{}"
NOW="$(date +%s)"
check_jq "E1: DynamoDB item has status == HAZARD_ACTIVE" "$ITEM" '.Item.status.S == "HAZARD_ACTIVE"'
check_jq "E1: DynamoDB item has expires_at in the future" "$ITEM" "(.Item.expires_at.N | tonumber) > $NOW"
check_jq "E1: DynamoDB depth_mm == golden $(g .allow.depth_mm)" "$ITEM" "(.Item.depth_mm.N | tonumber) == $(g .allow.depth_mm)"

# expires_at filter: seed an already-expired ACTIVE item; GET must hide it
# (TTL deletion is lazy, so the read path has to filter).
awsl dynamodb put-item --table-name "$TABLE_NAME" --item "{
  \"sink_id\":{\"S\":\"DELSNK002\"},\"status\":{\"S\":\"HAZARD_ACTIVE\"},
  \"depth_mm\":{\"N\":\"350\"},\"tts_min\":{\"N\":\"10\"},\"required_pump_hp\":{\"N\":\"1\"},
  \"cedar_authorization\":{\"S\":\"DISPATCH_AUTHORIZED\"},\"expires_at\":{\"N\":\"$((NOW - 3600))\"}}" >/dev/null \
  || fail "E1b: could not seed expired item"
_c="$(curl -s --max-time 30 -o "$TMP/active.json" -w '%{http_code} %{time_total}' "$BASE/hazards/active")" || _c="000 0"
printf '  GET /hazards/active -> HTTP %s, time_total=%ss\n' "${_c% *}" "${_c#* }"
printf '%s\n' "${_c#* }" >> "$LAT"
BODY="$(cat "$TMP/active.json")"
check_jq "E1b: GET /hazards/active lists the live sink" "$BODY" ".hazards | map(.sink_id) | index(\"$SINK\") != null"
check_jq "E1b: GET /hazards/active hides the expired item (expires_at filter)" "$BODY" '.hazards | map(.sink_id) | index("DELSNK002") == null'

# SQS capture: poll until >=2 dispatch events (D2 + D3 repeat + final) or deadline
EVENTS="$TMP/events.jsonl"; : > "$EVENTS"
sqs_enough() {
  _m="$(awsl sqs receive-message --queue-url "$QUEUE_URL" --max-number-of-messages 10 \
        --wait-time-seconds 2 --output json 2>/dev/null)" || _m=""
  [ -n "$_m" ] && printf '%s' "$_m" | jq -c '.Messages[]?.Body
      | fromjson | (try (.Message | fromjson) catch .)' >> "$EVENTS" 2>/dev/null
  [ "$(wc -l < "$EVENTS" | tr -d " ")" -ge 3 ]
}
wait_until "$SQS_DEADLINE_S" 1 sqs_enough || true
printf '  captured %s event(s) from SQS\n' "$(wc -l < "$EVENTS" | tr -d ' ')"

A_D="$(g .allow.depth_mm)"; A_T="$(g .allow.tts_min)"
ev() { jq -s -e "$1" "$EVENTS" >/dev/null 2>&1; }
OK='.source == "hydrosentry.engine" and .["detail-type"] == "EmergencyDispatchAuthorized"'
if ev "[.[] | select($OK and .detail.sink_id == \"$SINK\" and .detail.depth_mm == $A_D and .detail.tts_min == $A_T)] | length >= 1"
then pass "E2: SQS has event source=hydrosentry.engine, detail-type=EmergencyDispatchAuthorized, sink_id/depth_mm=$A_D/tts_min=$A_T match"
else fail "E2: no matching dispatch event in SQS" "$(head -c 400 "$EVENTS")"; fi
if ev "[.[] | select(.detail.depth_mm == $(g .deny.depth_mm) and .detail.tts_min == $(g .deny.tts_min))] | length == 0"
then pass "E3: denied call (${R_DENY} mm/hr) emitted no dispatch event"
else fail "E3: denied call leaked a dispatch event"; fi
if ev "[.[] | select(.detail.tts_min == null)] | length == 0"
then pass "E3b: no CLEAR-state event emitted"
else fail "E3b: unexpected event for CLEAR state"; fi

# -- Latency summary (measured through sam local + LocalStack, NOT AWS) ------
if [ -s "$LAT" ]; then
  awk '{ ms=$1*1000; s+=ms; if(NR==1||ms<mn)mn=ms; if(ms>mx)mx=ms }
       END { printf "\n  curl time_total over %d calls (sam local + emulator): min %.0f ms, avg %.0f ms, max %.0f ms\n", NR, mn, s/NR, mx }' "$LAT"
fi

# Summary + exit code are emitted by the EXIT trap (cleanup).
exit 0
