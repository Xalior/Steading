# Steading

**Small Business Server for macOS** — a native SwiftUI admin app that
turns a Mac into a cheap, easy small-office server. Steading wraps
macOS's built-in server facilities (SMB, Time Machine, SSH, printer
sharing, firewall, power management, Content Caching, Screen Sharing)
with a first-class GUI, and curates a catalog of self-hosted services
installed via Homebrew.

Targets macOS Tahoe (26) and forward, Apple Silicon. Licensed MIT.

## What it's for

- A developer's Mac that's also serving the office wiki or a git
  repo.
- A second Mac (often a Mini) on a desk or in a closet, providing
  LAN services.
- A Mac that used to be someone's desktop being repurposed as a
  dedicated server when its user gets a new machine.
- A Mac mini in a datacenter, reachable over the public internet.

The "my old desktop becomes our wiki server" migration is a
load-bearing scenario: a service running on a Mac must survive the
owner logging out, rebooting, power cuts, and the machine changing
roles. Steading exists to make that path work.

## What it's not

- Not Electron. Native SwiftUI all the way down.
- Not a replacement for macOS's built-in server facilities — it's a
  GUI over them. SMB, CUPS, SSH, `pf`, `pmset`, Time Machine, etc.
  stay where they are.
- Not a parallel environment. Steading adopts the user's existing
  Homebrew install; no second brew, no `_steading` user account.

## Status

Proof-of-concept, under active development. The app:

- Builds, signs with a real Developer ID identity, passes 49 live
  unit tests.
- Onboards cleanly, registers its privileged helper via
  `SMAppService`, and survives user approval + reboots.
- Actually controls macOS built-in services end-to-end (verified
  live with Content Caching enable/disable going through the XPC
  pipeline to `AssetCacheManagerUtil activate` as root).

The third-party service catalog (Caddy, PHP-FPM, MySQL, …) is
scaffolded but not yet install-capable.

## Quick start

Build prerequisites: Xcode 26.3+, Homebrew, `xcodegen`
(`brew install xcodegen`).

```sh
cd app
xcodegen generate
open Steading.xcodeproj       # build and run from Xcode
```

Or from the command line:

```sh
cd app
xcodegen generate
xcodebuild -project Steading.xcodeproj -scheme Steading \
    -configuration Debug build
xcodebuild -project Steading.xcodeproj -scheme Steading \
    -destination 'platform=macOS,arch=arm64' \
    -enableCodeCoverage NO test
```

On first launch the app runs through onboarding — it checks for
Homebrew, registers its privileged helper, and asks you to approve
it in System Settings → Login Items. That approval persists across
reboots.

## Repo layout

- **[DESIGN.md](DESIGN.md)** — product design doc. The gold master
  for what Steading is and isn't.
- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — how the code is
  organised, how the pieces fit together, the privileged helper
  model, the testing strategy.
- **[app/](app/)** — the macOS app: main target, privileged helper
  target, tests. See [app/README.md](app/README.md) for build
  instructions.
- **[scripts/](scripts/)** — VM harness for clean-room testing on
  fresh macOS installs. See [scripts/README.md](scripts/README.md).
- **[tart/](tart/)** — repo-local `TART_HOME` for VM images.
- **[CLAUDE.md](CLAUDE.md)** — guidance for AI coding agents working
  on this repo.

## Contributing

Work happens on short-lived feature branches, with a WIP tracker in
`docs/plans/` updated continuously so the git log tells the story.
See [CLAUDE.md](CLAUDE.md) for conventions — branch naming, commit
style, testing rules.

Before proposing changes to scope or behavior, read
[DESIGN.md](DESIGN.md). The design doc is the authoritative answer
to "should Steading do X?" — if your change conflicts with it, the
design doc is the one to update (with discussion), not the code
ahead of it.
