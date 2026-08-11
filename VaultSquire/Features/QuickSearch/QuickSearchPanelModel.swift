import Foundation

@MainActor
final class QuickSearchPanelModel: ObservableObject {
    @Published var query = ""
    /// The index of the keyboard-selected result, or nil when nothing is
    /// selected. The view drives ↑/↓ through `moveSelection(by:)` and opens
    /// the selection with `selectedItemID`. It is reset to nil whenever the
    /// query or the underlying item set changes, so a stale index can never
    /// point past the end of the current results.
    @Published private(set) var selectedIndex: Int?
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
        selectedIndex = nil
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

    /// Moves the keyboard selection by `offset` rows, clamping to the result
    /// list. With no selection, a downward move selects the first row and an
    /// upward move selects the last, matching the Spotlight/Raycast convention.
    /// A no-op when there is nothing to select.
    func moveSelection(by offset: Int) {
        let count = results.count
        guard count > 0 else { selectedIndex = nil; return }
        let current = selectedIndex ?? (offset > 0 ? -1 : count)
        var proposed = current + offset
        if proposed < 0 { proposed = 0 }
        if proposed >= count { proposed = count - 1 }
        selectedIndex = proposed
    }

    /// Resets the selection. Called by the view when the query changes, so the
    /// highlight never lingers on a row the new filter has already removed.
    func resetSelection() {
        selectedIndex = nil
    }

    /// The id of the selected result, or nil when nothing is selected. Used by
    /// the view to scroll the selection into view.
    var selectedItemID: VaultItemID? {
        guard let selectedIndex, selectedIndex >= 0, selectedIndex < results.count else {
            return nil
        }
        return results[selectedIndex].id
    }

    /// The id to open for ↩: the selection when one exists, otherwise the first
    /// result. Nil when there is nothing to open.
    var openOnEnterItemID: VaultItemID? {
        if let selectedIndex, selectedIndex >= 0, selectedIndex < results.count {
            return results[selectedIndex].id
        }
        return results.first?.id
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
