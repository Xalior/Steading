import Testing
@testable import Steading

/// Pure tests for `ServiceDefinitionLoader`. Every test feeds canned
/// YAML to the *real* loader (the same code path the build-phase
/// validator and runtime loader use); no parallel reimplementation,
/// no mocking. Per CLAUDE.md hard rule.
///
/// The fixtures are inline strings rather than files-on-disk: the
/// loader takes `String`, so passing a literal exercises the same
/// production path as the build-phase script reading from disk.
@Suite("ServiceDefinitionLoader")
struct ServiceDefinitionLoaderTests {

    // MARK: - Valid fixtures

    @Test("Valid minimal definition decodes")
    func validMinimal() throws {
        let yaml = """
        schemaVersion: 1
        serviceID: example
        displayName: Example
        summary: An example service.
        brewFormula: steading-example
        upstreamFormula: example
        systemUser:
          name: _example
        launchDaemon:
          label: com.xalior.steading.example
          plist:
            Label: com.xalior.steading.example
            RunAtLoad: true
        writeTargets: []
        panes:
          - id: welcome
            title: Welcome
        """

        let result = ServiceDefinitionLoader.load(source: yaml)
        guard case .success(let def) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(def.serviceID == "example")
        #expect(def.brewFormula == "steading-example")
        #expect(def.systemUser.name == "_example")
        #expect(def.launchDaemon.label == "com.xalior.steading.example")
    }

    @Test("Valid full definition with fields, write targets, preflight, warnings")
    func validFull() throws {
        let yaml = """
        schemaVersion: 1
        serviceID: example
        displayName: Example
        summary: An example service.
        brewFormula: steading-example
        upstreamFormula: example
        systemUser:
          name: _example
          home: /var/empty
        launchDaemon:
          label: com.xalior.steading.example
          plist:
            Label: com.xalior.steading.example
            RunAtLoad: true
            ProgramArguments:
              - /opt/homebrew/bin/example
              - --foreground
        writeTargets:
          - id: config
            kind: literal
            path: /opt/homebrew/etc/example.conf
            mode: 420
            ownerUID: 0
            groupGID: 0
            sizeCapBytes: 65536
          - id: data_dir
            kind: directory
            path: /opt/steading/example/data
            mode: 448
        panes:
          - id: welcome
            title: Welcome
            help: Hello.
          - id: pre
            title: Preflight
            preflightChecks:
              - kind: portFree
                port: 4242
              - kind: pathAbsent
                path: /opt/homebrew/etc/example.conf
          - id: settings
            title: Settings
            fields:
              - id: bindAddress
                kind: text
                label: Bind address
                default: 127.0.0.1
                validation:
                  regex: "^[0-9.]+$"
                warnings:
                  - id: publicExposure
                    predicate:
                      kind: notEqual
                      value: 127.0.0.1
                    message: Public exposure warning.
              - id: rootPassword
                kind: secret
                label: Root password
                keychainAccount: example.root
                validation:
                  minLength: 8
        """

        let result = ServiceDefinitionLoader.load(source: yaml)
        guard case .success(let def) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(def.writeTargets.count == 2)
        #expect(def.panes.count == 3)
        let preflightPane = def.panes[1]
        #expect(preflightPane.preflightChecks?.count == 2)
        let settingsPane = def.panes[2]
        let secret = settingsPane.fields?.first(where: { $0.id == "rootPassword" })
        #expect(secret?.keychainAccount == "example.root")
    }

    // MARK: - Strictness rejections

    @Test("Anchors are rejected")
    func rejectsAnchors() {
        let yaml = """
        schemaVersion: 1
        serviceID: example
        displayName: &name Example
        summary: An example.
        brewFormula: steading-example
        upstreamFormula: example
        systemUser:
          name: _example
        launchDaemon:
          label: com.xalior.steading.example
          plist:
            Label: *name
        writeTargets: []
        panes:
          - id: welcome
            title: Welcome
        """
        let result = ServiceDefinitionLoader.load(source: yaml)
        guard case .failure(let errors) = result else {
            Issue.record("expected failure, got \(result)"); return
        }
        let matched = errors.errors.contains(where: {
            if case .parse(let r) = $0 { return r.contains("anchors") } else { return false }
        })
        if !matched {
            Issue.record("expected anchors-rejected parse error; got \(errors.errors)")
        }
    }

