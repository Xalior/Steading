import Foundation

// MARK: - Top-level

/// In-memory shape of a single service-definition YAML.
///
/// Decoded from YAML by `ServiceDefinitionLoader`; consumed by the
/// picker, install wizard, install pipeline, status pane, and
/// edit-config view. Conforms to `Codable` for direct Yams decoding;
/// every nested type matches a YAML key one-for-one so the YAML and
/// the in-memory representation stay tightly aligned.
public struct ServiceDefinition: Codable, Equatable, Sendable {

    /// Schema version; bumped whenever the YAML shape changes in a
    /// non-additive way. The loader rejects unknown versions.
    public let schemaVersion: Int

    /// Stable identifier for the service. Constrained to
    /// `[a-z][a-z0-9-]{1,30}` — used as a dictionary key, in file
    /// paths, in launchd labels (`com.xalior.steading.<id>`), and as
    /// the brew wrapper name (`steading-<id>`).
    public let serviceID: String

    /// Human-readable display name surfaced in the picker, sidebar,
    /// and status pane header.
    public let displayName: String

    /// One-line summary shown on the picker card.
    public let summary: String

    /// Brew formula Steading installs to bring this service in.
    /// Always a wrapper from `xalior/homebrew-steading`
    /// (`steading-<id>`); the upstream is reached transitively.
    public let brewFormula: String

    /// Upstream brew token used for `brew info` / `brew outdated`
    /// queries on the status pane (e.g. `mysql` for `steading-mysql`).
    public let upstreamFormula: String

    /// Service-user the LaunchDaemon runs as. Pattern enforced by
    /// the loader: `_<id>`. UID allocation is the helper's job; this
    /// type only carries the name.
    public let systemUser: SystemUser

    /// LaunchDaemon label and the plist body Steading writes for it.
    public let launchDaemon: LaunchDaemonSpec

    /// Files and directories Steading writes during install. Each
    /// `WriteTarget` is approval-gated by the consent system.
    public let writeTargets: [WriteTarget]

    /// Wizard pane definitions, in order. The install wizard renders
    /// them sequentially; the edit-config view renders the same panes
    /// over the service's *current* config.
    public let panes: [Pane]
}

// MARK: - System user

public struct SystemUser: Codable, Equatable, Sendable {
    /// `_<id>` form. `_mysql`, `_caddy`, etc.
    public let name: String

    /// Home directory the helper sets on `dscl . -create`. Defaults
    /// to `/var/empty` when absent.
    public let home: String?
}

// MARK: - LaunchDaemon

public struct LaunchDaemonSpec: Codable, Equatable, Sendable {
    /// Required label form: `com.xalior.steading.<id>`. Helper
    /// rejects any other prefix.
    public let label: String

    /// Per-key plist contents the helper materialises into
    /// `/Library/LaunchDaemons/<label>.plist`. Templated values
    /// (e.g. `{dataDir}`) are resolved against wizard field state at
    /// install time.
    public let plist: [String: PlistValue]
}

/// Limited plist value tree the launch-daemon spec is allowed to
/// contain. Closed enum so the loader can reject anything that
/// wouldn't round-trip through `PropertyListSerialization`.
public enum PlistValue: Codable, Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case integer(Int)
    case array([PlistValue])
    case dictionary([String: PlistValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .integer(i); return }
        if let a = try? c.decode([PlistValue].self) { self = .array(a); return }
        if let d = try? c.decode([String: PlistValue].self) { self = .dictionary(d); return }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "plist value must be string, bool, int, array, or dictionary"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .bool(let b): try c.encode(b)
        case .integer(let i): try c.encode(i)
        case .array(let a): try c.encode(a)
        case .dictionary(let d): try c.encode(d)
        }
    }
}

// MARK: - Panes

public struct Pane: Codable, Equatable, Sendable {
    public let id: String
    public let title: String

    /// Optional inline help text shown above the fields.
    public let help: String?

    /// Preflight checks run when this pane is the *preflight* pane.
    /// On any failure the wizard switches to its abort screen.
    public let preflightChecks: [PreflightCheck]?

    public let fields: [Field]?
}

public struct Field: Codable, Equatable, Sendable {
    public let id: String
    public let kind: FieldKind
    public let label: String

    /// Optional inline help shown below the field's label.
    public let help: String?

    /// Default value used when the wizard is first rendered. For
    /// `secret` fields, the default is ignored (the user must supply
    /// the secret explicitly).
    public let defaultValue: String?

    public let validation: Validation?

    /// When `true`, hidden behind the pane's "Show advanced" toggle.
    public let advanced: Bool?

    /// Warnings that appear adjacent to the field when their
    /// predicate evaluates true against the current value.
    public let warnings: [WarningPredicate]?

    /// For `secret` fields: the Keychain account name Steading
    /// stores the value under (qualified at runtime by service id).
    public let keychainAccount: String?

    /// When the field controls a path written by a `WriteTarget`,
    /// names that target so the install pipeline can locate it.
    public let writeTarget: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, label, help
        case defaultValue = "default"
        case validation, advanced, warnings, keychainAccount, writeTarget
    }
}

public enum FieldKind: String, Codable, Equatable, Sendable {
    case text
    case secret
    case toggle
    case choice
    case hostname
    case port
    case path
    case integer
}

public struct Validation: Codable, Equatable, Sendable {
    public let regex: String?
    public let minLength: Int?
    public let maxLength: Int?
    public let minimum: Int?
    public let maximum: Int?
    /// For `choice` fields: the legal options.
    public let choices: [String]?
}

public struct WarningPredicate: Codable, Equatable, Sendable {
    public let id: String
    public let predicate: Predicate
    public let message: String
}

/// A small predicate language the wizard evaluates against a field's
/// current text value. Closed set so the loader can validate every
/// arm at parse time.
public struct Predicate: Codable, Equatable, Sendable {
    public let kind: Kind
    public let value: String?

    public enum Kind: String, Codable, Equatable, Sendable {
        case equal
        case notEqual
        case matchesRegex
        case doesNotMatchRegex
    }
}

// MARK: - Preflight

public struct PreflightCheck: Codable, Equatable, Sendable {
    public let kind: Kind
    public let port: Int?
    public let path: String?
    public let executable: String?

    public enum Kind: String, Codable, Equatable, Sendable {
        /// Port `port` must be free.
        case portFree
        /// Path `path` must not exist.
        case pathAbsent
        /// Path `path` must exist.
        case pathPresent
        /// `which executable` must succeed (for upstream-binary checks
        /// after `brew install`).
        case executablePresent
    }
}
