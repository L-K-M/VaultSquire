import Foundation

@MainActor
final class QuickSearchPanelModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard oldValue != query else { return }
            // A refined query resets the highlight to the top match, the way
            // every launcher behaves; arrows take it from there.
            selection = results.first?.id
        }
    }

    /// The highlighted result, moved with the arrow keys and opened with
    /// Return. Resets to the top result whenever the query changes, so Return
    /// alone still opens the best match.
    @Published private(set) var selection: VaultItemID?

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
        selection = nil
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
        selection = results.first?.id
        notePresented()
    }

    func open(_ id: VaultItemID) {
        onOpen?(id)
    }

    /// Moves the highlight one result up or down, clamping at the ends.
    func moveSelection(by delta: Int) {
        let results = results
        guard !results.isEmpty else {
            selection = nil
            return
        }
        let currentIndex = Self.sanitized(selection, in: results)
            .flatMap { id in results.firstIndex(where: { $0.id == id }) }
            ?? (delta > 0 ? -1 : results.count)
        let next = min(max(currentIndex + delta, 0), results.count - 1)
        selection = results[next].id
    }

    /// Opens the highlighted result, or the top result when the highlight has
    /// fallen off the list. Returns the opened id so the caller can decide
    /// whether to dismiss.
    @discardableResult
    func openSelectionOrFirst() -> VaultItemID? {
        guard isUnlocked,
              let target = Self.sanitized(selection, in: results) ?? results.first?.id else {
            return nil
        }
        open(target)
        return target
    }

    /// The selection if it still names a visible result, else nil.
    private static func sanitized(
        _ selection: VaultItemID?,
        in results: [VaultItemProjection]
    ) -> VaultItemID? {
        guard let selection, results.contains(where: { $0.id == selection }) else { return nil }
        return selection
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
