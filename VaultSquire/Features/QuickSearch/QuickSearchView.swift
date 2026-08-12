import SwiftUI

struct QuickSearchView: View {
    @ObservedObject var model: QuickSearchPanelModel
    let onDismiss: () -> Void

    @FocusState private var searchFocused: Bool

    /// The text colour for the highlighted row. Taken from the system rather
    /// than hardcoded white: the highlight is drawn in the selection colour,
    /// and white on a light or high-contrast accent is unreadable.
    private var selectedForeground: Color { Color(nsColor: .selectedMenuItemTextColor) }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            Divider()

            content
        }
        .frame(width: 620, height: 330)
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
                .onSubmit(openSelection)
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

            Text("esc")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                .accessibilityHidden(true)
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
                Image(systemName: "return")
                    .font(.caption)
                    .foregroundStyle(selectedForeground.opacity(0.8))
                    .accessibilityHidden(true)
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

    private func openSelection() {
        guard model.isUnlocked, model.selection != nil else { return }
        model.openSelection()
        onDismiss()
    }

    private func open(_ id: VaultItemID) {
        model.open(id)
        onDismiss()
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
