import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum BiometricUnlockError: Error, Equatable, Sendable {
    /// This Mac has no usable biometric hardware, or no fingerprint is
    /// enrolled. The password prompt is the only way in.
    case unavailable
    /// The user dismissed the Touch ID prompt or chose another method. Not a
    /// failure to report as an error; the password prompt simply stays.
    case cancelled
    /// No enrollment exists for this account (never opted in, or revoked).
    case notEnrolled
    /// An enrollment exists but can no longer be used: the enrolled fingerprint
    /// set changed (which destroys the quick-unlock key), or the account's key
    /// material was rotated since it was stored. Both records are deleted and
    /// the password prompt takes over.
    case invalidated
    /// The Keychain refused the operation for another reason.
    case failed(OSStatus)
    /// The Keychain accepted the write but the record could not be read back,
    /// so the enrollment is not usable and was rolled back. Distinct from
    /// `failed` because nothing refused anything — reporting it as a refusal
    /// sends the reader looking in the wrong place.
    case notReadableAfterStore
}

/// The seam the app unlocks through, so tests can exercise enrollment, unlock,
/// revocation, and every failure mode without real biometrics or a real
/// Keychain (hosted CI has neither).
protocol BiometricVaultKeyStoring: Sendable {
    /// Whether this Mac can evaluate a biometric policy right now (hardware
    /// present and a fingerprint enrolled).
    var isBiometryAvailable: Bool { get }

    /// Whether an enrollment exists for this account. Does not prompt.
    func hasKey(for account: AccountID) -> Bool

    /// Enrolls the vault key, bound to the wrapping that key currently has, so
    /// a later rotation invalidates the enrollment.
    func store(userKey: Data, boundTo wrappedUserKey: String, for account: AccountID) throws

    /// Prompts for Touch ID and returns the enrolled vault key. Throws
    /// `.invalidated` when the enrollment no longer matches `wrappedUserKey`.
    func loadUserKey(
        for account: AccountID,
        boundTo wrappedUserKey: String,
        reason: String
    ) async throws -> Data

    /// Invalidates every in-flight authentication context. Lock calls this only
    /// after advancing the session generation, so a prompt cannot release a key
    /// into a newly locked session.
    func cancelAuthentication()

    /// Removes the enrollment. Called on opt-out and on account removal.
    func remove(for account: AccountID) throws
}

/// Quick unlock for one account, built the way ARCHITECTURE.md §"Keychain and
/// biometrics" requires rather than by putting a provider key in the Keychain.
///
/// Enrollment generates a random quick-unlock key `QK`, stores **only** `QK` in
/// a generic-password Keychain item whose release is access controlled, and
/// writes an AEAD-wrapped copy of the vault's user key — sealed under `QK`,
/// authenticating provider, account, and schema version — beside the other
/// at-rest caches. No plaintext key is ever persisted, and the Keychain holds
/// nothing that decrypts anything on its own.
///
/// What is wrapped is deliberately the narrowest useful secret: the user key,
/// never the master password and never the master key. The user key only
/// decrypts vault content; it sits below the master key, cannot re-derive it,
/// and is not an input to the server authentication hash (which needs the
/// master key *and* the raw password), so an enrollment cannot be turned into
/// account access.
///
/// The Keychain read is the authorization: a dedicated `LAContext` carrying the
/// operation prompt is attached to the read itself, so biometry gates the
/// release of `QK`. VaultSquire deliberately does not run a standalone
/// LocalAuthentication prompt first and then perform an unrestricted lookup —
/// that would split authentication from secret release.
struct BiometricVaultKeyStore: BiometricVaultKeyStoring {
    let service: String
    private let directory: URL?
    // FileManager is thread-safe for the operations used here but is not
    // Sendable; vouch for it so the store stays Sendable.
    nonisolated(unsafe) private let fileManager: FileManager

    /// The wrapped copy's layout version, folded into the seal's authenticated
    /// data so a payload sealed under one layout can never open as another.
    private static let schemaVersion = 1
    private static let maximumWrappedKeyBytes = 16 * 1024 * 1024

