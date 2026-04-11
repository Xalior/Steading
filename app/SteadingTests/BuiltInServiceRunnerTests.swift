import Testing
import Foundation
@testable import Steading

/// Tests exercise the real `BuiltInServiceRunner` code paths. Pure
/// parsers (`parseLaunchdOverride`, `pmsetValue`) are called directly
/// with canned input. Live runners call `readState()` against the
/// real filesystem and real system commands. No stubs.
@Suite("BuiltInServiceRunner")
struct BuiltInServiceRunnerTests {

    // MARK: - parseLaunchdOverride — pure parser, real production function.

    @Test("parseLaunchdOverride: picks up 'enabled' for matching label")
    func parseEnabled() {
        let raw = """
            disabled services = {
                "com.apple.something" => disabled
                "com.openssh.sshd" => enabled
                "com.apple.other" => disabled
            }
            """
        let result = BuiltInServiceRunner.parseLaunchdOverride(
            output: raw, label: "com.openssh.sshd"
        )
        #expect(result == .enabled)
    }

    @Test("parseLaunchdOverride: picks up 'disabled' for matching label")
    func parseDisabled() {
        let raw = """
            disabled services = {
                "com.apple.smbd" => disabled
            }
            """
        #expect(BuiltInServiceRunner.parseLaunchdOverride(
            output: raw, label: "com.apple.smbd"
        ) == .disabled)
    }

    @Test("parseLaunchdOverride: unknown when label is absent")
    func parseUnknown() {
        let raw = """
            disabled services = {
                "com.apple.other" => enabled
            }
            """
        let result = BuiltInServiceRunner.parseLaunchdOverride(
            output: raw, label: "com.apple.smbd"
        )
        if case .unknown = result { } else {
            Issue.record("expected .unknown, got \(result)")
        }
    }

    @Test("parseLaunchdOverride: does not match label prefixes")
    func parseExactMatchOnly() {
        // A lookup for "com.openssh.sshd" must NOT match
        // "com.openssh.sshd-agent" on a neighbouring line.
        let raw = """
            "com.openssh.sshd-agent" => enabled
            "com.openssh.sshd" => disabled
            """
        #expect(BuiltInServiceRunner.parseLaunchdOverride(
            output: raw, label: "com.openssh.sshd"
        ) == .disabled)
    }

    @Test("parseLaunchdOverride: handles empty output")
    func parseEmpty() {
        let result = BuiltInServiceRunner.parseLaunchdOverride(
            output: "", label: "com.anything"
        )
        if case .unknown = result { } else {
            Issue.record("expected .unknown, got \(result)")
        }
    }

    // MARK: - pmsetValue — pure parser, real production function.

    @Test("pmsetValue: extracts numeric values from pmset -g output")
    func pmsetExtractNumeric() {
        let raw = """
            System-wide power settings:
            Currently in use:
             standby              1
             sleep                0 (sleep prevented by Google Chrome)
             womp                 1
             autopoweroff         1
            """
        #expect(BuiltInServiceRunner.pmsetValue(for: "sleep", in: raw) == "0")
        #expect(BuiltInServiceRunner.pmsetValue(for: "womp",  in: raw) == "1")
        #expect(BuiltInServiceRunner.pmsetValue(for: "autopoweroff", in: raw) == "1")
        #expect(BuiltInServiceRunner.pmsetValue(for: "standby",      in: raw) == "1")
    }

    @Test("pmsetValue: returns nil for keys that aren't present")
    func pmsetMissingKey() {
        let raw = " sleep 0\n womp 1"
        #expect(BuiltInServiceRunner.pmsetValue(for: "nothingzzz", in: raw) == nil)
    }

    // MARK: - Registry integrity.

    @Test("registry: every BuiltInCatalog item has a runner")
    func registryIsComplete() {
        for item in BuiltInCatalog.items {
            #expect(
                BuiltInServiceRegistry.runner(for: item.id) != nil,
                "no runner registered for built-in catalog item \(item.id)"
            )
        }
    }

    @Test("registry: runner ids match their catalog item ids")
    func registryIdsAlign() {
        for item in BuiltInCatalog.items {
            guard let runner = BuiltInServiceRegistry.runner(for: item.id) else {
                continue
            }
            #expect(runner.id == item.id,
                    "runner.id \(runner.id) != catalog id \(item.id)")
        }
    }

    // MARK: - Live runners — hit real system commands end-to-end.

    @Test("ssh runner: live readState resolves to a defined value")
    func liveSSHState() async {
        let state = await BuiltInServiceRunner.ssh.readState()
        expectDefinedBooleanState(state, for: "ssh")
    }

    @Test("smb runner: live readState resolves to a defined value")
    func liveSMBState() async {
        let state = await BuiltInServiceRunner.smb.readState()
        expectDefinedBooleanState(state, for: "smb")
    }

    @Test("screenSharing runner: live readState resolves to a defined value")
    func liveScreenSharingState() async {
        let state = await BuiltInServiceRunner.screenSharing.readState()
        expectDefinedBooleanState(state, for: "screen-sharing")
    }

    @Test("contentCaching runner: live readState resolves to enabled or disabled")
    func liveContentCachingState() async {
        let state = await BuiltInServiceRunner.contentCaching.readState()
        switch state {
        case .enabled, .disabled:
            break
        case .unknown(let reason):
            Issue.record("content caching state unknown: \(reason)")
        case .error(let msg):
            Issue.record("content caching state error: \(msg)")
        case .custom:
            Issue.record(".custom is unexpected for content caching")
        }
    }

    @Test("firewall runner: live readState resolves to enabled or disabled")
    func liveFirewallState() async {
        let state = await BuiltInServiceRunner.firewall.readState()
        switch state {
        case .enabled, .disabled:
            break
        case .unknown(let reason):
            Issue.record("firewall state unknown: \(reason)")
        case .error(let msg):
            Issue.record("firewall state error: \(msg)")
        case .custom:
            Issue.record(".custom is unexpected for firewall")
        }
    }

    @Test("printerSharing runner: live readState resolves to enabled or disabled")
    func livePrinterSharingState() async {
        let state = await BuiltInServiceRunner.printerSharing.readState()
        switch state {
        case .enabled, .disabled:
            break
        case .unknown(let reason):
            Issue.record("printer sharing state unknown: \(reason)")
        case .error(let msg):
            Issue.record("printer sharing state error: \(msg)")
        case .custom:
            Issue.record(".custom is unexpected for printer sharing")
        }
    }

    @Test("power runner: live readState returns a custom pmset summary")
    func livePowerState() async {
        let state = await BuiltInServiceRunner.power.readState()
        guard case .custom(let summary, _) = state else {
            Issue.record("expected .custom for power runner, got \(state)")
            return
        }
        #expect(summary.contains("sleep="))
        #expect(summary.contains("womp="))
    }

    @Test("timeMachine runner: state is .unknown until multi-source detection lands")
    func liveTimeMachineState() async {
        let state = await BuiltInServiceRunner.timeMachine.readState()
        if case .unknown = state { } else {
            Issue.record("expected .unknown for time machine runner, got \(state)")
        }
    }

    // MARK: - Helpers

    /// Assert that a state is one of the four acceptable "resolved"
    /// values (enabled/disabled/unknown/error). Any of these is fine
    /// for the boolean-shaped runners; we only care that the live
    /// command path ran end-to-end without blowing up.
    private func expectDefinedBooleanState(_ state: BuiltInServiceState, for id: String) {
        switch state {
        case .enabled, .disabled, .unknown, .error:
            break
        case .custom:
            Issue.record(".custom is unexpected for \(id) runner, got \(state)")
        }
    }
}
