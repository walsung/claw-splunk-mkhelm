# Splunk-K8s-helm Skill for OpenClaw

A complete solution for deploying Splunk Enterprise on MicroK8s with automated log forwarding from OpenClaw gateway and system syslog, and then build a new dashboard.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                         HOST SYSTEM                                  │
│                                                                      │
│  ┌─────────────────┐      ┌──────────────────────────────────────┐  │
│  │ OpenClaw        │      │ Python Log Forwarder (systemd)       │  │
│  │ Gateway         │─────▶│  • Batches 50 events                 │  │
│  │ (journald)      │      │  • 3s flush interval                 │  │
│  └─────────────────┘      │  • Monitors: openclaw + syslog       │  │
│                           └────────────────────┬───────────────────┘  │
│                                                │ HEC                  │
│                                                ▼                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │                    MICROK8s CLUSTER                            │  │
│  │                                                                │  │
│  │  ┌──────────────┐      ┌──────────────────────────────────┐   │  │
│  │  │ Splunk       │─────▶│  Standalone Instance             │   │  │
│  │  │ Operator     │      │  • Web: 8000, HEC: 8088          │   │  │
│  │  │ (Helm)       │      │  • Volumes: 5Gi etc / 20Gi var   │   │  │
│  │  └──────────────┘      │  • ClusterIP: 10.152.183.118     │   │  │
│  │                        └──────────────────────────────────┘   │  │
│  └────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
`# claw-splunk-mkhelm

> **OpenClaw Skill** — Idempotent Splunk deployment on MicroK8s via Helm.  
> Detects if Splunk is installed, installs it if missing, configures HEC,  
> forwards OpenClaw application logs, and builds a custom Splunk dashboard.  
> Safe to run multiple times — already-completed steps are automatically skipped.

---

## 📋 Prerequisites

| Requirement | Version | Check |
|---|---|---|
| Ubuntu | 22.04 / 24.04 | `lsb_release -a` |
| MicroK8s | 1.28+ | `microk8s version` |
| OpenClaw | 2026.x | `openclaw --version` |
| Helm (via MicroK8s) | 3.x | `microk8s helm version` |
| curl, jq, python3, openssl | any | `which curl jq python3 openssl` |

> ⚠️ All `kubectl` and `helm` commands in this project are **prefixed with `microk8s`**.  
> Do not use standalone `kubectl` or `helm` — they will target the wrong cluster.

---

## 🌐 Splunk Port Reference

| Service | Port | Purpose |
|---|---|---|
| **Web UI** | `8000` | Splunk browser dashboard |
| **HEC** | `8088` | HTTP Event Collector (log ingestion) |
| **Management API** | `8089` | REST API for admin and configuration |
| **Forwarder Receiver** | `9997` | Universal Forwarder input |

---

## 🗂️ Skill File Structure

```
~/.openclaw/skills/splunk-k8s/
├── SKILL.md                      ← OpenClaw skill manifest
├── state.env                     ← Shared config (ports, names, paths)
├── install.sh                    ← Full sequential installer (all 5 phases)
├── phase1-check.sh               ← Pre-flight + idempotency check
├── phase2-install.sh             ← Helm chart install
├── phase3-hec.sh                 ← Configure Splunk HEC token
├── phase4-forwarder.sh           ← Forward OpenClaw logs to Splunk
├── phase5-dashboard.sh           ← Create Splunk operations dashboard
├── uninstall.sh                  ← Full teardown
└── .state/                       ← Phase gate files (auto-generated)
    ├── phase1.state
    ├── phase2.state
    ├── phase3.state
    ├── phase4.state
    ├── phase5.state
    └── splunk-creds.env          ← Auto-generated credentials (gitignored)
