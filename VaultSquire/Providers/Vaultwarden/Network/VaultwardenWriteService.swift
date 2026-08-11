import Foundation

enum VaultwardenWriteError: Error, Equatable, Sendable {
    case sessionExpired
    case transient
    /// A field could not be encrypted (invalid key material).
    case encryptionFailed
    /// The server rejected the mutation.
    case rejected
    /// The server rejected the update because the item changed on the server
    /// since this client last saw it (the pinned server's
    /// `lastKnownRevisionDate` stale-write guard). The user must sync and
    /// review before saving again; a retry must never be blind.
    case conflict
}

/// Builds and sends Vaultwarden cipher mutations. Every user-authored field is
/// encrypted with the account's user key into the canonical type-2 EncString
/// before it is placed in the request body, so no plaintext field ever leaves
/// the device. Only personal-vault login items are written in this slice;
/// organization items are read-only until their write contract is proven.
struct VaultwardenWriteService: Sendable {
    let transport: VaultwardenTransport
    /// The API base approved at login (".../api"). When absent the API URL is
    /// derived from the configured base, which is only correct for same-origin
    /// servers.
    var apiBaseURL: URL? = nil

    private var apiBase: URL {
        apiBaseURL ?? transport.environment.apiURL
    }

    /// Creates a login cipher. `POST /api/ciphers`.
    func createLogin(
        draft: VaultItemDraft,
        userKey: VaultwardenSymmetricKey,
        accessToken: String
    ) async -> Result<Void, VaultwardenWriteError> {
        let body: Data
        do {
            body = try encodeBody(draft: draft, userKey: userKey)
        } catch {
            return .failure(.encryptionFailed)
        }
        let url = apiBase.appendingPathComponent("ciphers")
        return await send(.post, url: url, body: body, accessToken: accessToken)
    }

