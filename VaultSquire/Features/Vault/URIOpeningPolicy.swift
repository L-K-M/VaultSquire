import Foundation

/// The validated form of a vault URI that may leave the app: the parsed URL
/// and the exact scheme and host the user is shown before it is opened.
struct URIOpeningDecision: Equatable, Sendable {
    let url: URL
    /// The effective scheme and host, rendered for the confirmation prompt,
    /// e.g. `https://accounts.example.com:8443`. This is what the user must
    /// recognize; the raw vault text is displayed beside it but never alone
    /// decides where the system browser goes.
    let display: String

    var confirmationMessage: String {
        "VaultSquire will hand the complete saved address to your default browser: \(url.absoluteString). The destination resolves to \(display)."
    }
}

/// The URI-opening policy from `SECURITY_AND_TESTING.md`: only parsed `https`
/// and `http` destinations may leave the app, URL credentials are rejected,
/// and `file`, `javascript`, `data`, privileged system schemes, and arbitrary
/// custom schemes are blocked. The effective host and scheme are always shown
/// before the URL is handed to the system, and a URI is never executed through
/// a shell.
enum URIOpeningPolicy {
    /// Validates a vault-stored URI. Hand-typed entries often omit the scheme,
    /// so a bare host is promoted to `https://`; anything whose stated scheme
    /// is not exactly `https` or `http` is refused, as is a URL carrying user
    /// info, which can disguise the real host.
    static func decision(for raw: String) -> URIOpeningDecision? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.user == nil,
              components.password == nil,
              let host = components.host, !host.isEmpty,
              let url = components.url else {
            return nil
        }

        let defaultPort = scheme == "https" ? 443 : 80
        // The host renders lowercased, matching how the effective destination
        // is evaluated; the URL itself is opened exactly as parsed.
        let displayHost = host.lowercased()
        let display: String
        if let port = components.port, port != defaultPort {
            display = "\(scheme)://\(displayHost):\(port)"
        } else {
            display = "\(scheme)://\(displayHost)"
        }
        return URIOpeningDecision(url: url, display: display)
    }
}
