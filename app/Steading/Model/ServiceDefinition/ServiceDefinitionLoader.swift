import Foundation
import Yams

/// Parses and validates a service-definition YAML into a typed
/// `ServiceDefinition`. Used identically by:
///
/// - the build-phase script (compiled into a small CLI that links
///   the main module), so a malformed YAML fails the build before
///   it ships;
/// - the runtime, so a hand-edited bundle resource or external YAML
///   is rejected with a useful message instead of crashing the app.
///
/// Strictness — the loader rejects:
///
/// - anchors and aliases (`&foo` / `*foo`)
/// - custom tags (anything outside the YAML core schema)
/// - non-explicit type coercions outside the explicit schema (the
///   Codable types pin every leaf to a specific Swift type)
/// - oversize sources (`ServiceDefinitionMaxSize`)
/// - schema invariants the type system can't capture (id patterns,
///   absolute-path requirements, regex compilability, etc.)
public enum ServiceDefinitionLoader {

    /// Schema version this loader knows how to read. A YAML with a
    /// different `schemaVersion` is rejected.
    public static let supportedSchemaVersion = 1

    /// Load and validate `source`. Returns the parsed definition or
    /// every error the loader could surface.
    public static func load(source: String) -> Result<ServiceDefinition, SchemaErrors> {
        if source.utf8.count > ServiceDefinitionMaxSize {
            return .failure(SchemaErrors([
                .oversize(bytes: source.utf8.count, limit: ServiceDefinitionMaxSize)
            ]))
        }

        // Strictness pre-pass: source-text scan for forbidden YAML
        // features (anchors `&`, aliases `*`, explicit tags `!`).
        //
        // We scan the source rather than walking Yams' Node tree
        // because Yams holds `Node.anchor` as a *weak* reference —
        // the parser deallocates its anchor list as soon as
        // compose() returns, so by the time we'd walk, the durable
        // signal is gone. Scanning the bytes catches the same set
        // before parsing happens.
        if let strictnessReason = strictnessRejection(in: source) {
            return .failure(SchemaErrors([.parse(reason: strictnessReason)]))
        }

        // Confirm Yams can at least parse what's left, so we surface
        // a syntax error before attempting Codable decode.
        do {
            _ = try Yams.compose(yaml: source)
        } catch {
            return .failure(SchemaErrors([.parse(reason: String(describing: error))]))
        }

        // Decode via Yams' Codable bridge. The Codable conformance
        // on every nested type pins each YAML leaf to a specific
        // Swift type, so unexpected coercions fall out as decode
        // errors here.
        let definition: ServiceDefinition
        do {
            let decoder = YAMLDecoder()
            definition = try decoder.decode(ServiceDefinition.self, from: source)
        } catch let DecodingError.dataCorrupted(ctx) {
            return .failure(SchemaErrors([
                .decode(path: keyPath(ctx.codingPath), reason: ctx.debugDescription)
            ]))
        } catch let DecodingError.keyNotFound(key, ctx) {
            return .failure(SchemaErrors([
                .decode(path: keyPath(ctx.codingPath + [key]),
                        reason: "missing required key")
            ]))
        } catch let DecodingError.typeMismatch(_, ctx) {
            return .failure(SchemaErrors([
                .decode(path: keyPath(ctx.codingPath), reason: ctx.debugDescription)
            ]))
        } catch let DecodingError.valueNotFound(_, ctx) {
            return .failure(SchemaErrors([
                .decode(path: keyPath(ctx.codingPath), reason: ctx.debugDescription)
            ]))
        } catch {
            return .failure(SchemaErrors([
                .decode(path: "", reason: String(describing: error))
            ]))
        }

        let invariantErrors = validateInvariants(definition)
        if !invariantErrors.isEmpty {
            return .failure(SchemaErrors(invariantErrors))
        }
        return .success(definition)
    }

    // MARK: - Strictness pre-pass

    /// Scans `source` for forbidden YAML constructs:
    ///
    /// - anchors (`&name`) and aliases (`*name`)
    /// - explicit tag handles (`!tag`, `!!tag`, `!<tag>`)
    ///
    /// Returns a human-readable rejection reason, or nil when the
    /// source is clean. Public so tests and the build-phase script
    /// can drive it directly.
    ///
    /// Strategy: strip single- and double-quoted strings (where
    /// these characters are legitimate content) plus comments, then
    /// look for the indicators in node-property positions —
    /// preceded by a whitespace, line start, or one of the YAML
    /// flow-context indicators (`:`, `-`, `,`, `[`, `{`).
    public static func strictnessRejection(in source: String) -> String? {
        let stripped = stripQuotedAndComments(source)

        // The leading character class matches "what comes before a
        // node property": start of line, whitespace, mapping/list
        // indicators, or flow-context separators.
        let prefix = #"(?:^|[\s:,\[\{\-])"#

        let patterns: [(String, String)] = [
            (prefix + #"&[A-Za-z0-9_-]+"#,
             "anchors and aliases are not permitted (found '&...')"),
            (prefix + #"\*[A-Za-z0-9_-]+"#,
             "anchors and aliases are not permitted (found '*...')"),
            (prefix + #"!{1,2}[A-Za-z<]"#,
             "explicit tags are not permitted (found '!...')"),
        ]
        for (pattern, message) in patterns {
            if stripped.range(of: pattern, options: .regularExpression) != nil {
                return message
            }
        }
        return nil
    }

