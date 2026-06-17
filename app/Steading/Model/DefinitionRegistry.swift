import Foundation
import Observation

/// Where a service-definition came from and how trustworthy it is at
/// load time.
public enum DefinitionOrigin: Equatable, Sendable {
    /// Bundle YAML whose hash matches the recorded build-time hash.
    case bundleTrusted
    /// Bundle YAML whose hash differs from the recorded value (or
    /// has no recorded value). The user must approve before it loads.
    case bundleModified
    /// External YAML dropped into
    /// `~/Library/Application Support/Steading/ServiceDefinitions/`.
    /// External entries replace bundle entries that share a serviceID.
    case external
}

/// One entry in the registry.
public struct DefinitionRecord: Equatable, Sendable {
    public let definition: ServiceDefinition
    public let yamlPath: String
    public let hash: String
    public let origin: DefinitionOrigin
    /// True when (yamlPath, hash) is recorded in the helper's
    /// approvals plist (or when origin is `.bundleTrusted`).
    public var approved: Bool

    public var serviceID: String { definition.serviceID }
    public var needsApproval: Bool {
        origin != .bundleTrusted && !approved
    }
}

/// Holds the merged set of bundle + external service definitions for
/// the running app. Drives the picker (which only shows approved
/// entries), the consent gate (which iterates `needsApproval`), and
/// Prefs → Advanced (which lists every external/modified entry).
///
/// Purely a data model — I/O happens in `loadAll(...)` and the
/// approval methods, both of which take their dependencies as
/// parameters so tests can drive the registry against a temp
/// directory without launchd, the real helper, or a real bundle.
@Observable
@MainActor
public final class DefinitionRegistry {

    public private(set) var records: [DefinitionRecord] = []

    public init() {}

    /// Records that need approval before they can be used.
    public var pendingApprovals: [DefinitionRecord] {
        records.filter { $0.needsApproval }
    }

    /// Records that are loaded and approved (the picker shows these).
    public var approved: [DefinitionRecord] {
        records.filter { $0.approved && parseSucceeded($0) }
    }

    /// External or modified records (Prefs → Advanced shows these).
    public var externalEntries: [DefinitionRecord] {
        records.filter { $0.origin != .bundleTrusted }
    }

    /// Merge bundle and external sources into a single deduplicated
    /// set. External entries replace bundle entries that share a
    /// serviceID. The caller has already loaded each YAML through
    /// `ServiceDefinitionLoader`; only valid definitions reach this
    /// method.
    public func loadAll(bundleDirectory: URL,
                        bundleHashListURL: URL,
                        externalDirectory: URL,
                        currentApprovals: [String: String]) {
        var merged: [String: DefinitionRecord] = [:]

        // Bundle pass — verify against build-time hashes, decode the
        // ones that pass, partition mismatched ones for the consent
        // gate.
        let partition: BundleDefinitionVerifier.Partition
        do {
            partition = try BundleDefinitionVerifier.verify(
                directory: bundleDirectory,
                hashListURL: bundleHashListURL
            )
        } catch {
            partition = BundleDefinitionVerifier.Partition()
        }

        let fm = FileManager.default
        for name in partition.matched + partition.mismatched + partition.unrecorded {
            let url = bundleDirectory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let source = String(data: data, encoding: .utf8) else { continue }
            guard case .success(let def) = ServiceDefinitionLoader.load(source: source) else {
                continue
            }
            let hash = DefinitionHash.sha256Hex(data)
            let origin: DefinitionOrigin = partition.matched.contains(name)
                ? .bundleTrusted : .bundleModified
            let approved = origin == .bundleTrusted
                || currentApprovals[url.path] == hash
            merged[def.serviceID] = DefinitionRecord(
                definition: def,
                yamlPath: url.path,
                hash: hash,
                origin: origin,
                approved: approved
            )
        }

        // External pass — overwrites bundle entries by serviceID.
        if fm.fileExists(atPath: externalDirectory.path) {
            let externalEntries = (try? ExternalDefinitionScanner.scan(directory: externalDirectory)) ?? []
            for entry in externalEntries {
                guard case .success(let def) = ServiceDefinitionLoader.load(source: entry.source) else {
                    continue
                }
                let approved = currentApprovals[entry.url.path] == entry.hash
                merged[def.serviceID] = DefinitionRecord(
                    definition: def,
                    yamlPath: entry.url.path,
                    hash: entry.hash,
                    origin: .external,
                    approved: approved
                )
            }
        }

        records = merged.values.sorted { $0.serviceID < $1.serviceID }
    }

    /// Mark a record approved in the registry. Caller is responsible
    /// for persisting via `helper.recordApproval`.
    public func markApproved(yamlPath: String) {
        records = records.map {
            var r = $0
            if r.yamlPath == yamlPath { r.approved = true }
            return r
        }
    }

    /// Drop a record from the registry (Deny path or Forget action).
    public func remove(yamlPath: String) {
        records.removeAll { $0.yamlPath == yamlPath }
    }

    private func parseSucceeded(_ r: DefinitionRecord) -> Bool { true }
}
