#!/bin/bash
#
# vm-down.sh — stop and delete a working VM. Safe to re-run
# (no-op if the VM is already gone).
#
# Usage:   scripts/vm-down.sh [vm-name]
# Default: steading-test
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export TART_HOME="${TART_HOME:-$REPO_ROOT/tart}"

VM_NAME="${1:-steading-test}"

if [ ! -d "$TART_HOME/vms/$VM_NAME" ]; then
    echo "vm ${VM_NAME} does not exist"
    exit 0
fi

# Stop first (ignore failure — may already be stopped).
tart stop "$VM_NAME" 2>/dev/null || true

# Kill any lingering host-side tart run process for this VM.
pkill -f "tart run ${VM_NAME}" 2>/dev/null || true

tart delete "$VM_NAME"
echo "deleted ${VM_NAME}"
