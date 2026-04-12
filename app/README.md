# Steading — macOS app

Native SwiftUI. Two Xcode targets: `Steading` (main app) and
`SteadingPrivHelper` (privileged helper, embedded in the main app
bundle). Targets macOS Tahoe (26.0) and forward, Apple Silicon.

See [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) for how the
pieces fit together.

## Build

Open `Steading.xcodeproj` in Xcode 26.3+ and run. Or from the
command line:

```sh
cd app
xcodegen generate     # when project.yml or sources have changed
xcodebuild -project Steading.xcodeproj -scheme Steading \
    -configuration Debug -arch arm64 ONLY_ACTIVE_ARCH=YES build
```

## Test

Swift Testing (`@Suite`, `@Test`, `#expect`). All 49 tests exercise
live production code — pure functions called directly with canned
inputs, live probes that hit the real filesystem / spawn the real
subprocesses. No stubs.

```sh
cd app
xcodebuild -project Steading.xcodeproj -scheme Steading \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -enableCodeCoverage NO test
```

## Layout

```
app/
├── project.yml                     # xcodegen input
├── Steading.xcodeproj              # generated
├── Steading/                       # main app target
│   ├── App/                        # @main, AppDelegate, AppState
│   ├── Model/                      # BrewDetector, built-in service runners,
│   │                               # ProcessRunner, PrivHelperClient
│   ├── Views/                      # SwiftUI views
│   ├── Shared/                     # compiled into BOTH targets
│   │                               # (XPC protocol + allowlist)
│   ├── Resources/LaunchDaemons/    # embedded plist for SMAppService
│   ├── Assets.xcassets/
│   └── Steading.entitlements
├── SteadingPrivHelper/             # privileged helper target
│   ├── main.swift
│   ├── PrivHelperListenerDelegate.swift
│   └── PrivHelperService.swift
└── SteadingTests/
```
