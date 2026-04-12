# WIP — feature/hosts-file-editor

## Goal

Let the owner edit `/etc/hosts` from inside Steading without dropping to
a terminal, without destroying comments or commented-out entries, and
without widening the privileged helper's security boundary beyond what
the existing executable allowlist already guarantees.

## Context

`/etc/hosts` is owned by `root:wheel` and not writable by the logged-in
user. Today the helper only knows how to *run allowlisted executables*
(systemsetup, launchctl, etc.) — it has no API for writing files. Naïvely
adding a generic `writeFile(path:data:)` would break the allowlist model
by letting any code-sign-verified client overwrite arbitrary paths.

Scope narrowed to: **raw text editor UX** (user pastes/edits whole file,
preservation is their responsibility) + **purpose-built helper method**
(path hard-coded to `/etc/hosts`, atomic write, size cap). A structured
editor that parses comments was considered and deferred.

Branched from `feature/builtin-service-controllers` (not `main`) because
that work's dashboard/catalog/helper scaffolding is needed underneath
and hasn't merged yet.

## Design decisions

- **Narrow helper API, not generic.** `writeHostsFile(content:withReply:)`
  on `SteadingPrivHelperProtocol`. No `writeFile` method, no path
  parameter. Adding `/etc/pf.anchors/steading` later = a separate
  named method, not a path-allowlist expansion. This keeps the security
  story per-method instead of per-data.
- **Atomic write.** Helper writes to `/etc/hosts.steading-new` then
  `rename(2)` into place. `chmod 0644` + `chown root:wheel` explicitly
  on the temp file before rename so the rename lands with correct
  ownership/mode regardless of umask.
- **Size cap: 1 MiB.** `/etc/hosts` is typically <10 KB. 1 MiB is
  generous while keeping a DoS ceiling.
- **UTF-8 only, no BOM.** Content crosses XPC as `Data`; helper
  writes bytes verbatim. UI is a SwiftUI `TextEditor` which produces
  UTF-8 `String` natively.
- **Client-side signature pinning (new).** Add
  `conn.setCodeSigningRequirement(...)` in `PrivHelperClient.connect()`
  pinning the helper to bundle id `com.xalior.Steading.privhelper` and
  team OU `M353B943AK`. Closes the symmetric gap: helper already pins
  clients, this pins the helper. macOS 13+ API, we're 13+ anyway.
- **Protocol version bump** from `0.0.1` → `0.0.2` since the XPC
  surface changed.

## Files touched

- [app/Steading/Shared/SteadingPrivHelperProtocol.swift](../../app/Steading/Shared/SteadingPrivHelperProtocol.swift)
  — new `writeHostsFile` method, version bump
- [app/SteadingPrivHelper/PrivHelperService.swift](../../app/SteadingPrivHelper/PrivHelperService.swift)
  — implementation (temp + rename, chmod/chown, size cap)
- [app/Steading/App/PrivHelperClient.swift](../../app/Steading/App/PrivHelperClient.swift)
  — `writeHostsFile(_:)` wrapper, `setCodeSigningRequirement` on
  connection
- [app/Steading/App/SteadingApp.swift](../../app/Steading/App/SteadingApp.swift)
  — `CommandMenu("Tools")` with **Edit /etc/hosts…**, new
  `Window` scene `hosts-editor`
- [app/Steading/Views/HostsEditorView.swift](../../app/Steading/Views/HostsEditorView.swift)
  — new file. TextEditor + Load/Save/Cancel + error banner
- [app/SteadingTests/](../../app/SteadingTests/) — add round-trip test
  against real `/etc/hosts`
- [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md) — document mutual
  code-sign pinning so future agents don't reason about the XPC
  surface as if either end is trusting anonymous peers

## Verification

- `xcodebuild build` clean.
- `xcodebuild test` green (new round-trip test included).
- Manual: launch app, Tools → Edit /etc/hosts…, confirm current file
  loads, make a no-op save, verify `/etc/hosts` byte-identical
  afterward (`diff` against backup). Then add a comment line, save,
  verify it landed and permissions stayed `-rw-r--r-- root:wheel`.

## Progress log

- 2026-04-12: branch cut from `feature/builtin-service-controllers`,
  plan drafted.
- 2026-04-12: ARCHITECTURE.md updated with mutual-pinning threat
  model and file-mutation rationale (commit `7553e38`).
- 2026-04-12: client-side `setCodeSigningRequirement` landed in
  `PrivHelperClient.connect()` (commit `2f55e62`).
- 2026-04-12: `writeHostsFile` XPC method added; protocol bumped to
  `0.0.2` (commit `9893837`).
- 2026-04-12: Tools menu + `HostsEditorView` window scene wired up
  in `SteadingApp` (commit `26384a3`).
- 2026-04-12: atomic-write refactor into `Shared/HostsFileWriter` +
  6 round-trip / boundary tests (commit `f0cbe45`).
- 2026-04-12: build green, full test suite 55/55 passing including
  the new `HostsFileWriter` suite. Manual `/etc/hosts` write
  verification deferred to next at-desk session (requires the
  helper to be registered and the user to click Save in the UI).
- 2026-04-12: added `XPCIntegrationTests` suite — 8 tests covering
  end-to-end `PrivHelperClient` ↔ `PrivHelperService` round trips
  via an anonymous `NSXPCListener`. Refactored `PrivHelperClient`
  to accept an injected connection factory so tests wire it to an
  in-process listener endpoint without touching launchd. Test
  target now compiles `PrivHelperService.swift` directly (conditional
  `@testable import Steading` guarded by `STEADING_TEST_HOST` flag).
  Full suite: 63/63 passing.
