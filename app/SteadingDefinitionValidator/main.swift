import Foundation

/// `steading-definition-validator` — command-line tool for parsing,
/// validating, and hashing Steading service-definition YAMLs.
///
/// Two roles:
///
/// 1. **Build-phase tool.** Steading's Xcode build phase invokes this
///    tool against the bundle's `Resources/ServiceDefinitions/`
///    directory; the tool fails the build if any YAML doesn't parse
///    or doesn't validate, and writes `.bundle-hashes.plist` so the
///    runtime can verify integrity at launch.
/// 2. **Authoring tool.** Anyone writing third-party service
///    definitions (or replacing built-ins via the external data
///    directory) can run the same tool against their YAML to surface
///    schema errors before installing the file.
///
/// The CLI links the same `ServiceDefinitionLoader`, `DefinitionHash`,
/// and `BundleHashList` types the runtime uses, so build-time and
/// runtime never disagree.
///
/// Usage:
///
///   steading-definition-validator validate <path>...
///       Validate one or more YAMLs (file or directory). Non-zero
///       exit on the first error encountered; every error is printed.
///
///   steading-definition-validator hashlist <directory> --output <plist>
///       Validate every *.yml in <directory>, then write a hash list
///       plist to <plist>. Used by Steading's build phase.

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case validation(path: String, errors: [SchemaError])
    case io(String)

    var description: String {
        switch self {
        case .usage(let s): return "usage: \(s)"
        case .validation(let p, let errs):
            return "\(p): " + errs.map(\.description).joined(separator: "; ")
        case .io(let s): return s
        }
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    printUsage()
    exit(64)
}

do {
    switch arguments[1] {
    case "validate":
        try runValidate(paths: Array(arguments.dropFirst(2)))
    case "hashlist":
        try runHashList(args: Array(arguments.dropFirst(2)))
    case "-h", "--help", "help":
        printUsage()
        exit(0)
    default:
        printUsage()
        exit(64)
    }
} catch let CLIError.usage(msg) {
    FileHandle.standardError.write(Data("usage error: \(msg)\n".utf8))
    exit(64)
} catch let CLIError.validation(path, errs) {
    for err in errs {
        FileHandle.standardError.write(Data("\(path): \(err.description)\n".utf8))
    }
    exit(65)
} catch let CLIError.io(msg) {
    FileHandle.standardError.write(Data("io error: \(msg)\n".utf8))
    exit(74)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

// MARK: - Subcommands

func runValidate(paths: [String]) throws {
    if paths.isEmpty {
        throw CLIError.usage("validate <path>...")
    }
    var failures = 0
    for path in paths {
        let urls = try resolveYamlURLs(at: path)
        for url in urls {
            do {
                _ = try loadAndValidate(url: url)
                print("ok: \(url.path)")
            } catch let CLIError.validation(p, errs) {
                failures += 1
                for err in errs {
                    FileHandle.standardError.write(Data("\(p): \(err.description)\n".utf8))
                }
            }
        }
    }
    if failures > 0 {
        exit(65)
    }
}

func runHashList(args: [String]) throws {
    var directory: String? = nil
    var output: String? = nil
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--output", "-o":
            guard i + 1 < args.count else {
                throw CLIError.usage("--output requires a path")
            }
            output = args[i + 1]
            i += 2
        default:
            if directory == nil { directory = a } else {
                throw CLIError.usage("unexpected positional arg \(a)")
            }
            i += 1
        }
    }
    guard let dir = directory, let out = output else {
        throw CLIError.usage("hashlist <directory> --output <plist>")
    }
    let dirURL = URL(fileURLWithPath: dir)
    let outURL = URL(fileURLWithPath: out)

    let urls = try yamlURLs(in: dirURL)
    var hashes: [String: String] = [:]
    for url in urls {
        _ = try loadAndValidate(url: url)
        let data = try Data(contentsOf: url)
        hashes[url.lastPathComponent] = DefinitionHash.sha256Hex(data)
    }
    let list = BundleHashList(hashes)
    do {
        try list.write(to: outURL)
    } catch {
        throw CLIError.io("write \(outURL.path): \(error)")
    }
    print("wrote \(urls.count) hash(es) to \(outURL.path)")
}

// MARK: - Helpers

func loadAndValidate(url: URL) throws -> ServiceDefinition {
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        throw CLIError.io("read \(url.path): \(error)")
    }
    guard let source = String(data: data, encoding: .utf8) else {
        throw CLIError.validation(path: url.path, errors: [
            .parse(reason: "file is not valid UTF-8")
        ])
    }
    switch ServiceDefinitionLoader.load(source: source) {
    case .success(let def):
        return def
    case .failure(let errors):
        throw CLIError.validation(path: url.path, errors: errors.errors)
    }
}

func resolveYamlURLs(at path: String) throws -> [URL] {
    let url = URL(fileURLWithPath: path)
    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    if isDir {
        return try yamlURLs(in: url)
    }
    return [url]
}

func yamlURLs(in directory: URL) throws -> [URL] {
    let names: [String]
    do {
        names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    } catch {
        throw CLIError.io("read directory \(directory.path): \(error)")
    }
    return names
        .filter { $0.hasSuffix(".yml") }
        .sorted()
        .map { directory.appendingPathComponent($0) }
}

func printUsage() {
    let usage = """
    usage: steading-definition-validator <command> [args]

    commands:
      validate <path>...
          Parse and schema-validate one or more YAMLs. <path> can be
          a single file or a directory; directories are scanned for
          *.yml files (non-recursive). Exit 0 if every YAML passes,
          65 if any fail.

      hashlist <directory> --output <plist>
          Validate every *.yml in <directory>, compute SHA-256 of
          each file, and write a hash list to <plist>. Steading's
          build phase calls this against the bundled
          ServiceDefinitions/ directory.

      help
          Print this message.
    """
    print(usage)
}
