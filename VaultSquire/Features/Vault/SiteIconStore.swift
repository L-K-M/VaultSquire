import AppKit
import Foundation
import ImageIO

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
    nonisolated static let maximumCachedIcons = 500

    /// The largest icon body accepted. Real favicons are a few kilobytes; this
    /// bounds both transfer and in-memory buffering from a hostile host.
    nonisolated static let maximumIconBytes = 256 * 1024
    /// Compressed byte bounds do not stop a tiny decompression bomb. Inspect
    /// image metadata before asking AppKit to decode and refuse implausible
    /// dimensions or pixel counts.
    nonisolated static let maximumIconDimension = 1_024
    nonisolated static let maximumIconPixels = 1_048_576

    @Published private(set) var images: [String: NSImage] = [:]

    /// Whether icons are fetched at all. Turning it off drops what was fetched,
    /// so the switch takes effect on screen immediately rather than at the next
    /// launch.
    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults.set(isEnabled, forKey: Self.preferenceKey)
            generation &+= 1
            if !isEnabled {
                cancelFetchesAndReleaseState()
            }
        }
    }

    /// Hosts already tried this session, successfully or not. A site with no
    /// icon is asked once and then left alone; without this, scrolling past it
    /// would re-request forever.
    private var attemptedHosts: Set<String> = []
    /// Invalidates every suspended fetch when the preference changes or the
    /// vault locks. A response from the prior generation can never repopulate
    /// the store after its sensitive presentation state was cleared.
    private var generation: UInt64 = 0
    private var fetchTasks: [String: Task<Data?, Never>] = [:]
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
              attemptedHosts.count < Self.maximumCachedIcons,
              let url = ItemIconIdentity.iconURL(forHost: host) else {
            return
        }
        // Claimed before the suspension point, so two rows for the same site
        // make one request rather than two.
        attemptedHosts.insert(host)
        let requestedGeneration = generation
        let fetch = self.fetch
        let task = Task { await fetch(url) }
        fetchTasks[host] = task
        let data = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if generation == requestedGeneration {
            fetchTasks[host] = nil
        }

        guard let data,
              !Task.isCancelled,
              isEnabled,
              generation == requestedGeneration,
              data.count <= Self.maximumIconBytes,
              Self.hasSafeDimensions(data),
              let image = NSImage(data: data), image.isValid, image.size.width > 0 else {
            return
        }
        images[host] = image
    }

    /// Drops every fetched icon and cancels requests on any security lock.
    func clear() {
        generation &+= 1
        cancelFetchesAndReleaseState()
    }

    private func cancelFetchesAndReleaseState() {
        for task in fetchTasks.values { task.cancel() }
        fetchTasks = [:]
        images = [:]
        attemptedHosts = []
    }

    private static func hasSafeDimensions(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        let imageCount = CGImageSourceGetCount(source)
        guard imageCount > 0, imageCount <= 32 else { return false }
        var totalPixels = 0
        for index in 0..<imageCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                    as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
                return false
            }
            let w = width.intValue
            let h = height.intValue
            guard w > 0, h > 0,
                  w <= maximumIconDimension, h <= maximumIconDimension else {
                return false
            }
            let (pixels, pixelOverflow) = w.multipliedReportingOverflow(by: h)
            let (nextTotal, totalOverflow) = totalPixels.addingReportingOverflow(pixels)
            guard !pixelOverflow, !totalOverflow,
                  pixels <= maximumIconPixels,
                  nextTotal <= maximumIconPixels * 4 else {
                return false
            }
            totalPixels = nextTotal
        }
        return true
    }

}

/// The network side, kept out of the store so it stays off the main actor: the
/// fetch touches nothing the store owns and returns bytes, which are Sendable.
private final class SiteIconRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        // A redirect would let every site funnel its request to one tracking
        // origin, defeating the privacy reason for avoiding an aggregator.
        nil
    }
}

private enum SiteIconFetcher {
    /// A session that carries nothing between requests: no cookies, no
    /// credential store, no shared cache. Redirects are refused by its delegate
    /// so a site cannot silently turn itself into a cross-vault aggregator.
    private static let redirectBlocker = SiteIconRedirectBlocker()
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.httpAdditionalHeaders = [
            "Accept": "image/*",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
        ]
        return URLSession(
            configuration: configuration,
            delegate: redirectBlocker,
            delegateQueue: nil
        )
    }()

    static let fetch: @Sendable (URL) async -> Data? = { url in
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  http.url == url,
                  http.expectedContentLength <= Int64(SiteIconStore.maximumIconBytes),
                  http.value(forHTTPHeaderField: "Content-Type")?
                    .lowercased().hasPrefix("image/") == true else {
                return nil
            }

            var data = Data()
            data.reserveCapacity(Int(max(0, http.expectedContentLength)))
            for try await byte in bytes {
                guard data.count < SiteIconStore.maximumIconBytes else { return nil }
                data.append(byte)
            }
            return data
        } catch {
            return nil
        }
    }
}
