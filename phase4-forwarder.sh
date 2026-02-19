#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/state.env"
ensure_path

log()  { echo "$(date '+%H:%M:%S') [Phase4] $*" | tee -a "$LOG_FILE"; }
pass() { echo "  ✅ $*"; }
fail() { echo "  ❌ $*"; }
warn() { echo "  ⚠️  $*"; }

log "=== PHASE 4: Deploy Python Log Forwarder ==="

[ -f "$STATE_DIR/phase3.state" ] || { fail "Run Phase 3 first"; exit 1; }
source "$STATE_DIR/splunk-creds.env"

# ── 4.1 Idempotency check ────────────────────────────────────
log "4.1 Checking if forwarder service exists..."
if systemctl is-active openclaw-splunk-forwarder &>/dev/null; then
  pass "Forwarder service already active"
  systemctl restart openclaw-splunk-forwarder
fi

# ── 4.2 Write Python forwarder ───────────────────────────────
log "4.2 Writing Python forwarder..."
FORWARDER_PY='/usr/local/bin/openclaw-splunk-forwarder.py'

sudo tee "$FORWARDER_PY" > /dev/null << 'PYEOF'
#!/usr/bin/env python3
"""Splunk HEC Forwarder - Monitors OpenClaw (journald) and /var/log/syslog"""
import json, subprocess, sys, time, urllib.request, threading, os

HEC_TOKEN = os.environ.get('HEC_TOKEN', '')
HEC_URL = os.environ.get('HEC_URL', '')
BATCH_SIZE = int(os.environ.get('BATCH_SIZE', '50'))
BATCH_TIMEOUT = int(os.environ.get('BATCH_TIMEOUT', '3'))
HOSTNAME = os.uname().nodename

class SplunkForwarder:
    def __init__(self):
        self.batch = []
        self.lock = threading.Lock()
        self.last_flush = time.time()
        self.running = True
        
    def send_event(self, event, sourcetype):
        if not event or not HEC_URL:
            return
        payload = {"time": time.time(), "host": HOSTNAME, "sourcetype": sourcetype, "index": "main", "event": event}
        with self.lock:
            self.batch.append(json.dumps(payload))
            if len(self.batch) >= BATCH_SIZE or (time.time() - self.last_flush) >= BATCH_TIMEOUT:
                self._flush()
    
    def _flush(self):
        if not self.batch:
            return
        data = ("\n".join(self.batch) + "\n").encode('utf-8')
        self.batch = []
        self.last_flush = time.time()
        try:
            req = urllib.request.Request(HEC_URL, data=data,
                headers={"Authorization": f"Splunk {HEC_TOKEN}", "Content-Type": "application/json"},
                method="POST")
            urllib.request.urlopen(req, timeout=10).read()
        except Exception as e:
            print(f"[{time.strftime('%H:%M:%S')}] Flush error: {e}", file=sys.stderr)
    
    def monitor_stream(self, cmd, sourcetype):
        while self.running:
            try:
                proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
                for line in proc.stdout:
                    if not self.running:
                        break
                    self.send_event(line.strip(), sourcetype)
            except Exception as e:
                print(f"{sourcetype} error: {e}", file=sys.stderr)
                time.sleep(5)
    
    def periodic_flush(self):
        while self.running:
            time.sleep(BATCH_TIMEOUT)
            with self.lock:
                self._flush()
    
    def run(self):
        print(f"[{time.strftime('%H:%M:%S')}] Forwarder starting...")
        print(f"[{time.strftime('%H:%M:%S')}] HEC URL: {HEC_URL}")
        threads = [
            threading.Thread(target=self.monitor_stream, args=(["journalctl", "-u", "openclaw", "-f", "--no-pager", "-o", "cat"], "openclaw"), daemon=True),
            threading.Thread(target=self.monitor_stream, args=(["tail", "-F", "/var/log/syslog"], "syslog"), daemon=True),
            threading.Thread(target=self.periodic_flush, daemon=True)
        ]
        for t in threads:
            t.start()
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            self.running = False
            with self.lock:
                self._flush()

if __name__ == "__main__":
    SplunkForwarder().run()
PYEOF

sudo chmod +x "$FORWARDER_PY"
pass "Python forwarder written"

# ── 4.3 Write systemd service ────────────────────────────────
log "4.3 Writing systemd service..."
sudo tee /etc/systemd/system/openclaw-splunk-forwarder.service > /dev/null << SVCEOF
[Unit]
Description=OpenClaw Log Forwarder to Splunk HEC
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
Environment="HEC_TOKEN=${HEC_TOKEN}"
Environment="HEC_URL=${SPLUNK_HEC_URL:-http://${SPLUNK_CLUSTER_IP}:8088/services/collector/event}"
Environment="BATCH_SIZE=50"
Environment="BATCH_TIMEOUT=3"
ExecStart=/usr/bin/python3 /usr/local/bin/openclaw-splunk-forwarder.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

sudo systemctl daemon-reload
sudo systemctl enable openclaw-splunk-forwarder
sudo systemctl restart openclaw-splunk-forwarder
sleep 3
pass "Forwarder service started"

# ── 4.4 Verify ───────────────────────────────────────────────
log "4.4 Verifying forwarder status..."
if systemctl is-active openclaw-splunk-forwarder &>/dev/null; then
  pass "Forwarder is running"
else
  fail "Forwarder failed to start"
  exit 1
fi

echo "PHASE4_DONE=true" > "$STATE_DIR/phase4.state"
log "=== PHASE 4 COMPLETE ==="
echo ""
echo " ✅ Ready for Phase 5"