```

---

## ⚙️ Installation

### Step 1 — Enable required MicroK8s addons

```bash
microk8s enable helm3
microk8s enable storage
microk8s enable dns
```

Verify they are enabled:

```bash
microk8s status | grep -E "helm3|storage|dns"
```

Expected output:
```
helm3: enabled
storage: enabled
dns: enabled
```

---

### Step 2 — Clone the skill into OpenClaw

```bash
mkdir -p ~/.openclaw/skills
cd ~/.openclaw/skills
git clone https://github.com/walsung/claw-splunk-mkhelm.git splunk-k8s
```

Make all scripts executable:

```bash
chmod +x ~/.openclaw/skills/splunk-k8s/*.sh
```

---

### Step 3 — Register the skill in OpenClaw

Edit `~/.openclaw/openclaw.json` and add `splunk-k8s` to the skills entries block:

```json
"skills": {
  "install": {
    "nodeManager": "npm"
  },
  "entries": {
    "splunk-k8s": {
      "enabled": true
    }
  }
}
```

Restart the gateway and confirm the skill is loaded:

```bash
openclaw gateway restart
openclaw skills list
```

You should see `splunk-k8s` with status **ready**.

---

### Step 4 — Port-forward Splunk services (run after Phase 2)

After Helm installs Splunk, forward all required ports to localhost:

```bash
microk8s kubectl port-forward \
  svc/splunk-splunk-enterprise-standalone-service \
  -n splunk \
  8000:8000 \
  8088:8088 \
  8089:8089 \
  9997:9997 \
  --address 0.0.0.0 &
```

Verify ports are listening:

```bash
ss -tlnp | grep -E '8000|8088|8089|9997'
```

To make the port-forward **permanent across reboots**:

```bash
sudo tee /etc/systemd/system/splunk-portforward.service > /dev/null << 'EOF'
[Unit]
Description=Splunk MicroK8s Port Forward
After=network.target

[Service]
User=ubuntu
ExecStart=/snap/bin/microk8s kubectl port-forward \
  svc/splunk-splunk-enterprise-standalone-service \
  -n splunk \
  8000:8000 8088:8088 8089:8089 9997:9997 \
  --address 0.0.0.0
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now splunk-portforward
sudo systemctl status splunk-portforward
```

---

## 🚀 Running the Skill in OpenClaw Chat

> ⚠️ **Important:** OpenClaw must run each phase **one at a time**.  
> Do NOT ask OpenClaw to run all phases in a single prompt.  
> Each phase has a verification gate — confirm ✅ before moving to the next.

---

### Phase 1 — Pre-flight Check

Paste this into the OpenClaw chat:

```
Use the splunk-k8s skill. Run Phase 1 only:
  bash ~/.openclaw/skills/splunk-k8s/phase1-check.sh

Show me the full terminal output.
Do NOT proceed to Phase 2 until I confirm.
```

**What Phase 1 does:**
- Checks MicroK8s is running
- Verifies addons (helm3, storage, dns) are enabled — auto-enables if missing
- Detects if Splunk Helm release already exists (idempotency check)
- Adds the Splunk Helm repo if missing
- Creates the `splunk` namespace if it doesn't exist

**Expected output:**
```
✅ MicroK8s is running
✅ Addon: helm3 enabled
✅ Addon: storage enabled
✅ Addon: dns enabled
✅ Namespace 'splunk' exists
✅ Helm repo check: OK
=== PHASE 1 COMPLETE ===
✅ Ready for Phase 2
```

---

### Phase 2 — Helm Chart Install

Only run after Phase 1 shows ✅ complete:

```
Phase 1 is confirmed complete. Now run Phase 2 only:
  bash ~/.openclaw/skills/splunk-k8s/phase2-install.sh

Show me the full output including pod status.
This may take 5-10 minutes for pods to reach Running state — please poll and wait.
Do NOT proceed to Phase 3 until all pods show Running.
```

**What Phase 2 does:**
- Skips automatically if Splunk is already deployed (idempotent)
- Generates a secure random admin password (stored in `.state/splunk-creds.env`)
- Runs `microk8s helm upgrade --install` with resource limits and HEC enabled
- Polls pods every 10 seconds until all are in `Running` state (max 10 min)

**Check pods manually at any time:**
```bash
microk8s kubectl get pods -n splunk
microk8s kubectl get all -n splunk
```

**Expected output:**
```
✅ Helm release status: deployed
✅ All pods are Running
=== PHASE 2 COMPLETE ===
  Release  : splunk-enterprise
  Namespace: splunk
  Password : <auto-generated>
  Creds at : ~/.openclaw/skills/splunk-k8s/.state/splunk-creds.env
✅ Ready for Phase 3
```

---

### Phase 3 — Configure HEC Token

Only run after Phase 2 shows all pods Running:

```
Phase 2 is confirmed complete. All pods are Running.
Now run Phase 3 only:
  bash ~/.openclaw/skills/splunk-k8s/phase3-hec.sh

Show me the HEC token value and all HTTP response codes.
Do NOT proceed to Phase 4 until HEC test event returns HTTP 200 and code:0.
```

**What Phase 3 does:**
- Opens port-forward to Splunk management API on port `8089` and HEC on port `8088`
- Checks if HEC token `openclaw-logs` already exists (idempotent)
- Enables HEC globally via the Splunk REST API on port `8089`
- Creates the HEC token and saves it to `.state/splunk-creds.env`
- Sends a test event to port `8088` and confirms `"code":0` response

**Expected output:**
```
✅ Splunk API reachable (HTTP 200)
✅ HEC token 'openclaw-logs' created
✅ HEC test event accepted (HTTP 200, code:0)
=== PHASE 3 COMPLETE ===
  HEC Token    : xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  HEC Endpoint : http://127.0.0.1:8088/services/collector/event
  Splunk Web   : http://127.0.0.1:8000
  Mgmt API     : https://127.0.0.1:8089/services
✅ Ready for Phase 4
```

---

### Phase 4 — Forward OpenClaw Logs to Splunk

Only run after Phase 3 confirms HEC test event succeeded:

```
Phase 3 is confirmed complete. HEC token is working.
Now run Phase 4 only:
  bash ~/.openclaw/skills/splunk-k8s/phase4-forwarder.sh

Show me the systemctl status output and confirm events
are arriving in Splunk index=main sourcetype=openclaw.
Do NOT proceed to Phase 5 until log forwarding is confirmed.
```

**What Phase 4 does:**
- Auto-detects the OpenClaw log file path (falls back to journald)
- Skips reinstall if forwarder is already running with the same HEC token (idempotent)
- Installs `/usr/local/bin/openclaw-splunk-forwarder.sh`
- Creates and enables systemd service `openclaw-splunk-forwarder`
- Sends logs to Splunk HEC on port `8088`
- Waits 30 seconds then verifies events appear in Splunk `index=main`

**Check forwarder status at any time:**
```bash
systemctl status openclaw-splunk-forwarder --no-pager
journalctl -u openclaw-splunk-forwarder -n 50 --no-pager
```

**Expected output:**
```
✅ Forwarder service started
✅ Events confirmed in Splunk index
=== PHASE 4 COMPLETE ===
✅ Ready for Phase 5
```

---

### Phase 5 — Build Splunk Dashboard

Only run after Phase 4 confirms log events are arriving:

```
Phase 4 is confirmed complete. Logs are flowing into Splunk.
Now run Phase 5 only:
  bash ~/.openclaw/skills/splunk-k8s/phase5-dashboard.sh

Show me the final summary box with the Splunk UI URL,
credentials, and dashboard URL.
```

**What Phase 5 does:**
- Checks if the `openclaw_operations` dashboard already exists (idempotent overwrite)
- Posts a dark-themed XML dashboard via the Splunk REST API on port `8089`
- Verifies the dashboard was created/updated successfully

**Dashboard panels created:**

| Panel | Description |
|---|---|
| 📈 Log Volume (last 24h) | Line chart — `timechart span=5m count` |
| 🎯 Log Level Breakdown | Pie chart by DEBUG / INFO / WARN / ERROR |
| 🚨 Recent Errors & Warnings | Table of ERROR and WARN events |
| 🔄 Gateway Lifecycle Events | Start / stop / crash / restart events |
| 📊 Event Rate (per min) | Average events per minute |
| 🗂️ All Recent Events | Last 50 raw log lines |

**Expected output:**
```
✅ Dashboard verified: openclaw_operations
=== PHASE 5 COMPLETE — ALL PHASES DONE ===
  Splunk Web UI  : http://127.0.0.1:8000
  Username       : admin
  Password       : <see splunk-creds.env>
  Dashboard URL  : http://127.0.0.1:8000/en-US/app/search/openclaw_operations
  HEC Endpoint   : http://127.0.0.1:8088/services/collector/event
  Mgmt API       : https://127.0.0.1:8089/services
```

---

## 🌐 Splunk Access After Setup

| Access | URL |
|---|---|
| **Web UI** | http://127.0.0.1:8000 |
| **OpenClaw Dashboard** | http://127.0.0.1:8000/en-US/app/search/openclaw_operations |
| **HEC Endpoint** | http://127.0.0.1:8088/services/collector/event |
| **Management REST API** | https://127.0.0.1:8089/services |

Login: `admin` / password stored at:

```bash
cat ~/.openclaw/skills/splunk-k8s/.state/splunk-creds.env
```

---

## 🔍 Useful Debug Commands

```bash
# All Splunk pods with node/IP info
microk8s kubectl get pods -n splunk -o wide

# All Splunk services and ports
microk8s kubectl get svc -n splunk

# All resources in splunk namespace
microk8s kubectl get all -n splunk

# Helm release status
microk8s helm list -n splunk

# Watch pods live during install
watch -n 3 'microk8s kubectl get pods -n splunk'

# View Splunk pod logs
microk8s kubectl logs -n splunk \
  $(microk8s kubectl get pods -n splunk --no-headers | awk 'NR==1{print $1}') \
  --tail=50

# Test Web UI is responding
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8000

# Test Management API
curl -sk -o /dev/null -w "%{http_code}" \
  -u admin:YOUR_PASSWORD \
  https://127.0.0.1:8089/services

# Test HEC endpoint
curl -s http://127.0.0.1:8088/services/collector/event \
  -H "Authorization: Splunk YOUR_HEC_TOKEN" \
  -d '{"event":"test","sourcetype":"openclaw"}'

# Check log forwarder
systemctl status openclaw-splunk-forwarder --no-pager
journalctl -u openclaw-splunk-forwarder -n 50 --no-pager

# Check port-forward service
systemctl status splunk-portforward --no-pager
```

---

## 🧹 Uninstall Everything

```bash
# Remove Helm release
microk8s helm uninstall splunk-enterprise -n splunk

# Delete namespace (removes all pods, services, pvcs)
microk8s kubectl delete namespace splunk

# Remove log forwarder
sudo systemctl stop openclaw-splunk-forwarder
sudo systemctl disable openclaw-splunk-forwarder
sudo rm /etc/systemd/system/openclaw-splunk-forwarder.service
sudo rm /usr/local/bin/openclaw-splunk-forwarder.sh
sudo systemctl daemon-reload

# Remove port-forward service
sudo systemctl stop splunk-portforward
sudo systemctl disable splunk-portforward
sudo rm /etc/systemd/system/splunk-portforward.service
sudo systemctl daemon-reload

# Remove state and credentials
rm -rf ~/.openclaw/skills/splunk-k8s/.state
```

---

## 📄 License

MIT — free to 

