import Foundation

/// A completed HTTP response reduced to the fields the auth layer consumes.
struct VaultwardenHTTPResponse: Sendable {
    let status: Int
    let body: Data
    let retryAfter: TimeInterval?
}

/// Refuses any redirect that leaves the approved origin or base path, or that
/// downgrades HTTPS. A discovered cross-origin service must be approved
/// separately; a redirect never expands the allowlist. Immutable and
/// therefore safe to hand to URLSession as a per-task delegate.
final class VaultwardenRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    let origin: VaultwardenOrigin
    let basePath: String

    init(origin: VaultwardenOrigin, basePath: String) {
        self.origin = origin
        self.basePath = basePath
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url,
              origin.permitsRedirect(to: url, withinBasePath: basePath) else {
            // Returning nil delivers the 3xx response as the result instead of
            // following it, so the caller sees a blocked redirect.
            return nil
        }

        return request
    }
}

enum VaultwardenTransportError: Error, Equatable, Sendable {
    case responseTooLarge
    case notHTTP
    case cancelled
    case transportFailure
}

/// Ephemeral, bounded HTTP transport for the Vaultwarden provider. The session
/// keeps no URL cache, cookie store, or credential store; every request runs
/// under the redirect policy, carries the fixed client headers, and has its
/// body size bounded before it is fully buffered.
struct VaultwardenTransport: Sendable {
    let environment: VaultwardenEnvironment
    /// Maximum response body accepted before the request is aborted. Auth and
    /// config responses are small; this is a safety bound, not a content size.
    let maximumResponseBytes: Int
    private let session: URLSession
    private let redirectPolicy: VaultwardenRedirectPolicy
    private let clientName: String
    private let userAgent: String

    init(
        environment: VaultwardenEnvironment,
        clientName: String = "VaultSquire",
        userAgent: String = "VaultSquire",
        maximumResponseBytes: Int = 5 * 1024 * 1024,
        session: URLSession? = nil
    ) {
        self.environment = environment
        self.maximumResponseBytes = maximumResponseBytes
        self.clientName = clientName
        self.userAgent = userAgent
        self.redirectPolicy = VaultwardenRedirectPolicy(
            origin: environment.origin,
            basePath: environment.redirectBasePath
        )
        self.session = session ?? Self.makeEphemeralSession()
    }

    static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }

    enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
    }

    enum Body: Sendable {
        case none
        case json(Data)
        case form([String: String])
    }

    /// Performs one request and returns the bounded response. `bearer` is
    /// attached as an Authorization header when present; the caller keeps the
    /// token in memory and never logs it.
    func send(
        _ method: Method,
        url: URL,
        body: Body = .none,
        bearer: String? = nil
    ) async throws -> VaultwardenHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        // Fixed client identification. Bitwarden-Client-Version is intentionally
        // omitted: it remains unset until a contract lane justifies an exact
        // compatibility declaration.
        request.setValue(clientName, forHTTPHeaderField: "Bitwarden-Client-Name")
        request.setValue("7", forHTTPHeaderField: "Device-Type")
        request.setValue("\(userAgent)/network", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == .get {
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        }
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }

        switch body {
        case .none:
            break
        case .json(let data):
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        case .form(let fields):
            request.setValue(
                "application/x-www-form-urlencoded",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = Data(Self.encodeForm(fields).utf8)
        }

        do {
            let (bytes, response) = try await session.bytes(
                for: request,
                delegate: redirectPolicy
            )
            guard let http = response as? HTTPURLResponse else {
                throw VaultwardenTransportError.notHTTP
            }

            var buffer = Data()
            buffer.reserveCapacity(min(maximumResponseBytes, 64 * 1024))
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count > maximumResponseBytes {
                    throw VaultwardenTransportError.responseTooLarge
                }
            }

            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After"))
                .flatMap(Self.parseRetryAfter)
            return VaultwardenHTTPResponse(
                status: http.statusCode,
                body: buffer,
                retryAfter: retryAfter
            )
        } catch let error as VaultwardenTransportError {
            throw error
        } catch is CancellationError {
            throw VaultwardenTransportError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw VaultwardenTransportError.cancelled
        } catch {
            // Never surface the underlying error object; it can carry the full
            // failing URL. The category alone crosses the boundary.
            throw VaultwardenTransportError.transportFailure
        }
    }

    /// Retry-After is either delta-seconds or an HTTP date; only the numeric
    /// form is honored here (the date form falls back to jittered backoff).
    static func parseRetryAfter(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let seconds = TimeInterval(trimmed), seconds >= 0 else {
            return nil
        }

        return seconds
    }

    static func encodeForm(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(
                    withAllowedCharacters: allowed
                ) ?? key
                let encodedValue = value.addingPercentEncoding(
                    withAllowedCharacters: allowed
                ) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }
}
