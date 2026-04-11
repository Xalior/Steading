#!/bin/bash
#
# vm-up.sh — clone a macOS Tahoe base image into a working VM,
# start it headless with the repo mounted as a virtio-fs share,
# and wait for the Tart guest agent to come up so subsequent
# `tart exec` calls work.
#
# Usage:   scripts/vm-up.sh [vm-name]
# Default: steading-test
#
# Environment:
#   BASE_IMAGE — OCI ref of the base image to clone from.
#                Defaults to ghcr.io/cirruslabs/macos-tahoe-xcode:26.4
#                (full Xcode toolchain preinstalled — the everyday
#                dev / build-test VM).
#                Set to ghcr.io/cirruslabs/macos-tahoe-vanilla:26.4
#                for the release-test VM with no developer tools —
#                matches a real end-user machine.
#
# The base image must already be pulled with
# `TART_HOME=… tart pull …` before this script.
#
# The host's repo root is mounted read-only inside the VM at
# /Volumes/My Shared Files/Steading — the guest can build from a
# writable copy (~/build) without writing anything back to the
# host.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export TART_HOME="${TART_HOME:-$REPO_ROOT/tart}"

VM_NAME="${1:-steading-test}"
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/cirruslabs/macos-tahoe-xcode:26.4}"

echo "TART_HOME =$TART_HOME"
echo "repo root =$REPO_ROOT"
echo "vm name   =$VM_NAME"
echo "base image=$BASE_IMAGE"

# Clone if the working VM doesn't already exist. Tart stores each
# local VM at $TART_HOME/vms/<name>/ so a directory probe is more
# reliable than parsing `tart list --format json`.
if [ -d "$TART_HOME/vms/$VM_NAME" ]; then
    echo "vm ${VM_NAME} already exists; reusing"
else
    echo "cloning ${BASE_IMAGE} -> ${VM_NAME}"
    tart clone "$BASE_IMAGE" "$VM_NAME"
fi

# Run headless in the background with the repo mounted read-only.
# `nohup` + `&` + redirecting fds keeps it alive when this script
# exits. The VM appears inside the guest at
# /Volumes/My Shared Files/Steading.
RUN_LOG="$TART_HOME/${VM_NAME}.run.log"
if pgrep -f "tart run ${VM_NAME}" >/dev/null; then
    echo "vm ${VM_NAME} is already running"
else
    echo "starting vm headless (log: $RUN_LOG)"
    nohup tart run "$VM_NAME" \
        --no-graphics \
        --dir "Steading:${REPO_ROOT}:ro" \
        >"$RUN_LOG" 2>&1 &
    disown
fi

# Wait up to ~120s for the guest agent to respond.
echo -n "waiting for guest agent"
for _ in $(seq 1 60); do
    if tart exec "$VM_NAME" -- /usr/bin/true >/dev/null 2>&1; then
        echo
        IP="$(tart ip "$VM_NAME" 2>/dev/null || echo '?')"
        echo "vm ${VM_NAME} is ready (ip=${IP})"
        exit 0
    fi
    echo -n "."
    sleep 2
done

echo
echo "timed out waiting for ${VM_NAME} guest agent" >&2
exit 1
