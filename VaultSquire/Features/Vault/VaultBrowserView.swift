import AppKit
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
    @State private var selection: VaultItemID?
    @State private var query = ""
    @State private var editSession: EditSession?
    /// The password being typed for a locked vault, keyed by vault so switching
    /// between two locked vaults does not carry one field's text to the other.
    ///
    /// Dropped as soon as the field it belongs to is no longer on screen — see
    /// `discardUnsubmittedPasswords()`. Only `submitUnlock` used to clear an
    /// entry, so a master password typed and then abandoned stayed in memory
    /// for the life of the process.
    @State private var passwords: [AccountID: String] = [:]
    /// Which vaults have their container list expanded in the sidebar.
    @State private var expandedVaults: Set<AccountID> = []
    /// The website awaiting confirmation to open, shown with the effective
    /// scheme and host the browser will actually visit — the same confirmation
    /// the detail pane gives before any URI leaves the app.
    @State private var pendingOpen: URIOpeningDecision?
    @State private var showOpenConfirmation = false
    /// The item awaiting archive confirmation. The dialog's presentation is
    /// derived from this rather than tracked separately, so dismissing it with
    /// Escape cannot leave a staged item behind.
    @State private var pendingArchive: VaultItemID?

    /// What the detail pane's hydration is keyed on: the item, and the
    /// generation of the fetched-secret store it was satisfied from.
    private struct HydrationKey: Equatable {
        let item: VaultItemID
        let epoch: UInt64
    }

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
            // Quick Search spans every open vault, so jump the browser to a
            // scope that actually contains the chosen item: a group or
            // single-vault scope that excludes it would swallow the selection.
            // The owning vault's scope is preferred over All Vaults so the
            // user's context narrows rather than resets.
            if !scopeContains(newValue) {
                appModel.scope = .vault(newValue.account)
            }
            // A filter left in the search field can hide the handed-off item
            // even once the scope is right, which would select a row the list
            // does not render. Quick Search asked for this item by name, so the
            // filter is what gives way.
            if !filteredItems.contains(where: { $0.id == newValue }) {
                query = ""
            }
            selection = newValue
            appModel.clearQuickSearchSelection()
        }
        .onChange(of: appModel.scope) { _, _ in
            discardUnsubmittedPasswords()
            // A new scope is a fresh list, so the filter typed for the old one
            // does not carry into it — the same thing Finder and Mail do when
            // the sidebar selection changes.
            query = ""
            // Clear the selection only when it is not visible in the new
            // scope. This handler also fires for the Quick Search jump above,
            // where clearing would undo the navigation it just performed.
            if let selection, !scopeContains(selection) {
                self.selection = nil
            }
        }
        .onChange(of: query) { _, _ in
            // A narrower filter can hide the selected row; drop the selection
            // so the detail pane never disagrees with the visible list.
            if let selection, !filteredItems.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
        }
        .confirmationDialog(
            "Archive this item?",
            isPresented: archiveConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Archive", role: .destructive) {
                if let pendingArchive {
                    appModel.archive(pendingArchive)
                }
                pendingArchive = nil
            }
            Button("Cancel", role: .cancel) { pendingArchive = nil }
        } message: {
            Text("\(archiveCandidateTitle) leaves every list and search here. VaultSquire cannot bring it back yet — you would restore it from your Vaultwarden app.")
        }
        .confirmationDialog(
            "Open this link?",
            isPresented: $showOpenConfirmation,
            titleVisibility: .visible
        ) {
            if let decision = pendingOpen {
                Button("Open \(decision.display)") {
                    NSWorkspace.shared.open(decision.url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let decision = pendingOpen {
                Text(decision.confirmationMessage)
            }
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

    /// Drives the archive dialog from `pendingArchive`, so Escape or a dismissal
    /// clears the staged item instead of leaving it armed for the next dialog.
    private var archiveConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingArchive != nil },
            set: { presented in
                if !presented { pendingArchive = nil }
            }
        )
    }

    /// The quoted name of the item being archived, so the dialog is about a
    /// specific entry rather than an abstract action.
    private var archiveCandidateTitle: String {
        guard let pendingArchive,
              let title = appModel.allOpenItems.first(where: { $0.id == pendingArchive })?.displayTitle,
              !title.isEmpty else {
            return "This item"
        }
        return "\u{201C}\(title)\u{201D}"
    }

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
                    // The cache is not partitioned by account. Clear it all so
                    // a site belonging only to this now-locked vault cannot
                    // remain in memory while another vault stays open.
                    siteIcons.clear()
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
                .safeAreaInset(edge: .bottom) { writeErrorBanner }
        } else {
            ContentUnavailableView(
                "No vault is open",
                systemImage: "lock",
                description: Text("Select a vault to open it.")
            )
        }
    }

    /// A write failure that happened outside the editor sheet.
    ///
    /// `writeError` is rendered inside that sheet, which is the only place it
    /// could ever appear — so archiving from the toolbar or from a row failed
    /// silently, and the message then turned up misattributed above the next
    /// form the user opened. Archive is also the one write with no undo here,
    /// which makes a silent failure the worst kind.
    @ViewBuilder
    private var writeErrorBanner: some View {
        if editSession == nil, let error = appModel.writeError {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(error)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Dismiss") { appModel.dismissWriteError() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
            .accessibilityIdentifier("vault-write-error")
        }
    }

    @ViewBuilder
    private var itemList: some View {
        let items = filteredItems
        Group {
            if items.isEmpty {
                emptyItemList
            } else {
                List(items, selection: $selection) { item in
                    itemRow(item)
                        .tag(item.id)
                        .contextMenu { itemActions(item) }
                }
            }
        }
        .searchable(text: $query, prompt: searchPrompt)
        .navigationTitle(scopeTitle)
        // On the Group rather than the List, so the identifier is present in
        // both states and a test for it does not fail on an empty vault.
        .accessibilityIdentifier("vault-item-list")
    }

    /// The row's own actions. Getting a password onto the clipboard is the
    /// single most common thing anyone does with this app, and it previously
    /// required selecting the item, waiting for its detail, and aiming at a
    /// sixteen-point button. Every copy goes through the same clipboard service
    /// the detail view uses, so a secret copied from a row expires and clears
    /// on lock exactly as one copied from the item does, and each action is
    /// gated on the owning vault's capabilities rather than on the row it
    /// happens to sit beside.
    @ViewBuilder
    private func itemActions(_ item: VaultItemProjection) -> some View {
        if let username = item.username, !username.isEmpty {
            Button("Copy Username") { appModel.copyUsername(item.id) }
                .accessibilityIdentifier("context-copy-username")
        }
        if appModel.canCopySecret(item.id) {
            Button("Copy Password") { appModel.copySecret(.password, of: item.id) }
                .accessibilityIdentifier("context-copy-password")
            if item.hasOneTimeCode {
                Button("Copy One-Time Code") { appModel.copySecret(.oneTimeCode, of: item.id) }
                    .accessibilityIdentifier("context-copy-totp")
            }
        }
        if let website = item.websites.first,
           let decision = URIOpeningPolicy.decision(for: website) {
            Divider()
            // Behind the same confirmation the detail pane gives: nothing
            // leaves for a browser without the user seeing where it goes.
            Button("Open \(decision.display)") {
                pendingOpen = decision
                showOpenConfirmation = true
            }
            .accessibilityIdentifier("context-open-website")
        }
        // Every predicate below is answered from the projection or the vault's
        // capabilities. Nothing here decrypts: the list may build this menu for
        // each visible row, so a decrypt per predicate would be a decrypt of
        // the whole vault on every redraw.
        if appModel.canOfferEdit(item.id) || appModel.canArchive(item.id) {
            Divider()
            if appModel.canOfferEdit(item.id) {
                Button("Edit…") {
                    guard let draft = appModel.draft(for: item.id) else { return }
                    editSession = EditSession(draft: draft)
                }
                .accessibilityIdentifier("context-edit")
            }
            if appModel.canArchive(item.id) {
                Button("Archive") { pendingArchive = item.id }
                    .accessibilityIdentifier("context-archive")
            }
        }
    }

    /// The empty state for the item list: "no matches" when a filter excludes
    /// everything, and "no items" when the scope itself is empty. A blank list
    /// said neither.
    @ViewBuilder
    private var emptyItemList: some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        ContentUnavailableView {
            Label(
                trimmed.isEmpty ? "No items" : "No matches",
                systemImage: trimmed.isEmpty ? "tray" : "magnifyingglass"
            )
        } description: {
            if trimmed.isEmpty {
                Text("This scope has no items to show.")
            } else {
                Text("No items match “\(trimmed)”.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// Whether the current scope's item list contains the item. Group scopes
    /// consult the owning vault's group contents; the other scopes follow the
    /// scope's account.
    private func scopeContains(_ itemID: VaultItemID) -> Bool {
        Self.scope(appModel.scope, shows: itemID) { account, group in
            appModel.session(for: account)?
                .items(inGroup: group)
                .contains(where: { $0.id == itemID }) ?? false
        }
    }

    /// The pure rule behind `scopeContains`, extracted so it can be tested
    /// without standing up a view and an environment.
    ///
    /// A group scope is not satisfied merely by belonging to the same vault:
    /// an item in another folder of that same vault is not in this list, and
    /// treating it as visible leaves a selection the user cannot see.
    /// `groupContainsItem` is consulted only for a group scope, so the
    /// non-group cases stay a comparison.
    static func scope(
        _ scope: VaultScope,
        shows itemID: VaultItemID,
        groupContainsItem: (AccountID, String) -> Bool
    ) -> Bool {
        switch scope {
        case .allVaults:
            return true
        case .vault(let account):
            return account == itemID.account
        case .group(let account, let group):
            guard account == itemID.account else { return false }
            return groupContainsItem(account, group)
        }
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
            if item.favorite {
                Spacer(minLength: 4)
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
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

    /// Forgets every typed master password whose prompt is no longer showing.
    ///
    /// The prompt appears only for the vault the scope names, and only while it
    /// is closed, so anything else in the map is text the user typed and walked
    /// away from. A master password is the one value this app must never keep.
    private func discardUnsubmittedPasswords() {
        let stillPrompting = appModel.selectedSession.flatMap { $0.isOpen ? nil : $0.account }
        // Filtered into a new dictionary rather than removed while iterating
        // the old one's keys.
        passwords = passwords.filter { $0.key == stillPrompting }
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
            VaultItemDetailView(
                detail: detail,
                isFetchingSecrets: appModel.isHydrating(selection)
            )
                .id(selection)
                // A CLI provider's item has its secret fields fetched the first
                // time it is opened, because listing deliberately carries none;
                // a Vaultwarden item already has them in memory.
                // Keyed on the content epoch too: a sync drops the secrets
                // fetched against the listing it replaced, and without this the
                // selection has not changed so the task never re-runs — the
                // password row would vanish from an open item and stay gone.
                .task(id: HydrationKey(item: selection, epoch: appModel.contentEpoch)) {
                    appModel.hydrateIfNeeded(selection)
                }
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
                    // abbreviated form ("2 min ago") also keeps it short. The
                    // timeline re-evaluates the relative wording, so it cannot
                    // sit at "2 min ago" for the rest of the session.
                    TimelineView(.periodic(from: date, by: 60)) { _ in
                        Text(date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help("Last synced \(date.formatted(.relative(presentation: .named)))")
                    }
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
            .keyboardShortcut("e", modifiers: .command)
            .accessibilityIdentifier("vault-edit")

            Button {
                pendingArchive = selection
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
            .keyboardShortcut("r", modifiers: .command)
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

    private static func matches(_ item: VaultItemProjection, query: String) -> Bool {
        let haystacks = [item.displayTitle, item.displaySubtitle ?? item.username ?? ""]
            + item.websites + item.groupingLabels
        return haystacks.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
