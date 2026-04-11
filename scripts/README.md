# Scripts

Host-side helpers for driving Tart VMs from the command line.
Every script respects `TART_HOME` (defaulting to
`$repo_root/tart/`) so all VM state lives alongside the repo on
the McFiver volume.

## One-time setup

Pull the base image. This takes a while and needs ~90 GB:

```sh
TART_HOME=$PWD/tart \
  tart pull ghcr.io/cirruslabs/macos-tahoe-xcode:26.4
```

## Day-to-day workflow

```sh
scripts/vm-up.sh           # clone base, start headless, wait for guest agent
scripts/vm-smoke.sh        # build + unit tests inside the VM
scripts/vm-down.sh         # stop and delete the working VM
```

All three take an optional `vm-name` argument (default
`steading-test`) so you can run several working VMs in parallel
against the same base image.

## Scripts

- **`vm-up.sh [name]`** — clones
  `ghcr.io/cirruslabs/macos-tahoe-xcode:26.4` to a working VM, runs
  it headless with the repo mounted read-only at
  `/Volumes/My Shared Files/Steading` inside the guest, and waits
  for the Tart guest agent to respond. Reusable — re-running on an
  already-up VM is a no-op.

- **`vm-smoke.sh [name]`** — copies the shared mount to
  `~/build` inside the guest (so DerivedData stays in the VM),
  runs `xcodegen generate`, then `xcodebuild build test` with
  ad-hoc signing. Verifies that Steading compiles and all 49
  tests pass on a fresh macOS 26 install with no state leaked in
  from the host.

- **`vm-down.sh [name]`** — stops the VM and deletes the working
  clone. Safe to run on a missing VM.

## What this tests

- The repo is self-contained: clone, generate, build, run tests
  work from a fresh checkout on a stock macOS 26 install.
- `xcodegen` picks up all sources and produces a working project.
- The built-in service runners, brew detector, helper allowlist,
  and app-state logic all pass their tests against a clean system.

## What this does NOT test (yet)

- The full onboarding flow including SMAppService registration
  and user approval of the privileged helper. That requires a
  real Apple Development signing identity in the VM's keychain
  plus the one-time GUI click to approve the Login Item — a
  separate script and snapshot workflow, deferred until the smoke
  test proves the build is healthy in a VM.
