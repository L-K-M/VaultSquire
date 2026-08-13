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
    ///
    /// A full cache does not freeze: the oldest resolved icon is evicted for
    /// a newly resolved one, so icons keep loading after the cap is reached
    /// and scrolling back simply re-fetches what was evicted.
    static let maximumCachedIcons = 500

    /// The most hosts asked in one session. The cache bound above counts what
    /// was found, so on its own it never closes: a vault full of sites that
    /// have no icon keeps the gate open and keeps asking. This bounds the
    /// requests, which is the number that matters — each one tells a site the
    /// vault has an entry for it.
    static let maximumAttemptedHosts = 2_000

    /// How many times one host may fail before it is left alone for the rest
    /// of the session. The first failure is forgiven — a transient network
    /// blip or a server hiccup must not cost a host its icon until the next
    /// launch — and the second keeps the original ask-once behaviour for
    /// hosts that reliably have nothing.
    static let maximumAttemptsPerHost = 2

    /// The largest icon body accepted. Real favicons are a few kilobytes; this
    /// bounds what a hostile or misconfigured host can hand back. Nonisolated
    /// so the off-actor fetcher enforces it mid-transfer.
    nonisolated static let maximumIconBytes = 256 * 1024

    /// The largest edge, and the total pixels across every frame, that will be
    /// decoded. The byte bound above limits the transfer, not the bitmap: a
    /// few kilobytes of PNG can describe a 30,000-square canvas, and asking
    /// `NSImage` about it is already asking for the allocation. A row draws
    /// this at around sixteen points, so the ceiling is generous.
    static let maximumIconDimension = 1_024
    static let maximumIconPixels = 4 * 1_024 * 1_024
    /// A `.ico` legitimately carries a handful of sizes. Hundreds is a bomb.
    static let maximumIconFrames = 16

    /// How long resolved icons are held before they are published together.
    /// Every row in the list, the sidebar, and the detail observe this store,
    /// so publishing one icon at a time invalidated the whole window once per
    /// site in the vault — arriving as a burst the moment a vault opened, which
    /// is exactly when the list is being scrolled. A window this short is
    /// imperceptible and turns that burst into a handful of updates.
    static let publishInterval: Duration = .milliseconds(120)

    @Published private(set) var images: [String: NSImage] = [:]

    /// Whether icons are fetched at all. Turning it off drops what was fetched,
    /// so the switch takes effect on screen immediately rather than at the next
    /// launch.
    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults.set(isEnabled, forKey: Self.preferenceKey)
            if !isEnabled {
                clear()
            }
        }
    }

    /// Hosts already tried this session, successfully or not. A site with no
    /// icon is asked once and then left alone; without this, scrolling past it
    /// would re-request forever.
    private var attemptedHosts: Set<String> = []
    /// How many times each host has already failed this session. A host whose
    /// count has not reached `maximumAttemptsPerHost` is asked again on the
    /// next render; one that has is left alone.
    private var failureCounts: [String: Int] = [:]
    /// The order hosts were successfully resolved in, oldest first, so the cap
    /// evicts the icon the user has not needed for the longest.
    private var insertionOrder: [String] = []
    /// Icons resolved since the last publish, held for one short window so a
    /// vault's worth of them lands as a few updates rather than hundreds.
    private var pendingImages: [String: NSImage] = [:]
    private var publishTask: Task<Void, Never>?
    /// Bumped by `clear()`. A fetch reads it before it suspends and again when
    /// it resumes, so a response that lands after the vault locked is dropped
    /// instead of repopulating a window that was deliberately emptied.
    private var generation: UInt64 = 0
    /// The transfers in flight, so locking can stop them rather than let them
    /// run out their ten-second resource timeout holding a buffer.
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

    /// Everything held for this host, published or waiting to be. Used by the
    /// duplicate-request check so a host resolved moments ago is not fetched
    /// again before it has been published.
    private func isKnown(_ host: String) -> Bool {
        images[host] != nil || pendingImages[host] != nil
    }

    /// Fetches one host's icon if it is wanted and not already known. Safe to
    /// call from every row on every redraw: it is a no-op for a host that is
    /// cached, already in flight, or already found to have nothing.
    func load(_ host: String?) async {
        guard isEnabled,
              let host,
              !isKnown(host),
              !attemptedHosts.contains(host),
              attemptedHosts.count < Self.maximumAttemptedHosts,
              // Refuses an address literal and a local-only name before a
              // request exists, so the switch never starts probing the
              // router and NAS entries a vault holds alongside its websites.
              let url = ItemIconIdentity.iconURL(forHost: host) else {
            return
        }
        // Claimed before the suspension point, so two rows for the same site
        // make one request rather than two.
        attemptedHosts.insert(host)

        let requestedGeneration = generation
        let data = await fetchCancellably(url, for: host)
        // Only when nothing invalidated this fetch: `clear()` already emptied
        // the dictionary, and a later load for the same host owns the entry.
        if generation == requestedGeneration {
            fetchTasks[host] = nil
        }

        guard let data else {
            // A transfer stopped because its row scrolled away learned nothing
            // about whether the site has an icon. Forget the attempt, or a
            // fast scroll would leave every row it passed permanently blank.
            if Task.isCancelled, generation == requestedGeneration {
                attemptedHosts.remove(host)
            } else if generation == requestedGeneration {
                // A genuine failure — timeout, refused connection, a dropped
                // route — is forgiven a bounded number of times, so one blip
                // does not cost the host its icon for the whole session,
                // while a host that reliably has nothing is still asked only
                // a handful of times.
                let failures = failureCounts[host, default: 0] + 1
                failureCounts[host] = failures
                if failures < Self.maximumAttemptsPerHost {
                    attemptedHosts.remove(host)
                }
            }
            return
        }
        guard generation == requestedGeneration,
              isEnabled,
              data.count <= Self.maximumIconBytes,
              // Before `NSImage`, not after: this is what decides whether the
              // bitmap is allocated at all.
              Self.hasPlausibleIconDimensions(data) else {
            return
        }
        // A host that answers 200 with an HTML error page decodes to nothing,
        // which is indistinguishable from having no icon, and treated as such.
        guard let image = NSImage(data: data), image.isValid, image.size.width > 0 else { return }
        // Held rather than published, so a vault's worth of icons resolving at
        // once does not invalidate every row in the window once each.
        evictIfNeeded()
        pendingImages[host] = image
        insertionOrder.removeAll { $0 == host }
        insertionOrder.append(host)
        schedulePublish()
    }

    /// Makes room at the cap by dropping the oldest resolved icon. Runs only
    /// once a new icon has actually resolved, so a full cache never refuses a
    /// host whose fetch would have succeeded, and a fetch that fails never
    /// costs an icon that was already on screen. An evicted host may be asked
    /// again later — it left the cache, not the session.
    private func evictIfNeeded() {
        while images.count + pendingImages.count >= Self.maximumCachedIcons,
              let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            images[oldest] = nil
            pendingImages[oldest] = nil
            attemptedHosts.remove(oldest)
        }
    }

    /// Runs one fetch as a task the store can cancel, while still stopping if
    /// the caller stops. An unstructured task does not inherit cancellation,
    /// so the handler forwards it and the row going away ends the transfer as
    /// it did before.
    private func fetchCancellably(_ url: URL, for host: String) async -> Data? {
        let fetch = self.fetch
        let task = Task { await fetch(url) }
        fetchTasks[host] = task
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func schedulePublish() {
        guard publishTask == nil else { return }
        publishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.publishInterval)
            self?.publishTask = nil
            self?.publishPendingImages()
        }
    }

    /// Moves what has resolved into the published map in one change. Left
    /// internal so a test can drive it without waiting on the window.
    func publishPendingImages() {
        guard !pendingImages.isEmpty else { return }
        images.merge(pendingImages) { _, resolved in resolved }
        pendingImages = [:]
    }

    /// Drops every fetched icon. Called when the last vault locks, so the
    /// window stops showing which sites were in it.
    ///
    /// Dropping what has arrived is only half of it. A fetch already in flight
    /// would otherwise resume after the lock and put its host back on screen,
    /// so the generation is bumped — which invalidates every suspended fetch —
    /// and the transfers are cancelled rather than left running.
    func clear() {
        generation &+= 1
        for task in fetchTasks.values { task.cancel() }
        fetchTasks = [:]
        publishTask?.cancel()
        publishTask = nil
        pendingImages = [:]
        images = [:]
        attemptedHosts = []
        failureCounts = [:]
        insertionOrder = []
    }

    /// Whether the bytes describe an image small enough to be worth decoding.
    ///
    /// ImageIO reads the header without decoding, so an implausible canvas is
    /// refused before a pixel buffer exists for it. Anything it cannot read
    /// at all is refused too: that is the HTML error page case, which is
    /// indistinguishable from a site having no icon and treated the same way.
    static func hasPlausibleIconDimensions(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        let frames = CGImageSourceGetCount(source)
        guard frames > 0, frames <= maximumIconFrames else { return false }
        var totalPixels = 0
        for index in 0..<frames {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                    as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0,
                  width <= maximumIconDimension, height <= maximumIconDimension else {
                return false
            }
            // Both edges are already bounded, and the frame count with them,
            // so neither the product nor the running total can overflow.
            totalPixels += width * height
            guard totalPixels <= maximumIconPixels else { return false }
        }
        return true
    }

}

