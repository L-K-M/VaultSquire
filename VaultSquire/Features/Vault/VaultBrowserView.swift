import SwiftUI

/// The main window once at least one vault is configured: a vault sidebar, the
/// item list for the selected scope, and the item detail.
///
/// Several vaults can be open at once. "All Vaults" merges every open vault's
/// items into one searchable list; selecting a single vault narrows to it and,
/// when that vault is closed, offers its own unlock. Every action is gated on
/// the capabilities of the vault that owns the item, so a read-only provider's
/// item never gains a write action by sitting next to a writable one.
struct VaultBrowserView: View {
    /// Presents the add-account sheet, which the root owns so one sheet serves
    /// both the empty shell and the browser.
    var onAddAccount: () -> Void = {}

    @EnvironmentObject private var appModel: AppModel
    @State private var selection: VaultItemID?
    @State private var query = ""
    @State private var editSession: EditSession?
    /// The password being typed for a locked vault, keyed by vault so switching
    /// between two locked vaults does not carry one field's text to the other.
    @State private var passwords: [AccountID: String] = [:]
    /// Which vaults have their container list expanded in the sidebar.
    @State private var expandedVaults: Set<AccountID> = []

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
            sidebar
        } content: {
            contentColumn
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
            // Quick Search spans every open vault, so jump the browser to the
            // scope that actually contains the chosen item.
            if case .vault(let account) = appModel.scope, account != newValue.account {
                appModel.scope = .allVaults
            }
            selection = newValue
            appModel.clearQuickSearchSelection()
        }
        .onChange(of: appModel.scope) { _, _ in
            selection = nil
        }
        .task {
            // Offer Touch ID as soon as the browser appears when it is set up,
            // so the common case is a fingerprint rather than a retyped master
            // password. The prompt is cancellable and the password field stays.
            if appModel.canUnlockWithBiometrics,
               appModel.session(for: .vaultwardenPrimary)?.isOpen == false {
                appModel.unlockWithBiometrics()
            }
        }
    }

    // MARK: - Sidebar

    private var scopeSelection: Binding<VaultScope?> {
        Binding(
            get: { appModel.scope },
            set: { if let value = $0 { appModel.scope = value } }
        )
    }

    private var sidebar: some View {
        List(selection: scopeSelection) {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("All Vaults").fontWeight(.medium)
                        Text(openSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "square.stack.3d.up")
                }
                .tag(VaultScope.allVaults)
                .accessibilityIdentifier("vault-scope-all")
            }

            Section("Vaults") {
                ForEach(appModel.sessions) { session in
                    // A vault with containers of its own — Proton's vaults,
                    // Vaultwarden's folders — expands to show them; one with
                    // none stays a plain row rather than an empty twisty.
                    if session.isOpen, !session.groups.isEmpty {
                        DisclosureGroup(isExpanded: expansion(for: session.account)) {
                            ForEach(session.groups) { group in
                                groupRow(group)
                                    .tag(VaultScope.group(session.account, group.id))
                            }
                        } label: {
                            vaultRow(session)
                                .tag(VaultScope.vault(session.account))
                        }
                    } else {
                        vaultRow(session)
                            .tag(VaultScope.vault(session.account))
                    }
                }
            }
        }
        .navigationTitle("VaultSquire")
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        .accessibilityIdentifier("vault-sidebar")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(action: onAddAccount) {
                    Label("Add Account", systemImage: "person.badge.plus")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("open-add-account")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var openSummary: String {
        let open = appModel.sessions.filter(\.isOpen).count
        guard open > 0 else { return "Nothing open" }
        return "\(appModel.allOpenItems.count) items in \(open) open"
    }

    private func vaultRow(_ session: VaultSlot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: session.isOpen ? "lock.open" : "lock")
                .foregroundStyle(session.isOpen ? Color.accentColor : .secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).lineLimit(1)
                Text(rowSubtitle(session))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if session.isOpening || session.isSyncing {
                ProgressView().controlSize(.small)
            } else if session.isOpen {
                Button {
                    appModel.lock(session.account)
                } label: {
                    Image(systemName: "lock")
                }
                .buttonStyle(.borderless)
                .help("Lock \(session.title)")
                .accessibilityIdentifier("vault-lock-\(session.account.rawValue)")
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("vault-row-\(session.account.rawValue)")
    }

    /// One container inside a vault. Indented by the disclosure group itself,
    /// so the row only carries its own name and count.
    private func groupRow(_ group: VaultGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(group.name).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(group.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("vault-group-\(group.id)")
    }

    /// Per-vault expansion state, so expanding one container list does not
    /// collapse another and the choice survives a re-render.
    private func expansion(for account: AccountID) -> Binding<Bool> {
        Binding(
            get: { expandedVaults.contains(account) },
            set: { isExpanded in
                if isExpanded {
                    expandedVaults.insert(account)
                } else {
                    expandedVaults.remove(account)
                }
            }
        )
    }

    private func rowSubtitle(_ session: VaultSlot) -> String {
        if case .failed(let message) = session.state { return message }
        if session.isOpening { return "Opening…" }
        if session.isOpen { return "\(session.items.count) items" }
        return session.subtitle
    }

    // MARK: - Content column

    @ViewBuilder
    private var contentColumn: some View {
        if let session = appModel.selectedSession, !session.isOpen {
            lockedVaultPane(session)
        } else if appModel.isUnlocked {
            itemList
        } else {
            ContentUnavailableView(
                "No vault is open",
                systemImage: "lock",
                description: Text("Select a vault to open it.")
            )
        }
    }

    private var itemList: some View {
        List(filteredItems, selection: $selection) { item in
            itemRow(item)
                .tag(item.id)
        }
        .searchable(text: $query, prompt: searchPrompt)
        .navigationTitle(scopeTitle)
        .accessibilityIdentifier("vault-item-list")
    }

    private var scopeTitle: String {
        switch appModel.scope {
        case .allVaults:
            return "All Vaults"
        case .vault(let account):
            return appModel.session(for: account)?.title ?? "Vault"
        case .group(let account, let group):
            // The scope carries the container's identifier, which for Proton is
            // a share id, so the name is resolved rather than displayed raw.
            return appModel.session(for: account)?
                .groups.first { $0.id == group }?.name ?? "Vault"
        }
    }

    private var searchPrompt: String {
        appModel.scope == .allVaults ? "Search every open vault" : "Search this vault"
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
                HStack(spacing: 6) {
                    if let subtitle = item.displaySubtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    // In a merged list the same title can come from two vaults,
                    // so name the source rather than leaving them ambiguous.
                    if appModel.scope == .allVaults,
                       let vault = appModel.session(for: item.id.account) {
                        Text(vault.title)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Locked vault pane

    @ViewBuilder
    private func lockedVaultPane(_ session: VaultSlot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(session.title)
                .font(.title2.weight(.semibold))
            Text(session.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)

            switch session.kind {
            case .vaultwarden:
                SecureField("Master password", text: passwordBinding(session.account))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit { submitUnlock(session.account) }
                    .accessibilityIdentifier("unlock-password")

                HStack(spacing: 10) {
                    Button {
                        submitUnlock(session.account)
                    } label: {
                        if session.isOpening {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Unlock")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled((passwords[session.account] ?? "").isEmpty || session.isOpening)
                    .accessibilityIdentifier("unlock-submit")

                    if appModel.canUnlockWithBiometrics {
                        Button {
                            appModel.unlockWithBiometrics()
                        } label: {
                            Label("Use Touch ID", systemImage: "touchid")
                        }
                        .disabled(session.isOpening)
                        .accessibilityIdentifier("unlock-biometrics")
                    }
                }
            case .proton:
                Text("VaultSquire reads this vault through the official Proton Pass CLI you signed in to.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    appModel.open(session.account)
                } label: {
                    if session.isOpening {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Open Vault")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.isOpening)
                .accessibilityIdentifier("open-proton-vault")
            case .onePassword:
                Text("VaultSquire reads these vaults through the official 1Password CLI. Your 1Password app will ask you to authorize it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    appModel.open(session.account)
                } label: {
                    if session.isOpening {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Open Vault")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.isOpening)
                .accessibilityIdentifier("open-onepassword-vault")
            }

            if case .failed(let message) = session.state {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("unlock-error")
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationTitle(session.title)
    }

    private func passwordBinding(_ account: AccountID) -> Binding<String> {
        Binding(
            get: { passwords[account] ?? "" },
            set: { passwords[account] = $0 }
        )
    }

    private func submitUnlock(_ account: AccountID) {
        let password = passwords[account] ?? ""
        guard !password.isEmpty else { return }
        appModel.unlock(account, password: password)
        passwords[account] = ""
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let selection, let detail = appModel.detail(for: selection) {
            VaultItemDetailView(detail: detail)
                .id(selection)
                // A CLI provider's item has its secret fields fetched the first
                // time it is opened, because listing deliberately carries none;
                // a Vaultwarden item already has them in memory.
                .task(id: selection) { appModel.hydrateIfNeeded(selection) }
        } else {
            ContentUnavailableView {
                Label("Select an item", systemImage: "list.bullet.rectangle")
            } description: {
                if let error = appModel.syncError {
                    Text("\(appModel.items.count) items in this scope.\n\(error)")
                } else {
                    Text("\(appModel.items.count) items in this scope.")
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 6) {
                if appModel.isSyncing {
                    ProgressView().controlSize(.small)
                    Text("Syncing…").font(.caption).foregroundStyle(.secondary)
                } else if let error = appModel.syncError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(error)
                        .accessibilityIdentifier("vault-sync-error")
                } else if let date = appModel.lastSyncedAt {
                    // The toolbar draws a fixed-size background behind this
                    // item; without fixedSize the label is compressed and its
                    // text clips against the edges of that bubble. The
                    // abbreviated form ("2 min ago") also keeps it short.
                    Text(date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("Last synced \(date.formatted(.relative(presentation: .named)))")
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                editSession = EditSession(draft: VaultItemDraft())
            } label: {
                Label("Add Item", systemImage: "plus")
            }
            .disabled(!appModel.canCreateItems || appModel.isWriting)
            .keyboardShortcut("n", modifiers: .command)
            .help(appModel.canCreateItems
                ? "Add an item"
                : "Select one writable vault to add an item to")
            .accessibilityIdentifier("vault-add")

            Button {
                guard let selection, let draft = appModel.draft(for: selection) else { return }
                editSession = EditSession(draft: draft)
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
            .disabled(selection.map { !appModel.canArchive($0) } ?? true || appModel.isWriting)
            .accessibilityIdentifier("vault-archive")

            Button {
                appModel.syncNow()
            } label: {
                Label("Sync", systemImage: "arrow.clockwise")
            }
            .disabled(appModel.isSyncing || !appModel.isUnlocked)
            .accessibilityIdentifier("vault-sync")

            Button {
                appModel.lock()
            } label: {
                Label("Lock All", systemImage: "lock")
            }
            .disabled(!appModel.isUnlocked)
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
