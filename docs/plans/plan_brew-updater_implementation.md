---
status: In Progress
source: docs/discovery/discovery_brew-updater.md
---

# Plan + WIP tracker: brew-updater

**Status:** In Progress
**Branch:** `feature/brew-updater`
**Source:** [docs/discovery/discovery_brew-updater.md](../discovery/discovery_brew-updater.md)

This file is both the plan (authoritative scope below, from "## Overview"
onward — unchanged from the doc that was committed in `dce25b7`) and the
living WIP tracker for the feature branch, matching the repo convention
set by [plan_hosts-file-editor_implementation.md](./plan_hosts-file-editor_implementation.md).
Plan sections are immutable for this session; tracker sections below are
updated continuously.

## Preflight Decisions

- **Branch:** `feature/brew-updater`, cut from `main` at 8c2e98a.
- **Baseline verification:** `xcodebuild -project Steading.xcodeproj
  -scheme Steading -configuration Debug -destination
  'platform=macOS,arch=arm64' -enableCodeCoverage NO test` against `main`
  — TEST SUCCEEDED, 63 tests across 6 suites (2026-04-23).
- **Tracker layout:** `single` — one tracker (this file), one sprint
  covering all 5 phases (explicit user election). Implication: all manual
  verification steps across Phases 1–5 are performed at the end of the
  sprint, not at per-phase boundaries. The Phase 4 pre-implementation
  sudo-propagation gate is plan-instructed and is honoured in-stream
  before any Phase 4 code is written — it is not a sprint boundary.
- **Plan-deferred decisions:** none. The plan uses "implementer's
  discretion" for several shape choices (preferences store mechanism,
  parser signature, menu-bar label visual composition, list-kind
  rendering); those are intentional implementation-time calls, not
  deferred choices to resolve upfront.

## Sprints

### Sprint 1: brew-updater end-to-end

- **Covers:** Phases 1–5 in full.
- **Success Criteria:** the union of each phase's Automated and Manual
  criteria as written below — no additions, no substitutions.
  Phase-level cumulative gates are checked as each phase's last code
  lands; the sprint does not complete until every phase's criteria are
  verified.
- **Status:** in progress (opened 2026-04-23)

## Tasks

- [ ] Sprint 1: brew-updater end-to-end
    - [x] Phase 1 (code): Makefile, PreferencesStore, PreferencesView,
          Settings scene — automated SCs green. Manual SCs deferred to
          sprint-end.
    - [ ] Phase 2: Check pipeline, singleton manager, bottom status strip
    - [ ] Phase 3: Brew Package Manager window + Apply (non-sudo path)
    - [ ] Phase 4: sudo-during-upgrade PoC (gated by in-stream
          pre-implementation verification)
    - [ ] Phase 5: dock badge, menu bar label, system banner

## Progress Log

- **2026-04-23** — Branch cut from `main` at 8c2e98a; baseline test suite
  green (63 tests). Tracker sections layered onto the existing plan
  doc per repo convention. Sprint 1 opened. Starting Phase 1.
- **2026-04-23** — Phase 1 code landed. `make -C app build/test` green
  (71 tests, 7 suites; +8 prefs tests, +1 suite). Starting Phase 2.

## Decisions & Notes

## Blockers

## Commits

---

# Plan (authoritative)

## Overview

Add a brew update workflow to Steading: periodic `brew update && brew
outdated` checks, a bottom status strip surfacing the pending-update
count, a **Brew Package Manager** window for review and upgrade, three
opt-in notification channels for the count (dock badge, menu bar label,
system banner), and a Preferences scene controlling cadence and
channels. Scope is the **regular** update-and-install cycle; irregular
brew actions stay CLI-driven.

## Current State

- [app/Steading/Model/BrewDetector.swift](../../app/Steading/Model/BrewDetector.swift)
  only probes for brew presence + version — no `brew update` / `brew
  outdated` code exists.
