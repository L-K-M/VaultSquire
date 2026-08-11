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
    @EnvironmentObject private var siteIcons: SiteIconStore
    @StateObject private var searchModel = VaultItemSearchModel(
        resultLimit: 250,
        emptyQueryLimit: 200
    )
    @State private var selection: VaultItemID?
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
        .onChange(of: appModel.items) { _, newValue in
            searchModel.updateItems(newValue)
        }
        .onChange(of: appModel.isUnlocked) { _, newValue in
            if !newValue {
                searchModel.resetQuery()
            }
        }
        .onChange(of: appModel.selectedSession?.isOpen) { _, newValue in
            if newValue == false {
                searchModel.resetQuery()
            }
        }
        .task {
            searchModel.updateItems(appModel.items, isUnlocked: appModel.isUnlocked)
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
                // Laid out like a vault row, gutter included, so its icon sits
                // in the same column as theirs even though it has no twisty.
                HStack(spacing: 8) {
                    Color.clear.frame(width: 12, height: 12)
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("All Vaults").fontWeight(.medium)
                        Text(openSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
                .padding(.vertical, 2)
                .tag(VaultScope.allVaults)
                .accessibilityIdentifier("vault-scope-all")
            }

            // A vault with containers of its own — Proton's vaults,
            // Vaultwarden's folders — expands to show them; one with none has
            // no twisty at all.
            //
            // The rows are flat with a twisty of their own rather than nested in
            // a DisclosureGroup, whose built-in triangle aligns to the top of
            // its label. A vault row is two lines tall, so that put the triangle
            // level with the title while everything beside it — the lock, both
            // lines of text — was centred on the pair.
            Section("Vaults") {
                ForEach(appModel.sessions) { session in
                    vaultRow(session)
                        .tag(VaultScope.vault(session.account))
                    if session.isOpen, expandedVaults.contains(session.account) {
                        ForEach(session.groups) { group in
                            groupRow(group)
                                .tag(VaultScope.group(session.account, group.id))
                        }
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
        HStack(spacing: 8) {
            disclosureControl(session)
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

    /// The twisty at the head of a vault row. It sits in the row's own HStack,
    /// so it is centred on the row rather than pinned to the first line. A vault
    /// with no containers still reserves the width, so every vault's lock icon
    /// and title line up whether or not that vault can expand.
    @ViewBuilder
    private func disclosureControl(_ session: VaultSlot) -> some View {
        if session.isOpen, !session.groups.isEmpty {
            let isExpanded = expandedVaults.contains(session.account)
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    toggleExpansion(session.account)
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse \(session.title)" : "Expand \(session.title)")
            .accessibilityIdentifier("vault-disclosure-\(session.account.rawValue)")
        } else {
            Color.clear.frame(width: 12, height: 12)
        }
    }

    /// One container inside a vault, indented one level past its vault so the
    /// nesting is visible: the twisty gutter plus a step, which puts a folder
    /// icon clear of the lock icon above it.
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
        .padding(.leading, 32)
        .accessibilityIdentifier("vault-group-\(group.id)")
    }

    /// Per-vault expansion state, so expanding one container list does not
    /// collapse another and the choice survives a re-render.
    private func toggleExpansion(_ account: AccountID) {
        if expandedVaults.contains(account) {
            expandedVaults.remove(account)
        } else {
            expandedVaults.insert(account)
        }
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
        VStack(spacing: 0) {
            List(searchModel.results, selection: $selection) { item in
                itemRow(item)
                    .tag(item.id)
            }
            statusBar
        }
        .searchable(text: $searchModel.query, prompt: searchPrompt)
        .navigationTitle(scopeTitle)
        .accessibilityIdentifier("vault-item-list")
    }

    private var statusBar: some View {
        HStack {
            if searchModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(summaryText(showing: searchModel.results.count, total: searchModel.totalMatchCount))
            } else {
                Text(summaryText(showing: searchModel.results.count, total: searchModel.totalMatchCount, noun: "matches"))
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func summaryText(showing: Int, total: Int, noun: String = "items") -> String {
        guard total > showing else { return "\(total) \(noun)" }
        return "Showing \(showing) of \(total) \(noun)"
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
            ItemIconView(identity: item.iconIdentity, category: item.category)
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
            // The toolbar draws a capsule that hugs this content. Without the
            // inset the text runs to both edges of it; `fixedSize` keeps the
            // label from being compressed back inside them.
            .padding(.horizontal, 7)
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
                // The icons on screen name the sites in the vault, so locking
                // everything takes them down with the items.
                siteIcons.clear()
            } label: {
                Label("Lock All", systemImage: "lock")
            }
            .disabled(!appModel.isUnlocked)
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .accessibilityIdentifier("vault-lock")
        }
    }

}
