import Foundation

/// A completed HTTP response reduced to the fields the auth layer consumes.
struct VaultwardenHTTPResponse: Sendable {
    let status: Int
    private(set) var body: Data
    let retryAfter: TimeInterval?

    init(status: Int, body: Data, retryAfter: TimeInterval?) {
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
    }

    mutating func discardBody() {
        body.resetBytes(in: body.startIndex..<body.endIndex)
        body.removeAll(keepingCapacity: false)
    }
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
/// under the redirect policy, carries the fixed client headers, and stops the
/// transfer as soon as its response body reaches the safety bound.
struct VaultwardenTransport: Sendable {
    let environment: VaultwardenEnvironment
    /// Maximum response body size. The async byte stream is counted before each
    /// append so a hostile server cannot force full-body buffering first.
    let maximumResponseBytes: Int
    private let session: URLSession
    private let redirectPolicy: VaultwardenRedirectPolicy
    private let clientName: String
    private let userAgent: String

    init(
        environment: VaultwardenEnvironment,
        clientName: String = "VaultSquire",
        userAgent: String = "VaultSquire",
        // A full-vault sync response scales with item count and can pass 5 MB
        // on a large real vault, so the bound must sit well above any
        // legitimate sync while still capping an anomalous body.
        maximumResponseBytes: Int = 50 * 1024 * 1024,
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
        // Bound how long a request and its whole transfer may run, so a hung or
        // slow-trickling server cannot hold a connection open indefinitely.
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }

    enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
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
        bearer: String? = nil,
        responseLimit: Int? = nil
    ) async throws -> VaultwardenHTTPResponse {
        // Reject malformed destinations and credentials before constructing a
        // request that could transiently associate them in Foundation state.
        guard url.absoluteString.utf8.count <= 4_096,
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              Self.isValidBody(body),
              bearer.map(Self.isValidBearer) != false else {
            throw VaultwardenTransportError.transportFailure
        }
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

        let effectiveResponseLimit = responseLimit.map {
            min($0, maximumResponseBytes)
        } ?? maximumResponseBytes
        let requestScheme = url.scheme?.lowercased()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let encodedPath = components?.percentEncodedPath.lowercased() ?? ""
        let pathHasTraversal = components?.path
            .split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0 == "." || $0 == ".." }) ?? true
        let canonicalPath = components != nil
            && !encodedPath.contains("%25")
            && !encodedPath.contains("%2e")
            && !encodedPath.contains("%2f")
            && !encodedPath.contains("%5c")
            && !encodedPath.contains("\\")
            && !pathHasTraversal
        let sameDevelopmentOrigin = requestScheme == environment.origin.scheme
            && url.host?.lowercased() == environment.origin.host.lowercased()
            && (url.port ?? (requestScheme == "https" ? 443 : 80)) == environment.origin.port
        guard url.absoluteString.utf8.count <= 4_096,
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              canonicalPath,
              (requestScheme == "https" || sameDevelopmentOrigin),
              (request.httpBody?.count ?? 0) <= 2 * 1024 * 1024,
              maximumResponseBytes > 0,
              maximumResponseBytes <= 128 * 1024 * 1024,
              effectiveResponseLimit > 0 else {
            throw VaultwardenTransportError.transportFailure
        }

        do {
            let (bytes, response) = try await session.bytes(
                for: request,
                delegate: redirectPolicy
            )
            guard let http = response as? HTTPURLResponse else {
                throw VaultwardenTransportError.notHTTP
            }
            if response.expectedContentLength > Int64(effectiveResponseLimit) {
                throw VaultwardenTransportError.responseTooLarge
            }
            var data = Data()
            var transfersBody = false
            defer {
                if !transfersBody {
                    data.resetBytes(in: data.startIndex..<data.endIndex)
                }
            }
            if response.expectedContentLength > 0 {
                data.reserveCapacity(
                    min(Int(response.expectedContentLength), effectiveResponseLimit)
                )
            }
            for try await byte in bytes {
                guard data.count < effectiveResponseLimit else {
                    throw VaultwardenTransportError.responseTooLarge
                }
                data.append(byte)
            }

            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After"))
                .flatMap(Self.parseRetryAfter)
            let result = VaultwardenHTTPResponse(
                status: http.statusCode,
                body: data,
                retryAfter: retryAfter
            )
            transfersBody = true
            return result
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

    private static func isValidBody(_ body: Body) -> Bool {
        switch body {
        case .none:
            return true
        case .json(let data):
            return data.count <= 2 * 1024 * 1024
        case .form(let fields):
            guard fields.count <= 64 else { return false }
            var total = 0
            for (key, value) in fields {
                guard key.utf8.count <= 4_096,
                      value.utf8.count <= 64 * 1024 else {
                    return false
                }
                let (withKey, keyOverflow) = total.addingReportingOverflow(key.utf8.count)
                let (withValue, valueOverflow) = withKey.addingReportingOverflow(value.utf8.count)
                guard !keyOverflow, !valueOverflow,
                      withValue <= 1 * 1024 * 1024 else {
                    return false
                }
                total = withValue
            }
            return true
        }
    }

    private static func isValidBearer(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 16 * 1024
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    /// Retry-After is either delta-seconds or an HTTP date; only the numeric
    /// form is honored here (the date form falls back to jittered backoff).
    static func parseRetryAfter(_ value: String) -> TimeInterval? {
        guard value.utf8.count <= 64 else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({
                  $0.value >= 48 && $0.value <= 57
              }),
              let seconds = TimeInterval(trimmed),
              seconds.isFinite,
              seconds >= 0 else {
            return nil
        }

        // Cap at 24 hours: RFC 7231 lets a recipient ignore a far-future value,
        // so a hostile server cannot disable retries for an arbitrary span.
        return min(seconds, 86_400)
    }

    static func encodeForm(_ fields: [String: String]) -> String {
        // RFC 3986 unreserved characters only. CharacterSet.alphanumerics would
        // also leave non-ASCII letters (e.g. in a device name) unencoded, which
        // is invalid in application/x-www-form-urlencoded.
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
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
