import Foundation

/// What Return does to the highlighted row.
enum QuickSearchPrimaryAction: Hashable, Sendable {
    case copyPassword
    case show

    var title: String {
        switch self {
        // Verb-less, like the Username and One-time code hints: the same key
        // types the value into the previous application or copies it to the
        // clipboard depending on where the panel was summoned from, so
        // naming a verb would be wrong on one of the two routes.
        case .copyPassword: return "Password"
        case .show: return "Show in VaultSquire"
        }
    }
}

/// Everything Return and its modifiers can ask for.
enum QuickSearchAction: Hashable, Sendable {
    case primary
    case copyUsername
    case copyOneTimeCode
    case show
}

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
    /// How many items matched before the cap, so the count can say "20 of 340"
    /// rather than implying the vault holds only what fits on screen.
    @Published private(set) var totalMatchCount = 0

    /// Upper bound on rendered rows. Opening the panel with an empty query must
    /// not build a `List` over the whole corpus of a large vault; anything past
    /// this is reached by typing, which is what a launcher is for.
    static let maximumResults = 200

    /// What the panel is doing to the highlighted row.
    ///
    /// Cases rather than a formatted string: a message assembled by
    /// interpolation is one careless edit away from interpolating the value the
    /// panel is forbidden to render. Nothing here can hold a secret.
    enum ActionState: Equatable {
        case idle
        case fetching(VaultItemID, QuickSearchCopy)
        case failed(QuickSearchCopy, SecretDeliveryOutcome)
    }

    @Published private(set) var actionState: ActionState = .idle

    var isWorking: Bool {
        if case .fetching = actionState { return true }
        return false
    }

    private var onOpen: ((VaultItemID) -> Void)?
    private var onDeliver: ((
        QuickSearchCopy, VaultItemID, SecretDelivery, @escaping @MainActor () -> Void
    ) async -> SecretDeliveryOutcome)?
    /// Where a delivered value should go, supplied by the controller because it
    /// is the thing that knows which application the panel was summoned from.
    private var deliveryTarget: SecretDelivery = .clipboard
    private var onCancelCopy: ((VaultItemID) -> Void)?
    private var onFinish: ((Bool) -> Void)?
    private var onCopied: ((QuickSearchCopy, SecretDeliveryOutcome) -> Void)?
    private var activeCopy: Task<Void, Never>?
    /// The searchable text of each item, lowercased once when the item set is
    /// assigned. Matching re-reads these on every keystroke, and lowercasing a
    /// title, subtitle, username, every address and every folder label per item
    /// per character is the one cost in this panel that scales with vault size.
    ///
    /// `ItemSearchRow` rather than a private type of the panel's own, so the
    /// browser's list filter reads the same haystacks and folds case the same
    /// way. Ranking stays here: it is what makes this a launcher rather than a
    /// list, and the browser deliberately does not want it.
    private var rows: [ItemSearchRow] = []

    /// One scored match. A named type rather than a labelled tuple: inferring
    /// the tuple through `compactMap`/`Optional.map`/`sorted` in one chain is
    /// the other shape that makes type checking blow up here.
    fileprivate struct Scored {
        let score: Int
        let index: Int
        let item: VaultItemProjection
    }

    /// Drops everything the presentation held. `dismiss()` and the lock path
    /// both land here, so the panel must not keep a locked vault's titles,
    /// usernames, and addresses alive behind an invisible window.
    func clear() {
        cancelInFlightWork()
        // Before the query, so a didSet-driven recompute cannot repopulate
        // results from an item set that should already be gone.
        items = []
        rows = []
        vaultTitles = [:]
        onOpen = nil
        onDeliver = nil
        onCancelCopy = nil
        onFinish = nil
        onCopied = nil
        // The `query` didSet only fires when the value actually changes, so
        // Escape on an untouched panel would otherwise leave the results and
        // the highlight standing. Reset them explicitly afterwards.
        query.removeAll(keepingCapacity: false)
        results = []
        selection = nil
        isUnlocked = false
        totalMatchCount = 0
    }

    /// Loads a presentation's items and open handler and announces it, so the
    /// view claims focus after the panel is key.
    func present(
        items: [VaultItemProjection],
        isUnlocked: Bool,
        vaultTitles: [AccountID: String] = [:],
        onOpen: ((VaultItemID) -> Void)?,
        onDeliver: ((
            QuickSearchCopy, VaultItemID, SecretDelivery, @escaping @MainActor () -> Void
        ) async -> SecretDeliveryOutcome)? = nil,
        deliveryTarget: SecretDelivery = .clipboard,
        onCancelCopy: ((VaultItemID) -> Void)? = nil,
        onFinish: ((Bool) -> Void)? = nil,
        onCopied: ((QuickSearchCopy, SecretDeliveryOutcome) -> Void)? = nil
    ) {
        self.items = items
        self.rows = items.map(ItemSearchRow.init)
        self.isUnlocked = isUnlocked
        self.vaultTitles = vaultTitles
        self.onOpen = onOpen
        self.onDeliver = onDeliver
        self.deliveryTarget = deliveryTarget
        self.onCancelCopy = onCancelCopy
        self.onFinish = onFinish
        self.onCopied = onCopied
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
        self.rows = items.map(ItemSearchRow.init)
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
        clearFailure()
        guard !results.isEmpty else { return }
        let current = selection.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
        let next = min(max(current + offset, 0), results.count - 1)
        selection = results[next].id
    }

    /// Moves the highlight to a row the user clicked, so the action that
    /// follows applies to it rather than to whatever the keyboard was on.
    func select(_ id: VaultItemID) {
        clearFailure()
        guard results.contains(where: { $0.id == id }) else { return }
        selection = id
    }

    func selectFirst() {
        clearFailure()
        selection = results.first?.id
    }

    func selectLast() {
        clearFailure()
        selection = results.last?.id
    }

    /// Shows the highlighted row in VaultSquire. Kept as the name for "take me
    /// to this item" now that Return no longer always means that.
    func openSelection() {
        guard isUnlocked, let selection else { return }
        open(selection)
    }

    func open(_ id: VaultItemID) {
        onOpen?(id)
        onFinish?(false)
    }

    // MARK: - Actions

    /// What Return does to this row, decided from the projection alone.
    ///
    /// Never from the decrypted detail: `detail(for:)` decrypts and the
    /// highlighted row changes on every arrow key, and it would still answer
    /// "unknown" for both CLI providers, whose listings carry no secrets — the
    /// same login would offer Copy Password under Vaultwarden and something
    /// else under 1Password. Cards and notes are excluded on purpose:
    /// `AppModel.secretValue` returns the first `.secret` field, which for a
    /// card is its number, and a panel that shows nothing before it dismisses
    /// must not copy a card number under a label that says Password.
    static func primaryAction(for item: VaultItemProjection) -> QuickSearchPrimaryAction {
        guard item.category == .login, item.capabilities.contains(.copySecret) else {
            return .show
        }
        return .copyPassword
    }

    /// Whether ⇧↩ has anything to deliver for this row. The footer's hint and
    /// the key handler both read this one check, so the two cannot drift
    /// apart and advertise a key that only earns an error.
    static func offersUsername(_ item: VaultItemProjection) -> Bool {
        item.username?.isEmpty == false
    }

    /// Whether ⌥↩ has anything to deliver for this row — the same pairing as
    /// `offersUsername`. False for both CLI providers by construction, so
    /// neither surface offers what their listings cannot produce.
    static func offersOneTimeCode(_ item: VaultItemProjection) -> Bool {
        item.hasOneTimeCode
    }

    func perform(_ action: QuickSearchAction) {
        guard isUnlocked, let id = selection,
              let item = results.first(where: { $0.id == id }),
              !isWorking else {
            return
        }
        switch action {
        case .primary:
            switch Self.primaryAction(for: item) {
            case .copyPassword: copy(.password, of: item)
            case .show: show(item)
            }
        case .copyUsername:
            guard Self.offersUsername(item) else {
                actionState = .failed(.username, .noSuchValue)
                return
            }
            copy(.username, of: item)
        case .copyOneTimeCode:
            guard Self.offersOneTimeCode(item) else {
                actionState = .failed(.oneTimeCode, .noSuchValue)
                return
            }
            copy(.oneTimeCode, of: item)
        case .show:
            show(item)
        }
    }

    /// The panel stays up until the clipboard actually holds the value. Both
    /// CLI providers list without secrets, so Return on one of their items
    /// starts a fetch that can take seconds; dismissing first would hand focus
    /// back to another application and then change the clipboard under the
    /// user — over whatever they copied in the meantime.
    private func copy(_ value: QuickSearchCopy, of item: VaultItemProjection) {
        guard let onDeliver else { return }
        // Captured by value: `beforeDelivery` takes the panel down, which
        // clears these, and the announcement still has to happen afterwards.
        let finish = onFinish
        let announce = onCopied
        actionState = .fetching(item.id, value)
        activeCopy = Task { [weak self] in
            let outcome = await onDeliver(value, item.id, self?.deliveryTarget ?? .clipboard) {
                // The value is in hand. Take the panel down and hand focus
                // back before it is delivered — and clear the task first, so
                // the teardown does not cancel the task it is running inside.
                self?.activeCopy = nil
                self?.actionState = .idle
                finish?(true)
            }
            switch outcome {
            case .typed, .copied:
                announce?(value, outcome)
            case .cancelled:
                self?.actionState = .idle
            case .noSuchValue, .notPermitted, .fetchFailed:
                self?.activeCopy = nil
                self?.actionState = .failed(value, outcome)
            }
        }
    }

    /// The one action that means "take me into VaultSquire", so it is the one
    /// dismissal that does not hand focus back to another application.
    private func show(_ item: VaultItemProjection) {
        open(item.id)
    }

    /// Abandons a copy the user walked away from. The provider fetch itself
    /// keeps running — it belongs to `AppModel`, not to us — but the value it
    /// produces must not reach the clipboard: by then the user has moved on and
    /// may have copied something of their own.
    func cancelInFlightWork() {
        if case .fetching(let id, _) = actionState {
            onCancelCopy?(id)
        }
        activeCopy?.cancel()
        activeCopy = nil
        actionState = .idle
    }

    /// A failure message belongs to one keystroke, so it never outlives the row
    /// it was about.
    private func clearFailure() {
        if case .failed = actionState { actionState = .idle }
    }

    func notePresented() {
        presentationID += 1
    }

    // MARK: - Matching

    private func recomputeResults() {
        // A refusal was about the row the user was on when they pressed the
        // key; a new query is a new question.
        clearFailure()
        let matches = Self.ranked(rows: rows, query: query)
        totalMatchCount = matches.count
        results = Array(matches.prefix(Self.maximumResults))
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
    /// buried mid-word. Ties keep the order the items were given in, which for
    /// the panel is `AppModel.allOpenItems` — sorted by title there, so that
    /// equal-scoring matches from two vaults interleave alphabetically instead
    /// of arriving in vault-by-vault blocks.
    static func ranked(
        _ items: [VaultItemProjection],
        query: String
    ) -> [VaultItemProjection] {
        ranked(rows: items.map(ItemSearchRow.init), query: query)
    }

    /// The ranking the panel actually runs, over haystacks lowercased once when
    /// the item set was assigned rather than once per keystroke.
    fileprivate static func ranked(rows: [ItemSearchRow], query: String) -> [VaultItemProjection] {
        // The same normalization the browser's filter applies, so a query that
        // is all whitespace means "no filter" in both places rather than
        // matching every row on a `contains("")` in one of them.
        guard let needle = ItemSearchRow.normalize(query) else { return rows.map(\.item) }

        var scored: [Scored] = []
        scored.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            guard let value = score(row: row, needle: needle) else { continue }
            scored.append(Scored(score: value, index: index, item: row.item))
        }
        scored.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score < rhs.score
        }

        var ordered: [VaultItemProjection] = []
        ordered.reserveCapacity(scored.count)
        for match in scored {
            ordered.append(match.item)
        }
        return ordered
    }

    /// How well one item matches an already-lowercased, non-empty needle, or
    /// nil for no match at all. Lower is better.
    static func score(_ item: VaultItemProjection, needle: String) -> Int? {
        score(row: ItemSearchRow(item), needle: needle)
    }

    fileprivate static func score(row: ItemSearchRow, needle: String) -> Int? {
        let title = row.title
        if title == needle { return 0 }
        if title.hasPrefix(needle) { return 1 }
        if startsAWord(of: title, needle) { return 2 }
        if title.contains(needle) { return 3 }

        var best: Int?
        for lowered in row.others {
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
