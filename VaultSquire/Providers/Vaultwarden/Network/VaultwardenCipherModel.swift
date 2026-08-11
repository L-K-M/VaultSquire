import Foundation

/// One vault item as it rests: every user-authored field is a Vaultwarden
/// EncString kept in its raw serialized form, decrypted only at unlock. The
/// model is `Codable` so a whole synced snapshot can be persisted to the
/// device-sealed cache and reloaded byte-identically for offline unlock; it is
/// never decrypted by the persistence layer.
///
/// Two preservation rules keep this model faithful to the server object. The
/// item type is stored as its raw integer, so a type this build does not
/// understand survives a sync/persist round trip instead of being flattened
/// into a known one (ARCHITECTURE.md: unknown records are never silently
/// dropped, rewritten, or treated as an empty known type). And the fields a
/// full-replacement write must pass back verbatim — the per-item cipher key,
/// password history, reprompt flag, collection membership, and organization
/// ownership — are decoded and re-encoded untouched, because a PUT that omits
/// them silently resets them server-side.
struct VaultwardenCipherModel: Sendable, Codable, Hashable {
    /// The raw item type discriminator. Values 1-5 are named; anything else
    /// is preserved numerically so it is never rewritten as a nearby kind.
    struct ItemType: RawRepresentable, Hashable, Sendable, Codable {
        let rawValue: Int

        init(rawValue: Int) {
            self.rawValue = rawValue
        }

        static let login = ItemType(rawValue: 1)
        static let secureNote = ItemType(rawValue: 2)
        static let card = ItemType(rawValue: 3)
        static let identity = ItemType(rawValue: 4)
        static let sshKey = ItemType(rawValue: 5)