    @Test("Custom tags are rejected")
    func rejectsCustomTags() {
        let yaml = """
        schemaVersion: 1
        serviceID: example
        displayName: Example
        summary: !!python/object Whatever
        brewFormula: steading-example
        upstreamFormula: example
        systemUser:
          name: _example
        launchDaemon:
          label: com.xalior.steading.example
          plist: {}
        writeTargets: []
        panes:
          - id: welcome
            title: Welcome
        """
        let result = ServiceDefinitionLoader.load(source: yaml)
        guard case .failure(let errors) = result else {
            Issue.record("expected failure, got \(result)"); return
        }
        #expect(errors.errors.contains(where: {
            if case .parse(let r) = $0 { return r.contains("explicit tag") } else { return false }
        }))
    }

    // MARK: - Schema-invariant rejections

    @Test("Wrong schemaVersion is rejected")
    func rejectsWrongSchemaVersion() {
        let yaml = baseYaml(serviceID: "example").replacingOccurrences(
            of: "schemaVersion: 1",
            with: "schemaVersion: 2"
        )
        let result = ServiceDefinitionLoader.load(source: yaml)
        guard case .failure(let errors) = result else {
            Issue.record("expected failure"); return
        }
        #expect(errors.errors.contains(where: {
            if case .invariant(let f, _) = $0 { return f == "schemaVersion" } else { return false }
        }))
    }

    @Test("Invalid serviceID is rejected")
    func rejectsBadServiceID() {
        let yaml = baseYaml(serviceID: "BadID")
        let result = ServiceDefinitionLoader.load(source: yaml)
        guard case .failure(let errors) = result else {
            Issue.record("expected failure"); return
        }
        #expect(errors.errors.contains(where: {
            if case .invariant(let f, _) = $0 { return f == "serviceID" } else { return false }
        }))
    }

    @Test("Mismatched systemUser name is rejected")
    func rejectsMismatchedSystemUser() {
        let yaml = """
        schemaVersion: 1
        serviceID: example
        displayName: Example
        summary: x
        brewFormula: steading-example
        upstreamFormula: example
        systemUser:
          name: _wrong
        launchDaemon:
          label: com.xalior.steading.example
          plist: {}
        writeTargets: []
        panes:
          - id: welcome
            title: Welcome
        """
        let result = ServiceDefinitionLoader.load(source: yaml)
        guard case .failure(let errors) = result else {
            Issue.record("expected failure"); return
        }
        #expect(errors.errors.contains(where: {
            if case .invariant(let f, _) = $0 { return f == "systemUser.name" } else { return false }
        }))
    }

    @Test("Wrong brew wrapper is rejected")
    func rejectsWrongBrewFormula() {
        let yaml = """
        schemaVersion: 1
        serviceID: example
        displayName: Example
        summary: x
        brewFormula: example
        upstreamFormula: example
        systemUser:
          name: _example
        launchDaemon:
          label: com.xalior.steading.example
          plist: {}
        writeTargets: []
        panes:
          - id: welcome
            title: Welcome
        """
        let result = ServiceDefinitionLoader.load(source: yaml)
        guard case .failure(let errors) = result else {
            Issue.record("expected failure"); return
        }
        #expect(errors.errors.contains(where: {
            if case .invariant(let f, _) = $0 { return f == "brewFormula" } else { return false }
        }))
    }

    @Test("Secret field without keychainAccount is rejected")
    func rejectsSecretWithoutKeychain() {
        let yaml = """
        schemaVersion: 1
        serviceID: example
        displayName: Example
        summary: x
        brewFormula: steading-example
        upstreamFormula: example
        systemUser:
          name: _example
        launchDaemon:
          label: com.xalior.steading.example
          plist: {}
        writeTargets: []
        panes:
          - id: settings
            title: Settings
            fields:
              - id: rootPassword
                kind: secret
                label: pw
        """
        let result = ServiceDefinitionLoader.load(source: yaml)
        guard case .failure(let errors) = result else {
            Issue.record("expected failure"); return
        }
        #expect(errors.errors.contains(where: {
            if case .invariant(let f, _) = $0 { return f.contains("keychainAccount") } else { return false }
        }))
    }

    @Test("Field referencing unknown writeTarget is rejected")
    func rejectsUnknownWriteTargetReference() {
        let yaml = """
        schemaVersion: 1
        serviceID: example
        displayName: Example
        summary: x
        brewFormula: steading-example
        upstreamFormula: example
        systemUser:
          name: _example
        launchDaemon:
          label: com.xalior.steading.example
          plist: {}
        writeTargets: []
        panes:
          - id: settings
            title: Settings
            fields:
              - id: dataDir
                kind: path
                label: Data dir
                writeTarget: nonexistent
        """
        let result = ServiceDefinitionLoader.load(source: yaml)
        guard case .failure(let errors) = result else {
            Issue.record("expected failure"); return
        }
        #expect(errors.errors.contains(where: {
            if case .invariant(let f, _) = $0 { return f.contains("writeTarget") } else { return false }
        }))
    }

    @Test("Template writeTarget without placeholder is rejected")
    func rejectsTemplateWithoutPlaceholder() {
        let yaml = """
        schemaVersion: 1
        serviceID: example
        displayName: Example
        summary: x
        brewFormula: steading-example
        upstreamFormula: example
        systemUser:
          name: _example
        launchDaemon:
          label: com.xalior.steading.example
          plist: {}
        writeTargets:
          - id: vhost
            kind: template
            path: /etc/example/static.conf
            mode: 420
            placeholders:
              hostname:
                regex: "^[a-z]+$"
        panes:
          - id: welcome
            title: Welcome
        """
        let result = ServiceDefinitionLoader.load(source: yaml)
        guard case .failure(let errors) = result else {
            Issue.record("expected failure"); return
        }
        #expect(errors.errors.contains(where: {
            if case .invariant(let f, _) = $0 { return f.contains("path") } else { return false }
        }))
    }

    @Test("Oversize source is rejected without parsing")
    func rejectsOversize() {
        let huge = String(repeating: "x", count: ServiceDefinitionMaxSize + 1)
        let result = ServiceDefinitionLoader.load(source: huge)
        guard case .failure(let errors) = result else {
            Issue.record("expected failure"); return
        }
        #expect(errors.errors.contains(where: {
            if case .oversize = $0 { return true } else { return false }
        }))
    }

    @Test("Empty document is rejected")
    func rejectsEmpty() {
        let result = ServiceDefinitionLoader.load(source: "")
        guard case .failure = result else {
            Issue.record("expected failure"); return
        }
    }

    // MARK: - Pure helpers

    @Test("Service-id pattern accepts valid forms")
    func validServiceIDs() {
        #expect(ServiceDefinitionLoader.isValidServiceID("mysql"))
        #expect(ServiceDefinitionLoader.isValidServiceID("php-fpm"))
        #expect(ServiceDefinitionLoader.isValidServiceID("a1"))
    }

    @Test("Service-id pattern rejects invalid forms")
    func invalidServiceIDs() {
        #expect(!ServiceDefinitionLoader.isValidServiceID(""))
        #expect(!ServiceDefinitionLoader.isValidServiceID("M"))
        #expect(!ServiceDefinitionLoader.isValidServiceID("BadID"))
        #expect(!ServiceDefinitionLoader.isValidServiceID("9starts-with-digit"))
        #expect(!ServiceDefinitionLoader.isValidServiceID("with_underscore"))
        #expect(!ServiceDefinitionLoader.isValidServiceID(String(repeating: "a", count: 32)))
    }

    @Test("Template placeholder extraction")
    func placeholderExtraction() {
        #expect(ServiceDefinitionLoader.templatePlaceholderNames(in: "/etc/{a}/{b}.conf") == ["a", "b"])
        #expect(ServiceDefinitionLoader.templatePlaceholderNames(in: "/etc/static.conf") == [])
    }

    // MARK: - Helpers

    private func baseYaml(serviceID: String) -> String {
        return """
        schemaVersion: 1
        serviceID: \(serviceID)
        displayName: Example
        summary: x
        brewFormula: steading-\(serviceID)
        upstreamFormula: \(serviceID)
        systemUser:
          name: _\(serviceID)
        launchDaemon:
          label: com.xalior.steading.\(serviceID)
          plist: {}
        writeTargets: []
        panes:
          - id: welcome
            title: Welcome
        """
    }
}
