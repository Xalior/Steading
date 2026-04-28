# Implementation: Server Installer

**Status:** In Progress
**Branch:** `main` (working directly on main, per user direction)
**Plan:** [docs/plans/plan_server-installer.md](plan_server-installer.md)

## Preflight Decisions

- **Branch strategy:** working directly on `main`. User declined a feature branch ("NO BRANCH, work on main"). Commits stay local; no push during the parcel.
- **Baseline verification:** skipped — user confirmed they already ran the test suite on `main` prior to starting.
- **Plan-deferred decisions:**
  - **Yams dependency:** added via SPM in `app/project.yml`. No SPM packages currently configured; this introduces the `packages:` section.
  - **Brew tap repo:** `xalior/homebrew-steading` does not exist yet. Will be created via `gh` CLI as a **public** GitHub repo. User authorised gh CLI use for this. Tap holds six wrapper formulae (`steading-caddy`, `steading-php-fpm`, `steading-mysql`, `steading-redis`, `steading-tailscale`, `steading-stalwart`); each is a `depends_on "<upstream>"` one-liner.
  - **VM clean-room verification:** plan already defers vanilla-VM verification until the release-test harness lands; dev-mac manual verification is the gating signal for Phase 1.

## Phase Status

- **Phase 1: Server Installer** — in progress.

## Progress Log

- **2026-04-28** — Phase 1 opened. Working order: foundation (Yams + schema types + loader + hash script + verifier + refusal list) → helper extensions (XPC methods + approvals plist) → consent gate UI → picker + installed-services store → wizard renderer → install/uninstall pipeline → MySQL reference (tap + wrapper + mysql.yml) → status pane → view logs → edit config → failure recovery → catalog completion (5 remaining services + wrappers).

## Decisions & Notes

## Blockers

## Commits
