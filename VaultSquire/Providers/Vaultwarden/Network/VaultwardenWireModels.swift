import Foundation

/// Accepts a JSON number that a server may encode either as a number or as a
/// decimal string, per the tolerant-decoding rule.
struct FlexibleInt: Hashable, Sendable, Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let stringValue = try? container.decode(String.self),
                  let parsed = Int(stringValue) {
            value = parsed
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an integer or decimal string."
            )
        }
    }
}

/// The `/api/config` discovery response. Only the fields VaultSquire consumes
/// are typed; the complete raw response is retained by the transport layer so
/// unknown fields are preserved.
struct VaultwardenConfig: Sendable, Decodable {
    /// Upstream compatibility version (e.g. "2026.6.0"); NOT the Vaultwarden
    /// release number.
    let version: String?
    let environment: Environment?

    struct Environment: Sendable, Decodable {
        let base: String?
        let api: String?
        let identity: String?
        let notifications: String?
    }
}

/// Prelogin KDF parameters. Identity responses use PascalCase; the tolerant
/// coding keys accept both casings.
struct VaultwardenPrelogin: Sendable, Decodable {
    let kdf: Int
    let kdfIterations: Int
    let kdfMemory: Int?
    let kdfParallelism: Int?

    enum CodingKeys: String, CodingKey {
        case kdf, kdfIterations, kdfMemory, kdfParallelism
        case kdfPascal = "Kdf"
        case kdfIterationsPascal = "KdfIterations"
        case kdfMemoryPascal = "KdfMemory"
        case kdfParallelismPascal = "KdfParallelism"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func flexibleInt(_ camel: CodingKeys, _ pascal: CodingKeys) throws -> Int? {
            if let value = try container.decodeIfPresent(FlexibleInt.self, forKey: camel) {
                return value.value
            }
            if let value = try container.decodeIfPresent(FlexibleInt.self, forKey: pascal) {
                return value.value
            }
            return nil
        }

        guard let kdf = try flexibleInt(.kdf, .kdfPascal) else {
            throw DecodingError.keyNotFound(
                CodingKeys.kdf,
                .init(codingPath: decoder.codingPath, debugDescription: "missing kdf")
            )
        }
        guard let iterations = try flexibleInt(.kdfIterations, .kdfIterationsPascal) else {
            throw DecodingError.keyNotFound(
                CodingKeys.kdfIterations,
                .init(codingPath: decoder.codingPath, debugDescription: "missing iterations")
            )
        }
        self.kdf = kdf
        self.kdfIterations = iterations
        self.kdfMemory = try flexibleInt(.kdfMemory, .kdfMemoryPascal)
        self.kdfParallelism = try flexibleInt(.kdfParallelism, .kdfParallelismPascal)
    }

    /// Maps the wire KDF fields onto the validated configuration from
    /// Workstream 3. Unknown algorithm identifiers fail closed.
    func configuration() throws -> VaultwardenKDFConfiguration {
        switch kdf {
        case 0:
            return .pbkdf2SHA256(iterations: kdfIterations)
        case 1:
            return .argon2id(
                iterations: kdfIterations,
                memoryMiB: kdfMemory ?? 0,
                parallelism: kdfParallelism ?? 0
            )
        default:
            throw VaultwardenCryptoError.invalidKDFParameters(.unknownAlgorithm)
        }
    }
}

/// The token-grant success response. Network-session fields plus the wrapped
/// key material used by later unlock. The raw response is retained upstream.
struct VaultwardenTokenResponse: Sendable, Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let tokenType: String?
    let key: String?
    let privateKey: String?
    let twoFactorToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case key = "Key"
        case privateKey = "PrivateKey"
        case twoFactorToken = "TwoFactorToken"
    }
}

/// The identity error / 2FA challenge body. All fields optional so a generic
/// 400 without challenge maps decodes cleanly.
struct VaultwardenErrorBody: Hashable, Sendable, Decodable {
    let error: String?
    let errorDescription: String?
    let message: String?
    let errorModel: ErrorModel?
    let validationErrors: [String: [String]]?
    /// Challenge maps: provider-id -> provider metadata. Present only when the
    /// server is signalling a 2FA requirement.
    let twoFactorProviders: [String]?
    let twoFactorProviders2: [String: TwoFactorProviderDetail]?

    struct ErrorModel: Hashable, Sendable, Decodable {
        let message: String?
    }

    struct TwoFactorProviderDetail: Hashable, Sendable, Decodable {
        // Provider-specific metadata is intentionally not interpreted here.
    }

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case message = "Message"
        case messageLower = "message"
        case errorModel = "ErrorModel"
        case validationErrors = "validationErrors"
        case validationErrorsPascal = "ValidationErrors"
        case twoFactorProviders = "TwoFactorProviders"
        case twoFactorProviders2 = "TwoFactorProviders2"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        errorDescription = try container.decodeIfPresent(String.self, forKey: .errorDescription)
        message = try container.decodeIfPresent(String.self, forKey: .message)
            ?? container.decodeIfPresent(String.self, forKey: .messageLower)
        errorModel = try container.decodeIfPresent(ErrorModel.self, forKey: .errorModel)
        validationErrors = try container.decodeIfPresent(
            [String: [String]].self, forKey: .validationErrors
        ) ?? container.decodeIfPresent(
            [String: [String]].self, forKey: .validationErrorsPascal
        )
        twoFactorProviders = try container.decodeIfPresent(
            [String].self, forKey: .twoFactorProviders
        )
        twoFactorProviders2 = try container.decodeIfPresent(
            [String: TwoFactorProviderDetail].self, forKey: .twoFactorProviders2
        )
    }

    var flattenedValidationErrors: String? {
        guard let validationErrors, !validationErrors.isEmpty else {
            return nil
        }

        let messages = validationErrors
            .sorted { $0.key < $1.key }
            .flatMap { $0.value }
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    /// The provider IDs the server offers, taken from either challenge map.
    var offeredProviderIDs: [Int] {
        if let map = twoFactorProviders2, !map.isEmpty {
            return map.keys.compactMap(Int.init).sorted()
        }
        return (twoFactorProviders ?? []).compactMap(Int.init).sorted()
    }

    var signalsTwoFactorChallenge: Bool {
        !offeredProviderIDs.isEmpty
    }
}
