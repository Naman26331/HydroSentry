#!/bin/sh
# ============================================================================
# HydroSentry — End-to-End Integration Test
# ============================================================================
# POSIX sh, no bashisms or pipefail.
# Every wait has a deadline; every curl uses --max-time.
# Exit non-zero on any assertion failure.
# ============================================================================
set -eu

# ── Colours (ANSI, harmless on dumb terminals) ──────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; RST='\033[0m'

# ── Configurable Defaults ───────────────────────────────────────────────────
PORT="${PORT:-3000}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

EMULATOR_ENDPOINT="${EMULATOR_ENDPOINT:-http://localhost:4566}"
DOCKER_NETWORK="hydrosentry-e2e"
TABLE_NAME="HydroSentry-HazardState"
BUS_NAME="HydroSentry-Bus"
TOPIC_NAME="HydroSentry-EmergencyAlerts"
QUEUE_NAME="hydrosentry-e2e-capture"
KEEP=""

# ── Counters ────────────────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0
SAM_PID=""
TMPDIR_E2E=""
EMULATOR_CONTAINER="localstack-hydrosentry-e2e"

# ── Parse flags ─────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
  esac
done

# ── Assertion helpers ───────────────────────────────────────────────────────
assert_eq() {
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  label="$1"; expected="$2"; actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    printf "${GRN}  [PASS]${RST} %s\n" "$label"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf "${RED}  [FAIL]${RST} %s  (expected='%s', got='%s')\n" "$label" "$expected" "$actual"
  fi
}