    /// Updates a login cipher. `PUT /api/ciphers/{id}`. The server replaces the
    /// cipher with this body, so the existing item's protected and opaque
    /// fields are passed through verbatim — folder, custom fields (already-
    /// encrypted EncStrings), master-password reprompt, and password history —
    /// and the item's revision date is sent as `LastKnownRevisionDate` so the
    /// server can reject a concurrent edit. Omitting any of them would
    /// silently wipe it on every edit.
    func updateLogin(
        cipherID: String,
        draft: VaultItemDraft,
        userKey: VaultwardenSymmetricKey,
        accessToken: String,
        existing: VaultwardenCipherModel? = nil
    ) async -> Result<Void, VaultwardenWriteError> {
        let body: Data
        do {
            body = try encodeBody(
                draft: draft,
                userKey: userKey,
                folderID: existing?.folderID,
                preservedFields: existing?.fields ?? [],
                preservedReprompt: existing?.reprompt,
                preservedPasswordHistory: existing?.passwordHistory ?? [],
                lastKnownRevisionDate: existing.map {
                    VaultwardenCipherModel.wireRevisionDate($0.revisionDate)
                }
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
    /// `PUT /api/ciphers/{id}/archive`.
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
        guard (200..<300).contains(response.status) else {
            if Self.isStaleRevisionRejection(response) {
                return .failure(.conflict)
            }
            return .failure(.rejected)
        }
        return .success(())
    }

    /// The pinned server (Vaultwarden 1.37.1,
    /// `src/api/core/ciphers.rs` `update_cipher_from_data`) rejects an update
    /// whose `LastKnownRevisionDate` is older than the stored revision with
    /// exactly this message. The message text is pinned protocol evidence;
    /// anything else on a 4xx stays a generic rejection.
    private static func isStaleRevisionRejection(_ response: VaultwardenHTTPResponse) -> Bool {
        guard let body = try? JSONDecoder().decode(
            VaultwardenErrorBody.self, from: response.body
        ), let message = body.message else {
            return false
        }
        return message.contains("out of date")
    }

    /// Encodes the request body, encrypting every user-authored field. The
    /// folder identifier and preserved custom fields are pass-through values
    /// from the existing cipher (a folder id is plaintext; field EncStrings
    /// stay encrypted), used by updates so a PUT never wipes them.
    func encodeBody(
        draft: VaultItemDraft,
        userKey: VaultwardenSymmetricKey,
        folderID: String? = nil,
        preservedFields: [VaultwardenCipherModel.CustomField] = [],
        preservedReprompt: Int? = nil,
        preservedPasswordHistory: [VaultwardenCipherModel.PasswordHistoryEntry] = [],
        lastKnownRevisionDate: String? = nil
    ) throws -> Data {
        func enc(_ value: String) throws -> String? {
            let trimmed = value
            guard !trimmed.isEmpty else { return nil }
            return try VaultwardenCipher.encryptToType2(Data(trimmed.utf8), key: userKey)
        }

        let uris = try draft.websites
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { try VaultwardenCipher.encryptToType2(Data($0.utf8), key: userKey) }

        let body = CipherRequestBody(
            type: 1,
            name: try enc(draft.title) ?? "",
            notes: try enc(draft.notes),
            favorite: draft.favorite,
            folderID: folderID,
            fields: preservedFields.isEmpty ? nil : preservedFields.map {
                CipherRequestBody.Field(type: $0.type, name: $0.name, value: $0.value)
            },
            login: CipherRequestBody.Login(
                username: try enc(draft.username),
                password: try enc(draft.password),
                totp: try enc(draft.totp),
                uris: uris.map { CipherRequestBody.Login.URI(uri: $0) }
            ),
            reprompt: preservedReprompt,
            passwordHistory: preservedPasswordHistory.isEmpty ? nil : preservedPasswordHistory.map {
                CipherRequestBody.PasswordHistoryEntry(
                    password: $0.password, lastUsedDate: $0.lastUsedDate
                )
            },
            lastKnownRevisionDate: lastKnownRevisionDate
        )
        return try JSONEncoder().encode(body)
    }

    /// The `POST`/`PUT /api/ciphers` request shape. Field values are already
    /// encrypted EncStrings; `nil` fields are omitted so the server keeps its
    /// defaults. Encoded with the server's PascalCase keys.
    struct CipherRequestBody: Encodable {
        let type: Int
        let name: String
        let notes: String?
        let favorite: Bool
        let folderID: String?
        let fields: [Field]?
        let login: Login
        /// The existing item's master-password reprompt flag (0/1). Sent on
        /// update so an edit never silently strips the protection; the pinned
        /// server resets `reprompt` to none when the field is absent.
        let reprompt: Int?
        /// The existing item's encrypted password-history entries, passed
        /// through verbatim on update; the pinned server replaces the stored
        /// history with whatever the body carries, so omitting it wipes it.
        let passwordHistory: [PasswordHistoryEntry]?
        /// The item's server revision date, sent on update so the server's
        /// stale-write guard rejects a concurrent edit instead of silently
        /// overwriting it.
        let lastKnownRevisionDate: String?

        /// A pass-through custom field: values are the existing EncStrings.
        struct Field: Encodable {
            let type: Int
            let name: String?
            let value: String?

            enum CodingKeys: String, CodingKey {
                case type = "Type"
                case name = "Name"
                case value = "Value"
            }
        }

        /// A pass-through password-history entry: opaque passthrough values,
        /// never re-encrypted or reformatted.
        struct PasswordHistoryEntry: Encodable {
            let password: String?
            let lastUsedDate: String?

            enum CodingKeys: String, CodingKey {
                case password = "Password"
                case lastUsedDate = "LastUsedDate"
            }
        }

        struct Login: Encodable {
            let username: String?
            let password: String?
            let totp: String?
            let uris: [URI]

            struct URI: Encodable {
                let uri: String

                enum CodingKeys: String, CodingKey { case uri = "Uri" }
            }

            enum CodingKeys: String, CodingKey {
                case username = "Username"
                case password = "Password"
                case totp = "Totp"
                case uris = "Uris"
            }
        }

        enum CodingKeys: String, CodingKey {
            case type = "Type"
            case name = "Name"
            case notes = "Notes"
            case favorite = "Favorite"
            case folderID = "FolderId"
            case fields = "Fields"
            case login = "Login"
            case reprompt = "Reprompt"
            case passwordHistory = "PasswordHistory"
            case lastKnownRevisionDate = "LastKnownRevisionDate"
        }
    }
}
