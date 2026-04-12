# Claude Code guidance for the Steading repo

This file is for AI coding agents (Claude Code, Cursor, and similar)
working on this repo. Human-facing documentation lives in
[README.md](README.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
Read those first — this file exists only to capture agent-specific
operating rules that wouldn't belong in docs a human would read.

## Before you change anything

1. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the code
   is laid out, the privileged-helper model, the testing strategy,
   and the architectural invariants that the rest of the codebase
   depends on.
2. Read [README.md](README.md) for the one-paragraph product pitch.
3. If the user's request conflicts with an architectural invariant
   (non-sandboxed, LaunchDaemons not LaunchAgents, adopts existing
   brew, one blessed implementation per category, owner decides
   policy, keychain-backed credentials) — ask the user before
   changing code. Invariants are structural; they aren't up to an
   agent to renegotiate.

## Hard rules

### Tests ALWAYS exercise production code

No stubs that reimplement logic. Pure functions go `public static`
so tests call them directly with canned inputs. Live tests hit the
real API against the real environment. Dependency injection is only
acceptable for feeding *boundary inputs* (empty params, nonexistent
paths) to the real production code — never for replacing logic with
a parallel fake.

Red flags that mean you're doing it wrong: `let fakeFileExists = …`,
"stub the parser to return", "the mock returns". Every one of those
is a parallel reimplementation that lets the production code be
completely broken while the test stays green.

Exemplar: [app/SteadingTests/BrewDetectorTests.swift](app/SteadingTests/BrewDetectorTests.swift)
— pure tests call the real parser, live tests spawn real `brew
--version`, boundary tests feed empty `searchPaths` to the real
detector.

### Never fabricate identifiers

Bundle IDs, team IDs, signing identities, API keys, Apple IDs, git
remotes, provisioning profile names, keychain access groups —
ask the user, don't invent. Even if a plausible value can be
inferred from context, do *not* use the inferred value. The user
has real ones; guesses end up baked into project files, commits,
and signed binaries.

Real values for this repo (safe to use because they've been
explicitly confirmed):

- Bundle prefix: `com.xalior`
- Main app bundle id: `com.xalior.Steading`
- Helper bundle id: `com.xalior.Steading.privhelper`
- Helper mach service: `com.xalior.Steading.privhelper`
- Dev team: `M353B943AK`
- Signing identity: `Apple Development: Darran David Rimron (NRSA2HJ3UB)`
- GitHub repo: `Xalior/Steading` (private)
- Brew tap (when it exists): `xalior/homebrew-steading`

### Don't touch running VM state

If `tart pull` is in progress, don't `rm -rf` the staging dir even
if the process looks orphaned. Verify process state with a correct
pgrep pattern — a backslash-pipe inside single quotes does NOT do
alternation in `pgrep`, use separate probes or `pgrep -fl tart | grep -v zsh`.

### `tart exec` has no `--` separator

It's `tart exec <vm-name> <executable> [args...]`, not
`tart exec <vm-name> -- <executable>`. The latter runs a binary
literally named `--` and fails with `executable file not found`.

### The vanilla VM image has no Tart Guest Agent

`ghcr.io/cirruslabs/macos-tahoe-vanilla:*` deliberately ships
without the guest agent (see `tart help exec`: "all non-vanilla
Cirrus Labs VM images already have the Tart Guest Agent
installed"). Use SSH (`admin`/`admin` via `sshpass`) for vanilla,
`tart exec` for xcode and other non-vanilla images. `vm-up.sh`
already probes both channels — don't special-case it further.

### TART_HOME is repo-local

Every tart invocation against this repo must set
`TART_HOME=/Volumes/McFiver/u/GIT/Steading/tart` (or
`$PWD/tart` from the repo root). Without it, tart silently falls
back to `~/.tart/` and drops tens of GB of image blobs on the
boot volume. `scripts/vm-*.sh` set it automatically; ad-hoc `tart …`
invocations must prefix it explicitly.

### TaskStop kills nohup'd children

The Bash tool's `TaskStop` sends SIGKILL to the process group,
which includes `nohup ... &` children. Don't rely on nohup to
survive a task stop — if you need a long-lived background process
outside the tool's control, spawn it via `launchctl` or detach
through another path.

## Collaboration style

The user is senior, remote-first (browser-based Claude Code), and
has explicit preferences:

- **Tight cadence.** No speculation when you can verify. Use tools
  rather than guess.
- **Own corrections cleanly.** If the user corrects something, save
  it as a durable rule (here, or in auto-memory) — don't apply it
  once and forget.
- **Short responses, no trailing summaries** unless asked for them.
- **Ask precise questions.** One at a time when possible; batch
  only when the answers are clearly linked.
- **Pre-planning discipline.** If a task is in planning mode, stay
  there until the user says otherwise. Don't jump ahead to
  implementation.

## Where things live

| Path | Contents |
|------|----------|
| `app/` | macOS app + helper Xcode project |
| `app/Steading/App/` | `@main`, AppDelegate, AppState |
| `app/Steading/Model/` | BrewDetector, built-in runners, ProcessRunner, PrivHelperClient |
| `app/Steading/Views/` | SwiftUI views |
| `app/Steading/Shared/` | compiled into BOTH targets (XPC protocol, allowlist) |
| `app/SteadingPrivHelper/` | privileged helper source |
| `app/SteadingTests/` | Swift Testing unit tests |
| `scripts/vm-*.sh` | VM harness |
| `tart/` | repo-local `TART_HOME` (gitignored except README) |
| `docs/plans/` | WIP trackers for feature branches |
| `~/.claude/projects/.../memory/` | durable agent memory across sessions |

## Build and test cheatsheet

```sh
# Regenerate Xcode project (after adding/removing source files)
cd app && xcodegen generate

# Build
cd app && xcodebuild -project Steading.xcodeproj -scheme Steading \
    -configuration Debug -arch arm64 ONLY_ACTIVE_ARCH=YES build

# Full test suite
cd app && xcodebuild -project Steading.xcodeproj -scheme Steading \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -enableCodeCoverage NO test

# Launch the last-built app
open ~/Library/Developer/Xcode/DerivedData/Steading-*/Build/Products/Debug/Steading.app

# VM clean-room smoke test (xcode base)
scripts/vm-up.sh steading-xcode && scripts/vm-smoke.sh steading-xcode
scripts/vm-down.sh steading-xcode

# VM release-test (vanilla base)
BASE_IMAGE=ghcr.io/cirruslabs/macos-tahoe-vanilla:26.4 \
    scripts/vm-up.sh steading-vanilla
# … release-test scripts TBD …
scripts/vm-down.sh steading-vanilla
```

## Git workflow

- Feature branches: `feature/<short-name>`, cut from `main`.
- Start every non-trivial branch with a WIP tracker at
  `docs/plans/plan_<branch-name>_implementation.md`. Update it
  continuously — progress log, decisions, blockers, commits. It
  tells reviewers the story when they scan the branch.
- Commit early, commit often. Push after every commit — the remote
  git log is the primary progress signal for anyone watching.
- Conventional commit prefixes: `feat:`, `fix:`, `refactor:`,
  `docs:`, `test:`, `chore:`, `wip:`.
- Never amend pushed commits. Never force-push.
- Use the `/implement-with-remote-feedback` skill for non-trivial
  feature work — it enforces the branch+WIP+push rhythm.

## User's environment

- Dev mac: macOS Tahoe 26.4, Xcode 26.3, Swift 6.2.4, Apple Silicon.
- Repo volume: `/Volumes/McFiver` (external drive). VM images also
  live there via `TART_HOME`.
- User connects remotely via Claude Code in a browser —
  "almost like SSH" — so GUI clicks on the host require them to
  Screen Share in. Prefer non-GUI-dependent verification; when a
  GUI interaction is unavoidable, bundle clicks into a single
  at-desk session rather than spreading them across the work.
- Claude Code extension binary has Screen Recording, Accessibility,
  and Automation permissions granted — `screencapture`,
  `osascript` UI scripting, and `tell application "System Events"`
  all work from the Bash tool.

## Common tasks — proven recipes

### Add a new source file to a target

1. Create the `.swift` file under the target's source dir.
2. `cd app && xcodegen generate` — picks up new files
   automatically via recursive source globs.
3. Build to confirm.

### Toggle a macOS built-in service for testing

Content Caching is the safest to toggle (no impact on remote
access). From the app UI: sidebar → Content Caching → Enable.
From CLI for verification: `/usr/bin/AssetCacheManagerUtil status`.

### Verify the privileged helper is healthy

```sh
launchctl print-disabled system | grep steading
# "com.xalior.Steading.privhelper" => enabled  ← good
```

If not enabled, the user needs to approve it in System Settings →
General → Login Items & Extensions. The app's onboarding flow
surfaces this automatically.
