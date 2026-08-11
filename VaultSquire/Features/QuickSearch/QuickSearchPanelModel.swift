import Foundation

@MainActor
final class QuickSearchPanelModel: ObservableObject {
    /// The typed query. Results and the highlighted row are recomputed on every
    /// change, so the panel always has a valid selection to open on Return.
    @Published var query = "" {
        didSet {
            guard oldValue != query else { return }
            recomputeResults()
        }
    }

    /// Incremented by the controller once the panel has been made key. The
    /// search field's focus is driven from this rather than from `onAppear`,
    /// which fires only for the first presentation and can run before the panel
    /// holds key status.
    @Published private(set) var presentationID = 0

    /// The searchable projections for this presentation, empty while locked.
    @Published private(set) var items: [VaultItemProjection] = []
    /// The matches for the current query, best first. Never contains secrets —
    /// projections carry display fields only.
    @Published private(set) var results: [VaultItemProjection] = []
    /// The highlighted row, which Return opens and the arrow keys move. Kept
    /// pointing at a row that still exists after every query change.
    @Published private(set) var selection: VaultItemID?
    /// Whether the vault is unlocked; drives the locked vs. results content.
    @Published private(set) var isUnlocked = false
    /// Display names for the open vaults, so a merged result can say which
    /// vault it came from rather than leaving two identically named logins
    /// indistinguishable.
    @Published private(set) var vaultTitles: [AccountID: String] = [:]

    private var onOpen: ((VaultItemID) -> Void)?

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
        recomputeResults()
        notePresented()
    }

    /// Replaces what an already-visible panel is searching, without disturbing
    /// the query, the focus, or a highlight that survived the change. A vault
    /// that locks or a sync that lands while the panel is up must not leave it
    /// offering items from a list that no longer exists.
    func update(
        items: [VaultItemProjection],
        isUnlocked: Bool,
        vaultTitles: [AccountID: String] = [:]
    ) {
        self.items = items
        self.isUnlocked = isUnlocked
        self.vaultTitles = vaultTitles
        recomputeResults()
    }

    /// The vault an item belongs to, for the row's badge. Nil when the panel
    /// was presented without titles, which is what the tests do.
    func vaultTitle(for id: VaultItemID) -> String? {
        vaultTitles[id.account]
    }

    // MARK: - Selection

    /// Moves the highlight by `offset` rows, clamped at both ends. Clamping
    /// rather than wrapping matches every other search field on the platform:
    /// holding the down arrow settles on the last row instead of cycling.
    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let current = selection.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
        let next = min(max(current + offset, 0), results.count - 1)
        selection = results[next].id
    }

    func selectFirst() {
        selection = results.first?.id
    }

    func selectLast() {
        selection = results.last?.id
    }

    func select(_ id: VaultItemID) {
        selection = id
    }

    /// Opens the highlighted row. Return runs this, so the panel opens what the
    /// user is looking at rather than always the first match.
    func openSelection() {
        guard isUnlocked, let selection else { return }
        open(selection)
    }

    func open(_ id: VaultItemID) {
        onOpen?(id)
    }

    func notePresented() {
        presentationID += 1
    }

    // MARK: - Matching

    private func recomputeResults() {
        results = Self.ranked(items, query: query)
        // Keep the highlight where it is when the row survived the edit;
        // otherwise fall to the new best match, so Return is always live.
        if let selection, results.contains(where: { $0.id == selection }) { return }
        selection = results.first?.id
    }

    /// The items matching `query`, best match first, or every item in the order
    /// given when the query is empty.
    ///
    /// Ranking matters more here than in the browser's list: the panel is a
    /// launcher, and alphabetical order means typing "git" offers "Digital
    /// Ocean" before "GitHub". A title match always beats a match on a
    /// subtitle, address, or folder; within a field, an exact match beats a
    /// prefix, a prefix beats the start of a later word, and that beats a match
    /// buried mid-word. Ties keep the order the vaults produced, which is
    /// already sorted by title.
    static func ranked(
        _ items: [VaultItemProjection],
        query: String
    ) -> [VaultItemProjection] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return items }
        return items.enumerated()
            .compactMap { index, item in
                score(item, needle: needle).map { (score: $0, index: index, item: item) }
            }
            .sorted { lhs, rhs in
                lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score < rhs.score
            }
            .map(\.item)
    }

    /// How well one item matches an already-lowercased, non-empty needle, or
    /// nil for no match at all. Lower is better.
    static func score(_ item: VaultItemProjection, needle: String) -> Int? {
        let title = item.displayTitle.lowercased()
        if title == needle { return 0 }
        if title.hasPrefix(needle) { return 1 }
        if startsAWord(of: title, needle) { return 2 }
        if title.contains(needle) { return 3 }

        let others = [item.displaySubtitle, item.username].compactMap { $0 }
            + item.websites + item.groupingLabels
        var best: Int?
        for value in others where !value.isEmpty {
            let lowered = value.lowercased()
            if lowered.hasPrefix(needle) || startsAWord(of: lowered, needle) { return 4 }
            if lowered.contains(needle) { best = 5 }
        }
        return best
    }

    /// Whether the needle starts a word in the haystack, so "pass" finds
    /// "Proton Pass" and "hub" does not outrank a title that begins with it.
    private static func startsAWord(of haystack: String, _ needle: String) -> Bool {
        haystack
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains { $0.hasPrefix(needle) }
    }
}