- [app/Steading/Model/ProcessRunner.swift:20-45](../../app/Steading/Model/ProcessRunner.swift#L20-L45)
  collects subprocess output to completion; no streaming API.
- No scheduler / periodic task infrastructure. `AppState` uses
  `@Observable` (main-actor) and currently only fires a one-shot
  `refreshBrewStatus()` from `SteadingApp`'s `.task`
  ([app/Steading/App/SteadingApp.swift:19-22](../../app/Steading/App/SteadingApp.swift#L19-L22)).
- No `Settings { }` scene, no UserDefaults wrapper, no preferences UI.
- No `UNUserNotificationCenter` usage anywhere in the codebase.
- Tools menu has a single entry — Edit /etc/hosts… —
  at [app/Steading/App/SteadingApp.swift:57](../../app/Steading/App/SteadingApp.swift#L57).
- `MenuBarExtra` uses a static `"Steading"` string as its label
  ([app/Steading/App/SteadingApp.swift:42](../../app/Steading/App/SteadingApp.swift#L42)).
- Main window is a `NavigationSplitView` with no `.safeAreaInset`
  modifier ([app/Steading/Views/ContentView.swift:9-14](../../app/Steading/Views/ContentView.swift#L9-L14)).
- Privileged helper allowlist does not contain `brew`, and should not
  need to — see Key Discoveries.

## Desired End State

- Steading runs a check on launch (toggleable) and every `interval`
  (default 24h) thereafter; the last-check timestamp persists across
  launches and is consulted on startup so an overdue check fires
  immediately when check-on-launch is off.
- The main window's bottom strip shows one of: `"N pending updates"`,
  `"Checking…"`, `"Last check failed: …"`, or (when nothing is
  pending) is empty — a narrow context-aware status channel.
- Dock badge, menu bar label beside the house icon, and a
  fixed-identifier system notification each independently reflect the
  count when enabled in Preferences.
- Tools → Brew Package Manager opens a window listing outdated
  packages with per-row checkboxes, Mark All Upgrades, Apply, and
  Check Now. Apply runs `brew upgrade <marked…>` as a single
  invocation with a progress bar and a disclosure-triangle "More
  details" view streaming live output. Upgrades that prompt for sudo
  mid-run succeed via a PoC password mechanism.
- Preferences scene offers: interval override, three independent
  notification-channel toggles, Check on launch toggle.

## Key Discoveries

- **Brew runs as the user, not via the privileged helper.** Brew
  itself refuses to run as root; the sudo-during-upgrade problem is a
  separate concern handled in-process, not by widening the helper's
  allowlist. No XPC protocol changes or version bumps for this
  feature.
- **`brew outdated --json=v2`** returns a typed list of outdated
  formulae and casks, safer to parse than the tabular default.
- **ProcessRunner is non-streaming.** The live-output view in Apply
  needs a new streaming runner. Designed with a bail-out-to-human
  posture for unexpected subprocess states. Potentially reusable for
  a future `brew install` bootstrap at app first-run.
- **`MenuBarExtra`'s first string argument IS the label** shown
  beside the icon — a computed binding flips the whole label
  ("Steading" ↔ "Steading – 7") without new API.
- **Fixed `UNNotificationRequest` identifier** makes Notification
  Center replace the entry on each post rather than stack, matching
  discovery's "daily reminder, single entry" requirement.

## What We're NOT Doing

From the discovery's Scope (out):

- Installing new (not-already-installed) packages from Steading.
- Uninstalling packages.
- Managing brew taps (add/remove/list).
- A dedicated "upgrade brew itself" action distinct from the normal
  update cycle.
- Synaptic-aspirational surroundings (sidebar sections, origin /
  architecture / custom filters, search box, per-package details
  pane, screenshots / changelogs) — absent, not stubbed.

Additional implementation boundaries, decided here:

- No SecureInput panels, pty-driven prompt detection, or
  keychain-backed sudo retries. Explicit PoC scope in Phase 4.
- No brew in the privileged-helper allowlist; no XPC protocol
  version bump.
- No "stop on first failure" logic in Apply. Defer to brew's own
  behaviour (continues past individual failures, reports at end).
- No queuing of concurrent check / apply requests — the singleton
  manager rejects them outright while busy.

## Approach

Vertical slice per phase. Each phase is end-to-end and observable on
its own. Preferences ship first so downstream phases consume a single
settings store rather than hardcoded constants they later have to
unlearn.

A single `@MainActor` **singleton** (`BrewUpdateManager`) owns
check-pipeline and apply-pipeline state. The bottom strip, the Brew
Package Manager window, and the notification layer are all thin views
on that state. Concurrent check or apply requests are **rejected**
while the manager is busy — no queuing, no debouncing.

Tests are written red/green where practical: the failing test lands
(or at minimum is written) before the production code that turns it
green. Pure parsers stay `public static` and are tested with canned
inputs; live tests hit a real `brew` where safe (pure reads:
`brew --version`, `brew outdated --json=v2` — never `brew upgrade` in
CI). Boundary-input injection into real production code, not
parallel-reimplementation mocks. See CLAUDE.md's "Tests ALWAYS
exercise production code" rule and
[app/SteadingTests/BrewDetectorTests.swift](../../app/SteadingTests/BrewDetectorTests.swift)
as the pattern exemplar.

## Phase 1: Preferences scene and settings store

### Overview

Ship a macOS Preferences window wired up to a persistent settings
store, with no downstream consumers yet. Delivering prefs first means
Phases 2–5 bind to the real store from day one instead of using
hardcoded constants they later have to unlearn.

Scene is reachable via **Steading → Preferences…** (Cmd+,). Contents:
a single pane containing the four controls below. Preferences are the
app's first and only settings surface; no tab bar yet.

### Changes Required

Four preference keys must exist. The plan specifies name, type,
default, legal range; the store mechanism is at the implementer's
discretion.

| Key | Type | Default | Range / values |
|---|---|---|---|
| `checkIntervalHours` | Int | `24` | `1`–`168` (inclusive) |
| `checkOnLaunch` | Bool | `true` | — |
| `notifyDockBadge` | Bool | `true` | — |
| `notifyMenuBarLabel` | Bool | `true` | — |
| `notifySystemBanner` | Bool | `true` | — |

One further persisted value, not user-facing and not shown in the
Preferences UI but reachable from the same store:

| Key | Type | Default | Notes |
|---|---|---|---|
| `lastCheckAt` | Date? | `nil` | Updated by the check pipeline in Phase 2; read on startup to decide whether an interval has already elapsed |

Preferences UI layout (single pane, vertical `Form`):

- **Update checks** section
    - "Check interval" control bound to `checkIntervalHours` (hours,
      stepper or picker at implementer's choice; must enforce 1–168).
    - "Check on launch" checkbox bound to `checkOnLaunch`.
- **Notification style** section, with a one-line explanation
  ("Choose how Steading tells you updates are pending"):
    - "Show count on dock icon" → `notifyDockBadge`
    - "Show count in menu bar" → `notifyMenuBarLabel`
    - "Post system notification" → `notifySystemBanner`

New files (expected, though names are not binding — xcodegen picks
them up automatically via glob):

- A view file under [app/Steading/Views/](../../app/Steading/Views/)
  for the Preferences pane.
- A model file under [app/Steading/Model/](../../app/Steading/Model/)
  for the settings store (if one is needed — implementer's call).

Edits:

- [app/Steading/App/SteadingApp.swift](../../app/Steading/App/SteadingApp.swift)
  — add a `Settings { … }` scene alongside the existing `Window` and
  `MenuBarExtra` scenes. SwiftUI auto-wires the **Preferences…** menu
  item and Cmd+, shortcut when a `Settings` scene is present.

No other Steading source files are touched in this phase.

**Minimal Makefile (introduced this phase).** The repo has no
`Makefile` today; every later phase's automated criteria assume
`make -C app build` and `make -C app test`. Add
[app/Makefile](../../app/Makefile) with two targets that wrap the
invocations already documented in
[CLAUDE.md](../../CLAUDE.md)'s build-and-test cheatsheet:

- `build` → `xcodebuild -project Steading.xcodeproj -scheme
  Steading -configuration Debug -arch arm64
  ONLY_ACTIVE_ARCH=YES build`
- `test` → `xcodebuild -project Steading.xcodeproj -scheme
  Steading -configuration Debug -destination
  'platform=macOS,arch=arm64' -enableCodeCoverage NO test`

Not a phony scope-creep — the skill directs plans to add missing
Makefile targets. No functional change vs. the cheatsheet; just a
single stable entry point for future phases and CI.

### Success Criteria

#### Automated

- Unit test: each preference key's default value matches the table
  above, read through whatever store the implementer chose. (Red
  first: write the test asserting the default, see it fail, add the
  defaults, turn it green.)
- Unit test: interval clamping — writing `0` or `169` either refuses
  or clamps into `[1, 168]`; the stored value is always in range
  when read back.
- Unit test: round-trip — write each preference to a scratch
  UserDefaults suite, read back, assert the value matches what was
  written, for each of the six keys (including `lastCheckAt`).
- `make -C app build` and `make -C app test` both pass. (Phase 1
  introduces the minimal `app/Makefile` — see Changes Required.)

#### Manual

Human-observation steps only. CLI-verifiable details (console
warnings, preference round-trip through plist, clamp enforcement
on the stored value) are covered by Automated above.

- [ ] Launch the app. Menu bar shows **Steading → Preferences…**
      and Cmd+, opens the Preferences window.
- [ ] All five user-facing controls render, with defaults matching
      the table (24h, all three notification toggles on, Check on
      launch on).
- [ ] Interval control's UI visibly refuses to go below 1 or above
      168 (stepper greys out at bounds, picker has no entries
      outside range, etc.).
- [ ] Flip every control, quit the app, relaunch, reopen
      Preferences — every flipped value visibly persisted in the UI.

## Phase 2: Check pipeline, singleton manager, and bottom status strip

### Overview

The thin vertical slice that makes "pending updates" visible. A
singleton manager (`BrewUpdateManager`, main-actor, observable) owns
the check pipeline's state; the bottom status strip on ContentView
renders that state. Scheduler fires checks on launch (when
configured) and every interval thereafter. No window, no dock badge,
no menu bar label yet — just the strip.

Phase 2 ships shippable on its own: the user sees a live count after
launch and sees it refresh once the interval elapses.

### Changes Required

**Check definition.** One *check* is the two-step operation defined
in the discovery: `brew update` followed by `brew outdated --json=v2`.
Both must complete. The check succeeds iff both invocations exit
zero; the count is the number of entries in the JSON's `formulae`
plus `casks` arrays.

**Manager states** (observable, consumed by the strip and — in later
phases — by the window, dock, menu bar label, notification layer):

| State | When | What the strip shows |
|---|---|---|
| `.idle(count: 0)` | After a successful check with nothing pending | strip empty / hidden |
| `.idle(count: N)` where N>0 | After a successful check with pending packages | `"N pending updates"` (singular form when N=1) |
| `.checking` | During `brew update` or `brew outdated` | `"Checking…"` |
| `.failed(message)` | Last check failed (either step non-zero, or parse error, or brew missing at invocation) | `"Last check failed: <terse message>"` |

The manager also exposes the list of outdated packages (consumed by
Phase 3) — name, installed version, available version, kind
(formula vs cask). List is empty in `.idle(count: 0)` and `.failed`
states.

**Concurrency contract.** `.checking` is a UI-observable state, not
an error path. Callers (the scheduler, the Phase 3 Check Now
button) bind their availability to it — the button disables while
busy, the scheduler does not fire a tick while the previous tick is
still running. If an errant second `check()` call arrives while
busy (programmer error, racy scheduler, etc.) the manager silently
no-ops; no second brew invocation runs and no error is surfaced.

**Scheduler.** On app launch:

- If `checkOnLaunch` is `true` → fire a check immediately.
- Else if `lastCheckAt` is `nil` → fire immediately.
- Else if `now - lastCheckAt >= checkIntervalHours` → fire
  immediately.
- Else → wait `(lastCheckAt + checkIntervalHours) - now`, then fire.

**Retry / back-off on failure.** The manager distinguishes a check
*attempt* (one invocation chain of `brew update` + `brew outdated`)
from a check *settlement* (the end of a retry chain, whether the
chain succeeded or surrendered).

- If an attempt fails because brew ran and exited non-zero, the
  manager schedules a retry with exponential back-off:
  **1min → 2min → 4min → 8min → 15min** and capped at 15min for any
  further attempts. **Max 4 retries.** After the 4th retry fails,
  the chain surrenders — this is a settlement.
- During the chain the manager stays `.checking`; the strip shows
  `"Checking…"` throughout (no "retry 2/5" noise — matches the
  discovery's "terse" framing).
- `lastCheckAt` is written only on settlement: success, surrender,
  or the fail-fast cases below. The in-flight chain does not write
  it, so relaunching mid-chain sees the pre-chain timestamp and
  starts a new chain under the normal startup rules.
- The regular-interval tick does not fire while a chain is in
  flight. After settlement the next tick is scheduled at
  `settlement-time + checkIntervalHours`.
- Quitting the app cancels any pending retry. On relaunch, normal
  scheduler logic runs against the pre-chain `lastCheckAt`.
- Check Now (Phase 3) while a chain is in flight: the button is
  disabled — see Concurrency contract.

**Fail-fast cases (no retry).** Anything that is not "brew ran and
exited non-zero" settles immediately, writes `lastCheckAt`, and
surfaces `.failed`:

- Brew binary not executable (ENOENT, permission denied, path
  missing). This is treated as a *catastrophic* error — Steading
  depends on brew as a handled dependency, and mid-session
  disappearance is outside the retry model's scope. The strip
  surfaces a terse message; deeper recovery (e.g. flipping
  `AppState.isReady` back to drive re-onboarding) is out of scope
  for this phase.
- JSON parse failure on a zero-exit `brew outdated` output. This
  shouldn't happen in practice and indicates a bug or an
  incompatible brew version; retrying won't help.

**Parser.** A `public static` pure parser transforms
`brew outdated --json=v2` stdout (a `String` or `Data`) into
`[OutdatedPackage]`. Returns an empty array for the empty-JSON case;
throws or returns `nil` for malformed JSON so the manager can surface
`.failed`. Exact signature is the implementer's call; it must be
directly callable from a unit test with canned JSON input.

**Bottom status strip.** A new view rendered via
`.safeAreaInset(edge: .bottom)` on the root of
[app/Steading/Views/ContentView.swift](../../app/Steading/Views/ContentView.swift).
Single "well" (visually distinct but unobtrusive) containing the
strings from the table above. Hidden (or zero-height) when the state
is `.idle(count: 0)` so the strip does not occupy screen space while
there is nothing to report. Shown in OnboardingView: no. Strip is a
post-onboarding surface only.

**Files expected to change or be added:**

- New: model for `OutdatedPackage` and for the parser — under
  [app/Steading/Model/](../../app/Steading/Model/).
- New: the `BrewUpdateManager` singleton — under
  [app/Steading/Model/](../../app/Steading/Model/).
- New: the bottom status strip view — under
  [app/Steading/Views/](../../app/Steading/Views/).
- Edit:
  [app/Steading/Views/ContentView.swift](../../app/Steading/Views/ContentView.swift) —
  add `.safeAreaInset(edge: .bottom) { … }` binding to the manager's
  state.
- Edit:
  [app/Steading/App/SteadingApp.swift](../../app/Steading/App/SteadingApp.swift) —
  kick off the scheduler when the main scene's `.task` runs, after
  the existing `refreshBrewStatus()` / `refreshHelperStatus()`
  calls.
- Edit:
  [app/Steading/App/AppState.swift](../../app/Steading/App/AppState.swift) —
  hold a reference to the manager so views can reach it, or the
  manager is its own scene-scoped singleton the views pick up via
  `@Environment` — implementer's call which.

No XPC protocol changes. No helper version bump. No changes to the
allowlist. `brew` is invoked as the logged-in user via a plain
subprocess.

### Success Criteria

#### Automated

Tests written red/green: each failing test is written and run (and
seen to fail) before the production code that turns it green.

- Pure parser: parses a canned `brew outdated --json=v2` fixture
  with 2 formulae + 1 cask, returns exactly three `OutdatedPackage`
  values with correct names, versions, and kinds.
- Pure parser: empty-JSON fixture (`{"formulae": [], "casks": []}`)
  returns an empty array, not a failure.
- Pure parser: malformed-JSON fixture returns a failure (nil / throw
  / error — whichever shape the parser uses), not a crash and not an
  empty array.
- Scheduler decision: pure function `shouldFireOnStartup(lastCheckAt,
  interval, checkOnLaunch, now) -> Decision` covered with a table
  of (nil-timestamp, overdue, not-yet-due) × (checkOnLaunch on/off).
- Manager concurrency: invoke `check()` twice back-to-back; second
  call silently no-ops while the first is in flight; only one
  underlying brew invocation is spawned.
- Back-off schedule: pure function `nextRetryDelay(attempt: Int) ->
  Duration?` returns `1min, 2min, 4min, 8min, 15min` for attempts
  `1…5` and `nil` for attempt `6` (signalling surrender). Table
  test covers the full curve.
- Retry settlement: against a subprocess surface that returns
  non-zero three times then zero, the manager settles as success
  with exactly four attempts. Against a surface that returns
  non-zero five times, the manager settles as surrender with
  exactly five attempts. (Subprocess seam for test purposes is at
  the implementer's discretion — e.g. a shim script on PATH, a
  parameter on `ProcessRunner`, or a protocol the manager depends
  on — but the production code path under test must be the real
  retry logic, not a stand-in.)
- Live test: real `brew outdated --json=v2` against the dev
  machine's real brew; parser accepts the output; result is either
  an empty list or a list of real package names (test asserts
  shape, not specific packages). Skipped gracefully if brew is not
  installed on the test host.
- `make -C app build` and `make -C app test` both pass.

#### Manual

Human-observation steps only. State-setup commands in callouts are
for the implementer to run before the human eyeballs the result.
Concurrency behaviour and the settlement counts are covered in
Automated.

- [ ] Launch the app with `checkOnLaunch: true` (Phase 1 default).
      Within a few seconds, bottom strip visibly shows `"Checking…"`,
      then transitions to either `"N pending updates"` (matching
      `brew outdated` on the same machine) or empty when N=0.
- [ ] Strip is hidden / zero-height when count is 0 — no empty well
      occupying screen space.
- [ ] With brew temporarily made unexecutable, strip shows
      `"Last check failed: <terse message>"`.
      *Implementer setup:* `sudo chmod -x /opt/homebrew/bin/brew`
      before relaunch; `sudo chmod +x /opt/homebrew/bin/brew` after
      the observation.
- [ ] With `checkOnLaunch` off and `lastCheckAt` overdue (older
      than the interval), relaunching the app visibly fires a
      check immediately.
      *Implementer setup:* `defaults write com.xalior.Steading
      checkOnLaunch -bool false && defaults write
      com.xalior.Steading lastCheckAt -date '2020-01-01 00:00:00
      +0000' && killall cfprefsd`.
- [ ] With `checkOnLaunch` off and `lastCheckAt` recent,
      relaunching the app does NOT fire a check on start.
      *Implementer setup:* `defaults write com.xalior.Steading
      lastCheckAt -date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" && killall
      cfprefsd`.

## Phase 3: Brew Package Manager window and Apply

### Overview

Tools → **Brew Package Manager** opens a Synaptic-inspired window
listing the outdated packages the Phase 2 manager already knows
about, with per-row checkboxes, Mark All Upgrades, Check Now, and
Apply. Apply runs a single `brew upgrade <marked…>` invocation,
renders a progress bar primary surface, and expands on click to a
read-only live log of the subprocess's output.

Ships shippable for the *no-sudo* case — i.e. upgrades that don't
prompt for a password mid-run (which is most formulae). Upgrades
that do prompt will stall at the prompt in Phase 3; Phase 4 supplies
the PoC password mechanism that unblocks them.

This phase introduces the **streaming subprocess surface** the live
log needs. Scoped so a future "install brew at first run" flow can
reuse it — the surface is not brew-specific.

### Changes Required

**Window scene.** A new SwiftUI `Window` scene with a stable id
(`"brew-package-manager"` or similar), opened from a new entry in
`ToolsMenuContent` at
[app/Steading/App/SteadingApp.swift:53-61](../../app/Steading/App/SteadingApp.swift#L53-L61).
Pattern matches the existing hosts-editor wiring at
[app/Steading/App/SteadingApp.swift:35-40](../../app/Steading/App/SteadingApp.swift#L35-L40).

**Window contents (single pane, top-to-bottom):**

1. Optional header with a one-line status (`"7 pending updates"` /
   `"Checking…"` / `"Last check failed: …"`), binding to the
   manager's state — mirrors the bottom strip's messages so the
   user has one source of truth whether they look at the main
   window or this one.
2. The package list — one row per `OutdatedPackage`, each row
   showing:
   - A checkbox (marked / unmarked)
   - The package name
   - Installed version → available version (e.g. `1.2.3 → 1.3.0`)
   - Kind (formula / cask), rendered unobtrusively (badge, trailing
     label, whatever — implementer's call).
3. A row of buttons below the list:
   - **Mark All Upgrades** — checks every row.
   - **Check Now** — triggers a fresh check via the Phase 2 manager.
   - **Apply** — runs `brew upgrade <names of marked rows>` as a
     single invocation.
4. A progress/output area at the bottom, collapsed by default and
   visible only while an Apply is in flight or has recently
   finished:
   - Primary surface: a determinate-or-indeterminate progress bar
     (implementer's call depending on what brew's output lets us
     derive).
   - A disclosure triangle labelled "Show details" / "Hide details"
     expanding to a monospaced, read-only, auto-scrolling view of
     streamed stdout+stderr, interleaved in arrival order.
   - A **Cancel** button visible while Apply is in flight.

**List population.** When the window opens:

- Manager state is `.idle(count: N>0)` with a list in hand → render
  the list immediately. No auto-check.
- Manager state is `.idle(count: 0)` → render an empty-state
  message ("No updates pending"). No auto-check.
- Manager state is `.checking` → render a spinner / "Checking…"
  placeholder for the list area. Transitions into the populated
  list when the check settles.
- Manager state is `.failed(message)` → render the error
  prominently and offer Check Now to retry.

**Button enablement rules** (all binding to manager state):

| Control | Enabled when |
|---|---|
| Mark All Upgrades | Not `.checking`, not applying, at least one outdated row present |
| Check Now | Not `.checking`, not applying |
| Apply | Not `.checking`, not applying, at least one row marked |
| Cancel | Applying |
| Per-row checkbox | Not applying (checking is fine; list won't change underneath) |

**Apply pipeline.** New method on the Phase 2 manager:
`apply(_ packages: [OutdatedPackage])` — single invocation of
`brew upgrade <name1> <name2> …`. No per-package sequencing, no
Steading-level "stop on first failure" logic; brew's own
multi-package failure behaviour stands. On completion:

- Re-run a check (to refresh the list — successfully-upgraded
  packages drop off; failures stay visible).
- The progress/output area stays visible briefly with a success /
  failure indicator; user can collapse or it collapses itself when
  the user takes another action.

**Cancel.** Sends `SIGTERM` to the brew process; after a 5-second
grace window without exit, escalates to `SIGKILL`. On termination,
re-runs a check (the cancel may have landed mid-upgrade of one
package; the list should reflect reality). Strip / header briefly
shows `"Last upgrade canceled"` then returns to the normal count
display.

**Close / quit while Apply is in flight — strong warning.**
Cancelling mid-upgrade is equivalent to SIGINT'ing `brew upgrade` at
the command line: packages being installed may be left in a partial
or broken state, and the user's brew install may need manual repair.
This is **strongly advised against**, and any close attempt during
Apply must surface that warning prominently — not a neutral "are you
sure?" dialog.

Every close gesture during Apply routes through the same warning:

- Window red button (close widget)
- Cmd+W
- Cmd+Q (app quit) — via
  `NSApplicationDelegate.applicationShouldTerminate(_:)` returning
  `.terminateLater` until the user answers

Dialog content:

- **Title** (prominent): `"Cancel upgrade in progress?"`
- **Message** (explicit about consequence): `"Stopping an upgrade
  midway is equivalent to pressing Ctrl-C during `brew upgrade`.
  Packages currently being installed may be left in a partial or
  broken state, and your Homebrew installation may need manual
  repair. This is strongly advised against."`
- **Buttons**: `Keep Running` (default, `.cancel` role — returns to
  the window / cancels the quit) and `Cancel and Close Anyway`
  (`.destructive` role — calls Cancel as defined above, then
  completes the close / quit once the process settles).

Default button is `Keep Running`, so an accidental Return-keypress
on the dialog does the safe thing.

**Streaming subprocess surface.** A new abstraction in
[app/Steading/Model/](../../app/Steading/Model/). Requirements:

- Spawns an arbitrary executable with arbitrary arguments (not
  brew-specific — the future bootstrap flow needs this too).
- Emits stdout and stderr as they arrive, interleaved in arrival
  order into a single delivery channel the caller can consume to
  render live output. Line-granularity delivery is fine; byte /
  chunk granularity is fine too — caller-visible semantics must be
  "output lands promptly, not all at the end".
- Reports final exit code after the process exits.
- Supports cancellation with the SIGTERM-then-SIGKILL escalation
  described above.
- **Bail-out posture for anomalies.** If the runner encounters a
  condition its design doesn't cover (subprocess won't die after
  SIGKILL, file descriptor weirdness, etc.), it surfaces the
  condition clearly — an explicit failure with a diagnostic — and
  does *not* try to paper over it. The Phase 3 install UX shows
  the diagnostic; an implementer noticing a recurring anomaly
  escalates to design rather than silently handling it.

**Files expected to change or be added:**

- New: streaming subprocess surface under
  [app/Steading/Model/](../../app/Steading/Model/).
- New: the Brew Package Manager view under
  [app/Steading/Views/](../../app/Steading/Views/).
- Edit: the Phase 2 manager — add the `apply(_:)` method and the
  `.applying(progress, outputStream)` state (or equivalent shape at
  implementer's discretion), plus the post-apply re-check.
- Edit: `ToolsMenuContent` in
  [app/Steading/App/SteadingApp.swift:53-61](../../app/Steading/App/SteadingApp.swift#L53-L61) —
  add a second button.
- Edit: [app/Steading/App/SteadingApp.swift](../../app/Steading/App/SteadingApp.swift) —
  add the new `Window` scene.

No XPC protocol changes. `brew upgrade` runs as the logged-in user.

### Success Criteria

#### Automated

Red/green: failing test first, production code to turn it green.

- Streaming surface: spawn a shell one-liner that prints five lines
  with `sleep 0.2` between each; assert that lines arrive at the
  consumer incrementally (first line observed before the process
  exits), final exit code is zero, and all five lines are present
  in order.
- Streaming surface, interleaving: spawn a shell one-liner that
  prints to stdout and stderr in a known interleaved sequence;
  assert the consumer sees the same interleaving (tolerant of
  small reordering from pipe buffering, but both channels
  represented).
- Streaming surface, cancel: spawn `sleep 30`, cancel after 100ms,
  assert the subprocess is reaped within the 5s SIGTERM grace
  window (no SIGKILL necessary), and the surface reports a
  canceled outcome.
- Streaming surface, stubborn subprocess: spawn a trap-ignoring
  subprocess (`trap '' TERM; sleep 30`), cancel, assert SIGKILL
  fires after 5s and the subprocess is reaped.
- Apply argument construction: pure function taking
  `[OutdatedPackage]` and returning the argv for `brew upgrade`;
  tested with 0 / 1 / many packages, and with names containing
  awkward characters (e.g. `python@3.11`) passed through verbatim.
- Button enablement: pure function mapping
  (manager state, markedCount, outdatedCount) → (applyEnabled,
  checkNowEnabled, markAllEnabled, perRowEnabled, cancelEnabled).
  Table test covers the rules above.
- `make -C app build` and `make -C app test` both pass.

No live `brew upgrade` in automated tests — it's destructive and
network-dependent. The Apply pipeline is exercised manually.

#### Manual

Human-observation steps only. Process-existence checks
(`pgrep -fl brew`, Activity Monitor inspection) and log-warning
audits are CLI-verifiable — the implementer runs those alongside
these visual checks, not the human.

- [ ] Bottom strip shows a non-zero count. Tools → Brew Package
      Manager opens the window; the list matches the count and
      each row shows name, installed version → available version,
      and kind.
- [ ] Mark All Upgrades checks every row; Apply becomes enabled.
- [ ] Unchecking one row leaves Apply enabled. Unchecking all
      rows disables Apply.
- [ ] Check Now visibly shows a "Checking…" state briefly, then
      refreshes the list.
- [ ] Apply with a single low-risk no-sudo formula marked (any
      updatable one on the dev box that isn't a cask): progress
      area appears, disclosure-triangle "Show details" expands to
      a live stream of brew's output, completion shows a success
      indicator, and the upgraded package drops off the list.
- [ ] Apply with multiple packages marked: output streams,
      progress progresses, completion re-refreshes the list.
- [ ] Apply with a package that requires sudo (cask or similar):
      output streams up to the `Password:` prompt, then stalls.
      Cancel terminates the subprocess; list re-refreshes. (Phase
      4 unblocks this case — this step just confirms the stall +
      Cancel path works in Phase 3.)
- [ ] Cancel during a long-running upgrade: button visibly
      terminates within a few seconds; strip briefly shows
      `"Last upgrade canceled"` and returns to the count.
- [ ] Close the window mid-Apply (red button): the strong warning
      dialog appears with `"Cancel upgrade in progress?"`, the
      Ctrl-C-equivalent explanation, and the two buttons. Return
      key does nothing destructive (default is `Keep Running`).
- [ ] Cmd+W mid-Apply: same warning dialog.
- [ ] Cmd+Q mid-Apply: same warning dialog. `Keep Running` returns
      to the running Apply; `Cancel and Close Anyway` cancels the
      subprocess and quits the app once it settles.

## Phase 4: sudo-during-upgrade PoC

### Overview

Unblock the Apply pipeline for upgrades that prompt for a password
mid-run (casks, keg-only formulae with privileged postinstall
scripts). Explicitly a **proof-of-concept** — discovery calls out
that SecureInput isolation, pty-driven prompt detection, and
keychain-backed retries are **future work**, to be tackled only
after the PoC proves the mechanism end-to-end.

Approach: **pre-warm the sudo timestamp.** Before spawning
`brew upgrade`, prompt the user for their password, run
`sudo -v -S` with the password piped via stdin; if that succeeds
the sudo timestamp is valid for ~5 minutes, and any `sudo` invoked
by brew within that window runs without prompting. Simplest-possible
mechanism matching the discovery's "simple input modal that
collects the password and feeds it to brew" framing.

**Phase-4-is-a-PoC contract.** The mechanism has a known failure
mode: sudo's default `timestamp_type=tty` on macOS, and Steading
spawns brew without a controlling tty — so whether a pre-warmed
timestamp actually propagates to brew's internal sudo call is
empirically-verified, not presumed.

**Pre-implementation gate (LLM, before writing Phase 4 code).**
Verify the propagation by running a scratch subprocess chain on
the dev box that mirrors what Steading will do at runtime:

1. Spawn `/usr/bin/sudo -v -S` with a password piped to stdin.
2. After it exits zero, spawn `brew upgrade <cask-known-to-need-sudo>`
   as a child process (no controlling tty, plain `Process` API).
3. Observe whether brew's internal `sudo` prompts for the password
   again, or runs silently on the warm timestamp.

If brew runs silently → propagation works, Phase 4 proceeds as
specified. If brew re-prompts → the PoC approach as planned does
not work; **stop and escalate**. The likely redesign is
`SUDO_ASKPASS` with a bundled askpass helper — do not push through
or invent workarounds. Matches the "break early for human
guidance" posture of the streaming runner.

### Changes Required

**Password prompt modal.** A sheet-presented modal shown on Apply:

- Title: `"Administrator password required"`
- One-line explanation: `"Some upgrades may need administrator
  access. Your password is used once and not stored."`
- A `SecureField` for the password (no keychain "remember me"
  checkbox — future work).
- Two buttons: **Cancel** (dismisses the modal, cancels Apply
  before it spawns brew) and **Continue** (runs the sudo
  pre-warm).

Password lifecycle: held in a local Swift `String` for the
duration of the Apply call, passed to the `sudo -v -S` subprocess
via stdin, and discarded once the pre-warm returns. No UserDefaults,
no keychain, no logging of the plaintext anywhere. If the Apply
later re-runs (e.g. user re-clicks Apply after a canceled run),
prompt again.

**Pre-warm subprocess.** A new call path in the Phase 2 manager
(or a small helper) that invokes `/usr/bin/sudo -v -S` with the
password written to its stdin as `"<password>\n"` bytes. Reads the
exit code:

- `0` → timestamp is warm, proceed to spawn `brew upgrade …` via
  the streaming runner.
- Non-zero → surface `"Password incorrect"` (or terser) in the
  modal and let the user retry. After 3 consecutive wrong
  passwords, dismiss the modal with `"Administrator access denied"`
  and cancel the Apply.

**Prompt-every-Apply semantics.** The modal shows every time the
user clicks Apply. We can't predict in advance which upgrades will
trigger sudo, and the PoC does not attempt the detect-then-prompt
flow (that's pty-territory, future work). If the upgrade doesn't
need sudo, the pre-warm still ran — it's slightly wasteful but
cheap.

**What still stalls.** If the sudo timestamp doesn't propagate
(Verification Step 1 fails, or individual upgrades ask for the
password a second time past the ~5-minute window), brew still
stalls at an interactive prompt as it does in Phase 3. The Phase 3
Cancel button is still the escape hatch. The strip / output view
surfaces this honestly — no pretending.

**Files expected to change or be added:**

- New: the password prompt modal view under
  [app/Steading/Views/](../../app/Steading/Views/).
- Edit: the Phase 2 manager's `apply(_:)` method — prepend the
  pre-warm step, propagate cancel-on-modal-cancel semantics.
- Edit: the Brew Package Manager view — present the modal when
  Apply is clicked; only transition into the applying state after
  the pre-warm returns zero.

No XPC protocol changes. No privileged helper involvement (brew
itself is unprivileged; the `sudo` calls brew makes are direct
kernel sudo invocations, not mediated by our helper).

### Success Criteria

#### Automated

Red/green where practical. The sudo pipeline is inherently
system-integrated and hard to unit-test without side effects; most
verification lives in the Manual section below. Automated coverage:

- Pure function: "should the password prompt be shown" — takes a
  marked-package list and returns `true` (always, in Phase 4;
  scaffolds future work where we might skip the prompt if we
  detect no-sudo-needed).
- Password lifecycle: after a pre-warm call, assert the password
  string passed in is no longer reachable from the manager / view
  state (nil / zeroed / out of scope — implementer's call how to
  demonstrate, but a test must demonstrate it).
- Wrong-password handling: stub the pre-warm subprocess seam to
  return non-zero 3 times, assert the modal advances through
  retry → retry → denied-and-canceled. (Same seam shape as Phase
  2's retry test — the production `apply(_:)` flow is under test,
  the `sudo` invocation itself is substituted.)
- `make -C app build` and `make -C app test` both pass.

#### Manual

Human-observation steps only. The sudo-propagation pre-gate is in
the Overview (LLM verifies). Password-leak checks (`log show`,
Console.app subsystem filters, streamed-output-area grep for the
plaintext) are CLI-verifiable and the implementer runs them as
part of automated security due diligence, not the human.

- [ ] Tools → Brew Package Manager → Apply. Password modal appears
      with the title, explanation text, SecureField (dots only,
      not plaintext), Cancel button, Continue button.
- [ ] Cancel on the modal dismisses it and leaves the manager
      idle; no spinner, no output area, no brew process started.
- [ ] Wrong password, Continue: modal shows a terse error, the
      SecureField clears, focus returns to the field.
- [ ] Three wrong passwords in a row: modal auto-dismisses with
      `"Administrator access denied"` and the Apply is canceled.
- [ ] Correct password on the first try, with a cask that needs
      sudo marked: modal dismisses, Apply proceeds (Phase 3
      progress UI), the subprocess does *not* stall at an
      internal sudo prompt, upgrade completes.
- [ ] Correct password, with only no-sudo formulae marked: Apply
      still works (the pre-warm was harmless).
- [ ] After a completed Apply, clicking Apply a second time
      re-shows the password modal (prompt-every-Apply).

## Phase 5: Notification surface (dock badge, menu bar label, system banner)

### Overview

Three independent surfaces that reflect the pending-update count
without the user opening Steading, each individually toggled by the
Phase 1 preferences (`notifyDockBadge`, `notifyMenuBarLabel`,
`notifySystemBanner`). All three read the same manager state, and
update in real time — flipping a preference mid-session takes
effect immediately. Shippable after Phase 2 (the count is the only
input), but sequenced last because the Brew Package Manager window
from Phase 3 is the target for the "tap the notification to act"
flow.

### Changes Required

**Dock badge.** Bind `NSApplication.shared.dockTile.badgeLabel` to
`(notifyDockBadge && count > 0) ? "\(count)" : nil`. No formatting
tricks, no "999+" clamp (brew counts don't reach that territory);
render the integer as-is.

**Menu bar label.** Replace the current
[app/Steading/App/SteadingApp.swift:42](../../app/Steading/App/SteadingApp.swift#L42)
`MenuBarExtra("Steading", systemImage: "house.fill")` call with the
`MenuBarExtra(content:label:)` initializer so the label becomes a
custom view: the `house.fill` SF Symbol always, plus a count
rendered beside it when `notifyMenuBarLabel && count > 0`. Exact
visual composition (HStack, Text badge, Capsule overlay, whatever)
is at the implementer's discretion — must be legible at standard
macOS menu-bar sizes and in both light and dark modes.

**System notification.** Post a
`UNNotificationRequest` on each successful check-settlement where
count > 0 and `notifySystemBanner` is on.

- **Identifier:** fixed constant (e.g. `"com.xalior.Steading.brew-updates"`) —
  identical on every post, so macOS replaces the Notification
  Center entry rather than stacking. (Exact string is the
  implementer's call — the identifier must match the bundle-id
  prefix `com.xalior.Steading`, see CLAUDE.md.)
- **Title:** `"Brew updates available"`
- **Body:** `"<N> pending updates"` (singular form for N=1).
- **Sound:** none. The banner is the notification; no beep.
- **Tap target:** tapping the notification body opens the Brew
  Package Manager window (`openWindow(id: "brew-package-manager")`
  from Phase 3), not the main window. The notification's whole
  point is to act on updates; routing to the main window would be
  one extra click.

**Authorization.** At app launch, call
`UNUserNotificationCenter.current().requestAuthorization(options:
[.alert, .badge])` once. If the user declines, the
`notifySystemBanner` preference stays user-toggleable but posts
silently fail (macOS enforces this). No in-app "you need to enable
notifications in System Settings" banner in this phase — future
polish.

**Preference-change semantics.**

| Transition | Effect |
|---|---|
| `notifyDockBadge` off → on, count > 0 | Badge appears immediately |
| `notifyDockBadge` on → off | Badge clears immediately |
| `notifyMenuBarLabel` off → on, count > 0 | Count appears beside icon immediately |
| `notifyMenuBarLabel` on → off | Count disappears; icon only |
| `notifySystemBanner` off → on, count > 0 | No immediate post — posts on next successful check. (Keeps the semantics simple: a banner is a **post-check event**, not a "currently-pending-updates" poll.) |
| `notifySystemBanner` on → off | Any already-delivered notification with our identifier is removed via `removeDeliveredNotifications(withIdentifiers:)`. |

**Count-change semantics.**

| Transition | Dock | Menu bar | Banner |
|---|---|---|---|
| `0 → N` | badge shows N (if pref on) | count shows (if pref on) | posts (if pref on) |
| `N → M` where M > 0 and pref on | badge updates to M | count updates to M | posts (replacing prior entry, same identifier) |
| `N → 0` (e.g. after Apply) | badge clears | count disappears | prior delivered notification is removed |
| `.checking` / `.failed` | badge reflects last known count (unchanged) | label reflects last known count (unchanged) | no post (banner is a success-settlement event only) |

Rationale for the `.checking` / `.failed` row: we don't want the
count to flicker off while a routine check is running. It stays at
the last settled value until the next settlement.

**Files expected to change or be added:**

- Edit:
  [app/Steading/App/SteadingApp.swift](../../app/Steading/App/SteadingApp.swift) —
  rework the `MenuBarExtra` to use the `content:label:` initializer
  with a custom label view.
- Edit:
  [app/Steading/App/AppDelegate.swift](../../app/Steading/App/AppDelegate.swift) —
  request notification authorization at app launch; wire a
  `UNUserNotificationCenterDelegate` that routes the tap to
  `openWindow(id: "brew-package-manager")`.
- Edit: the Phase 2 manager — on settlement, invoke the
  notification post (if enabled) and update dock/menu bar
  reactively. Alternative shape: a new small coordinator type
  subscribes to manager state — implementer's call.
- New: a custom `MenuBarExtra` label view under
  [app/Steading/Views/](../../app/Steading/Views/).

No XPC protocol changes.

### Success Criteria

#### Automated

Red/green where practical.

- Pure function: `dockBadgeLabel(count: Int, enabled: Bool) -> String?`.
  Returns `nil` for `count == 0` regardless, `nil` for `enabled == false`,
  and `"\(count)"` otherwise. Table test.
- Pure function: `menuBarShowsCount(count: Int, enabled: Bool) -> Bool`.
  Same shape. Table test.
- Pure function: given `(previousCount, currentCount, previousPref,
  currentPref)`, compute the banner action — one of `.post`,
  `.removeDelivered`, `.noop`. Table test covering the eight rows
  of the count-change and preference-change tables above.
- Live: post two `UNNotificationRequest`s with the same fixed
  identifier back-to-back against the real
  `UNUserNotificationCenter`; read back
  `getDeliveredNotifications()` and assert exactly one entry with
  that identifier remains (replacement-not-stacking semantics
  confirmed). Skip gracefully in environments without
  notification entitlement.
- `make -C app build` and `make -C app test` both pass.

#### Manual

Human-observation steps only. Replacement-semantics confirmation
(two posts with the same identifier → exactly one entry remaining
via `getDeliveredNotifications()`) is in Automated.

- [ ] On a dev machine with pending brew updates and no prior
      permission grant, launching Steading shows the macOS
      "Steading would like to send you notifications" prompt.
      Allow.
      *Implementer setup (if previously granted):* `tccutil reset
      Notifications com.xalior.Steading` then relaunch.
- [ ] With all three notification prefs on (Phase 1 defaults):
      dock icon shows the count as a badge; menu bar's house icon
      has the count rendered beside it; a macOS banner appears
      with `"Brew updates available"` / `"<N> pending updates"`.
- [ ] Clicking the banner (or its entry in Notification Center)
      opens the **Brew Package Manager** window, not the main
      window. App activates.
- [ ] Quit Steading (Cmd+Q), confirm a notification entry still
      sits in Notification Center, then click it — Steading
      cold-launches and the Brew Package Manager window opens.
- [ ] After running Apply to reduce the count to 0: dock badge
      clears, menu bar count disappears, the prior Notification
      Center entry is no longer present.
- [ ] Toggling `notifyDockBadge` off in Preferences clears the
      badge immediately (even with a non-zero count); toggling
      back on makes it reappear.
- [ ] Toggling `notifyMenuBarLabel` off / on — same, for the menu
      bar count.
- [ ] Toggling `notifySystemBanner` off while a delivered entry
      exists in Notification Center — the entry is removed.
- [ ] Toggling `notifySystemBanner` off → on does NOT post
      immediately. Triggering the next check (Check Now, or
      relaunch with check-on-launch) posts a fresh banner.
- [ ] On a dev machine where the user has *declined* the
      notification permission: dock badge and menu bar count
      still work, but no banners appear, and `notifySystemBanner`
      remains user-toggleable in Preferences.
      *Implementer setup:* `tccutil reset Notifications
      com.xalior.Steading`, launch, decline the prompt.

## Testing Strategy

**Red/green discipline.** Every new piece of logic lands with its
failing test first. Write the test, run it, see it red; then add
the production code that turns it green. This is not negotiable for
the pure functions (parsers, scheduler decisions, back-off curve,
notification-action calculator, button-enablement table). For
integration-ish code (the streaming runner, the retry settlement
counter, the sudo pre-warm pipeline) the seam between "production
code under test" and "test-only subprocess substitute" is at the
implementer's discretion — but the production retry / spawn / pipe
code path must be what runs under test, never a parallel
reimplementation.

**Pure functions stay public static.** Matching the
[BrewDetectorTests.swift](../../app/SteadingTests/BrewDetectorTests.swift)
exemplar: `parseOutdatedJSON`, `nextRetryDelay`, `shouldFireOnStartup`,
`brewUpgradeArgv`, `dockBadgeLabel`, `menuBarShowsCount`, and the
banner-action mapper are all `public static` so tests call them
directly with canned inputs. No wrappers, no shims, no helpers
over the top of them in test code.

**Live tests over real boundaries, where safe.**

- `brew --version` and `brew outdated --json=v2` are read-only and
  fast; invoke the real binary in live tests (skip gracefully if
  brew is absent on the test host).
- `UNUserNotificationCenter`: real notifications under the app's
  actual bundle identity — post two with the same identifier,
  read back `getDeliveredNotifications()`, confirm exactly one
  entry remains. Skip gracefully in environments without
  notification entitlement.
- The streaming subprocess surface: exercise against real-but-harmless
  subprocesses (`sh -c 'for i in 1 2 3 4 5; do echo $i; sleep 0.2; done'`,
  `trap '' TERM; sleep 30`, etc.). These have deterministic,
  cheap behaviour and verify the runner against a real OS pipe
  rather than a fake.

**Never live `brew upgrade` in automated tests.** It's destructive
and network-dependent. The Apply pipeline is covered by pure
argv-construction tests + the streaming runner's general tests;
end-to-end Apply is a manual verification step in Phase 3 (and
Phase 4 for the sudo path).

**No mocks that re-implement logic.** Per CLAUDE.md, tests must
exercise real production code. Boundary-input injection (empty
package list, malformed JSON fixture, scratch UserDefaults suite,
seam substitute for the `sudo` subprocess) is fine. Stub-then-test
a parallel reimplementation is not.

**Build and test entry points.**

- `make -C app build`
- `make -C app test`

Both added in Phase 1 (see that phase's Changes Required); all
later phases' automated criteria refer to these targets.

**Clean-state manual checks.** Some manual verification steps
depend on a known-clean starting state — the notification
permission prompt on first launch, the preferences-not-yet-present
path, the cold-launch notification-click route. The `tart` + VM
harness is installed but unverified at plan-time; until it's
exercised end-to-end, arrange clean state on the dev machine
directly. If the harness becomes verified during implementation,
any of the dev-machine resets below can move into a VM run
instead.

**Reset notification permission (re-trigger the first-run prompt).**
macOS caches the user's permission decision in TCC (Transparency,
Consent, and Control), so subsequent `requestAuthorization` calls
return the cached result without re-prompting. To clear that cache
for Steading:

```sh
tccutil reset Notifications com.xalior.Steading
```

No `sudo` required (user-scope TCC entry). The next launch's
`requestAuthorization` call will show the OS prompt again.

The GUI alternative (System Settings → Notifications → Steading →
toggle Allow Notifications off) *disables* notifications but does
**not** re-trigger the first-run prompt. Use `tccutil reset` when
you specifically want the prompt path.

**Delete app preferences (test the pre-prefs-present path).**

```sh
defaults delete com.xalior.Steading
killall cfprefsd      # flush the in-memory cache macOS keeps
```

The `killall cfprefsd` step is needed because macOS's preferences
daemon caches reads in memory; without it, a relaunch of Steading
may see the old defaults until the cache ages out.

GUI alternative: delete
`~/Library/Preferences/com.xalior.Steading.plist` (and run
`killall cfprefsd` afterward).

**Arrange a cold-launch state (test the notification-click
route while the app isn't running).** Quit Steading via Cmd+Q or:

```sh
osascript -e 'quit app "Steading"'
```

After that, clicking a Steading entry in Notification Center
launches the app from cold — the `applicationDidFinishLaunching`
→ delegate-response path runs, rather than the live event path.

## References

- Source discovery:
  [docs/discovery/discovery_brew-updater.md](../discovery/discovery_brew-updater.md)
- Agent operating rules:
  [CLAUDE.md](../../CLAUDE.md) — "Tests ALWAYS exercise production
  code", VM harness rules, build cheatsheet.
- Architecture:
  [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md) — privileged-helper
  model, invariants, testing strategy.
- Test exemplar:
  [app/SteadingTests/BrewDetectorTests.swift](../../app/SteadingTests/BrewDetectorTests.swift)
- Existing plan in the repo to mirror for WIP tracker / progress
  log shape during implementation:
  [docs/plans/plan_hosts-file-editor_implementation.md](./plan_hosts-file-editor_implementation.md)
- Menu / Window scene pattern to mirror for the Brew Package
  Manager window:
  [app/Steading/App/SteadingApp.swift:30-40](../../app/Steading/App/SteadingApp.swift#L30-L40),
  [app/Steading/Views/HostsEditorView.swift](../../app/Steading/Views/HostsEditorView.swift)
- `MenuBarExtra` baseline the Phase 5 label view replaces:
  [app/Steading/App/SteadingApp.swift:42-46](../../app/Steading/App/SteadingApp.swift#L42-L46)
- Main-window layout the Phase 2 status strip attaches to:
  [app/Steading/Views/ContentView.swift:9-14](../../app/Steading/Views/ContentView.swift#L9-L14)
- Xcodegen source auto-discovery (no manual source-list edits
  needed for new files in standard dirs):
  [app/project.yml:30-38](../../app/project.yml#L30-L38)
- Brew's machine-readable outdated output documentation:
  `brew outdated --json=v2` — man `brew outdated` on any machine
  with brew installed.