/// Decides whether a redirect may be followed.
///
/// Without one of these the host rules are advisory: a site can answer
/// `https://example.com/favicon.ico` with a redirect to `192.168.1.1` and the
/// request is made anyway, because nothing re-checks a destination the app did
/// not choose. So a redirect has to pass the same test the original address
/// did, and has to stay on the same site.
///
/// Staying on the same site keeps `example.com` → `www.example.com` working,
/// which is the redirect nearly every real site actually serves — the `www.`
/// prefix is stripped when the host is derived, so the apex is what gets
/// asked. It refuses the one that matters, which is a site handing its request
/// to somewhere else: an origin collecting redirects from many sites would
/// learn the vault's list, which is the reason icons come from each site
/// directly and never from an aggregator.
///
/// Only the address the app itself chose may redirect, which bounds a chain to
/// a single hop with no per-task state. The comparison is against the whole
/// original URL rather than only its host: on the second hop the redirecting
/// response is the first hop's destination, so a differing path is what ends
/// the chain when a site redirects to itself. Comparing hosts alone would let
/// `/favicon.ico` → `/a` → `/b` → … run to URLSession's own limit.
private final class SiteIconRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let original = task.originalRequest?.url,
              response.url == original,
              let origin = original.host?.lowercased(),
              let destination = request.url,
              destination.scheme?.lowercased() == "https",
              let host = destination.host?.lowercased(),
              ItemIconIdentity.isSafeIconHost(host),
              Self.isSameSite(host, as: origin) else {
            return nil
        }
        return request
    }

    /// One host is the other, or a subdomain of it. A vault entry naming a
    /// public suffix directly — `co.uk` — would widen this, but that is not a
    /// site anyone stores a login for.
    static func isSameSite(_ host: String, as origin: String) -> Bool {
        host == origin || host.hasSuffix("." + origin) || origin.hasSuffix("." + host)
    }
}

