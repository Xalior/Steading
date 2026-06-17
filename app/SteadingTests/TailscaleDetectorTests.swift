import Testing
import Foundation
@testable import Steading

/// All tests exercise the real `TailscaleDetector` code paths. The pure
/// `classify`/`variant` decisions are called with canned probe results;
/// the live `detect()` runs the real filesystem probe on this dev mac;
/// the boundary tests construct the real detector with boundary search
/// paths (empty, a real executable path, a temp `.app` bundle) and let
/// the production code decide. No stubs reimplement the logic.
@Suite("TailscaleDetector")
struct TailscaleDetectorTests {

    // MARK: - Pure decision — `classify` called directly.

    @Test("classify: GUI app with no receipt is the standalone variant")
    func classifyStandalone() {
        let status = TailscaleDetector.classify(
            guiAppPath: "/Applications/Tailscale.app",
            masReceiptPresent: false,
            cliPath: nil
        )
        #expect(status == .guiVariantPresent(.standalone, appPath: "/Applications/Tailscale.app"))
    }

    @Test("classify: GUI app with a MAS receipt is the App Store variant")
    func classifyAppStore() {
        let status = TailscaleDetector.classify(
            guiAppPath: "/Applications/Tailscale.app",
            masReceiptPresent: true,
            cliPath: nil
        )
        #expect(status == .guiVariantPresent(.appStore, appPath: "/Applications/Tailscale.app"))
    }

    @Test("classify: a present GUI app gates even when the CLI is also present")
    func classifyGUIWins() {
        let status = TailscaleDetector.classify(
            guiAppPath: "/Applications/Tailscale.app",
            masReceiptPresent: false,
            cliPath: "/opt/homebrew/bin/tailscale"
        )
        #expect(status == .guiVariantPresent(.standalone, appPath: "/Applications/Tailscale.app"))
    }

    @Test("classify: no GUI app but a CLI on disk is openSourceInstalled")
    func classifyOpenSource() {
        let status = TailscaleDetector.classify(
            guiAppPath: nil,
            masReceiptPresent: false,
            cliPath: "/opt/homebrew/bin/tailscale"
        )
        #expect(status == .openSourceInstalled(path: "/opt/homebrew/bin/tailscale"))
    }

    @Test("classify: nothing present is notInstalled")
    func classifyNotInstalled() {
        let status = TailscaleDetector.classify(
            guiAppPath: nil,
            masReceiptPresent: false,
            cliPath: nil
        )
        #expect(status == .notInstalled)
    }

    @Test("variant: receipt presence maps to App Store / standalone")
    func variantMapping() {
        #expect(TailscaleDetector.variant(masReceiptPresent: true) == .appStore)
        #expect(TailscaleDetector.variant(masReceiptPresent: false) == .standalone)
    }

    // MARK: - Live `detect()` — hits the real filesystem.

    @Test("detect: returns a coherent status on this dev mac")
    func liveDetect() async {
        let status = await TailscaleDetector().detect()
        // Whatever is (or isn't) installed, the result must agree with
        // the real filesystem the detector probed.
        switch status {
        case .guiVariantPresent(_, let appPath):
            #expect(FileManager.default.fileExists(atPath: appPath))
        case .openSourceInstalled(let path):
            #expect(FileManager.default.isExecutableFile(atPath: path))
        case .notInstalled:
            #expect(!FileManager.default.fileExists(atPath: "/Applications/Tailscale.app"))
        }
    }

    @Test("detect: empty search paths yield notInstalled")
    func detectEmptyPaths() async {
        let detector = TailscaleDetector(appSearchPaths: [], cliSearchPaths: [])
        let status = await detector.detect()
        #expect(status == .notInstalled)
    }

    @Test("detect: a real executable fed as the CLI path is openSourceInstalled")
    func detectRealCLIBoundary() async {
        // `/bin/ls` is a real executable — a boundary input feeding the
        // real `isExecutableFile` probe, not a mock.
        let detector = TailscaleDetector(appSearchPaths: [], cliSearchPaths: ["/bin/ls"])
        let status = await detector.detect()
        #expect(status == .openSourceInstalled(path: "/bin/ls"))
    }

    @Test("detect: a temp .app bundle is detected as a GUI variant")
    func detectTempAppBoundary() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("Tailscale-\(UUID().uuidString).app")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        // No receipt → standalone.
        let standalone = await TailscaleDetector(
            appSearchPaths: [base.path], cliSearchPaths: []
        ).detect()
        #expect(standalone == .guiVariantPresent(.standalone, appPath: base.path))

        // Add a MAS receipt → App Store.
        let receiptDir = base.appendingPathComponent("Contents/_MASReceipt")
        try fm.createDirectory(at: receiptDir, withIntermediateDirectories: true)
        try Data().write(to: receiptDir.appendingPathComponent("receipt"))
        let appStore = await TailscaleDetector(
            appSearchPaths: [base.path], cliSearchPaths: []
        ).detect()
        #expect(appStore == .guiVariantPresent(.appStore, appPath: base.path))
    }

    // MARK: - Install argv — pure.

    @Test("installArgv: installs the open-source formula")
    func installArgv() {
        #expect(TailscaleInstaller.installArgv() == ["install", "tailscale"])
    }
}
