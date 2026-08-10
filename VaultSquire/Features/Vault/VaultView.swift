import SwiftUI

/// The unlocked vault: a searchable item list beside a detail pane. Shown only
/// while `AppModel` reports the vault unlocked; locking returns to the shell.
struct VaultView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var selection: VaultItemID?
    @State private var query = ""
    @State private var editSession: EditSession?

    /// Wraps a draft so it can drive an item-identified sheet.
    private struct EditSession: Identifiable {
        let id = UUID()
        let draft: VaultItemDraft
    }

    private var filteredItems: [VaultItemProjection] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return appModel.items }
        return appModel.items.filter { Self.matches($0, query: trimmed) }
    }

    var body: some View {
        NavigationSplitView {
            List(filteredItems, selection: $selection) { item in
                itemRow(item)
                    .tag(item.id)
            }
            .searchable(text: $query, prompt: "Search the unlocked vault")
            .navigationTitle("Vault")
            .accessibilityIdentifier("vault-item-list")
        } detail: {
            detailPane
        }
        .toolbar { toolbarContent }
        .accessibilityIdentifier("vault-view")
        .sheet(item: $editSession) { session in
            VaultItemEditView(draft: session.draft) { editSession = nil }
                .environmentObject(appModel)
        }
        .onChange(of: appModel.quickSearchSelection) { _, newValue in
            guard let newValue else { return }
            selection = newValue
            appModel.clearQuickSearchSelection()
        }
    }

    private func presentCreate() {
        editSession = EditSession(draft: VaultItemDraft())
    }

    private func presentEdit() {
        guard let selection, let draft = appModel.draft(for: selection) else { return }
        editSession = EditSession(draft: draft)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selection, let detail = appModel.detail(for: selection) {
            VaultItemDetailView(detail: detail)
                .id(selection)
        } else {
            ContentUnavailableView {
                Label("Select an item", systemImage: "list.bullet.rectangle")
            } description: {
                if let error = appModel.syncError {
                    // Surface the sync failure where there is room to read it;
                    // the toolbar has only an icon's worth of space.
                    Text("\(appModel.items.count) items in this vault.\n\(error)")
                } else {
                    Text("\(appModel.items.count) items in this vault.")
                }
            }
        }
    }

    private func itemRow(_ item: VaultItemProjection) -> some View {
        HStack(spacing: 12) {
            Image(systemName: Self.icon(for: item.category))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let subtitle = item.displaySubtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 6) {
                if appModel.isSyncing {
                    ProgressView().controlSize(.small)
                    Text("Syncing…").font(.caption).foregroundStyle(.secondary)
                } else if let error = appModel.syncError {
                    // The toolbar can collapse the text portion to nothing, so
                    // the full message is also a tooltip here and shown in the
                    // empty detail pane.
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(error)
                        .accessibilityIdentifier("vault-sync-error")
                } else if let date = appModel.lastSyncedAt {
                    Text("Synced \(date.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                presentCreate()
            } label: {
                Label("Add Item", systemImage: "plus")
            }
            .disabled(!appModel.canCreateItems || appModel.isWriting)
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityIdentifier("vault-add")

            Button {
                presentEdit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .disabled(selection.map { !appModel.canEdit($0) } ?? true || appModel.isWriting)
            .accessibilityIdentifier("vault-edit")

            Button {
                if let selection { appModel.archive(selection) }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .disabled(selection == nil || appModel.isWriting || !appModel.canArchiveItems)
            .accessibilityIdentifier("vault-archive")

            Button {
                appModel.syncNow()
            } label: {
                Label("Sync", systemImage: "arrow.clockwise")
            }
            .disabled(appModel.isSyncing)
            .accessibilityIdentifier("vault-sync")

            Button {
                appModel.lock()
            } label: {
                Label("Lock", systemImage: "lock")
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .accessibilityIdentifier("vault-lock")
        }
    }

    private static func matches(_ item: VaultItemProjection, query: String) -> Bool {
        let haystacks = [item.displayTitle, item.displaySubtitle ?? item.username ?? ""]
            + item.websites + item.groupingLabels
        return haystacks.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private static func icon(for category: VaultItemCategory) -> String {
        switch category {
        case .login: return "person.crop.circle"
        case .secureNote: return "note.text"
        case .card: return "creditcard"
        case .identity: return "person.text.rectangle"
        case .unsupported: return "questionmark.square.dashed"
        }
    }
}
