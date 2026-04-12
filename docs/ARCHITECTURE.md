# Architecture

How Steading is built. Read [DESIGN.md](../DESIGN.md) first for *what*
Steading is and *why* — this document is about *how* the code
delivers it.

## Overview

Steading is two binaries shipped inside one app bundle:

```
Steading.app/
├── Contents/
│   ├── MacOS/
│   │   ├── Steading                          ← main SwiftUI app (unprivileged)
│   │   └── SteadingPrivHelper                ← privileged helper tool
│   └── Library/
│       └── LaunchDaemons/
│           └── com.xalior.Steading.privhelper.plist
```

The main app is a regular non-sandboxed GUI SwiftUI application. It
has no elevated permissions of its own. Every root operation is
dispatched to the privileged helper, which runs as a LaunchDaemon
managed by `launchd` after the user approves it once via
`SMAppService`.

This split is non-negotiable: it's what DESIGN.md § Technical
realities calls for, and it's what lets Steading ship as a notarized
Developer ID app without asking the user to install anything with
`sudo` by hand.

## Repository layout

```
Steading/
├── DESIGN.md                      ← product design (gold master)
├── README.md                      ← entry point for readers
├── CLAUDE.md                      ← agent-specific operating notes
├── LICENSE                        ← MIT
│
├── app/
│   ├── project.yml                ← xcodegen project definition
│   ├── Steading.xcodeproj         ← generated from project.yml
│   ├── Steading/                  ← main app target sources
│   │   ├── App/                   ← @main, AppDelegate, AppState
│   │   ├── Model/                 ← BrewDetector, built-in service runners, ProcessRunner
│   │   ├── Views/                 ← SwiftUI views
│   │   ├── Shared/                ← compiled into BOTH targets (XPC protocol, allowlist)
│   │   ├── Resources/
│   │   │   └── LaunchDaemons/     ← embedded plist for SMAppService
│   │   ├── Assets.xcassets
│   │   └── Steading.entitlements
│   ├── SteadingPrivHelper/        ← privileged helper target sources
│   │   ├── main.swift             ← NSXPCListener entry
│   │   ├── PrivHelperListenerDelegate.swift
│   │   └── PrivHelperService.swift
│   └── SteadingTests/             ← Swift Testing unit tests
│
├── scripts/                       ← VM harness
│   ├── vm-up.sh                   ← clone base, boot headless, wait for reachability
│   ├── vm-smoke.sh                ← in-VM build + test
│   └── vm-down.sh                 ← tear down a working clone
│
├── tart/                          ← repo-local TART_HOME (gitignored)
│   ├── cache/OCIs/                ← pulled base images (gold masters)
│   ├── vms/                       ← working VM clones
│   └── README.md
│
└── docs/
    ├── ARCHITECTURE.md            ← this file
    └── plans/                     ← per-branch WIP trackers
```

## The app

### Scene graph

`SteadingApp` has two scenes:

- `Window("Steading", id: "main")` — the main application window.
  Dispatched by `isReady`:
  - `isReady == false` → `OnboardingView`
  - `isReady == true`  → `ContentView` with `NavigationSplitView`
- `MenuBarExtra("Steading", systemImage: "house.fill")` — a menu bar
  item exposing **Open Steading…** and **Quit Steading**.

A small private `WindowBridge` view captures SwiftUI's
`@Environment(\.openWindow)` and stores it as a closure on
`AppDelegate` so the dock-click reopen path
(`applicationShouldHandleReopen`) can recreate the window after the
user closes it with the red button. SwiftUI's Window scene destroys
the NSWindow on red-button close, so hunting for an NSWindow in
`NSApplication.shared.windows` doesn't work — the closure is the
supported path.

### AppState

`@Observable @MainActor final class AppState` owns:

- `brewCheck: BrewCheckState` — idle / checking / ready(BrewDetector.Status)
- `helperCheck: HelperCheckState` — idle / checking / ready(HelperStatus)
- `registrationError: String?`
- `selection: CatalogItem.ID?` — drives the NavigationSplitView detail
- Methods: `refreshBrewStatus()`, `refreshHelperStatus()`,
  `registerHelper()`
