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
    /// No key is stored for this account (the user never opted in, or it was
    /// revoked).
    case notEnrolled
    /// A stored key exists but can no longer be used: the enrolled fingerprint
    /// set changed, or the account's key material was rotated since it was
    /// stored. The stale entry is deleted and the password prompt takes over.
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

    /// Whether a key is stored for this account. Does not prompt.
    func hasKey(for account: AccountID) -> Bool

    /// Stores the vault key behind biometry, bound to the wrapping this key
    /// currently has on the server, so a later key rotation invalidates it.
    func store(userKey: Data, boundTo wrappedUserKey: String, for account: AccountID) throws

    /// Prompts for Touch ID and returns the stored vault key. Throws
    /// `.invalidated` when the stored entry no longer matches `wrappedUserKey`.
    func loadUserKey(
        for account: AccountID,
        boundTo wrappedUserKey: String,
        reason: String
    ) async throws -> Data

    /// Removes the stored key. Called on opt-out and on account removal.
    func remove(for account: AccountID) throws
}

/// Stores one account's **user key** behind Touch ID.
///
/// What is stored is deliberately the narrowest useful secret. The master
/// password and the master key are not stored: the master key derives the
/// server authentication hash, so holding it would let a thief with an unlocked
/// Mac authenticate as the user and change their password. The user key only
/// decrypts vault content — the RSA private key and every organization key are
/// themselves wrapped under it inside the snapshot, so the whole keyring
/// rebuilds from it without ever touching the password.
///
/// The Keychain item is protected by a `SecAccessControl` requiring the current
/// biometric set: adding or removing a fingerprint invalidates it, and it never
/// leaves this device or syncs to iCloud. The stored payload is additionally
/// bound to the wrapped-user-key string the account had when it was enrolled,
/// so rotating the vault key makes the entry fail closed instead of decrypting
/// a vault it no longer matches.
struct BiometricVaultKeyStore: BiometricVaultKeyStoring {
    let service: String

    init(service: String = "ch.lkmc.VaultSquire.biometric-vault-keys") {
        self.service = service
    }

    /// The stored payload: the key plus what it was bound to. Versioned so a
    /// later format change is recognizable rather than silently misread.
    private struct Payload: Codable {
        let version: Int
        let userKey: Data
        /// SHA-256 of the account's wrapped user key at enrollment time.
        let boundTo: String

        static let currentVersion = 1
    }

    /// Holds an `LAContext` — a non-Sendable reference type — so it can be
    /// carried across the async evaluation and into the Keychain query without
    /// tripping Swift 6 strict concurrency. One box is used by one call at a
    /// time and never shared, which is what makes the unchecked conformance
    /// sound.
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
        var query = baseQuery(for: account)
        query[kSecReturnData] = kCFBooleanFalse
        query[kSecMatchLimit] = kSecMatchLimitOne
        // Ask only whether the item exists; authentication must not be
        // triggered by an existence check, so the UI can decide whether to
        // offer the button without ever prompting.
        query[kSecUseAuthenticationUI] = kSecUseAuthenticationUISkip
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    func store(userKey: Data, boundTo wrappedUserKey: String, for account: AccountID) throws {
        guard isBiometryAvailable else { throw BiometricUnlockError.unavailable }

        var controlError: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &controlError
        ) else {
            controlError?.release()
            throw BiometricUnlockError.unavailable
        }

        let payload = Payload(
            version: Payload.currentVersion,
            userKey: userKey,
            boundTo: Self.digest(of: wrappedUserKey)
        )
        guard let encoded = try? JSONEncoder().encode(payload) else {
            throw BiometricUnlockError.failed(errSecParam)
        }

        // Replace any previous entry: re-enrolling must not fail on a duplicate,
        // and the old key must not linger behind a stale access control.
        try? remove(for: account)

        var query = baseQuery(for: account)
        query[kSecValueData] = encoded
        query[kSecAttrAccessControl] = control
        query[kSecAttrSynchronizable] = kCFBooleanFalse
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BiometricUnlockError.failed(status)
        }
    }

    func loadUserKey(
        for account: AccountID,
        boundTo wrappedUserKey: String,
        reason: String
    ) async throws -> Data {
        guard hasKey(for: account) else { throw BiometricUnlockError.notEnrolled }

        let box = AuthenticationBox()
        var availability: NSError?
        guard box.context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics, error: &availability
        ) else {
            throw BiometricUnlockError.unavailable
        }

        try await Self.evaluate(box, reason: reason)

        var query = baseQuery(for: account)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne
        // The policy was just satisfied on this context, so the item opens
        // without a second prompt.
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
            // The stored entry no longer opens under the current biometric set.
            try? remove(for: account)
            throw BiometricUnlockError.invalidated
        default:
            throw BiometricUnlockError.failed(status)
        }

        guard let data = result as? Data,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Payload.currentVersion else {
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
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw BiometricUnlockError.failed(status)
        }
    }

    // MARK: - Private

    /// Runs the biometric policy, mapping every outcome onto a typed error so a
    /// cancellation is never confused with a failure.
    private static func evaluate(_ box: AuthenticationBox, reason: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            box.context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            ) { success, error in
                if success {
                    continuation.resume()
                    return
                }
                let code = (error as? LAError)?.code
                switch code {
                case .userCancel, .appCancel, .systemCancel, .userFallback:
                    continuation.resume(throwing: BiometricUnlockError.cancelled)
                case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
                    continuation.resume(throwing: BiometricUnlockError.unavailable)
                case .biometryLockout:
                    continuation.resume(throwing: BiometricUnlockError.invalidated)
                default:
                    continuation.resume(throwing: BiometricUnlockError.cancelled)
                }
            }
        }
    }

    /// Hex SHA-256, used to bind a stored key to the account's current wrapped
    /// user key without storing that value itself.
    static func digest(of value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
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