    init(
        service: String = "ch.lkmc.VaultSquire.quick-unlock-keys",
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.service = service
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            self.directory = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: "group.ch.lkmc.VaultSquire"
            )?.appendingPathComponent("QuickUnlock", isDirectory: true)
        }
    }

    /// The wrapped payload. Sealed under `QK`, so none of it is readable
    /// without a successful biometric release of that key.
    private struct Payload: Codable {
        let version: Int
        let userKey: Data
        /// SHA-256 of the account's wrapped user key at enrollment time.
        let boundTo: String
    }

    /// Holds an `LAContext` — a non-Sendable reference type — so it can be
    /// carried into the Keychain query without tripping Swift 6 strict
    /// concurrency. One box serves one call and is never shared, which is what
    /// makes the unchecked conformance sound.
    private final class AuthenticationBox: @unchecked Sendable {
        let context = LAContext()
    }

    private final class AuthenticationRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var contexts: [UUID: LAContext] = [:]

        func insert(_ context: LAContext) -> UUID {
            lock.lock()
            defer { lock.unlock() }
            let id = UUID()
            contexts[id] = context
            return id
        }

        func remove(_ id: UUID) {
            lock.lock()
            contexts[id] = nil
            lock.unlock()
        }

        func invalidateAll() {
            lock.lock()
            let active = Array(contexts.values)
            contexts.removeAll()
            lock.unlock()
            for context in active { context.invalidate() }
        }
    }

    private static let authenticationRegistry = AuthenticationRegistry()

    var isBiometryAvailable: Bool {
        // A fresh context per query: LAContext caches its evaluation, so a
        // reused one can report a stale answer after the user enrolls a finger.
        var error: NSError?
        return LAContext().canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics, error: &error
        )
    }

    /// Whether this account is enrolled, judged by the sealed copy alone.
    ///
    /// The gated Keychain item is deliberately not probed. An
    /// access-controlled item is filtered out of any search that skips
    /// authentication UI — it reports "not found" even when it is there — and a
    /// probe that does not skip UI risks putting a fingerprint dialog on screen
    /// for a mere existence check. The sealed copy is written and deleted with
    /// the key, so it is the honest marker of "the user opted in". If the key
    /// is later destroyed (the enrolled fingerprints changed), the unlock read
    /// says so and clears both halves, so the state self-heals instead of
    /// lying.
    func hasKey(for account: AccountID) -> Bool {
        guard let directory else { return false }
        return fileManager.fileExists(
            atPath: fileURL(for: account, directory: directory).path
        )
    }


    func store(userKey: Data, boundTo wrappedUserKey: String, for account: AccountID) throws {
        guard let directory else { throw BiometricUnlockError.failed(errSecNotAvailable) }
        guard isBiometryAvailable else { throw BiometricUnlockError.unavailable }
        guard userKey.count == 64,
              wrappedUserKey.utf8.count <= Self.maximumWrappedKeyBytes else {
            throw BiometricUnlockError.failed(errSecParam)
        }

        var controlError: Unmanaged<CFError>?
        // The protection class is supplied to this call and carried by the
        // resulting object; the item must not also set kSecAttrAccessible.
        guard let control = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &controlError
        ) else {
            controlError?.release()
            throw BiometricUnlockError.unavailable
        }

        let quickUnlockKey = SymmetricKey(size: .bits256)
        let payload = Payload(
            version: Self.schemaVersion,
            userKey: userKey,
            boundTo: Self.digest(of: wrappedUserKey)
        )
        guard var encoded = try? JSONEncoder().encode(payload) else {
            throw BiometricUnlockError.failed(errSecParam)
        }
        defer { encoded.resetBytes(in: encoded.startIndex..<encoded.endIndex) }
        guard let sealed = try? CacheEnvelopeCipher.seal(
            encoded,
            key: quickUnlockKey,
            context: CacheEnvelopeContext(account: account, schemaVersion: Self.schemaVersion)
        ) else {
            throw BiometricUnlockError.failed(errSecParam)
        }

        // Replace any previous enrollment: re-enrolling must not leave two
        // differently controlled records. Failure to remove the old record is
        // a hard failure, not permission to downgrade to another Keychain.
        try remove(for: account)

        var keyBytes = quickUnlockKey.withUnsafeBytes { Data($0) }
        defer { keyBytes.resetBytes(in: keyBytes.startIndex..<keyBytes.endIndex) }
        let status = addQuickUnlockKey(
            keyBytes,
            accessControl: control,
            for: account
        )
        guard status == errSecSuccess else {
            throw BiometricUnlockError.failed(status)
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.write(sealed, to: fileURL(for: account, directory: directory))
        } catch {
            // Never leave a gated key with nothing to open: roll the whole
            // enrollment back so the state stays consistent.
            try? remove(for: account)
            throw BiometricUnlockError.failed(errSecIO)
        }

        // Both halves are now in place: the Keychain accepted the key and the
        // sealed copy is on disk. Reading the key back to prove it would cost a
        // fingerprint prompt during enrollment, and an access-controlled item
        // cannot be probed without one, so success is reported on the write.
        // A key that turns out to be unusable surfaces on the first unlock,
        // which clears the enrollment rather than failing silently.
        guard hasKey(for: account) else {
            try? remove(for: account)
            throw BiometricUnlockError.notReadableAfterStore
        }
    }

    func loadUserKey(
        for account: AccountID,
        boundTo wrappedUserKey: String,
        reason: String
    ) async throws -> Data {
        guard let directory else { throw BiometricUnlockError.failed(errSecNotAvailable) }
        guard hasKey(for: account) else { throw BiometricUnlockError.notEnrolled }
        guard wrappedUserKey.utf8.count <= Self.maximumWrappedKeyBytes,
              !reason.isEmpty,
              reason.utf8.count <= 1_024,
              reason.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw BiometricUnlockError.failed(errSecParam)
        }
        try Task.checkCancellation()

        let box = AuthenticationBox()
        let authenticationID = Self.authenticationRegistry.insert(box.context)
        defer { Self.authenticationRegistry.remove(authenticationID) }
        // The prompt belongs to the read itself, so biometry gates the release
        // of the quick-unlock key rather than merely preceding it.
        box.context.localizedReason = reason

        var result: CFTypeRef?
        var query = baseQuery(for: account)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext] = box.context
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // Lock cancels the owning task before invalidating this context. Check
        // that signal before classifying the resulting OSStatus, because an
        // invalidated prompt may surface as auth-failed without any biometric
        // enrollment change and must not delete a valid record.
        try Task.checkCancellation()

        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            // The sealed copy outlived the key that opens it; it is now inert,
            // so drop it rather than leaving Touch ID permanently offered.
            try? remove(for: account)
            throw BiometricUnlockError.notEnrolled
        case errSecUserCanceled:
            throw BiometricUnlockError.cancelled
        case errSecAuthFailed:
            // A changed biometric set destroys a `biometryCurrentSet` item.
            try? remove(for: account)
            throw BiometricUnlockError.invalidated
        case errSecInteractionNotAllowed:
            // Background/session state can temporarily prohibit UI. Do not
            // destroy a valid enrollment for an environmental failure.
            throw BiometricUnlockError.failed(status)
        default:
            throw BiometricUnlockError.failed(status)
        }

        try Task.checkCancellation()
        guard var keyBytes = result as? Data, keyBytes.count == 32 else {
            try? remove(for: account)
            throw BiometricUnlockError.invalidated
        }
        let quickUnlockKey = SymmetricKey(data: keyBytes)
        keyBytes.resetBytes(in: keyBytes.startIndex..<keyBytes.endIndex)

        let file = fileURL(for: account, directory: directory)
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue > 0,
              fileSize.intValue <= 16 * 1024,
              let sealed = try? Data(contentsOf: file),
              var opened = try? CacheEnvelopeCipher.open(
                  sealed,
                  key: quickUnlockKey,
                  context: CacheEnvelopeContext(account: account, schemaVersion: Self.schemaVersion)
              ) else {
            try? remove(for: account)
            throw BiometricUnlockError.invalidated
        }
        defer { opened.resetBytes(in: opened.startIndex..<opened.endIndex) }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: opened),
              payload.version == Self.schemaVersion,
              payload.userKey.count == 64 else {
            try? remove(for: account)
            throw BiometricUnlockError.invalidated
        }
        // The account's key material rotated since enrollment: this key would
        // decrypt nothing, so drop it and fall back to the password.
        guard payload.boundTo == Self.digest(of: wrappedUserKey) else {
            try? remove(for: account)
            throw BiometricUnlockError.invalidated
        }
        try Task.checkCancellation()
        return payload.userKey
    }

    func cancelAuthentication() {
        Self.authenticationRegistry.invalidateAll()
    }

    func remove(for account: AccountID) throws {
        var firstFailure: OSStatus?

        // Destroy the sealed half first. If Keychain deletion is then refused,
        // the surviving key has nothing to open and cannot re-enable Touch ID
        // after a restart.
        if let directory {
            let url = fileURL(for: account, directory: directory)
            if fileManager.fileExists(atPath: url.path) {
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    firstFailure = errSecIO
                }
            }
        }

        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            firstFailure = firstFailure ?? status
        }
        // Cleanup-only migration for records written by the old fallback. No
        // read or write path ever uses this legacy query.
        let legacyStatus = SecItemDelete(legacyQuery(for: account) as CFDictionary)
        if legacyStatus != errSecSuccess && legacyStatus != errSecItemNotFound {
            firstFailure = firstFailure ?? legacyStatus
        }
        if let firstFailure {
            throw BiometricUnlockError.failed(firstFailure)
        }
    }

    // MARK: - Private

    private func addQuickUnlockKey(
        _ keyBytes: Data,
        accessControl: SecAccessControl,
        for account: AccountID
    ) -> OSStatus {
        var query = baseQuery(for: account)
        query[kSecValueData] = keyBytes
        query[kSecAttrAccessControl] = accessControl
        return SecItemAdd(query as CFDictionary, nil)
    }

    /// Prefer complete file protection, falling back to a plain atomic write
    /// when an unentitled build rejects the data-protection option. The payload
    /// is already sealed under a key this file does not contain.
    private static func write(_ sealed: Data, to url: URL) throws {
        do {
            try sealed.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            try sealed.write(to: url, options: [.atomic])
        }
    }

    /// Hex SHA-256, used to bind an enrollment to the account's current wrapped
    /// user key without storing that value itself.
    static func digest(of value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(for account: AccountID, directory: URL) -> URL {
        let material = "\(account.provider.rawValue)|\(account.rawValue)"
        let name = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).quickunlock", isDirectory: false)
    }

    private func baseQuery(for account: AccountID) -> [CFString: Any] {
        var query = legacyQuery(for: account)
        query[kSecUseDataProtectionKeychain] = kCFBooleanTrue
        return query
    }

    private func legacyQuery(for account: AccountID) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "\(account.provider.rawValue)|\(account.rawValue)",
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
    }
}
