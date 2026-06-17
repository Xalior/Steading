import Foundation
import Observation
import Darwin
import Security

/// Unix-socket listener that answers password requests from the
/// bundled `steading-askpass` CLI. The service binds a socket inside
/// the user's Application Support dir (0600 perms) at app launch;
/// the helper connects when sudo invokes it.
///
/// Each incoming connection is validated twice: the peer's effective
/// UID must equal ours (defence in depth against another local user),
/// and its code signature must satisfy the askpass helper's pinning
/// requirement. Either failure makes the service send `DENY` and
/// drop the connection without ever presenting a modal.
///
/// On success the service publishes `pendingRequest` so the Brew
/// Package Manager view can surface the password modal. The view
/// calls `respond(password:)` or `respondCancel()` to complete the
/// exchange and release the helper.
@Observable
@MainActor
final class AskpassService {

    struct PendingRequest: Identifiable, Equatable {
        let id: UUID
    }

    /// How long an opt-in password cache survives. Default behaviour
    /// (no caching) is the *absence* of a duration — the modal's
    /// "Remember" checkbox is off, so `respond` is called with
    /// `cache: nil` and nothing is retained.
    enum CacheDuration: String, CaseIterable, Identifiable, Sendable {
        case oneMinute
        case fiveMinutes
        case fifteenMinutes
        case untilQuit

        var id: String { rawValue }

        var label: String {
            switch self {
            case .oneMinute:      return "1 minute"
            case .fiveMinutes:    return "5 minutes"
            case .fifteenMinutes: return "15 minutes"
            case .untilQuit:      return "Until app quits"
            }
        }

        /// Seconds until expiry, or `nil` for `untilQuit` (no time
        /// bound — the RAM cache simply dies when the process exits).
        var timeout: TimeInterval? {
            switch self {
            case .oneMinute:      return 60
            case .fiveMinutes:    return 5 * 60
            case .fifteenMinutes: return 15 * 60
            case .untilQuit:      return nil
            }
        }
    }

    private(set) var pendingRequest: PendingRequest?

    /// True while a candidate password is being validated by the
    /// throwaway `sudo -k -v`. The modal shows a spinner and disables
    /// its controls while this is set.
    private(set) var isValidating = false

    /// Set when the most recent validation rejected the password, so
    /// the re-presented modal can tell the user it was incorrect.
    /// Cleared on the next submit.
    private(set) var lastValidationFailed = false

    /// Non-nil when a security anomaly should be surfaced to the user —
    /// currently, a `validate` request arriving outside the validation
    /// window. The view presents it as an alert and clears it.
    var securityWarning: String?

    private let askpassHelperResolver: @Sendable () -> String?

    init(askpassHelperResolver: @escaping @Sendable () -> String?
         = BrewUpdateManager.defaultAskpassHelperResolver) {
        self.askpassHelperResolver = askpassHelperResolver
    }

    /// Respond to the pending request. With `cache == nil` (the
    /// default) the password is sent once and nothing is retained.
    /// With a `cache` duration the password is first validated by a
    /// throwaway `sudo -k -v` — only a password that genuinely
    /// authenticates is stored, so a typo can never poison the cache.
    func respond(password: String?, cache: CacheDuration? = nil) {
        lastValidationFailed = false
        guard let password else {
            let ch = pendingChannel
            pendingChannel = nil
            pendingRequest = nil
            ch?.sendCancel()
            ch?.close()
            return
        }
        guard let cache else {
            // No caching: send once, retain nothing.
            let ch = pendingChannel
            pendingChannel = nil
            pendingRequest = nil
            ch?.sendPassword(password)
            ch?.close()
            return
        }
        // Caching requested: validate before storing. Keep the pending
        // brew channel held until validation settles.
        beginValidation(candidate: password, cache: cache)
    }

    func respondCancel() { respond(password: nil) }

    /// Drop any cached password immediately (e.g. socket teardown).
    func clearCache() {
        cachedPassword = nil
        cacheExpiry = nil
    }

    // MARK: - Password cache (opt-in, in-RAM, expiring)

    /// The retained password, or nil when nothing is cached.
    private var cachedPassword: String?
    /// Absolute expiry instant; `nil` together with a non-nil
    /// `cachedPassword` means "until app quits" (no time bound).
    private var cacheExpiry: Date?

    /// The cached password if one is present and still valid at `Date()`;
    /// expired entries are cleared as a side effect and return nil.
    private func validCachedPassword() -> String? {
        guard let password = cachedPassword else { return nil }
        guard Self.isCacheValid(expiry: cacheExpiry, now: Date()) else {
            clearCache()
            return nil
        }
        return password
    }

