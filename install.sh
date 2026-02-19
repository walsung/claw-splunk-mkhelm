#!/usr/bin/env bash
# Main installer - runs all phases sequentially
# Usage: bash install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INSTALL]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log "Starting Splunk K8s installation..."
echo ""

# Check if running from correct directory
if [ ! -f "$SCRIPT_DIR/SKILL.md" ]; then
    error "Please run this script from the splunk-k8s skill directory"
    exit 1
fi

# Phase 1
log "=== Phase 1: Pre-flight Checks ==="
bash "$SCRIPT_DIR/phase1-check.sh" || {
    error "Phase 1 failed"
    exit 1
}
echo ""

# Phase 2
log "=== Phase 2: Install Splunk ==="
bash "$SCRIPT_DIR/phase2-install.sh" || {
    error "Phase 2 failed"
    exit 1
}
echo ""

# Phase 3
log "=== Phase 3: Configure HEC ==="
bash "$SCRIPT_DIR/phase3-hec.sh" || {
    error "Phase 3 failed"
    exit 1
}
echo ""

# Phase 4
log "=== Phase 4: Deploy Log Forwarder ==="
bash "$SCRIPT_DIR/phase4-forwarder.sh" || {
    error "Phase 4 failed"
    exit 1
}
echo ""

# Phase 5
log "=== Phase 5: Create Dashboard ==="
bash "$SCRIPT_DIR/phase5-dashboard.sh" || {
    error "Phase 5 failed"
    exit 1
}

echo ""
log "=== Installation Complete ==="
echo ""
echo "To access Splunk:"
echo "  1. Run: kubectl port-forward -n splunk pod/\$(kubectl get pods -n splunk -l app.kubernetes.io/component=standalone -o jsonpath='{.items[0].metadata.name}') 8000:8000"
echo "  2. Open: http://localhost:8000"
echo "  3. Login with credentials from: $SCRIPT_DIR/.state/splunk-creds.env"
