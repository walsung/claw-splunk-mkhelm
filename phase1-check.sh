#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/state.env"
ensure_path

# ── Helpers ───────────────────────────────────────────────────
log()  { echo "$(date '+%H:%M:%S') [Phase1] $*" | tee -a "$LOG_FILE"; }
pass() { echo "  ✅ $*"; }
fail() { echo "  ❌ $*"; }
warn() { echo "  ⚠️  $*"; }

mkdir -p "$STATE_DIR"
log "=== PHASE 1: Pre-flight + Idempotency Check ==="

# ── 1.1 Check MicroK8s is running ────────────────────────────
log "1.1 Checking MicroK8s status..."
if $MK status 2>&1 | grep -q "microk8s is running"; then
  pass "MicroK8s is running"
else
  fail "MicroK8s is NOT running"
  log "ERROR: Run: microk8s start"
  exit 1
fi

# ── 1.2 Check required addons ─────────────────────────────────
log "1.2 Checking required addons (helm3, storage, dns)..."
ADDONS_OK=true
for addon in helm3 storage dns; do
  if $MK status 2>&1 | grep -qE "${addon}.*enabled"; then
    pass "Addon: $addon enabled"
  else
    warn "Addon: $addon NOT enabled — enabling now..."
    $MK enable $addon 2>&1 | tee -a "$LOG_FILE" || {
      fail "Could not enable addon: $addon"
      ADDONS_OK=false
    }
  fi
done
$ADDONS_OK || { log "ERROR: Fix addon issues before continuing"; exit 1; }

# ── 1.3 Idempotency: Is Splunk already installed? ─────────────
log "1.3 Checking if Splunk Helm release already exists..."
EXISTING=$($HELM list -n "$SPLUNK_NAMESPACE" 2>/dev/null \
  | grep "$SPLUNK_RELEASE" | awk '{print $8}' || true)

if [ "$EXISTING" = "deployed" ]; then
  pass "Splunk already DEPLOYED (release=$SPLUNK_RELEASE, ns=$SPLUNK_NAMESPACE)"
  echo "SPLUNK_ALREADY_INSTALLED=true" > "$STATE_DIR/phase1.state"
  log "Phase 1 result: SKIP install — already deployed"
elif [ -n "$EXISTING" ]; then
  warn "Splunk release exists but status is: $EXISTING"
  echo "SPLUNK_ALREADY_INSTALLED=partial" > "$STATE_DIR/phase1.state"
else
  pass "Splunk NOT installed — Phase 2 will install it"
  echo "SPLUNK_ALREADY_INSTALLED=false" > "$STATE_DIR/phase1.state"
fi

# ── 1.4 Check Helm repo ──────────────────────────────────────
log "1.4 Checking Splunk Helm repo..."
if $HELM repo list 2>/dev/null | grep -q "splunk"; then
  pass "Splunk Helm repo already added"
else
  warn "Splunk Helm repo missing — adding..."
  $HELM repo add splunk https://splunk.github.io/splunk-operator 2>&1 \
    | tee -a "$LOG_FILE"
  $HELM repo update 2>&1 | tee -a "$LOG_FILE"
  pass "Splunk Helm repo added and updated"
fi

# ── 1.5 Check namespace ───────────────────────────────────────
log "1.5 Checking namespace: $SPLUNK_NAMESPACE..."
if $KUBECTL get namespace "$SPLUNK_NAMESPACE" &>/dev/null; then
  pass "Namespace '$SPLUNK_NAMESPACE' exists"
else
  warn "Namespace missing — creating..."
  $KUBECTL create namespace "$SPLUNK_NAMESPACE" 2>&1 | tee -a "$LOG_FILE"
  pass "Namespace '$SPLUNK_NAMESPACE' created"
fi

# ── 1.6 Verification test ─────────────────────────────────────
log "1.6 Phase 1 verification..."
$KUBECTL get namespace "$SPLUNK_NAMESPACE" &>/dev/null \
  && pass "Namespace check: OK" \
  || { fail "Namespace check: FAILED"; exit 1; }
$HELM repo list | grep -q splunk \
  && pass "Helm repo check: OK" \
  || { fail "Helm repo check: FAILED"; exit 1; }

echo "PHASE1_DONE=true" >> "$STATE_DIR/phase1.state"
log "=== PHASE 1 COMPLETE ==="
echo ""
echo "───────────────────────────────────────"
echo " Phase 1 Summary:"
cat "$STATE_DIR/phase1.state"
echo "───────────────────────────────────────"
echo " ✅ Ready for Phase 2"