- Computed `isReady: Bool` — true iff brew is installed AND the
  helper is registered and enabled. Drives the onboarding→main-UI
  transition.

`isReady` and `mapHelperStatus(_:)` are exposed as pure static
helpers specifically so tests can exercise them directly with canned
inputs.

### Onboarding

`OnboardingView` shows two prerequisite cards:

- **Homebrew** — read-only status (install flow is future work).
- **Privileged Helper** — state-driven actions:
  - `.notRegistered` → **Register** button calls
    `SMAppService.daemon(plistName:).register()`
  - `.requiresApproval` → **Open Login Items…** + **Re-check**
  - `.enabled` → dismissed; SwiftUI transitions to ContentView

A `didBecomeActive` notification observer re-reads helper status when
the app comes forward — so the moment the user Cmd-Tabs back from
System Settings after flipping the Login Items toggle, `isReady`
flips true and the main UI appears without any further clicks.

### Main UI

`ContentView` hosts a `NavigationSplitView`:

- **Sidebar** (`SidebarView`) — a Dashboard row at the top, then
  three sections: Services, Webapps, macOS Built-ins. Selection
  binding is `CatalogItem.ID?`; the Dashboard row uses the reserved
  sentinel `CatalogItem.dashboardTag` so ContentView routes either
  `nil` or the sentinel to the Dashboard.
- **Detail pane** — dispatches on the selected item's kind:
  - `.builtIn` + registered runner → `BuiltInServiceDetailView`
  - `.service` or `.webapp` → `CatalogDetailView` (placeholder)
  - Default → `DashboardView`

### Catalogs

Catalog data lives in three `enum`s, each exposing a static
`[CatalogItem]`:

| Enum | Items |
|------|-------|
| `ServiceCatalog` | Caddy, PHP-FPM, MySQL, Redis, Tailscale (optional), Stalwart (optional) |
| `WebappCatalog` | MediaWiki, WordPress, DokuWiki |
| `BuiltInCatalog` | SMB, Time Machine Server, SSH, Screen Sharing, Firewall, Printer Sharing, Power Management, Content Caching |

These are dummy data today — the real implementation will load from
per-item definition files (DESIGN.md § Definition files). The
structure is stable enough to keep using.

### Built-in service runners

`BuiltInServiceRunner` is the bridge between a catalog item and the
real macOS facility:

```swift
struct BuiltInServiceRunner: Sendable {
    let id: String
    let displayName: String
    let detectionNote: String
    let readState: @Sendable () async -> BuiltInServiceState
    let enableCommands: [[String]]?
    let disableCommands: [[String]]?
}
```

Key points:

- **`readState`** hits the real system via unprivileged probes —
  `launchctl print-disabled system`, `socketfilterfw
  --getglobalstate`, `cupsctl`, `pmset -g`,
  `AssetCacheManagerUtil status`. None of these need root.
- **`enableCommands` / `disableCommands`** are *sequences* of argv
  arrays, not single commands. Some services need multiple steps to
  take immediate effect — e.g. SMB and Screen Sharing need
  `launchctl enable system/<label>` followed by
  `launchctl kickstart -k system/<label>` because the first flips
  the override plist but doesn't start the daemon. The detail view's
  apply loop bails on the first non-zero exit.
- Commands are executed via the privileged helper (see below).

`BuiltInServiceRegistry.all` maps catalog item ids to runners.
Power Management and Time Machine Server have `readState` but `nil`
commands — they're display-only because their "enable" is a
multi-setting change that needs its own UI.

### Dashboard

`DashboardView` is the default detail pane (shown when selection is
`nil` or the Dashboard sentinel). It queries all built-in runners
concurrently via `withTaskGroup` on appear, and re-fires via
`.task(id: appState.selection)` any time the user navigates back to
it. Cards for services currently ON get a gradient-tinted background
and thicker stroke so the enabled set stands out at a glance.
Tapping a card sets `appState.selection` to the item's id, which
drives the detail pane to the service's full view.