    /// Absolute expiry for a freshly-stored cache entry. `untilQuit`
    /// has no time bound, so it stores `nil`. Pure — exposed for tests.
    nonisolated static func expiry(for duration: CacheDuration, from now: Date) -> Date? {
        guard let timeout = duration.timeout else { return nil }
        return now.addingTimeInterval(timeout)
    }

    /// Whether a cache entry stored with `expiry` is still valid at
    /// `now`. A nil `expiry` (the `untilQuit` policy) never time-expires.
    /// Pure — exposed for tests.
    nonisolated static func isCacheValid(expiry: Date?, now: Date) -> Bool {
        guard let expiry else { return true }
        return now < expiry
    }

    // MARK: - Pre-cache validation

    /// What an incoming request line means, given whether validation is
    /// in progress. Pure — exposed for tests; centralises the security
    /// rule that a `validate` request is legitimate *only* during the
    /// validation window.
    enum RequestAction: Equatable {
        case fetch
        case validate
        case outOfBandValidate
        case deny
    }

    nonisolated static func classify(line: String?, validationActive: Bool) -> RequestAction {
        switch line {
        case SteadingAskpassWire.requestLine:
            return .fetch
        case SteadingAskpassWire.validateRequestLine:
            return validationActive ? .validate : .outOfBandValidate
        default:
            return .deny
        }
    }

    /// The candidate password under validation and the cache policy to
    /// apply if it authenticates. Non-nil only inside the window.
    private var validationCandidate: String?
    private var pendingValidationCache: CacheDuration?

    private var validationActive: Bool { validationCandidate != nil }

    /// Spawn the throwaway `/usr/bin/sudo -k -v` that authenticates the
    /// candidate via the askpass helper (over the socket — never argv),
    /// then store the cache and release the brew request on success, or
    /// re-present the modal on failure.
    private func beginValidation(candidate: String, cache: CacheDuration) {
        validationCandidate = candidate
        pendingValidationCache = cache
        isValidating = true

        Task { [weak self] in
            let ok = await self?.runValidationSudo() ?? false
            self?.finishValidation(success: ok)
        }
    }

    private func runValidationSudo() async -> Bool {
        guard let helper = askpassHelperResolver() else { return false }
        var env = ProcessInfo.processInfo.environment
        env["SUDO_ASKPASS"] = helper
        env[SteadingAskpassWire.validationEnvVar] = "1"
        // Full path for security: never resolve `sudo` via PATH.
        // -k ignores any cached timestamp so the candidate is actually
        // authenticated; -v validates without running a command; -A
        // routes the prompt through our helper.
        let handle = StreamingProcessRunner.run(
            executable: "/usr/bin/sudo",
            arguments: ["-A", "-k", "-v"],
            environment: env
        )
        var exitCode: Int32?
        for await event in handle.events {
            if case .exited(let code) = event { exitCode = code }
        }
        return exitCode == 0
    }

    private func finishValidation(success: Bool) {
        let candidate = validationCandidate
        let cache = pendingValidationCache
        validationCandidate = nil
        pendingValidationCache = nil
        isValidating = false

        if success, let candidate, let cache {
            cachedPassword = candidate
            cacheExpiry = Self.expiry(for: cache, from: Date())
            let ch = pendingChannel
            pendingChannel = nil
            pendingRequest = nil
            ch?.sendPassword(candidate)
            ch?.close()
        } else {
            // Rejected: keep the brew request pending and re-present the
            // modal so the user can retry. Nothing is cached.
            lastValidationFailed = true
            if pendingChannel != nil {
                pendingRequest = PendingRequest(id: UUID())
            }
        }
    }

    /// Surface an out-of-band `validate` request (one arriving while no
    /// validation is in progress) to the user. Logged for audit and
    /// published for the UI to alert on.
    private func reportOutOfBandValidation() {
        NSLog("AskpassService: SECURITY — validate request received outside the validation window; denied")
        securityWarning = "Steading received a password-validation request when it wasn't validating a password. "
            + "The request was denied. If you didn't trigger this, treat it as suspicious."
    }

