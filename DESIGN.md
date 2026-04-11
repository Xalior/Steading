# Steading
## Small Business Server for macOS

*Pre-planning · 2026-04-11 · MIT · native SwiftUI · macOS Tahoe (26) and forward · Apple Silicon*

---

## What Steading is

A native SwiftUI desktop app for macOS Tahoe that turns a Mac into a cheap, easy, affordable small-office server. Steading detects or installs Homebrew during onboarding, offers a curated list of common self-hosted services to install, and provides a native GUI over macOS's built-in server facilities (SMB, Time Machine, SSH, printer sharing, firewall, power management, etc.) — wrapping them, never replacing them.

## What Steading is not

- **Not Electron.** Native SwiftUI, driving the macOS stack directly.
- **Not a replacement for macOS's built-in server facilities.** SMB, CUPS, SSH, `pf`, `pmset`, Time Machine, etc. stay where they are. Steading provides an administration surface over them using `defaults write`, `sharing`, `systemsetup`, bash, and the rest of the native plumbing.
- **Not a parallel environment.** Steading adopts the user's existing Homebrew install. The user's brew *is* the brew. No parallel brew, no dedicated `_steading` user account, no `brew services` (which installs per-user agents; Steading generates its own `LaunchDaemons` instead).
- **Not opinionated about how you run your Mac.** Sensible defaults, warnings on footguns, but the owner always decides. Steading prevents accidents, not decisions.

## Scope

Steading is designed for the full span of "Mac as small-office server":

- A developer's Mac that's also serving the office wiki or a git repo
- A second Mac (often a Mini) on a desk or in a closet, providing LAN services
- A Mac that used to be someone's desktop and is being repurposed as a dedicated server when its user gets a new machine
- A Mac mini in a datacenter, reachable over the public internet
- Anything in between

The "my old desktop becomes our wiki server" migration is a load-bearing scenario: a service running on a Mac must survive the owner logging out, rebooting, power cuts, and the machine changing roles. The product fails if that migration is hard.

## Core principles

### How Steading handles choices

Three kinds of things get different treatment:

1. **Dependencies are automatic.** If installing an HTTP app needs an ingress server (Caddy), or a PHP app needs PHP-FPM, or WordPress needs MySQL, Steading pulls the prerequisites in and configures them — no "may I install what you obviously just asked for" dialogs. The owner *is* notified up front about what's coming along for the ride — *"Installing WordPress will also install: Caddy, PHP-FPM, MySQL"* — as information, not a decision. Dependencies are reference-counted; never silently auto-removed on uninstall. See **Install and uninstall flow** below for how this surfaces to the owner.
2. **Configuration is defaulted and easily overridable.** Sensible defaults per service, driven by what the service *is* (MySQL → loopback, Caddy → LAN + public, Redis → loopback, a wiki → LAN). Every default is editable in the normal UI.
3. **Policy is the owner's call, with context-aware warnings.** Firewall state, public exposure, opening port 22 / 25 / 80 to the world, enabling password SSH — Steading warns, never refuses. Warnings are context-aware: port 25 open on a colocated Mac is correct with a small sign ("make sure your PTR matches"); port 25 open on a residential connection is a footgun with a big sign. Same switch, different sign. The owner acknowledges and Steading moves on.

### Install and uninstall flow

When the owner installs a service from the catalog, Steading reads that service's definition file (see **Catalog** below) and does the following in order:

