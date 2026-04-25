# Plan: brew-package-manager

**Status:** Ready for Implementation
**Source:** [`docs/discovery/discovery_brew-package-manager.md`](../discovery/discovery_brew-package-manager.md)

## Overview

Replace the upgrade-only contents of the existing **Brew Package Manager**
window with a Synaptic-equivalent package manager over Homebrew: a
three-pane window (sidebar / list / details) that handles install,
uninstall, and upgrade for both formulae and casks, with sidebar
modes for Status, Origin (taps), and Search Results. The existing
brew-updater background cycle's externally-visible semantics —
periodic `brew update` + `brew outdated`, retry back-off, dock
badge, menu-bar count, and system banners — stay exactly as they
do today; the only addition is a soft post-settle step that
regenerates a Steading-owned cache for user-added taps (described
under Source of Truth).

## Current State

- [`app/Steading/Views/BrewPackageManagerView.swift`](../../app/Steading/Views/BrewPackageManagerView.swift)
  is the upgrade-only window. It shows the outdated list, a Mark All /
  Check Now / Apply control row, an apply progress area, and an
  askpass password sheet.
- [`app/Steading/Model/BrewUpdateManager.swift`](../../app/Steading/Model/BrewUpdateManager.swift)
  owns *both* the headless background cycle (`brew update` + outdated,
  scheduler, retry back-off, banner/dock/menu-bar surfaces) *and* the
  upgrade-only Apply pipeline (`apply`, `applyLog`,
  `recentApplyOutcome`, askpass plumbing, `Buttons`, `cancelApply`).
- The window scene is registered as `Window("Brew Package Manager",
  id: "brew-package-manager")` in
  [`app/Steading/App/SteadingApp.swift`](../../app/Steading/App/SteadingApp.swift)
  and opened via `AppDelegate.openBrewPackageManager` from the Tools
  menu and the brew-updates notification tap path.
- `OutdatedPackage` and `BrewOutdatedParser` already model the
  formula/cask union the new UI needs — but only for the outdated
  subset.

## Desired End State

Two main-actor `@Observable` types own brew-related state, with
disjoint responsibilities:

- **`BrewUpdateManager`** (existing type, narrowed). Headless. Periodic
  `brew update` + `brew outdated --json=v2`, retry back-off, settle,
  notification surface (dock badge, menu-bar count, system banner).
  Exposes `outdated: [OutdatedPackage]`, `lastSettledCount`, `check()`
  for the toolbar's Check Now button. Its `.applying` State case and
  the entire Apply pipeline are gone.
