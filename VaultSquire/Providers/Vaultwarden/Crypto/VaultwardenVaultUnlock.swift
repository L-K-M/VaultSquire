import Foundation

enum VaultwardenUnlockError: Error, Equatable, Sendable {
    /// The master password did not unwrap the user key (the common wrong-password
    /// case, surfaced as a single generic outcome — a MAC failure and a padding
    /// failure are indistinguishable by design).
    case wrongPassword
    /// The account's KDF is one VaultSquire cannot run yet (Argon2id fails
    /// closed rather than substituting a weaker derivation).
    case unsupportedKDF
    /// The vault's key material uses the legacy unauthenticated type-0
    /// encryption VaultSquire refuses to read. The account must be migrated by
    /// a compatible client; telling the user their password is wrong sends
    /// them retrying a correct password forever.
    case legacyEncryptionUnsupported
    /// The stored vault snapshot is structurally unusable.
    case malformedVault
}

/// Turns a stored vault snapshot and a master password into an in-memory
/// keyring. This is the whole unlock crypto path: derive the master key from
/// the snapshot's KDF and email, stretch it, unwrap the user key, and best-effort
/// unwrap each organization key through the user's RSA private key. No secret is
/// persisted; the keyring lives only as long as the session holds it.
enum VaultwardenVaultUnlock {
    static func unlock(
        snapshot: VaultwardenVaultSnapshot,
        masterPasswordBytes: Data
    ) async throws -> VaultwardenKeyring {
        let configuration: VaultwardenKDFConfiguration
        do {
            configuration = try snapshot.kdf.configuration()
        } catch {
            throw VaultwardenUnlockError.malformedVault
        }

        let masterKey: Data
        do {
            masterKey = try await VaultwardenKeyDerivation.deriveMasterKey(
                passwordBytes: masterPasswordBytes,
                email: snapshot.email,
                configuration: configuration
            )
        } catch VaultwardenCryptoError.argon2idUnavailable {
            throw VaultwardenUnlockError.unsupportedKDF
        } catch {
            // A below-floor or arithmetic KDF failure is a malformed vault, not a
            // wrong password.
            throw VaultwardenUnlockError.malformedVault
        }

        let stretched: Data
        do {
            stretched = try VaultwardenKeyDerivation.stretchMasterKey(masterKey)
        } catch {
            throw VaultwardenUnlockError.malformedVault
        }

        let userKey: VaultwardenSymmetricKey
        do {
            userKey = try VaultwardenKeyUnwrap.unwrapUserKey(
                wrapped: snapshot.wrappedUserKey,
                stretchedMasterKey: stretched
            )
        } catch VaultwardenCryptoError.legacyEncryptionDetected {
            throw VaultwardenUnlockError.legacyEncryptionUnsupported
        } catch {
            // Any unwrap failure under the derived key means the password was
            // wrong (or the wrapped key is corrupt, which the user cannot
            // distinguish and should retry the password for).
            throw VaultwardenUnlockError.wrongPassword
        }

        let organizationKeys = unwrapOrganizationKeys(snapshot: snapshot, userKey: userKey)
        return VaultwardenKeyring(userKey: userKey, organizationKeys: organizationKeys)
    }

    /// Rebuilds the keyring from an already-unwrapped user key, for an unlock
    /// that authenticated some other way (Touch ID). No password and no KDF
    /// work is involved: the RSA private key and every organization key are
    /// wrapped under the user key inside the snapshot, so the same keyring
    /// falls out. The caller is responsible for having authenticated the user.
    static func keyring(
        snapshot: VaultwardenVaultSnapshot,
        userKey: VaultwardenSymmetricKey
    ) -> VaultwardenKeyring {
        VaultwardenKeyring(
            userKey: userKey,
            organizationKeys: unwrapOrganizationKeys(snapshot: snapshot, userKey: userKey)
        )
    }

    /// Best-effort organization-key unwrapping: decrypt the user's private key,
    /// then RSA-decapsulate each organization key. Any organization that fails
    /// is omitted rather than aborting unlock — personal items still open.
    private static func unwrapOrganizationKeys(
        snapshot: VaultwardenVaultSnapshot,
        userKey: VaultwardenSymmetricKey
    ) -> [String: VaultwardenSymmetricKey] {
        guard let wrappedPrivateKey = snapshot.wrappedPrivateKey,
              !snapshot.organizations.isEmpty,
              let privateKey = try? VaultwardenKeyUnwrap.decryptPrivateKey(
                  wrapped: wrappedPrivateKey,
                  userKey: userKey
              ) else {
            return [:]
        }

        var keys: [String: VaultwardenSymmetricKey] = [:]
        for organization in snapshot.organizations {
            guard let parsed = try? VaultwardenEncString.parse(organization.wrappedKey),
                  case .asymmetric(_, let payload) = parsed,
                  let key = try? VaultwardenKeyUnwrap.unwrapOrganizationKey(
                      wrappedOrganizationKey: payload,
                      privateKeyPKCS8: privateKey
                  ) else {
                continue
            }
            keys[organization.id] = key
        }
        return keys
    }
}