1. Reads the dependency set from the definition file and verifies that the ports, sockets, and target paths those dependencies need are actually free. If anything is already in use — port `3306` occupied by another MySQL, port `80` bound by something other than Steading's Caddy, a chosen webapp directory that is not empty — installation is **aborted** with a clear explanation of what's blocking it. Steading does not try to negotiate conflicts, pick alternative ports, or rename directories; this is not advanced mode. The owner resolves the conflict themselves (stop the other service, pick a different directory, whatever) and tries again.
2. Shows the owner what is about to be pulled in — *"Installing WordPress will also install: Caddy, PHP-FPM, MySQL"* — as **information, not a decision**. If the owner didn't want that, they wouldn't have asked to install WordPress.
3. Presents a form (generated from the definition file) asking for whatever configuration and credentials the service needs: admin passwords for things like MySQL root, hostnames, data paths, whatever the service demands. The owner fills it in once.
4. Installs the brew formulae for anything not already present (Steading adopts existing installs rather than duplicating them — the owner may already have Tailscale or MySQL from earlier work; Steading offers to manage those rather than re-install), writes any new `LaunchDaemon` plists needed (for services — a webapp has no daemon of its own; see *Services vs webapps* below), applies the owner-provided configuration, wires everything together (e.g. creates the WordPress database inside MySQL and adds a Caddy virtual host pointing at the WordPress files), and starts everything.
5. Hands off to the service's own admin UI for any remaining setup.

On uninstall, Steading **never** auto-purges dependencies. If removing a service causes a dependency's Steading-side refcount to drop to zero, Steading offers cleanup through a dialog that makes the data-loss risk explicit. Something like:

> **MySQL was installed automatically when you added WordPress. Nothing else Steading manages is using it now.**
>
> If you've created your own databases on this MySQL — or connected something outside Steading to it — removing it now would take those with it. If you're not sure, leave it alone.
>
> `[ Keep MySQL ]`   `[ Uninstall it too ]`

The default answer is **keep it** — conservative, non-destructive. The cost of leaving an idle MySQL running is far lower than the cost of blowing away the owner's own work.

### Services vs webapps

Not every catalog entry is a service. Steading distinguishes between:

- **Services** — things that run as daemons of their own: Caddy, PHP-FPM, MySQL, Stalwart, Forgejo, Syncthing, Vaultwarden, and so on. Each has its own process, its own service user, its own `LaunchDaemon` plist, and its own lifecycle.
- **Webapps** — things that are just files served by shared infrastructure: DokuWiki, MediaWiki, WordPress, phpMyAdmin, and similar. A webapp has no daemon of its own and no service user of its own; it lives as a directory of files behind a Caddy virtual host, served by the shared PHP-FPM and (optionally) backed by the shared MySQL or Postgres.

The Catalog has **two separate lists** for this reason — a *Services catalog* (one blessed implementation per category) and a *Webapps catalog* (multiple entries coexist freely). MediaWiki and DokuWiki both installed on the same machine is legitimate, not a conflict: each gets its own Caddy virtual host and its own database if needed, sharing the underlying Caddy and PHP-FPM.

For the install and uninstall flow the distinction is invisible to the owner — a webapp install pulls in its dependencies, triggers the up-front notification, presents the credential form, participates in refcounting. What differs is only what "installed" means: for a service, a new daemon is running; for a webapp, new files are on disk and a new virtual host is live.

### Services are LaunchDaemons

Every service Steading installs runs as a system `LaunchDaemon` in `/Library/LaunchDaemons/`, under an appropriate service user (`_stalwart`, `_postgres`, `_mysql`, `_redis`, and so on — the standard Unix daemon pattern). Services start at boot, survive logout, survive reboot, and survive power cuts. No `LaunchAgents`. No services that are "usually running."

This is non-negotiable. A service that dies when the owner logs out is a toy, not a service. The migration scenario above depends on it absolutely.

### Brew adoption, not replacement

On first run, Steading detects whether Homebrew is installed. If it is, Steading adopts it — managing services within the user's brew environment without parallelizing, shadowing, or taking ownership. If brew isn't installed, Steading offers to install it during onboarding in a visible embedded console view — nothing happens silently.

Steading never touches a brew formula the user installed outside Steading unless the user explicitly says so. Any service Steading manages can be released back to manual management without breaking anything.

### Division of labor between brew and Steading