        /// The types this build decrypts and displays with a dedicated layout.
        /// Everything else is shown as an unsupported record — visible, never
        /// coerced into a category it is not.
        var isRecognized: Bool {
            self == .login || self == .secureNote || self == .card || self == .identity
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            rawValue = try container.decode(Int.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    let id: String
    let type: ItemType
    /// The organization that owns this cipher, or nil for a personal item. A
    /// personal item decrypts under the user key; an organization item under
    /// that organization's key.
    let organizationID: String?
    /// The collections this cipher is filed under. Passthrough only: it is
    /// re-sent verbatim on update so an edit never silently unfiles the item.
    let collectionIds: [String]
    let folderID: String?
    let favorite: Bool
    let revisionDate: Date
    /// When the cipher was created. Passthrough metadata.
    let creationDate: Date?
    /// When the cipher was moved to trash, or nil while it is live. A trashed
    /// cipher still syncs down; it must never appear as a live item.
    let deletedDate: Date?
    /// When the requesting user archived the cipher, or nil. Per-user state,
    /// distinct from trash, excluded from default lists and search.
    let archivedDate: Date?
    /// The per-item cipher key, wrapped under the user (or organization) key
    /// as a type-2 EncString. When present, every user-authored field of this
    /// cipher is encrypted under the item key, not the account key. Current
    /// official clients encrypt new ciphers this way, so a model without this
    /// field cannot read — or safely edit — those ciphers at all.
    let key: String?
    /// Master-password reprompt policy (0 = none, 1 = required). Decoded so a
    /// write never strips it, and so the reveal surface can refuse to treat a
    /// reprompt item like any other until re-verification ships.
    let reprompt: Int?
    /// The server-computed read/write permissions for the requesting user.
    /// `edit == false` forbids mutation and `viewPassword == false` forbids
    /// reveal and copy of concealed fields even though the ciphertext is
    /// locally decryptable (collection policies such as hide-passwords are
    /// already folded into these flags by the server).
    let edit: Bool?
    let viewPassword: Bool?
    /// Server-computed delete/restore permissions. Passthrough this slice;
    /// delete and restore are not offered yet.
    let permissions: Permissions?
    /// Previous passwords for this cipher, each an EncString under the same
    /// key as the item's fields. Strictly passthrough: a replacing PUT that
    /// omitted it would wipe the item's password history server-side.
    let passwordHistory: [PasswordHistoryEntry]
    /// Name EncString (always present for a real item).
    let name: String?
    /// Notes EncString.
    let notes: String?
    let login: Login?
    let card: Card?
    let identity: Identity?
    /// User-defined custom fields. Imported items commonly keep their real
    /// content here (serial numbers, license keys), so they are first-class:
    /// decoded, displayed, and passed through untouched on update.
    let fields: [CustomField]

    /// True while the cipher is in the trash. Trashed ciphers are hidden from
    /// every list, search, detail, and write surface.
    var isTrashed: Bool { deletedDate != nil }
    /// True when the requesting user archived the cipher. Archived ciphers are
    /// hidden from default lists and search, distinct from trash.
    var isArchived: Bool { archivedDate != nil }
    /// Whether a master-password reprompt is required before reveal, copy,
    /// edit, or autofill of any field.
    var requiresReprompt: Bool { (reprompt ?? 0) != 0 }

    struct Permissions: Sendable, Codable, Hashable {
        let delete: Bool?
        let restore: Bool?

        init(delete: Bool? = nil, restore: Bool? = nil) {
            self.delete = delete
            self.restore = restore
        }

        enum CodingKeys: String, CodingKey {
            case delete, restore
            case deleteP = "Delete", restoreP = "Restore"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.delete = try c.decodeIfPresent(Bool.self, forKey: .delete)
                ?? c.decodeIfPresent(Bool.self, forKey: .deleteP)
            self.restore = try c.decodeIfPresent(Bool.self, forKey: .restore)
                ?? c.decodeIfPresent(Bool.self, forKey: .restoreP)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(delete, forKey: .delete)
            try c.encodeIfPresent(restore, forKey: .restore)
        }
    }

    struct PasswordHistoryEntry: Sendable, Codable, Hashable {
        /// Previous password EncString, encrypted under the same key as the
        /// item's current fields.
        let password: String?
        let lastUsedDate: Date?

        init(password: String? = nil, lastUsedDate: Date? = nil) {
            self.password = password
            self.lastUsedDate = lastUsedDate
        }

        enum CodingKeys: String, CodingKey {
            case password, lastUsedDate
            case passwordP = "Password", lastUsedDateP = "LastUsedDate"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.password = try c.decodeIfPresent(String.self, forKey: .password)
                ?? c.decodeIfPresent(String.self, forKey: .passwordP)
            let raw = try c.decodeIfPresent(String.self, forKey: .lastUsedDate)
                ?? c.decodeIfPresent(String.self, forKey: .lastUsedDateP)
            self.lastUsedDate = raw.flatMap(VaultwardenCipherModel.parseWireDate)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(password, forKey: .password)
            if let lastUsedDate {
                try c.encode(VaultwardenCipherModel.wireDateString(lastUsedDate), forKey: .lastUsedDate)
            }
        }
    }

    struct CustomField: Sendable, Codable, Hashable {
        /// Bitwarden field kind: 0 text, 1 hidden, 2 boolean, 3 linked.
        let type: Int
        /// Field label EncString.
        let name: String?
        /// Field value EncString; absent for linked fields.
        let value: String?

        init(type: Int, name: String?, value: String?) {
            self.type = type
            self.name = name
            self.value = value
        }

        enum CodingKeys: String, CodingKey {
            case type, name, value
            case typeP = "Type", nameP = "Name", valueP = "Value"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.type = try c.decodeIfPresent(Int.self, forKey: .type)
                ?? c.decodeIfPresent(Int.self, forKey: .typeP) ?? 0
            self.name = try c.decodeIfPresent(String.self, forKey: .name)
                ?? c.decodeIfPresent(String.self, forKey: .nameP)
            self.value = try c.decodeIfPresent(String.self, forKey: .value)
                ?? c.decodeIfPresent(String.self, forKey: .valueP)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(type, forKey: .type)
            try c.encodeIfPresent(name, forKey: .name)
            try c.encodeIfPresent(value, forKey: .value)
        }
    }

    struct Login: Sendable, Codable, Hashable {
        let username: String?
        let password: String?
        /// TOTP seed EncString (an `otpauth://` URI or a bare Base32 secret,
        /// once decrypted).
        let totp: String?
        let uris: [URI]

        struct URI: Sendable, Codable, Hashable {
            let uri: String?

            init(uri: String?) { self.uri = uri }

            // The wire is PascalCase from the API; a persisted snapshot is the
            // lowerCamel form this encodes to. Both decode.
            enum CodingKeys: String, CodingKey {
                case uri
                case uriP = "Uri"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.uri = try c.decodeIfPresent(String.self, forKey: .uri)
                    ?? c.decodeIfPresent(String.self, forKey: .uriP)
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encodeIfPresent(uri, forKey: .uri)
            }
        }

        init(username: String? = nil, password: String? = nil, totp: String? = nil, uris: [URI] = []) {
            self.username = username
            self.password = password
            self.totp = totp
            self.uris = uris
        }

        enum CodingKeys: String, CodingKey {
            case username, password, totp, uris
            case usernameP = "Username", passwordP = "Password"
            case totpP = "Totp", urisP = "Uris"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.username = try c.decodeIfPresent(String.self, forKey: .username)
                ?? c.decodeIfPresent(String.self, forKey: .usernameP)
            self.password = try c.decodeIfPresent(String.self, forKey: .password)
                ?? c.decodeIfPresent(String.self, forKey: .passwordP)
            self.totp = try c.decodeIfPresent(String.self, forKey: .totp)
                ?? c.decodeIfPresent(String.self, forKey: .totpP)
            // A login with no URIs omits the field entirely on the wire, so an
            // absent list is the empty list, not a decode failure.
            self.uris = try c.decodeIfPresent([URI].self, forKey: .uris)
                ?? c.decodeIfPresent([URI].self, forKey: .urisP) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(username, forKey: .username)
            try c.encodeIfPresent(password, forKey: .password)
            try c.encodeIfPresent(totp, forKey: .totp)
            try c.encode(uris, forKey: .uris)
        }
    }

    struct Card: Sendable, Codable, Hashable {
        let cardholderName: String?
        let brand: String?
        let number: String?
        let expMonth: String?
        let expYear: String?
        let code: String?

        init(
            cardholderName: String? = nil, brand: String? = nil, number: String? = nil,
            expMonth: String? = nil, expYear: String? = nil, code: String? = nil
        ) {
            self.cardholderName = cardholderName
            self.brand = brand
            self.number = number
            self.expMonth = expMonth
            self.expYear = expYear
            self.code = code
        }

        enum CodingKeys: String, CodingKey {
            case cardholderName, brand, number, expMonth, expYear, code
            case cardholderNameP = "CardholderName", brandP = "Brand", numberP = "Number"
            case expMonthP = "ExpMonth", expYearP = "ExpYear", codeP = "Code"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func str(_ camel: CodingKeys, _ pascal: CodingKeys) throws -> String? {
                try c.decodeIfPresent(String.self, forKey: camel)
                    ?? c.decodeIfPresent(String.self, forKey: pascal)
            }
            self.cardholderName = try str(.cardholderName, .cardholderNameP)
            self.brand = try str(.brand, .brandP)
            self.number = try str(.number, .numberP)
            self.expMonth = try str(.expMonth, .expMonthP)
            self.expYear = try str(.expYear, .expYearP)
            self.code = try str(.code, .codeP)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(cardholderName, forKey: .cardholderName)
            try c.encodeIfPresent(brand, forKey: .brand)
            try c.encodeIfPresent(number, forKey: .number)
            try c.encodeIfPresent(expMonth, forKey: .expMonth)
            try c.encodeIfPresent(expYear, forKey: .expYear)
            try c.encodeIfPresent(code, forKey: .code)
        }
    }

    struct Identity: Sendable, Codable, Hashable {
        let title: String?
        let firstName: String?
        let lastName: String?
        let email: String?
        let phone: String?

        init(
            title: String? = nil, firstName: String? = nil, lastName: String? = nil,
            email: String? = nil, phone: String? = nil
        ) {
            self.title = title
            self.firstName = firstName
            self.lastName = lastName
            self.email = email
            self.phone = phone
        }

        enum CodingKeys: String, CodingKey {
            case title, firstName, lastName, email, phone
            case titleP = "Title", firstNameP = "FirstName", lastNameP = "LastName"
            case emailP = "Email", phoneP = "Phone"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func str(_ camel: CodingKeys, _ pascal: CodingKeys) throws -> String? {
                try c.decodeIfPresent(String.self, forKey: camel)
                    ?? c.decodeIfPresent(String.self, forKey: pascal)
            }
            self.title = try str(.title, .titleP)
            self.firstName = try str(.firstName, .firstNameP)
            self.lastName = try str(.lastName, .lastNameP)
            self.email = try str(.email, .emailP)
            self.phone = try str(.phone, .phoneP)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(title, forKey: .title)
            try c.encodeIfPresent(firstName, forKey: .firstName)
            try c.encodeIfPresent(lastName, forKey: .lastName)
            try c.encodeIfPresent(email, forKey: .email)
            try c.encodeIfPresent(phone, forKey: .phone)
        }
    }

    // Wire keys are PascalCase from the API and lowerCamel from some proxies;
    // both are accepted. Persisted snapshots use the explicit lowerCamel form
    // this type encodes to, so a reload round-trips through the same keys.
    /// The identifier keys need three spellings, not two. A `CodingKey` derived
    /// from a Swift property spells these `organizationID` / `folderID` with a
    /// capital D, which is neither wire form: the server sends PascalCase
    /// `FolderId` or lowerCamel `folderId`. Accepting only the first two
    /// silently dropped folder and organization membership on a camelCase
    /// server — items still decrypted, but every one of them looked unfiled.
    enum CodingKeys: String, CodingKey {
        case id, type, organizationID, collectionIds, folderID, favorite, revisionDate
        case creationDate, deletedDate, archivedDate, key, reprompt
        case edit, viewPassword, permissions, passwordHistory
        case name, notes, login, card, identity, fields
        case idP = "Id", typeP = "Type", organizationIDP = "OrganizationId"
        case collectionIdsP = "CollectionIds", folderIDP = "FolderId"
        case favoriteP = "Favorite", revisionDateP = "RevisionDate"
        case creationDateP = "CreationDate", deletedDateP = "DeletedDate"
        case archivedDateP = "ArchivedDate", keyP = "Key", repromptP = "Reprompt"
        case editP = "Edit", viewPasswordP = "ViewPassword", permissionsP = "Permissions"
        case passwordHistoryP = "PasswordHistory"
        case nameP = "Name", notesP = "Notes", loginP = "Login", cardP = "Card", identityP = "Identity"
        case fieldsP = "Fields"
        case organizationIDWire = "organizationId", folderIDWire = "folderId"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ camel: CodingKeys, _ pascal: CodingKeys) throws -> String? {
            try c.decodeIfPresent(String.self, forKey: camel)
                ?? c.decodeIfPresent(String.self, forKey: pascal)
        }
        func date(_ camel: CodingKeys, _ pascal: CodingKeys) throws -> Date? {
            guard let raw = try str(camel, pascal) else { return nil }
            return Self.parseWireDate(raw)
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
        // A present type is preserved exactly, even one this build does not
        // know. Only a missing type degrades, to the response-model default.
        self.type = rawType.map(ItemType.init(rawValue:)) ?? .secureNote

        self.organizationID = try str(.organizationID, .organizationIDP)
            ?? c.decodeIfPresent(String.self, forKey: .organizationIDWire)
        self.collectionIds = try c.decodeIfPresent([String].self, forKey: .collectionIds)
            ?? c.decodeIfPresent([String].self, forKey: .collectionIdsP) ?? []
        self.folderID = try str(.folderID, .folderIDP)
            ?? c.decodeIfPresent(String.self, forKey: .folderIDWire)
        self.favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite)
            ?? c.decodeIfPresent(Bool.self, forKey: .favoriteP) ?? false

        if let date = try date(.revisionDate, .revisionDateP) {
            self.revisionDate = date
        } else {
            self.revisionDate = Date(timeIntervalSince1970: 0)
        }
        self.creationDate = try date(.creationDate, .creationDateP)
        self.deletedDate = try date(.deletedDate, .deletedDateP)
        self.archivedDate = try date(.archivedDate, .archivedDateP)

        self.key = try str(.key, .keyP)
        self.reprompt = try c.decodeIfPresent(Int.self, forKey: .reprompt)
            ?? c.decodeIfPresent(Int.self, forKey: .repromptP)
        self.edit = try c.decodeIfPresent(Bool.self, forKey: .edit)
            ?? c.decodeIfPresent(Bool.self, forKey: .editP)
        self.viewPassword = try c.decodeIfPresent(Bool.self, forKey: .viewPassword)
            ?? c.decodeIfPresent(Bool.self, forKey: .viewPasswordP)
        self.permissions = try c.decodeIfPresent(Permissions.self, forKey: .permissions)
            ?? c.decodeIfPresent(Permissions.self, forKey: .permissionsP)
        self.passwordHistory = try c.decodeIfPresent([PasswordHistoryEntry].self, forKey: .passwordHistory)
            ?? c.decodeIfPresent([PasswordHistoryEntry].self, forKey: .passwordHistoryP) ?? []

        self.name = try str(.name, .nameP)
        self.notes = try str(.notes, .notesP)
        self.login = try c.decodeIfPresent(Login.self, forKey: .login)
            ?? c.decodeIfPresent(Login.self, forKey: .loginP)
        self.card = try c.decodeIfPresent(Card.self, forKey: .card)
            ?? c.decodeIfPresent(Card.self, forKey: .cardP)
        self.identity = try c.decodeIfPresent(Identity.self, forKey: .identity)
            ?? c.decodeIfPresent(Identity.self, forKey: .identityP)
        self.fields = try c.decodeIfPresent([CustomField].self, forKey: .fields)
            ?? c.decodeIfPresent([CustomField].self, forKey: .fieldsP) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(organizationID, forKey: .organizationID)
        try c.encode(collectionIds, forKey: .collectionIds)
        try c.encodeIfPresent(folderID, forKey: .folderID)
        try c.encode(favorite, forKey: .favorite)
        try c.encode(Self.wireDateString(revisionDate), forKey: .revisionDate)
        if let creationDate { try c.encode(Self.wireDateString(creationDate), forKey: .creationDate) }
        if let deletedDate { try c.encode(Self.wireDateString(deletedDate), forKey: .deletedDate) }
        if let archivedDate { try c.encode(Self.wireDateString(archivedDate), forKey: .archivedDate) }
        try c.encodeIfPresent(key, forKey: .key)
        try c.encodeIfPresent(reprompt, forKey: .reprompt)
        try c.encodeIfPresent(edit, forKey: .edit)
        try c.encodeIfPresent(viewPassword, forKey: .viewPassword)
        try c.encodeIfPresent(permissions, forKey: .permissions)
        try c.encode(passwordHistory, forKey: .passwordHistory)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(login, forKey: .login)
        try c.encodeIfPresent(card, forKey: .card)
        try c.encodeIfPresent(identity, forKey: .identity)
        try c.encode(fields, forKey: .fields)
    }

    /// Direct memberwise construction, used by tests and by the write path when
    /// building a cipher to persist alongside its server round trip.
    init(
        id: String,
        type: ItemType,
        organizationID: String? = nil,
        collectionIds: [String] = [],
        folderID: String? = nil,
        favorite: Bool = false,
        revisionDate: Date,
        creationDate: Date? = nil,
        deletedDate: Date? = nil,
        archivedDate: Date? = nil,
        key: String? = nil,
        reprompt: Int? = nil,
        edit: Bool? = nil,
        viewPassword: Bool? = nil,
        permissions: Permissions? = nil,
        passwordHistory: [PasswordHistoryEntry] = [],
        name: String?,
        notes: String? = nil,
        login: Login? = nil,
        card: Card? = nil,
        identity: Identity? = nil,
        fields: [CustomField] = []
    ) {
        self.id = id
        self.type = type
        self.organizationID = organizationID
        self.collectionIds = collectionIds
        self.folderID = folderID
        self.favorite = favorite
        self.revisionDate = revisionDate
        self.creationDate = creationDate
        self.deletedDate = deletedDate
        self.archivedDate = archivedDate
        self.key = key
        self.reprompt = reprompt
        self.edit = edit
        self.viewPassword = viewPassword
        self.permissions = permissions
        self.passwordHistory = passwordHistory
        self.name = name
        self.notes = notes
        self.login = login
        self.card = card
        self.identity = identity
        self.fields = fields
    }

    /// A fresh formatter per call: `ISO8601DateFormatter` is a reference type and
    /// not `Sendable`, so it cannot be a shared static under Swift 6 strict
    /// concurrency, and date coding is not hot enough to need caching.
    private static func fractionalFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    /// Parses a wire date. `ISO8601DateFormatter` accepts exactly three
    /// fractional digits, but real servers emit none (plain seconds) or six
    /// (microseconds), so over-precise output is trimmed to milliseconds
    /// before the fractional parse.
    static func parseWireDate(_ raw: String) -> Date? {
        if let date = fractionalFormatter().date(from: raw) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) {
            return date
        }
        if let range = raw.range(of: #"\.\d{4,}"#, options: .regularExpression) {
            let trimmed = raw.replacingCharacters(
                in: range,
                with: String(raw[range].prefix(4))
            )
            return fractionalFormatter().date(from: trimmed)
        }
        return nil
    }

    static func wireDateString(_ date: Date) -> String {
        fractionalFormatter().string(from: date)
    }
}
