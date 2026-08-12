import AppKit
import XCTest
@testable import VaultSquire

final class ItemIconTests: XCTestCase {
    // MARK: - Host extraction

    func testHostIsTakenFromAFullURL() {
        XCTAssertEqual(ItemIconIdentity.host(from: "https://github.com/login"), "github.com")
    }

    /// Vault entries are typed by hand as often as pasted, so a bare host has
    /// to resolve exactly like a full URL does.
    func testBareHostResolves() {
        XCTAssertEqual(ItemIconIdentity.host(from: "github.com"), "github.com")
        XCTAssertEqual(ItemIconIdentity.host(from: "  GitHub.com  "), "github.com")
    }

    func testWWWIsStrippedSoOneSiteIsOneIcon() {
        XCTAssertEqual(ItemIconIdentity.host(from: "https://www.example.com"), "example.com")
        XCTAssertEqual(
            ItemIconIdentity(title: "A", websites: ["https://www.example.com"]).hue,
            ItemIconIdentity(title: "B", websites: ["https://example.com"]).hue
        )
    }

    /// A subdomain is its own site: `mail.example.com` and `example.com` may be
    /// wholly unrelated services, so they are not folded together.
    func testSubdomainsAreDistinct() {
        XCTAssertEqual(ItemIconIdentity.host(from: "https://mail.example.com"), "mail.example.com")
    }

    /// Bitwarden stores `androidapp://` and other custom-scheme URIs next to web
    /// ones. There is no site to ask for those, and asking anyway would send a
    /// request built from a package name.
    func testNonWebSchemesYieldNoHost() {
        XCTAssertNil(ItemIconIdentity.host(from: "androidapp://com.example.app"))
        XCTAssertNil(ItemIconIdentity.host(from: "otpauth://totp/example"))
        XCTAssertNil(ItemIconIdentity.host(from: "ssh://box.example.com"))
    }

    /// A dotless host is a LAN name or an alias; nothing public answers for it.
    func testDotlessAndEmptyHostsAreRejected() {
        XCTAssertNil(ItemIconIdentity.host(from: "http://localhost"))
        XCTAssertNil(ItemIconIdentity.host(from: "nas"))
        XCTAssertNil(ItemIconIdentity.host(from: ""))
        XCTAssertNil(ItemIconIdentity.host(from: "   "))
    }

    func testTheFirstUsableWebsiteWins() {
        let identity = ItemIconIdentity(
            title: "Thing",
            websites: ["androidapp://com.example", "", "https://example.org/x"]
        )
        XCTAssertEqual(identity.host, "example.org")
    }

    // MARK: - Monogram

    /// The site's own name reads better than the item's title when they differ:
    /// "Work GitHub" is the row you find by looking for a G.
    func testMonogramPrefersTheSiteOverTheTitle() {
        let identity = ItemIconIdentity(title: "Work GitHub", websites: ["https://github.com"])
        XCTAssertEqual(identity.monogram, "G")
    }

    func testMonogramFallsBackToTheTitleWithoutASite() {
        XCTAssertEqual(ItemIconIdentity(title: "passport", websites: []).monogram, "P")
    }

    /// A title of only punctuation or emoji still has to draw something.
    func testMonogramAlwaysProducesACharacter() {
        XCTAssertFalse(ItemIconIdentity(title: "***", websites: []).monogram.isEmpty)
        XCTAssertFalse(ItemIconIdentity(title: "", websites: []).monogram.isEmpty)
        XCTAssertEqual(ItemIconIdentity(title: "9lives", websites: []).monogram, "9")
    }

    // MARK: - Colour

    /// The colour has to survive a relaunch, so it cannot come from `Hasher`,
    /// which is seeded per process. This pins the arithmetic instead.
    func testHueIsDeterministicAndBounded() {
        let first = ItemIconIdentity.hue(seed: "github.com")
        XCTAssertEqual(first, ItemIconIdentity.hue(seed: "github.com"))
        XCTAssertNotEqual(first, ItemIconIdentity.hue(seed: "gitlab.com"))
        for seed in ["a", "example.com", "", "ünïcode.example"] {
            let hue = ItemIconIdentity.hue(seed: seed)
            XCTAssertGreaterThanOrEqual(hue, 0)
            XCTAssertLessThan(hue, 1)
        }
    }

