#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/state.env"
ensure_path

log()  { echo "$(date '+%H:%M:%S') [Phase2] $*" | tee -a "$LOG_FILE"; }
pass() { echo "  ✅ $*"; }
fail() { echo "  ❌ $*"; }

log "=== PHASE 2: Helm Chart Install + Splunk Standalone CR ==="

# ── Load Phase 1 state ────────────────────────────────────────
if [ ! -f "$STATE_DIR/phase1.state" ]; then
  fail "Phase 1 has not been run. Run phase1-check.sh first."
  exit 1
fi
source "$STATE_DIR/phase1.state"

# ── 2.1 Idempotency gate ──────────────────────────────────────
if [ "${SPLUNK_ALREADY_INSTALLED:-false}" = "true" ]; then
  pass "Splunk already deployed — skipping"
  echo "PHASE2_DONE=true" > "$STATE_DIR/phase2.state"
  echo "Skipped (already installed)" >> "$STATE_DIR/phase2.state"
  log "=== PHASE 2 SKIPPED (already installed) ==="
  exit 0
fi

# ── 2.2 Helm install (Splunk Operator) ───────────────────────
log "2.2 Running helm install (this may take 2-5 minutes)..."
$HELM upgrade --install "$SPLUNK_RELEASE" \
  splunk/splunk-enterprise \
  --namespace "$SPLUNK_NAMESPACE" \
  --version "$SPLUNK_VERSION" \
  --timeout 8m \
  --wait=false \
  2>&1 | tee -a "$LOG_FILE"

if [ ${PIPESTATUS[0]} -ne 0 ]; then
  fail "Helm install command failed — check logs: $LOG_FILE"
  exit 1
fi
pass "Helm install command submitted"

# ── 2.3 Create Splunk Standalone CR ──────────────────────────
log "2.3 Creating Splunk Standalone instance..."
cat <<EOF | $KUBECTL apply -f - 2>&1 | tee -a "$LOG_FILE"
apiVersion: enterprise.splunk.com/v4
kind: Standalone
metadata:
  name: ${SPLUNK_RELEASE}
  namespace: ${SPLUNK_NAMESPACE}
spec:
  etcVolumeStorageConfig:
    storageCapacity: 5Gi
  varVolumeStorageConfig:
    storageCapacity: 20Gi
EOF
pass "Splunk Standalone CR created"

# ── 2.4 Wait for pods ────────────────────────────────────────
log "2.4 Waiting for Splunk pods (max 15 min)..."
MAX_WAIT=90
COUNT=0
while [ $COUNT -lt $MAX_WAIT ]; do
  SPLUNK_POD=$($KUBECTL get pods -n "$SPLUNK_NAMESPACE" --no-headers 2>/dev/null | \
    grep "standalone" | grep "1/1" | grep "Running" | awk '{print $1}' || true)
  
  if [ -n "$SPLUNK_POD" ]; then
    pass "Splunk pod is Running: $SPLUNK_POD"
    break
  fi
  
  RUNNING=$($KUBECTL get pods -n "$SPLUNK_NAMESPACE" --no-headers 2>/dev/null | \
    grep -c "Running" || true)
  TOTAL=$($KUBECTL get pods -n "$SPLUNK_NAMESPACE" --no-headers 2>/dev/null | wc -l || true)
  log "  Waiting... (attempt $((COUNT+1))/$MAX_WAIT, $RUNNING/$TOTAL pods ready)"
  
  if [ $COUNT -eq 60 ]; then
    log "  Current status:"
    $KUBECTL get pods -n "$SPLUNK_NAMESPACE" 2>&1 | tee -a "$LOG_FILE"
  fi
  
  COUNT=$((COUNT+1))
  sleep 10
done

if [ -z "$SPLUNK_POD" ]; then
  fail "Splunk pod did not reach Running state"
  $KUBECTL get pods -n "$SPLUNK_NAMESPACE"
  exit 1
fi

# ── 2.5 Retrieve actual admin password from secret ──────────
log "2.5 Retrieving admin password from Kubernetes secret..."
ACTUAL_PASSWORD=$($KUBECTL get secret "${SPLUNK_RELEASE}-standalone-secret-v1" \
  -n "$SPLUNK_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)

if [ -n "$ACTUAL_PASSWORD" ]; then
  SPLUNK_PASSWORD="$ACTUAL_PASSWORD"
  echo "SPLUNK_PASSWORD=${SPLUNK_PASSWORD}" > "$STATE_DIR/splunk-creds.env"
  chmod 600 "$STATE_DIR/splunk-creds.env"
  pass "Password retrieved from secret"
else
  # Fallback: generate and store a password for reference
  SPLUNK_PASSWORD=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 16)
  echo "SPLUNK_PASSWORD=${SPLUNK_PASSWORD}" > "$STATE_DIR/splunk-creds.env"
  chmod 600 "$STATE_DIR/splunk-creds.env"
  warn "Could not retrieve password from secret; stored generated password"
fi

# ── 2.6 Get ClusterIP for internal access ───────────────────
log "2.6 Getting Splunk service ClusterIP..."
CLUSTER_IP=$($KUBECTL get svc "${SPLUNK_RELEASE}-standalone-service" \
  -n "$SPLUNK_NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)

if [ -n "$CLUSTER_IP" ]; then
  echo "SPLUNK_CLUSTER_IP=${CLUSTER_IP}" >> "$STATE_DIR/splunk-creds.env"
  echo "SPLUNK_HEC_URL=http://${CLUSTER_IP}:8088/services/collector/event" >> "$STATE_DIR/splunk-creds.env"
  pass "ClusterIP: $CLUSTER_IP"
else
  warn "Could not get ClusterIP; will rely on service DNS"
fi

echo "PHASE2_DONE=true" > "$STATE_DIR/phase2.state"
echo "SPLUNK_RELEASE_STATUS=deployed" >> "$STATE_DIR/phase2.state"

log "=== PHASE 2 COMPLETE ==="
echo ""
echo "──────────────────────────────────────────────"
echo " Phase 2 Summary:"
echo "  Release   : $SPLUNK_RELEASE"
echo "  Namespace : $SPLUNK_NAMESPACE"
echo "  Password  : ${SPLUNK_PASSWORD}"
echo "  ClusterIP : ${CLUSTER_IP:-N/A}"
echo "  Creds at  : $STATE_DIR/splunk-creds.env"
echo "──────────────────────────────────────────────"
echo " ✅ Ready for Phase 3"
