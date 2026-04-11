# Steading — macOS app

PoC of the Steading desktop app. Native SwiftUI, macOS Tahoe (26) and
forward, Apple Silicon. See [../DESIGN.md](../DESIGN.md) for the full
product design.

## Build

Open `Steading.xcodeproj` in Xcode (26.3 or newer) and run. Or from the
command line:

```sh
cd app
xcodebuild -project Steading.xcodeproj -scheme Steading \
  -configuration Debug -arch arm64 ONLY_ACTIVE_ARCH=YES build
```

## Test

Tests use Swift Testing (`@Suite`, `@Test`, `#expect`) and exercise the
live `BrewDetector` — pure parser functions are called directly, and
the `detect()` / `readVersion(ofBrewAt:)` tests hit the real filesystem
and spawn the real `brew --version` subprocess. No stubs, no fakes.

```sh
cd app
xcodebuild -project Steading.xcodeproj -scheme Steading \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -enableCodeCoverage NO test
```

## Layout

```
app/
├── Steading.xcodeproj       # Xcode project — committed
├── Steading/
│   ├── App/                 # @main, AppDelegate, AppState
│   ├── Model/               # BrewDetector (the one real function)
│   │                        # + dummy Service/Webapp/BuiltIn catalogs
│   ├── Views/               # SwiftUI views
│   ├── Assets.xcassets/
│   └── Steading.entitlements
└── SteadingTests/
    └── BrewDetectorTests.swift   # live tests against real code
```

## What the PoC does

On launch the app checks for Homebrew in the standard locations
(`/opt/homebrew/bin/brew`, `/usr/local/bin/brew`), runs `brew --version`
to confirm it's responsive, and surfaces the result in the toolbar and
on the welcome screen. The sidebar lists the v1 service, webapp, and
macOS built-in catalogs as dummy data with per-item detail views. The
app shows in both the dock and the menu bar; clicking the dock icon
after closing the window reopens it.

Install / uninstall actions are deliberately disabled — this PoC is
about shape, not functionality.
