import Foundation
import Security

/// Wraps Authorization Services for the consent-gate admin
/// challenge. Calling `challenge(rightName:prompt:)` triggers the
/// system's admin-password / Touch ID dialog; success means the
/// user just physically authorised this exact action, even if the
/// main-app process were compromised at runtime.
public enum AdminAuthorization {

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case createFailed(OSStatus)
        case denied(OSStatus)
        public var description: String {
            switch self {
            case .createFailed(let s): return "AuthorizationCreate failed: \(s)"
            case .denied(let s): return "AuthorizationCopyRights denied: \(s)"
            }
        }
    }

    /// Challenge the user for admin credentials against `rightName`.
    /// Throws on user denial / cancel.
    ///
    /// `rightName` defaults to a Steading-specific right
    /// (`com.xalior.Steading.approveDefinition`); the system creates
    /// an `authenticate-admin`-policy default rule the first time an
    /// unknown right is evaluated, so no plist registration is
    /// required.
    public static func challenge(
        rightName: String = "com.xalior.Steading.approveDefinition",
        prompt: String
    ) throws {
        var authRef: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authRef)
        guard createStatus == errAuthorizationSuccess, let authRef else {
            throw Error.createFailed(createStatus)
        }
        defer { AuthorizationFree(authRef, [.destroyRights]) }

        return try rightName.withCString { rightCStr in
            try prompt.withCString { promptCStr in
                let nameMutable = UnsafeMutablePointer(mutating: rightCStr)
                var rightItem = AuthorizationItem(
                    name: nameMutable,
                    valueLength: 0,
                    value: nil,
                    flags: 0
                )
                var rights = withUnsafeMutablePointer(to: &rightItem) { itemPtr in
                    AuthorizationRights(count: 1, items: itemPtr)
                }
                let promptMutable = UnsafeMutablePointer(mutating: promptCStr)
                var envItem = AuthorizationItem(
                    name: kAuthorizationEnvironmentPrompt,
                    valueLength: prompt.utf8.count,
                    value: UnsafeMutableRawPointer(promptMutable),
                    flags: 0
                )
                var environment = withUnsafeMutablePointer(to: &envItem) { itemPtr in
                    AuthorizationEnvironment(count: 1, items: itemPtr)
                }
                let flags: AuthorizationFlags = [.interactionAllowed, .extendRights]
                let status = AuthorizationCopyRights(authRef, &rights, &environment, flags, nil)
                if status != errAuthorizationSuccess {
                    throw Error.denied(status)
                }
            }
        }
    }
}
