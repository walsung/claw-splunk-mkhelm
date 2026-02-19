---
name: splunk-k8s
description: >
  Idempotent Splunk-on-MicroK8s manager. Deploys Splunk Enterprise via the 
  Splunk Operator, configures HEC for log ingestion, and deploys a Python-based
  log forwarder that monitors both OpenClaw journald logs and /var/log/syslog.
  Features: kubectl-exec based API access (no port-forward dependency), 
  efficient event batching, auto-reconnect, and a custom Splunk dashboard.
version: 2.0.0
requires:
  bins: [microk8s, curl, python3]
  env: []
---

# Splunk K8s Skill

## When to use this skill

- Deploy Splunk Enterprise on MicroK8s
- Monitor OpenClaw gateway logs
- Monitor system syslog
- Create a unified logging dashboard

## Quick Start

```bash
# Full setup
bash ~/.openclaw/skills/splunk-k8s/install.sh

# Individual phases
bash ~/.openclaw/skills/splunk-k8s/phase1-check.sh     # Pre-flight
bash ~/.openclaw/skills/splunk-k8s/phase2-install.sh   # Deploy Splunk
bash ~/.openclaw/skills/splunk-k8s/phase3-hec.sh       # Configure HEC
bash ~/.openclaw/skills/splunk-k8s/phase4-forwarder.sh # Start forwarder
bash ~/.openclaw/skills/splunk-k8s/phase5-dashboard.sh # Create dashboard
```

## Access Splunk

```bash
# Port-forward (keep terminal open)
kubectl port-forward -n splunk pod/splunk-splunk-enterprise-standalone-0 8000:8000

# Open browser: http://localhost:8000
# Dashboard: http://localhost:8000/en-US/app/search/openclaw_operations
```

## Credentials

Stored in: `~/.openclaw/skills/splunk-k8s/.state/splunk-creds.env`

- Username: `admin`
- Password: auto-generated and retrieved from K8s secret
- HEC Token: auto-generated

## Commands

```bash
# Check Splunk status
microk8s kubectl get pods -n splunk

# View forwarder logs
sudo journalctl -u openclaw-splunk-forwarder -f

# Uninstall
bash ~/.openclaw/skills/splunk-k8s/uninstall.sh
```

## Architecture Notes

- **No port-forward dependency**: All API calls use `kubectl exec`
- **ClusterIP access**: Forwarder uses K8s ClusterIP for reliable HEC communication
- **Python forwarder**: Efficient batching (50 events/3s), low memory (~12MB)
- **Dual sources**: Monitors both OpenClaw (journald) and syslog
