import Foundation
import Security
@testable import VaultSquire

/// In-memory credential store for logic tests. Mirrors the refresh-token
/// replacement semantics of the Keychain implementation, including throwing
/// `recordNotFound` when no record exists.
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
        guard let existing = records[account.rawValue] else {
            throw VaultwardenCredentialStoreError.recordNotFound
        }
        records[account.rawValue] = VaultwardenStoredCredentials(
            refreshToken: token,
            rememberedTwoFactorToken: existing.rememberedTwoFactorToken,
            version: existing.version
        )
    }

    func delete(for account: VaultwardenAccountKey) throws {
        lock.lock(); defer { lock.unlock() }
        records[account.rawValue] = nil
    }

    /// Test-only, non-throwing direct read. Kept alongside `load(for:)` so
    /// add-account assertions can read a record without a `try`; used by
    /// `AddAccountModelTests`.
    func record(for account: VaultwardenAccountKey) -> VaultwardenStoredCredentials? {
        lock.lock(); defer { lock.unlock() }
        return records[account.rawValue]
    }
}

/// A credential store whose reads and writes report the platform store as
/// unavailable, for exercising the credential-store-failure path where the
/// server authenticated but the local store could not complete. `delete` is a
/// no-op so teardown never fails.
struct FailingCredentialStore: VaultwardenCredentialStore {
    func save(_ credentials: VaultwardenStoredCredentials, for account: VaultwardenAccountKey) throws {
        throw VaultwardenCredentialStoreError.storeUnavailable(errSecMissingEntitlement)
    }

    func load(for account: VaultwardenAccountKey) throws -> VaultwardenStoredCredentials? {
        nil
    }

    func replaceRefreshToken(_ token: String, for account: VaultwardenAccountKey) throws {
        throw VaultwardenCredentialStoreError.storeUnavailable(errSecMissingEntitlement)
    }

    func delete(for account: VaultwardenAccountKey) throws {}
}
