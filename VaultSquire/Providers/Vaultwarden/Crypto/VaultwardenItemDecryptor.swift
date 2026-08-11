import Foundation

/// Decrypts a synced cipher into the shared projection (for lists and search)
/// and the transient detail (for the item view). It reads every field through
/// the key the cipher actually uses — the per-item cipher key when the cipher
/// carries one, otherwise the account key for its scope — tolerating
/// individual field failures, and never persists a decrypted value.
///
/// Server-computed restrictions are enforced here, at the use-case boundary
/// rather than only in disabled controls: a cipher the server marks
/// `viewPassword: false` yields no concealed field (reveal and copy have
/// nothing to act on), and trashed or archived ciphers produce no projection,
/// detail, or draft at all.
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
        default: return .unsupported
        }
    }

    /// The key this cipher's user-authored fields are encrypted under.
    ///
    /// When the cipher carries a wrapped per-item key (the form current
    /// official clients emit for every new cipher), that key — unwrapped under
    /// the account key for the cipher's scope — decrypts its fields.
    /// Otherwise the scope's account key is used directly. Returns nil when
    /// the needed account key is unavailable or the wrapped item key is
    /// undecryptable, in which case the cipher yields no plaintext rather than
    /// garbage decrypted under the wrong key.
    static func decryptionKey(
        for cipher: VaultwardenCipherModel,
        keyring: VaultwardenKeyring
    ) -> VaultwardenSymmetricKey? {
        guard let accountKey = keyring.key(forOrganization: cipher.organizationID) else {
            return nil
        }
        guard let wrappedItemKey = cipher.key, !wrappedItemKey.isEmpty else {
            return accountKey
        }
        return try? VaultwardenKeyUnwrap.unwrapCipherKey(
            wrapped: wrappedItemKey,
            accountKey: accountKey
        )
    }

    /// Decrypts one EncString field under the cipher's resolved key. Returns
    /// nil for a nil or undecryptable field, so a single bad field never
    /// aborts a whole item.
    private static func decrypt(
        _ encString: String?,
        with key: VaultwardenSymmetricKey?
    ) -> String? {
        guard let encString, let key,
              let parsed = try? VaultwardenEncString.parse(encString),
              let data = try? VaultwardenCipher.decrypt(parsed, key: key) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// The list projection for a live cipher, or nil for a trashed or
    /// archived one: both stay out of default lists and search (trash state
    /// and per-user archived state alike), exactly as the reference clients
    /// present them.
    static func projection(
        for cipher: VaultwardenCipherModel,
        keyring: VaultwardenKeyring,
        account: AccountID,
        folderNames: [String: String],
        generation: UInt64
    ) -> VaultItemProjection? {
        guard !cipher.isTrashed, !cipher.isArchived else { return nil }
        let key = decryptionKey(for: cipher, keyring: keyring)
        let title = decrypt(cipher.name, with: key) ?? "Unnamed item"
        let username = decrypt(cipher.login?.username, with: key)
        let websites = (cipher.login?.uris ?? []).compactMap {
            decrypt($0.uri, with: key)
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

    /// The decrypted detail for a live cipher, or nil for a trashed or
    /// archived one, which has no business on the detail surface either.
    static func detail(
        for cipher: VaultwardenCipherModel,
        keyring: VaultwardenKeyring,
        account: AccountID,
        generation: UInt64
    ) -> VaultItemDetail? {
        guard !cipher.isTrashed, !cipher.isArchived else { return nil }
        let key = decryptionKey(for: cipher, keyring: keyring)
        func dec(_ value: String?) -> String? { decrypt(value, with: key) }

        // A cipher the server marks viewPassword: false (a hide-passwords
        // collection, for example) must not reveal or copy its concealed
        // fields even though the ciphertext is locally decryptable. The
        // fields are simply not emitted, so the detail view has no secret to
        // render, reveal, or copy.
        let mayRevealSecrets = cipher.viewPassword ?? true

        var fields: [VaultItemDetail.DetailField] = []
        func add(_ label: String, _ value: String?, _ kind: VaultItemDetail.DetailField.Kind) {
            guard let value, !value.isEmpty else { return }
            if kind == .secret || kind == .totpSeed {
                guard mayRevealSecrets else { return }
            }
            fields.append(.init(id: "\(label)#\(fields.count)", label: label, value: value, kind: kind))
        }

        switch cipher.type {
        case .login:
            add("Username", dec(cipher.login?.username), .plain)
            add("Password", dec(cipher.login?.password), .secret)
            add("One-time code", dec(cipher.login?.totp), .totpSeed)
            for uri in cipher.login?.uris ?? [] {
                add("Website", dec(uri.uri), .uri)
            }
        case .card:
            add("Cardholder", dec(cipher.card?.cardholderName), .plain)
            add("Brand", dec(cipher.card?.brand), .plain)
            add("Number", dec(cipher.card?.number), .secret)
            if let month = dec(cipher.card?.expMonth), let year = dec(cipher.card?.expYear) {
                add("Expires", "\(month)/\(year)", .plain)
            }
            add("Security code", dec(cipher.card?.code), .secret)
        case .identity:
            let name = [dec(cipher.identity?.firstName), dec(cipher.identity?.lastName)]
                .compactMap { $0 }.joined(separator: " ")
            add("Name", name.isEmpty ? nil : name, .plain)
            add("Email", dec(cipher.identity?.email), .plain)
            add("Phone", dec(cipher.identity?.phone), .plain)
        default:
            // Secure notes carry their content in Notes below; SSH keys and
            // unrecognized types present their notes and custom fields only.
            break
        }
        add("Notes", dec(cipher.notes), .plain)

        // Custom fields carry much of an imported item's real content (serial
        // numbers, license keys). Hidden fields stay concealed like passwords;
        // linked fields are references with no value of their own and are not
        // rendered.
        for field in cipher.fields where field.type != 3 {
            let label = dec(field.name) ?? "Field"
            add(label, dec(field.value), field.type == 1 ? .secret : .plain)
        }

        return VaultItemDetail(
            id: itemID(for: cipher, account: account),
            title: dec(cipher.name) ?? "Unnamed item",
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
