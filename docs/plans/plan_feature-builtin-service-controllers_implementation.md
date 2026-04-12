# WIP: feature/builtin-service-controllers

**Branch:** `feature/builtin-service-controllers`
**Started:** 2026-04-12
**Status:** Complete

## Plan

Full plan lives in `/Users/darran/.claude/plans/smooth-swimming-meerkat.md`
(local to the session machine). Summary:

Make the built-in service Enable/Disable buttons actually work end-to-end
and make the dashboard reflect live active-service state.

### Tasks

- [x] Change `BuiltInServiceRunner.enableCommand`/`disableCommand`
  (single `[String]?`) to `enableCommands`/`disableCommands`
  (sequence `[[String]]?`), because `launchctl enable` alone doesn't
  start a daemon — SMB and Screen Sharing need a follow-up
  `launchctl kickstart`.
- [x] Update all 8 runner definitions in `BuiltInServiceRegistry.swift`
  to use the new field shape. Add kickstart/kill sequences for SMB and
  Screen Sharing.
- [x] Update `BuiltInServiceDetailView.apply()` to iterate over the
  command sequence and bail on the first failure. Fix the button
  disabled checks and the "no commands" fallback branch.
- [x] Make `DashboardView` re-read all runner states whenever the user
  navigates back to it (use `.task(id: appState.selection)`).
- [x] Add a subtle visual highlight to dashboard cards whose service
  is actively enabled, so the user can scan for "what's on" at a
  glance.
- [x] Update any tests that reference the old `enableCommand` /
  `disableCommand` field names. (None did — tests never referenced
  those fields directly.)
- [x] `xcodebuild build` + full test suite green. 49/49 pass.
- [x] Live verification on host: click Enable Content Caching →
  helper runs AssetCacheManagerUtil activate as root →
  `AssetCacheManagerUtil status` flips from `Activated: false` to
  `Activated: true`. Click Disable → flips back. End-to-end XPC
  pipeline works.

## Progress Log

### 2026-04-12 — branch created
- Cut `feature/builtin-service-controllers` from `main` at
  `4e9c528` (the window-reopen-after-red-button-close fix).
- WIP plan tracker initialised.

### 2026-04-12 — runner + registry refactor
- Renamed `enableCommand` → `enableCommands` (and disable variant)
  on `BuiltInServiceRunner`. Commit `7b6049e`.
- Rewrote all 8 runner definitions. SMB and Screen Sharing now use
  a `launchctl enable` → `launchctl kickstart -k` sequence on enable,
  and a `launchctl disable` → `launchctl kill SIGTERM` sequence on
  disable. Commit `994521b`.

### 2026-04-12 — detail view iterates sequence
- `BuiltInServiceDetailView.apply()` now loops over the command
  sequence and bails on the first non-zero exit. Error message
  includes the invoked argv for quick debugging when a multi-step
  sequence breaks partway through. Commit `565ce0d`.

### 2026-04-12 — dashboard refresh + active highlight
- `.task(id: appState.selection)` re-fires every time the user
  navigates back to the dashboard, re-probing all 8 runner states
  concurrently.
- Cards for services currently ON (state `.enabled` or
  `.custom(isOn: true)`) get a gradient-tinted background and
  thicker stroke so the active services pop out. Commit `0e43831`.

### 2026-04-12 — live verification
- Launched the rebuilt app, navigated to Content Caching detail,
  clicked Enable. Verified via `AssetCacheManagerUtil status` that
  `Activated` flipped `false` → `true`, confirming the full XPC
  pipeline runs the command as root.
- Clicked Disable, verified the flag flipped back to `false`.
- Re-enabled and re-disabled to restore original state.
- All 49 tests still pass.

## Decisions & Notes

**Why a sequence of commands rather than one-shot?** On macOS,
`launchctl enable system/<label>` only flips the override — the daemon
stays stopped until boot unless we `launchctl kickstart` it. Without
this, clicking "Enable SMB" would LOOK correct in the detail view (the
override-list probe reports "enabled") but smbd wouldn't actually be
running. Modelling the commands as a sequence also future-proofs us
for services where enable is a multi-step dance (e.g. a Power
Management 24/7 preset that flips several `pmset` keys).

**Allowlist:** no changes needed. The helper's allowlist gates on
executable path, not arguments, so `/bin/launchctl kickstart|kill`
are already permitted.

**Dashboard refresh strategy:** using SwiftUI's `.task(id:)` with
`appState.selection` as the id is cheaper than a shared state model.
The unprivileged probes take <100ms each running concurrently, so
re-reading all 8 on return is effectively free, and we get the real
system state every time rather than trusting cached UI state.

**Live verification target:** Content Caching was chosen as the
safest live-toggle service — toggling it has no effect on remote
access, SSH, or any user-visible workflow, unlike SSH or Screen
Sharing. The `AssetCacheManagerUtil status` command is cheap and
gives an unambiguous before/after reading.

## Blockers

None.

## Commits

- `83d3c4c` — wip: start builtin-service-controllers — init progress tracker
- `7b6049e` — refactor(runner): accept a sequence of commands for enable/disable
- `994521b` — feat(registry): kickstart+kill for SMB and screen sharing
- `565ce0d` — feat(detail): apply() iterates command sequence with short-circuit
- `0e43831` — feat(dashboard): auto-refresh on return + active-service highlight