Brew handles what brew is good at: downloading binaries, verifying checksums, installing files into `/opt/homebrew/`, and resolving dependencies across brew packages. **Steading's install flow handles everything brew can't or shouldn't**: creating system users (`_stalwart`, `_redis`, `_mysql`, and so on), writing `LaunchDaemon` plists into `/Library/LaunchDaemons/`, running `launchctl load`, initialising per-service config files and data directories with correct ownership and permissions, storing credentials in the Keychain, wiring services to their dependencies (creating a database for a webapp, adding a Caddy virtual host, etc.), and applying any firewall rules.

This split is uniform across the catalog: every service install is `brew install <formula>` plus Steading's privileged helper doing the system-level work afterward. The brew formulae in the `xalior/homebrew-steading` tap are deliberately minimal — just the binary, with at most a `service` block as descriptive metadata — because Steading writes its own plists and drives `launchctl` directly rather than going through `brew services` (which installs per-user `LaunchAgents`, the exact thing Steading exists to avoid).

### Wraps macOS built-ins where they're best-in-class

Steading provides a native GUI over existing macOS server facilities rather than duplicating them. Candidates include:

- SMB file sharing with per-share ACLs
- Time Machine as a network destination
- Printer sharing (CUPS)
- SSH / Remote Login with key management
- Firewall (`socketfilterfw`, `pf`)
- Power / wake preset for 24/7 operation (`pmset`)
- Content Caching
- Screen Sharing / Remote Management
- Hostname and Bonjour advertisement

None of this is on by default. Enabling any of it is a deliberate owner choice with sensible sub-defaults (e.g. when SSH is enabled, the defaults are key-based only, no root login, rate-limited).

**SSH and Screen Sharing together are Steading's entire remote-access and recovery story.** SSH handles CLI work and automation; Screen Sharing (the Apple Remote Desktop protocol) handles GUI recovery when clicking through the UI is the fastest way back from something having gone wrong. Both travel over whatever transport the owner has configured — Tailscale for private overlay access to a headless Mac, or the public interface behind a firewall rule on a colocated Mac with a real IP. Steading does **not** bundle a VPN or overlay network of its own; it relies on the owner's transport choice plus the native macOS facilities. Anything beyond that is out of scope.

### Browser handoff for hosted-service configuration

Services in the catalog that bring their own web-based admin UIs (wikis, git forges, mail servers, password managers, etc.) are configured through those existing admin UIs — either via the system browser or an embedded browser view in Steading. Steading gets a service installed, running, and reachable; it does not re-implement every service's configuration surface.

## Onboarding

First run is deliberately minimal:

1. Owner installs Steading — either by dragging the `.app` bundle from a GitHub release into `/Applications` (standard Mac app distribution) or, for owners who already have Homebrew, via `brew install --cask xalior/steading/steading` (see *Distribution* under Technical realities). Both paths end with the app in `/Applications`. Owner launches it.
2. Steading checks whether Homebrew is installed and whether `xalior/homebrew-steading` is tapped. If brew is missing, Steading offers to install it in the visible embedded console view. Once brew is present, Steading taps the xalior repo if it isn't already — tapping only registers the repo as a formula source, it does not install anything from it. **The only thing Steading installs automatically during onboarding is brew itself, and only if missing.** If the owner arrived via `brew install --cask xalior/steading/steading`, both of these checks short-circuit immediately — brew and the tap were already in place for the cask install to have worked in the first place. The two entry points (drag-to-Applications, or `brew install --cask`) converge to the same state by the end of this step.
3. Steading asks whether the Steading **app itself** should launch at login. This is independent of services — services are `LaunchDaemons` and run regardless of whether the app window is open; this toggle only controls whether the admin UI is waiting in the menu bar / dock after login. Owner says yes or no.
4. Steading presents the main window.

That is the entire onboarding flow. **Steading installs nothing else by default** — no "starter pack," no "recommended services," no background downloads. The catalogs sit there waiting; the owner decides what to install and when.

## Catalog

Steading ships **two catalogs**, kept visually and conceptually separate in the UI:

