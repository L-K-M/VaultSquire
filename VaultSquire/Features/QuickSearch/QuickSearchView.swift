import SwiftUI

struct QuickSearchView: View {
    @ObservedObject var model: QuickSearchPanelModel
    let onDismiss: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField("Search the unlocked vault", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit(openFirstResult)
                .accessibilityIdentifier("quick-search-field")

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
            List(model.results) { item in
                Button {
                    open(item.id)
                } label: {
                    resultRow(item)
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    model.selection == item.id
                        ? Color.accentColor.opacity(0.18)
                        : Color.clear
                )
            }
            .listStyle(.plain)
            .accessibilityIdentifier("quick-search-results")
        }
    }

    private func resultRow(_ item: VaultItemProjection) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayTitle).fontWeight(.medium).lineLimit(1)
                if let subtitle = item.displaySubtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private func openFirstResult() {
        // The model resolves the highlighted result, falling back to the top
        // one; arrow keys move that highlight while the field keeps focus.
        guard model.openSelectionOrFirst() != nil else { return }
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
