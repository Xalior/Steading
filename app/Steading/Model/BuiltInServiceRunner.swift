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
/// - `enableCommand` / `disableCommand` are *command specs*, not
///   direct calls. `BuiltInServiceDetailView` feeds them to
///   `PrivilegedShell.run(_:)` which is today's interim
///   admin-privilege path (via `osascript`). When the SMAppService
///   privileged helper lands (see DESIGN.md § Technical realities),
///   only the `PrivilegedShell` implementation needs to change — the
///   runners keep the same shape.
struct BuiltInServiceRunner: Sendable {
    let id: String
    let displayName: String
    /// Human-readable note about what Steading looks at to decide the
    /// current state. Displayed in the UI under the state card.
    let detectionNote: String
    /// Live, unprivileged state read.
    let readState: @Sendable () async -> BuiltInServiceState
    /// Command line that will enable the service when run with
    /// administrator privileges. `nil` if the built-in doesn't have a
    /// single-command enable (e.g. SMB needs share configuration,
    /// Time Machine Server needs a destination).
    let enableCommand: [String]?
    /// Command line that will disable the service.
    let disableCommand: [String]?
}
