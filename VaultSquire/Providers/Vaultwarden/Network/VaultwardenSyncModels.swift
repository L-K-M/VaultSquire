import Foundation

/// The subset of `GET /api/sync` VaultSquire consumes, decoded tolerantly.
///
/// Every user-authored string field on the wire is a Vaultwarden EncString
/// (almost always the authenticated type-2 form); these models keep those
/// fields as their raw serialized strings and never decrypt here. Decryption
/// happens only at unlock, under the unwrapped user or organization key, in the
/// crypto layer. Unknown fields are ignored by `Decodable` but the raw sync
/// bytes are retained by the cache, so nothing understood-later is lost.
struct VaultwardenSyncResponse: Sendable, Decodable {
    let profile: Profile
    let folders: [Folder]
    let ciphers: [VaultwardenCipherModel]

    enum CodingKeys: String, CodingKey {
        case profile = "Profile"
        case profileLower = "profile"
        case folders = "Folders"
        case foldersLower = "folders"
        case ciphers = "Ciphers"
        case ciphersLower = "ciphers"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try Self.either(container, .profile, .profileLower)
        folders = try Self.eitherList(container, .folders, .foldersLower)
        ciphers = try Self.eitherList(container, .ciphers, .ciphersLower)
    }

    private static func either<T: Decodable>(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ pascal: CodingKeys,
        _ camel: CodingKeys
    ) throws -> T {
        if let value = try container.decodeIfPresent(T.self, forKey: pascal) {
            return value
        }
        return try container.decode(T.self, forKey: camel)
    }

    private static func eitherList<T: Decodable>(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ pascal: CodingKeys,
        _ camel: CodingKeys
    ) throws -> [T] {
        if let value = try container.decodeIfPresent([T].self, forKey: pascal) {
            return value
        }
        return try container.decodeIfPresent([T].self, forKey: camel) ?? []
    }

    /// The account profile: the wrapped user key, the wrapped RSA private key,
    /// and the organizations whose keys are RSA-wrapped for this user.
    struct Profile: Sendable, Decodable {
        let key: String?
        let privateKey: String?
        let organizations: [Organization]

        enum CodingKeys: String, CodingKey {
            case key = "Key", keyLower = "key"
            case privateKey = "PrivateKey", privateKeyLower = "privateKey"
            case organizations = "Organizations", organizationsLower = "organizations"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decodeIfPresent(String.self, forKey: .key)
                ?? c.decodeIfPresent(String.self, forKey: .keyLower)
            privateKey = try c.decodeIfPresent(String.self, forKey: .privateKey)
                ?? c.decodeIfPresent(String.self, forKey: .privateKeyLower)
            organizations = try c.decodeIfPresent([Organization].self, forKey: .organizations)
                ?? c.decodeIfPresent([Organization].self, forKey: .organizationsLower)
                ?? []
        }
    }

    struct Organization: Sendable, Decodable {
        let id: String
        let name: String?
        /// The organization key, RSA-wrapped for this user (an EncString of an
        /// asymmetric type). Unwrapped with the user's private key at unlock.
        let key: String

        enum CodingKeys: String, CodingKey {
            case id = "Id", idLower = "id"
            case name = "Name", nameLower = "name"
            case key = "Key", keyLower = "key"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id)
                ?? c.decode(String.self, forKey: .idLower)
            name = try c.decodeIfPresent(String.self, forKey: .name)
                ?? c.decodeIfPresent(String.self, forKey: .nameLower)
            key = try c.decodeIfPresent(String.self, forKey: .key)
                ?? c.decode(String.self, forKey: .keyLower)
        }
    }

    struct Folder: Sendable, Decodable {
        let id: String
        /// Folder name EncString, decrypted under the user key at unlock.
        let name: String

        enum CodingKeys: String, CodingKey {
            case id = "Id", idLower = "id"
            case name = "Name", nameLower = "name"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id)
                ?? c.decode(String.self, forKey: .idLower)
            name = try c.decodeIfPresent(String.self, forKey: .name)
                ?? c.decode(String.self, forKey: .nameLower)
        }
    }
}
