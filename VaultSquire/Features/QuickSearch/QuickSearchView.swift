import SwiftUI

struct QuickSearchView: View {
    @ObservedObject var model: QuickSearchPanelModel
    let onDismiss: () -> Void

    @FocusState private var searchFocused: Bool

    /// The keycap glyph size, scaled with the user's text size so the chips
    /// keep their lead over the labels rather than clipping against them at
    /// accessibility sizes.
    @ScaledMetric(relativeTo: .callout) private var keyCapSize: CGFloat = 18

    /// The text colour for the highlighted row. Taken from the system rather
    /// than hardcoded white: the highlight is drawn in the selection colour,
    /// and white on a light or high-contrast accent is unreadable.
    private var selectedForeground: Color { Color(nsColor: .selectedMenuItemTextColor) }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            Divider()

            content

            footer
        }
        .frame(width: 620, height: 366)
        .background(.regularMaterial)
        .onAppear(perform: focusSearchField)
        .onChange(of: model.presentationID) { _, _ in
            focusSearchField()
        }
        .onExitCommand(perform: onDismiss)
        // The arrow keys are not handled here. The search field holds first
        // responder and AppKit's field editor implements `moveUp:`/`moveDown:`
        // itself, so it consumes them before an ancestor's `onKeyPress` ever
        // runs. `QuickSearchPanelController` installs a local key monitor
        // instead, which sees the event first. Return still opens the
        // highlighted row through `onSubmit`.
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search every open vault", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                // A safety net only: the key monitor swallows plain Return
                // first, and `perform` ignores a second call while one is
                // running, so the two cannot both fire.
                .onSubmit(performPrimary)
                .accessibilityIdentifier("quick-search-field")

            if model.isUnlocked, !model.results.isEmpty {
                // Says "20 of 340" when the cap truncated the list, so a capped
                // result set reads as "keep typing" rather than as the whole
                // answer.
                Text(model.totalMatchCount > model.results.count
                     ? "\(model.results.count) of \(model.totalMatchCount)"
                     : "\(model.results.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("\(model.results.count) of \(model.totalMatchCount) results")
            }

            keyCap("esc")
        }
        .padding(.horizontal, 22)
        .frame(height: 58)
    }

    @ViewBuilder
    private var content: some View {
        if !model.isUnlocked {
            ContentUnavailableView {
                Label("Vault locked", systemImage: "lock")
            } description: {
                Text("Unlock a configured account before searching.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("quick-search-locked")
        } else if model.results.isEmpty {
            ContentUnavailableView {
                Label("No matches", systemImage: "magnifyingglass")
            } description: {
                Text("No items match “\(model.query)”.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("quick-search-empty")
        } else {
            resultList
        }
    }

    /// The results, with the highlight drawn rather than left to the list's own
    /// selection: the search field owns first responder, so a `List` selection
    /// would render in its inactive grey exactly when the user is driving it
    /// from the keyboard.
    private var resultList: some View {
        ScrollViewReader { proxy in
            List(model.results) { item in
                resultRow(item, isSelected: model.selection == item.id)
                    .id(item.id)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { open(item.id) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("quick-search-results")
            .onChange(of: model.selection) { _, newValue in
                guard let newValue else { return }
                proxy.scrollTo(newValue)
            }
        }
    }

    private func resultRow(_ item: VaultItemProjection, isSelected: Bool) -> some View {
        let identity = item.iconIdentity
        return HStack(spacing: 10) {
            badge(identity, category: item.category, isSelected: isSelected)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayTitle).fontWeight(.medium).lineLimit(1)
                if let subtitle = item.displaySubtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(isSelected ? selectedForeground.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let vault = model.vaultTitle(for: item.id) {
                Text(vault)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        isSelected ? selectedForeground.opacity(0.22) : Color.secondary.opacity(0.15),
                        in: Capsule()
                    )
                    .foregroundStyle(isSelected ? selectedForeground : Color.secondary)
            }
            if isSelected {
                // The primary action is not the same for every item, so the row
                // has to say which one Return will run.
                let action = QuickSearchPanelModel.primaryAction(for: item)
                HStack(spacing: 4) {
                    Text(action.title)
                    Image(systemName: "return")
                }
                .font(.caption)
                .foregroundStyle(selectedForeground.opacity(0.8))
                .accessibilityLabel("Return: \(action.title)")
            }
        }
        .foregroundStyle(isSelected ? selectedForeground : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
    }

    /// A small monogram or category badge. Deliberately not `ItemIconView`:
    /// this panel is hosted outside the main window's environment and has no
    /// site-icon store, and a launcher should never start a network request for
    /// a row that scrolls past.
    private func badge(
        _ identity: ItemIconIdentity,
        category: VaultItemCategory,
        isSelected: Bool
    ) -> some View {
        let tint = identity.host == nil
            ? Color.secondary
            : Color(hue: identity.hue, saturation: 0.62, brightness: 0.72)
        return Group {
            if identity.host == nil {
                Image(systemName: category.symbolName).font(.system(size: 11))
            } else {
                Text(identity.monogram)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(isSelected ? selectedForeground : tint)
        .frame(width: 22, height: 22)
        .background(
            (isSelected ? selectedForeground.opacity(0.22) : tint.opacity(0.18)),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .accessibilityHidden(true)
    }

    private func performPrimary() {
        model.perform(.primary)
    }

    private func open(_ id: VaultItemID) {
        model.select(id)
        model.perform(.primary)
    }

    /// Says what Return will do, and reports a copy that could not happen.
    /// Never shows a value — only these fixed labels.
    @ViewBuilder
    private var footer: some View {
        Divider()
        HStack(spacing: 12) {
            switch model.actionState {
            case .fetching(_, let value):
                ProgressView().controlSize(.small)
                Text("Fetching \(value.name.lowercased())…")
            case .failed(let value, let outcome):
                Image(systemName: "exclamationmark.triangle")
                Text(Self.message(for: value, outcome))
            case .idle:
                // At extreme text sizes the hints shrink before they may
                // truncate: a clipped shortcut is a hidden feature. Scoped
                // to the hints — the fetching and failure branches above
                // keep every line of their messages.
                Group {
                    // Only what the highlighted row can actually do. The
                    // hints used to be a fixed set, which advertised
                    // Username and One-time code for rows that have neither
                    // — pressing the key then earned an error — and never
                    // said the word "Password" for a row whose Return had
                    // fallen back to Show, which read as "this panel cannot
                    // hand out a password at all".
                    if let item = model.selectedProjection {
                        let primary = QuickSearchPanelModel.primaryAction(for: item)
                        hint("↩", primary.title)
                        if QuickSearchPanelModel.offersUsername(item) {
                            hint("⇧↩", "Username")
                        }
                        if QuickSearchPanelModel.offersOneTimeCode(item) {
                            hint("⌥↩", "One-time code")
                        }
                        if primary != .show {
                            // Short here, spelled out on the row: four hints
                            // and the full phrase do not fit the panel's
                            // width together.
                            hint("⌘↩", "Show")
                        }
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 22)
        .frame(minHeight: 38)
        .accessibilityIdentifier("quick-search-footer")
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            keyCap(keys)
            Text(label)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Self.spokenKeys(keys)) \(label)")
    }

    /// The spoken form of a key-cap string: VoiceOver gets "Shift Return"
    /// rather than raw glyphs, whose Unicode names it may read out literally
    /// (↩ is "leftwards arrow with hook"), and "Escape" rather than "e-s-c".
    /// Whole keys, not substring replacements, so a future cap can neither be
    /// mangled by a partial match nor leave a trailing blank.
    private static func spokenKeys(_ keys: String) -> String {
        if keys == "esc" { return "Escape" }
        let names = ["⇧": "Shift", "⌥": "Option", "⌘": "Command", "↩": "Return"]
        return keys.map { names[String($0)] ?? String($0) }.joined(separator: " ")
    }

    /// A key glyph with enough presence to read at a glance.
    ///
    /// The modifier-and-Return combinations are the whole interface of this
    /// footer, and at caption-adjacent sizes ⇧ and ⌥ collapse into blobs one
    /// squint away from each other. The chips are therefore set much larger
    /// and heavier than the labels beside them — the inverse of the usual
    /// hierarchy, justified by these being symbols with no surrounding word
    /// to guess them from. The search field's `esc` shares the shape.
    private func keyCap(_ keys: String) -> some View {
        Text(keys)
            .font(.system(size: keyCapSize, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(Self.spokenKeys(keys))
    }

    private static func message(
        for value: QuickSearchCopy,
        _ outcome: SecretDeliveryOutcome
    ) -> String {
        switch outcome {
        case .noSuchValue: return "This item has no \(value.name.lowercased())."
        case .notPermitted: return "That vault is no longer open."
        case .fetchFailed: return "\(value.name) could not be read from the provider."
        // A delivery that worked says so on the confirmation panel, over the
        // application the value went into — not here, where the panel it
        // would appear in has already gone.
        case .typed, .copied, .cancelled: return ""
        }
    }

    /// Claims keyboard focus for the search field.
    ///
    /// `onAppear` alone is not enough on two counts: it fires only for the first
    /// presentation, so re-showing the panel after `orderOut` left focus behind,
    /// and it can run before the panel holds key status, in which case macOS 26
    /// leaves first responder on the window and the field never becomes
    /// typeable. The controller therefore announces each presentation after the
    /// panel is key, and the assignment is deferred one turn so it lands after
    /// SwiftUI has finished the update that presentation triggered.
    private func focusSearchField() {
        Task { @MainActor in
            searchFocused = true
        }
    }
}
