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
    private let directory: URL
    // FileManager is thread-safe for the operations used here but is not
    // Sendable; vouch for it so the store stays Sendable.
    nonisolated(unsafe) private let fileManager: FileManager

    /// The wrapped copy's layout version, folded into the seal's authenticated
    /// data so a payload sealed under one layout can never open as another.
    private static let schemaVersion = 1

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
            let base = (try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )) ?? fileManager.temporaryDirectory
            self.directory = base
                .appendingPathComponent("VaultSquire", isDirectory: true)
                .appendingPathComponent("QuickUnlock", isDirectory: true)
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

    var isBiometryAvailable: Bool {
        // A fresh context per query: LAContext caches its evaluation, so a
        // reused one can report a stale answer after the user enrolls a finger.
        var error: NSError?
        return LAContext().canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics, error: &error
        )
    }

    func hasKey(for account: AccountID) -> Bool {
        // Both halves must exist: the gated key and the wrapped copy it opens.
        keychainItemExists(for: account)
            && fileManager.fileExists(atPath: fileURL(for: account).path)
    }

    func store(userKey: Data, boundTo wrappedUserKey: String, for account: AccountID) throws {
        guard isBiometryAvailable else { throw BiometricUnlockError.unavailable }

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
        guard let encoded = try? JSONEncoder().encode(payload),
              let sealed = try? CacheEnvelopeCipher.seal(
                  encoded,
                  key: quickUnlockKey,
                  context: CacheEnvelopeContext(account: account, schemaVersion: Self.schemaVersion)
              ) else {
            throw BiometricUnlockError.failed(errSecParam)
        }

        // Replace any previous enrollment: re-enrolling must not fail on a
        // duplicate, and an old key must not linger behind a stale control.
        try? remove(for: account)

        var query = baseQuery(for: account)
        query[kSecValueData] = quickUnlockKey.withUnsafeBytes { Data($0) }
        query[kSecAttrAccessControl] = control
        query[kSecAttrSynchronizable] = kCFBooleanFalse
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BiometricUnlockError.failed(status)
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.write(sealed, to: fileURL(for: account))
        } catch {
            // Never leave a gated key with nothing to open: roll the whole
            // enrollment back so the state stays consistent.
            try? remove(for: account)
            throw BiometricUnlockError.failed(errSecIO)
        }
    }

    func loadUserKey(
        for account: AccountID,
        boundTo wrappedUserKey: String,
        reason: String
    ) async throws -> Data {
        guard hasKey(for: account) else { throw BiometricUnlockError.notEnrolled }

        let box = AuthenticationBox()
        // The prompt belongs to the read itself, so biometry gates the release
        // of the quick-unlock key rather than merely preceding it.
        box.context.localizedReason = reason

        var query = baseQuery(for: account)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext] = box.context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw BiometricUnlockError.notEnrolled
        case errSecUserCanceled:
            throw BiometricUnlockError.cancelled
        case errSecAuthFailed, errSecInteractionNotAllowed:
            // The gated key no longer opens under the current biometric set.
            try? remove(for: account)
            throw BiometricUnlockError.invalidated
        default:
            throw BiometricUnlockError.failed(status)
        }

        guard let keyBytes = result as? Data, keyBytes.count == 32 else {
            try? remove(for: account)
            throw BiometricUnlockError.invalidated
        }
        let quickUnlockKey = SymmetricKey(data: keyBytes)

        guard let sealed = try? Data(contentsOf: fileURL(for: account)),
              let opened = try? CacheEnvelopeCipher.open(
                  sealed,
                  key: quickUnlockKey,
                  context: CacheEnvelopeContext(account: account, schemaVersion: Self.schemaVersion)
              ),
              let payload = try? JSONDecoder().decode(Payload.self, from: opened),
              payload.version == Self.schemaVersion else {
            try? remove(for: account)
            throw BiometricUnlockError.invalidated
        }
        // The account's key material rotated since enrollment: this key would
        // decrypt nothing, so drop it and fall back to the password.
        guard payload.boundTo == Self.digest(of: wrappedUserKey) else {
            try? remove(for: account)
            throw BiometricUnlockError.invalidated
        }
        return payload.userKey
    }

    func remove(for account: AccountID) throws {
        let url = fileURL(for: account)
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw BiometricUnlockError.failed(status)
        }
    }

    // MARK: - Private

    /// Whether the gated Keychain record exists, without prompting: an
    /// existence check must never put a fingerprint dialog on screen.
    private func keychainItemExists(for account: AccountID) -> Bool {
        var query = baseQuery(for: account)
        query[kSecReturnData] = kCFBooleanFalse
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI] = kSecUseAuthenticationUISkip
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // A gated item reports "interaction not allowed" precisely because it
        // exists and would have prompted.
        return status == errSecSuccess || status == errSecInteractionNotAllowed
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

    private func fileURL(for account: AccountID) -> URL {
        let material = "\(account.provider.rawValue)|\(account.rawValue)"
        let name = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).quickunlock", isDirectory: false)
    }

    private func baseQuery(for account: AccountID) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain: kCFBooleanTrue as Any,
            kSecAttrService: service,
            kSecAttrAccount: "\(account.provider.rawValue)|\(account.rawValue)",
        ]
    }
}
