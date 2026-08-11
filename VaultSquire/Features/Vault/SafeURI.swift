import Foundation

/// Resolves a vault-entry URI into a safe, user-confirmable open target.
///
/// `SECURITY_AND_TESTING.md` § "URI Opening" permits only parsed `http`/`https`
/// destinations, requires the effective host and scheme to be shown before the
/// app hands off, and forbids `file`, `javascript`, `data`, privileged system
/// schemes, arbitrary custom schemes, and embedded URL credentials. A vault
/// entry is untrusted input — it may come from a shared org collection, a
/// hostile server, or a phishing entry — so this type is the one place that
/// decision is made, and the detail view refuses to render anything it rejects
/// as an openable link.
enum SafeURI {
    /// A resolved destination that is safe to offer the user, carrying the
    /// effective scheme and host to display before opening.
    struct Destination: Equatable, Sendable {
        let url: URL

        /// Lowercased scheme, e.g. "https". Never empty for a Destination.
        var scheme: String { url.scheme?.lowercased() ?? "" }
        /// The destination host, for the confirmation prompt. Never empty for a
        /// Destination.
        var host: String { url.host ?? "" }
    }

    /// Parses `raw` into a `Destination` only when it resolves to an `http(s)`
    /// URL with a non-empty host and no embedded credentials. A bare host such
    /// as `github.com` is treated as `https`. Returns `nil` for anything else —
    /// `file`/`javascript`/`data`/custom schemes, URL credentials, hostless, or
    /// unparseable input — so the caller renders it as inert text rather than a
    /// link.
    static func destination(for raw: String) -> Destination? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // If the input already carries a scheme, honor it and reject anything
        // that is not http/https. Otherwise treat the value as a bare host and
        // prefix https://. Detecting the scheme explicitly (rather than letting
        // URLComponents infer it) keeps `javascript:alert(1)` from being read as
        // a host and keeps `foo/bar:x` from being read as scheme `foo/bar`.
        let candidate: String
        if let scheme = explicitScheme(of: trimmed) {
            guard scheme == "http" || scheme == "https" else { return nil }
            candidate = trimmed
        } else {
            candidate = "https://\(trimmed)"
        }

        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              // Reject embedded credentials outright: the opener must never be
              // handed a URL carrying user info.
              components.user == nil, components.password == nil,
              let url = components.url else {
            return nil
        }

        return Destination(url: url)
    }

    /// Returns the lowercased scheme when `value` begins with a valid RFC 3986
    /// scheme (`ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )` followed by `:`),
    /// otherwise nil. A leading digit is not a valid scheme start, so `1.2.3.4`
    /// and `8080:foo` are treated as scheme-less.
    private static func explicitScheme(of value: String) -> String? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let prefix = value[value.startIndex..<colon]
        guard let first = prefix.first, first.isLetter else { return nil }
        guard prefix.allSatisfy({ character in
            character.isLetter || character.isNumber
                || character == "+" || character == "-" || character == "."
        }) else { return nil }
        return String(prefix).lowercased()
    }
}
