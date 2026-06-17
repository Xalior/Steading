import Foundation

/// Detects which flavour of Tailscale, if any, is present on this Mac.
///
/// Steading manages Tailscale as a boot-time LaunchDaemon, which only
/// the open-source `tailscale`/`tailscaled` build (the Homebrew
/// formula) can satisfy — the GUI variants connect per-user *after*
/// login and so can't bring the tailnet up before anyone signs in.
/// They also can't coexist with the open-source daemon, so a GUI
/// Tailscale.app is a blocker that must be removed first.
///
/// Design notes
/// ------------
/// - `classify(...)` is the pure decision and is `static` so tests can
///   exercise every branch with canned probe results.
/// - `detect()` hits the real filesystem; tests call it directly and
///   feed boundary inputs (empty search paths, a real executable path)
///   to the real production code rather than faking it.
struct TailscaleDetector: Sendable {

    /// Which GUI variant of `Tailscale.app` is installed. Both block
    /// Steading's boot-time daemon, so the pane gates either one; the
    /// distinction only tunes the explanatory copy.
    enum Variant: Sendable, Equatable {
        /// Installed from the Mac App Store (fully sandboxed). Carries
        /// a `_MASReceipt`.
        case appStore
        /// Direct-download / Homebrew cask GUI build (system-extension
        /// sandbox). No App Store receipt.
        case standalone
    }

    enum Status: Sendable, Equatable {
        /// A GUI `Tailscale.app` is present. It connects only after
        /// login, so it can't satisfy Steading's boot-time requirement
        /// and must be removed before the open-source daemon can be
        /// installed.
        case guiVariantPresent(Variant, appPath: String)
        /// The open-source `tailscale` CLI/daemon is on disk (the
        /// Homebrew formula). This is the build Steading manages.
        case openSourceInstalled(path: String)
        /// No Tailscale of any kind found — offer to install the formula.
        case notInstalled
    }

    /// Standard install location for the GUI app (both MAS and
    /// standalone land here).
    static let standardAppSearchPaths: [String] = [
        "/Applications/Tailscale.app",
    ]

    /// Standard locations for the open-source CLI, Apple Silicon brew
    /// prefix first, Intel second.
    static let standardCLISearchPaths: [String] = [
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    let appSearchPaths: [String]
    let cliSearchPaths: [String]

    init(appSearchPaths: [String] = Self.standardAppSearchPaths,
         cliSearchPaths: [String] = Self.standardCLISearchPaths) {
        self.appSearchPaths = appSearchPaths
        self.cliSearchPaths = cliSearchPaths
    }

    /// Probe the filesystem and return the first matching status. The
    /// GUI app is checked first because it's the blocker — if one is
    /// present the open-source CLI is irrelevant until it's removed.
    func detect() async -> Status {
        let fm = FileManager.default
        let appPath = appSearchPaths.first(where: { fm.fileExists(atPath: $0) })
        let masReceiptPresent = appPath.map {
            fm.fileExists(atPath: $0 + "/Contents/_MASReceipt/receipt")
        } ?? false
        let cliPath = cliSearchPaths.first(where: { fm.isExecutableFile(atPath: $0) })
        return Self.classify(
            guiAppPath: appPath,
            masReceiptPresent: masReceiptPresent,
            cliPath: cliPath
        )
    }

    /// Classify a GUI bundle by whether it carries a Mac App Store
    /// receipt. Pure — exposed for tests.
    static func variant(masReceiptPresent: Bool) -> Variant {
        masReceiptPresent ? .appStore : .standalone
    }

    /// The detection decision, given probe results. A present GUI app
    /// always wins (it's the blocker); otherwise an open-source CLI on
    /// disk means it's installed; otherwise nothing is installed.
    /// Pure — exposed for tests so every branch can be exercised
    /// without touching disk.
    static func classify(guiAppPath: String?,
                         masReceiptPresent: Bool,
                         cliPath: String?) -> Status {
        if let guiAppPath {
            return .guiVariantPresent(
                variant(masReceiptPresent: masReceiptPresent),
                appPath: guiAppPath
            )
        }
        if let cliPath {
            return .openSourceInstalled(path: cliPath)
        }
        return .notInstalled
    }
}
