#!/usr/bin/env bash
# Uninstall Splunk K8s and all related resources
# Usage: bash uninstall.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/state.env"
ensure_path 2>/dev/null || true

echo "=== Splunk K8s Uninstaller ==="
echo ""

# Check if MicroK8s is available
if ! command -v microk8s &>/dev/null && [ -d "/snap/bin" ]; then
    export PATH="$PATH:/snap/bin"
fi

if command -v microk8s &>/dev/null; then
    echo "Removing Splunk Helm release..."
    microk8s helm uninstall "$SPLUNK_RELEASE" -n "$SPLUNK_NAMESPACE" 2>/dev/null || true
    
    echo "Removing Splunk Standalone CR..."
    microk8s kubectl delete standalone "$SPLUNK_RELEASE" -n "$SPLUNK_NAMESPACE" 2>/dev/null || true
    
    echo "Removing namespace..."
    microk8s kubectl delete namespace "$SPLUNK_NAMESPACE" --wait=false 2>/dev/null || true
else
    echo "MicroK8s not found, skipping K8s cleanup"
fi

echo "Stopping and removing forwarder service..."
sudo systemctl stop openclaw-splunk-forwarder 2>/dev/null || true
sudo systemctl disable openclaw-splunk-forwarder 2>/dev/null || true
sudo rm -f /etc/systemd/system/openclaw-splunk-forwarder.service
sudo rm -f /usr/local/bin/openclaw-splunk-forwarder.py
sudo systemctl daemon-reload

echo "Removing configuration files..."
rm -rf "$STATE_DIR"

echo ""
echo "=== Uninstall Complete ==="
echo "Splunk K8s has been removed from your system."