    /// Replaces every single- or double-quoted string and `#`
    /// comment with whitespace, preserving line structure and byte
    /// positions so the strictness regex can scan only "live" YAML
    /// content. Block scalars (`|`, `>`) are left in place — they
    /// can contain anything, but anchors/tags lexically appear on
    /// the *header* line, not inside the block body.
    static func stripQuotedAndComments(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        var iterator = source.makeIterator()
        var pending: Character? = nil

        func nextChar() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        while let ch = nextChar() {
            switch ch {
            case "'":
                // Single-quoted: ends at the next single quote that
                // isn't escaped (`''` is an escape for `'` in YAML).
                out.append(" ")
                while let inner = nextChar() {
                    if inner == "'" {
                        if let peek = nextChar() {
                            if peek == "'" {
                                out.append(" ")
                                continue
                            } else {
                                pending = peek
                                out.append(" ")
                                break
                            }
                        } else {
                            out.append(" ")
                            break
                        }
                    } else if inner.isNewline {
                        out.append(inner)
                    } else {
                        out.append(" ")
                    }
                }
            case "\"":
                out.append(" ")
                while let inner = nextChar() {
                    if inner == "\\" {
                        // Skip the escaped char so an embedded \" doesn't
                        // close the string early.
                        if let escaped = nextChar() {
                            out.append(" ")
                            if escaped.isNewline { out.append(escaped) }
                        }
                    } else if inner == "\"" {
                        out.append(" ")
                        break
                    } else if inner.isNewline {
                        out.append(inner)
                    } else {
                        out.append(" ")
                    }
                }
            case "#":
                // Comment runs to end of line.
                out.append(" ")
                while let inner = nextChar() {
                    if inner.isNewline {
                        out.append(inner)
                        break
                    } else {
                        out.append(" ")
                    }
                }
            default:
                out.append(ch)
            }
        }
        return out
    }

    // MARK: - Schema invariants

