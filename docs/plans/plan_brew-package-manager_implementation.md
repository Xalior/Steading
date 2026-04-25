# Implementation: brew-package-manager

**Status:** In Progress
**Branch:** `main`
**Plan:** [`docs/plans/plan_brew-package-manager.md`](plan_brew-package-manager.md)
**PR:** n/a (no-PR strategy)

## Preflight Decisions

- **PR strategy:** `none` (working on `main` per user instruction)
- **Comment trust minimum:** n/a (no PR)
- **Baseline verification:** user-confirmed `make -C app test` green on `main` prior to start
- **In-flight labels created:** n/a
- **Tracker layout:** `single`
- **Plan-deferred decisions:**
  - Brew-spawn boundary (`BrewPathResolver`, `AskpassHelperResolver`): plan explicitly delegates wiring to implementer; will be resolved as the manager split lands.

## Sprints

### Sprint 1 — Brew data parsers + tap-regen on `BrewUpdateManager`

**Covers:** Phase 1 → "Tap-regen step on `BrewUpdateManager`" + parser portions of the Tests subsection.

**Status:** complete

**Changes:**
- New `BrewIndexParser` — decodes both brew's JWS-envelope cache (`~/Library/Caches/Homebrew/api/{formula,cask}.jws.json`) and the Steading tap-cache shape through one Codable path. JWS envelope's `payload` is a JSON-encoded string that decodes to `{"formulae":[…], "casks":[…]}`.
- New `BrewTapInfoParser` — decodes `brew tap-info --json --installed`.
- Soft post-settle tap-regen step on `BrewUpdateManager`: after a successful `runChain`, run `brew tap-info --json --installed`, filter out `homebrew/core` and `homebrew/cask`, collect the union of `formula_names` and `cask_tokens`, run a single `brew info --json=v2 …` against that union, write the result to `~/Library/Caches/com.xalior.Steading/tap-index.json`. Failure-isolated: cannot push state to `.failed`, cannot trigger retry; partial output never written; prior cache file left untouched on failure.
- Tests: `BrewIndexParserTests`, `BrewTapInfoParserTests`, `BrewIndexLiveTests`, `BrewJWSCacheLiveTests`; `BrewUpdateManagerTests` gains tap-regen cases (non-zero `brew info` exit ⇒ no `.failed`, no retry, on-disk cache untouched).

**Success Criteria (Automated):**
- `make -C app generate` succeeds (xcodegen picks up new files + fixtures).
- `make -C app build` green, no new warnings.
- `make -C app test` green; new tests exercised: `BrewIndexParserTests`, `BrewTapInfoParserTests`, `BrewIndexLiveTests`, `BrewJWSCacheLiveTests`, plus the new tap-regen cases in `BrewUpdateManagerTests`.

**Success Criteria (Manual):** none surfaced this sprint — the regen step is invisible until Sprint 2 lands the UI. Manual SC #11 and #12 are deferred to Sprint 2's walkthrough where they sit alongside the rest of the window-level checks.

### Sprint 2 — `BrewPackageManager` + view rebuild + narrowing + wiring

**Covers:** Phase 1 → "`BrewUpdateManager` narrowing", "New `BrewPackageManager`", "`BrewPackageManagerView` rebuild", "App wiring", and the remaining Tests subsection.

**Status:** in progress

**Changes:**
- New `app/Steading/Model/BrewPackageManager.swift` — main-actor `@Observable`. Owns: unified package index keyed by full name; `enum SidebarMode { case status, origin, searchResults }`; search text + computed search results; per-row marking state with verb derived from row state at Apply time; tap list + add/remove; Apply pipeline (add phase: `brew upgrade …` then `brew install …`; remove phase: `brew uninstall …`; post-uninstall autoremove confirmation with default-yes; partial-failure halt on first non-zero); pin/unpin verbs (no askpass). Reads `outdated` from `BrewUpdateManager` for upgradable subset and Mark All Upgrades.
- Narrow `BrewUpdateManager`: remove `.applying` State case; remove `apply(_:)`, `cancelApply()`, `applyTask`, `applyHandle`, `applyLog`, `recentApplyOutcome`, `appendLog`, `finishApply`, `runBrewUpgrade`, `ApplyOutcome`, `Buttons`, `brewUpgradeArgv`. Keep `BrewPathResolver`, `AskpassHelperResolver` (regen still uses brew-spawn). Relocate `buttons(state:markedCount:outdatedCount:)` to `BrewPackageManager` or a pure-helpers file.
- Rebuild `BrewPackageManagerView` against `BrewPackageManager`: three-pane (sidebar / list / details), per-row checkbox + sortable columns including marked-state and pinned indicator, toolbar with **Mark All Upgrades** / **Apply** / **Check Now** (calls `BrewUpdateManager.check()`). Row context-menu **Pin** / **Unpin** (formulae only, visibility gated by current pinned state). Search field forces sidebar to `searchResults` when non-empty; case-insensitive substring against name + `desc`. Existing askpass sheet, close-while-applying confirmation, post-uninstall autoremove confirmation, streaming-output disclosure all re-homed onto the new manager.
- Wire `BrewPackageManager` into `SteadingApp` environment alongside `BrewUpdateManager`; inject into the Brew Package Manager window scene.
- Tests: new `BrewPackageManagerTests` (pure helpers — verb derivation, Status/Origin/SearchResults predicates, Apply argv builders; mock-runner state-machine — empty-mark no-op, add-only skips remove and autoremove, remove-only skips add + presents autoremove, partial-failure halts on first non-zero, autoremove-no ends cleanly, autoremove-yes runs `brew autoremove`); new `BrewPinTests` (argv builders + manager pinned-view update on success / failure surfacing on non-zero); `BrewUpdateManagerTests` drops apply-pipeline cases.

