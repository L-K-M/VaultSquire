import Foundation

/// The non-secret visual identity of a row: the site the item belongs to, the
/// letter to draw when no artwork is available, and a colour derived from that
/// site so the same login always looks the same.
///
/// Everything here is derived from fields the row already shows — the item's
/// title and its website — so building it exposes nothing the list does not.
struct ItemIconIdentity: Equatable, Sendable {
    /// The lowercased host the item's first usable website points at, with any
    /// `www.` prefix dropped. Nil for every item without an `http(s)` URL,
    /// which is most non-logins and some logins.
    let host: String?
    /// The single character drawn when there is no artwork. Never empty.
    let monogram: String
    /// A stable hue in `0..<1`. Derived from the host when there is one and the
    /// title otherwise, by a hash written out here rather than `hashValue`,
    /// which is seeded per process — a row would otherwise change colour on
    /// every launch.
    let hue: Double

    init(title: String, websites: [String]) {
        let host = Self.host(from: websites)
        self.host = host
        self.monogram = Self.monogram(host: host, title: title)
        self.hue = Self.hue(seed: host ?? title.lowercased())
    }

    /// The site's own conventional icon location.
    ///
    /// Deliberately the site's own origin. An icon aggregator would be handed
    /// the list of sites in the vault one request at a time, which is precisely
    /// the inventory this app exists to keep private; asking each site directly
    /// tells that site only the single thing it already knows.
    var iconURL: URL? {
        host.flatMap(Self.iconURL(forHost:))
    }

    /// The one place the icon address is built, so the "site's own origin, over
    /// TLS, never an aggregator" rule has a single site to hold it.
    static func iconURL(forHost host: String) -> URL? {
        let normalized = host.lowercased()
        guard isSafeIconHost(normalized) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = normalized
        components.path = "/favicon.ico"
        return components.url
    }

    // MARK: - Derivation

    /// The first website that yields a usable public host.
    static func host(from websites: [String]) -> String? {
        for website in websites {
            if let host = host(from: website) { return host }
        }
        return nil
    }

    static func host(from website: String) -> String? {
        let trimmed = website.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Vault entries are typed by hand as often as pasted, so a bare
        // "github.com" has to work as well as a full URL does.
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate) else { return nil }
        // Bitwarden stores `androidapp://` and custom-scheme URIs alongside web
        // ones. They have no site to ask, so they get a monogram.
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        guard var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        // A dotless host is a LAN name, a typo, or an alias; nothing public
        // answers for it, and the monogram reads fine.
        guard host.contains(".") else { return nil }
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }
        return isSafeIconHost(host) ? host : nil
    }

    private static func isSafeIconHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57)
                      || (scalar.value >= 97 && scalar.value <= 122)
                      || scalar.value == 45 || scalar.value == 46
              }),
              !host.hasPrefix("."), !host.hasSuffix("."),
              !host.contains("..") else {
            return false
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63
                      && !label.hasPrefix("-") && !label.hasSuffix("-")
              }) else {
            return false
        }
        // Never turn vault content into an obvious local-network request. DNS
        // rebinding remains a residual of this opt-in feature, but literals and
        // common local-only suffixes are rejected before URLSession is touched.
        let looksNumericAddress = labels.allSatisfy { label in
            let scalars = label.unicodeScalars
            if scalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) {
                return true
            }
            guard label.hasPrefix("0x"), label.count > 2 else { return false }
            return label.dropFirst(2).unicodeScalars.allSatisfy {
                ($0.value >= 48 && $0.value <= 57)
                    || ($0.value >= 97 && $0.value <= 102)
            }
        }
        if looksNumericAddress { return false }
        let blockedSuffixes = [
            "local", "localdomain", "localhost", "internal", "home", "lan"
        ]
        return !blockedSuffixes.contains(String(labels.last!))
    }

    /// The letter drawn without artwork. The site's own name is preferred over
    /// the item's title, because they often differ and the site is what the
    /// user is scanning for: "Work GitHub" reads as a G, not a W.
    static func monogram(host: String?, title: String) -> String {
        let source = host.flatMap { $0.split(separator: ".").first.map(String.init) } ?? title
        let letter = source.unicodeScalars.first { CharacterSet.alphanumerics.contains($0) }
        return letter.map { String(Character($0)).uppercased() } ?? "•"
    }

    /// FNV-1a over the seed's UTF-8, mapped onto the hue circle. Written out
    /// rather than taken from `Hasher` so the colour is stable across launches
    /// and identical on every machine showing the same vault.
    static func hue(seed: String) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return Double(hash % 3600) / 3600
    }
}

extension VaultItemProjection {
    var iconIdentity: ItemIconIdentity {
        ItemIconIdentity(title: displayTitle, websites: websites)
    }
}

extension VaultItemCategory {
    /// The SF Symbol standing in for an item with no site of its own.
    var symbolName: String {
        switch self {
        case .login: return "person.crop.circle"
        case .secureNote: return "note.text"
        case .card: return "creditcard"
        case .identity: return "person.text.rectangle"
        case .unsupported: return "questionmark.square.dashed"
        }
    }
}
