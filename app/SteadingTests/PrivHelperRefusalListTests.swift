import Testing
@testable import Steading

/// Pure tests for `PrivHelperRefusalList`. Every test calls the real
/// production refusal function with canned (path, mode) inputs.
@Suite("PrivHelperRefusalList")
struct PrivHelperRefusalListTests {

    // MARK: - Mode bits

    @Test("Refuses SUID bit")
    func refusesSUID() {
        #expect(PrivHelperRefusalList.refuse(path: "/opt/x/file", mode: 0o4644) == .suidBit)
    }

    @Test("Refuses SGID bit")
    func refusesSGID() {
        #expect(PrivHelperRefusalList.refuse(path: "/opt/x/file", mode: 0o2644) == .sgidBit)
    }

    @Test("Refuses sticky bit")
    func refusesSticky() {
        #expect(PrivHelperRefusalList.refuse(path: "/opt/x/file", mode: 0o1644) == .stickyBit)
    }

    @Test("Refuses out-of-range modes")
    func refusesBadMode() {
        if case .modeOutOfRange = PrivHelperRefusalList.refuse(path: "/opt/x", mode: -1) {} else {
            Issue.record("expected modeOutOfRange for -1")
        }
        if case .modeOutOfRange = PrivHelperRefusalList.refuse(path: "/opt/x", mode: 0o10000) {} else {
            Issue.record("expected modeOutOfRange for 0o10000")
        }
    }

    @Test("Accepts plain modes")
    func acceptsPlainMode() {
        #expect(PrivHelperRefusalList.refuse(path: "/opt/steading/x", mode: 0o644) == nil)
        #expect(PrivHelperRefusalList.refuse(path: "/opt/steading/x", mode: 0o755) == nil)
        #expect(PrivHelperRefusalList.refuse(path: "/opt/steading/x", mode: 0o600) == nil)
    }

    // MARK: - Path shape

    @Test("Refuses relative paths")
    func refusesRelative() {
        #expect(PrivHelperRefusalList.refuse(path: "opt/x", mode: 0o644) == .pathNotAbsolute)
        #expect(PrivHelperRefusalList.refuse(path: "x", mode: 0o644) == .pathNotAbsolute)
    }

    @Test("Refuses path traversal")
    func refusesTraversal() {
        #expect(PrivHelperRefusalList.refuse(path: "/opt/x/../etc/passwd", mode: 0o644) == .pathTraversal)
        #expect(PrivHelperRefusalList.refuse(path: "/opt/x/./y", mode: 0o644) == .pathTraversal)
    }

    @Test("Refuses non-canonical paths")
    func refusesNonCanonical() {
        #expect(PrivHelperRefusalList.refuse(path: "//opt/x", mode: 0o644) == .nonCanonical)
        #expect(PrivHelperRefusalList.refuse(path: "/opt/x/", mode: 0o644) == .nonCanonical)
    }

    // MARK: - Blocklist

    @Test("Blocklist: sudoers and variants",
          arguments: [
              "/etc/sudoers",
              "/etc/sudoers.d/anything",
              "/private/etc/sudoers",
              "/private/etc/sudoers.d/anything",
          ])
    func blocksSudoers(_ path: String) {
        if case .blocklisted = PrivHelperRefusalList.refuse(path: path, mode: 0o644) {} else {
            Issue.record("expected blocklist match for \(path)")
        }
    }

    @Test("Blocklist: pam.d, master.passwd, sudo db, audit, system")
    func blocksOtherSystemPaths() {
        let paths = [
            "/etc/pam.d/login",
            "/etc/master.passwd",
            "/var/db/sudo/anything",
            "/private/etc/security/audit_control",
            "/System/Library/anything",
        ]
        for p in paths {
            if case .blocklisted = PrivHelperRefusalList.refuse(path: p, mode: 0o644) {} else {
                Issue.record("expected blocklist match for \(p)")
            }
        }
    }

    @Test("Blocklist: /usr/bin /usr/sbin /sbin /bin write attempts")
    func blocksSystemBinDirs() {
        for p in ["/usr/bin/foo", "/usr/sbin/foo", "/sbin/foo", "/bin/foo"] {
            if case .blocklisted = PrivHelperRefusalList.refuse(path: p, mode: 0o755) {} else {
                Issue.record("expected blocklist match for \(p)")
            }
        }
    }

    @Test("Blocklist: PrivilegedHelperTools rogue helpers")
    func blocksRogueHelper() {
        if case .blocklisted = PrivHelperRefusalList.refuse(
            path: "/Library/PrivilegedHelperTools/com.example.malware",
            mode: 0o755) {} else {
            Issue.record("expected rogue-helper rejection")
        }
    }

    @Test("Allows writes to Steading's own helper")
    func allowsOwnHelper() {
        let result = PrivHelperRefusalList.refuse(
            path: PrivHelperRefusalList.ownHelperPath,
            mode: 0o755
        )
        #expect(result == nil, "own helper write must be allowed; got \(String(describing: result))")
    }

    // MARK: - Legitimate paths

    @Test("Allows writes to legitimate Steading-managed paths",
          arguments: [
              "/opt/steading/mysql/data",
              "/opt/homebrew/etc/my.cnf",
              "/Library/LaunchDaemons/com.xalior.steading.mysql.plist",
              "/Library/Application Support/Steading/installed.plist",
          ])
    func allowsLegitimate(_ path: String) {
        let result = PrivHelperRefusalList.refuse(path: path, mode: 0o644)
        #expect(result == nil, "expected no rejection for \(path); got \(String(describing: result))")
    }
}
