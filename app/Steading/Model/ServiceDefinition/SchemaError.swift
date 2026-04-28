import Foundation

/// Errors surfaced by `ServiceDefinitionLoader` when parsing or
/// validating a service definition YAML.
///
/// The loader returns *every* error it finds rather than failing on
/// the first; the build-phase script can show all problems in one
/// CI run, and the runtime UI can present a coherent rejection
/// reason for a hand-edited bundle resource.
public enum SchemaError: Error, Equatable, CustomStringConvertible {

    /// The YAML source could not be parsed at all (syntax error or a
    /// strictness rule violation — anchors, aliases, custom tags).
    case parse(reason: String)

    /// Yams' Codable decode failed. `path` is the dotted key path
    /// where decoding failed when Yams provides one; `reason` is the
    /// underlying decoding-error message.
    case decode(path: String, reason: String)

    /// A schema-level invariant the type system can't capture: a
    /// regex that doesn't compile, a path that isn't absolute, an
    /// id that violates its naming pattern, a duplicated id, etc.
    case invariant(field: String, reason: String)

    /// The YAML was larger than the loader's hard cap; rejected
    /// without parsing.
    case oversize(bytes: Int, limit: Int)

    public var description: String {
        switch self {
        case .parse(let reason):
            return "parse error: \(reason)"
        case .decode(let path, let reason):
            return "decode error at \(path): \(reason)"
        case .invariant(let field, let reason):
            return "schema invariant '\(field)': \(reason)"
        case .oversize(let bytes, let limit):
            return "yaml size \(bytes) exceeds limit \(limit)"
        }
    }
}

/// Hard cap on the size of a single service-definition YAML file.
/// Real definitions are a few KB; 256 KiB is generous while keeping
/// a DoS ceiling on inputs that may have been hand-edited.
public let ServiceDefinitionMaxSize: Int = 256 * 1024

/// Wraps a non-empty list of `SchemaError`s into a single `Error` so
/// `Result<ServiceDefinition, SchemaErrors>` is well-typed.
public struct SchemaErrors: Error, Equatable, CustomStringConvertible {
    public let errors: [SchemaError]
    public init(_ errors: [SchemaError]) { self.errors = errors }
    public var description: String {
        errors.map(\.description).joined(separator: "\n")
    }
}
