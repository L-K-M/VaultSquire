import Foundation

/// One vault item as it rests: every user-authored field is a Vaultwarden
/// EncString kept in its raw serialized form, decrypted only at unlock. The
/// model is `Codable` so a whole synced snapshot can be persisted to the
/// device-sealed cache and reloaded byte-identically for offline unlock; it is
/// never decrypted by the persistence layer.
///
/// Only the fields VaultSquire currently projects or reveals are typed. The
/// non-secret routing fields — identifiers, item type, organization/folder
/// membership, favorite flag, revision date — are plaintext on the wire and
/// stay plaintext here; they order and group items without any decryption.
struct VaultwardenCipherModel: Sendable, Codable, Hashable {
    /// Vaultwarden's item type discriminator.
    enum ItemType: Int, Sendable, Codable {
        case login = 1
        case secureNote = 2
        case card = 3
        case identity = 4
    }

    let id: String
    let type: ItemType
    /// The organization that owns this cipher, or nil for a personal item. A
    /// personal item decrypts under the user key; an organization item under
    /// that organization's key.
    let organizationID: String?
    let folderID: String?
    let favorite: Bool
    let revisionDate: Date
    /// Name EncString (always present for a real item).
    let name: String?
    /// Notes EncString.
    let notes: String?
    let login: Login?
    let card: Card?
    let identity: Identity?

    struct Login: Sendable, Codable, Hashable {
        let username: String?
        let password: String?
        /// TOTP seed EncString (an `otpauth://` URI or a bare Base32 secret,
        /// once decrypted).
        let totp: String?
        let uris: [URI]

        struct URI: Sendable, Codable, Hashable {
            let uri: String?
        }
    }

    struct Card: Sendable, Codable, Hashable {
        let cardholderName: String?
        let brand: String?
        let number: String?
        let expMonth: String?
        let expYear: String?
        let code: String?
    }

    struct Identity: Sendable, Codable, Hashable {
        let title: String?
        let firstName: String?
        let lastName: String?
        let email: String?
        let phone: String?
    }

    // Wire keys are PascalCase from the API and lowerCamel from some proxies;
    // both are accepted. Persisted snapshots use the explicit lowerCamel form
    // this type encodes to, so a reload round-trips through the same keys.
    enum CodingKeys: String, CodingKey {
        case id, type, organizationID, folderID, favorite, revisionDate
        case name, notes, login, card, identity
        case idP = "Id", typeP = "Type", organizationIDP = "OrganizationId"
        case folderIDP = "FolderId", favoriteP = "Favorite", revisionDateP = "RevisionDate"
        case nameP = "Name", notesP = "Notes", loginP = "Login", cardP = "Card", identityP = "Identity"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ camel: CodingKeys, _ pascal: CodingKeys) throws -> String? {
            try c.decodeIfPresent(String.self, forKey: camel)
                ?? c.decodeIfPresent(String.self, forKey: pascal)
        }

        guard let id = try str(.id, .idP) else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                .init(codingPath: decoder.codingPath, debugDescription: "missing cipher id")
            )
        }
        self.id = id

        let rawType = try c.decodeIfPresent(Int.self, forKey: .type)
            ?? c.decodeIfPresent(Int.self, forKey: .typeP)
        self.type = rawType.flatMap(ItemType.init(rawValue:)) ?? .secureNote

        self.organizationID = try str(.organizationID, .organizationIDP)
        self.folderID = try str(.folderID, .folderIDP)
        self.favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite)
            ?? c.decodeIfPresent(Bool.self, forKey: .favoriteP) ?? false

        if let date = try Self.decodeDate(c, .revisionDate, .revisionDateP) {
            self.revisionDate = date
        } else {
            self.revisionDate = Date(timeIntervalSince1970: 0)
        }

        self.name = try str(.name, .nameP)
        self.notes = try str(.notes, .notesP)
        self.login = try c.decodeIfPresent(Login.self, forKey: .login)
            ?? c.decodeIfPresent(Login.self, forKey: .loginP)
        self.card = try c.decodeIfPresent(Card.self, forKey: .card)
            ?? c.decodeIfPresent(Card.self, forKey: .cardP)
        self.identity = try c.decodeIfPresent(Identity.self, forKey: .identity)
            ?? c.decodeIfPresent(Identity.self, forKey: .identityP)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type.rawValue, forKey: .type)
        try c.encodeIfPresent(organizationID, forKey: .organizationID)
        try c.encodeIfPresent(folderID, forKey: .folderID)
        try c.encode(favorite, forKey: .favorite)
        try c.encode(Self.wireDateString(revisionDate), forKey: .revisionDate)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(login, forKey: .login)
        try c.encodeIfPresent(card, forKey: .card)
        try c.encodeIfPresent(identity, forKey: .identity)
    }

    /// Direct memberwise construction, used by tests and by the write path when
    /// building a cipher to persist alongside its server round trip.
    init(
        id: String,
        type: ItemType,
        organizationID: String? = nil,
        folderID: String? = nil,
        favorite: Bool = false,
        revisionDate: Date,
        name: String?,
        notes: String? = nil,
        login: Login? = nil,
        card: Card? = nil,
        identity: Identity? = nil
    ) {
        self.id = id
        self.type = type
        self.organizationID = organizationID
        self.folderID = folderID
        self.favorite = favorite
        self.revisionDate = revisionDate
        self.name = name
        self.notes = notes
        self.login = login
        self.card = card
        self.identity = identity
    }

    /// A fresh formatter per call: `ISO8601DateFormatter` is a reference type and
    /// not `Sendable`, so it cannot be a shared static under Swift 6 strict
    /// concurrency, and date coding is not hot enough to need caching.
    private static func fractionalFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func decodeDate(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ camel: CodingKeys,
        _ pascal: CodingKeys
    ) throws -> Date? {
        guard let raw = try container.decodeIfPresent(String.self, forKey: camel)
            ?? container.decodeIfPresent(String.self, forKey: pascal) else {
            return nil
        }
        if let date = fractionalFormatter().date(from: raw) {
            return date
        }
        // Some servers omit fractional seconds.
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private static func wireDateString(_ date: Date) -> String {
        fractionalFormatter().string(from: date)
    }
}
