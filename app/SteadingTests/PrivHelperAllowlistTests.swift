import Testing
@testable import Steading

/// Tests call `PrivHelperAllowlist.isAllowed(executable:arguments:)`
/// directly. The same source file is compiled into both the main
/// Steading target (where tests see it via `@testable import`) and
/// the privileged helper target (where it enforces the allowlist
/// at runtime). The tests exercise production code with boundary
/// inputs — no parallel reimplementation.
@Suite("PrivHelperAllowlist")
struct PrivHelperAllowlistTests {

    // MARK: - Positives — every executable the v1 built-in services need.

    @Test("systemsetup is allowed")
    func systemsetupAllowed() {
        #expect(PrivHelperAllowlist.isAllowed(
            executable: "/usr/sbin/systemsetup",
            arguments: ["-setremotelogin", "on"]
        ))
    }

    @Test("launchctl is allowed")
    func launchctlAllowed() {
        #expect(PrivHelperAllowlist.isAllowed(
            executable: "/bin/launchctl",
            arguments: ["enable", "system/com.apple.smbd"]
        ))
    }

    @Test("AssetCacheManagerUtil is allowed")
    func assetCacheAllowed() {
        #expect(PrivHelperAllowlist.isAllowed(
            executable: "/usr/bin/AssetCacheManagerUtil",
            arguments: ["activate"]
        ))
    }

    @Test("socketfilterfw is allowed")
    func socketfilterfwAllowed() {
        #expect(PrivHelperAllowlist.isAllowed(
            executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
            arguments: ["--setglobalstate", "on"]
        ))
    }

    @Test("cupsctl is allowed")
    func cupsctlAllowed() {
        #expect(PrivHelperAllowlist.isAllowed(
            executable: "/usr/sbin/cupsctl",
            arguments: ["--share-printers"]
        ))
    }

    @Test("pmset is allowed")
    func pmsetAllowed() {
        #expect(PrivHelperAllowlist.isAllowed(
            executable: "/usr/bin/pmset",
            arguments: ["-a", "sleep", "0"]
        ))
    }

    // MARK: - Negatives — anything outside the allowlist is rejected.

    @Test("arbitrary executables are rejected")
    func arbitraryRejected() {
        #expect(!PrivHelperAllowlist.isAllowed(
            executable: "/bin/sh", arguments: ["-c", "echo hi"]
        ))
        #expect(!PrivHelperAllowlist.isAllowed(
            executable: "/bin/bash", arguments: []
        ))
        #expect(!PrivHelperAllowlist.isAllowed(
            executable: "/usr/bin/osascript", arguments: ["-e", "do shell script"]
        ))
        #expect(!PrivHelperAllowlist.isAllowed(
            executable: "/usr/bin/env", arguments: []
        ))
    }

    @Test("relative paths are rejected")
    func relativePathsRejected() {
        #expect(!PrivHelperAllowlist.isAllowed(
            executable: "systemsetup", arguments: []
        ))
        #expect(!PrivHelperAllowlist.isAllowed(
            executable: "./systemsetup", arguments: []
        ))
    }

    @Test("path traversal is rejected")
    func traversalRejected() {
        #expect(!PrivHelperAllowlist.isAllowed(
            executable: "/usr/sbin/../bin/sh", arguments: []
        ))
        #expect(!PrivHelperAllowlist.isAllowed(
            executable: "/usr/sbin/systemsetup/../../bin/sh", arguments: []
        ))
    }

    @Test("empty string is rejected")
    func emptyRejected() {
        #expect(!PrivHelperAllowlist.isAllowed(executable: "", arguments: []))
    }

    @Test("lookalike paths are rejected")
    func lookalikeRejected() {
        // Same basename, different directory — must NOT match.
        #expect(!PrivHelperAllowlist.isAllowed(
            executable: "/tmp/systemsetup", arguments: []
        ))
        #expect(!PrivHelperAllowlist.isAllowed(
            executable: "/usr/local/sbin/systemsetup", arguments: []
        ))
    }
}
