#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/state.env"
ensure_path

log()  { echo "$(date '+%H:%M:%S') [Phase5] $*" | tee -a "$LOG_FILE"; }
pass() { echo "  ✅ $*"; }
fail() { echo "  ❌ $*"; }

log "=== PHASE 5: Create OpenClaw Operations Dashboard ==="

[ -f "$STATE_DIR/phase4.state" ] || { fail "Run Phase 4 first"; exit 1; }
source "$STATE_DIR/splunk-creds.env"

SPLUNK_POD=$($KUBECTL get pods -n "$SPLUNK_NAMESPACE" --no-headers \
  | grep "standalone" | grep "Running" | awk '{print $1}' | head -1)

[ -n "$SPLUNK_POD" ] || { fail "No Splunk pod found"; exit 1; }

# ── 5.1 Delete old dashboard if exists ───────────────────────
log "5.1 Removing existing dashboard if present..."
$KUBECTL exec -n "$SPLUNK_NAMESPACE" "$SPLUNK_POD" -- \
  bash -c "curl -sk -u \"admin:${SPLUNK_PASSWORD}\" -X DELETE \
    https://localhost:8089/servicesNS/admin/search/data/ui/views/openclaw_operations 2>/dev/null || true"

# ── 5.2 Create dashboard via REST API ────────────────────────
log "5.2 Creating dashboard..."

$KUBECTL exec -n "$SPLUNK_NAMESPACE" "$SPLUNK_POD" -- bash -c "curl -sk -u \"admin:${SPLUNK_PASSWORD}\" \
  https://localhost:8089/servicesNS/admin/search/data/ui/views \
  -d name=openclaw_operations \
  --data-urlencode 'eai:data=<dashboard version=\"1.1\" theme=\"dark\"><label>OpenClaw Operations</label><row><panel><title>Log Volume 24h</title><chart><search><query>index=main | timechart span=5m count by sourcetype</query><earliest>-24h</earliest></search><option name=\"charting.chart\">area</option></chart></panel><panel><title>Log Sources</title><chart><search><query>index=main | stats count by sourcetype</query><earliest>-24h</earliest></search><option name=\"charting.chart\">pie</option></chart></panel></row><row><panel><title>Recent Errors</title><table><search><query>index=main (error OR fail OR crash) | table _time,sourcetype,_raw | head 25</query><earliest>-24h</earliest></search></table></panel></row><row><panel><title>OpenClaw</title><table><search><query>index=main sourcetype=openclaw | table _time,_raw | head 50</query><earliest>-1h</earliest></search></table></panel><panel><title>Syslog</title><table><search><query>index=main sourcetype=syslog | table _time,_raw | head 50</query><earliest>-1h</earliest></search></table></panel></row></dashboard>'" 2>&1 | grep -oE "HTTP:[0-9]*|name.*openclaw_operations|title.*views" | head -5

# ── 5.3 Verify ───────────────────────────────────────────────
log "5.3 Verifying dashboard..."
VERIFY=$($KUBECTL exec -n "$SPLUNK_NAMESPACE" "$SPLUNK_POD" -- \
  bash -c "curl -sk -u \"admin:${SPLUNK_PASSWORD}\" \
    https://localhost:8089/servicesNS/admin/search/data/ui/views/openclaw_operations?output_mode=json 2>/dev/null" | \
  grep -o '"name":"openclaw_operations"' || true)

[ -n "$VERIFY" ] && pass "Dashboard verified: openclaw_operations" || warn "Dashboard verification inconclusive"

echo "PHASE5_DONE=true" > "$STATE_DIR/phase5.state"

log "=== PHASE 5 COMPLETE ==="
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║          OpenClaw + Splunk K8s — SETUP COMPLETE                ║"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║  Splunk Web UI   : http://localhost:8000 (kubectl port-forward)║"
echo "║  Dashboard       : /en-US/app/search/openclaw_operations       ║"
echo "║  Username        : admin                                       ║"
echo "║  Password        : ${SPLUNK_PASSWORD}                          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "To access Splunk Web UI:"
echo "  kubectl port-forward -n splunk pod/${SPLUNK_POD} 8000:8000"
echo ""
echo "Forwarder service: sudo systemctl status openclaw-splunk-forwarder"