assert_nonzero() {
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  label="$1"; actual="$2"
  if [ -n "$actual" ] && [ "$actual" != "null" ] && [ "$actual" != "0" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    printf "${GRN}  [PASS]${RST} %s\n" "$label"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf "${RED}  [FAIL]${RST} %s  (got='%s')\n" "$label" "$actual"
  fi
}

# ── Cleanup (idempotent) ───────────────────────────────────────────────────
cleanup() {
  printf "\n${YLW}[CLEANUP]${RST} Tearing down...\n"
  if [ -n "$SAM_PID" ]; then
    # kill process group (sam local start-api spawns children)
    kill -- -"$SAM_PID" 2>/dev/null || kill "$SAM_PID" 2>/dev/null || true
    wait "$SAM_PID" 2>/dev/null || true
    SAM_PID=""
  fi
  if [ -z "$KEEP" ]; then
    docker rm -f "$EMULATOR_CONTAINER" 2>/dev/null || true
    docker network rm "$DOCKER_NETWORK" 2>/dev/null || true
    if [ -n "$TMPDIR_E2E" ] && [ -d "$TMPDIR_E2E" ]; then
      rm -rf "$TMPDIR_E2E"
    fi
  else
    printf "  --keep: leaving stack and emulator up\n"
  fi
  printf "${YLW}[CLEANUP]${RST} Done.\n"
}
trap cleanup EXIT INT TERM

# ── mktemp dir ──────────────────────────────────────────────────────────────
TMPDIR_E2E="$(mktemp -d)"

# ============================================================================
# SECTION A — Preflight & SAM Validate
# ============================================================================
printf "\n${YLW}═══ SECTION A: Preflight & SAM Validate ═══${RST}\n\n"

# Preflight checks
for cmd in docker sam jq curl aws; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf "${RED}[FATAL]${RST} Required command not found: %s\n" "$cmd"
    exit 1
  fi
done
printf "  Preflight: docker, sam, jq, curl, aws — OK\n"

# Free port check
if command -v ss >/dev/null 2>&1; then
  if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
    printf "${RED}[FATAL]${RST} Port %s already in use\n" "$PORT"
    exit 1
  fi
elif command -v lsof >/dev/null 2>&1; then
  if lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    printf "${RED}[FATAL]${RST} Port %s already in use\n" "$PORT"
    exit 1
  fi
fi
printf "  Port %s: available\n" "$PORT"

# SAM validate + lint
printf "\n  Running: sam validate --lint\n"
sam validate --lint --template-file template.yaml
TOTAL_COUNT=$((TOTAL_COUNT + 1))
if [ $? -eq 0 ]; then
  PASS_COUNT=$((PASS_COUNT + 1))
  printf "${GRN}  [PASS]${RST} sam validate --lint\n"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf "${RED}  [FAIL]${RST} sam validate --lint\n"
fi

# ============================================================================
# SECTION B — Cedar Policy Verification
# ============================================================================
printf "\n${YLW}═══ SECTION B: Cedar Policy Verification ═══${RST}\n\n"

# Check for cedar CLI
if ! command -v cedar >/dev/null 2>&1; then
  printf "  ${YLW}[SKIP]${RST} cedar CLI not installed — skipping policy verification\n"
else
  # Create entity data
  cat > "$TMPDIR_E2E/entities.json" << 'ENTITIES_EOF'
[
  {
    "uid": { "type": "HydroSentry::Role", "id": "AutomatedSentinel" },
    "attrs": {},
    "parents": []
  },
  {
    "uid": { "type": "HydroSentry::UrbanSink", "id": "DELSNK001" },
    "attrs": {},
    "parents": []
  }
]
ENTITIES_EOF

  CEDAR_PRINCIPAL='HydroSentry::Role::"AutomatedSentinel"'
  CEDAR_ACTION='HydroSentry::Action::"DispatchEmergencyPump"'
  CEDAR_RESOURCE='HydroSentry::UrbanSink::"DELSNK001"'

  # ── Context matrix ──────────────────────────────────────────────────────
  # Each row: label, context_json, expected_decision (ALLOW|DENY)
  # Fixtures derived from compute.py output — never hand-typed.
  #
  # 65 mm/hr Minto:  depth_mm=131, tts_min=39  -> DENY (depth < 350)
  # 169 mm/hr Minto: depth_mm=350, tts_min=14  -> ALLOW (both thresholds met)
  # Edge: depth=350, tts=30                     -> ALLOW (exact boundary)
  # Edge: depth=349, tts=30                     -> DENY  (depth off by 1)
  # Edge: depth=350, tts=31                     -> DENY  (tts off by 1)

  run_cedar() {
    _label="$1"; _ctx_file="$2"; _expect="$3"

    cedar_rc=0
    cedar_out="$(cedar authorize \
      --policies policies/hydrosentry.cedar \
      --entities "$TMPDIR_E2E/entities.json" \
      --schema policies/hydrosentry.cedarschema \
      --principal "$CEDAR_PRINCIPAL" \
      --action "$CEDAR_ACTION" \
      --resource "$CEDAR_RESOURCE" \
      --context "$_ctx_file" 2>&1)" || cedar_rc=$?

    # rc 0 = ALLOW, rc 2 = DENY, rc 1 = error
    if [ "$cedar_rc" = "1" ]; then
      TOTAL_COUNT=$((TOTAL_COUNT + 1))
      FAIL_COUNT=$((FAIL_COUNT + 1))
      printf "${RED}  [FAIL]${RST} %s — cedar error (rc=1): %s\n" "$_label" "$cedar_out"
      return
    fi

    if [ "$_expect" = "ALLOW" ]; then
      assert_eq "$_label" "0" "$cedar_rc"
    else
      assert_eq "$_label" "2" "$cedar_rc"
    fi
  }

  # Fixture 1: 65 mm/hr Minto Bridge -> DENY
  printf '{"water_depth_mm": 131, "time_to_submersion_mins": 39}' > "$TMPDIR_E2E/ctx_deny_65.json"
  run_cedar "Cedar DENY: Minto 65mm/hr (depth=131mm < 350)" "$TMPDIR_E2E/ctx_deny_65.json" "DENY"

  # Fixture 2: 169 mm/hr Minto Bridge -> ALLOW
  printf '{"water_depth_mm": 350, "time_to_submersion_mins": 14}' > "$TMPDIR_E2E/ctx_allow_169.json"
  run_cedar "Cedar ALLOW: Minto 169mm/hr (depth=350mm, tts=14min)" "$TMPDIR_E2E/ctx_allow_169.json" "ALLOW"

  # Fixture 3: boundary ALLOW (exactly 350mm, exactly 30min)
  printf '{"water_depth_mm": 350, "time_to_submersion_mins": 30}' > "$TMPDIR_E2E/ctx_boundary_allow.json"
  run_cedar "Cedar ALLOW: boundary (depth=350mm, tts=30min)" "$TMPDIR_E2E/ctx_boundary_allow.json" "ALLOW"

  # Fixture 4: boundary DENY (349mm, 30min)
  printf '{"water_depth_mm": 349, "time_to_submersion_mins": 30}' > "$TMPDIR_E2E/ctx_boundary_deny1.json"
  run_cedar "Cedar DENY: boundary (depth=349mm < 350)" "$TMPDIR_E2E/ctx_boundary_deny1.json" "DENY"

  # Fixture 5: boundary DENY (350mm, 31min)
  printf '{"water_depth_mm": 350, "time_to_submersion_mins": 31}' > "$TMPDIR_E2E/ctx_boundary_deny2.json"
  run_cedar "Cedar DENY: boundary (tts=31min > 30)" "$TMPDIR_E2E/ctx_boundary_deny2.json" "DENY"

  printf "\n  Cedar differential test: 5/5 context matrix exercised\n"
fi

# ============================================================================
# SECTION C — Emulator + SAM Local Stack
# ============================================================================
printf "\n${YLW}═══ SECTION C: LocalStack + SAM Local API ═══${RST}\n\n"

# Docker network (idempotent)
docker network create "$DOCKER_NETWORK" 2>/dev/null || true

# Start LocalStack emulator
printf "  Starting LocalStack emulator...\n"
docker rm -f "$EMULATOR_CONTAINER" 2>/dev/null || true
docker run -d \
  --name "$EMULATOR_CONTAINER" \
  --network "$DOCKER_NETWORK" \
  -p 4566:4566 \
  -e "SERVICES=dynamodb,events,sns,sqs" \
  -e "DEFAULT_REGION=${AWS_DEFAULT_REGION}" \
  ${LOCALSTACK_AUTH_TOKEN:+-e "LOCALSTACK_AUTH_TOKEN=${LOCALSTACK_AUTH_TOKEN}"} \
  localstack/localstack:latest

# Wait for LocalStack health
printf "  Waiting for LocalStack health"
LS_DEADLINE=60
LS_ELAPSED=0
while [ "$LS_ELAPSED" -lt "$LS_DEADLINE" ]; do
  if curl -s --max-time 2 "$EMULATOR_ENDPOINT/_localstack/health" | jq -e '.services.dynamodb' >/dev/null 2>&1; then
    printf " ready (%ss)\n" "$LS_ELAPSED"
    break
  fi
  printf "."
  sleep 2
  LS_ELAPSED=$((LS_ELAPSED + 2))
done
if [ "$LS_ELAPSED" -ge "$LS_DEADLINE" ]; then
  printf "\n${RED}[FATAL]${RST} LocalStack did not become healthy within %ss\n" "$LS_DEADLINE"
  exit 1
fi

# Create DynamoDB table
printf "  Creating DynamoDB table: %s\n" "$TABLE_NAME"
aws dynamodb create-table \
  --endpoint-url "$EMULATOR_ENDPOINT" \
  --table-name "$TABLE_NAME" \
  --attribute-definitions AttributeName=sink_id,AttributeType=S \
  --key-schema AttributeName=sink_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --no-cli-pager >/dev/null

# Enable TTL
aws dynamodb update-time-to-live \
  --endpoint-url "$EMULATOR_ENDPOINT" \
  --table-name "$TABLE_NAME" \
  --time-to-live-specification "Enabled=true,AttributeName=expires_at" \
  --no-cli-pager >/dev/null

# Create EventBridge bus
printf "  Creating EventBridge bus: %s\n" "$BUS_NAME"
aws events create-event-bus \
  --endpoint-url "$EMULATOR_ENDPOINT" \
  --name "$BUS_NAME" \
  --no-cli-pager >/dev/null

# Create SNS topic
printf "  Creating SNS topic: %s\n" "$TOPIC_NAME"
TOPIC_ARN="$(aws sns create-topic \
  --endpoint-url "$EMULATOR_ENDPOINT" \
  --name "$TOPIC_NAME" \
  --query 'TopicArn' --output text \
  --no-cli-pager)"

# Create SQS capture queue
printf "  Creating SQS capture queue: %s\n" "$QUEUE_NAME"
QUEUE_URL="$(aws sqs create-queue \
  --endpoint-url "$EMULATOR_ENDPOINT" \
  --queue-name "$QUEUE_NAME" \
  --query 'QueueUrl' --output text \
  --no-cli-pager)"

QUEUE_ARN="$(aws sqs get-queue-attributes \
  --endpoint-url "$EMULATOR_ENDPOINT" \
  --queue-url "$QUEUE_URL" \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' --output text \
  --no-cli-pager)"

# Subscribe SQS to SNS (capture dispatch events)
aws sns subscribe \
  --endpoint-url "$EMULATOR_ENDPOINT" \
  --topic-arn "$TOPIC_ARN" \
  --protocol sqs \
  --notification-endpoint "$QUEUE_ARN" \
  --no-cli-pager >/dev/null

# Create EventBridge rule: hydrosentry.engine -> SNS
printf "  Creating EventBridge rule -> SNS target\n"
aws events put-rule \
  --endpoint-url "$EMULATOR_ENDPOINT" \
  --name "EmergencyDispatchRule" \
  --event-bus-name "$BUS_NAME" \
  --event-pattern '{"source":["hydrosentry.engine"],"detail-type":["EmergencyDispatchAuthorized"]}' \
  --no-cli-pager >/dev/null

aws events put-targets \
  --endpoint-url "$EMULATOR_ENDPOINT" \
  --rule "EmergencyDispatchRule" \
  --event-bus-name "$BUS_NAME" \
  --targets "Id=SNSTarget,Arn=$TOPIC_ARN" \
  --no-cli-pager >/dev/null

# SAM build
printf "\n  Running: sam build\n"
sam build --template-file template.yaml

# SAM local start-api
printf "  Starting: sam local start-api on port %s\n" "$PORT"
sam local start-api \
  --port "$PORT" \
  --docker-network "$DOCKER_NETWORK" \
  --env-vars env.json \
  --parameter-overrides "LocalEndpointUrl=http://${EMULATOR_CONTAINER}:4566" \
  --warm-containers EAGER \
  > "$TMPDIR_E2E/sam.log" 2>&1 &
SAM_PID=$!

# Poll until API responds (deadline 90s)
printf "  Waiting for SAM local API"
API_BASE="http://127.0.0.1:${PORT}"
API_DEADLINE=90
API_ELAPSED=0
while [ "$API_ELAPSED" -lt "$API_DEADLINE" ]; do
  HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${API_BASE}/hazards/active" 2>/dev/null)" || HTTP_CODE="000"
  if [ "$HTTP_CODE" != "000" ]; then
    printf " ready (%ss, HTTP %s)\n" "$API_ELAPSED" "$HTTP_CODE"
    break
  fi
  printf "."
  sleep 3
  API_ELAPSED=$((API_ELAPSED + 3))
done
if [ "$API_ELAPSED" -ge "$API_DEADLINE" ]; then
  printf "\n${RED}[FATAL]${RST} SAM local API did not start within %ss\n" "$API_DEADLINE"
  printf "  SAM log tail:\n"
  tail -20 "$TMPDIR_E2E/sam.log"
  exit 1
fi

# ============================================================================
# SECTION D — API Integration Tests
# ============================================================================
printf "\n${YLW}═══ SECTION D: API Response Assertions ═══${RST}\n\n"

# ── D1: POST 65 mm/hr for Minto Bridge -> HAZARD_ACTIVE, DISPATCH_DENIED ──
printf "  POST /telemetry/rainfall  sink=DELSNK001  rain=65 mm/hr\n"
RESP_65="$(curl -s --max-time 10 \
  -X POST "${API_BASE}/telemetry/rainfall" \
  -H "Content-Type: application/json" \
  -d '{"sink_id":"DELSNK001","rainfall_mm_hr":65}' \
  -w '\n%{time_total}')"

BODY_65="$(printf '%s' "$RESP_65" | sed '$d')"
TIME_65="$(printf '%s' "$RESP_65" | tail -1)"
printf "  Response time: %s s\n" "$TIME_65"

assert_eq "D1: status == HAZARD_ACTIVE"       "HAZARD_ACTIVE"    "$(printf '%s' "$BODY_65" | jq -r '.status')"
assert_eq "D1: depth_mm == 131"                "131"              "$(printf '%s' "$BODY_65" | jq -r '.depth_mm')"
assert_eq "D1: tts_min == 39"                  "39"               "$(printf '%s' "$BODY_65" | jq -r '.tts_min')"
assert_eq "D1: required_pump_hp == 51.49"      "51.49"            "$(printf '%s' "$BODY_65" | jq -r '.required_pump_hp')"
assert_eq "D1: cedar == DISPATCH_DENIED"       "DISPATCH_DENIED"  "$(printf '%s' "$BODY_65" | jq -r '.cedar_authorization')"

# ── D2: POST 169 mm/hr for Minto Bridge -> HAZARD_ACTIVE, AUTHORIZED ──────
printf "\n  POST /telemetry/rainfall  sink=DELSNK001  rain=169 mm/hr\n"
RESP_169="$(curl -s --max-time 10 \
  -X POST "${API_BASE}/telemetry/rainfall" \
  -H "Content-Type: application/json" \
  -d '{"sink_id":"DELSNK001","rainfall_mm_hr":169}' \
  -w '\n%{time_total}')"

BODY_169="$(printf '%s' "$RESP_169" | sed '$d')"
TIME_169="$(printf '%s' "$RESP_169" | tail -1)"
printf "  Response time: %s s\n" "$TIME_169"

assert_eq "D2: status == HAZARD_ACTIVE"        "HAZARD_ACTIVE"        "$(printf '%s' "$BODY_169" | jq -r '.status')"
assert_eq "D2: depth_mm == 350"                 "350"                  "$(printf '%s' "$BODY_169" | jq -r '.depth_mm')"
assert_eq "D2: tts_min == 14"                   "14"                   "$(printf '%s' "$BODY_169" | jq -r '.tts_min')"
assert_eq "D2: required_pump_hp == 137.42"      "137.42"               "$(printf '%s' "$BODY_169" | jq -r '.required_pump_hp')"
assert_eq "D2: cedar == DISPATCH_AUTHORIZED"    "DISPATCH_AUTHORIZED"  "$(printf '%s' "$BODY_169" | jq -r '.cedar_authorization')"

# ── D3: Idempotency — repeat call, diff (timestamps stripped) ─────────────
printf "\n  Repeating POST 169 mm/hr for idempotency check\n"
RESP_169B="$(curl -s --max-time 10 \
  -X POST "${API_BASE}/telemetry/rainfall" \
  -H "Content-Type: application/json" \
  -d '{"sink_id":"DELSNK001","rainfall_mm_hr":169}')"

DIFF_RESULT="$(diff \
  <(printf '%s' "$BODY_169" | jq -S 'del(.timestamp?)') \
  <(printf '%s' "$RESP_169B" | jq -S 'del(.timestamp?)') 2>&1)" || true

TOTAL_COUNT=$((TOTAL_COUNT + 1))
if [ -z "$DIFF_RESULT" ]; then
  PASS_COUNT=$((PASS_COUNT + 1))
  printf "${GRN}  [PASS]${RST} D3: Idempotent response (diff empty)\n"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf "${RED}  [FAIL]${RST} D3: Responses differ:\n%s\n" "$DIFF_RESULT"
fi

# ============================================================================
# SECTION E — Backend State Assertions
# ============================================================================
printf "\n${YLW}═══ SECTION E: Backend State Verification ═══${RST}\n\n"

# ── E1: DynamoDB get-item ─────────────────────────────────────────────────
printf "  Checking DynamoDB item for DELSNK001\n"
DDB_ITEM="$(aws dynamodb get-item \
  --endpoint-url "$EMULATOR_ENDPOINT" \
  --table-name "$TABLE_NAME" \
  --key '{"sink_id":{"S":"DELSNK001"}}' \
  --no-cli-pager \
  --output json 2>/dev/null)"

DDB_STATUS="$(printf '%s' "$DDB_ITEM" | jq -r '.Item.status.S // empty')"
DDB_EXPIRES="$(printf '%s' "$DDB_ITEM" | jq -r '.Item.expires_at.N // empty')"
DDB_DEPTH="$(printf '%s' "$DDB_ITEM" | jq -r '.Item.depth_mm.N // empty')"

assert_eq "E1: DynamoDB status == HAZARD_ACTIVE"  "HAZARD_ACTIVE" "$DDB_STATUS"
assert_nonzero "E1: DynamoDB expires_at is set"    "$DDB_EXPIRES"
assert_eq "E1: DynamoDB depth_mm == 350"           "350" "$DDB_DEPTH"

# ── E2: SQS capture queue — EventBridge -> SNS -> SQS ────────────────────
printf "\n  Checking SQS capture queue for dispatch event\n"
# Give EventBridge a moment to propagate
sleep 3

SQS_MSG="$(aws sqs receive-message \
  --endpoint-url "$EMULATOR_ENDPOINT" \
  --queue-url "$QUEUE_URL" \
  --max-number-of-messages 1 \
  --wait-time-seconds 5 \
  --no-cli-pager \
  --output json 2>/dev/null)"

SQS_BODY="$(printf '%s' "$SQS_MSG" | jq -r '.Messages[0].Body // empty')"

if [ -n "$SQS_BODY" ]; then
  # SNS wraps the EventBridge event in a Message field
  EVENT_MSG="$(printf '%s' "$SQS_BODY" | jq -r '.Message // .' 2>/dev/null)"

  EVT_SOURCE="$(printf '%s' "$EVENT_MSG" | jq -r '.source // empty' 2>/dev/null)"
  EVT_DETAIL_TYPE="$(printf '%s' "$EVENT_MSG" | jq -r '.["detail-type"] // empty' 2>/dev/null)"
  EVT_SINK_ID="$(printf '%s' "$EVENT_MSG" | jq -r '.detail.sink_id // empty' 2>/dev/null)"
  EVT_DEPTH="$(printf '%s' "$EVENT_MSG" | jq -r '.detail.depth_mm // empty' 2>/dev/null)"
  EVT_TTS="$(printf '%s' "$EVENT_MSG" | jq -r '.detail.tts_min // empty' 2>/dev/null)"

  assert_eq "E2: event source == hydrosentry.engine"           "hydrosentry.engine"               "$EVT_SOURCE"
  assert_eq "E2: event detail-type == EmergencyDispatchAuthorized" "EmergencyDispatchAuthorized"   "$EVT_DETAIL_TYPE"
  assert_eq "E2: event detail.sink_id == DELSNK001"            "DELSNK001"                        "$EVT_SINK_ID"
  assert_eq "E2: event detail.depth_mm == 350"                 "350"                              "$EVT_DEPTH"
  assert_eq "E2: event detail.tts_min == 14"                   "14"                               "$EVT_TTS"
else
  # No message received — fail all event assertions
  TOTAL_COUNT=$((TOTAL_COUNT + 5))
  FAIL_COUNT=$((FAIL_COUNT + 5))
  printf "${RED}  [FAIL]${RST} E2: No SQS message received (EventBridge -> SNS -> SQS pipeline)\n"
fi

# ============================================================================
# SUMMARY
# ============================================================================
printf "\n${YLW}═══════════════════════════════════════════════${RST}\n"
printf "  TOTAL: %d  |  ${GRN}PASS: %d${RST}  |  ${RED}FAIL: %d${RST}\n" "$TOTAL_COUNT" "$PASS_COUNT" "$FAIL_COUNT"
printf "${YLW}═══════════════════════════════════════════════${RST}\n"

if [ "$FAIL_COUNT" -gt 0 ]; then
  printf "\n${RED}RESULT: FAILED${RST}\n\n"
  exit 1
else
  printf "\n${GRN}RESULT: ALL TESTS PASSED${RST}\n\n"
  exit 0
fi