    /// Two logins at the same site look alike whatever they are called, which is
    /// the point: the colour names the site, not the row.
    func testSameSiteSameColourAcrossDifferentTitles() {
        let personal = ItemIconIdentity(title: "Personal", websites: ["https://github.com"])
        let work = ItemIconIdentity(title: "Work", websites: ["https://github.com/enterprise"])
        XCTAssertEqual(personal.hue, work.hue)
        XCTAssertEqual(personal.monogram, work.monogram)
    }

    // MARK: - Icon URL

    /// The URL is the site's own origin over TLS. An icon aggregator would be
    /// handed the vault's whole list of sites, which is the thing this must
    /// never do.
    func testIconURLIsTheSitesOwnHTTPSOrigin() {
        let identity = ItemIconIdentity(title: "GitHub", websites: ["http://github.com/login"])
        XCTAssertEqual(identity.iconURL?.absoluteString, "https://github.com/favicon.ico")
        XCTAssertEqual(identity.iconURL?.scheme, "https")
    }

    func testNoIconURLWithoutAHost() {
        XCTAssertNil(ItemIconIdentity(title: "Passport", websites: []).iconURL)
    }

    // MARK: - Which hosts may be asked

    /// A vault holds the router and the NAS next to the websites. Turning the
    /// icon switch on must not start probing them.
    func testAddressLiteralsAreRefused() {
        for website in [
            "https://192.168.1.1/", "http://10.0.0.1", "172.16.4.9",
            "https://127.0.0.1:8080/admin", "8.8.8.8", "https://169.254.169.254/"
        ] {
            let host = ItemIconIdentity.host(from: website)
            XCTAssertNotNil(host, "\(website) still names a site to the row")
            XCTAssertFalse(ItemIconIdentity.isSafeIconHost(host ?? ""), website)
            XCTAssertNil(host.flatMap(ItemIconIdentity.iconURL(forHost:)), website)
        }
    }

    /// Only the request is refused, never the row's identity. Five LAN logins
    /// have to stay five distinguishable rows rather than collapse into one
    /// identical category badge, which is what a nil host would do to them.
    func testARefusedHostKeepsItsLetterAndItsColour() {
        let router = ItemIconIdentity(title: "Home Router", websites: ["https://192.168.1.1"])
        let nas = ItemIconIdentity(title: "Synology NAS", websites: ["https://nas.local"])

        XCTAssertNotNil(router.host)
        XCTAssertNotNil(nas.host)
        XCTAssertNil(router.iconURL, "and neither is ever asked for artwork")
        XCTAssertNil(nas.iconURL)
        XCTAssertNotEqual(router.hue, nas.hue)
        XCTAssertEqual(nas.monogram, "N")
    }

    /// The octal and hexadecimal spellings of an address exist to slip past a
    /// check that only knows dotted decimal.
    func testAlternativeAddressSpellingsAreRefused() {
        for host in ["0x7f.0x0.0x0.0x1", "0177.0.0.1", "0x7f.0.0.1"] {
            XCTAssertFalse(ItemIconIdentity.isSafeIconHost(host), host)
        }
    }

    /// An IPv6 literal never reaches the label rules — the colons are not
    /// characters a host this builds an address from may contain.
    func testIPv6LiteralsAreRefused() {
        for host in ["::1", "[::1]", "fe80::1", "::ffff:192.168.1.1"] {
            XCTAssertFalse(ItemIconIdentity.isSafeIconHost(host), host)
        }
        XCTAssertNil(ItemIconIdentity.host(from: "https://[::1]/favicon.ico"))
    }

    /// Names that resolve on the user's own network, or that a development
    /// machine routinely points at loopback.
    func testLocalOnlySuffixesAreRefused() {
        for host in [
            "nas.local", "router.lan", "printer.home", "vault.internal",
            "wiki.intranet", "git.corp", "app.private", "host.localdomain",
            "api.localhost", "dev.test", "1.0.0.127.in-addr.arpa",
            "abcdefgh.onion"
        ] {
            XCTAssertFalse(ItemIconIdentity.isSafeIconHost(host), host)
            XCTAssertNil(ItemIconIdentity.iconURL(forHost: host), host)
        }
    }

