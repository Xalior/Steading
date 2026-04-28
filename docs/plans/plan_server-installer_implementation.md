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
- **2026-04-28** — Yams 5.4.0 added via SPM. xcodegen regenerated; Steading target builds clean with the new dependency. Yams is wired only into the Steading app target — the helper does not parse YAML, so it stays Yams-free.
- **2026-04-28** — Schema types + ServiceDefinitionLoader landed with pure tests. 194/194 tests pass. Loader exercises strictness rejection (anchors/aliases/explicit tags), Yams Codable decode, and schema-invariant validation. Tests use inline YAML fixtures hitting the real loader.
- **2026-04-28** — DefinitionHash + BundleHashList + BundleDefinitionVerifier + ExternalDefinitionScanner landed. 201/201 tests pass.
- **2026-04-28** — SteadingDefinitionValidator CLI target landed (signed, hardened-runtime), wired as Steading's pre-build phase to write .bundle-hashes.plist into the bundle. Live tests spawn the real binary; build-fail fixture confirmed via 'validate: malformed YAML exits non-zero'. CLI also embedded in Steading.app/Contents/Executables/ for third-party authors. 205/205 tests pass.
- **2026-04-28** — PrivHelperRefusalList landed (pure Swift in Shared/, parametric tests over the blocklist). 219/219 pass.
- **2026-04-28** — Privileged helper extended end-to-end: protocol grew from 3 methods to 21, ApprovalsStore (helper-only, root-owned plist), PrivilegedFileWriter generalising the atomic write path, full PrivHelperClient async wrappers, version bumped to 0.1.0. Live XPC tests cover approval round-trip, writeFile approval gating, refusal-list defense in depth (writes to /etc/sudoers refused even when approved). 226/226 pass.

## Decisions & Notes

- **Yams strictness pre-pass:** Yams 5.4.0 holds `Node.anchor` as a weak reference, so anchors are gone from a composed Node tree by the time the loader walks it. Strictness check now does a source-byte scan (with quoted-string/comment stripping) before handing off to Yams' Codable decoder. Works for our schema; expected to false-positive on legitimate `&`/`*`/`!` in unquoted scalars (which would be unusual and easily fixed by quoting). Documented in code.
- **Build-phase validator:** plan called for a "shell script" but a shell script can't import Yams or call ServiceDefinitionLoader, so we'd violate the plan's "same loader" requirement. Resolved upfront with the user: SteadingDefinitionValidator becomes a signed CLI target that links the same Swift sources the runtime uses. Doubles as a deliverable for third-party YAML authors per the user's direction.

## Blockers

## Commits
