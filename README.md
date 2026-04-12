# 🏡 Steading

> 🖥️ A native macOS admin app that turns your Mac into a small-office server — GUI over the built-in services, plus a curated catalog of self-hosted extras.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: macOS 26+](https://img.shields.io/badge/Platform-macOS%2026%2B-blue.svg)]()
[![Arch: Apple Silicon](https://img.shields.io/badge/Arch-Apple%20Silicon-black.svg)]()
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)]()

---

## ✨ What you can run

**macOS built-ins, with a proper UI:**

- 📁 SMB file sharing
- 💾 Time Machine network destination
- 🖨️ Printer sharing (CUPS)
- 🔐 SSH / Remote Login
- 🧱 Firewall
- ⚡ Power management
- 📺 Content Caching
- 🖥️ Screen Sharing
- 📡 Hostname & Bonjour

**Curated services, installed via Homebrew:**

| Category | Pick |
|----------|------|
| 🌐 Web server / reverse proxy | Caddy |
| 🐘 PHP runtime | PHP-FPM |
| 🗄️ Relational database | MySQL |
| 🔑 Key-value / cache | Redis |
| 🕸️ Overlay networking | Tailscale |
| ✉️ Mail server | Stalwart |

**Curated webapps:**

| Webapp | Needs |
|--------|-------|
| 📖 MediaWiki | PHP-FPM, MySQL |
| 📰 WordPress | PHP-FPM, MySQL |
| 📝 DokuWiki | PHP-FPM |

---

## 🚀 Quick Start

Requires **Xcode 26.3+**, **Homebrew**, and **xcodegen** (`brew install xcodegen`).

```sh
cd app
xcodegen generate
open Steading.xcodeproj
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

---

## 📦 Install

1. 🎁 Direct download from GitHub releases — drag to `/Applications`.
2. 🍺 `brew install --cask xalior/steading/steading`.

---

## 📚 Docs

| Doc | What's in it |
|-----|--------------|
| 🎯 [DESIGN.md](DESIGN.md) | Product vision, catalog, install flow |
| 📐 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Code layout |
| 📦 [app/README.md](app/README.md) | App build details |
| 🧼 [scripts/README.md](scripts/README.md) | VM harness for clean-room testing |

---

## 🎯 Targets

macOS **Tahoe (26)** and forward. **Apple Silicon** only.

## 📜 License

MIT. See [LICENSE](LICENSE).
