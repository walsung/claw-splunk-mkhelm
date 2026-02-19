# Splunk-K8s Skill for OpenClaw

A complete solution for deploying Splunk Enterprise on MicroK8s with automated log forwarding from OpenClaw gateway and system syslog.

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
```

## Quick Start

```bash
# Run full setup
bash ~/.openclaw/skills/splunk-k8s/install.sh

# Or run phases individually:
bash phase1-check.sh     # Pre-flight
bash phase2-install.sh   # Deploy Splunk
bash phase3-hec.sh       # Configure HEC
bash phase4-forwarder.sh # Start forwarder
bash phase5-dashboard.sh # Create dashboard
```

## Phase-by-Phase Walkthrough

### Phase 1: Pre-flight Checks

Validates MicroK8s status, enables addons, creates namespace.

### Phase 2: Install Splunk

Installs Splunk Operator via Helm and creates the Standalone Custom Resource. Retrieves the auto-generated admin password from Kubernetes secrets and stores the ClusterIP for internal access.

### Phase 3: Configure HEC

Uses `kubectl exec` to configure the HTTP Event Collector inside the Splunk pod:
- Enables HEC globally
- Creates the `openclaw-logs` HEC token
- Retrieves and stores credentials

**Key Fix**: No port-forwarding required — all API calls happen via `kubectl exec`.

### Phase 4: Deploy Python Forwarder

Installs a systemd service that monitors:
- OpenClaw logs via `journalctl -u openclaw`
- System syslog via `tail -F /var/log/syslog`

The forwarder is written in Python for:
- Efficient batching (50 events / 3 seconds)
- Proper JSON escaping
- Low memory footprint (~12MB vs 3GB+ in bash)
- Auto-reconnect on failure

### Phase 5: Create Dashboard

Creates the "OpenClaw Operations" dashboard via REST API inside the pod.

## Accessing Splunk

```bash
# Port-forward (run in terminal)
kubectl port-forward -n splunk pod/splunk-splunk-enterprise-standalone-0 8000:8000

# Then open browser:
# http://localhost:8000
# Username: admin
# Password: (from ~/.openclaw/skills/splunk-k8s/.state/splunk-creds.env)

# Dashboard URL:
# http://localhost:8000/en-US/app/search/openclaw_operations
```

## Dashboard

The dashboard includes:
- **Log Volume (24h)**: Area chart showing events over time
- **Log Source Breakdown**: Pie chart by sourcetype
- **Recent Errors**: Table of error/fail/crash messages
- **OpenClaw Events**: Last 50 OpenClaw log entries
- **Syslog Events**: Last 50 syslog entries

## Files

| File | Purpose |
|------|---------|
| `SKILL.md` | Skill metadata and commands |
| `state.env` | Shared configuration |
| `phase1-check.sh` | Pre-flight validation |
| `phase2-install.sh` | Splunk deployment |
| `phase3-hec.sh` | HEC configuration |
| `phase4-forwarder.sh` | Log forwarder installation |
| `phase5-dashboard.sh` | Dashboard creation |
| `install.sh` | Runs all phases |
| `uninstall.sh` | Cleanup script |

## Troubleshooting

### Check forwarder status:
```bash
sudo systemctl status openclaw-splunk-forwarder
sudo journalctl -u openclaw-splunk-forwarder -f
```

### Verify logs in Splunk:
```bash
# Inside Splunk pod
kubectl exec -n splunk splunk-splunk-enterprise-standalone-0 -- bash
curl -u admin:PASSWORD https://localhost:8089/services/search/jobs/export \
  --data-urlencode "search=search index=main | head 10"
```

## Uninstallation

```bash
bash ~/.openclaw/skills/splunk-k8s/uninstall.sh
```

This removes:
- Splunk Helm release
- `splunk` namespace
- Log forwarder systemd service
- All configuration files

## License

MIT
