import Foundation

/// One item's searchable text, lowercased once when the item set is built
/// rather than once per keystroke.
///
/// Both searches in the app read these. Quick Search ranks over them; the
/// browser's filter asks only whether they match. Lowercasing a title, a
/// subtitle, a username, every address and every folder label — per item, per
/// character typed — is the one cost in either search that scales with vault
/// size, and it is paid here once per item set instead.
///
/// The browser used to match with `localizedCaseInsensitiveContains` over a
/// haystack array it allocated per item per keystroke. That is an ICU
/// collation call per field per item per character, and it also meant the two
/// searches folded case differently: a query could match in Quick Search and
/// not in the list beside it. Both now fold the same way, because both read
/// the same rows.
struct ItemSearchRow: Sendable {
    let item: VaultItemProjection
    /// The item's title, lowercased. Quick Search ranks this ahead of `others`.
    let title: String
    /// Every other searchable field, lowercased, with empties dropped.
    let others: [String]

    // Built with explicit types and a plain loop rather than a chain of `+`
    // and `map`: overload resolution across concatenated arrays is one of the
    // shapes the Swift type checker takes exponential time on.
    init(_ item: VaultItemProjection) {
        self.item = item
        self.title = item.displayTitle.lowercased()

        var haystacks: [String] = []
        haystacks.reserveCapacity(item.websites.count + item.groupingLabels.count + 2)
        if let subtitle = item.displaySubtitle { haystacks.append(subtitle) }
        if let username = item.username { haystacks.append(username) }
        haystacks.append(contentsOf: item.websites)
        haystacks.append(contentsOf: item.groupingLabels)

        var lowered: [String] = []
        lowered.reserveCapacity(haystacks.count)
        for value in haystacks where !value.isEmpty {
            lowered.append(value.lowercased())
        }
        self.others = lowered
    }

    /// Whether any searchable field contains `needle`, which must already be
    /// lowercased and non-empty — `normalize(_:)` produces exactly that.
    ///
    /// The title is tested first because it is the field most queries are
    /// aimed at, so the common match returns without touching the rest.
    func matches(_ needle: String) -> Bool {
        if title.contains(needle) { return true }
        return others.contains { $0.contains(needle) }
    }

    /// The form a query has to be in before `matches(_:)` will see it: trimmed
    /// and lowercased, or nil when there is nothing left to search for.
    ///
    /// Returning nil rather than an empty string makes "no filter" a case the
    /// caller has to handle, which is what keeps an all-whitespace query from
    /// matching every row on a `contains("")`.
    static func normalize(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}