### Built-in service detail view

`BuiltInServiceDetailView` shows a header, a summary card, a state
card (live, re-read on appear and after each change), an actions
card with Enable/Disable buttons gated on current state, and a
detection footer explaining what `readState` probes. The `apply()`
helper iterates the runner's command sequence, routes each command
through `PrivHelperClient.runCommand`, and re-reads state on success.
Errors include the invoked argv so multi-step failures are diagnosable.

## The privileged helper

### Registration

The helper is registered with launchd via `SMAppService`
(macOS 13+). The main app:

1. Calls `SMAppService.daemon(plistName: "com.xalior.Steading.privhelper.plist")`
2. Calls `.register()` — the first time, this lands the daemon in
   pending-approval state.
3. Surfaces `.requiresApproval` to the user with an **Open Login
   Items…** button that takes them to System Settings.
4. Re-polls status when the app comes forward via
   `didBecomeActive` — once the user approves, registration
   persists across reboots until the user explicitly disables it.

The `LaunchDaemon` plist is shipped *inside* the app bundle at
`Contents/Library/LaunchDaemons/com.xalior.Steading.privhelper.plist`.
SMAppService reads it from there. Keys:

- `Label` = `com.xalior.Steading.privhelper`
- `BundleProgram` = `Contents/MacOS/SteadingPrivHelper` (relative to
  app bundle; NOT the bundle identifier, because a `.privhelper`
  suffix would be parsed as a filename extension by `codesign`)
- `MachServices` = `{ com.xalior.Steading.privhelper: true }`
- `AssociatedBundleIdentifiers` = `[com.xalior.Steading]`

### XPC protocol

Both the main app and the helper compile `Steading/Shared/`, which
contains:

- `SteadingPrivHelperProtocol` — the `@objc` protocol with two
  methods: `runCommand(executable:arguments:withReply:)` and
  `helperVersion(withReply:)`.
- `PrivHelperAllowlist` — the set of executables the helper is
  willing to run.
- The mach service name constant and helper version string.

Since both targets compile these files independently, each has its
own runtime copy. XPC crosses the boundary via `@objc` selectors —
the two copies just need to agree on protocol shape.

### Client verification

`PrivHelperListenerDelegate.listener(_:shouldAcceptNewConnection:)`
rejects any connection whose code signature doesn't match:

```
identifier "com.xalior.Steading" and anchor apple generic and
certificate 1[field.1.2.840.113635.100.6.2.1] exists and
certificate leaf[subject.OU] = "M353B943AK"
```

This is the entire security boundary between the main app and root —
only processes signed by the Steading team, with the Steading
bundle id, can talk to the helper. The check uses
`SecCodeCopyGuestWithAttributes` against the connecting client's
audit token (from `NSXPCConnection.auditToken` via KVC, which is
public API but not Objective-C visible).

### Allowlist

Even with a verified client, the helper refuses to run arbitrary
commands. `PrivHelperAllowlist.isAllowed` gates every invocation:

- Executable must be an absolute path (no relative, no `..`
  traversal).
- Executable must be in the static `allowedExecutables` set:
  `/usr/sbin/systemsetup`, `/bin/launchctl`,
  `/usr/bin/AssetCacheManagerUtil`,
  `/usr/libexec/ApplicationFirewall/socketfilterfw`,
  `/usr/sbin/cupsctl`, `/usr/bin/pmset`.

Arguments are not currently restricted. Tightening the allowlist to
gate specific argument patterns is a future hardening step.

### Client lifecycle

`PrivHelperClient` is a `@MainActor` singleton that owns one
long-lived `NSXPCConnection(machServiceName:options: .privileged)`
to the helper. On invalidation or interruption the connection is
cleared and the next `runCommand` call creates a fresh one.
`launchd` manages the helper process's lifetime on the other side —
it's spawned on demand when the first connection opens, and torn
down when idle per the plist's policy.

