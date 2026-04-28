# Plan: Server Installer

**Status:** Ready for Implementation
**Source:** `docs/discovery/discovery_server-installer.md`

## Overview

Steading's base application function: installation and config management
of the v1 **Services catalog** (Caddy, PHP-FPM, MySQL, Redis, Tailscale,
Stalwart). One UI parcel hosts every flow — picker, install wizard,
install/uninstall progress, per-service status, and edit-config — in
the existing `NavigationSplitView`'s detail pane. The installer is
data-driven from per-service definition files so adding a service is
dropping a file in rather than editing Swift, and the same definition
machinery is the proto-version of what the Webapps catalog will reuse.

## Current State

- Sidebar already lists Services, Webapps, and macOS Built-ins
  ([app/Steading/Views/SidebarView.swift](../../app/Steading/Views/SidebarView.swift)).
- Service catalog entries exist as static dummy data in
  [app/Steading/Model/ServiceCatalog.swift](../../app/Steading/Model/ServiceCatalog.swift)
  with no install state.
- Selecting a Service routes to a placeholder `CatalogDetailView`
  ([app/Steading/Views/CatalogDetailView.swift](../../app/Steading/Views/CatalogDetailView.swift))
  whose Install button is a no-op.
- No `+` affordance on the Services sidebar list and no picker.
- Privileged helper exposes `runCommand` (allowlisted executables only),
  `writeHostsFile` (per-target named method, atomic, mode-pinned), and
  `helperVersion`
  ([app/Steading/Shared/SteadingPrivHelperProtocol.swift](../../app/Steading/Shared/SteadingPrivHelperProtocol.swift),
  [app/Steading/Shared/HostsFileWriter.swift](../../app/Steading/Shared/HostsFileWriter.swift)).
  No methods for service-user creation, LaunchDaemon plist writes,
  service config-file writes, dir init, firewall rules, or daemon
  start/stop/restart.