- **`BrewPackageManager`** (new). UI-facing. Owns the full package
  index, the three sidebar modes' state (Status / Origin /
  Search Results), search text, per-row boolean marking (verb
  derived at Apply time from each row's package state), tap list
  and tap add/remove, the batched Apply pipeline (add phase
  before remove phase, with a post-uninstall autoremove
  confirmation), and the per-row context-menu pin/unpin verbs.
  Reads `outdated` from `BrewUpdateManager` to drive the
  upgradable subset and Mark All Upgrades.

`BrewPackageManagerView` is rebuilt against `BrewPackageManager`, with
the existing askpass sheet, close-while-applying confirmation, and
streaming progress area preserved (re-homed to read from the new
manager).

## Key Discoveries

- The discovery's Scope-out of "Changes to the brew-updater background
  cycle" forces the responsibility split — the headless cycle has to
  remain bit-for-bit unchanged. That makes
  [`BrewUpdateManager.swift`](../../app/Steading/Model/BrewUpdateManager.swift)
  a poor home for the new install/remove verbs and the reason the
  Apply pipeline gets relocated rather than extended.
- The window scene id (`brew-package-manager`), the
  `AppDelegate.openBrewPackageManager` plumbing, the Tools-menu entry,
  and the notification-tap routing all stay as-is; only the window's
  *contents* change.
- `OutdatedPackage` is the right shape for the per-row model in the
  list — the new code needs to broaden it (or layer on top) so casks
  and formulae *not* currently outdated can also be represented.
- The askpass coordination via
  [`AskpassService`](../../app/Steading/Model/AskpassService.swift)
  and the `SUDO_ASKPASS` env path are already correct for batched
  apply; they just need to move with the apply pipeline.
- The close-while-applying confirmation (`CloseInterceptor`,
  `steadingAppQuitDuringApply` notification) is generic over the verb
  in flight — it works unchanged once `state == .applying` is read off
  `BrewPackageManager`.
- **brew's own cached package index is on disk.** `brew update`
  populates `~/Library/Caches/Homebrew/api/formula.jws.json` and
  `cask.jws.json` (JWS-signed envelopes; the `payload` field is a
  JSON-encoded string that decodes to the same per-entry shape
  `brew info --json=v2` emits). On this developer's machine the
  files are 32 MB and 15 MB respectively. They cover *only*
  `homebrew/core` and `homebrew/cask` — third-party taps
  (including `xalior/homebrew-steading`) are not in these files.
- Companion cache files in the same directory are useful boundary
  inputs: `formula_names.txt` / `cask_names.txt` are flat name
  lists; `formula_tap_migrations.jws.json` /
  `cask_tap_migrations.jws.json` carry rename/move data.

## Source of Truth for the Package Universe

The package universe surfaced to the UI is the union of two
disk-resident caches:

1. **brew's own JWS cache** at
   `~/Library/Caches/Homebrew/api/{formula,cask}.jws.json` — the
   authoritative index for `homebrew/core` + `homebrew/cask`. Read
   directly; brew already keeps it fresh as part of its own
   `brew update` flow.
2. **A Steading-owned cache** at
   `~/Library/Caches/com.xalior.Steading/tap-index.json`,
   regenerated on every successful brew-updater scheduler settle
   so it's as fresh as brew's own cache. The on-disk shape
   mirrors brew's payload — `{"formulae":[…], "casks":[…]}` —
   so a single Codable model decodes both files. The regen
   command sequence and the failure-mode constraints are
   specified under Phase 1 → Changes Required → "Tap-regen step
   on `BrewUpdateManager`".

Forced constraint from the discovery's Scope-out: a tap-regen
failure cannot put `BrewUpdateManager` into `.failed` and cannot
trigger its retry back-off — those are existing cycle semantics
that the Scope-out protects. On regen failure the previous
on-disk cache file (if any) is left untouched — the next
successful settle replaces it; partial output is never written.

## What We're NOT Doing

(seeded from discovery's Scope-out, plus what emerged from the split.)

- No "Get Screenshot" / "Get Changelog" buttons in the details pane —
  the details pane is text-metadata-only.
- No self-update verb for Homebrew itself on this surface.
- No changes to the brew-updater background cycle: periodic check
  cadence, retry back-off, dock badge, menu-bar count, system banner,
  and `BrewUpdateManager.start()`/`check()` semantics all stay as they
  are. The toolbar's Check Now button is a *caller* of the existing
  `BrewUpdateManager.check()`, not a redefinition of it.
- No per-package "show only selected" filter — the affordance for
  finding marked rows is sort-by-marked-state on the list column.
- No separate Taps UI — tap add/remove lives inline in the Origin
  sidebar mode.
- **No Sections sidebar mode.** Brew has no native category /
  taxonomy field on formulae or casks, so a Synaptic-style
  Sections view is not achievable from brew data. The sidebar's
  modes are Status, Origin, and Search Results only.
- **No "broken" Status value.** Brew has no per-package broken
  state in its index that maps to Synaptic's "broken". The
  Status filter values are `installed`, `not installed`,
  `upgradable`, and `pinned`.
- **No service lifecycle.** The Brew Package Manager window is
  the bits-on-disk surface only — install / uninstall / upgrade.
  Service lifecycle (start, stop, enable-on-boot) lives in the
  Catalog UI and the privileged helper, deliberately not via
  `brew services`, per the architectural invariant in
  [`docs/ARCHITECTURE.md`](../ARCHITECTURE.md) ("LaunchDaemons,
  not LaunchAgents"). The `service` field present in brew's
  per-formula JSON is therefore informational only and is not
  surfaced as an actionable affordance in this window.

## Approach

Single phase, vertical slice: the entire Synaptic-clone window lands
in one cut. The split between `BrewUpdateManager` (narrowed) and
`BrewPackageManager` (new) is established as part of the same change
so the window never has to bind to a half-migrated manager.

Justification for not slicing further: the discovery explicitly
defines the window as "a single bundle of Synaptic-equivalent
surfaces", and the surfaces interlock — sidebar modes drive list
content, search drives Search Results mode, marking drives Apply,
Origin mode is also tap management. Splitting horizontally (e.g.
"land Status mode first, Origin later") would mean shipping a window
that looks like Synaptic only partway, which is worse UX than holding
the whole thing until it's ready. The amount of code is modest — the
new manager and view together are smaller than landing intermediate
half-states with feature flags.

## Phase 1: Synaptic-clone Brew Package Manager

### Overview

Phase 1 lands the Synaptic-equivalent window in one vertical
slice. The existing upgrade-only window's contents are replaced
with a three-pane (sidebar / list / details) surface that handles
install, uninstall, and upgrade across formulae and casks;
brew-state ownership splits into the existing
[`BrewUpdateManager`](../../app/Steading/Model/BrewUpdateManager.swift)
(narrowed) and a new `BrewPackageManager`; and `BrewUpdateManager`'s
settle path gains the soft tap-regen step that keeps the
Steading-owned tap cache as fresh as brew's own JWS cache. The
window scene id, the
[`AppDelegate.openBrewPackageManager`](../../app/Steading/App/AppDelegate.swift)
routing, the
[`AskpassService`](../../app/Steading/Model/AskpassService.swift)
plumbing, and the close-during-apply confirmation
([`CloseInterceptor`](../../app/Steading/Views/BrewPackageManagerView.swift),
`steadingAppQuitDuringApply`) are reused unchanged — only the
window's contents and the manager that owns its state change.

### Changes Required

#### Tap-regen step on `BrewUpdateManager`

After a successful
[`runChain`](../../app/Steading/Model/BrewUpdateManager.swift#L203)
settle, `BrewUpdateManager` invokes a regeneration step that:

1. Runs `brew tap-info --json --installed`, parses the result, and
   filters to taps whose `name` is neither `homebrew/core` nor
   `homebrew/cask`.
2. Collects the union of `formula_names` and `cask_tokens` across
   the remaining taps.
3. Runs `brew info --json=v2 <name1> <name2> …` against that union
   (one call) and writes the resulting
   `{"formulae":[…], "casks":[…]}` document to the Steading cache
   file.

The regen step is part of the new responsibility surface introduced
by this phase; it is not the existing brew-updater behaviour. Its
failure cannot push the brew-updater cycle into `.failed` and
cannot trigger retry back-off (Source-of-Truth section).

**Default cache path:** `~/Library/Caches/com.xalior.Steading/tap-index.json`.
The directory follows the macOS app-private cache convention and
matches the main-app bundle id.

**Default on-disk shape:** `{"formulae":[…], "casks":[…]}` — the
same envelope `brew info --json=v2` emits and that brew's JWS
payload uses, so a single Codable model decodes both files.

#### `BrewUpdateManager` narrowing

Removed from `BrewUpdateManager` (relocated to `BrewPackageManager`):
- The `.applying` `State` case.
- `apply(_:)`, `cancelApply()`, `applyTask`, `applyHandle`,
  `applyLog`, `recentApplyOutcome`, `appendLog`, `finishApply`,
  `runBrewUpgrade`.
- `ApplyOutcome`, `Buttons`, `BrewPathResolver`,
  `AskpassHelperResolver`, `brewUpgradeArgv`, the askpass-helper
  resolver default and the brew-path resolver default *if* they're
  not also needed by the Steading cache regen path. (They are
  needed: the regen step needs to spawn brew. They stay on
  `BrewUpdateManager` as the brew-spawn boundary, with the new
  manager calling into them or receiving them via DI — exact wiring
  is implementer's choice.)
- `buttons(state:markedCount:outdatedCount:)` — moves to
  `BrewPackageManager` (or its own pure helpers file) since the
  button enablement is UI-facing.

`BrewUpdateManager` retains: `State` (without `.applying`),
`outdated`, `lastSettledCount`, `start()`, `stop()`, `check()`, the
scheduler (`shouldFireOnStartup`, `nextRetryDelay`,
`scheduleDelayedCheck`), the notification surface (`BannerNotifier`,
`bannerActionOnSettle`, `bannerActionOnPrefChange`,
`dockBadgeLabel`, `menuBarShowsCount`,
`notificationIdentifier`), `preferencesChanged()`, the runner
contract (`Runner`, `RunResult`, `defaultRunner`), and the new
tap-regen step.

#### New `BrewPackageManager`

A new main-actor `@Observable` type co-located with the other
brew model code at
[`app/Steading/Model/BrewPackageManager.swift`](../../app/Steading/Model/BrewPackageManager.swift)
(new file). Owns:

- The unified package index (loaded from brew's JWS cache + the
  Steading tap cache) keyed by full package name (`<tap>/<name>`
  for non-core, `<name>` for `homebrew/core`/`homebrew/cask`).
- Sidebar mode: `enum SidebarMode { case status, origin, searchResults }`.
- Search text and computed search results.
- Per-package marking state (verb per row).
- Tap list (read from `brew tap-info --json --installed`) with
  add/remove via `brew tap <user>/<repo>` and `brew untap <name>`.
- The Apply pipeline (state, `applyLog`, `recentApplyOutcome`,
  cancel handle), running `brew install …`, `brew uninstall …`,
  `brew upgrade …` against the marked rows, with `SUDO_ASKPASS`
  set to the bundled `steading-askpass` helper. Includes the
  autoremove confirmation step described under "Apply ordering".
- Per-row context-menu actions invoked outside the Apply pipeline:
  `brew pin <name>` and `brew unpin <name>`, run as
  single-shot processes that update the manager's pinned-status
  view of the affected row on completion. Pin/unpin do not need
  askpass.
- Reads `outdated` from `BrewUpdateManager` to drive the upgradable
  subset and the **Mark All Upgrades** action.

**Apply ordering:** upgrade and install are the same conceptual
operation (both additive — they don't orphan dependencies);
remove is destructive and must run last so the add phase doesn't
delete dependencies the new installs need. Two phases, run
sequentially through one streaming pipeline:

1. **Add phase.** `brew upgrade <upgrade-names>` for marked rows
   whose state is installed+outdated, followed by
   `brew install <install-names>` for marked rows whose state is
   not-installed. Either of these sub-calls is skipped if its
   names list is empty.
2. **Remove phase.** `brew uninstall <remove-names>` for marked
   rows whose state is installed+current. Skipped if empty.
3. **Autoremove confirmation.** If the remove phase ran and
   completed successfully, the pipeline pauses on a confirmation
   dialog asking whether to run `brew autoremove` (default
   action: yes — pre-selected, Enter confirms). On yes, the
   pipeline runs `brew autoremove` and streams its output into
   the same `applyLog`. On no, the pipeline ends without
   running it. The dialog does not appear if the remove phase
   was skipped (no marked rows targeted removal) or failed
   (Partial-failure rule has already stopped the pipeline).

All sub-calls inherit the askpass `SUDO_ASKPASS` env (existing
plumbing) and stream into the same `applyLog`.

**Partial failure:** the pipeline stops on the first sub-call
that exits non-zero. Subsequent sub-calls do not run. The
non-zero exit and its captured stderr land in
`recentApplyOutcome` (existing `.failed(exitCode:)` shape) and
the streaming log preserves whatever output the failing sub-call
produced before it exited. The user can then inspect the log,
adjust their marks, and re-Apply.

**Marking model:** one boolean checkbox per row. The verb is
derived from the row's package state at the moment Apply runs:

| Row state            | Checked → verb |
|----------------------|----------------|
| not installed        | install        |
| installed, outdated  | upgrade        |
| installed, current   | remove         |

Unchecked rows contribute no verb. The marked-state column shown in
the list is the same boolean the checkbox binds to; sort-by-marked
brings every checked row to the top regardless of which verb its
state implies.


**Status mode values:** `installed`, `not installed`,
`upgradable`, `pinned`. The values are mutually exclusive view
filters: selecting `pinned` shows only pinned formulae,
regardless of their installed/upgradable state.

#### `BrewPackageManagerView` rebuild

[`BrewPackageManagerView.swift`](../../app/Steading/Views/BrewPackageManagerView.swift)
is rebuilt against `BrewPackageManager`. Three-pane layout:
sidebar (mode picker + mode-specific list), main list (per-row
checkbox + sortable columns including a marked-state column and
a pinned indicator), details pane (text metadata from the
indexed package). Each row carries a SwiftUI `.contextMenu`
with **Pin** (visible iff the row is an installed formula and
not currently pinned) and **Unpin** (visible iff installed
formula and currently pinned); selecting either invokes the
manager's pin/unpin verb on that row's package. Toolbar hosts
**Mark All Upgrades**, **Apply**, and an optional **Check Now**
button that calls `BrewUpdateManager.check()` (existing verb).
The askpass sheet, the close-while-applying confirmation, the
post-uninstall autoremove confirmation, and the
streaming-output disclosure area are all surfaced through
`BrewPackageManager`'s state.

**Search scope:** case-insensitive substring match against
package name and `desc`, matching `brew search --desc`'s
default behaviour. Search runs locally against the unified
in-memory index (no `brew search` shell-out); when the search
field is non-empty the sidebar mode is forced to
`searchResults`.

#### App wiring

[`SteadingApp.swift`](../../app/Steading/App/SteadingApp.swift)
instantiates `BrewPackageManager` alongside `BrewUpdateManager`
and injects it into the Brew Package Manager window scene's
environment. Other scene wiring stays as-is.

#### Tests

New test files:

- `app/SteadingTests/BrewPackageManagerTests.swift` — pure
  helpers on `BrewPackageManager` exercised with canned
  inputs: marking-derived verb rule (the table under "Marking
  model"), Status-mode filter predicates including `pinned`,
  Origin-mode filter predicates, Search-Results filter
  (case-insensitive substring against name + `desc`), Apply
  argv builders (add-phase upgrade/install splits, remove-phase
  uninstall, autoremove). Plus integration tests of the
  manager driven through a mock-runner DI seam, exercising the
  real Apply state machine: empty-mark Apply is a no-op,
  add-only Apply skips remove and skips the autoremove
  confirmation, remove-only Apply skips add and presents the
  autoremove confirmation, partial failure halts the pipeline
  on the first non-zero exit, autoremove "no" path ends
  cleanly, autoremove "yes" path runs `brew autoremove`.
- `app/SteadingTests/BrewIndexParserTests.swift` — fixture-driven
  tests for the unified `{formulae,casks}` shape, exercising
  both brew-JWS-cache and Steading-tap-cache fixtures through
  the same parser; JWS-envelope unwrapping (the `payload`
  field is a JSON-encoded string, not a nested object).
- `app/SteadingTests/BrewTapInfoParserTests.swift` —
  fixture-driven tests for `brew tap-info --json --installed`
  output: representative multi-tap input, the "no non-core
  taps" boundary, a tap with both `formula_names` and
  `cask_tokens` populated, a tap with neither.
- `app/SteadingTests/BrewPinTests.swift` — argv-builder tests
  for `brew pin` / `brew unpin`; integration tests through the
  mock runner asserting the manager updates its pinned-status
  view of the affected row on a successful exit and surfaces
  the failure on a non-zero exit.

Live tests (skipped if brew is not on the host, matching
[`BrewOutdatedLiveTests`](../../app/SteadingTests/BrewOutdatedLiveTests.swift)):

- `app/SteadingTests/BrewIndexLiveTests.swift` — spawns real
  `brew tap-info --json --installed` and real
  `brew info --json=v2 <known-formula>`, parses the output
  through production code, asserts shape and that at least one
  per-entry field expected by the manager (`name`, `desc`,
  `tap`) is populated.
- `app/SteadingTests/BrewJWSCacheLiveTests.swift` — reads the
  real JWS files at `~/Library/Caches/Homebrew/api/`,
  unwraps the envelope, parses through production code,
  asserts a known core formula (e.g. `git`) and a known core
  cask (e.g. `firefox`) decode with non-empty `desc`.

Existing test updates:

- [`app/SteadingTests/BrewUpdateManagerTests.swift`](../../app/SteadingTests/BrewUpdateManagerTests.swift)
  — drop the apply-pipeline tests (relocated to
  `BrewPackageManagerTests`). Add a tap-regen test that
  asserts a non-zero `brew info` exit does not push state
  into `.failed` and does not trigger retry, and that the
  on-disk cache file is left untouched on regen failure.

### Success Criteria

#### Automated

Targets are the existing
[`app/Makefile`](../../app/Makefile) wrappers over CLAUDE.md's
cheatsheet invocations.

- `make -C app generate` succeeds (xcodegen picks up new model
  files: `BrewPackageManager.swift`, parser files, fixture
  resources for tests).
- `make -C app build` succeeds with no new warnings beyond the
  pre-existing baseline.
- `make -C app test` passes; the count grows by the new suites
  enumerated under "Tests":
    - `BrewPackageManagerTests` — pure-helper assertions for the
      marking-derived-verb table, Status mode predicates
      (including `pinned`), Origin/Search-Results predicates,
      Apply-argv builders; manager state-machine assertions for
      the empty-mark, add-only, remove-only, partial-failure,
      autoremove-yes, autoremove-no Apply paths.
    - `BrewIndexParserTests` — fixture-driven decode of brew JWS
      payload (envelope unwrap then array decode) and the
      Steading tap-cache shape through the same parser.
    - `BrewTapInfoParserTests` — fixture-driven decode of
      `brew tap-info --json --installed` output, including the
      no-non-core-taps boundary.
    - `BrewPinTests` — argv builders for `brew pin` /
      `brew unpin`; manager updates its pinned view on success;
      surfaces failure on non-zero exit.
    - `BrewUpdateManagerTests` (existing, updated) — apply-pipeline
      tests removed; tap-regen tests added asserting non-zero
      `brew info` does not push state into `.failed`, does not
      trigger retry, and leaves the on-disk cache untouched.
    - `BrewIndexLiveTests`, `BrewJWSCacheLiveTests` — live tests
      that pass on a host with brew installed and skip cleanly
      where it isn't.

#### Manual

Run after `make -C app build` against a developer mac with
brew installed and at least one user-added tap (`brew tap` lists
something other than `homebrew/core` and `homebrew/cask`).

1. Open the Brew Package Manager from the Tools menu. The
   window opens to the new three-pane layout (sidebar / list /
   details), not the old upgrade-only layout.
2. Sidebar: switching among Status, Origin, Search Results
   swaps the main list's filter; Status's four values
   (`installed`, `not installed`, `upgradable`, `pinned`) each
   produce a non-empty list when a corresponding row exists on
   the host. There is no Sections mode.
3. Origin mode lists all installed taps and lets the user
   tap-add a new tap (e.g. typing a known public tap into the
   add field) and tap-remove an existing user-added tap; the
   list updates.
4. Search: typing a substring into the search field switches
   the sidebar to Search Results and filters by name + `desc`
   case-insensitively (e.g. searching "json" returns formulae
   whose name or `desc` mentions JSON).
5. Marking and Apply: mark one not-installed package, one
   outdated package, and one installed-current package; click
   Apply. The streaming output area shows `brew upgrade …`
   then `brew install …` then `brew uninstall …` running in
   sequence; the askpass sheet appears when sudo is needed and
   accepts a password; after `brew uninstall` succeeds, the
   autoremove confirmation dialog appears with "Yes" as the
   default action; pressing Enter runs `brew autoremove`,
   declining ends the pipeline.
6. Partial failure: deliberately mark a package whose install
   will fail (e.g. a non-existent name surfaced via a stale
   cache) — Apply stops at the failing sub-call, surfaces the
   exit code in the outcome indicator, and does not run the
   subsequent sub-calls. The streaming log retains the
   failing sub-call's output.
7. Pin/unpin: right-click an installed formula whose state is
   not pinned; the context menu shows **Pin**. Selecting it
   updates the row's pinned indicator. Right-click again; the
   menu now shows **Unpin**. Selecting it returns the row to
   unpinned. Casks do not show Pin/Unpin in their context
   menu.
8. Mark All Upgrades: with at least one outdated package on
   the host, the toolbar's **Mark All Upgrades** button checks
   every upgradable row.
9. Close-while-applying: start an Apply, attempt to close the
   window during the run — the existing confirmation dialog
   appears unchanged, and "Cancel and Close Anyway" terminates
   the in-flight brew sub-call.
10. Brew-updater background cycle: with the new build running,
    the dock badge, menu-bar count, and system banner behave
    identically to the prior release for the same outdated
    set; periodic check still fires on the configured interval.
11. Tap-cache regen: after a successful brew-updater check
    settle, the file at
    `~/Library/Caches/com.xalior.Steading/tap-index.json`
    exists and contains entries for the host's user-added
    taps (`grep '"tap":"<user-tap-name>"' tap-index.json`
    returns matches).
12. Tap-cache regen failure isolation: temporarily rename a
    tap directory under `$(brew --repository)/Library/Taps/`
    so its `brew info` invocation will fail, force a check via
    the toolbar's **Check Now**, observe that the brew-updater
    State settles to `.idle`, the dock badge / menu-bar count
    update normally for the outdated set, and the on-disk
    `tap-index.json` is unchanged from before the forced
    check. Restore the tap directory afterwards.

## Testing Strategy

The new code follows the repo's standing rule that tests exercise
production code (CLAUDE.md "Tests ALWAYS exercise production
code"). Pure helpers (mode predicates, marking-derived verb
rules, Apply argv builders, brew JWS-payload extraction, tap-info
parsing, package-index union) are `static` so tests call them
directly with canned inputs. State-machine behaviour is exercised
through the real manager with a mock runner injected at the
brew-spawn boundary — the runner returns canned `RunResult`
values; everything inside the manager (state transitions, settle,
Apply, tap-regen) is real production code. Live tests spawn real
brew against the developer's machine and skip cleanly when brew
is absent, matching
[`BrewOutdatedLiveTests`](../../app/SteadingTests/BrewOutdatedLiveTests.swift).

## References

- [`docs/discovery/discovery_brew-package-manager.md`](../discovery/discovery_brew-package-manager.md) — source
- [`docs/ARCHITECTURE.md`](../ARCHITECTURE.md) — the privileged-helper model and testing strategy
- [`docs/plans/plan_brew-updater_implementation.md`](plan_brew-updater_implementation.md) — prior plan that built the headless cycle being preserved
