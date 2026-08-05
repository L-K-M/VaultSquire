import Foundation
@testable import VaultSquire

/// In-memory credential store for logic tests. Mirrors the atomic
/// refresh-token replacement semantics of the Keychain implementation.
final class InMemoryCredentialStore: VaultwardenCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: VaultwardenStoredCredentials] = [:]

    func save(
        _ credentials: VaultwardenStoredCredentials,
        for account: VaultwardenAccountKey
    ) throws {
        lock.lock(); defer { lock.unlock() }
        records[account.rawValue] = credentials
    }

    func load(for account: VaultwardenAccountKey) throws -> VaultwardenStoredCredentials? {
        lock.lock(); defer { lock.unlock() }
        return records[account.rawValue]
    }

    func replaceRefreshToken(
        _ token: String,
        for account: VaultwardenAccountKey
    ) throws {
        lock.lock(); defer { lock.unlock() }
        let existing = records[account.rawValue]
        records[account.rawValue] = VaultwardenStoredCredentials(
            refreshToken: token,
            rememberedTwoFactorToken: existing?.rememberedTwoFactorToken
        )
    }

    func delete(for account: VaultwardenAccountKey) throws {
        lock.lock(); defer { lock.unlock() }
        records[account.rawValue] = nil
    }

    /// Test-only direct read.
    func record(for account: VaultwardenAccountKey) -> VaultwardenStoredCredentials? {
        lock.lock(); defer { lock.unlock() }
        return records[account.rawValue]
    }
}