- Existing apply-pipeline UI pattern (progress bar + disclosure
  triangle for streaming output) lives in
  [app/Steading/Views/BrewPackageManagerView.swift:448-490](../../app/Steading/Views/BrewPackageManagerView.swift#L448-L490)
  and is the model the install/uninstall progress UI will reuse.
- `StreamingProcessRunner`
  ([app/Steading/Model/StreamingProcessRunner.swift](../../app/Steading/Model/StreamingProcessRunner.swift))
  is the generic streaming-subprocess surface available for the brew
  half of the pipeline.

## Desired End State

- The Services-list `+` button opens an in-pane picker showing cards
  for every entry in the v1 Services catalog, styled like the sidebar
  rows.
- Selecting a card runs the per-service install wizard (data-driven
  from that service's definition file): one section per pane, advanced
  toggle hiding non-decision settings, inline help/warnings, preflight
  conflict aborts.
- Install runs as one continuous progress UI (brew + post-brew helper
  steps presented as one install) with a streaming-output disclosure.
  On completion, the new service appears in the sidebar Services list
  and clicking it opens its status pane.
- The status pane exposes the per-service lifecycle (restart, stop,
  start, status, view logs, edit config, uninstall, restart-required
  indicator, enable-on-boot — full set settled in Phase 1).
- Uninstall runs reverse teardown in the same progress UI.
- Install failure mid-pipeline triggers cleanup that returns the system
  to its pre-install state.
- Credentials supplied during install live in the macOS Keychain under
  named Steading entries; Steading keeps a list of which entries
  belong to which service.
- Each install registers a top-level meta-package marker that the Brew
  Package Manager can recognise (the BPM's warning UX is out of scope
  for this parcel — see What We're NOT Doing).
- Edit Config presents the same wizard panes for ongoing editing,
  plus a raw-text-editor fallback tab. Saves do not auto-restart;
  a "restart required" signal lives on the status pane.

## Key Discoveries

### Definition files: YAML, in the app bundle, with build- and load-time validation

**Format: YAML.** The data shape is panes → fields → validation
rules → config-file mappings, with multi-line help and warning text.
That's YAML's strong suit. Parsed via Yams (Swift, YAML 1.2 — the
Norway-problem and similar implicit-typing footguns are fixed at the
spec level, not just by convention).

Per-service definition files ship as bundle resources under
`app/Steading/Resources/ServiceDefinitions/<service-id>.yml`. They
are read-only at runtime from the user's perspective, but the on-disk
location inside an installed `Steading.app` (`Contents/Resources/
ServiceDefinitions/`) is reachable to a determined owner who edits the
bundle directly — handled by the validation strategy below.

### Definition-file validation: build-time AND load-time

- **Build-time.** A build-phase script validates every
  `ServiceDefinitions/*.<ext>` against the schema and fails the build
  if any file is malformed. Catches bad files in CI before ship.
- **Load-time.** The runtime loader re-validates on launch. A
  malformed file is logged, that catalog entry is omitted from the
  picker, and the rest of the catalog still loads. This is the
  fallback for a user who has hand-edited a bundle resource on the
  installed app.

Both layers run the same validator over the same schema, so they can't
disagree.

### YAML parser strictness

Yams is configured to reject anchors, references, custom tags, and any
YAML feature beyond plain mappings/sequences/scalars. Schema-violating
input is treated as a parse error → the file isn't loaded. This
removes type-confusion as an attack surface on inputs that may have
been edited by the owner or supplied externally.

### YAML may be added or replaced at runtime, gated by a build-time hash

Owners may drop replacement or net-new YAML into the bundle's
`Resources/ServiceDefinitions/` directory or into an external data
directory (e.g. `~/Library/Application Support/Steading/
ServiceDefinitions/`). Externally-supplied YAML matching a built-in
service-ID *replaces* the built-in. This is intentional power-user
extensibility; it is also the entire reason the security model below
exists.

### Bundle YAML integrity: build-time hashes, runtime verification

At build time, a build-phase script computes a content hash of every
`Resources/ServiceDefinitions/*.yml` file and writes the hash list as
a plist also under `Resources/`. The hash list is therefore covered
by the app bundle's codesign envelope (`_CodeSignature/CodeResources`)
and cannot be modified without breaking the signature.

At startup, the main app re-hashes every bundle YAML and compares to
the recorded list. Matches → silent pass, the YAML is loaded as
trusted. Mismatch (or YAML in the bundle that has no recorded hash) →
treated identically to externally-supplied YAML — the user-consent
gate below applies.

### User-consent gate for any non-built-in YAML

Any YAML that isn't a hash-matched built-in — modified bundle YAML,
external-data-dir YAML, net-new YAML — must be approved before it
loads or before any helper write derived from it is accepted.

Approval flow:

- The main app shows a modal blocking dialog before main UI opens.
  The dialog identifies the YAML by name/path and lists the file
  paths (literal where known, templated where the path depends on
  per-instance owner input) the YAML declares writes to.
- The user clicks Approve or Deny.
- Approve triggers a live admin-password / Touch ID challenge via
  Authorization Services. The challenge is the consent ceremony:
  even if the main-app process were compromised at runtime, an
  attacker can't inject approvals without the user physically
  entering their admin credentials at that moment.
- On successful auth, the main app calls a helper XPC method
  `recordApproval(yamlPath:hash:)` to commit the approval.
- Deny → the YAML is not loaded; its service does not appear in the
  picker; no derived helper writes are accepted.

### Approval state lives in helper-owned, root-only storage

Persisted approvals live at
`/Library/Application Support/Steading/approvals.plist`, owned
`root:wheel`, mode `0600`. Only the helper (running as root) can read
or write it. The main app cannot tamper with it directly — every
mutation goes through the helper's `recordApproval` XPC method, gated
by the existing mutual codesign pin. This closes the local-attacker
"drop a YAML and forge an approval" path: dropping YAML in the data
dir is allowed; forging an approval requires either defeating the
codesign pin or staging the live admin-password challenge.

Approval semantics:

- One stored approval per YAML, keyed by path-or-service-ID, valued
  by hash. Not stacked.
- Re-approval triggered when the YAML's current hash doesn't match
  the stored one. Stored value overwritten on re-approve. **No diff
  display** — only the prior hash is stored, not the prior content,
  so re-approval shows the current YAML's full intended write paths
  and the user approves or denies the whole current state.
- An approved external/bundle-modified YAML cannot be reverted to
  any other state except by replacing it with the built-in original
  (which auto-trusts via the build-time hash match).
- Same flow applies to services and webapps; YAML kind doesn't
  change the gate.

### Helper write surface: wide, with structural refusal list

Per the consent model above, the helper's *primary* trust gate is
"the calling main app is codesign-pinned and the writes derive from
hash-matched-or-user-approved YAML." The helper does not enumerate
allowed paths — that's what the YAML/consent gate handles.

Defense in depth: the helper additionally refuses categorically
illegitimate writes regardless of the consent state. Refused:

- SUID, SGID, or sticky bits in the requested mode
- Path traversal (`..` components), non-canonical paths
- Symlinks where the resolved target is outside the requested
  parent directory
- Writes to a hardcoded blocklist that no Steading-managed service
  has any business touching: `/etc/sudoers*`, `/etc/pam.d/`,
  `/etc/master.passwd`, `/var/db/sudo/`, `~/.ssh/`,
  `/Library/PrivilegedHelperTools/*` other than Steading's own
  helper, `/System/`, `/private/etc/security/audit_*`, etc.

This list catches a user who is socially-engineered into approving a
malicious YAML — same threat model as Apple's own "this app wants to
control your computer" prompts that people frequently click yes on.

### Prefs surface for re-scan and revocation

Prefs → Advanced gets two controls:

- **Rescan data directory.** Picks up newly-dropped external YAMLs
  without restarting; each newly-discovered YAML triggers the consent
  gate.
- **Approved external YAMLs.** Lists every external/bundle-modified
  YAML the user has approved, with path, content hash short, and
  approval timestamp. Each row has a **Forget** button — calling
  `forgetApproval` on the helper, removing the entry from the
  helper-owned approvals plist. Next time the YAML is encountered
  (next scan or app launch), the consent gate fires again from
  scratch. Modelled on the same "forget warnings" pattern used
  elsewhere in the product.

### WriteTarget pattern types — literal, templated, directory

A YAML's `WriteTarget` declarations come in three flavours, in order
of preference:

- **Literal path.** A specific path string — e.g.
  `/opt/homebrew/etc/my.cnf`. Helper accepts only that exact path.
  Tightest, most audit-legible.
- **Templated path.** A path with named placeholders constrained by
  per-placeholder validation rules in the YAML — e.g.
  `Caddyfile.d/{hostname}.caddy` with `hostname: {regex:
  "^[a-z0-9.-]+$", maxLength: 253}`. The approvals plist stores the
  template + placeholder constraints; per-write calls supply
  concrete values, the helper renders the template, validates the
  resolved path matches, and only then writes. Right for cases like
  Caddy per-vhost config where the path varies but the *shape*
  doesn't.
- **Directory approval.** A directory under which any file may be
  written — e.g. `/opt/steading/<svc>/dropins/`. Approvals plist
  stores the directory; the helper accepts writes to any path
  whose canonical resolution stays under it. Loosest; reserved for
  cases where neither literal nor templated patterns capture the
  real surface.

**YAML authors pick the tightest fit that captures the actual write
shape.** A literal path beats a templated one beats a directory.
Reviewers reading a YAML can see at a glance which mechanism is in
use. The helper supports all three; the consent gate displays which
flavour each WriteTarget uses so an approver can see whether they're
greenlighting one specific file, a constrained pattern, or a whole
directory.

### Service-user UID allocation policy

When `createSystemUser` is asked for a service user (e.g. `_mysql`,
`_redis`, `_caddy`):

1. **Adopt the Apple-blessed UID if it already exists for that
   service name.** Tahoe ships a number of `_<service>` users with
   reserved UIDs — `_mysql:74`, `_www:70`, `_postgres:216`,
   `_dovecot:214`, etc. (verified by `dscl . -list /Users
   UniqueID`). If the requested name already exists with a UID, the
   helper adopts that UID rather than minting a new one — the user
   is already there.
2. **Otherwise allocate the next free UID in Steading's reserved
   range, 410-440.** This range sits in the gap between Apple's
   currently-densely-populated daemon zone (200-308 on Tahoe, with
   the front edge creeping upward each release) and the singleton
   `_oahd:441`. It's small enough to be a clear reservation, large
   enough for the v1 catalog plus headroom. Steading documents which
   UID belongs to which `_<service>` so reinstall produces the same
   UID for the same name.

Range choice rationale: Apple's daemon-UID growth pattern (over the
last five releases) is upward from the high 200s. Starting at 410
keeps Steading's range above any reasonable Apple expansion horizon
without colliding with existing assignments.

Reassessment trigger: if a future macOS release allocates inside
410-440, the helper's allocation policy gets revisited (move
Steading's range higher, or fall back to a higher zone). UID
assignments persist on existing machines and don't shift; the
policy change applies only to net-new mints.

### Top-level meta-package = wrapper formula in `xalior/homebrew-steading`

Per discovery's *Top-level meta packages* section, every
Steading-managed install introduces a wrapper formula that triggers
the install of the upstream. Concrete shape:

- One wrapper per Services-catalog entry, named `steading-<service-id>`
  (`steading-caddy`, `steading-mysql`, `steading-redis`, …) and
  hosted in `xalior/homebrew-steading`.
- Each wrapper is minimal: `depends_on "<upstream>"` and nothing
  else. Matches the house-style packaging split — formulae stay
  binary-only, the app install flow does everything else.
- For non-homebrew-core upstreams (Stalwart), the tap holds both
  the real formula and the wrapper that depends on it.
- BPM signal: tap origin `xalior/homebrew-steading`. Naming prefix
  `steading-` is also reliable but the tap origin is the canonical
  marker since it survives any future wrapper rename.

Steading installs `steading-<svc>` (not `<svc>` directly) so brew's
dep graph carries the relationship. On uninstall Steading runs
reverse-teardown via the helper, then `brew uninstall steading-<svc>`;
the upstream dep is left behind unless the owner chooses the
"Uninstall it too" path from discovery's cleanup dialog.

### Status-pane contents for v1

- **Header.** Service name, upstream version (from brew), live state
  badge (running / stopped / failed).
- **State card.** Live status, last-started timestamp, uptime when
  reachable from `launchctl print system/<label>`.
- **Restart-required banner.** Visible above the action row when
  Edit Config has saved a change since the last daemon start/restart.
- **Action row.** Start / Stop / Restart (state-gated like
  [`BuiltInServiceDetailView`](../../app/Steading/Views/BuiltInServiceDetailView.swift)),
  Edit Config (opens the structured editor in-pane — see *Edit
  Config* in Changes Required), View Logs (priv-helper
  install/uninstall log plus a tail of the service's own log file —
  polished log UX deferred to follow-on), Uninstall (confirm →
  reverse teardown).
- **Enable-on-boot toggle.** Flips the LaunchDaemon plist's
  `Disabled` key via the helper. Lets an owner keep a service
  installed but inactive at boot.
- **Listening endpoints.** What addresses and ports the service is
  bound to — sourced from `lsof -nP -iTCP -sTCP:LISTEN -p <pid>`
  (or equivalent) at status read time, or declared in the YAML when
  the live socket is unreachable.
- **Files & directories panel.** The set of paths this service
  owns — config files, data dirs, log dirs — declared in its YAML
  definition file. Click-through opens in Finder. Same data the
  uninstall reverse-teardown operates on, surfaced for the owner's
  inspection.
- **Update-available indicator.** Hooked into the existing
  [`BrewUpdateManager`](../../app/Steading/Model/BrewUpdateManager.swift)
  headless `brew outdated` cycle: the indicator queries the
  outdated set for the service's upstream formula token (e.g.
  `mysql` for `steading-mysql`) and surfaces "Update available:
  X → Y" with an upgrade button when present. Reuses the single
  source of truth for outdated state rather than spawning its own
  brew query.

### Items deferred to follow-on (out of scope for this parcel)

- Disk-usage / data-dir size display
- Credentials-stored view (per-service Keychain-item summary)
- Polished log-viewer UX beyond the initial tail
- Aggregated warning audit panel (DESIGN.md open question)

## What We're NOT Doing

- **Webapps.** Their install flow is a separate parcel. Definition-file
  reuse for webapps is intentional but the webapp catalog is not in
  scope here.
- **Adoption of existing brew installs.** Out of scope for this parcel
  (lantern hung in [README.md](../../README.md) under Roadmap).
- **Picker behaviour for already-installed services.** Whether the
  picker hides, greys, or shows-and-refuses an already-installed
  service is out of scope for this parcel.
- **Brew Package Manager warnings on Steading meta-package removal.**
  That work lives in BPM, not here. This plan only emits the marker
  the BPM can later recognise.
- **Aggregated warning audit view.** Inline warnings only; the
  "what's non-default about this machine" panel is a separate question
  flagged in DESIGN.md.

## Approach

**Single-phase vertical slice, MySQL as reference service.** One
phase stands the whole Server Installer pipeline up end-to-end —
picker, wizard, install/uninstall progress, status pane, **and the
post-install Edit-config UI** — against MySQL, because MySQL
exercises credentials/Keychain, config-file writes, service user
creation, plist write, data-dir init, and full status-pane lifecycle
in a single service. Once the framework is proven against MySQL,
the remaining v1 Services catalog (Caddy, PHP-FPM, Redis, Tailscale,
Stalwart) is added as definition files plus whatever incremental
helper methods their distinct capabilities require (firewall rules
for Caddy public exposure, etc.). Edit-config reuses the wizard's
pane renderer rather than getting its own — installing and editing
are the same renderer over the same data, just initialised
differently.

## Phase 1: Server Installer

### Overview

Build the entire Server Installer pipeline against MySQL as the
reference service, then fill the rest of the v1 Services catalog
(Caddy, PHP-FPM, Redis, Tailscale, Stalwart) as YAML definition files
plus whatever incremental helper additions their distinct capabilities
require. By the end of this phase: the `+` button on the Services
sidebar opens an in-pane picker; selecting any v1 service runs its
data-driven install wizard; install runs as one continuous progress UI
spanning brew + post-brew helper steps; the new service appears in
the sidebar with a status pane exposing start/stop/restart, listening
ports, files-and-dirs panel, update-available, view-logs,
enable-on-boot, edit-config (structured editor over the same wizard
panes plus a raw-text fallback tab), and uninstall (reverse teardown
in the same progress UI). Install failure mid-pipeline rolls the
system back to its pre-install state. Credentials supplied during
install are stored in the macOS Keychain under named Steading entries
with a per-service inventory.

### Changes Required

#### Definition-file engine

- Swift schema types in `app/Steading/Model/ServiceDefinition/`:
  `ServiceDefinition`, `Pane`, `Field`, `FieldKind` (text, secret,
  toggle, choice, hostname, port, path, integer), `Validation`,
  `WarningPredicate`, `WriteTarget` (path or path-template + mode +
  owner + size cap), `PreflightCheck`, `Dependency`. Conform to
  `Codable` for direct Yams decoding.
- Yams loader in `ServiceDefinitionLoader.swift`: strict-mode parse
  (reject anchors, custom tags, type-coercion outside the explicit
  schema), schema validation, returns
  `Result<ServiceDefinition, [SchemaError]>`.
- Build-phase script `app/scripts/hash-service-definitions.sh`:
  reads every `app/Steading/Resources/ServiceDefinitions/*.yml`,
  computes SHA-256, writes
  `app/Steading/Resources/ServiceDefinitions/.bundle-hashes.plist`.
  Wired into the Steading target in `app/project.yml` as a Run
  Script build phase before "Copy Bundle Resources." Script also
  fails the build if any YAML fails strict-parse + schema-validate
  using the same loader the runtime uses.
- Runtime verifier `BundleDefinitionVerifier.swift`: at app launch,
  re-hashes every bundle YAML and compares against
  `.bundle-hashes.plist`. Returns `(matched, mismatched, unrecorded)`
  partitions.
- External-dir scanner `ExternalDefinitionScanner.swift`: enumerates
  `~/Library/Application Support/Steading/ServiceDefinitions/*.yml`,
  composes with bundle YAML (external entries replace built-ins by
  service-id), returns the merged set + per-entry origin
  (`bundleTrusted`, `bundleModified`, `external`).
- Reference definition: `mysql.yml` with panes for Welcome, Preflight
  (port 3306 free, no existing `/opt/homebrew/etc/my.cnf`, mysql
  binary present after brew install), Admin Account (root password
  → Keychain), Bind Address (loopback default; warning predicate on
  non-loopback), Data Directory (default `/opt/steading/mysql/data`),
  Advanced (innodb_buffer_pool_size, log paths, service-user
  override). Drives a generated `my.cnf` plus the LaunchDaemon plist
  contents. WriteTargets enumerated.

#### Consent gate

- `ServiceDefinitionApprovalSheet` (Views/) — modal that blocks
  `ContentView` from rendering until every needs-approval definition
  is resolved. Shows yaml path/origin and the list of declared
  WriteTargets (literal where known, templated with placeholders for
  per-instance paths).
- Approval action triggers an Authorization Services right
  (`com.xalior.Steading.approveDefinition`) — Touch ID first,
  admin-password sheet as fallback. On success the main app calls
  the helper's `recordApproval` XPC method.
- New helper XPC methods on `SteadingPrivHelperProtocol`:
  - `recordApproval(yamlPath:hash:withReply:)`
  - `listApprovals(withReply:)`
  - `forgetApproval(yamlPath:withReply:)`
- Helper persists approvals at
  `/Library/Application Support/Steading/approvals.plist`, mode
  `0600 root:wheel`. Read/write via the existing atomic-write idiom
  in [HostsFileWriter](../../app/Steading/Shared/HostsFileWriter.swift).
- Helper rejects every privileged write derived from a YAML whose
  `(yamlPath, hash)` isn't in its current approvals list. Write
  contracts include the YAML's content hash so the helper can
  cross-check.

#### Picker

- `+` affordance on the Services section of
  [SidebarView](../../app/Steading/Views/SidebarView.swift) —
  styled to sit at the bottom of the section's installed list.
- New view `ServicePickerView` (Views/) renders in the detail pane
  when the user clicks `+`. Card grid: one card per available
  Services-catalog entry, visual treatment matching the sidebar
  rows. Each card sourced from its YAML's display fields.
- `AppState.installFlow: InstallFlowState?` drives the detail pane:
  `.picking`, `.wizard(serviceID)`, `.installing(serviceID,
  Pipeline)`, `.statusFor(serviceID)`. ContentView routes based on
  this in addition to the existing `selection`.
- `InstalledServicesStore` (Model/) — observable, source of truth
  for "which services has Steading installed." Backed by a brew
  query for installed `xalior/homebrew-steading/steading-*`
  formulae plus per-service metadata in
  `/Library/Application Support/Steading/installed.plist` (helper-
  written) covering install timestamp, restart-required flag,
  Keychain item ids.

#### Wizard renderer

- `ServiceInstallWizardView` (Views/) driven by
  `ServiceDefinition.panes`. Per-pane: title, optional inline help,
  fields, prev/next buttons. Final review pane lists every write
  the install will perform plus the brew formula(e), Keychain
  items, firewall rules, daemon label.
- Field renderers per `FieldKind` consume `Validation` rules; invalid
  fields disable Next.
- Advanced toggle hides every field marked `advanced: true` by
  default; one toggle per pane.
- Warning banners: each `WarningPredicate` evaluates against the
  current field state (e.g. "bindAddress != 127.0.0.1 → public
  exposure warning"). Banner appears alongside the offending field;
  acknowledging clears the banner-blocks-Next state but the warning
  stays visible.
- Preflight pane runs every `PreflightCheck` declared in the YAML
  before the wizard's main body — on failure shows the abort screen
  with the specific blockers; no Next.
- Secret-field handoff: `FieldKind.secret` values are written to the
  macOS Keychain immediately on field commit (under a service-tagged
  account name); the wizard never carries cleartext beyond the
  current pane.

#### Helper extensions

- New methods on `SteadingPrivHelperProtocol`:
  - `writeFile(path:mode:ownerUID:groupGID:content:yamlHash:withReply:)` —
    atomic write per the
    [HostsFileWriter](../../app/Steading/Shared/HostsFileWriter.swift)
    pattern. Validates `yamlHash` against approvals; runs the
    refusal list (next bullet); rejects on failure.
  - `removeFile(path:yamlHash:withReply:)`
  - `makeDirectory(path:mode:ownerUID:groupGID:yamlHash:withReply:)`
  - `removeDirectory(path:recursive:yamlHash:withReply:)`
  - `createSystemUser(name:uid:gid:home:yamlHash:withReply:)` —
    name must match `_<service>` pattern; uid allocation policy
    below; home under `/var/empty` or `/opt/<service>/`.
  - `removeSystemUser(name:yamlHash:withReply:)`
  - `writeLaunchDaemon(label:contentPlist:yamlHash:withReply:)` —
    label must match `com.xalior.steading.<service>*`; path is
    `/Library/LaunchDaemons/<label>.plist`, derived not parametric.
  - `loadLaunchDaemon(label:withReply:)` /
    `unloadLaunchDaemon(label:withReply:)` /
    `bounceLaunchDaemon(label:withReply:)` /
    `setLaunchDaemonDisabled(label:disabled:withReply:)`
  - `addFirewallRule(serviceLabel:allow:yamlHash:withReply:)` /
    `removeFirewallRule(serviceLabel:yamlHash:withReply:)` —
    wraps `socketfilterfw`.
  - `appendInstallLog(serviceID:line:withReply:)` —
    helper-side append to
    `/Library/Application Support/Steading/Logs/<svc>-<timestamp>.log`.
- Refusal list `app/Steading/Shared/PrivHelperRefusalList.swift`:
  pure functions evaluating mode, path, owner, traversal,
  symlink-target. Hardcoded dangerous-path blocklist
  (`/etc/sudoers*`, `/etc/pam.d/`, `/etc/master.passwd`,
  `~/.ssh/`, `/Library/PrivilegedHelperTools/*` other than
  `com.xalior.Steading.privhelper`, `/System/`, `/private/etc/`,
  `/usr/`, `/sbin/`, `/bin/` write attempts, etc.). Called from
  every write/create/remove method.
- Update [PrivHelperAllowlist](../../app/Steading/Shared/PrivHelperAllowlist.swift)
  with any additional executables the new methods spawn (likely
  none — most go through direct syscalls or
  `Foundation.Process` for `socketfilterfw` which is already
  allowlisted).
- Bump
  [`SteadingPrivHelperVersion`](../../app/Steading/Shared/SteadingPrivHelperProtocol.swift#L68)
  so the main app can detect a stale registration after the
  protocol grows.

#### Install / uninstall progress UI

- Extract the progress + disclosure-triangle pattern from
  [BrewPackageManagerView:448-490](../../app/Steading/Views/BrewPackageManagerView.swift#L448-L490)
  into a reusable `StreamingProgressView` (Views/) that takes an
  `AsyncStream<ProgressEvent>` and a current `PipelineState`.
- New driver `ServiceInstallPipeline` (Model/): orchestrates a
  declared step list (Brew install of `steading-<svc>` →
  createSystemUser → makeDirectory(s) → writeFile config(s) →
  writeLaunchDaemon → addFirewallRule(s) → loadLaunchDaemon →
  post-install probe). Each step emits a labelled log line; any
  step failure flips the driver into `rollback` mode and reverses
  the steps run so far, emitting rollback events into the same
  stream. Terminal events: `.success`, `.failed(reason)`,
  `.rolledBack(reason)`.
- Symmetric `ServiceUninstallPipeline` running the steps in reverse
  (unloadLaunchDaemon → removeFirewallRule → removeFile config(s) →
  removeDirectory(data) → removeSystemUser → `brew uninstall
  steading-<svc>`). On a successful uninstall, follows up with the
  cleanup-dialog if the upstream's brew refcount has fallen to zero
  (per discovery).
- One unified progress UI hosts both pipelines; no separate "brew
  phase" vs "helper phase" — single progress bar, single log feed
  in the disclosure.

#### Status pane

- New view `ServiceStatusView` (Views/), routed to from
  `ContentView` when `selection` matches an installed service id.
- `InstalledServiceStatus` (Model/) value composed from:
  `launchctl print system/<label>`, `lsof -nP -iTCP -sTCP:LISTEN`
  scoped by pid, `brew info --json=v2 <upstream>`,
  [`BrewUpdateManager`](../../app/Steading/Model/BrewUpdateManager.swift)
  outdated set keyed by upstream token, the YAML's WriteTargets for
  the files-and-dirs panel.
- Restart-required flag lives on `InstalledServicesStore`. Set when
  any `writeFile` call commits a config write since the last
  start/restart for that service. Cleared on bounce.
- Action row: Start / Stop / Restart (state-gated like
  [BuiltInServiceDetailView](../../app/Steading/Views/BuiltInServiceDetailView.swift)),
  Edit Config (opens the structured editor in the same pane —
  see *Edit Config* below), View Logs, Uninstall.
- Enable-on-boot toggle calls `setLaunchDaemonDisabled`.
- Listening-endpoints card refreshes on appear and after each
  start/stop/restart.

#### View Logs surface

- `ServiceLogView` (Views/) — initial scope: read the helper-written
  `/Library/Application Support/Steading/Logs/<svc>-*.log` files +
  tail the service's own log file declared in YAML. Live tailing via
  the existing
  [`StreamingProcessRunner`](../../app/Steading/Model/StreamingProcessRunner.swift).
  Polished log UX (search, filtering, time scrubbing) deferred.

#### Edit Config

- `ServiceEditConfigView` (Views/) reuses the same pane renderer as
  `ServiceInstallWizardView` rather than re-implementing it.
  Initialised from the service's *current* config (read from disk
  via the YAML's WriteTargets) rather than blank defaults. Same
  field types, same validation rules, same `Show advanced` toggle —
  the install wizard's "less-common options" are the edit pane's
  advanced section.
- Plus a `Raw config files` tab. One sub-tab per WriteTarget for
  the service. Each sub-tab loads the current file contents into a
  `TextEditor`; save commits via the same `writeFile` XPC method
  used by the structured editor. Escape hatch when the structured
  UI doesn't cover what the owner needs.
- Symmetric helper read method: `readFile(path:yamlHash:withReply:)`
  added to `SteadingPrivHelperProtocol` so the editor can read
  files that aren't owner-readable (e.g. `_mysql:_mysql`-owned
  config). Same approvals + refusal-list gating as `writeFile`.
- Saves do not auto-restart. Each successful `writeFile` flips the
  restart-required flag on `InstalledServicesStore` for that
  service; the status-pane banner picks that up. Owner clears it
  by hitting Restart on the status pane when they're ready.

#### Failure recovery beyond the in-pipeline rollback

- Pipeline persists checkpoint state in
  `InstalledServicesStore` ("brew step done", "config files
  written", etc.) so an app/helper crash mid-install can be
  detected on next launch.
- On launch, if `InstalledServicesStore` shows any service in a
  partial-install or partial-uninstall state, the main app surfaces
  a "previous install was interrupted; clean up?" alert which runs
  the appropriate rollback pipeline.
- Verbose persistent logs are the same files the View Logs surface
  reads — no parallel log path.

#### Catalog completion

- `caddy.yml` — adds firewall (TCP 80/443). Declares a templated
  WriteTarget `Caddyfile.d/{hostname}.caddy` with a hostname regex
  constraint, exercising the templated-path approval mechanism
  for the first time. Per-webapp vhost writes (a future webapps
  parcel) will supply concrete `hostname` values resolving against
  this template.
- `php-fpm.yml` — fastcgi unix socket; no firewall.
- `redis.yml` — loopback only; the simplest service after MySQL.
- `tailscale.yml` — brew install + plist; admin handoff to
  `tailscale up` post-install (a "open Tailscale to finish setup"
  step in the wizard's review pane).
- `stalwart.yml` — sourced from `xalior/homebrew-steading`'s real
  formula, validates the out-of-core upstream path through the
  pipeline.
- `xalior/homebrew-steading` tap gains six wrappers: `steading-caddy`,
  `steading-php-fpm`, `steading-mysql`, `steading-redis`,
  `steading-tailscale`, `steading-stalwart`. Each is one
  `depends_on` line.
- Helper additions only where a remaining service surfaces a
  capability not exercised by MySQL — most likely templated-path
  `writeFile` for Caddy vhosts; if more than one service surfaces
  net-new helper needs, that's a signal MySQL was the wrong
  reference and we should revisit.

### Success Criteria

#### Automated

- `make test` passes after running `cd app && xcodegen generate &&
  xcodebuild … test` per
  [CLAUDE.md](../../CLAUDE.md#build-and-test-cheatsheet)'s recipe.
  New pure tests cover:
  - `ServiceDefinitionLoader` against canned YAML fixtures (valid
    minimal, valid full, invalid-anchor, invalid-tag, schema-violations,
    over-size, etc.).
  - `BundleDefinitionVerifier` partitions for matched / mismatched /
    unrecorded inputs.
  - `PrivHelperRefusalList` returns refused for each entry of the
    blocklist (parametric test) and not-refused for representative
    legitimate paths.
  - `ServiceInstallPipeline` state machine: every
    (currentState, event) → nextState transition; rollback ordering
    matches step-list reverse.
  - Hash-list determinism: building the same input set twice
    produces byte-identical `.bundle-hashes.plist`.
  - Approvals plist round-trip (write, read, forget) hitting the
    real
    [HostsFileWriter](../../app/Steading/Shared/HostsFileWriter.swift)-
    style atomic write under a temp path.
- `app/scripts/hash-service-definitions.sh` runs in the build phase
  and fails the build for a fixture YAML that violates the schema.
- Every YAML in `Resources/ServiceDefinitions/` parses with the
  strict loader on a fresh checkout.
- Live test (suite "ServerInstallerLiveTests") spawns the real
  helper against the dev mac and exercises `recordApproval` /
  `listApprovals` / `forgetApproval` round-trip plus a
  small-content `writeFile` to a tempdir under
  `/Library/Application Support/Steading/Tests/`.
- VM clean-room automation is **deferred to whenever the vanilla
  VM release-test harness lands** (the `# … release-test scripts
  TBD …` line in [CLAUDE.md](../../CLAUDE.md)). Phase 1 does not
  block on it. Once that harness exists, a follow-on
  `scripts/vm-installer-smoke.sh` extends it to drive the full
  MySQL install/uninstall and assert the post-state.

#### Manual

Verification a human runs on the dev mac and inside a fresh vanilla
VM:

- Fresh launch on dev mac: helper still trusted; no approval modal
  appears since every bundle YAML hash matches its recorded value.
- Modify one bundle YAML by hand → next launch shows the approval
  modal listing the modified file's WriteTargets and blocking the
  main UI until the user approves (with admin-password challenge)
  or denies. Denying suppresses that service from the picker.
- Drop a hand-written new YAML into the external data dir and click
  "Rescan data directory" in Prefs → Advanced. Approval modal fires
  for the new YAML.
- `+` on Services sidebar opens picker; six cards for the v1
  Services catalog visible.
- Pick MySQL → wizard runs with Welcome, Preflight (port 3306, etc.),
  Admin Account, Bind Address, Data Directory, Advanced (default
  hidden), Review. Setting Bind Address to `0.0.0.0` triggers the
  warning banner.
- Confirm → unified progress UI runs through brew install +
  post-brew steps with streaming log in the disclosure. Completes
  successfully; MySQL appears in sidebar Services list; clicking it
  shows the status pane with state running, listening on
  127.0.0.1:3306, files-and-dirs panel populated, version visible,
  no update-available indicator (unless the dev mac actually has
  one outdated).
- `mysql -u root -p<password>` from a terminal connects (using the
  password the wizard captured into the Keychain).
- Toggle enable-on-boot off → `launchctl print system/...` shows
  `Disabled = true`. Toggle on → cleared.
- Stop button stops the daemon; status flips to stopped; ports card
  empties. Start button restarts.
- View Logs shows the install log plus a tail of MySQL's own log.
- Uninstall → confirm → progress UI runs reverse teardown; MySQL
  disappears from sidebar; cleanup dialog asks whether to remove
  the upstream `mysql` formula too.
- Mid-install kill of the helper (via `sudo killall
  SteadingPrivHelper` mid-progress) → app surfaces the
  partial-install alert on next launch and offers cleanup.
- Drop a hostile YAML claiming to write `/etc/sudoers` → approval
  modal shows the malicious WriteTargets clearly. Even if the
  user mistakenly approves, the helper's refusal list rejects the
  write at runtime and the install fails into rollback.
- Vanilla-VM verification (drag-installed `.app` in a fresh VM,
  full MySQL install/uninstall round-trip from the user-visible
  distribution path) is **deferred until the vanilla VM
  release-test harness lands**. Until then the dev-mac manual
  verification above is the gating signal for Phase 1.

## Testing Strategy

Per [CLAUDE.md](../../CLAUDE.md)'s hard rule — tests always exercise
production code, no stubs that reimplement logic. Three test classes,
matching the existing exemplar in
[BrewDetectorTests.swift](../../app/SteadingTests/BrewDetectorTests.swift):

- **Pure tests.** Every pure function — `ServiceDefinitionLoader`,
  `BundleDefinitionVerifier`, `PrivHelperRefusalList`, hash
  computation, pipeline state machine, button-state derivation,
  warning-predicate evaluation — is `public static` and tested by
  calling it directly with canned inputs. Schema fixtures live under
  `app/SteadingTests/Fixtures/ServiceDefinitions/` covering valid
  minimal, valid full, every schema-violation class, and every
  parser-strictness rejection (anchors, custom tags, etc.).
- **Boundary-input tests.** Construct the real
  `ServiceInstallPipeline` against a temp directory with no helper
  and assert that step ordering, error propagation, and rollback
  ordering all behave as the state machine declares.
- **Live tests.** Spawn the real privileged helper and exercise:
  `recordApproval` / `listApprovals` / `forgetApproval` round-trip;
  `writeFile` to a temp path under
  `/Library/Application Support/Steading/Tests/`; refusal-list
  assertions (helper actually refuses a `/etc/sudoers` write
  request); approvals-plist atomic-write semantics. The real-helper
  invocation already runs in the existing live-test path used by
  `BrewDetectorTests` and `BuiltInServiceRunner` tests.

The full install/uninstall integration test runs in the vanilla VM
release-test harness once that lands; until then dev-mac manual
verification is the gating signal (per Success Criteria above).

## References

- Source: [docs/discovery/discovery_server-installer.md](../discovery/discovery_server-installer.md)
- Product framing: [DESIGN.md](../../DESIGN.md)
- Architecture: [docs/ARCHITECTURE.md](../ARCHITECTURE.md)
- Apply-pipeline UI pattern: [app/Steading/Views/BrewPackageManagerView.swift:448-490](../../app/Steading/Views/BrewPackageManagerView.swift#L448-L490)
- Per-target privileged-write exemplar: [app/Steading/Shared/HostsFileWriter.swift](../../app/Steading/Shared/HostsFileWriter.swift)
- XPC contract: [app/Steading/Shared/SteadingPrivHelperProtocol.swift](../../app/Steading/Shared/SteadingPrivHelperProtocol.swift)
- Allowlist: [app/Steading/Shared/PrivHelperAllowlist.swift](../../app/Steading/Shared/PrivHelperAllowlist.swift)
- Streaming subprocess: [app/Steading/Model/StreamingProcessRunner.swift](../../app/Steading/Model/StreamingProcessRunner.swift)
