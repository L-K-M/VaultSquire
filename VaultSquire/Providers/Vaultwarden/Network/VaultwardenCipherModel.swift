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
        /// A discriminator this build does not understand. `rawType` below
        /// preserves the exact wire integer; this sentinel only prevents an
        /// unknown object from being interpreted as a nearby known shape.
        case unknown = -1
        case login = 1
        case secureNote = 2
        case card = 3
        case identity = 4
    }

    let id: String
    let type: ItemType
    /// Exact wire discriminator, including values unknown to this build.
    let rawType: Int
    /// The organization that owns this cipher, or nil for a personal item. A
    /// personal item decrypts under the user key; an organization item under
    /// that organization's key.
    let organizationID: String?
    let folderID: String?
    let favorite: Bool
    let revisionDate: Date
    /// Optional individual cipher key, wrapped under the owning user or
    /// organization key. When present every item field uses the unwrapped key;
    /// treating it as absent makes modern ciphers unreadable and makes writes
    /// destructive.
    let key: String?
    /// Effective permissions returned by the server. Personal ciphers omit
    /// these and retain full read permission; organization ciphers fail closed
    /// when a permission is absent.
    let edit: Bool
    let viewPassword: Bool
    let permissions: Permissions?
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

    struct Permissions: Sendable, Codable, Hashable {
        let delete: Bool?
        let restore: Bool?

        enum CodingKeys: String, CodingKey {
            case delete, restore
            case deleteP = "Delete", restoreP = "Restore"
        }

        init(delete: Bool? = nil, restore: Bool? = nil) {
            self.delete = delete
            self.restore = restore
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            delete = try c.decodeIfPresent(Bool.self, forKey: .delete)
                ?? c.decodeIfPresent(Bool.self, forKey: .deleteP)
            restore = try c.decodeIfPresent(Bool.self, forKey: .restore)
                ?? c.decodeIfPresent(Bool.self, forKey: .restoreP)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(delete, forKey: .delete)
            try c.encodeIfPresent(restore, forKey: .restore)
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
                ?? c.decodeIfPresent(Int.self, forKey: .typeP) ?? -1
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
        case id, type, organizationID, folderID, favorite, revisionDate
        case key, edit, viewPassword, permissions
        case name, notes, login, card, identity, fields
        case idP = "Id", typeP = "Type", organizationIDP = "OrganizationId"
        case folderIDP = "FolderId", favoriteP = "Favorite", revisionDateP = "RevisionDate"
        case keyP = "Key", editP = "Edit", viewPasswordP = "ViewPassword", permissionsP = "Permissions"
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

        guard let id = try str(.id, .idP) else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                .init(codingPath: decoder.codingPath, debugDescription: "missing cipher id")
            )
        }
        self.id = id

        let decodedRawType = try c.decodeIfPresent(Int.self, forKey: .type)
            ?? c.decodeIfPresent(Int.self, forKey: .typeP)
        self.rawType = decodedRawType ?? ItemType.unknown.rawValue
        self.type = decodedRawType.flatMap(ItemType.init(rawValue:)) ?? .unknown

        self.organizationID = try str(.organizationID, .organizationIDP)
            ?? c.decodeIfPresent(String.self, forKey: .organizationIDWire)
        self.folderID = try str(.folderID, .folderIDP)
            ?? c.decodeIfPresent(String.self, forKey: .folderIDWire)
        self.favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite)
            ?? c.decodeIfPresent(Bool.self, forKey: .favoriteP) ?? false

        guard let date = try Self.decodeDate(c, .revisionDate, .revisionDateP) else {
            throw DecodingError.keyNotFound(
                CodingKeys.revisionDate,
                .init(codingPath: decoder.codingPath, debugDescription: "missing or invalid revision date")
            )
        }
        self.revisionDate = date
        self.key = try str(.key, .keyP)
        let personal = organizationID == nil
        self.edit = try c.decodeIfPresent(Bool.self, forKey: .edit)
            ?? c.decodeIfPresent(Bool.self, forKey: .editP) ?? personal
        self.viewPassword = try c.decodeIfPresent(Bool.self, forKey: .viewPassword)
            ?? c.decodeIfPresent(Bool.self, forKey: .viewPasswordP) ?? personal
        self.permissions = try c.decodeIfPresent(Permissions.self, forKey: .permissions)
            ?? c.decodeIfPresent(Permissions.self, forKey: .permissionsP)

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
        try c.encode(rawType, forKey: .type)
        try c.encodeIfPresent(organizationID, forKey: .organizationID)
        try c.encodeIfPresent(folderID, forKey: .folderID)
        try c.encode(favorite, forKey: .favorite)
        try c.encode(Self.wireDateString(revisionDate), forKey: .revisionDate)
        try c.encodeIfPresent(key, forKey: .key)
        try c.encode(edit, forKey: .edit)
        try c.encode(viewPassword, forKey: .viewPassword)
        try c.encodeIfPresent(permissions, forKey: .permissions)
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
        folderID: String? = nil,
        favorite: Bool = false,
        revisionDate: Date,
        key: String? = nil,
        edit: Bool = true,
        viewPassword: Bool = true,
        permissions: Permissions? = nil,
        name: String?,
        notes: String? = nil,
        login: Login? = nil,
        card: Card? = nil,
        identity: Identity? = nil,
        fields: [CustomField] = []
    ) {
        self.id = id
        self.type = type
        self.rawType = type.rawValue
        self.organizationID = organizationID
        self.folderID = folderID
        self.favorite = favorite
        self.revisionDate = revisionDate
        self.key = key
        self.edit = edit
        self.viewPassword = viewPassword
        self.permissions = permissions
        self.name = name
        self.notes = notes
        self.login = login
        self.card = card
        self.identity = identity
        self.fields = fields
    }

    /// Validates allocation and identity bounds after decoding but before a
    /// snapshot is promoted or persisted. Encryption forms themselves stay
    /// opaque here so unknown ciphertext is preserved for a future build.
    var isStructurallyValid: Bool {
        guard !id.isEmpty, id.utf8.count <= 512,
              organizationID.map({ !$0.isEmpty && $0.utf8.count <= 512 }) != false,
              folderID.map({ !$0.isEmpty && $0.utf8.count <= 512 }) != false,
              revisionDate.timeIntervalSince1970.isFinite,
              fields.count <= 1_000,
              (login?.uris.count ?? 0) <= 1_000 else {
            return false
        }
        let encryptedValues: [String?] = [
            key, name, notes,
            login?.username, login?.password, login?.totp,
            card?.cardholderName, card?.brand, card?.number,
            card?.expMonth, card?.expYear, card?.code,
            identity?.title, identity?.firstName, identity?.lastName,
            identity?.email, identity?.phone,
        ] + (login?.uris.map(\.uri) ?? [])
          + fields.flatMap { [$0.name, $0.value] }
        return encryptedValues.allSatisfy { value in
            value.map { $0.utf8.count <= VaultwardenEncString.maximumSerializedBytes } != false
        }
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
        return parseWireDate(raw)
    }

    /// Parses a wire date. `ISO8601DateFormatter` accepts exactly three
    /// fractional digits, but real servers emit none (plain seconds) or six
    /// (microseconds), so over-precise output is trimmed to milliseconds
    /// before the fractional parse.
    static func parseWireDate(_ raw: String) -> Date? {
        guard raw.utf8.count <= 128,
              raw.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
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

    private static func wireDateString(_ date: Date) -> String {
        fractionalFormatter().string(from: date)
    }
}
