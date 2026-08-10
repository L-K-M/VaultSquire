import Foundation
@testable import VaultSquire

/// Test-only biometric key store. Hosted CI has neither Touch ID nor a usable
/// Data Protection Keychain, so enrollment, unlock, revocation, and every
/// failure mode are exercised through this fake. It never leaves the test
/// target.
final class FakeBiometricVaultKeyStore: BiometricVaultKeyStoring, @unchecked Sendable {
    private struct Entry {
        let userKey: Data
        let boundTo: String
    }

    private let lock = NSLock()
    private var entries: [AccountID: Entry] = [:]

    var available: Bool
    /// When set, `loadUserKey` throws this instead of returning the key, so a
    /// cancelled prompt or an invalidated entry can be exercised.
    var loadFailure: BiometricUnlockError?
    /// When true, `store` throws, standing in for a Keychain refusal.
    var storeFails = false

    private(set) var loadCallCount = 0

    init(available: Bool = true) {
        self.available = available
    }

    var isBiometryAvailable: Bool { available }

    func hasKey(for account: AccountID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[account] != nil
    }

    func store(userKey: Data, boundTo wrappedUserKey: String, for account: AccountID) throws {
        if storeFails { throw BiometricUnlockError.failed(-1) }
        guard available else { throw BiometricUnlockError.unavailable }
        lock.lock(); defer { lock.unlock() }
        entries[account] = Entry(userKey: userKey, boundTo: wrappedUserKey)
    }

    func loadUserKey(
        for account: AccountID,
        boundTo wrappedUserKey: String,
        reason: String
    ) async throws -> Data {
        // Scoped locking: NSLock's bare lock()/unlock() are unavailable from an
        // async context, and this method is the only async one here.
        let entry = lock.withLock {
            loadCallCount += 1
            return entries[account]
        }

        if let loadFailure { throw loadFailure }
        guard available else { throw BiometricUnlockError.unavailable }
        guard let entry else { throw BiometricUnlockError.notEnrolled }
        // Mirrors the real store: a key bound to different material is stale.
        guard entry.boundTo == wrappedUserKey else {
            try? remove(for: account)
            throw BiometricUnlockError.invalidated
        }
        return entry.userKey
    }

    func remove(for account: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: account)
    }
}
