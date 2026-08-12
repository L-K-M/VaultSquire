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
    ///
    /// Naming a host here does not mean it may be asked for an icon: an entry
    /// for the router names `192.168.1.1`, and that is what the row's letter
    /// and colour come from even though nothing is ever requested from it.
    /// `iconURL` is what decides that.
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
    ///
    /// The host is re-checked here rather than trusted from `host(from:)`,
    /// because this is also the entry point the redirect policy uses to judge
    /// a destination the app did not choose.
    static func iconURL(forHost host: String) -> URL? {
        let host = host.lowercased()
        guard isSafeIconHost(host) else { return nil }
        // Assembled through `URLComponents` rather than interpolated into a
        // string, so the address cannot depend on how a host spells itself.
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/favicon.ico"
        return components.url
    }

    // MARK: - Derivation

    /// The first website that yields a usable host.
    ///
    /// A host that may actually be asked for an icon wins over one that may
    /// not, so an entry listing the router first and a real site second still
    /// gets artwork. When nothing on the item is askable the first parseable
    /// host is still returned, because this is also what the monogram and the
    /// colour are derived from: five LAN logins should look like five
    /// different sites, not collapse into one identical category badge.
    static func host(from websites: [String]) -> String? {
        var firstParseable: String?
        for website in websites {
            guard let host = host(from: website) else { continue }
            if isSafeIconHost(host) { return host }
            if firstParseable == nil { firstParseable = host }
        }
        return firstParseable
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
        // Not filtered by `isSafeIconHost` here. This is the row's identity —
        // its letter and its colour — and a host that may not be *asked* is
        // still the site the item names. `iconURL(forHost:)` is the one place
        // that decides what may be requested.
        return host.isEmpty ? nil : host
    }

    /// Whether a host may be asked for an icon at all.
    ///
    /// Fetching an icon is the one thing the app does that turns vault content
    /// into an outbound request, so the address it will build has to be a
    /// public web host and nothing else. A vault holds router, NAS and
    /// intranet logins as readily as it holds `github.com`, and those entries
    /// name hosts on the user's own network — turning the icon switch on must
    /// not quietly start probing them.
    ///
    /// A host refused here keeps its row's letter and colour — it is still the
    /// site the item names — and simply never has artwork fetched for it. Only
    /// the request is refused, not the identity.
    ///
    /// This does not defeat DNS rebinding: a public name whose record points
    /// inside the network still resolves inside the network. That residual is
    /// inherent to an opt-in feature that fetches from names the vault
    /// supplies, and is why the feature is off until it is asked for.
    static func isSafeIconHost(_ host: String) -> Bool {
        // A host that is not letters, digits, hyphens and dots is not a name
        // this will build an address from — that includes the colons of an
        // IPv6 literal, a percent escape, and anything with credentials or a
        // port smuggled into it. A non-ASCII host is refused with them: the
        // punycode form is what a URL carries, and accepting the Unicode form
        // would mean deciding here how to encode it.
        guard !host.isEmpty, host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy(Self.isHostScalar),
              !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else {
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
        // An address literal names a machine rather than a site. `192.168.1.1`
        // and `10.0.0.1` are ordinary vault entries; the dotted-decimal check
        // also covers the octal and hexadecimal spellings of the same address,
        // which exist precisely to slip past a check like this one.
        if labels.allSatisfy(Self.isNumericLabel) { return false }
        return !Self.localOnlySuffixes.contains(String(labels[labels.count - 1]))
    }

    /// Suffixes that resolve on the user's own network or nowhere.
    ///
    /// `local` is mDNS and `home.arpa` is the RFC 8375 residential name;
    /// `internal` is ICANN's reserved private-use suffix; `lan`, `home`,
    /// `corp`, `intranet` and `private` are what routers hand out by
    /// convention. `test` is here because a development machine routinely
    /// wires it to loopback. `onion` names a service no `URLSession` can
    /// reach.
    ///
    /// `example` and `invalid` are deliberately absent. They are reserved and
    /// resolve nowhere, so a request to one fails like any dead host, and
    /// refusing them would buy nothing.
    private static let localOnlySuffixes: Set<String> = [
        "arpa", "corp", "home", "internal", "intranet", "lan",
        "local", "localdomain", "localhost", "onion", "private", "test"
    ]

    private static func isHostScalar(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 97 && scalar.value <= 122)   // a-z; the host is lowercased
            || (scalar.value >= 48 && scalar.value <= 57)  // 0-9
            || scalar.value == 45                          // -
            || scalar.value == 46                          // .
    }

    /// A label that is a number in any base a resolver accepts.
    private static func isNumericLabel(_ label: Substring) -> Bool {
        if label.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) {
            return !label.isEmpty
        }
        guard label.hasPrefix("0x"), label.count > 2 else { return false }
        return label.dropFirst(2).unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 97 && scalar.value <= 102)
        }
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
