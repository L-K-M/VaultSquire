import Foundation

@MainActor
final class VaultItemSearchModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard !suppressQuerySearch else { return }
            guard query != oldValue else { return }
            searchRevision &+= 1
            performSearch(for: searchRevision)
        }
    }
    @Published private(set) var results: [VaultItemProjection] = []
    @Published private(set) var totalMatchCount = 0

    /// Incremented by the controller once the panel has been made key. The
    /// search field's focus is driven from this rather than from `onAppear`,
    /// which fires only for the first presentation and can run before the panel
    /// holds key status.
    @Published private(set) var presentationID = 0

    /// The searchable projections for this presentation, empty while locked.
    @Published private(set) var items: [VaultItemProjection] = []
    /// Whether the vault is unlocked; drives the locked vs. results content.
    @Published private(set) var isUnlocked = false

    private let resultLimit: Int
    private let emptyQueryLimit: Int
    private let searchDelay: Duration
    private let buildDelay: Duration
    private var onOpen: ((VaultItemID) -> Void)?
    private var searchIndex = VaultItemSearchIndex(items: [])
    private var sourceRevision: UInt64 = 0
    private var searchRevision: UInt64 = 0
    private var buildTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var suppressQuerySearch = false

    init(
        resultLimit: Int = 200,
        emptyQueryLimit: Int = 50,
        searchDelay: Duration = .zero,
        buildDelay: Duration = .zero
    ) {
        self.resultLimit = resultLimit
        self.emptyQueryLimit = emptyQueryLimit
        self.searchDelay = searchDelay
        self.buildDelay = buildDelay
    }

    func clear() {
        cancelTasks()
        setQueryWithoutSearching("")
        results = []
        totalMatchCount = 0
        items = []
        isUnlocked = false
        searchIndex = VaultItemSearchIndex(items: [])
        onOpen = nil
    }

    /// Loads a presentation's items and open handler and announces it, so the
    /// view claims focus after the panel is key.
    func present(
        items: [VaultItemProjection],
        isUnlocked: Bool,
        onOpen: ((VaultItemID) -> Void)?
    ) {
        self.onOpen = onOpen
        setQueryWithoutSearching("")
        updateItems(items, isUnlocked: isUnlocked)
        notePresented()
    }

    func updateItems(_ items: [VaultItemProjection], isUnlocked: Bool = true) {
        cancelTasks()
        sourceRevision &+= 1
        let sourceRevision = sourceRevision
        self.items = items
        self.isUnlocked = isUnlocked
        results = []
        totalMatchCount = 0
        searchIndex = VaultItemSearchIndex(items: [])

        guard isUnlocked, !items.isEmpty else {
            return
        }

        let capturedItems = items
        let buildDelay = buildDelay
        buildTask = Task.detached(priority: .userInitiated) {
            if buildDelay > .zero {
                try? await Task.sleep(for: buildDelay)
            }
            guard !Task.isCancelled else { return }
            let index = VaultItemSearchIndex(items: capturedItems)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.sourceRevision == sourceRevision else { return }
                self.searchIndex = index
                self.searchRevision &+= 1
                self.performSearch(for: self.searchRevision)
            }
        }
    }

    func resetQuery() {
        guard !query.isEmpty || !results.isEmpty || totalMatchCount != 0 else { return }
        cancelSearch()
        setQueryWithoutSearching("")
        results = []
        totalMatchCount = 0
    }

    func refreshSearch() {
        searchRevision &+= 1
        performSearch(for: searchRevision)
    }

    func open(_ id: VaultItemID) {
        onOpen?(id)
    }

    func notePresented() {
        presentationID += 1
    }

    private func cancelTasks() {
        cancelSearch()
        buildTask?.cancel()
        buildTask = nil
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
    }

    private func setQueryWithoutSearching(_ value: String) {
        suppressQuerySearch = true
        query = value
        suppressQuerySearch = false
    }

    private func performSearch(for revision: UInt64) {
        cancelSearch()

        let index = searchIndex
        let query = query
        let resultLimit = resultLimit
        let emptyQueryLimit = emptyQueryLimit
        let searchDelay = searchDelay
        searchTask = Task.detached(priority: .userInitiated) {
            if searchDelay > .zero {
                try? await Task.sleep(for: searchDelay)
            }
            guard !Task.isCancelled else { return }
            let outcome = index.search(
                query: query,
                resultLimit: resultLimit,
                emptyQueryLimit: emptyQueryLimit
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.searchRevision == revision else { return }
                self.results = outcome.items
                self.totalMatchCount = outcome.totalMatchCount
            }
        }
    }
}

typealias QuickSearchPanelModel = VaultItemSearchModel

private struct VaultItemSearchIndex: Sendable {
    struct Outcome: Sendable {
        let items: [VaultItemProjection]
        let totalMatchCount: Int
    }

    private struct Entry: Sendable {
        enum Rank: Int, Sendable {
            case exactTitle
            case titlePrefix
            case usernameOrHostPrefix
            case contains
        }

        let item: VaultItemProjection
        let title: String
        let subtitle: String
        let username: String
        let websites: [String]
        let hosts: [String]
        let groups: [String]
        let sortKey: SortKey

