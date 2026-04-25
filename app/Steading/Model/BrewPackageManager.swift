import Foundation
import Observation

/// UI-facing brew model for the Brew Package Manager window. Owns the
/// unified package index loaded from brew's JWS cache + the
/// Steading-owned tap cache, the sidebar mode + its filters, per-row
/// marking state, the batched Apply pipeline (add phase before remove
/// phase, with a post-uninstall autoremove confirmation), and the
/// pin/unpin verbs. Reads the upgradable subset from
/// `BrewUpdateManager` so the headless cycle stays the single source
/// of truth for `brew outdated`.
@Observable
@MainActor
final class BrewPackageManager {

    // MARK: - Public types

    enum State: Equatable, Sendable {
        case idle
        case loading
        case applying
        case failed(message: String)
    }

    /// Outcome of the most recent Apply, kept on the manager so the
    /// progress area can display a success/failure/cancel indicator
    /// after the pipeline finishes.
    enum ApplyOutcome: Equatable, Sendable {
        case success
        case failed(exitCode: Int32)
        case cancelled
        case spawnFailed(reason: String)
    }

    enum SidebarMode: Sendable, Hashable {
        case status
        case origin
        case searchResults
    }

    /// Status mode's four mutually-exclusive view filters. Selecting
    /// `pinned` shows only pinned formulae regardless of installed/
    /// upgradable state — same single-key constraint as the others.
    enum StatusFilter: Sendable, Hashable, CaseIterable {
        case installed
        case notInstalled
        case upgradable
        case pinned
    }

    /// Verb derived from a row's package state at the moment Apply
    /// runs. Uniformly applied: each marked row contributes exactly
    /// one verb, the row's bare checkbox carries the user's intent.
    enum Verb: Sendable, Equatable {
        case install
        case upgrade
        case remove
    }

    /// One package row. Combines the universe entry with current
    /// per-host status. Identifiable on `fullToken` so SwiftUI lists
    /// can diff stably across refreshes.
    struct PackageRow: Sendable, Hashable, Identifiable {
        let entry: BrewIndexEntry
        let isInstalled: Bool
        let isOutdated: Bool
        let isPinned: Bool
        var id: String { entry.fullToken }
    }

    /// Argv breakdown for one Apply run. Each non-empty list becomes
    /// a brew sub-call in order; empty lists skip their phase.
    struct ApplyArgv: Sendable, Equatable {
        let upgrades: [String]
        let installs: [String]
        let removes: [String]
        var isEmpty: Bool {
            upgrades.isEmpty && installs.isEmpty && removes.isEmpty
        }
    }

    /// Enablement decisions for the toolbar. Pure — derived from
    /// state and counts.
    struct Buttons: Equatable, Sendable {
        let applyEnabled: Bool
        let checkNowEnabled: Bool
        let markAllEnabled: Bool
        let perRowEnabled: Bool
        let cancelEnabled: Bool
    }

    // MARK: - Pure helpers

    /// Verb a marked row's checkbox implies, given its current state.
    nonisolated static func verb(for row: PackageRow) -> Verb {
        if !row.isInstalled { return .install }
        if row.isOutdated { return .upgrade }
        return .remove
    }

    /// Split the marked rows into the three argv tails the Apply
    /// pipeline runs. Order within each list mirrors input order.
    nonisolated static func applyArgv(for rows: [PackageRow]) -> ApplyArgv {
        var upgrades: [String] = []
        var installs: [String] = []
        var removes: [String] = []
        for row in rows {
            let token = row.entry.fullToken
            switch verb(for: row) {
            case .upgrade: upgrades.append(token)
            case .install: installs.append(token)
            case .remove:  removes.append(token)
            }
        }
        return ApplyArgv(upgrades: upgrades, installs: installs, removes: removes)
    }

    /// Toolbar enablement table. Mirrors the prior
    /// `BrewUpdateManager.buttons(...)` shape with the new manager's
    /// state values; relocation-equivalent so the view's call site
    /// reads identically after the narrowing.
    nonisolated static func buttons(state: State,
                                    markedCount: Int,
                                    upgradableCount: Int) -> Buttons {
        let isApplying = state == .applying
        let isLoading = state == .loading
        let busy = isApplying || isLoading
        return Buttons(
            applyEnabled:    !busy && markedCount > 0,
            checkNowEnabled: !busy,
            markAllEnabled:  !busy && upgradableCount > 0,
            perRowEnabled:   !isApplying,
            cancelEnabled:   isApplying
        )
    }

