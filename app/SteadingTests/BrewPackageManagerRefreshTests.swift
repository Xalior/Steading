import Testing
import Foundation
@testable import Steading

/// Index-loader tests for `BrewPackageManager.refresh`. The loader
/// pulls from five sources — JWS formula cache, JWS cask cache,
/// Steading tap-cache, brew list (formulae / casks / pinned), and
/// brew tap-info — and composes them into rows with
/// installed/outdated/pinned status. These tests inject canned
/// bytes for each source through the manager's DI seams and assert
/// the composed shape.
@Suite("BrewPackageManager — refresh")
@MainActor
struct BrewPackageManagerRefreshTests {

    /// A scripted runner that responds to specific argv prefixes with
    /// canned stdout. Anything not in the script returns a zero-exit
    /// empty response (the loader treats that as "no entries").
    private final class ScriptedRunner: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [[String]: String] = [:]

        func respond(to argv: [String], stdout: String) {
            lock.lock(); defer { lock.unlock() }
            responses[argv] = stdout
        }

        func runner() -> BrewUpdateManager.Runner {
            return { args in
                self.lock.lock()
                let stdout = self.responses[args]
                self.lock.unlock()
                return .ran(exitCode: 0,
                            stdout: (stdout ?? "").data(using: .utf8) ?? Data(),
                            stderr: Data())
            }
        }
    }

    /// Wait until a predicate is true or a small timeout elapses.
    private func waitFor(_ predicate: @MainActor () -> Bool,
                         timeoutSeconds: Double = 1.0) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test("refresh: composes installed/outdated/pinned status across all five sources")
    func refresh_composesAllSources() async throws {
        let runner = ScriptedRunner()
        runner.respond(to: ["list", "--formula", "-1"], stdout: "git\njq\nneovim\n")
        runner.respond(to: ["list", "--cask", "-1"], stdout: "firefox\n")
        runner.respond(to: ["list", "--pinned"], stdout: "git\n")
        runner.respond(to: ["tap-info", "--json", "--installed"], stdout: """
            [{"name":"cirruslabs/cli","formula_names":["cirruslabs/cli/tart"],"cask_tokens":[]}]
            """)

        let formulaJWSPayload = #"""
        [
          {"name":"git","full_name":"git","tap":"homebrew/core","desc":"Distributed revision control system"},
          {"name":"jq","full_name":"jq","tap":"homebrew/core","desc":"JSON processor"},
          {"name":"neovim","full_name":"neovim","tap":"homebrew/core","desc":"Editor"}
        ]
        """#
        let caskJWSPayload = #"""
        [
          {"token":"firefox","full_token":"firefox","tap":"homebrew/cask","desc":"Browser"}
        ]
        """#
        let tapIndexPayload = #"""
        {"formulae":[{"name":"tart","full_name":"cirruslabs/cli/tart","tap":"cirruslabs/cli","desc":"VMs"}],"casks":[]}
        """#

        let formulaURL = URL(fileURLWithPath: "/tmp/test-formula.jws.json")
        let caskURL = URL(fileURLWithPath: "/tmp/test-cask.jws.json")
        let tapURL = URL(fileURLWithPath: "/tmp/test-tap-index.json")

        let reader: BrewPackageManager.DataReader = { url in
            switch url {
            case formulaURL:
                return jwsEnvelope(payload: formulaJWSPayload)
            case caskURL:
                return jwsEnvelope(payload: caskJWSPayload)
            case tapURL:
                return tapIndexPayload.data(using: .utf8)!
            default:
                throw CocoaError(.fileNoSuchFile)
            }
        }

        let manager = BrewPackageManager(
            runner: runner.runner(),
            jwsCachePathResolver: { kind in
                switch kind {
                case .formula: return formulaURL
                case .cask:    return caskURL
                }
            },
            tapIndexCachePathResolver: { tapURL },
            dataReader: reader
        )

        let outdated = [
            OutdatedPackage(name: "neovim", installedVersion: "0.12.1",
                            availableVersion: "0.12.2", kind: .formula),
        ]

        manager.refresh(outdated: outdated)
        await waitFor { manager.state == .idle && !manager.rows.isEmpty }

        // Universe = JWS formulae (3) + JWS casks (1) + tap-index entries (1) = 5
        #expect(manager.rows.count == 5)

        // git: installed (in formula list) + pinned (in pinned list) + not outdated
        let git = try #require(manager.rows.first { $0.entry.token == "git" })
        #expect(git.isInstalled)
        #expect(git.isPinned)
        #expect(!git.isOutdated)

        // jq: installed, not pinned, not outdated
        let jq = try #require(manager.rows.first { $0.entry.token == "jq" })
        #expect(jq.isInstalled)
        #expect(!jq.isPinned)
        #expect(!jq.isOutdated)

        // neovim: installed, not pinned, outdated (matches BrewUpdateManager.outdated)
        let neovim = try #require(manager.rows.first { $0.entry.token == "neovim" })
        #expect(neovim.isInstalled)
        #expect(!neovim.isPinned)
        #expect(neovim.isOutdated)

        // firefox: installed (cask list), not pinned, not outdated
        let firefox = try #require(manager.rows.first { $0.entry.token == "firefox" })
        #expect(firefox.isInstalled)
        #expect(!firefox.isPinned)

        // tart: in tap-index, not installed
        let tart = try #require(manager.rows.first { $0.entry.token == "tart" })
        #expect(!tart.isInstalled)
        #expect(!tart.isPinned)

        // taps loaded
        #expect(manager.taps.map(\.name) == ["cirruslabs/cli"])
    }

    @Test("refresh: missing on-disk caches yield an empty universe (no error)")
    func refresh_missingCaches_emptyUniverseNotError() async {
        let runner = ScriptedRunner()
        let manager = BrewPackageManager(
            runner: runner.runner(),
            jwsCachePathResolver: { _ in nil },
            tapIndexCachePathResolver: { nil },
            dataReader: { _ in throw CocoaError(.fileNoSuchFile) }
        )

        manager.refresh(outdated: [])
        await waitFor { manager.state == .idle }

        #expect(manager.rows.isEmpty)
        #expect(manager.state == .idle)
    }

    @Test("refresh: in-flight refresh coalesces — second call is a no-op")
    func refresh_inFlight_coalesces() async {
        let calls = TestCounter()
        let runner: BrewUpdateManager.Runner = { _ in
            await calls.increment()
            try? await Task.sleep(for: .milliseconds(20))
            return .ran(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let manager = BrewPackageManager(
            runner: runner,
            jwsCachePathResolver: { _ in nil },
            tapIndexCachePathResolver: { nil },
            dataReader: { _ in throw CocoaError(.fileNoSuchFile) }
        )

        manager.refresh(outdated: [])
        manager.refresh(outdated: [])
        manager.refresh(outdated: [])
        await waitFor { manager.state == .idle }

        // The first refresh spawns four runner calls: brew list --formula,
        // brew list --cask, brew list --pinned, brew tap-info. Subsequent
        // refresh() calls during the first one's flight must not spawn a
        // second pipeline.
        let total = await calls.value
        #expect(total == 4)
    }

    // MARK: - Helpers

    nonisolated private func jwsEnvelope(payload: String) -> Data {
        let escaped = String(
            data: try! JSONEncoder().encode(payload),
            encoding: .utf8
        )!
        return #"{"payload":\#(escaped),"signatures":[]}"#.data(using: .utf8)!
    }
}

private actor TestCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
