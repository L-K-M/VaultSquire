import Foundation

/// Decrypts a synced cipher into the shared projection (for lists and search)
/// and the transient detail (for the item view). It reads every field through
/// the keyring, tolerating individual field failures, and never persists a
/// decrypted value.
enum VaultwardenItemDecryptor {
    static func itemID(for cipher: VaultwardenCipherModel, account: AccountID) -> VaultItemID {
        let scope: VaultSpaceID.Scope = cipher.organizationID
            .map { .providerSpace($0) } ?? .personal
        return VaultItemID(
            space: VaultSpaceID(account: account, scope: scope),
            rawValue: cipher.id
        )
    }

    static func cacheReference(
        for cipher: VaultwardenCipherModel,
        account: AccountID,
        generation: UInt64
    ) -> ProviderCacheReference {
        let scope: ProviderCacheScope = cipher.organizationID
            .map { .space(VaultSpaceID(account: account, scope: .providerSpace($0))) }
            ?? .wholeAccount(account)
        return ProviderCacheReference(
            scope: scope,
            captureGeneration: SnapshotGeneration(rawValue: generation)
        )
    }

    static func category(for type: VaultwardenCipherModel.ItemType) -> VaultItemCategory {
        switch type {
        case .login: return .login
        case .secureNote: return .secureNote
        case .card: return .card
        case .identity: return .identity
        case .unknown: return .unsupported
        }
    }

    static func projection(
        for cipher: VaultwardenCipherModel,
        keyring: VaultwardenKeyring,
        account: AccountID,
        folderNames: [String: String],
        generation: UInt64
    ) -> VaultItemProjection {
        let contentKey = keyring.key(for: cipher)
        let title = keyring.decrypt(
            cipher.name, key: contentKey, maximumUTF8Bytes: 16 * 1024
        ) ?? "Unreadable item"
        let username = cipher.type == .login
            ? keyring.decrypt(
                cipher.login?.username, key: contentKey, maximumUTF8Bytes: 64 * 1024
            ) : nil
        let websites = cipher.type == .login
            ? (cipher.login?.uris ?? []).prefix(100).compactMap {
                keyring.decrypt($0.uri, key: contentKey, maximumUTF8Bytes: 2_048)
            }
            : []
        let groupings: [VaultItemGrouping]
        if let folderID = cipher.folderID, let folderName = folderNames[folderID] {
            groupings = [VaultItemGrouping(id: folderID, name: folderName)]
        } else {
            groupings = []
        }
        var capabilities: Set<ProviderCapability> = [.viewItems, .searchItems]
        if cipher.type != .unknown, cipher.viewPassword {
            capabilities.formUnion([.revealSecret, .copySecret])
        }

        return VaultItemProjection(
            id: itemID(for: cipher, account: account),
            displayTitle: title,
            displaySubtitle: subtitle(username: username, websites: websites, category: category(for: cipher.type)),
            category: category(for: cipher.type),
            username: username,
            websites: websites,
            groupings: groupings,
            capabilities: capabilities,
            cacheReference: cacheReference(for: cipher, account: account, generation: generation)
        )
    }

    static func detail(
        for cipher: VaultwardenCipherModel,
        keyring: VaultwardenKeyring,
        account: AccountID,
        generation: UInt64
    ) -> VaultItemDetail {
        let contentKey = keyring.key(for: cipher)
        var remainingPlaintextBytes = 4 * 1024 * 1024
        func decrypt(
            _ value: String?,
            maximumBytes: Int = 1 * 1024 * 1024
        ) -> String? {
            let allowance = min(maximumBytes, remainingPlaintextBytes)
            guard allowance > 0,
                  let plaintext = keyring.decrypt(
                      value, key: contentKey, maximumUTF8Bytes: allowance
                  ) else {
                return nil
            }
            remainingPlaintextBytes -= plaintext.utf8.count
            return plaintext
        }
        let title = decrypt(cipher.name, maximumBytes: 16 * 1024) ?? "Unreadable item"

        var fields: [VaultItemDetail.DetailField] = []
        func add(_ label: String, _ value: String?, _ kind: VaultItemDetail.DetailField.Kind) {
            guard fields.count < 512, label.utf8.count <= 16 * 1024,
                  let value, !value.isEmpty else { return }
            fields.append(.init(id: "\(label)#\(fields.count)", label: label, value: value, kind: kind))
        }

        switch cipher.type {
        case .login:
            add("Username", decrypt(cipher.login?.username, maximumBytes: 64 * 1024), .plain)
            if cipher.viewPassword {
                add("Password", decrypt(cipher.login?.password), .secret)
                add("One-time code", decrypt(cipher.login?.totp, maximumBytes: 8_192), .totpSeed)
            }
            for uri in (cipher.login?.uris ?? []).prefix(100) {
                add("Website", decrypt(uri.uri, maximumBytes: 2_048), .uri)
            }
        case .card:
            add("Cardholder", decrypt(cipher.card?.cardholderName), .plain)
            add("Brand", decrypt(cipher.card?.brand), .plain)
            if cipher.viewPassword {
                add("Number", decrypt(cipher.card?.number), .secret)
            }
            if let month = decrypt(cipher.card?.expMonth), let year = decrypt(cipher.card?.expYear) {
                add("Expires", "\(month)/\(year)", .plain)
            }
            if cipher.viewPassword {
                add("Security code", decrypt(cipher.card?.code), .secret)
            }
        case .identity:
            let name = [decrypt(cipher.identity?.firstName), decrypt(cipher.identity?.lastName)]
                .compactMap { $0 }.joined(separator: " ")
            add("Name", name.isEmpty ? nil : name, .plain)
            add("Email", decrypt(cipher.identity?.email), .plain)
            add("Phone", decrypt(cipher.identity?.phone), .plain)
        case .secureNote:
            break
        case .unknown:
            // The exact ciphertext remains in the snapshot, but this build has
            // no reviewed field interpretation for the unknown object type.
            break
        }
        if cipher.type != .unknown {
            add("Notes", decrypt(cipher.notes, maximumBytes: 2 * 1024 * 1024), .plain)
        }

        // Custom fields carry much of an imported item's real content (serial
        // numbers, license keys). Hidden fields stay concealed like passwords;
        // linked fields are references with no value of their own and are not
        // rendered.
        if cipher.type != .unknown {
            for field in cipher.fields.prefix(500) where field.type != 3 {
                // Only explicitly documented text/boolean fields are plain.
                // Hidden and unknown kinds are secret, and are omitted when the
                // server denies password viewing.
                let kind: VaultItemDetail.DetailField.Kind =
                    (field.type == 0 || field.type == 2) ? .plain : .secret
                guard kind != .secret || cipher.viewPassword else { continue }
                let label = decrypt(field.name, maximumBytes: 16 * 1024) ?? "Field"
                add(label, decrypt(field.value), kind)
            }
        }

        return VaultItemDetail(
            id: itemID(for: cipher, account: account),
            title: title,
            category: category(for: cipher.type),
            fields: fields
        )
    }

    private static func subtitle(
        username: String?,
        websites: [String],
        category: VaultItemCategory
    ) -> String? {
        if let username, !username.isEmpty { return username }
        if let first = websites.first, let host = URL(string: first)?.host { return host }
        if let first = websites.first, !first.isEmpty { return first }
        switch category {
        case .login: return nil
        case .secureNote: return "Secure note"
        case .card: return "Card"
        case .identity: return "Identity"
        case .unsupported: return nil
        }
    }
}
