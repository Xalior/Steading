import Testing
import Foundation
@testable import Steading

/// Pure tests for `BundleDefinitionVerifier` and friends. Every test
/// stages real YAML files under a temp directory, hits the real
/// hashing + partition logic, and asserts on the partition.
@Suite("BundleDefinitionVerifier")
struct BundleDefinitionVerifierTests {

    @Test("Matched / mismatched / unrecorded / missing partition arms")
    func partitionsCorrectly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mysqlSource = "schemaVersion: 1\nserviceID: mysql\n"
        let caddySource = "schemaVersion: 1\nserviceID: caddy\n"
        let redisSource = "schemaVersion: 1\nserviceID: redis\n"
        try mysqlSource.write(to: dir.appendingPathComponent("mysql.yml"), atomically: true, encoding: .utf8)
        try caddySource.write(to: dir.appendingPathComponent("caddy.yml"), atomically: true, encoding: .utf8)
        try redisSource.write(to: dir.appendingPathComponent("redis.yml"), atomically: true, encoding: .utf8)

        // Hash list:
        //   mysql — recorded with the correct hash → matched
        //   caddy — recorded with a wrong hash      → mismatched
        //   stalwart — recorded but not on disk     → missing
        // redis is NOT recorded → unrecorded
        let hashes = BundleHashList([
            "mysql.yml": DefinitionHash.sha256Hex(of: mysqlSource),
            "caddy.yml": "deadbeef",
            "stalwart.yml": "0000",
        ])
        let partition = try BundleDefinitionVerifier.verify(directory: dir, hashList: hashes)

        #expect(partition.matched == ["mysql.yml"])
        #expect(partition.mismatched == ["caddy.yml"])
        #expect(partition.unrecorded == ["redis.yml"])
        #expect(partition.missing == ["stalwart.yml"])
    }

    @Test("Hash list round-trip via plist")
    func hashListRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(".bundle-hashes.plist")

        let original = BundleHashList([
            "mysql.yml": DefinitionHash.sha256Hex(of: "yaml-a"),
            "caddy.yml": DefinitionHash.sha256Hex(of: "yaml-b"),
        ])
        try original.write(to: url)
        let read = try BundleHashList.read(from: url)
        #expect(read == original)
    }

    @Test("Hash determinism: same content yields the same hash")
    func hashDeterminism() {
        let a = DefinitionHash.sha256Hex(of: "schemaVersion: 1\n")
        let b = DefinitionHash.sha256Hex(of: "schemaVersion: 1\n")
        #expect(a == b)
        #expect(a.count == 64)
    }

    @Test("Missing directory: every recorded file shows as missing")
    func missingDirectory() throws {
        let dir = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let hashes = BundleHashList(["mysql.yml": "abc"])
        let partition = try BundleDefinitionVerifier.verify(directory: dir, hashList: hashes)
        #expect(partition.matched.isEmpty)
        #expect(partition.mismatched.isEmpty)
        #expect(partition.unrecorded.isEmpty)
        #expect(partition.missing == ["mysql.yml"])
    }

    @Test("Empty hash list with files on disk: every file unrecorded")
    func emptyHashList() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: dir.appendingPathComponent("a.yml"), atomically: true, encoding: .utf8)
        try "y".write(to: dir.appendingPathComponent("b.yml"), atomically: true, encoding: .utf8)
        let partition = try BundleDefinitionVerifier.verify(directory: dir, hashList: BundleHashList())
        #expect(partition.unrecorded == ["a.yml", "b.yml"])
    }

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("steading-bvtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite("ExternalDefinitionScanner")
struct ExternalDefinitionScannerTests {

    @Test("Returns one Entry per yml file with hash and source")
    func scansAndHashes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let aSrc = "schemaVersion: 1\nserviceID: a\n"
        let bSrc = "schemaVersion: 1\nserviceID: b\n"
        try aSrc.write(to: dir.appendingPathComponent("a.yml"), atomically: true, encoding: .utf8)
        try bSrc.write(to: dir.appendingPathComponent("b.yml"), atomically: true, encoding: .utf8)
        // A non-yml file is ignored.
        try "ignore me".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let entries = try ExternalDefinitionScanner.scan(directory: dir)
        #expect(entries.count == 2)
        #expect(entries[0].source == aSrc)
        #expect(entries[0].hash == DefinitionHash.sha256Hex(of: aSrc))
        #expect(entries[1].source == bSrc)
        #expect(entries[1].hash == DefinitionHash.sha256Hex(of: bSrc))
    }

    @Test("Missing directory yields empty list")
    func missingDir() throws {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let entries = try ExternalDefinitionScanner.scan(directory: url)
        #expect(entries.isEmpty)
    }

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("steading-edstest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
