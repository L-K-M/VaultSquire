import Foundation

/// A scheme+host+port origin. Redirects and requests are constrained to the
/// origin (and base path) approved at configuration time; a discovered
/// cross-origin service is a new endpoint requiring approval, never a redirect
/// exception.
struct VaultwardenOrigin: Hashable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    /// Whether a redirect target stays within this origin over HTTPS. Host
    /// comparison is case-insensitive; scheme must remain https so an
    /// https->http downgrade is refused.
    func permitsRedirect(to url: URL, withinBasePath basePath: String) -> Bool {
        guard let targetScheme = url.scheme?.lowercased(), targetScheme == "https",
              scheme == "https",
              let targetHost = url.host?.lowercased(), targetHost == host.lowercased(),
              (url.port ?? 443) == port else {
            return false
        }

        return Self.path(url).hasPrefix(basePath)
    }

    static func path(_ url: URL) -> String {
        url.path.isEmpty ? "/" : url.path
    }
}

enum VaultwardenEnvironmentError: Error, Equatable, Sendable {
    case invalidURL
    case schemeNotHTTPS
    case userInfoNotAllowed
    case queryNotAllowed
    case fragmentNotAllowed
    case unsupportedScheme
}

/// Resolves the configured base URL into the Vaultwarden service URLs and
/// enforces the base-URL policy: preserve the port and path prefix, normalize
/// only trailing slashes, and reject userinfo, query, fragment, and non-HTTPS
/// (outside an explicit development-only loopback).
struct VaultwardenEnvironment: Hashable, Sendable {
    let base: URL
    let origin: VaultwardenOrigin
    /// The configured path prefix with no trailing slash (empty for a
    /// root-hosted server). Service paths and the redirect base path derive
    /// from it, so a reverse-proxied `/vault` prefix is preserved.
    let basePathPrefix: String

    var apiURL: URL { appending("api") }
    var identityURL: URL { appending("identity") }
    var iconsURL: URL { appending("icons") }
    var notificationsURL: URL { appending("notifications") }
    var eventsURL: URL { appending("events") }

    /// The path all redirects and requests must stay within. Root-hosted
    /// servers use "/"; a prefixed server uses "<prefix>/".
    var redirectBasePath: String {
        basePathPrefix.isEmpty ? "/" : basePathPrefix + "/"
    }

    /// Parses a user-entered base URL. `allowInsecureLoopback` enables the
    /// documented development-only exception for http on a loopback host.
    init(configuredURL raw: String, allowInsecureLoopback: Bool = false) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() else {
            throw VaultwardenEnvironmentError.invalidURL
        }
        guard scheme == "https" || scheme == "http" else {
            throw VaultwardenEnvironmentError.unsupportedScheme
        }
        guard components.user == nil, components.password == nil else {
            throw VaultwardenEnvironmentError.userInfoNotAllowed
        }
        guard components.query == nil else {
            throw VaultwardenEnvironmentError.queryNotAllowed
        }
        guard components.fragment == nil else {
            throw VaultwardenEnvironmentError.fragmentNotAllowed
        }
        guard let host = components.host, !host.isEmpty else {
            throw VaultwardenEnvironmentError.invalidURL
        }

        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        if scheme != "https" {
            guard allowInsecureLoopback, isLoopback else {
                throw VaultwardenEnvironmentError.schemeNotHTTPS
            }
        }

        // Preserve the path prefix; drop only trailing slashes so composing
        // service URLs never produces a double slash.
        var path = components.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path == "/" {
            path = ""
        }
        components.path = path
        components.scheme = scheme

        guard let normalized = components.url else {
            throw VaultwardenEnvironmentError.invalidURL
        }

        let port = components.port ?? (scheme == "https" ? 443 : 80)
        self.base = normalized
        self.basePathPrefix = path
        self.origin = VaultwardenOrigin(scheme: scheme, host: host.lowercased(), port: port)
    }

    private func appending(_ service: String) -> URL {
        base.appendingPathComponent(service)
    }
}