        func rank(for query: Query) -> Rank? {
            let fields = [title, subtitle, username] + websites + hosts + groups
            guard query.terms.allSatisfy({ term in
                fields.contains { field in field.contains(term) }
            }) else {
                return nil
            }

            if title == query.normalized {
                return .exactTitle
            }
            if title.hasPrefix(query.normalized) {
                return .titlePrefix
            }
            if username.hasPrefix(query.normalized) || hosts.contains(where: { $0.hasPrefix(query.normalized) }) {
                return .usernameOrHostPrefix
            }
            return .contains
        }
    }

    private struct Query: Sendable {
        let normalized: String
        let terms: [String]
    }

    private struct SortKey: Comparable, Sendable {
        let title: String
        let subtitle: String
        let provider: String
        let account: String
        let space: String
        let item: String

        static func < (lhs: SortKey, rhs: SortKey) -> Bool {
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            if lhs.subtitle != rhs.subtitle { return lhs.subtitle < rhs.subtitle }
            if lhs.provider != rhs.provider { return lhs.provider < rhs.provider }
            if lhs.account != rhs.account { return lhs.account < rhs.account }
            if lhs.space != rhs.space { return lhs.space < rhs.space }
            return lhs.item < rhs.item
        }
    }

    private let entries: [Entry]

    init(items: [VaultItemProjection]) {
        entries = items
            .map(Self.entry(for:))
            .sorted { lhs, rhs in lhs.sortKey < rhs.sortKey }
    }

    func search(query: String, resultLimit: Int, emptyQueryLimit: Int) -> Outcome {
        let parsed = Self.parse(query: query)
        guard !parsed.normalized.isEmpty else {
            return Outcome(
                items: Array(entries.prefix(emptyQueryLimit).map(\.item)),
                totalMatchCount: entries.count
            )
        }

        var exact: [VaultItemProjection] = []
        var titlePrefix: [VaultItemProjection] = []
        var usernameOrHostPrefix: [VaultItemProjection] = []
        var contains: [VaultItemProjection] = []
        var totalMatchCount = 0

        for entry in entries {
            guard let rank = entry.rank(for: parsed) else { continue }
            totalMatchCount += 1
            switch rank {
            case .exactTitle:
                if exact.count < resultLimit { exact.append(entry.item) }
            case .titlePrefix:
                if titlePrefix.count < resultLimit { titlePrefix.append(entry.item) }
            case .usernameOrHostPrefix:
                if usernameOrHostPrefix.count < resultLimit { usernameOrHostPrefix.append(entry.item) }
            case .contains:
                if contains.count < resultLimit { contains.append(entry.item) }
            }
        }

        let items = Array((exact + titlePrefix + usernameOrHostPrefix + contains).prefix(resultLimit))
        return Outcome(items: items, totalMatchCount: totalMatchCount)
    }

    private static func entry(for item: VaultItemProjection) -> Entry {
        let title = normalize(item.displayTitle)
        let subtitle = normalize(item.displaySubtitle ?? "")
        let username = normalize(item.username ?? "")
        let websites = item.websites.map(normalize)
        let hosts = item.websites.compactMap(normalizedHost)
        let groups = item.groupingLabels.map(normalize)
        let sortKey = SortKey(
            title: title,
            subtitle: subtitle,
            provider: item.id.provider.rawValue,
            account: item.id.account.rawValue,
            space: spaceKey(item.id.space.scope),
            item: item.id.rawValue
        )
        return Entry(
            item: item,
            title: title,
            subtitle: subtitle,
            username: username,
            websites: websites,
            hosts: hosts,
            groups: groups,
            sortKey: sortKey
        )
    }

    private static func parse(query: String) -> Query {
        let normalized = normalize(query.replacingOccurrences(of: "\"", with: " "))
        guard !normalized.isEmpty else {
            return Query(normalized: "", terms: [])
        }

        var terms: [String] = []
        var buffer = ""
        var inQuotes = false

        for character in query {
            if character == "\"" {
                if !buffer.isEmpty {
                    let term = normalize(buffer)
                    if !term.isEmpty { terms.append(term) }
                    buffer.removeAll(keepingCapacity: true)
                }
                inQuotes.toggle()
                continue
            }

            if character.isWhitespace && !inQuotes {
                let term = normalize(buffer)
                if !term.isEmpty { terms.append(term) }
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(character)
            }
        }

        let tail = normalize(buffer)
        if !tail.isEmpty { terms.append(tail) }
        if terms.isEmpty { terms = [normalized] }
        return Query(normalized: normalized, terms: terms)
    }

    private static func normalize(_ string: String) -> String {
        string
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedHost(_ website: String) -> String? {
        let candidate = website.contains("://") ? website : "https://\(website)"
        guard let host = URLComponents(string: candidate)?.host else { return nil }
        return normalize(host)
    }

    private static func spaceKey(_ scope: VaultSpaceID.Scope) -> String {
        switch scope {
        case .personal:
            return ""
        case .providerSpace(let value):
            return value
        }
    }
}
