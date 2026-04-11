import Foundation
import Security
import os.log

/// Accepts XPC connections from the main Steading app and installs
/// a `PrivHelperService` as the exported object. Before accepting,
/// verifies the connecting process's code signature against a
/// designated requirement so only Steading itself can talk to us.
final class PrivHelperListenerDelegate: NSObject, NSXPCListenerDelegate {

    private let log = Logger(subsystem: "com.xalior.Steading.privhelper", category: "listener")

    /// Code-signing designated requirement that clients must satisfy.
    /// Pinned to Steading's bundle identifier and Apple development/
    /// distribution identity (team M353B943AK).
    ///
    /// This is the entire security story of the helper: if an attacker
    /// can satisfy this requirement, they already have code running
    /// signed by us, and we have bigger problems.
    private let clientRequirement =
        "identifier \"com.xalior.Steading\" and anchor apple generic and " +
        "certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */ and " +
        "certificate leaf[subject.OU] = \"M353B943AK\""

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard verifyClient(newConnection) else {
            log.error("rejecting XPC connection: client code-sign check failed")
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: SteadingPrivHelperProtocol.self)
        newConnection.exportedObject = PrivHelperService()
        newConnection.resume()
        log.info("accepted XPC connection from verified client")
        return true
    }

    // MARK: - Client verification

    private func verifyClient(_ connection: NSXPCConnection) -> Bool {
        // Grab the audit token for the connecting process.
        let token = connection.auditToken
        var tokenCopy = token
        let attributes: [String: Any] = [
            kSecGuestAttributeAudit as String: Data(
                bytes: &tokenCopy,
                count: MemoryLayout.size(ofValue: tokenCopy)
            )
        ]

        var code: SecCode?
        let copyStatus = SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code)
        guard copyStatus == errSecSuccess, let code else {
            log.error("SecCodeCopyGuestWithAttributes failed: \(copyStatus)")
            return false
        }

        var requirement: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(
            clientRequirement as CFString, [], &requirement
        )
        guard reqStatus == errSecSuccess, let requirement else {
            log.error("SecRequirementCreateWithString failed: \(reqStatus)")
            return false
        }

        let checkStatus = SecCodeCheckValidity(code, [], requirement)
        if checkStatus != errSecSuccess {
            log.error("SecCodeCheckValidity failed: \(checkStatus)")
            return false
        }
        return true
    }
}

// MARK: - NSXPCConnection.auditToken

extension NSXPCConnection {
    /// Expose the connecting client's audit token. `NSXPCConnection`
    /// has this as a public API (added in macOS 10.15) but it's not
    /// surfaced in the ObjC header — we grab it by KVC.
    var auditToken: audit_token_t {
        var token = audit_token_t()
        withUnsafeMutableBytes(of: &token) { buffer in
            guard let value = self.value(forKey: "auditToken") as? NSValue else { return }
            let tokenSize = MemoryLayout<audit_token_t>.size
            value.getValue(buffer.baseAddress!, size: tokenSize)
        }
        return token
    }
}
