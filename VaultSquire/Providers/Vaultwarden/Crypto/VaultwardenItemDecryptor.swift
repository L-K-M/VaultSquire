import Foundation

/// Decrypts a synced cipher into the shared projection (for lists and search)
/// and the transient detail (for the item view). It reads every field through
/// the keyring, tolerating individual field failures, and never persists a
/// decrypted value.
enum VaultwardenItemDecryptor {
    /// Read-side capabilities every decrypted item supports. Write capabilities
    /// are added by the write path per account, so absence here never implies a
    /// mutation is unsupported — it just is not part of the read slice.
    static let readCapabilities: Set<ProviderCapability> = [
        .viewItems, .searchItems, .revealSecret, .copySecret,
    ]

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
        }
    }

    static func projection(
        for cipher: VaultwardenCipherModel,
        keyring: VaultwardenKeyring,
        account: AccountID,
        folderNames: [String: String],
        generation: UInt64
    ) -> VaultItemProjection {
        let org = cipher.organizationID
        let title = keyring.decrypt(cipher.name, organizationID: org) ?? "Unnamed item"
        let username = keyring.decrypt(cipher.login?.username, organizationID: org)
        let websites = (cipher.login?.uris ?? []).compactMap {
            keyring.decrypt($0.uri, organizationID: org)
        }
        let groupingLabels = cipher.folderID
            .flatMap { folderNames[$0] }
            .map { [$0] } ?? []

        return VaultItemProjection(
            id: itemID(for: cipher, account: account),
            displayTitle: title,
            displaySubtitle: subtitle(username: username, websites: websites, category: category(for: cipher.type)),
            category: category(for: cipher.type),
            username: username,
            websites: websites,
            groupingLabels: groupingLabels,
            capabilities: readCapabilities,
            cacheReference: cacheReference(for: cipher, account: account, generation: generation)
        )
    }

    static func detail(
        for cipher: VaultwardenCipherModel,
        keyring: VaultwardenKeyring,
        account: AccountID,
        generation: UInt64
    ) -> VaultItemDetail {
        let org = cipher.organizationID
        func decrypt(_ value: String?) -> String? { keyring.decrypt(value, organizationID: org) }

        var fields: [VaultItemDetail.DetailField] = []
        func add(_ label: String, _ value: String?, _ kind: VaultItemDetail.DetailField.Kind) {
            guard let value, !value.isEmpty else { return }
            fields.append(.init(id: "\(label)#\(fields.count)", label: label, value: value, kind: kind))
        }

        switch cipher.type {
        case .login:
            add("Username", decrypt(cipher.login?.username), .plain)
            add("Password", decrypt(cipher.login?.password), .secret)
            add("One-time code", decrypt(cipher.login?.totp), .totpSeed)
            for uri in cipher.login?.uris ?? [] {
                add("Website", decrypt(uri.uri), .uri)
            }
        case .card:
            add("Cardholder", decrypt(cipher.card?.cardholderName), .plain)
            add("Brand", decrypt(cipher.card?.brand), .plain)
            add("Number", decrypt(cipher.card?.number), .secret)
            if let month = decrypt(cipher.card?.expMonth), let year = decrypt(cipher.card?.expYear) {
                add("Expires", "\(month)/\(year)", .plain)
            }
            add("Security code", decrypt(cipher.card?.code), .secret)
        case .identity:
            let name = [decrypt(cipher.identity?.firstName), decrypt(cipher.identity?.lastName)]
                .compactMap { $0 }.joined(separator: " ")
            add("Name", name.isEmpty ? nil : name, .plain)
            add("Email", decrypt(cipher.identity?.email), .plain)
            add("Phone", decrypt(cipher.identity?.phone), .plain)
        case .secureNote:
            break
        }
        add("Notes", decrypt(cipher.notes), .plain)

        return VaultItemDetail(
            id: itemID(for: cipher, account: account),
            title: decrypt(cipher.name) ?? "Unnamed item",
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