/// The network side, kept out of the store so it stays off the main actor: the
/// fetch touches nothing the store owns and returns bytes, which are Sendable.
private enum SiteIconFetcher {
    private static let redirectPolicy = SiteIconRedirectPolicy()

    /// A session that carries nothing between requests: no cookies, no
    /// credential store, no shared cache. Two sites cannot correlate a visit
    /// through it, and nothing it touches is written to disk.
    static let session: URLSession = {
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
        return URLSession(
            configuration: configuration,
            delegate: SiteIconFetcher.redirectPolicy,
            delegateQueue: nil
        )
    }()

    static let fetch: @Sendable (URL) async -> Data? = { url in
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        // The byte cap is enforced mid-transfer, not after: the host being
        // asked is one a vault item names, so an untrusted endpoint cannot
        // answer with an unbounded body and cost the app its memory.
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              // A body that says up front how big it is, and says too big, is
              // refused before a byte of it is read. Undeclared is -1, which
              // passes here and is caught by the count below.
              http.expectedContentLength <= Int64(SiteIconStore.maximumIconBytes) else {
            return nil
        }
        var data = Data()
        data.reserveCapacity(Int(max(0, http.expectedContentLength)))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > SiteIconStore.maximumIconBytes {
                    return nil
                }
            }
        } catch {
            return nil
        }
        return data
    }
}
