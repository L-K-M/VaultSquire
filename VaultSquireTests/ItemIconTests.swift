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
    func testLocalAndLiteralHostsNeverProduceNetworkIconURLs() {
        for website in [
            "https://127.0.0.1/login",
            "https://127.1/login",
            "https://0x7f.0x1/login",
            "https://192.168.1.10/login",
            "https://vault.local/login",
            "https://service.internal/login",
            "https://host.localdomain/login",
        ] {
            XCTAssertNil(ItemIconIdentity.host(from: website), website)
        }
        XCTAssertNil(ItemIconIdentity.iconURL(forHost: "127.0.0.1"))
        XCTAssertNil(ItemIconIdentity.iconURL(forHost: "user@127.0.0.1"))
    }

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
    /// Built straight from a bitmap rep rather than through `lockFocus`, which
    /// needs a drawing context the test host has no reason to own.
    private var pngData: Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            return Data()
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

    func testImageWithOversizedDecodedDimensionsIsRefused() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: SiteIconStore.maximumIconDimension + 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertLessThan(data.count, SiteIconStore.maximumIconBytes)
        let store = SiteIconStore(defaults: makeDefaults(), fetch: { _ in data })
        store.isEnabled = true

        await store.load("example.com")

        XCTAssertNil(store.image(for: "example.com"))
    }

    func testClearPreventsASuspendedFetchFromRepublishing() async {
        let gate = DeferredIconFetch()
        let png = pngData
        let store = SiteIconStore(defaults: makeDefaults(), fetch: { _ in
            await gate.value()
        })
        store.isEnabled = true
        let task = Task { await store.load("example.com") }
        while !(await gate.didStart) { await Task.yield() }

        store.clear()
        await gate.resolve(png)
        await task.value

        XCTAssertNil(store.image(for: "example.com"))
    }

    /// Turning the switch off has to take effect on screen, not at the next
    /// launch: what was already fetched is dropped.
    func testTurningItOffDropsWhatWasFetched() async {
        let png = pngData
        let store = SiteIconStore(defaults: makeDefaults(), fetch: { _ in png })
        store.isEnabled = true
        await store.load("github.com")
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
        XCTAssertEqual(store.images.count, 2)

        store.clear()
        XCTAssertTrue(store.images.isEmpty)
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
}

/// A counter the injected fetch closure can bump from any isolation.
private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor DeferredIconFetch {
    private var continuation: CheckedContinuation<Data?, Never>?
    private(set) var didStart = false

    func value() async -> Data? {
        didStart = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ data: Data?) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}