    /// Malformed names are refused rather than normalized into something that
    /// might resolve differently from what was checked.
    func testMalformedHostsAreRefused() {
        let tooLongLabel = String(repeating: "a", count: 64) + ".example.com"
        let tooLongHost = Array(repeating: "abcdefghij", count: 26).joined(separator: ".")
        for host in [
            "", ".example.com", "example.com.", "a..b.com", "-bad.example.com",
            "bad-.example.com", "user:pass@example.com", "example.com:8443",
            "exa mple.com", "münchen.de", "single", tooLongLabel, tooLongHost
        ] {
            XCTAssertFalse(ItemIconIdentity.isSafeIconHost(host), host)
        }
    }

    /// The refusals have to leave ordinary sites alone, including the punycode
    /// form an internationalized name is actually carried as.
    func testPublicHostsAreStillAccepted() {
        for host in [
            "github.com", "mail.example.co.uk", "xn--bcher-kva.de",
            "1password.com", "3m.com", "a-b.example.org"
        ] {
            XCTAssertTrue(ItemIconIdentity.isSafeIconHost(host), host)
            XCTAssertNotNil(ItemIconIdentity.iconURL(forHost: host), host)
        }
    }

    /// An entry whose first website is a router keeps its icon: the next
    /// website that names a real site is used instead.
    func testAnUnsafeWebsiteFallsThroughToTheNextOne() {
        let identity = ItemIconIdentity(
            title: "Home",
            websites: ["https://192.168.1.1/", "https://synology.com/account"]
        )
        XCTAssertEqual(identity.host, "synology.com")
    }

    /// The address builder is the entry point the redirect policy uses to
    /// judge a destination the app did not choose, so it re-checks rather than
    /// trusting that a host reached it through `host(from:)`.
    func testTheAddressBuilderRefusesAnUnsafeHostOnItsOwn() {
        XCTAssertNil(ItemIconIdentity.iconURL(forHost: "192.168.1.1"))
        XCTAssertNil(ItemIconIdentity.iconURL(forHost: "nas.local"))
        XCTAssertEqual(
            ItemIconIdentity.iconURL(forHost: "GitHub.com")?.absoluteString,
            "https://github.com/favicon.ico"
        )
    }
}