    /// Status-mode predicate: does a row match the selected filter?
    nonisolated static func matches(_ row: PackageRow, statusFilter: StatusFilter) -> Bool {
        switch statusFilter {
        case .installed:    return row.isInstalled
        case .notInstalled: return !row.isInstalled
        case .upgradable:   return row.isOutdated
        case .pinned:       return row.isPinned
        }
    }

    /// Origin-mode predicate: does a row originate from the named tap?
    nonisolated static func matches(_ row: PackageRow, originTap tap: String) -> Bool {
        row.entry.tap == tap
    }

    /// Search-results predicate: case-insensitive substring match
    /// against name + `desc`, mirroring `brew search --desc`. The
    /// fully-qualified token is also matched so a user typing a tap
    /// prefix surfaces tap-namespaced packages.
    nonisolated static func matches(_ row: PackageRow, search needle: String) -> Bool {
        let lowered = needle.lowercased()
        if lowered.isEmpty { return false }
        if row.entry.token.lowercased().contains(lowered) { return true }
        if row.entry.fullToken.lowercased().contains(lowered) { return true }
        if let desc = row.entry.desc?.lowercased(), desc.contains(lowered) { return true }
        return false
    }

    // MARK: - Observable state

    /// Manager-level state. `idle` is the resting state once the
    /// initial index load has completed; `applying` is set while a
    /// brew sub-call (upgrade / install / uninstall / autoremove) is
    /// in flight; `loading` covers the index-refresh cycle; `failed`
    /// surfaces an index-load failure to the view.
    private(set) var state: State = .loading

    /// Universe of packages, keyed and ordered by `fullToken`.
    private(set) var rows: [PackageRow] = []

    /// Sidebar mode. Forced to `.searchResults` while `searchText` is
    /// non-empty (the view's search affordance).
    var sidebarMode: SidebarMode = .status

    /// Currently-selected Status mode filter.
    var statusFilter: StatusFilter = .upgradable

    /// Currently-selected tap (Origin mode). `nil` when nothing is
    /// selected — the view shows an empty list.
    var originTap: String?

    /// User-typed search text. Switching this from empty to non-empty
    /// flips `sidebarMode` to `.searchResults`; switching back to
    /// empty is the user's job (Search Results is sticky once
    /// entered, matching Synaptic's behaviour).
    var searchText: String = ""

    /// Set of marked row IDs (full tokens). Mutated through
    /// `mark(_:_:)` / `markAll(...)` / `unmarkAll()`.
    private(set) var marked: Set<String> = []

    /// Streaming output from the in-flight Apply, UTF-8 decoded in
    /// arrival order. Reset at the start of each Apply.
    private(set) var applyLog: String = ""

    /// Outcome of the most recent Apply. `nil` until the first Apply
    /// completes; cleared at the start of each fresh Apply.
    private(set) var recentApplyOutcome: ApplyOutcome?

    /// True while the Apply pipeline is paused on the post-uninstall
    /// autoremove confirmation. The view shows the dialog while this
    /// is true; pressing Yes/No calls `confirmAutoremove(_:)`.
    private(set) var pendingAutoremoveConfirmation: Bool = false

    /// Installed taps in display order, refreshed alongside the index.
    private(set) var taps: [BrewTapInfo] = []

    // MARK: - Lifecycle (skeleton — load/apply/pin land in subsequent commits)

    init() {}

    // MARK: - Marking

    func mark(_ id: String, _ on: Bool) {
        if on { marked.insert(id) } else { marked.remove(id) }
    }

    /// Mark every upgradable row. Idempotent.
    func markAllUpgrades() {
        for row in rows where row.isOutdated {
            marked.insert(row.id)
        }
    }

    func unmarkAll() {
        marked.removeAll()
    }

    // MARK: - Filtered view

    /// The current filtered slice the list pane shows, derived from
    /// `sidebarMode` + the active filter values.
    var filteredRows: [PackageRow] {
        switch sidebarMode {
        case .status:
            return rows.filter { Self.matches($0, statusFilter: statusFilter) }
        case .origin:
            guard let tap = originTap else { return [] }
            return rows.filter { Self.matches($0, originTap: tap) }
        case .searchResults:
            return rows.filter { Self.matches($0, search: searchText) }
        }
    }

    /// The marked rows, in the same order they appear in the unfiltered
    /// universe. Apply uses this — partial-failure ordering needs to
    /// be predictable and not depend on filter state.
    var markedRows: [PackageRow] {
        rows.filter { marked.contains($0.id) }
    }

    /// Count used by the toolbar's `markAllEnabled` decision: every
    /// row whose state implies an upgrade verb when checked.
    var upgradableCount: Int {
        rows.reduce(into: 0) { $0 += $1.isOutdated ? 1 : 0 }
    }
}