- **Services** — things that run as their own processes, bind to their own ports or sockets, and get their own `LaunchDaemon` plists. One blessed implementation per category.
- **Webapps** — things that are just files served by existing services (typically a Caddy virtual host backed by shared PHP-FPM and, when the webapp needs one, a shared database). No process of their own, no port of their own. Multiple webapps coexist freely.

See *Services vs webapps* in Core Principles for the conceptual distinction.

### Services catalog

**One blessed implementation per category.** For each service category Steading supports, there is exactly one supported choice — not a menu of alternatives, and no "Caddy or Nginx or Traefik" style decision trees. This keeps integration tight, testing scoped, and the user experience clear. If the owner wants an alternative, they're welcome to install it themselves outside Steading's management; that is not something Steading tries to support.

The v1 services catalog:

| Service category | Pick |
|---|---|
| Web server / reverse proxy (ingress) | **Caddy** |
| PHP runtime | **PHP-FPM** |
| Relational database | **MySQL** |
| Key-value / cache store | **Redis** |
| Overlay networking *(optional; frequently already installed by the owner for their own use)* | **Tailscale** |
| Mail server *(optional, not foundational)* | **Stalwart** — shipped via the `xalior/homebrew-steading` tap since it isn't in homebrew-core |

### Webapps catalog