@MainActor
final class SiteIconStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "VSQ-icons-\(UUID().uuidString)"
        // The teardown captures the suite name rather than the instance, so it
        // carries nothing across isolation but a string.
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    /// A tiny real PNG, so `NSImage` has something that actually decodes.
    private var pngData: Data { pngData(width: 4, height: 4) }

    /// A real PNG of a given size. Built straight from a bitmap rep rather
    /// than through `lockFocus`, which needs a drawing context the test host
    /// has no reason to own, and zeroed so the encoded size stays small even
    /// when the canvas does not.
    private func pngData(width: Int, height: Int) -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            return Data()
        }
        if let pixels = rep.bitmapData {
            pixels.update(repeating: 0, count: rep.bytesPerRow * height)
        }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    /// The default that matters most: a fresh install fetches nothing, so no
    /// site is told about the vault until the user asks.
    func testDisabledByDefaultAndFetchesNothing() async {
        let requested = Counter()
        let store = SiteIconStore(defaults: makeDefaults(), fetch: { _ in
            await requested.increment()
            return nil
        })

        XCTAssertFalse(store.isEnabled)
        await store.load("github.com")
        let count = await requested.value
        XCTAssertEqual(count, 0, "nothing may be requested while site icons are off")
        XCTAssertNil(store.image(for: "github.com"))
    }

    func testEnabledStoreFetchesAndCachesOnePerHost() async {
        let requested = Counter()
        let png = pngData
        let store = SiteIconStore(defaults: makeDefaults(), fetch: { _ in
            await requested.increment()
            return png
        })
        store.isEnabled = true

        await store.load("github.com")
        store.publishPendingImages()
        XCTAssertNotNil(store.image(for: "github.com"))

        // A second row for the same site draws from the cache.
        await store.load("github.com")
        let count = await requested.value
        XCTAssertEqual(count, 1)
    }

    /// A site with no icon is asked once. Without that, every scroll past the
    /// row would send another request to a host that already said no.
    func testAFailedFetchIsNotRetried() async {
        let requested = Counter()
        let store = SiteIconStore(defaults: makeDefaults(), fetch: { _ in
            await requested.increment()
            return nil
        })
        store.isEnabled = true

        await store.load("nothing.example")
        await store.load("nothing.example")
        await store.load("nothing.example")

        let count = await requested.value
        XCTAssertEqual(count, 1)
        XCTAssertNil(store.image(for: "nothing.example"))
    }

    /// A host that answers 200 with an HTML error page is not an icon, and is
    /// treated exactly like having none.
    func testUndecodableBodyIsIgnored() async {
        let store = SiteIconStore(defaults: makeDefaults(), fetch: { _ in
            Data("<!doctype html><title>404</title>".utf8)
        })
        store.isEnabled = true
        await store.load("example.com")
        XCTAssertNil(store.image(for: "example.com"))
    }

    /// An oversized body is refused before it is decoded, so a hostile host
    /// cannot hand back an image bomb.
    func testOversizedBodyIsRefused() async {
        // Read on the main actor: the fetch closure is nonisolated, and the
        // store's limits belong to it.
        let overLimit = SiteIconStore.maximumIconBytes + 1
        let store = SiteIconStore(defaults: makeDefaults(), fetch: { _ in
            Data(repeating: 0, count: overLimit)
        })
        store.isEnabled = true
        await store.load("example.com")
        XCTAssertNil(store.image(for: "example.com"))
    }

    /// Turning the switch off has to take effect on screen, not at the next
    /// launch: what was already fetched is dropped.
    func testTurningItOffDropsWhatWasFetched() async {
        let png = pngData
        let store = SiteIconStore(defaults: makeDefaults(), fetch: { _ in png })
        store.isEnabled = true
        await store.load("github.com")
        store.publishPendingImages()
        XCTAssertNotNil(store.image(for: "github.com"))

        store.isEnabled = false
        XCTAssertNil(store.image(for: "github.com"))

        await store.load("github.com")
        XCTAssertNil(store.image(for: "github.com"), "and nothing is fetched while off")
    }

    /// The icons on screen name the sites in the vault, so locking takes them
    /// down with the items.
    func testClearDropsEveryIcon() async {
        let png = pngData
        let store = SiteIconStore(defaults: makeDefaults(), fetch: { _ in png })
        store.isEnabled = true
        await store.load("github.com")
        await store.load("example.com")
        store.publishPendingImages()
        XCTAssertEqual(store.images.count, 2)

        store.clear()
        XCTAssertTrue(store.images.isEmpty)
    }

    /// Every row, the sidebar, and the detail observe this store, so an icon
    /// published on its own invalidated the whole window — once per site in the
    /// vault, arriving as a burst the moment a vault opened. Resolved icons are
    /// held and published together instead.
    func testResolvedIconsArePublishedInOneUpdate() async {
        let png = pngData
        let store = SiteIconStore(defaults: makeDefaults(), fetch: { _ in png })
        store.isEnabled = true

        await store.load("one.example")
        await store.load("two.example")
        store.publishPendingImages()

        XCTAssertEqual(store.images.count, 2)
        // Nothing is left waiting, so a second publish changes nothing.
        store.publishPendingImages()
        XCTAssertEqual(store.images.count, 2)
    }

    /// And the publish happens on its own: nothing has to ask for it.
    func testAnIconAppearsWithoutAnExplicitPublish() async throws {
        let png = pngData
        let store = SiteIconStore(defaults: makeDefaults(), fetch: { _ in png })
        store.isEnabled = true

        await store.load("github.com")

        for _ in 0..<200 where store.image(for: "github.com") == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(store.image(for: "github.com"))
    }

    func testThePreferenceSurvivesANewStore() async {
        let defaults = makeDefaults()
        let first = SiteIconStore(defaults: defaults, fetch: { _ in nil })
        first.isEnabled = true

        let second = SiteIconStore(defaults: defaults, fetch: { _ in nil })
        XCTAssertTrue(second.isEnabled)
    }

    func testNilHostIsANoOp() async {
        let png = pngData
        let store = SiteIconStore(defaults: makeDefaults(), fetch: { _ in png })
        store.isEnabled = true
        await store.load(nil)
        XCTAssertTrue(store.images.isEmpty)
    }

    // MARK: - What is never asked for

    /// The host rules are the point at which vault content stops being able to
    /// become an outbound request, so nothing refused there reaches the
    /// network at all.
    func testAHostTheIdentityRefusesIsNeverRequested() async {
        let requested = Counter()
        let store = SiteIconStore(defaults: makeDefaults(), fetch: { _ in
            await requested.increment()
            return nil
        })
        store.isEnabled = true

        for host in ["192.168.1.1", "nas.local", "router.lan", "::1"] {
            await store.load(host)
        }

        let count = await requested.value
        XCTAssertEqual(count, 0, "an address literal or a local-only name is never asked")
        XCTAssertTrue(store.images.isEmpty)
    }

    // MARK: - What is never decoded

    /// The byte bound limits the transfer, not the bitmap. A few kilobytes of
    /// PNG describes a canvas large enough to matter, and the decode is the
    /// allocation.
    func testAnImplausiblyLargeCanvasIsRefusedBeforeDecoding() async {
        let bomb = pngData(width: 1_200, height: 1_200)
        XCTAssertFalse(bomb.isEmpty)
        XCTAssertLessThan(
            bomb.count, SiteIconStore.maximumIconBytes,
            "the byte bound must not be what refuses this, or the test proves nothing"
        )
        XCTAssertFalse(SiteIconStore.hasPlausibleIconDimensions(bomb))

        let store = SiteIconStore(defaults: makeDefaults(), fetch: { _ in bomb })
        store.isEnabled = true
        await store.load("example.com")
        store.publishPendingImages()
        XCTAssertNil(store.image(for: "example.com"))
    }

    /// And an ordinary icon still passes, while bytes that are not an image at
    /// all are refused without `NSImage` being asked.
    func testTheDimensionCheckAdmitsARealIconAndNothingElse() {
        XCTAssertTrue(SiteIconStore.hasPlausibleIconDimensions(pngData))
        XCTAssertFalse(SiteIconStore.hasPlausibleIconDimensions(Data()))
        XCTAssertFalse(
            SiteIconStore.hasPlausibleIconDimensions(Data("<!doctype html><title>404</title>".utf8))
        )
    }

    // MARK: - Locking

    /// Dropping the icons already on screen is only half of a lock. A fetch
    /// still in flight would otherwise resume afterwards and put its host
    /// back, telling anyone looking at the window what was in the vault.
    func testAResponseArrivingAfterLockIsDiscarded() async {
        let gate = Gate()
        let png = pngData
        let store = SiteIconStore(defaults: makeDefaults(), fetch: { _ in
            await gate.waitUntilOpened()
            return png
        })
        store.isEnabled = true

        let load = Task { await store.load("github.com") }
        await gate.waitUntilEntered()
        store.clear()
        await gate.open()
        await load.value

        store.publishPendingImages()
        XCTAssertTrue(store.images.isEmpty)
        XCTAssertNil(store.image(for: "github.com"))

        // And the next unlock may ask again: the discard is about this fetch,
        // not about the host.
        await store.load("github.com")
        store.publishPendingImages()
        XCTAssertNotNil(store.image(for: "github.com"))
    }

    /// A fetch that stopped because its row scrolled away learned nothing
    /// about the site. Without forgetting the attempt, one fast scroll would
    /// leave every row it passed permanently without an icon.
    func testAFetchStoppedByItsRowIsAskedAgain() async {
        let gate = Gate()
        let png = pngData
        let store = SiteIconStore(defaults: makeDefaults(), fetch: { _ in
            await gate.waitUntilOpened()
            // What a real transfer yields when it is cancelled.
            return Task.isCancelled ? nil : png
        })
        store.isEnabled = true

        let load = Task { await store.load("github.com") }
        await gate.waitUntilEntered()
        load.cancel()
        await gate.open()
        await load.value
        XCTAssertNil(store.image(for: "github.com"))

        await store.load("github.com")
        store.publishPendingImages()
        XCTAssertNotNil(store.image(for: "github.com"))
    }
}

/// A counter the injected fetch closure can bump from any isolation.
private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// A rendezvous that holds an injected fetch suspended, so a test can lock the
/// store while a request is genuinely in flight rather than pretend it is.
private actor Gate {
    private var isOpen = false
    private var hasEntered = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called by the fetch. Returns once the test calls `open()`.
    func waitUntilOpened() async {
        hasEntered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters = []
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    /// Called by the test. Returns once a fetch is suspended in the gate.
    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in openWaiters { waiter.resume() }
        openWaiters = []
    }
}
