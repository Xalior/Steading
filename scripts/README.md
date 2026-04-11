# Scripts

Host-side helpers for driving Tart VMs from the command line.
Every script respects `TART_HOME` (defaulting to
`$repo_root/tart/`) so all VM state lives alongside the repo on
the McFiver volume.

## Two base images, two test shapes

Steading's VM testing has two distinct purposes and matching base
images, both from the cirruslabs OCI registry:

| Image | Size | Use case |
|---|---|---|
| `ghcr.io/cirruslabs/macos-tahoe-xcode:26.4` | ~140 GB | Build-test VM. Full Xcode 26.4 preinstalled. Used to verify the repo builds from a fresh checkout against a stock macOS 26 install (no state leaked from the dev host). |
| `ghcr.io/cirruslabs/macos-tahoe-vanilla:26.4` | ~40 GB | Release-test VM. Clean macOS 26, no developer tools. Used to verify a built `Steading.app` runs on a real user's machine — tests the distribution artefact rather than the build. |

## One-time setup

Pull both base images once:

```sh
TART_HOME=$PWD/tart \
  tart pull ghcr.io/cirruslabs/macos-tahoe-xcode:26.4

TART_HOME=$PWD/tart \
  tart pull ghcr.io/cirruslabs/macos-tahoe-vanilla:26.4
```

## Day-to-day: build-test workflow

Against a fresh Xcode-equipped VM, copy the repo inside and run
the full build + test suite. Catches any "works on my machine"
drift between the dev host and a clean install.

```sh
scripts/vm-up.sh steading-xcode        # default base image is xcode
scripts/vm-smoke.sh steading-xcode     # xcodegen generate + build + test
scripts/vm-down.sh steading-xcode      # destroy the working clone
```

## Release-test workflow (coming next)

Against a vanilla VM with no developer tools, copy in a built
`Steading.app` from the host and launch it — matches the
experience of a real user installing the app. (Helper scripts
for this flow land after the build-test path is proven.)

```sh
BASE_IMAGE=ghcr.io/cirruslabs/macos-tahoe-vanilla:26.4 \
  scripts/vm-up.sh steading-vanilla
# …release-test scripts to be added…
scripts/vm-down.sh steading-vanilla
```

## Scripts

- **`vm-up.sh [name]`** — clones `$BASE_IMAGE` (default:
  `ghcr.io/cirruslabs/macos-tahoe-xcode:26.4`) to a working VM,
  runs it headless with the repo mounted read-only at
  `/Volumes/My Shared Files/Steading` inside the guest, and
  waits for the Tart guest agent to respond. Reusable —
  re-running on an already-up VM is a no-op. Override the base
  image with the `BASE_IMAGE` environment variable.

- **`vm-smoke.sh [name]`** — copies the shared mount to
  `~/build` inside the guest (so DerivedData stays in the VM),
  runs `xcodegen generate`, then `xcodebuild build test` with
  ad-hoc signing. Requires the xcode base image — the vanilla
  image has no developer tools.

- **`vm-down.sh [name]`** — stops the VM and deletes the working
  clone. Safe to run on a missing VM.

## What this tests

- **Build-test VM:** the repo is self-contained — clone,
  generate, build, run tests all work from a fresh checkout on
  a stock macOS 26 install with no state from the host dev
  environment.
- **Release-test VM:** (once release-test scripts land) — a
  built `Steading.app` launches and runs against a completely
  untouched macOS install matching an end user's machine, with
  no developer tooling seeded in.

## What this does NOT test (yet)

The full onboarding flow including SMAppService registration
and user approval of the privileged helper. That requires a
real Apple Development signing identity in the guest's login
keychain plus the one-time GUI click to approve the Login Item.
A separate script and snapshot workflow for that is the next
step after both smoke paths prove healthy.
