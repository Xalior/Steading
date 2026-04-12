# WIP: feature/builtin-service-controllers

**Branch:** `feature/builtin-service-controllers`
**Started:** 2026-04-12
**Status:** In Progress

## Plan

Full plan lives in `/Users/darran/.claude/plans/smooth-swimming-meerkat.md`
(local to the session machine). Summary:

Make the built-in service Enable/Disable buttons actually work end-to-end
and make the dashboard reflect live active-service state.

### Tasks

- [ ] Change `BuiltInServiceRunner.enableCommand`/`disableCommand`
  (single `[String]?`) to `enableCommands`/`disableCommands`
  (sequence `[[String]]?`), because `launchctl enable` alone doesn't
  start a daemon — SMB and Screen Sharing need a follow-up
  `launchctl kickstart`.
- [ ] Update all 8 runner definitions in `BuiltInServiceRegistry.swift`
  to use the new field shape. Add kickstart/kill sequences for SMB and
  Screen Sharing.
- [ ] Update `BuiltInServiceDetailView.apply()` to iterate over the
  command sequence and bail on the first failure. Fix the button
  disabled checks and the "no commands" fallback branch.
- [ ] Make `DashboardView` re-read all runner states whenever the user
  navigates back to it (use `.task(id: appState.selection)`).
- [ ] Add a subtle visual highlight to dashboard cards whose service
  is actively enabled, so the user can scan for "what's on" at a
  glance.
- [ ] Update any tests that reference the old `enableCommand` /
  `disableCommand` field names.
- [ ] `xcodebuild build` + full test suite green.
- [ ] Live verification on host: click Enable SSH → helper registers
  change → dashboard card flips to green "on" on return.

## Progress Log

### 2026-04-12 — branch created
- Cut `feature/builtin-service-controllers` from `main` at
  `4e9c528` (the window-reopen-after-red-button-close fix).
- WIP plan tracker initialised.

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

## Blockers

None currently.

## Commits

(will be appended as work lands)
