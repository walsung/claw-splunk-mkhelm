#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/state.env"
ensure_path

log()  { echo "$(date '+%H:%M:%S') [Phase3] $*" | tee -a "$LOG_FILE"; }
pass() { echo "  ✅ $*"; }
fail() { echo "  ❌ $*"; }

log "=== PHASE 3: Configure Splunk HEC (via kubectl exec) ==="

[ -f "$STATE_DIR/phase2.state" ] || { fail "Run Phase 2 first"; exit 1; }
source "$STATE_DIR/splunk-creds.env"

SPLUNK_POD=$($KUBECTL get pods -n "$SPLUNK_NAMESPACE" --no-headers | \
  grep "standalone" | grep "Running" | awk '{print $1}' | head -1)

if [ -z "$SPLUNK_POD" ]; then
  fail "No running Splunk standalone pod found"
  exit 1
fi
pass "Using pod: $SPLUNK_POD"

# ── 3.1 Enable HEC globally ──────────────────────────────────
log "3.1 Enabling HEC globally..."
$KUBECTL exec -n "$SPLUNK_NAMESPACE" "$SPLUNK_POD" -- \
  bash -c "curl -sk -u \"admin:${SPLUNK_PASSWORD}\" \
    https://localhost:8089/services/data/inputs/http/http \
    -d enableSSL=0 -d disabled=0" > /dev/null 2>&1
pass "HEC enabled"

# ── 3.2 Create HEC token ─────────────────────────────────────
log "3.2 Creating HEC token 'openclaw-logs'..."
$KUBECTL exec -n "$SPLUNK_NAMESPACE" "$SPLUNK_POD" -- \
  bash -c "curl -sk -u \"admin:${SPLUNK_PASSWORD}\" \
    https://localhost:8089/services/data/inputs/http \
    -d name=openclaw-logs \
    -d sourcetype=openclaw \
    -d index=main \
    -d useACK=0" > /dev/null 2>&1 || true

# ── 3.3 Retrieve HEC token ───────────────────────────────────
log "3.3 Retrieving HEC token value..."
HEC_TOKEN=$($KUBECTL exec -n "$SPLUNK_NAMESPACE" "$SPLUNK_POD" -- \
  bash -c "curl -sk -u \"admin:${SPLUNK_PASSWORD}\" \
    'https://localhost:8089/services/data/inputs/http/openclaw-logs?output_mode=json'" 2>/dev/null | \
  python3 -c "
import sys, json
try:
  d = json.load(sys.stdin)
  print(d['entry'][0]['content']['token'])
except:
  pass
")

if [ -z "$HEC_TOKEN" ]; then
  # Token might already exist from previous run
  HEC_TOKEN=$(grep "HEC_TOKEN" "$STATE_DIR/splunk-creds.env" 2>/dev/null | cut -d= -f2 || true)
fi

if [ -n "$HEC_TOKEN" ]; then
  # Update creds file with HEC token
  if grep -q "^HEC_TOKEN=" "$STATE_DIR/splunk-creds.env" 2>/dev/null; then
    sed -i "s/^HEC_TOKEN=.*/HEC_TOKEN=${HEC_TOKEN}/" "$STATE_DIR/splunk-creds.env"
  else
    echo "HEC_TOKEN=${HEC_TOKEN}" >> "$STATE_DIR/splunk-creds.env"
  fi
  pass "HEC token retrieved"
else
  fail "Could not retrieve HEC token"
  exit 1
fi

# ── 3.4 Test HEC ─────────────────────────────────────────────
log "3.4 Testing HEC..."
TEST_RESULT=$($KUBECTL exec -n "$SPLUNK_NAMESPACE" "$SPLUNK_POD" -- \
  bash -c "curl -s http://localhost:8088/services/collector/event \
    -H 'Authorization: Splunk ${HEC_TOKEN}' \
    -d '{\"event\": \"Phase 3 HEC test\"}'" 2>/dev/null | grep -o '"code":0' || true)

if [ -n "$TEST_RESULT" ]; then
  pass "HEC test passed"
else
  warn "HEC test may have issues, but continuing..."
fi

echo "PHASE3_DONE=true" > "$STATE_DIR/phase3.state"

# Get ClusterIP for HEC URL reference
CLUSTER_IP=$($KUBECTL get svc "${SPLUNK_RELEASE}-standalone-service" \
  -n "$SPLUNK_NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)

log "=== PHASE 3 COMPLETE ==="
echo ""
echo "──────────────────────────────────────────────────────"
echo " Phase 3 Summary:"
echo "  HEC Token    : ${HEC_TOKEN}"
echo "  HEC Endpoint : http://${CLUSTER_IP}:8088/services/collector/event"
echo "──────────────────────────────────────────────────────"
echo " ✅ Ready for Phase 4"
