import Foundation

enum VaultwardenWriteError: Error, Equatable, Sendable {
    case sessionExpired
    case transient
    /// A field could not be encrypted (invalid key material).
    case encryptionFailed
    /// The server answered outside the success range, carrying its status and
    /// its own message.
    ///
    /// Both, because without them a rejected write is undiagnosable: every
    /// status from 400 to 500 arrived as one sentence with no detail, so a
    /// malformed request body and a server fault and a permission problem
    /// were indistinguishable to the user and to whoever they reported it to.
    /// The message comes from `VaultwardenErrorDecoder.safeMessage`, which the
    /// login path already shows for the same reason; the server's validation
    /// errors name fields, and the field values it was sent are EncStrings, so
    /// echoing them back cannot disclose vault plaintext.
    /// `serverMessage` is nil when the server said nothing usable, rather than
    /// carrying a generic restatement of the status the caller already has.
    case rejected(status: Int, serverMessage: String?)
    /// Refused here, before any request was built or sent — a missing item
    /// identifier, a cipher the snapshot does not hold, one the server marked
    /// read-only, trashed or archived, or a mutation this provider does not
    /// support.
    ///
    /// Distinct from `rejected` because they were the same case, and so an
    /// action this app declined locally told the user "the server rejected the
    /// change" about a server that had never been asked.
    case notPermitted
    /// The item changed on the server since the client's last sync: the
    /// revision precondition failed. The client must reconcile with an
    /// authoritative read before any retry — a blind retry would overwrite
    /// the concurrent edit.
    case conflict
}

/// Builds and sends Vaultwarden cipher mutations. Every user-authored field is
/// encrypted with the cipher's own key — its per-item key when it carries one,
/// else the account key for its scope — into the canonical type-2 EncString
/// before it is placed in the request body, so no plaintext field ever leaves
/// the device.
///
/// A cipher PUT is a full-object replacement, so an update is built from the
/// stored cipher: everything the edit does not touch is passed back verbatim
/// (the per-item key, password history, reprompt flag, custom fields, folder,
/// collection, and organization membership), and the last-known revision date
/// is sent as the concurrency precondition. Omitting any of those silently
/// resets it server-side — a wiped password history or reprompt flag is
/// exactly the silent data loss the write contract exists to prevent. Only
/// login items are written in this slice; other types stay read-only until
/// their write contract is proven.
struct VaultwardenWriteService: Sendable {
    let transport: VaultwardenTransport
    /// The API base approved at login (".../api"). When absent the API URL is
    /// derived from the configured base, which is only correct for same-origin
    /// servers.
    var apiBaseURL: URL? = nil

    private var apiBase: URL {
        apiBaseURL ?? transport.environment.apiURL
    }

    /// Creates a login cipher in the personal vault. `POST /api/ciphers`.
    func createLogin(
        draft: VaultItemDraft,
        userKey: VaultwardenSymmetricKey,
        accessToken: String
    ) async -> Result<Void, VaultwardenWriteError> {
        let body: Data
        do {
            body = try encodeBody(draft: draft, writeKey: userKey)
        } catch {
            return .failure(.encryptionFailed)
        }
        let url = apiBase.appendingPathComponent("ciphers")
        return await send(.post, url: url, body: body, accessToken: accessToken)
    }

    /// Updates a login cipher. `PUT /api/ciphers/{id}`.
    ///
    /// `preserved` is the cipher as the client last synced it. Its opaque and
    /// server-owned fields go back byte-identical: the item key, password
    /// history, reprompt flag, custom fields, folder, collections, and
    /// organization are all pass-through, and its revision date becomes the
    /// `lastKnownRevisionDate` precondition so a concurrent edit the client
    /// already knows about is answered with a conflict instead of being
    /// silently overwritten.
    func updateLogin(
        cipherID: String,
        draft: VaultItemDraft,
        writeKey: VaultwardenSymmetricKey,
        accessToken: String,
        preserved: VaultwardenCipherModel
    ) async -> Result<Void, VaultwardenWriteError> {
        let body: Data
        do {
            body = try encodeBody(
                draft: draft,
                writeKey: writeKey,
                preserved: preserved
            )
        } catch {
            return .failure(.encryptionFailed)
        }
        let url = apiBase
            .appendingPathComponent("ciphers")
            .appendingPathComponent(cipherID)
        return await send(.put, url: url, body: body, accessToken: accessToken)
    }

    /// Archives a cipher where the server supports per-user archiving.
    /// `PUT /api/ciphers/{id}/archive`. The dedicated route carries no item
    /// content, so a lost race can cost at most the flag, never item data.
    func archive(
        cipherID: String,
        accessToken: String
    ) async -> Result<Void, VaultwardenWriteError> {
        let url = apiBase
            .appendingPathComponent("ciphers")
            .appendingPathComponent(cipherID)
            .appendingPathComponent("archive")
        return await send(.put, url: url, body: Data("{}".utf8), accessToken: accessToken)
    }

    // MARK: - Private

    private func send(
        _ method: VaultwardenTransport.Method,
        url: URL,
        body: Data,
        accessToken: String
    ) async -> Result<Void, VaultwardenWriteError> {
        let response: VaultwardenHTTPResponse
        do {
            response = try await transport.send(method, url: url, body: .json(body), bearer: accessToken)
        } catch {
            return .failure(.transient)
        }
        if response.status == 401 { return .failure(.sessionExpired) }
        // A revision-precondition failure surfaces as a conflict, never as a
        // generic rejection the caller might blindly retry.
        if response.status == 409 || response.status == 412 { return .failure(.conflict) }
        guard (200..<300).contains(response.status) else {
            // The server's own account of what was wrong, decoded through the
            // same shapes the login path reads. A 400 on a cipher write is
            // almost always the body's shape, and the server names the field.
            let body = try? JSONDecoder().decode(
                VaultwardenErrorBody.self, from: response.body
            )
            // `detail` rather than `safeMessage`: this path reports the status
            // itself, and `safeMessage` answers a bodyless response with a
            // sentence naming that same status, which would render it twice.
            // Asking for the detail states the distinction structurally
            // instead of inferring it from what the decoder happened to say.
            return .failure(.rejected(
                status: response.status,
                serverMessage: VaultwardenErrorDecoder.detail(from: body)
            ))
        }
        return .success(())
    }

