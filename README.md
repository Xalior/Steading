# Steading

Small Business Server for macOS. A native SwiftUI admin app that
wraps macOS's built-in server facilities (SMB, Time Machine, SSH,
printer sharing, firewall, power management, Content Caching,
Screen Sharing) with a first-class GUI, and installs curated
self-hosted services via Homebrew.

Targets macOS Tahoe (26) and forward, Apple Silicon. MIT.

## Build

Requires Xcode 26.3+, Homebrew, and `xcodegen`.

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

## Further reading

- [DESIGN.md](DESIGN.md) — product design (what Steading is and
  isn't).
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the code is
  organised.
- [app/README.md](app/README.md) — app build details.
- [scripts/README.md](scripts/README.md) — VM harness for clean-room
  testing.
