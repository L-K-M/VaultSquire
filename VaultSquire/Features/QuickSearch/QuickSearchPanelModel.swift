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

    private var onOpen: ((VaultItemID) -> Void)?

    /// The items matching the current query, or all items when the query is
    /// empty. Never contains secrets — projections carry display fields only.
    var results: [VaultItemProjection] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        return items.filter { Self.matches($0, query: trimmed) }
    }

    func clear() {
        query.removeAll(keepingCapacity: false)
    }

    /// Loads a presentation's items and open handler and announces it, so the
    /// view claims focus after the panel is key.
    func present(
        items: [VaultItemProjection],
        isUnlocked: Bool,
        onOpen: ((VaultItemID) -> Void)?
    ) {
        self.items = items
        self.isUnlocked = isUnlocked
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
