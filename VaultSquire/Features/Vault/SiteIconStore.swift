import AppKit
import Foundation

/// Fetches and holds site icons for vault rows, when the user has asked for
/// them.
///
/// This is off until it is turned on, and that default is the whole design.
/// Fetching a site's icon is the only thing VaultSquire does that sends
/// something derived from vault content to a host that is not the user's own
/// server: a request for `https://example.com/favicon.ico` tells example.com
/// that this Mac holds an entry for it, at the moment the vault is opened. That
/// is a trade a user can reasonably want to make — it is also one they have to
/// make knowingly, so nothing is fetched until the Settings switch is on.
///
/// Two limits follow from the same reasoning. Requests go to each site's own
/// origin and never to an icon aggregator, because a single aggregator would
/// receive the entire list of sites in the vault rather than each site learning
/// the one fact it already knows. And nothing is written to disk: icons live in
/// memory for the life of the session, so the set of sites in the vault leaves
/// no trace on the Mac, and quitting drops it.
@MainActor
final class SiteIconStore: ObservableObject {
    /// The preference key. Absent means off, which is what makes the safe state
    /// the default on a fresh install.
    static let preferenceKey = "VaultSquire.showsSiteIcons"

    /// The most icons held at once. A pathological vault cannot grow this
    /// without bound, and the cap is far above any realistic screenful.
    static let maximumCachedIcons = 500

    /// The largest icon body accepted. Real favicons are a few kilobytes; this
    /// bounds what a hostile or misconfigured host can hand back.
    static let maximumIconBytes = 256 * 1024

    @Published private(set) var images: [String: NSImage] = [:]

    /// Whether icons are fetched at all. Turning it off drops what was fetched,
    /// so the switch takes effect on screen immediately rather than at the next
    /// launch.
    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults.set(isEnabled, forKey: Self.preferenceKey)
            if !isEnabled {
                images = [:]
                attemptedHosts = []
            }
        }
    }

    /// Hosts already tried this session, successfully or not. A site with no
    /// icon is asked once and then left alone; without this, scrolling past it
    /// would re-request forever.
    private var attemptedHosts: Set<String> = []
    private let defaults: UserDefaults
    private let fetch: @Sendable (URL) async -> Data?

    init(
        defaults: UserDefaults = .standard,
        fetch: (@Sendable (URL) async -> Data?)? = nil
    ) {
        self.defaults = defaults
        // The parameter, not `self.defaults`: `self` is not usable until every
        // stored property is initialized.
        self.isEnabled = defaults.bool(forKey: Self.preferenceKey)
        self.fetch = fetch ?? SiteIconFetcher.fetch
    }

    /// The icon for a host, or nil when there is none to show — which is the
    /// common case and never an error: the row falls back to its monogram.
    func image(for host: String?) -> NSImage? {
        guard let host else { return nil }
        return images[host]
    }

    /// Fetches one host's icon if it is wanted and not already known. Safe to
    /// call from every row on every redraw: it is a no-op for a host that is
    /// cached, already in flight, or already found to have nothing.
    func load(_ host: String?) async {
        guard isEnabled,
              let host,
              images[host] == nil,
              !attemptedHosts.contains(host),
              images.count < Self.maximumCachedIcons,
              let url = ItemIconIdentity.iconURL(forHost: host) else {
            return
        }
        // Claimed before the suspension point, so two rows for the same site
        // make one request rather than two.
        attemptedHosts.insert(host)

        guard let data = await fetch(url), data.count <= Self.maximumIconBytes else { return }
        // A host that answers 200 with an HTML error page decodes to nothing,
        // which is indistinguishable from having no icon, and treated as such.
        guard let image = NSImage(data: data), image.isValid, image.size.width > 0 else { return }
        images[host] = image
    }

    /// Drops every fetched icon. Called when the last vault locks, so the
    /// window stops showing which sites were in it.
    func clear() {
        images = [:]
        attemptedHosts = []
    }

}

/// The network side, kept out of the store so it stays off the main actor: the
/// fetch touches nothing the store owns and returns bytes, which are Sendable.
private enum SiteIconFetcher {
    /// A session that carries nothing between requests: no cookies, no
    /// credential store, no shared cache. Two sites cannot correlate a visit
    /// through it, and nothing it touches is written to disk.
    ///
    /// `nonisolated(unsafe)` because `URLSession` is thread-safe by contract
    /// and this one is never mutated after construction.
    nonisolated(unsafe) static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        // A generic agent rather than the default, which names the app. "A
        // password manager holds an entry for you" is a far more useful fact to
        // the site receiving it than it is to VaultSquire sending it.
        configuration.httpAdditionalHeaders = [
            "Accept": "image/*",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
        ]
        return URLSession(configuration: configuration)
    }()

    static let fetch: @Sendable (URL) async -> Data? = { url in
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            return nil
        }
        return data
    }
}
