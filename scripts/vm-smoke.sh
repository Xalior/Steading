#!/bin/bash
#
# vm-smoke.sh — copy the repo into a running VM and run
# `xcodebuild build test` inside the guest. Verifies that Steading
# compiles and its unit tests pass against a clean macOS 26 install
# with no developer state leaking in from the host.
#
# Usage: scripts/vm-smoke.sh [vm-name]
# The VM must already be running (see vm-up.sh).
#
# Uses ad-hoc signing inside the VM — sufficient for the build and
# unit-test suite. The full onboarding flow (SMAppService
# registration, helper approval) requires a real Apple Development
# identity to be seeded into the VM's keychain; that's a separate
# script and the next step after this one proves the build works.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export TART_HOME="${TART_HOME:-$REPO_ROOT/tart}"

VM_NAME="${1:-steading-test}"

# Sanity: the VM must be up and the guest agent reachable.
if ! tart exec "$VM_NAME" -- /usr/bin/true >/dev/null 2>&1; then
    echo "vm ${VM_NAME} is not running or guest agent is not responding" >&2
    echo "run scripts/vm-up.sh ${VM_NAME} first" >&2
    exit 1
fi

echo "==> copying repo into VM (~/build)"
# Copy the shared mount to a writable location so DerivedData and
# anything xcodebuild scribbles stays in the guest.
tart exec "$VM_NAME" -- /bin/bash -lc '
    set -euo pipefail
    rm -rf ~/build
    mkdir -p ~/build
    cp -R "/Volumes/My Shared Files/Steading/app/." ~/build/
    ls ~/build | head
'

echo "==> regenerating xcodeproj (xcodegen)"
tart exec "$VM_NAME" -- /bin/bash -lc '
    set -euo pipefail
    cd ~/build
    if ! command -v xcodegen >/dev/null 2>&1; then
        brew install xcodegen >/dev/null
    fi
    xcodegen generate
'

echo "==> xcodebuild build (ad-hoc signed)"
tart exec "$VM_NAME" -- /bin/bash -lc '
    set -euo pipefail
    cd ~/build
    xcodebuild \
        -project Steading.xcodeproj \
        -scheme Steading \
        -configuration Debug \
        -arch arm64 \
        ONLY_ACTIVE_ARCH=YES \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGN_STYLE=Manual \
        DEVELOPMENT_TEAM="" \
        ENABLE_HARDENED_RUNTIME=NO \
        build 2>&1 | grep -E "error:|warning:|BUILD" | tail -20
'

echo "==> xcodebuild test"
tart exec "$VM_NAME" -- /bin/bash -lc '
    set -euo pipefail
    cd ~/build
    xcodebuild \
        -project Steading.xcodeproj \
        -scheme Steading \
        -configuration Debug \
        -destination "platform=macOS,arch=arm64" \
        -enableCodeCoverage NO \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGN_STYLE=Manual \
        DEVELOPMENT_TEAM="" \
        ENABLE_HARDENED_RUNTIME=NO \
        test 2>&1 | grep -E "Test run|✔|✘|passed|failed|Issue recorded" | tail -30
'

echo "==> smoke test complete"
