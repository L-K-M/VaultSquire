import Foundation
@testable import VaultSquire

/// A canned response for a stubbed route.
struct StubResponse: Sendable {
    var status: Int
    var body: Data
    var headers: [String: String]

    init(status: Int, body: Data = Data(), headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    static func json(_ status: Int, _ object: String, headers: [String: String] = [:]) -> StubResponse {
        StubResponse(status: status, body: Data(object.utf8), headers: headers)
    }
}

/// Records one request the transport sent, with its body decoded for assertions.
struct RecordedRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data

    var bodyString: String { String(decoding: body, as: UTF8.self) }

    /// Parses an application/x-www-form-urlencoded body into fields.
    var formFields: [String: String] {
        var fields: [String: String] = [:]
        for pair in bodyString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            // In application/x-www-form-urlencoded, "+" encodes a space.
            let key = parts[0].replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding ?? parts[0]
            let value = parts[1].replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding ?? parts[1]
            fields[key] = value
        }
        return fields
    }
}

/// Thread-safe stub server backing `StubURLProtocol`. A test installs route
/// handlers keyed by a path suffix and inspects the recorded requests.
final class StubServer: @unchecked Sendable {
    static let shared = StubServer()

    private let lock = NSLock()
    /// Per-suffix response queues; successive requests to a suffix consume the
    /// queue in registration order, with the last response sticky.
    private var queues: [String: [StubResponse]] = [:]
    private var cursors: [String: Int] = [:]
    private var recorded: [RecordedRequest] = []

    func reset() {
        lock.lock(); defer { lock.unlock() }
        queues.removeAll()
        cursors.removeAll()
        recorded.removeAll()
    }

    /// Registers a response for any request whose path ends with `suffix`.
    /// Registering the same suffix more than once queues the responses so a
    /// test can model a multi-step exchange (e.g. 2FA challenge then success).
    func on(_ suffix: String, respond response: StubResponse) {
        lock.lock(); defer { lock.unlock() }
        queues[suffix, default: []].append(response)
    }

    func response(for url: URL) -> StubResponse? {
        lock.lock(); defer { lock.unlock() }
        // Match the longest registered suffix so "/connect/token" wins over a
        // shorter accidental suffix match.
        let matches = queues.keys
            .filter { url.path.hasSuffix($0) }
            .sorted { $0.count > $1.count }
        guard let suffix = matches.first, let responses = queues[suffix] else {
            return nil
        }

        let index = cursors[suffix, default: 0]
        cursors[suffix] = index + 1
        return responses[min(index, responses.count - 1)]
    }

    func record(_ request: RecordedRequest) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
    }

    var requests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func lastRequest(pathSuffix: String) -> RecordedRequest? {
        lock.lock(); defer { lock.unlock() }
        return recorded.last { $0.url.path.hasSuffix(pathSuffix) }
    }
}

/// URLProtocol that serves `StubServer.shared`, so the transport can be driven
/// with synthetic responses and no sockets.
final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: request.url ?? URL(string: "about:blank")!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.readBody(request)
        )
        StubServer.shared.record(recorded)

        guard let url = request.url,
              let stub = StubServer.shared.response(for: url),
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: stub.status,
                  httpVersion: "HTTP/1.1",
                  headerFields: stub.headers
              ) else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }

        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

enum VaultwardenTestFactory {
    static func stubbedTransport(
        base: String = "https://vault.example.com"
    ) throws -> VaultwardenTransport {
        let environment = try VaultwardenEnvironment(configuredURL: base)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return VaultwardenTransport(environment: environment, session: session)
    }
}

/// Test policies that approve everything, isolating the flow logic from the
/// approval decisions (which are exercised separately).
struct ApproveAllKDFChangePolicy: VaultwardenKDFChangePolicy {
    func confirmChange(
        from last: VaultwardenKDFConfiguration?,
        to next: VaultwardenKDFConfiguration
    ) async -> VaultwardenKDFChangeDecision {
        .approve
    }
}

struct RejectAllKDFChangePolicy: VaultwardenKDFChangePolicy {
    func confirmChange(
        from last: VaultwardenKDFConfiguration?,
        to next: VaultwardenKDFConfiguration
    ) async -> VaultwardenKDFChangeDecision {
        .reject
    }
}

struct ApproveAllOriginPolicy: VaultwardenOriginApprovalPolicy {
    func approve(
        entered: VaultwardenOrigin,
        effectiveIdentity: VaultwardenOrigin,
        effectiveAPI: VaultwardenOrigin
    ) async -> Bool {
        true
    }
}

struct RejectAllOriginPolicy: VaultwardenOriginApprovalPolicy {
    func approve(
        entered: VaultwardenOrigin,
        effectiveIdentity: VaultwardenOrigin,
        effectiveAPI: VaultwardenOrigin
    ) async -> Bool {
        false
    }
}