    /// Encodes the request body, encrypting every user-authored field under
    /// the cipher's own key. When `preserved` is present (an update), the
    /// cipher's opaque and server-owned fields pass through untouched:
    /// already-encrypted custom-field EncStrings, the item key, password
    /// history, the reprompt flag, folder, collection and organization
    /// membership, and the revision precondition.
    func encodeBody(
        draft: VaultItemDraft,
        writeKey: VaultwardenSymmetricKey,
        preserved: VaultwardenCipherModel? = nil
    ) throws -> Data {
        func enc(_ value: String) throws -> String? {
            guard !value.isEmpty else { return nil }
            return try VaultwardenCipher.encryptToType2(Data(value.utf8), key: writeKey)
        }

        let uris = try draft.websites
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { try VaultwardenCipher.encryptToType2(Data($0.utf8), key: writeKey) }

        let body = CipherRequestBody(
            type: 1,
            name: try enc(draft.title) ?? "",
            notes: try enc(draft.notes),
            favorite: draft.favorite,
            folderID: preserved?.folderID,
            organizationID: preserved?.organizationID,
            collectionIds: preserved.flatMap {
                $0.collectionIds.isEmpty ? nil : $0.collectionIds
            },
            fields: preserved.flatMap {
                $0.fields.isEmpty ? nil : $0.fields.map {
                    CipherRequestBody.Field(type: $0.type, name: $0.name, value: $0.value)
                }
            },
            passwordHistory: preserved.flatMap {
                $0.passwordHistory.isEmpty ? nil : $0.passwordHistory.map {
                    CipherRequestBody.PasswordHistory(
                        password: $0.password,
                        lastUsedDate: $0.lastUsedDate.map(VaultwardenCipherModel.wireDateString)
                    )
                }
            },
            reprompt: preserved?.reprompt,
            key: preserved?.key,
            lastKnownRevisionDate: preserved.map {
                VaultwardenCipherModel.wireDateString($0.revisionDate)
            },
            login: CipherRequestBody.Login(
                username: try enc(draft.username),
                password: try enc(draft.password),
                totp: try enc(draft.totp),
                uris: uris.map { CipherRequestBody.Login.URI(uri: $0) }
            )
        )
        return try JSONEncoder().encode(body)
    }

    /// The `POST`/`PUT /api/ciphers` request shape. Edited field values are
    /// freshly encrypted EncStrings; preserved values are the existing ones
    /// verbatim. `nil` fields are omitted so the server keeps its defaults.
    /// Encoded with the server's PascalCase keys except the documented
    /// lowerCamel concurrency precondition.
    struct CipherRequestBody: Encodable {
        let type: Int
        let name: String
        let notes: String?
        let favorite: Bool
        let folderID: String?
        let organizationID: String?
        let collectionIds: [String]?
        let fields: [Field]?
        let passwordHistory: [PasswordHistory]?
        let reprompt: Int?
        /// The per-item cipher key, passed through untouched when the cipher
        /// carries one. Edited fields are encrypted under this same key, so
        /// the item never silently changes key hierarchy on edit.
        let key: String?
        /// The concurrency precondition: the revision date the client's edit
        /// is based on. The server answers a mismatch with a conflict status
        /// instead of silently taking the later write over a concurrent edit.
        let lastKnownRevisionDate: String?
        let login: Login

        /// A pass-through custom field: values are the existing EncStrings.
        struct Field: Encodable {
            let type: Int
            let name: String?
            let value: String?

            enum CodingKeys: String, CodingKey { case type, name, value }
        }

        /// A pass-through password-history entry: the previous password stays
        /// as its existing EncString.
        struct PasswordHistory: Encodable {
            let password: String?
            let lastUsedDate: String?

            enum CodingKeys: String, CodingKey { case password, lastUsedDate }
        }

        struct Login: Encodable {
            let username: String?
            let password: String?
            let totp: String?
            let uris: [URI]

            struct URI: Encodable {
                let uri: String

                enum CodingKeys: String, CodingKey { case uri }
            }

            enum CodingKeys: String, CodingKey { case username, password, totp, uris }
        }

        // lowerCamel, matching what `VaultwardenCipherModel` treats as the
        // canonical wire form and what it encodes to itself. This used to be
        // PascalCase throughout, which a camelCase server does not recognise —
        // so `name` and `type` arrived absent, the required fields were
        // missing, and every write came back 400. The reader was taught about
        // camelCase servers when folder and organization membership silently
        // vanished on one; the writer was never brought along, and its tests
        // asserted the PascalCase it sent against a fake transport, so nothing
        // caught the disagreement.
        //
        // Spelled out rather than derived, and deliberately so for the two
        // identifiers: a `CodingKey` taken from the Swift property gives
        // `folderID` and `organizationID` with a capital D, which is neither
        // wire form. That is the exact mistake the reader documents having
        // made.
        enum CodingKeys: String, CodingKey {
            case type
            case name
            case notes
            case favorite
            case folderID = "folderId"
            case organizationID = "organizationId"
            case collectionIds
            case fields
            case passwordHistory
            case reprompt
            case key
            case lastKnownRevisionDate
            case login
        }
    }
}
