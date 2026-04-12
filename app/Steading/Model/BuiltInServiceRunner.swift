import Foundation

/// Current observable state of a macOS built-in service.
///
/// - `.enabled` / `.disabled` — simple on/off.
/// - `.custom(summary:isOn:)` — state that isn't reducible to a single
///   boolean (e.g. power management's multi-setting preset). The
///   optional `isOn` still lets the UI highlight when the current
///   settings happen to match Steading's recommended state.
/// - `.unknown(reason:)` — state could not be determined with the
///   unprivileged probes we have today; UI should explain why.
/// - `.error(String)` — the command probe itself failed.
enum BuiltInServiceState: Sendable, Equatable {
    case unknown(reason: String)
    case enabled
    case disabled
    case custom(summary: String, isOn: Bool?)
    case error(String)
}

/// Runs the real commands needed to observe and change a single
/// macOS built-in service (SSH, SMB, Content Caching, firewall, …).
///
/// Design notes
/// ------------
/// - `readState` always hits the real system. All unprivileged probes
///   run through `ProcessRunner`.
/// - `enableCommands` / `disableCommands` are sequences of command
///   specs run in order through `PrivHelperClient.runCommand`. Some
///   services need multiple steps to take immediate effect — e.g.
///   SMB needs `launchctl enable` (set the override) followed by
///   `launchctl kickstart` (actually start the daemon now).
struct BuiltInServiceRunner: Sendable {
    let id: String
    let displayName: String
    /// Human-readable note about what Steading looks at to decide the
    /// current state. Displayed in the UI under the state card.
    let detectionNote: String
    /// Live, unprivileged state read.
    let readState: @Sendable () async -> BuiltInServiceState
    /// Ordered sequence of commands to enable the service. Each
    /// command is an argv array run as root via the privileged helper.
    /// `nil` if the service has no single-action enable path (e.g.
    /// Power Management needs a multi-setting preset, Time Machine
    /// needs share configuration).
    let enableCommands: [[String]]?
    /// Ordered sequence of commands to disable the service.
    let disableCommands: [[String]]?
}