**Success Criteria (Automated):**
- `make -C app generate` succeeds.
- `make -C app build` green, no new warnings.
- `make -C app test` green; new suites exercised (`BrewPackageManagerTests`, `BrewPinTests`); apply-pipeline cases removed from `BrewUpdateManagerTests`.

**Success Criteria (Manual)** — full Phase 1 walkthrough on the developer mac, brew installed, ≥1 user-added tap:
1. Brew Package Manager from Tools menu opens to three-pane layout (not the old upgrade-only one).
2. Sidebar Status/Origin/Search Results swap the list filter; Status's four values (`installed`, `not installed`, `upgradable`, `pinned`) each produce non-empty lists where applicable. No Sections mode.
3. Origin lists installed taps; tap-add a known public tap and tap-remove an existing user-added tap; list updates.
4. Typing a substring switches sidebar to Search Results; case-insensitive substring against name + `desc`.
5. Mark one not-installed, one outdated, one installed-current package; click Apply. Streaming log shows `brew upgrade` → `brew install` → `brew uninstall`; askpass sheet appears for sudo; after `brew uninstall` succeeds, autoremove confirmation appears with Yes default; Enter runs `brew autoremove`, declining ends.
6. Partial failure: mark a name that will fail; Apply stops at the failing sub-call, exit code surfaces in the outcome indicator, subsequent sub-calls do not run; log retains the failing sub-call's output.
7. Pin/unpin: right-click an installed not-pinned formula → Pin visible; selecting updates the row's pinned indicator. Right-click again → Unpin visible; selecting reverts. Casks show no Pin/Unpin.
8. Mark All Upgrades checks every upgradable row.
9. Close-while-applying: start Apply, attempt to close → confirmation dialog appears; "Cancel and Close Anyway" terminates the sub-call.
10. Brew-updater background cycle: dock badge / menu-bar count / system banner identical to prior release for the same outdated set; periodic check fires on configured interval.
11. Tap-cache regen: after a successful settle, `~/Library/Caches/com.xalior.Steading/tap-index.json` exists with user-tap entries (`grep '"tap":"<user-tap>"' tap-index.json`).
12. Tap-cache regen failure isolation: rename a tap dir under `$(brew --repository)/Library/Taps/`, force a check via Check Now, observe state settles to `.idle`, badge/count update normally for outdated set, on-disk `tap-index.json` unchanged. Restore the tap dir afterwards.

## Tasks

- [x] Sprint 1: Brew data parsers + tap-regen on `BrewUpdateManager`
- [ ] Sprint 2: `BrewPackageManager` + view rebuild + narrowing + wiring

## Progress Log

- 2026-04-25: Refined into 2 sprints. User elected to collapse the model + view + narrowing + wiring work into one user-visible cut (Sprint 2) so the manual SC walkthrough covers everything in one pass. No PR; autonomous between sprints — only stop on blockers or end-of-Sprint-2 manual walkthrough.
- 2026-04-25: Sprint 1 opened — exploring existing brew-related code to ground the parser + tap-regen design before writing.
- 2026-04-25: Sprint 1 complete. Landed `BrewIndexParser` + `BrewTapInfoParser` (commit `83d2572`), the post-settle tap-regen step on `BrewUpdateManager` with failure-isolation tests (commit `386dfc9`), and live tests against real brew + a deadlock fix to `defaultRunner` discovered while exercising `tap-info` output (~330 KB exceeded the OS pipe buffer; commit `38f00e8`). Test count went from 137 → 147; all green. Sprint 2 opened — `BrewPackageManager` + view rebuild + narrowing + wiring.

## Decisions & Notes

- **2026-04-25 (Sprint 1):** `defaultRunner` had a latent pipe-buffer deadlock — sequential `waitUntilExit` then `readToEnd` blocks on any brew subcommand whose stdout exceeds the OS pipe buffer (~64 KB). Surfaced when wiring `brew tap-info --json --installed` into the regen path; tap-info emits ~330 KB on this dev mac. Fixed in commit `38f00e8` by draining both pipes on background tasks concurrent with `waitUntilExit`. Pre-existing brew calls (`update`, `outdated`) emit small enough output to not have triggered it.
- **2026-04-25 (Sprint 1):** Tap-regen wiring keeps `BrewPathResolver` and `AskpassHelperResolver` on `BrewUpdateManager` since the regen step uses the brew-spawn boundary and the plan-deferred decision gives the implementer freedom to share or split. Sprint 2 will need them to also serve `BrewPackageManager`'s Apply pipeline.

## Blockers

## Last-seen Feedback State

- **Last-seen comment id:** none yet
- **Last-seen review id:** none yet
- **Last-seen check suite:** none yet
- **Ignored (below trust threshold):** —

## Commits