    /// Pure validation of invariants the Codable layer can't enforce.
    /// Public so tests can call it directly with hand-built
    /// `ServiceDefinition` values.
    public static func validateInvariants(_ d: ServiceDefinition) -> [SchemaError] {
        var errors: [SchemaError] = []

        if d.schemaVersion != supportedSchemaVersion {
            errors.append(.invariant(
                field: "schemaVersion",
                reason: "unsupported version \(d.schemaVersion); loader supports \(supportedSchemaVersion)"
            ))
        }

        if !isValidServiceID(d.serviceID) {
            errors.append(.invariant(
                field: "serviceID",
                reason: "must match [a-z][a-z0-9-]{1,30}"
            ))
        }

        let expectedSystemUser = "_\(d.serviceID)"
        if d.systemUser.name != expectedSystemUser {
            errors.append(.invariant(
                field: "systemUser.name",
                reason: "must be '\(expectedSystemUser)' for serviceID '\(d.serviceID)'"
            ))
        }

        let expectedLabelPrefix = "com.xalior.steading.\(d.serviceID)"
        if !(d.launchDaemon.label == expectedLabelPrefix
             || d.launchDaemon.label.hasPrefix(expectedLabelPrefix + ".")) {
            errors.append(.invariant(
                field: "launchDaemon.label",
                reason: "must be '\(expectedLabelPrefix)' or start '\(expectedLabelPrefix).'"
            ))
        }

        let expectedBrew = "steading-\(d.serviceID)"
        if d.brewFormula != expectedBrew {
            errors.append(.invariant(
                field: "brewFormula",
                reason: "must be '\(expectedBrew)' (Steading installs the wrapper, not the upstream)"
            ))
        }

        if d.upstreamFormula.isEmpty {
            errors.append(.invariant(
                field: "upstreamFormula",
                reason: "must be non-empty (used for brew info / outdated)"
            ))
        }

        // Write targets
        var seenTargetIDs = Set<String>()
        for (i, t) in d.writeTargets.enumerated() {
            if !seenTargetIDs.insert(t.id).inserted {
                errors.append(.invariant(
                    field: "writeTargets[\(i)].id",
                    reason: "duplicate id '\(t.id)'"
                ))
            }
            if t.kind != .template, !t.path.hasPrefix("/") {
                errors.append(.invariant(
                    field: "writeTargets[\(i)].path",
                    reason: "literal/directory path must be absolute"
                ))
            }
            if t.kind == .template {
                if t.placeholders == nil || t.placeholders?.isEmpty == true {
                    errors.append(.invariant(
                        field: "writeTargets[\(i)].placeholders",
                        reason: "template kind requires at least one placeholder"
                    ))
                }
                let names = templatePlaceholderNames(in: t.path)
                if names.isEmpty {
                    errors.append(.invariant(
                        field: "writeTargets[\(i)].path",
                        reason: "template path must contain at least one '{name}' placeholder"
                    ))
                }
                for name in names where t.placeholders?[name] == nil {
                    errors.append(.invariant(
                        field: "writeTargets[\(i)].placeholders",
                        reason: "placeholder '{\(name)}' has no validation rule"
                    ))
                }
            }
            if t.mode < 0 || t.mode > 0o7777 {
                errors.append(.invariant(
                    field: "writeTargets[\(i)].mode",
                    reason: "mode \(t.mode) outside 0..0o7777"
                ))
            }
        }

        // Panes
        var seenPaneIDs = Set<String>()
        for (i, pane) in d.panes.enumerated() {
            if !seenPaneIDs.insert(pane.id).inserted {
                errors.append(.invariant(
                    field: "panes[\(i)].id",
                    reason: "duplicate id '\(pane.id)'"
                ))
            }
            if let fields = pane.fields {
                var seenFieldIDs = Set<String>()
                for (j, field) in fields.enumerated() {
                    if !seenFieldIDs.insert(field.id).inserted {
                        errors.append(.invariant(
                            field: "panes[\(i)].fields[\(j)].id",
                            reason: "duplicate id '\(field.id)'"
                        ))
                    }
                    if let regex = field.validation?.regex {
                        if (try? NSRegularExpression(pattern: regex)) == nil {
                            errors.append(.invariant(
                                field: "panes[\(i)].fields[\(j)].validation.regex",
                                reason: "invalid regex '\(regex)'"
                            ))
                        }
                    }
                    if field.kind == .secret, field.keychainAccount == nil {
                        errors.append(.invariant(
                            field: "panes[\(i)].fields[\(j)].keychainAccount",
                            reason: "secret fields require keychainAccount"
                        ))
                    }
                    if let target = field.writeTarget, !seenTargetIDs.contains(target) {
                        errors.append(.invariant(
                            field: "panes[\(i)].fields[\(j)].writeTarget",
                            reason: "references unknown writeTarget '\(target)'"
                        ))
                    }
                }
            }
            if let checks = pane.preflightChecks {
                for (j, check) in checks.enumerated() {
                    let label = "panes[\(i)].preflightChecks[\(j)]"
                    switch check.kind {
                    case .portFree:
                        if check.port == nil {
                            errors.append(.invariant(field: label, reason: "portFree requires port"))
                        }
                    case .pathAbsent, .pathPresent:
                        guard let p = check.path else {
                            errors.append(.invariant(
                                field: label,
                                reason: "\(check.kind.rawValue) requires path"
                            ))
                            break
                        }
                        if !p.hasPrefix("/") {
                            errors.append(.invariant(field: label, reason: "path must be absolute"))
                        }
                    case .executablePresent:
                        if check.executable == nil {
                            errors.append(.invariant(
                                field: label,
                                reason: "executablePresent requires executable"
                            ))
                        }
                    }
                }
            }
        }

        return errors
    }

    /// Public for direct test access. Service ids are constrained to
    /// the same shape used as a launchd-label suffix and a brew
    /// wrapper name.
    public static func isValidServiceID(_ s: String) -> Bool {
        let pattern = #"^[a-z][a-z0-9-]{1,30}$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    /// Pure helper exposed for testing. Extracts `{name}` placeholder
    /// names from a template path.
    public static func templatePlaceholderNames(in template: String) -> [String] {
        var names: [String] = []
        var current = ""
        var inside = false
        for ch in template {
            switch ch {
            case "{":
                inside = true
                current = ""
            case "}":
                if inside, !current.isEmpty {
                    names.append(current)
                }
                inside = false
            default:
                if inside { current.append(ch) }
            }
        }
        return names
    }

    private static func keyPath(_ path: [CodingKey]) -> String {
        path.map { $0.stringValue }.joined(separator: ".")
    }
}
