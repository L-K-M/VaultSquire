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
                .onSubmit(openOnEnter)
                .onKeyPress(.upArrow) {
                    model.moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    model.moveSelection(by: 1)
                    return .handled
                }
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

            if model.isUnlocked && !model.results.isEmpty {
                footer
            }
        }
        .frame(width: 620, height: 360)
        .background(.regularMaterial)
        .onAppear(perform: focusSearchField)
        .onChange(of: model.presentationID) { _, _ in
            focusSearchField()
        }
        .onChange(of: model.query) { _, _ in
            // A new filter can shrink the list past the selection; drop it so
            // the highlight never points at a row that is no longer there.
            model.resetSelection()
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
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        let selected = model.selectedIndex == index
                        Button {
                            open(item.id)
                        } label: {
                            resultRow(item, isSelected: selected)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            selected ? Color.accentColor.opacity(0.18) : Color.clear
                        )
                        .id(item.id)
                    }
                }
                .listStyle(.plain)
                .accessibilityIdentifier("quick-search-results")
                .onChange(of: model.selectedItemID) { _, id in
                    guard let id else { return }
                    withAnimation(.snappy(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private func resultRow(_ item: VaultItemProjection, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            QuickSearchMonogram(identity: item.iconIdentity, category: item.category)
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

    private var footer: some View {
        HStack(spacing: 10) {
            hint("↑", "navigate")
            hint("↓", "navigate")
            hint("↩", "open")
            hint("esc", "dismiss")
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 7)
        .accessibilityHidden(true)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.caption)
        }
        .foregroundStyle(.tertiary)
    }

    private func openOnEnter() {
        guard model.isUnlocked, let id = model.openOnEnterItemID else { return }
        open(id)
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

/// The deterministic badge drawn beside a Quick Search result.
///
/// It mirrors `ItemIconView`'s monogram-and-category-symbol treatment but is
/// fully self-contained: the Quick Search panel is hosted in its own
/// `NSPanel` outside the main scene's environment, so it cannot reach the
/// shared `SiteIconStore`, and a transient quick-access panel should not fire
/// a favicon request per row in any case. The monogram is deterministic and
/// free, so a result's colour matches the main list's default look exactly.
private struct QuickSearchMonogram: View {
    let identity: ItemIconIdentity
    let category: VaultItemCategory
    var size: CGFloat = 24

    private var tint: Color {
        guard identity.host != nil else { return .secondary }
        return Color(hue: identity.hue, saturation: 0.62, brightness: 0.72)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
    }

    var body: some View {
        Group {
            if identity.host != nil {
                Text(identity.monogram)
                    .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                    .minimumScaleFactor(0.6)
            } else {
                Image(systemName: category.symbolName)
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .background(tint.opacity(0.18), in: shape)
        .overlay(shape.strokeBorder(tint.opacity(0.28), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}