## Testing

### Unit tests

Swift Testing (`@Suite`, `@Test`, `#expect`). 49 tests across 4
suites. **All tests exercise production code directly** — no stubs
that reimplement logic. Patterns:

- **Pure function tests** — `BrewDetector.parseVersion`,
  `BuiltInServiceRunner.parseLaunchdOverride`,
  `BuiltInServiceRunner.pmsetValue`, `PrivHelperAllowlist.isAllowed`,
  `AppState.mapHelperStatus`, `AppState.isReady` are all `public
  static` and tested by calling them directly with canned inputs.
- **Live integration tests** — `BrewDetector.detect`,
  `BuiltInServiceRunner.ssh.readState`, etc. hit the real
  filesystem and run real system commands on the dev mac.
- **Boundary-input tests** — construct the real production type
  with boundary values (empty `searchPaths`, nonexistent paths) to
  exercise the `.notFound` / `.error` branches without faking the
  logic.

### VM clean-room testing

`scripts/` harnesses two Tart base images pulled from
`ghcr.io/cirruslabs`:

| Image | Size | Guest channel | Use case |
|-------|------|---------------|----------|
| `macos-tahoe-xcode:26.4` | ~140 GB | `tart exec` (guest agent) | Build-test. Fresh checkout → xcodegen → xcodebuild build + test. |
| `macos-tahoe-vanilla:26.4` | ~50 GB | `ssh admin@<ip>` via sshpass | Release-test. Matches a real user's machine with no dev tools. |

`TART_HOME` is pinned to `<repo>/tart/` so all image blobs live on
the repo's volume, not the boot disk. The gold masters in
`tart/cache/OCIs/` are never mutated — every working VM is a CoW
clone at `tart/vms/<name>/` that gets destroyed at the end of each
test.

The smoke script mounts the repo read-only into the VM via
virtio-fs at `/Volumes/My Shared Files/Steading`, copies it to
`~/build` inside the guest (so DerivedData stays in the VM), then
builds with ad-hoc signing to verify the repo is self-contained.

## Distribution

Steading is designed to be distributed two ways:

1. **Direct download** from GitHub releases — drag the `.app`
   bundle to `/Applications`.
2. **`brew install --cask xalior/steading/steading`** from the
   Homebrew tap.

Both paths end at `/Applications/Steading.app`. Onboarding detects
which path was used and short-circuits any setup that's already in
place (brew present, tap added).

The Steading app bundle is signed with a Developer ID Application
identity, hardened runtime on, notarized for Gatekeeper. The
privileged helper is signed with the same team and an explicit
`--identifier` (via `OTHER_CODE_SIGN_FLAGS`) to prevent `codesign`
from misreading the `.privhelper` filename suffix as an extension.

The tap at `xalior/homebrew-steading` serves two purposes: hosting
the Steading cask, and providing formulae for anything Steading
needs that isn't in `homebrew-core` (starting with the chosen mail
server).

## Design constraints

Decisions that are fixed by [DESIGN.md](../DESIGN.md) and should not
be reopened without updating the design doc first:

- **Not sandboxed.** The main app needs to talk to a non-sandboxed
  privileged helper, and hardened runtime alone is enough for
  notarization. App Store distribution is explicitly not a target.
- **LaunchDaemons, not LaunchAgents.** Every service Steading
  installs must survive the owner logging out, the machine
  rebooting, and power cuts. Per-user `LaunchAgents` fail this
  requirement; `brew services` is explicitly rejected for the same
  reason.
- **Adopts existing Homebrew.** No parallel brew install, no
  `_steading` user. Steading manages services within whatever brew
  the owner already has.
- **One blessed implementation per service category.** No
  "Caddy or Nginx or Traefik" decision trees — the catalog is
  deliberately curated.
- **Owner decides policy, Steading warns.** Firewall rules, SSH
  exposure, port 25/80 — Steading never refuses an owner's choice,
  but warns context-aware on footguns.