    func start() {
        guard listeningFD == -1 else { return }
        let path = SteadingAskpassWire.socketPath()
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("AskpassService: socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            NSLog("AskpassService: socket path too long")
            close(fd)
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            ptr.baseAddress!.copyMemory(from: pathBytes, byteCount: pathBytes.count)
        }
        let len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_len = len

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            NSLog("AskpassService: bind() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
        chmod(path, 0o600)

        guard listen(fd, 5) == 0 else {
            NSLog("AskpassService: listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        listeningFD = fd
        // Accept runs on a background queue so a main-actor consumer
        // (test, synchronous SwiftUI binding, etc.) can't starve the
        // listener. The event handler captures `fd` directly — no
        // touching self while on the background queue — and only hops
        // back to the main actor once a validated request is ready.
        let src = DispatchSource.makeReadSource(
            fileDescriptor: fd,
            queue: DispatchQueue(label: "com.xalior.Steading.askpass.accept",
                                 qos: .userInitiated)
        )
        src.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }

            if !Self.validate(peerFD: client) {
                Self.sendLine(fd: client, SteadingAskpassWire.denyLine)
                Darwin.close(client)
                return
            }

            Self.readLine(fd: client) { line in
                Task { @MainActor in
                    self?.handleRequest(fd: client, line: line)
                }
            }
        }
        src.resume()
        acceptSource = src
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listeningFD >= 0 {
            close(listeningFD)
            listeningFD = -1
        }
        unlink(SteadingAskpassWire.socketPath())
        clearCache()
    }

    // MARK: - Internals

    private var listeningFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var pendingChannel: Channel?

    private func handleRequest(fd: Int32, line: String?) {
        switch Self.classify(line: line, validationActive: validationActive) {
        case .deny:
            Self.sendLine(fd: fd, SteadingAskpassWire.denyLine)
            close(fd)

        case .validate:
            // The throwaway validation sudo: answer with the candidate
            // under test. Never touches the cache or the modal.
            let channel = Channel(fd: fd)
            channel.sendPassword(validationCandidate ?? "")
            channel.close()

        case .outOfBandValidate:
            // A validate request with no validation in progress — anomalous.
            Self.sendLine(fd: fd, SteadingAskpassWire.denyLine)
            close(fd)
            reportOutOfBandValidation()

        case .fetch:
            // Cache hit: answer from RAM without surfacing the modal.
            if let cached = validCachedPassword() {
                let channel = Channel(fd: fd)
                channel.sendPassword(cached)
                channel.close()
                return
            }
            if let stale = pendingChannel {
                stale.sendCancel()
                stale.close()
            }
            let channel = Channel(fd: fd)
            pendingChannel = channel
            pendingRequest = PendingRequest(id: UUID())
        }
    }

    // MARK: - Peer validation

    private static func validate(peerFD fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        guard uid == getuid() else { return false }

        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        let rc = withUnsafeMutablePointer(to: &token) { ptr -> Int32 in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { _ in
                getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, ptr, &size)
            }
        }
        guard rc == 0 else { return false }

        let tokenData = withUnsafeBytes(of: token) { Data($0) }
        let attrs: [CFString: Any] = [kSecGuestAttributeAudit: tokenData]
        var secCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &secCode) == errSecSuccess,
              let secCode else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(SteadingAskpassHelperRequirement as CFString,
                                             [], &req) == errSecSuccess, let req else {
            return false
        }
        return SecCodeCheckValidity(secCode, [], req) == errSecSuccess
    }

    // MARK: - Socket I/O helpers

    nonisolated static func sendLine(fd: Int32, _ line: String) {
        let payload = line + "\n"
        payload.withCString { p in
            _ = write(fd, p, strlen(p))
        }
    }

    /// Read one line (LF-terminated) off `fd` in the background; call
    /// `completion` on the main actor with the line (or nil on EOF /
    /// error). Simple implementation: DispatchSource on the fd.
    private static func readLine(fd: Int32, completion: @escaping (String?) -> Void) {
        let queue = DispatchQueue.global(qos: .userInitiated)
        queue.async {
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 256)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                buffer.append(contentsOf: chunk[0..<Int(n)])
                if let idx = buffer.firstIndex(of: 0x0A) {
                    let line = String(data: buffer[..<idx], encoding: .utf8)
                    DispatchQueue.main.async { completion(line) }
                    return
                }
                if buffer.count > 4096 {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
            }
        }
    }

    // MARK: - Channel

    final class Channel: @unchecked Sendable {
        private let fd: Int32
        private var closed = false
        private let lock = NSLock()

        init(fd: Int32) { self.fd = fd }

        func sendPassword(_ password: String) {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            AskpassService.sendLine(fd: fd, SteadingAskpassWire.okLine)
            let payload = password + "\n"
            payload.withCString { p in
                _ = write(fd, p, strlen(p))
            }
        }

        func sendCancel() {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            AskpassService.sendLine(fd: fd, SteadingAskpassWire.cancelLine)
        }

        func close() {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            closed = true
            Darwin.close(fd)
        }
    }
}
