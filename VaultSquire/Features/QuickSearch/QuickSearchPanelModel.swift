import Foundation

@MainActor
final class QuickSearchPanelModel: ObservableObject {
    @Published var query = ""

    /// Incremented by the controller once the panel has been made key. The
    /// search field's focus is driven from this rather than from `onAppear`,
    /// which fires only for the first presentation and can run before the panel
    /// holds key status.
    @Published private(set) var presentationID = 0

    /// The searchable projections for this presentation, empty while locked.
    @Published private(set) var items: [VaultItemProjection] = []
    /// Whether the vault is unlocked; drives the locked vs. results content.
    @Published private(set) var isUnlocked = false

    /// Non-secret display names for the merged search's source badge, keyed by
    /// account. Captured at presentation so the panel never needs the live
    /// model (which may lock or change while the floating panel stays open).
    private var vaultTitles: [AccountID: String] = [:]

    private var onOpen: ((VaultItemID) -> Void)?

    /// Upper bound on how many results are rendered at once. Opening the panel
    /// with an empty query must not build a List over the whole corpus of a
    /// large vault; typing narrows the list instead.
    static let maximumResults = 100

    /// The items matching the current query, or the first `maximumResults`
    /// items when the query is empty. Never contains secrets — projections
    /// carry display fields only.
    var results: [VaultItemProjection] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let matching: [VaultItemProjection]
        if trimmed.isEmpty {
            matching = items
        } else {
            matching = items.filter { Self.matches($0, query: trimmed) }
        }
        return Array(matching.prefix(Self.maximumResults))
    }

    /// The vault display name for a result row, or nil when the vault is not
    /// known to this presentation.
    func vaultTitle(for item: VaultItemProjection) -> String? {
        vaultTitles[item.id.account]
    }

    func clear() {
        query.removeAll(keepingCapacity: false)
    }

    /// Loads a presentation's items and open handler and announces it, so the
    /// view claims focus after the panel is key.
    func present(
        items: [VaultItemProjection],
        isUnlocked: Bool,
        vaultTitles: [AccountID: String] = [:],
        onOpen: ((VaultItemID) -> Void)?
    ) {
        self.items = items
        self.isUnlocked = isUnlocked
        self.vaultTitles = vaultTitles
        self.onOpen = onOpen
        notePresented()
    }

    func open(_ id: VaultItemID) {
        onOpen?(id)
    }

    func notePresented() {
        presentationID += 1
    }

    private static func matches(_ item: VaultItemProjection, query: String) -> Bool {
        let haystacks = [item.displayTitle, item.displaySubtitle ?? item.username ?? ""]
            + item.websites + item.groupingLabels
        return haystacks.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