A webapp install has two owner-specified parameters beyond the usual config and credentials: a **target directory** (where the webapp's files live on disk) and a **hostname** (the Caddy virtual host serving them). This makes multiple instances of the same webapp legitimate — two separate MediaWikis on the same Mac, each with its own directory, its own hostname, and its own database, coexisting peacefully. Installing a webapp drops its files in the chosen directory, adds a Caddy virtual host for the chosen hostname pointing at those files, creates a database for it in the shared MySQL if it needs one, and runs whatever first-run setup the webapp itself requires.

The v1 webapps catalog:

| Webapp | Needs |
|---|---|
| **MediaWiki** | PHP-FPM, MySQL |
| **WordPress** | PHP-FPM, MySQL |
| **DokuWiki** | PHP-FPM (flat-file — no database required) |

### Definition files

**Each catalog entry — service or webapp — has a definition file.** This is Steading's source of truth for that entry: the brew formula (or content source), its dependencies, the configuration values and credentials the owner must supply (admin passwords, hostnames, data paths, and so on), default bind addresses and ports for services, vhost and database requirements for webapps, and the wiring instructions needed to integrate the entry with its dependencies. WordPress's definition file, for example, knows it needs a MySQL database and a Caddy virtual host, and specifies how to create and connect both. The UI generates its per-entry install form from this file. Adding support for a new catalog entry means writing its definition file. The exact schema is tbd.

Install path for any catalog entry, uniformly: install the brew formula or drop the files into place → for a service, generate a `LaunchDaemon` plist running as an appropriate service user; for a webapp, add a Caddy virtual host → apply the owner-provided configuration → wire the entry to its dependencies → start everything → hand off to the entry's own admin UI if it has one.

### Worked example: installing Stalwart

For concreteness, the end state after `brew install xalior/steading/stalwart` followed by Steading's install flow:

- `/opt/homebrew/bin/stalwart` — the Stalwart binary, placed by the brew formula from the `xalior/homebrew-steading` tap
- `_stalwart` system user, created by Steading's privileged helper at install time (standard Unix daemon pattern)
- `/opt/stalwart/etc/config.toml` — initial Stalwart config, generated by running `stalwart --init`, owned by `_stalwart`, mode `700`
- `/opt/stalwart/logs/` and `/opt/stalwart/data/` — log and data directories, owned by `_stalwart`
- `/Library/LaunchDaemons/io.xalior.steading.stalwart.plist` — the `LaunchDaemon` plist, written by Steading's privileged helper and loaded via `launchctl load`
- Stalwart running at boot as `_stalwart`, surviving logout, reboot, and power cuts
- Any admin credentials the owner provided during install stored in the macOS Keychain under a named Steading entry

This is strictly better than what Stalwart's own `install.sh` produces on macOS, which drops a **`LaunchAgent`** into `/Library/LaunchAgents/` that silently stops working the moment the logged-in user logs out — fine for a workstation install, broken for a headless Mac mini or any serious server role. Steading exists in part to fix exactly this class of gap.

## Technical realities

### Root operations require a privileged helper

A server administration app needs root for large parts of what it does: installing `LaunchDaemon` plists in `/Library/LaunchDaemons/`, editing `/etc/`, opening privileged ports, writing `pf` rules, trusting certificates, running `pmset` and `systemsetup`. A sandboxed SwiftUI app cannot do any of this.

Steading will be a Developer ID–distributed, notarized, non-sandboxed app with a privileged helper tool registered via `SMAppService`. The helper is invoked per-operation for root work and exits when done — not a long-running background daemon.

Mac App Store distribution is not viable; the sandbox fights too much of what Steading needs to do.

### Credential storage

When the owner hands Steading an admin password or API key during install (MySQL root, service admin accounts, and so on), Steading stores the secret in the **macOS Keychain**. Keychain is the native secure store designed for exactly this kind of credential, and it's the right default on a native Mac app.

Steading keeps a **list** of what it has stored — the Keychain item names and which service each one belongs to — because Keychain itself is opaque to humans. Without this list there would be no way to see what Steading-managed secrets exist on the machine.

For portability, Steading can **export its credential set to a single encrypted file**, passphrase-protected. This matters for the migration scenarios that are central to Steading's purpose — carrying a server install to a new Mac (my desktop becomes our wiki server; the old Mac mini dies and we restore onto a new one). Importing the encrypted file on another machine re-populates the Keychain entries there. Export and import are deliberate owner actions; nothing happens silently.

### Distribution

Steading is distributed two ways, both ending at `/Applications/Steading.app`:

1. **Direct download** from GitHub releases at `xalior/steading`. Drag to `/Applications`, run, onboarding kicks off.
2. **`brew install --cask xalior/steading/steading`** from the Steading Homebrew tap at `xalior/homebrew-steading`. For owners who already use Homebrew and want Steading's updates routed through `brew upgrade` alongside everything else they manage.

The tap at **`xalior/homebrew-steading`** serves a second purpose beyond hosting the Steading cask: it also holds **formulae for anything Steading needs that isn't in homebrew-core**, starting with the chosen mail server. When Steading's install flow pulls in an out-of-core dependency, the formula is sourced from this same tap. One tap, one update pipeline — `brew upgrade` keeps Steading itself and its out-of-core dependencies on the same cadence. Adding new formulae to the tap as further needs arise is a matter of dropping `.rb` files into the repo.

Tap layout: `Casks/steading.rb` for the app itself, `Formula/*.rb` for supporting formulae. Brew handles mixed-content taps natively; no special structure needed.

## Non-goals for v1

Explicitly out of scope. These may or may not return as real needs later:

- No centralised orchestration daemon beyond the per-operation privileged helper
- No multi-host management — Steading manages the Mac it's running on, one Mac, one instance
- No custom remote-admin wire protocol — SSH is the baseline remote-admin path
- No dedicated `_steading` user account or parallel brew install
- No `LaunchAgent`-based services; services are daemons
- No per-service "role tag" (dev-convenience vs server-grade was a bad abstraction and it's gone)
- No Apple Containerization runtime integration
- No identity-provider / SSO story across services
- No Postfix / Dovecot as a mail-backend option (OpenDKIM is broken on macOS)
- No named "notifications relay" subsystem auto-wiring services together

## Open questions

These are real design decisions still to be made, and will shape the next round of planning:

- **Aggregated warning audit view.** Inline warnings at the point of change are committed. Whether there is also a "what's non-default about this machine, and why" audit panel is undecided.
- **Service definition file schema.** The shape, format, and validation rules for the per-service definition files the UI parses into install forms.
