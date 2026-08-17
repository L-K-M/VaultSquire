import Combine
import Foundation

/// What a requested copy actually did. The browser's context menu can ignore
/// this — the window it was invoked from is still on screen if nothing
/// happens. Quick Search cannot: it dismisses and hands focus to another
/// application, and the user's next keystroke is Command-V.
/// Conforms to `Error` because it is the failure half of the `Result` a
/// resolution returns: the value or the reason there is none.
enum SecretDeliveryOutcome: Error, Hashable, Sendable {
    /// Typed straight into the application the user came from. The pasteboard
    /// was never involved, so there is nothing to expire and nothing for a
    /// clipboard-history manager to have taken.
    case typed
    case copied
    /// The item has no such field: a login stored without a password.
    case noSuchValue
    /// The vault is closed, or its provider does not permit copying secrets.
    case notPermitted
    /// The provider was asked and produced nothing before its own timeout.
    case fetchFailed
    /// The user gave up before the value arrived.
    case cancelled
}

@MainActor
final class AppModel: ObservableObject {
    /// Whether any account credentials exist on this installation. `unknown`
    /// covers environments where the credential store is unavailable (for
    /// example an ad-hoc-signed test host); the shell then keeps the locked
    /// wording, which is the safe default because it claims less than "no
    /// accounts exist" does.
    enum AccountPresence: Equatable, Sendable {
        case unknown
        case none
        case present
    }

    /// Every configured vault, in sidebar order, each carrying its own open
    /// state and decrypted material.
    @Published private(set) var sessions: [VaultSlot] = []
    /// What the item list is showing: everything open, or one vault.
    @Published var scope: VaultScope = .allVaults {
        didSet {
            guard oldValue != scope else { return }
            // A new scope is a fresh list, so the filter typed for the old one
            // does not carry into it — the same thing Finder and Mail do when
            // the sidebar selection changes. Cleared here rather than only in
            // the view, so the model can never publish the new scope narrowed
            // by the old scope's query.
            searchQuery = ""
            rebuildItems()
        }
    }

    @Published private(set) var accountPresence: AccountPresence = .unknown
    /// The configured accounts, for display in the shell and unlock prompt.
    @Published private(set) var accounts: [AccountDescriptor] = []
    /// A non-blocking unlock failure message shown on the unlock prompt.
    @Published private(set) var unlockError: String?
    @Published private(set) var isWriting = false
    @Published private(set) var writeError: String?
    /// Set when Quick Search opens an item; the vault view consumes it to select
    /// that item, then clears it.
    @Published var quickSearchSelection: VaultItemID?

    /// True when this Mac can do Touch ID and the vault has been enrolled, so
    /// the unlock prompt can offer it instead of the master password.
    @Published private(set) var canUnlockWithBiometrics = false
    /// True when a Vaultwarden vault is open and could be enrolled but has not
    /// been, so Settings can offer the opt-in.
    @Published private(set) var canEnrollBiometrics = false
    /// A non-blocking message when enrolling or revoking Touch ID failed.
    @Published private(set) var biometricError: String?

    /// In-flight work started for a vault (opens, syncs, hydrations, writes),
    /// tracked so a lock can cancel it: a cancelled Proton or 1Password CLI
    /// process is terminated by the executor instead of running on and
    /// emitting plaintext into a vault the user just closed.
    private var runningTasks: [AccountID: Set<Task<Void, Never>>] = [:]

    private let queryAccountPresence: () -> AccountPresence
    private let service: VaultwardenAccountService
    private let protonService: ProtonAccountService
    private let onePasswordService: OnePasswordAccountService
    private let biometricStore: any BiometricVaultKeyStoring
    private let clipboard: ClipboardService
    /// Secret fields fetched on demand for opened Proton items. In memory only
    /// for the life of the session — never sealed into the snapshot — and
    /// dropped when that vault locks.
    @Published private var protonContent: [VaultItemID: ProtonItemContent] = [:]
    /// The same, for opened 1Password items.
    @Published private var onePasswordContent: [VaultItemID: OnePasswordItemContent] = [:]
    /// Published so the detail view can say that an item's secret fields are
    /// still being read rather than looking like an item that has none.
    @Published private var hydratingItems: Set<VaultItemID> = []
    /// Copies asked for from a list row before the provider had fetched the
    /// value. The fetch is started and the copy completes when it lands, so the
    /// gesture behaves the same whether the provider decrypts locally or shells
    /// out for every item.
    /// A copy asked for before the provider had fetched the value: what to
    /// copy, and who is waiting to be told how it ended.
    private struct PendingCopy {
        var kind: CopyableSecret
        var observers: [@MainActor (Result<String, SecretDeliveryOutcome>) -> Void] = []
    }

    private var pendingCopies: [VaultItemID: PendingCopy] = [:]
    /// CLI vaults the user locked by hand this session. The unlock gesture
    /// that opens credential-free vaults must not undo a deliberate per-vault
    /// lock: "one unlock opens the app" is about vaults the user has not
    /// chosen to close. Cleared when the user opens the vault again, when the
    /// vault is removed, and by a global lock, which ends the session the
    /// mark belonged to.
    private var lockedByUser: Set<AccountID> = []
    /// Bumped whenever fetched secrets are discarded. The detail pane keys its
    /// hydration on this as well as on the selection, so a sync that drops the
    /// secrets of the item currently open re-reads them instead of leaving the
    /// password row simply gone until the user clicks away and back.
    @Published private(set) var contentEpoch: UInt64 = 0

    init(
        queryAccountPresence: @escaping () -> AccountPresence = AppModel.keychainAccountPresence,
        service: VaultwardenAccountService = VaultwardenAccountService(),
        protonService: ProtonAccountService = ProtonAccountService(),
        onePasswordService: OnePasswordAccountService = OnePasswordAccountService(),
        biometricStore: any BiometricVaultKeyStoring = BiometricVaultKeyStore(),
        clipboard: ClipboardService = .shared
    ) {
        self.queryAccountPresence = queryAccountPresence
        self.service = service
        self.protonService = protonService
        self.onePasswordService = onePasswordService
        self.biometricStore = biometricStore
        self.clipboard = clipboard
    }

    /// Starts tracked work for a vault. The task unregisters itself when it
    /// finishes; `lock` cancels whatever is still registered.
    private func spawnTracked(_ account: AccountID, _ body: @escaping @MainActor () async -> Void) {
        var task: Task<Void, Never>!
        task = Task {
            await body()
            self.untrack(task, for: account)
        }
        runningTasks[account, default: []].insert(task)
    }

    private func untrack(_ task: Task<Void, Never>, for account: AccountID) {
        runningTasks[account]?.remove(task)
    }

    /// Cancels every in-flight task for one vault, so a lock terminates the
    /// CLI processes and network calls that would otherwise finish into a
    /// closed vault.
    private func cancelTrackedTasks(for account: AccountID) {
        let tasks = runningTasks[account] ?? []
        runningTasks[account] = nil
        for task in tasks {
            task.cancel()
        }
    }

    // MARK: - Aggregate state

    /// True only when the store answered definitively that no credentials
    /// exist AND no vault is configured; `unknown` deliberately reads as
    /// locked, not as empty.
    var hasNoAccounts: Bool { accountPresence == .none && sessions.isEmpty }

    /// True while no vault is open, which is what the shell keys its locked
    /// presentation off.
    var isLocked: Bool { !sessions.contains(where: \.isOpen) }
    var isUnlocked: Bool { sessions.contains(where: \.isOpen) }
    var isUnlocking: Bool { sessions.contains(where: \.isOpening) }
    /// True while any vault is syncing, for the toolbar's shared indicator.
    var isSyncing: Bool { sessions.contains(where: \.isSyncing) }

    /// The account a master-password prompt belongs to. Filtered to Vaultwarden
    /// because Proton is configured too and has no password to prompt for;
    /// returning it would offer a password field for a vault that has none.
    var primaryAccount: AccountDescriptor? {
        accounts.first { $0.account.provider == .vaultwarden }
    }

    /// The vaults the item list is drawing from under the current scope.
    var scopedSessions: [VaultSlot] {
        switch scope {
        case .allVaults:
            return sessions.filter(\.isOpen)
        case .vault(let account), .group(let account, _):
            return sessions.filter { $0.account == account && $0.isOpen }
        }
    }

    /// The items shown for the current scope, merged across vaults when the
    /// scope is All Vaults and sorted by title so a merged list reads as one.
    ///
    /// Cached rather than computed. Building it flat-maps every open vault and
    /// sorts with a localized comparison, and the list read it on every body
    /// pass — which means on every keystroke in the search field, twice more
    /// for the placeholder's item count, and again for every unrelated change
    /// the model published. It is rebuilt when the vaults or the scope change,
    /// which is the only time the answer can differ.
    @Published private(set) var items: [VaultItemProjection] = []

    /// Every open vault's items, for Quick Search — it always searches
    /// everything that is open, regardless of the browser's scope.
    /// Sorted by title, not left in vault-by-vault blocks. Quick Search ranks
    /// these and breaks ties by the order it was given them, so an unsorted
    /// merge would make two equally good matches from different vaults arrive
    /// grouped by provider rather than alphabetically.
    ///
    /// Cached for the same reason `items` is: the sidebar's open summary reads
    /// this on every body pass, so as a computed property it re-sorted the
    /// entire open corpus — a localized comparison per element — on every
    /// keystroke in the search field and every model publish. Rebuilt beside
    /// `items` in `rebuildItems`, which is the only time the answer can differ.
    @Published private(set) var allOpenItems: [VaultItemProjection] = []

    /// The browser's filter text, already debounced by the view.
    ///
    /// The model owns this rather than the view because what it narrows —
    /// `items` — is owned here, and because the answer has to be computed once
    /// per change rather than once per body pass. It was a computed property on
    /// the view, read from `body` and from two `onChange` handlers, so a single
    /// keystroke ran the whole-corpus filter several times over.
    @Published var searchQuery = "" {
        didSet {
            guard oldValue != searchQuery else { return }
            rebuildFilteredItems()
        }
    }

    /// `items` narrowed by `searchQuery`, in the same order — alphabetical, not
    /// ranked. Ranking belongs to Quick Search, which is a launcher; a list that
    /// reorders itself under the user as they type is a different thing, and
    /// changing that is not what fixing the filter's cost is for.
    @Published private(set) var filteredItems: [VaultItemProjection] = []

    /// The lowercased haystacks behind `filteredItems`, built once per item set
    /// in `rebuildItems` rather than once per keystroke.
    private var searchRows: [ItemSearchRow] = []

    private func rebuildItems() {
        let scoped: [VaultItemProjection]
        if case .group(_, let group) = scope {
            scoped = scopedSessions.flatMap { $0.items(inGroup: group) }
        } else {
            scoped = scopedSessions.flatMap(\.items)
        }
        items = scoped.sorted { lhs, rhs in
            lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }
        allOpenItems = sessions
            .filter(\.isOpen)
            .flatMap(\.items)
            .sorted { lhs, rhs in
                lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            }
        // Beside the item set they describe, so the two can never disagree:
        // a filter answered from stale haystacks would show rows the list no
        // longer holds, or hide ones it does.
        searchRows = items.map(ItemSearchRow.init)
        rebuildFilteredItems()
    }

    private func rebuildFilteredItems() {
        guard let needle = ItemSearchRow.normalize(searchQuery) else {
            filteredItems = items
            return
        }
        var matched: [VaultItemProjection] = []
        for row in searchRows where row.matches(needle) {
            matched.append(row.item)
        }
        filteredItems = matched
    }

    /// Whether an item survives the current filter, without a second pass over
    /// the corpus. The browser asks this to decide whether a selection is still
    /// on screen; `filteredItems` is already the answer's domain.
    func filterShows(_ itemID: VaultItemID) -> Bool {
        filteredItems.contains { $0.id == itemID }
    }

    /// The sync timestamp shown for the current scope: the oldest across the
    /// scoped vaults, because that is the honest "synced as of" for a merge.
    var lastSyncedAt: Date? {
        scopedSessions.compactMap(\.lastSyncedAt).min()
    }

    /// The first sync error among the scoped vaults, for the status line.
    var syncError: String? {
        scopedSessions.compactMap(\.syncError).first
    }

    func session(for account: AccountID) -> VaultSlot? {
        sessions.first { $0.account == account }
    }

    /// The vault the current scope names, whether or not it is open.
    var selectedSession: VaultSlot? {
        guard let account = scope.account else { return nil }
        return session(for: account)
    }

    /// Every open vault a new item could be created in, for the destination
    /// picker. Read-only providers never appear.
    var writableVaults: [VaultSlot] {
        sessions.filter { $0.isOpen && $0.capabilities.contains(.createItem) }
    }

    // MARK: - Presence and accounts

    /// Rebuilds the vault list from the stored descriptors, preserving the open
    /// state of vaults that are already open.
    func refreshAccountPresence() {
        accountPresence = queryAccountPresence()
        accounts = service.descriptorStore.all()

        var rebuilt: [VaultSlot] = []
        for descriptor in accounts {
            if let existing = session(for: descriptor.account) {
                rebuilt.append(existing)
                continue
            }
            rebuilt.append(Self.makeSession(for: descriptor))
        }
        // Keep any open vault whose descriptor vanished rather than silently
        // dropping decrypted state on the floor.
        for previous in sessions
        where previous.isOpen && !rebuilt.contains(where: { $0.account == previous.account }) {
            rebuilt.append(previous)
        }
        sessions = rebuilt
        // A vault removed and re-added is a fresh installation of it, so the
        // deliberate-lock mark does not carry over from its previous life.
        lockedByUser = lockedByUser.filter { id in
            accounts.contains { $0.account == id }
        }
        rebuildItems()

        if let account = scope.account, session(for: account) == nil {
            scope = .allVaults
        }
        refreshBiometricAvailability()
    }

    private static func makeSession(for descriptor: AccountDescriptor) -> VaultSlot {
        let kind: VaultSlot.Kind
        let title: String
        switch descriptor.account.provider {
        case .protonCLI:
            kind = .proton
            title = "Proton Pass"
        case .onePasswordCLI:
            kind = .onePassword
            // The sign-in address, so two 1Password accounts are told apart in
            // the sidebar rather than both reading "1Password".
            title = descriptor.serverDisplay
        default:
            kind = .vaultwarden
            title = descriptor.serverDisplay
        }
        return VaultSlot(
            account: descriptor.account,
            kind: kind,
            title: title,
            subtitle: descriptor.email
        )
    }

    /// Recomputes whether Touch ID can unlock (enrolled) or be offered
    /// (available but not yet enrolled). Never prompts.
    private func refreshBiometricAvailability() {
        let available = biometricStore.isBiometryAvailable
        let enrolled = available && biometricStore.hasKey(for: .vaultwardenPrimary)
        canUnlockWithBiometrics = enrolled && accountPresence != .none
        let vaultwardenOpen = session(for: .vaultwardenPrimary)?.isOpen == true
        canEnrollBiometrics = available && !enrolled && vaultwardenOpen
    }

    /// Notes a just-configured account without another store round trip.
    func noteAccountConfigured() {
        accountPresence = .present
        refreshAccountPresence()
    }

    /// Clears a lingering write failure. Called when an editor sheet opens, so
    /// an error from an earlier, unrelated write is never shown above a form
    /// the user has not submitted yet.
    func noteEditorPresented() {
        writeError = nil
    }

    /// Dismisses a write failure the browser is showing. The editor clears it
    /// on open; a failure from a toolbar or row action is shown in the browser
    /// instead and is dismissed from there.
    func dismissWriteError() {
        writeError = nil
    }

    /// Registers the Proton vault so it appears in the sidebar like any other,
    /// then opens it. Called from the Add Account pane once the CLI reports
    /// ready.
    func addProtonVault() {
        service.descriptorStore.upsert(AccountDescriptor(
            account: ProtonAccountService.accountID,
            serverDisplay: "Proton Pass",
            email: "Official Proton Pass CLI"
        ))
        accountPresence = .present
        refreshAccountPresence()
        scope = .vault(ProtonAccountService.accountID)
        open(ProtonAccountService.accountID)
    }

    /// Registers one 1Password account as its own vault in the sidebar, then
    /// opens it. Called from the Add Account pane for the account the user
    /// chose. No 1Password credential is collected here or anywhere else: the
    /// desktop app authorizes the CLI when the vault opens.
    ///
    /// Adding a second account adds a second vault rather than replacing the
    /// first, because the descriptor is keyed by the CLI's own account
    /// identifier.
    func addOnePasswordVault(_ account: OnePasswordAccount) {
        let identity = OnePasswordAccountService.vaultIdentity(for: account.accountUUID)
        service.descriptorStore.upsert(AccountDescriptor(
            account: identity,
            serverDisplay: account.url,
            email: account.email.isEmpty ? "Official 1Password CLI" : account.email
        ))
        accountPresence = .present
        refreshAccountPresence()
        scope = .vault(identity)
        open(identity)
    }

    // MARK: - Open / lock

    /// Opens a vault that can be opened without collecting anything: both CLI
    /// providers read through a session the user already established. Vaultwarden
    /// needs a password or Touch ID, so it is a no-op here and the UI shows the
    /// prompt; its path is `unlock(_:password:)` or `unlockWithBiometrics()`.
    func open(_ account: AccountID) {
        guard let existing = session(for: account), !existing.isOpening, !existing.isOpen else { return }
        // The user asked for this vault specifically: whatever earlier lock
        // mark it carried is spent.
        lockedByUser.remove(account)
        switch existing.kind {
        case .proton:
            openProton(account)
        case .onePassword:
            openOnePassword(account)
        case .vaultwarden:
            // Nothing to do without a credential; the UI shows the prompt.
            break
        }
    }

    func unlock(_ account: AccountID, password: String) {
        guard !password.isEmpty,
              let current = session(for: account),
              current.kind == .vaultwarden,
              // Both, matching `unlockWithBiometrics`. Guarding only
              // `isOpening` let an already-open vault be unlocked over itself.
              !current.isOpening, !current.isOpen else {
            return
        }
        let generation = current.generation
        mutate(account) { $0.state = .opening }
        unlockError = nil

        spawnTracked(account) {
            // The password bytes are created inside this task so the buffer the
            // defer zeroizes is the only Data copy: a Data captured into the
            // task would share storage, and zeroizing a second reference would
            // detach it and leave the original bytes intact until the task is
            // released.
            var bytes = Data(password.utf8)
            defer { VaultwardenCryptoZeroize.zero(&bytes) }
            do {
                let vault = try await self.service.unlock(masterPasswordBytes: bytes)
                self.finishOpen(account, generation: generation, vault: vault)
            } catch let error as VaultwardenUnlockError {
                self.failOpen(account, generation: generation, message: Self.message(for: error))
            } catch VaultwardenAccountError.noVault {
                self.failOpen(
                    account, generation: generation,
                    message: "No stored vault was found. Add the account again to sync it."
                )
            } catch VaultwardenAccountError.missingKeyMaterial {
                self.failOpen(
                    account, generation: generation,
                    message: "Couldn't fetch your vault key from the server. Check your connection and try again."
                )
            } catch {
                self.failOpen(
                    account, generation: generation, message: "The vault could not be opened."
                )
            }
        }
    }

    private func finishOpen(
        _ account: AccountID,
        generation: UInt64,
        vault: VaultwardenUnlockedVault
    ) {
        // A lock that landed while the unlock was in flight wins: the user
        // asked for the vault to be closed, so the late result is dropped.
        guard isCurrent(account, generation) else { return }
        mutate(account) {
            $0.state = .open
            $0.vaultwarden = vault
            $0.items = vault.items
            $0.lastSyncedAt = vault.snapshot.syncedAt
        }
        unlockError = nil
        refreshBiometricAvailability()
        syncNow(account)
        // One unlock gesture opens the app, not just this vault.
        openCredentialFreeVaults()
        // A vault just became open (and more may follow), so a visible Quick
        // Search panel must stop searching only the vaults that were open
        // before the gesture.
        ApplicationCoordinator.shared.refreshQuickSearch()
    }

    /// Opens every configured vault that needs no credential of its own.
    ///
    /// Having authenticated to VaultSquire — by master password or by Touch ID —
    /// the user has already given the only secret the app can ask them for, so
    /// leaving the CLI vaults behind a second "Open Vault" press just makes them
    /// press a button that collects nothing. Vaults already open or opening are
    /// left alone, and a vault whose CLI is missing or signed out fails onto its
    /// own row without disturbing the vault the user did unlock.
    ///
    /// This is deliberately not run on launch: a CLI vault opening with no
    /// gesture at all would put vault contents on screen for whoever opened the
    /// window. The unlock is the gate.
    ///
    /// The gate does not override a deliberate choice: a vault the user locked
    /// by hand this session is left closed until they open it themselves, even
    /// though it could open with no credential. The gesture exists for vaults
    /// the user has not chosen to close, not as an undo for a lock they asked
    /// for.
    func openCredentialFreeVaults() {
        for account in sessions
        .filter({ !$0.needsCredentialToOpen && !lockedByUser.contains($0.account) })
        .map(\.account) {
            open(account)
        }
    }

    private func failOpen(_ account: AccountID, generation: UInt64, message: String) {
        guard isCurrent(account, generation) else { return }
        mutate(account) { $0.state = .failed(message) }
        unlockError = message
    }

    /// Opens the Proton vault read-only: a CLI refresh, its projections, and a
    /// sealed snapshot for offline read. No Proton credential is ever collected.
    private func openProton(_ account: AccountID) {
        guard let current = session(for: account) else { return }
        let generation = current.generation
        mutate(account) { $0.state = .opening }

        spawnTracked(account) {
            let result = await self.protonService.refresh()
            guard self.isCurrent(account, generation) else { return }
            switch result {
            case .success(let refresh):
                self.mutate(account) {
                    $0.state = .open
                    $0.proton = refresh.snapshot
                    $0.items = refresh.projections
                    $0.lastSyncedAt = refresh.snapshot.capturedAt
                    $0.syncError = nil
                }
                self.refreshQuickSearchAfterOpenOrSync()
            case .failure(let error):
                self.failProtonOpenOrShowOfflineSnapshot(
                    account, generation: generation, error: error
                )
                // The failure path may have opened the vault from its offline
                // snapshot, which changes the item set too. The coordinator
                // answers for itself when no panel is visible.
                self.refreshQuickSearchAfterOpenOrSync()
            }
        }
    }

    /// A live Proton refresh failed. `refresh()` seals a snapshot to disk on
    /// every success, and `cachedSnapshot()`/`projections(from:)` exist
    /// specifically to read it back — but until now nothing called them, so a
    /// CLI hiccup (briefly unavailable, one slow vault, a version the gate
    /// hasn't approved yet) showed a hard error with no data, even with a
    /// valid encrypted snapshot sitting on disk from the last successful
    /// refresh. Vaultwarden's own `unlock()` already reads its local cache
    /// first; this brings Proton's resilience in line with it instead of
    /// leaving the offline path built but unreachable from the UI.
    /// Whether a failed live read may fall back to the sealed offline snapshot.
    ///
    /// Only for failures that mean "VaultSquire could not reach the provider".
    /// A provider that answered and *refused* is not an outage: a signed-out
    /// Proton CLI, a locked 1Password app, a disabled CLI integration, or a
    /// user who pressed Deny on the authorization prompt have each withheld
    /// access on purpose. Serving the last snapshot there would show the vault
    /// to someone the provider just declined to serve, turning the offline
    /// cache into a way around the authorization gate.
    private static func mayFallBackOffline(_ error: ProtonServiceError) -> Bool {
        switch error {
        case .notAuthenticated:
            return false
        case .cliNotInstalled, .unsupportedVersion, .unparseableVersion,
             .incompleteVaultRead, .unreadableOutput, .executionFailed:
            return true
        }
    }

    /// The 1Password counterpart. `.notAuthorized` covers a declined prompt and
    /// a locked app, and `.unusableAccount` means the CLI will no longer accept
    /// this account at all; neither is an outage to ride out.
    private static func mayFallBackOffline(_ error: OnePasswordServiceError) -> Bool {
        switch error {
        case .notAuthorized, .unusableAccount:
            return false
        case .cliNotInstalled, .unsupportedVersion, .unparseableVersion,
             .incompleteVaultRead, .unreadableOutput, .executionFailed:
            return true
        }
    }

    private func failProtonOpenOrShowOfflineSnapshot(
        _ account: AccountID, generation: UInt64, error: ProtonServiceError
    ) {
        guard isCurrent(account, generation) else { return }
        guard Self.mayFallBackOffline(error), let snapshot = protonService.cachedSnapshot() else {
            mutate(account) { $0.state = .failed(Self.message(for: error)) }
            return
        }
        mutate(account) {
            $0.state = .open
            $0.proton = snapshot
            $0.items = protonService.projections(from: snapshot)
            $0.lastSyncedAt = snapshot.capturedAt
            $0.syncError = "Showing the last synced copy. \(Self.message(for: error))"
        }
    }

    /// Opens the 1Password vault read-only: a CLI refresh, its projections, and
    /// a sealed snapshot for offline read. No 1Password credential is ever
    /// collected — the desktop app prompts the user to authorize the CLI, and a
    /// declined or unanswered prompt surfaces as a recoverable failure.
    private func openOnePassword(_ account: AccountID) {
        guard let current = session(for: account) else { return }
        let generation = current.generation
        mutate(account) { $0.state = .opening }

        // The vault's own identity carries the CLI account it was added for.
        let accountUUID = account.rawValue
        spawnTracked(account) {
            let result = await self.onePasswordService.refresh(accountUUID: accountUUID)
            guard self.isCurrent(account, generation) else { return }
            switch result {
            case .success(let refresh):
                self.mutate(account) {
                    $0.state = .open
                    $0.onePassword = refresh.snapshot
                    $0.items = refresh.projections
                    $0.lastSyncedAt = refresh.snapshot.capturedAt
                    $0.syncError = nil
                }
                self.refreshQuickSearchAfterOpenOrSync()
            case .failure(let error):
                self.failOnePasswordOpenOrShowOfflineSnapshot(
                    account, generation: generation, accountUUID: accountUUID, error: error
                )
                // The failure path may have opened the vault from its offline
                // snapshot, which changes the item set too.
                self.refreshQuickSearchAfterOpenOrSync()
            }
        }
    }

    /// The 1Password counterpart of `failProtonOpenOrShowOfflineSnapshot`: a
    /// failed live refresh falls back to the last sealed snapshot for this
    /// specific 1Password account rather than a hard, dataless error.
    private func failOnePasswordOpenOrShowOfflineSnapshot(
        _ account: AccountID, generation: UInt64, accountUUID: String, error: OnePasswordServiceError
    ) {
        guard isCurrent(account, generation) else { return }
        guard Self.mayFallBackOffline(error),
              let snapshot = onePasswordService.cachedSnapshot(accountUUID: accountUUID) else {
            mutate(account) { $0.state = .failed(Self.message(for: error)) }
            return
        }
        mutate(account) {
            $0.state = .open
            $0.onePassword = snapshot
            $0.items = onePasswordService.projections(from: snapshot, accountUUID: accountUUID)
            $0.lastSyncedAt = snapshot.capturedAt
            $0.syncError = "Showing the last synced copy. \(Self.message(for: error))"
        }
    }

    /// Closes one vault, dropping only its decrypted state and cancelling
    /// its in-flight work.
    func lock(_ account: AccountID) {
        guard session(for: account) != nil else { return }
        // A lock the user asked for on this vault, not one the unlock gesture
        // opened them into: the gesture must not quietly reopen it later.
        lockedByUser.insert(account)
        cancelTrackedTasks(for: account)
        mutate(account) { $0.close() }
        dropFetchedContent(for: account)
        unlockError = nil
        refreshBiometricAvailability()
        clipboard.clearIfOwned()
        if isUnlocked {
            // Something is still open, so the panel stays — but it must stop
            // offering the items of the vault that just closed.
            ApplicationCoordinator.shared.refreshQuickSearch()
        } else {
            ApplicationCoordinator.shared.dismissQuickSearch()
        CopyConfirmationPanel.dismiss()
        }
        AppLog.record(.vaultLocked)
    }

    /// Closes every vault. Idempotent, and the shell's lock-everything action.
    func lock() {
        for account in sessions.map(\.account) {
            cancelTrackedTasks(for: account)
            mutate(account) { $0.close() }
        }
        // A global lock ends the session the marks belonged to: the next
        // unlock gesture is a fresh "open the app" and may reopen every
        // credential-free vault, including one that was locked by hand under
        // the session that just ended.
        lockedByUser = []
        contentEpoch &+= 1
        protonContent = [:]
        onePasswordContent = [:]
        hydratingItems = []
        resolvePendingCopies(.notPermitted, where: { _ in true })
        unlockError = nil
        refreshBiometricAvailability()
        clipboard.clearIfOwned()
        ApplicationCoordinator.shared.dismissQuickSearch()
        AppLog.record(.vaultLocked)
    }

    /// Drops every on-demand secret fetched for one vault. Both CLI providers
    /// hold theirs in memory only, so closing a vault must clear its entries
    /// from each map.
    private func dropFetchedContent(for account: AccountID) {
        dropFetchedSecrets(for: account)
        hydratingItems = hydratingItems.filter { $0.account != account }
    }

    /// Drops the fetched secrets for one vault while leaving the in-flight set
    /// alone, so a refresh invalidates what was fetched without letting a fetch
    /// that is already running be started a second time.
    private func dropFetchedSecrets(for account: AccountID) {
        contentEpoch &+= 1
        protonContent = protonContent.filter { $0.key.account != account }
        onePasswordContent = onePasswordContent.filter { $0.key.account != account }
        // A copy still waiting on a fetch must not land after the vault it came
        // from has been closed.
        // A copy still waiting on a fetch must not land after the vault it came
        // from has been closed — and whoever is waiting on it has to be told,
        // or a panel holding the wait never comes down.
        resolvePendingCopies(.notPermitted, where: { $0.account == account })
    }

    // MARK: - Touch ID

    /// Unlocks the Vaultwarden vault with Touch ID, so the master password is
    /// not retyped. Any failure falls back to the password prompt; a cancelled
    /// prompt is silent because the user chose to dismiss it.
    func unlockWithBiometrics() {
        let account = AccountID.vaultwardenPrimary
        guard canUnlockWithBiometrics,
              let current = session(for: account),
              !current.isOpening, !current.isOpen else {
            return
        }
        let generation = current.generation
        mutate(account) { $0.state = .opening }
        unlockError = nil

        spawnTracked(account) {
            guard let wrapped = self.service.currentWrappedUserKey() else {
                self.failOpen(
                    account, generation: generation,
                    message: "No stored vault was found. Add the account again to sync it."
                )
                return
            }
            do {
                var keyData = try await self.biometricStore.loadUserKey(
                    for: account,
                    boundTo: wrapped,
                    reason: "Unlock your VaultSquire vault"
                )
                defer { VaultwardenCryptoZeroize.zero(&keyData) }
                let vault = try self.service.unlock(userKeyData: keyData)
                self.finishOpen(account, generation: generation, vault: vault)
            } catch BiometricUnlockError.cancelled {
                // The user dismissed the prompt; the password field is right
                // there, so say nothing.
                guard self.isCurrent(account, generation) else { return }
                self.mutate(account) { $0.state = .locked }
            } catch BiometricUnlockError.invalidated {
                self.canUnlockWithBiometrics = false
                self.failOpen(
                    account, generation: generation,
                    message: "Touch ID unlock was turned off because this Mac's fingerprints or your vault key changed. Unlock with your master password to set it up again."
                )
            } catch BiometricUnlockError.notEnrolled {
                self.canUnlockWithBiometrics = false
                self.failOpen(
                    account, generation: generation,
                    message: "Touch ID isn't set up for this vault yet."
                )
            } catch BiometricUnlockError.unavailable {
                self.canUnlockWithBiometrics = false
                self.failOpen(
                    account, generation: generation,
                    message: "Touch ID isn't available on this Mac."
                )
            } catch {
                self.failOpen(
                    account, generation: generation,
                    message: "Touch ID unlock didn't work. Use your master password."
                )
            }
        }
    }

    /// Enrolls the open Vaultwarden vault's key behind Touch ID. Requires that
    /// vault to be open, because the key only exists in memory while it is.
    func enableBiometricUnlock() {
        guard let vault = session(for: .vaultwardenPrimary)?.vaultwarden else {
            // The key exists only while the vault is open, so say that rather
            // than doing nothing when the button is pressed in a closed state.
            biometricError = "Unlock your vault first, then turn on Touch ID."
            return
        }
        let keyData = vault.keyring.userKey.encryptionKey + vault.keyring.userKey.macKey
        do {
            try biometricStore.store(
                userKey: keyData,
                boundTo: vault.snapshot.wrappedUserKey,
                for: .vaultwardenPrimary
            )
            biometricError = nil
        } catch let error as BiometricUnlockError {
            biometricError = Self.message(for: error)
        } catch {
            biometricError = "Touch ID couldn't be enabled for this vault."
        }
        refreshBiometricAvailability()
    }

    /// Enrollment and revocation failures, named exactly. The Keychain status
    /// is included because it is the only thing that distinguishes "this build
    /// isn't signed for the Keychain" from a genuine fault, and it is not
    /// secret.
    private static func message(for error: BiometricUnlockError) -> String {
        switch error {
        case .unavailable:
            return "This Mac has no Touch ID available to VaultSquire."
        case .cancelled:
            return "Touch ID was cancelled."
        case .notEnrolled:
            return "Touch ID isn't set up for this vault."
        case .invalidated:
            return "The stored Touch ID key is no longer usable. Unlock with your master password and turn it on again."
        case .failed(let status):
            if status == errSecMissingEntitlement || status == errSecNotAvailable {
                return "The Keychain refused to store the key (\(status)). A locally built, ad-hoc-signed VaultSquire has no Keychain entitlement; a signed build is needed for Touch ID."
            }
            return "The Keychain refused to store the key (status \(status))."
        case .notReadableAfterStore:
            return "The key was stored but couldn't be read back, so Touch ID wasn't enabled."
        }
    }

    /// Forgets the enrolled key, so the next unlock needs the master password.
    func disableBiometricUnlock() {
        try? biometricStore.remove(for: .vaultwardenPrimary)
        biometricError = nil
        refreshBiometricAvailability()
    }

    // MARK: - Item detail

    /// The last Vaultwarden item whose detail and draft were decrypted, with
    /// the snapshot generation they were decrypted from.
    ///
    /// The detail pane reads `detail(for:)` from its body and the toolbar
    /// reads `draft(for:)` through `canEdit` on every redraw — each call runs
    /// an AES-CBC decrypt plus HMAC verify per field and a linear cipher scan.
    /// Memoizing the selected item's answers turns both redraw reads into a
    /// dictionary-sized comparison. The key includes the snapshot generation,
    /// so a sync that re-seals the snapshot invalidates the memo the moment
    /// its content can have changed; a lock drops it with the session.
    ///
    /// One item's plaintext is retained this way for the life of the session,
    /// which matches how the app already treats fetched CLI content: in
    /// memory, session-scoped, never persisted.
    private struct DecryptedItemMemo {
        let itemID: VaultItemID
        let snapshotGeneration: UInt64
        let detail: VaultItemDetail?
        let draft: VaultItemDraft?
    }

    private var decryptedItemMemo: DecryptedItemMemo?

    /// The decrypted detail for an item, routed to the vault that owns it.
    /// Returns nil when that vault is closed, so a locked vault's items can
    /// never be read out of a stale list.
    func detail(for itemID: VaultItemID) -> VaultItemDetail? {
        guard let owner = session(for: itemID.account), owner.isOpen else { return nil }
        switch owner.kind {
        case .proton:
            guard let snapshot = owner.proton else { return nil }
            return protonService.detail(
                for: itemID, snapshot: snapshot, content: protonContent[itemID]
            )
        case .onePassword:
            guard let snapshot = owner.onePassword else { return nil }
            return onePasswordService.detail(
                for: itemID, snapshot: snapshot, content: onePasswordContent[itemID]
            )
        case .vaultwarden:
            guard let vault = owner.vaultwarden else { return nil }
            if let memo = decryptedItemMemo,
               memo.itemID == itemID,
               memo.snapshotGeneration == vault.snapshot.generation {
                return memo.detail
            }
            guard let detail = service.detail(
                for: itemID, keyring: vault.keyring, snapshot: vault.snapshot
            ) else {
                return nil
            }
            // Computed together so the next body pass (detail pane and toolbar
            // alike) pays no decrypt at all for this item.
            decryptedItemMemo = DecryptedItemMemo(
                itemID: itemID,
                snapshotGeneration: vault.snapshot.generation,
                detail: detail,
                draft: service.draft(for: itemID, keyring: vault.keyring, snapshot: vault.snapshot)
            )
            return detail
        }
    }

    /// Fetches a CLI-provider item's secret fields the first time it is opened.
    /// Listing either CLI vault deliberately carries no secrets — one CLI call
    /// per item would make opening a vault slow, and for 1Password would burn
    /// request budget too — so the detail view asks for them here. A no-op for
    /// Vaultwarden, whose items decrypt locally, and for an already-fetched or
    /// in-flight item.
    func hydrateIfNeeded(_ itemID: VaultItemID) {
        guard let owner = session(for: itemID.account), owner.isOpen,
              !hydratingItems.contains(itemID) else {
            return
        }
        let generation = owner.generation

        switch owner.kind {
        case .vaultwarden:
            return
        case .proton:
            guard protonContent[itemID] == nil,
                  let shareID = ProtonAccountService.shareIdentifier(of: itemID) else {
                return
            }
            hydratingItems.insert(itemID)
            spawnTracked(itemID.account) {
                let content = await self.protonService.content(shareID: shareID, itemID: itemID.rawValue)
                self.hydratingItems.remove(itemID)
                // Never publish a secret into a vault the user locked meanwhile.
                guard self.isCurrent(itemID.account, generation) else {
                    self.resolvePendingCopy(itemID, .notPermitted)
                    return
                }
                guard let content else {
                    // The CLI failed or hit its timeout. A copy waiting on this
                    // fetch has to be told, or its caller waits for a value
                    // that is never coming.
                    self.resolvePendingCopy(itemID, .fetchFailed)
                    return
                }
                self.protonContent[itemID] = content
                self.completePendingCopy(itemID)
            }
        case .onePassword:
            guard onePasswordContent[itemID] == nil,
                  let vaultID = OnePasswordAccountService.vaultIdentifier(of: itemID) else {
                return
            }
            // The vault's identity is the CLI account it was added for, so a
            // second signed-in account cannot answer this read.
            let accountUUID = itemID.account.rawValue
            hydratingItems.insert(itemID)
            spawnTracked(itemID.account) {
                let content = await self.onePasswordService.content(
                    itemID: itemID.rawValue,
                    vaultID: vaultID,
                    accountUUID: accountUUID
                )
                self.hydratingItems.remove(itemID)
                // Never publish a secret into a vault the user locked meanwhile.
                guard self.isCurrent(itemID.account, generation) else {
                    self.resolvePendingCopy(itemID, .notPermitted)
                    return
                }
                guard let content else {
                    // The CLI failed or hit its timeout. A copy waiting on this
                    // fetch has to be told, or its caller waits for a value
                    // that is never coming.
                    self.resolvePendingCopy(itemID, .fetchFailed)
                    return
                }
                self.onePasswordContent[itemID] = content
                self.completePendingCopy(itemID)
            }
        }
    }

    /// True while an item's secret fields are being fetched, so the detail can
    /// say so instead of looking like the item simply has no password.
    func isHydrating(_ itemID: VaultItemID) -> Bool {
        hydratingItems.contains(itemID)
    }

    // MARK: - Copying without opening an item

    /// What a list row can put on the clipboard. A one-time code is generated
    /// rather than copied: the seed itself must never reach the pasteboard.
    enum CopyableSecret: Sendable {
        case password
        case oneTimeCode
    }

    /// Whether the vault that owns this item allows a secret to be copied. A
    /// read-only provider still does; a closed vault does not.
    func canCopySecret(_ itemID: VaultItemID) -> Bool {
        guard let owner = session(for: itemID.account), owner.isOpen else { return false }
        return owner.capabilities.contains(.copySecret)
    }

    /// Whether this item has a one-time code to copy. Answered from the
    /// decrypted detail, so it is false for a CLI item whose secrets have not
    /// been fetched yet rather than offering an action that would do nothing.
    func hasOneTimeCode(_ itemID: VaultItemID) -> Bool {
        detail(for: itemID)?.fields.contains { $0.kind == .totpSeed } ?? false
    }

    /// The username shown on the row, which is never a secret and is always
    /// present without a fetch.
    @discardableResult
    func copyUsername(_ itemID: VaultItemID) -> Bool {
        guard let owner = session(for: itemID.account), owner.isOpen,
              let username = owner.items.first(where: { $0.id == itemID })?.username,
              !username.isEmpty else {
            return false
        }
        clipboard.copyPlain(username)
        return true
    }

    /// Copies a secret straight from a row, so the most common thing anyone
    /// does with this app does not require selecting the item, waiting for its
    /// detail, and aiming at a sixteen-point button.
    ///
    /// Vaultwarden decrypts locally, so the value is already here. Both CLI
    /// providers list without secrets, so the fetch is started and the copy
    /// lands when it answers rather than the gesture quietly doing nothing —
    /// and is abandoned if the vault closes first.
    func copySecret(_ kind: CopyableSecret, of itemID: VaultItemID) {
        guard canCopySecret(itemID) else { return }
        if let value = secretValue(kind, of: itemID) {
            clipboard.copySecret(value)
            return
        }
        // A Vaultwarden item's secrets are already decrypted, so a missing
        // value means the item has none — there is nothing to wait for.
        guard session(for: itemID.account)?.kind != .vaultwarden else { return }
        pendingCopies[itemID] = PendingCopy(kind: kind)
        hydrateIfNeeded(itemID)
    }

    /// Copies a secret and reports what happened, waiting out a CLI provider's
    /// fetch first when the value is not in memory yet.
    ///
    /// The fire-and-forget `copySecret(_:of:)` stays as it is for the browser's
    /// context menu. This variant exists for Quick Search, which must not take
    /// itself down and hand focus to another application until the value really
    /// exists — there is no window left afterwards to explain a delivery that
    /// quietly did nothing, and a value that arrives twenty seconds late would
    /// be typed into whatever the user is doing by then.
    ///
    /// Returns the value rather than acting on it, because the caller decides
    /// between typing it and the clipboard.
    func resolveSecretAwaitingFetch(
        _ kind: CopyableSecret,
        of itemID: VaultItemID
    ) async -> Result<String, SecretDeliveryOutcome> {
        guard canCopySecret(itemID) else { return .failure(.notPermitted) }
        if let value = secretValue(kind, of: itemID) {
            return .success(value)
        }
        // A Vaultwarden item is decrypted already, so a missing value means the
        // item has no such field. There is nothing to wait for.
        guard session(for: itemID.account)?.kind != .vaultwarden else {
            return .failure(.noSuchValue)
        }

        return await withCheckedContinuation { continuation in
            var pending = pendingCopies[itemID] ?? PendingCopy(kind: kind)
            // A second request for the same item replaces the kind: the value
            // asked for most recently is the one the user wants.
            pending.kind = kind
            pending.observers.append { continuation.resume(returning: $0) }
            pendingCopies[itemID] = pending

            hydrateIfNeeded(itemID)
            // `hydrateIfNeeded` is a no-op when the content is already here,
            // when the provider identifier cannot be parsed, or when the vault
            // closed between these two lines. Nothing would ever complete the
            // copy in those cases, so resolve it now rather than leave the
            // panel waiting on a fetch that is not running.
            if !hydratingItems.contains(itemID) {
                resolvePendingCopy(itemID, .noSuchValue)
            }
        }
    }

    /// Abandons a copy the user escaped out of, so a value that arrives
    /// afterwards cannot overwrite whatever they have copied since.
    func cancelPendingCopy(of itemID: VaultItemID) {
        resolvePendingCopy(itemID, .cancelled)
    }

    /// Tells whoever is waiting on a copy how it ended and forgets it. Every
    /// path that drops a pending copy goes through here, so an awaiting caller
    /// can never be left on a fetch that will not answer.
    @discardableResult
    private func resolvePendingCopy(
        _ itemID: VaultItemID,
        _ outcome: SecretDeliveryOutcome
    ) -> Bool {
        resolvePendingCopy(itemID, .failure(outcome))
    }

    @discardableResult
    private func resolvePendingCopy(_ itemID: VaultItemID, success value: String) -> Bool {
        resolvePendingCopy(itemID, .success(value))
    }

    @discardableResult
    private func resolvePendingCopy(
        _ itemID: VaultItemID,
        _ result: Result<String, SecretDeliveryOutcome>
    ) -> Bool {
        guard let pending = pendingCopies.removeValue(forKey: itemID) else { return false }
        for observer in pending.observers {
            observer(result)
        }
        return true
    }

    /// The keys are snapshotted: `resolvePendingCopy` mutates the dictionary
    /// the lazy `keys` view is reading.
    private func resolvePendingCopies(
        _ outcome: SecretDeliveryOutcome,
        where predicate: (VaultItemID) -> Bool
    ) {
        for itemID in Array(pendingCopies.keys) where predicate(itemID) {
            resolvePendingCopy(itemID, outcome)
        }
    }

    /// The value a copy would put on the clipboard, or nil when it is not
    /// available yet.
    private func secretValue(_ kind: CopyableSecret, of itemID: VaultItemID) -> String? {
        guard let detail = detail(for: itemID) else { return nil }
        switch kind {
        case .password:
            return detail.fields.first { $0.kind == .secret }?.value
        case .oneTimeCode:
            guard let seed = detail.fields.first(where: { $0.kind == .totpSeed })?.value else {
                return nil
            }
            return VaultwardenTOTP.generate(seed: seed, at: Date())?.code
        }
    }

    /// Completes a copy that was waiting on a provider fetch. Nothing is copied
    /// when the fetch produced no such field, so a request for a password an
    /// item does not have leaves the clipboard alone.
    /// Completes a copy that was waiting on a provider fetch, and tells the
    /// caller either way. Nothing is copied when the fetch produced no such
    /// field, so a request for a password an item does not have leaves the
    /// clipboard alone — but the waiter still learns that, instead of hanging.
    private func completePendingCopy(_ itemID: VaultItemID) {
        guard let pending = pendingCopies[itemID] else { return }
        guard canCopySecret(itemID) else {
            resolvePendingCopy(itemID, .notPermitted)
            return
        }
        guard let value = secretValue(pending.kind, of: itemID) else {
            resolvePendingCopy(itemID, .noSuchValue)
            return
        }
        // The fire-and-forget path still copies here; the awaiting path hands
        // the value back and decides for itself.
        if pending.observers.isEmpty {
            clipboard.copySecret(value)
        }
        resolvePendingCopy(itemID, success: value)
    }

    // MARK: - Writes

    /// The vault a new item would be created in: the selected one when it is an
    /// open writable vault, otherwise the only open writable vault. Nil when
    /// that is ambiguous or unavailable, which is what disables Add Item.
    var createTarget: VaultSlot? {
        if let selected = selectedSession, selected.isOpen, selected.isWritable {
            return selected
        }
        let writable = sessions.filter { $0.isOpen && $0.isWritable }
        return writable.count == 1 ? writable.first : nil
    }

    /// Whether an item can be created right now. Creating needs an unambiguous
    /// writable target, so All Vaults with two writable vaults open offers
    /// nothing until the user picks one.
    var canCreateItems: Bool {
        guard let target = createTarget else { return false }
        return target.capabilities.contains(.createItem)
    }

    /// Whether this specific item can be archived. Gated on the owning vault's
    /// capabilities, so a read-only provider's item never gains the action by
    /// appearing in a merged list next to a writable one.
    func canArchive(_ itemID: VaultItemID) -> Bool {
        guard let owner = session(for: itemID.account), owner.isOpen else { return false }
        return owner.capabilities.contains(.archiveItem)
    }

    /// An editable draft for an item, or nil when its vault is closed, the
    /// provider is read-only, or the item is not an editable kind.
    func draft(for itemID: VaultItemID) -> VaultItemDraft? {
        guard let owner = session(for: itemID.account),
              owner.isOpen,
              owner.capabilities.contains(.updateItem),
              let vault = owner.vaultwarden else {
            return nil
        }
        if let memo = decryptedItemMemo,
           memo.itemID == itemID,
           memo.snapshotGeneration == vault.snapshot.generation {
            return memo.draft
        }
        let draft = service.draft(for: itemID, keyring: vault.keyring, snapshot: vault.snapshot)
        if let draft {
            // Both answers memoized together, so a later `detail(for:)` for
            // the same item and snapshot pays no decrypt either. `draft`
            // succeeded, so the cipher is live; its detail resolves under the
            // same guard (an undecryptable field never aborts the detail —
            // individual fields fail independently).
            decryptedItemMemo = DecryptedItemMemo(
                itemID: itemID,
                snapshotGeneration: vault.snapshot.generation,
                detail: service.detail(for: itemID, keyring: vault.keyring, snapshot: vault.snapshot),
                draft: draft
            )
        }
        return draft
    }

    /// Whether a given item can be edited. Builds the draft, so it decrypts.
    func canEdit(_ itemID: VaultItemID) -> Bool {
        draft(for: itemID) != nil
    }

    /// Whether an Edit entry is worth offering, decided without decrypting.
    ///
    /// `canEdit` builds the draft to answer, which is fine for the one selected
    /// item behind a toolbar button but not for a menu the list may build for
    /// every visible row. This checks the same gates minus the decrypt; the
    /// action still asks for the draft and does nothing if it cannot have one.
    func canOfferEdit(_ itemID: VaultItemID) -> Bool {
        guard let owner = session(for: itemID.account), owner.isOpen else { return false }
        return owner.capabilities.contains(.updateItem) && owner.vaultwarden != nil
    }

    /// Saves a create or edit. An edit routes to the vault that owns the item,
    /// which `destination` can never override; a create goes to the vault the
    /// user picked, or to the unambiguous writable target when they did not.
    func save(_ draft: VaultItemDraft, to destination: AccountID? = nil) {
        guard !isWriting else { return }
        let account = draft.itemID?.account ?? destination ?? createTarget?.account
        guard let account,
              let owner = session(for: account),
              owner.isOpen,
              let vault = owner.vaultwarden else {
            return
        }
        let generation = owner.generation
        isWriting = true
        writeError = nil
        spawnTracked(account) {
            let result = draft.isEditing
                ? await self.service.update(draft: draft, keyring: vault.keyring)
                : await self.service.create(draft: draft, keyring: vault.keyring)
            // A lock that landed while this was in flight wins. `isWriting` is
            // still cleared — it is app-wide UI state, and leaving it true
            // would block every later write for the life of the process — but
            // nothing else is published into a vault the user closed.
            self.isWriting = false
            guard self.isCurrent(account, generation) else { return }
            switch result {
            case .success:
                self.syncNow(account)
            case .failure(let error):
                self.writeError = Self.message(for: error)
            }
        }
    }

    func archive(_ itemID: VaultItemID) {
        guard !isWriting, canArchive(itemID) else { return }
        let account = itemID.account
        guard let generation = session(for: account)?.generation else { return }
        isWriting = true
        writeError = nil
        spawnTracked(account) {
            let result = await self.service.archive(itemID: itemID)
            self.isWriting = false
            guard self.isCurrent(account, generation) else { return }
            switch result {
            case .success:
                self.syncNow(account)
            case .failure(let error):
                self.writeError = Self.message(for: error)
            }
        }
    }

    // MARK: - Sync

    /// Syncs every vault in the current scope.
    func syncNow() {
        let targets = scopedSessions.map(\.account)
        for account in targets {
            syncNow(account)
        }
    }

    /// Syncs one vault. A failure surfaces on that vault's row without dropping
    /// the items it is already showing.
    func syncNow(_ account: AccountID) {
        guard let current = session(for: account), current.isOpen, !current.isSyncing else { return }
        let generation = current.generation
        mutate(account) {
            $0.isSyncing = true
            $0.syncError = nil
        }

        switch current.kind {
        case .vaultwarden:
            spawnTracked(account) {
                let result = await self.service.sync()
                guard self.isCurrent(account, generation) else { return }
                var succeeded = false
                self.mutate(account) { session in
                    session.isSyncing = false
                    switch result {
                    case .success(let snapshot):
                        succeeded = true
                        session.lastSyncedAt = snapshot.syncedAt
                        session.syncError = nil
                        if var vault = session.vaultwarden {
                            // Decrypting every cipher and rebuilding the list is
                            // real work — an AES-CBC decrypt and HMAC verify per
                            // field, synchronously, right here on the main
                            // actor. A sync that reports the same ciphers and
                            // folders the vault already has decrypted (the
                            // common case: nothing changed server-side since
                            // the last sync) does not need to pay that cost
                            // again, so it is skipped whenever the content
                            // that feeds it is unchanged. `VaultwardenCipherModel`
                            // and its `Folder` sibling are `Hashable`, so this
                            // is a cheap structural comparison, not a decrypt.
                            let contentUnchanged = vault.snapshot.ciphers == snapshot.ciphers
                                && vault.snapshot.folders == snapshot.folders
                            vault.snapshot = snapshot
                            if !contentUnchanged {
                                vault.items = self.service.projections(keyring: vault.keyring, snapshot: snapshot)
                                // A sync can add or rename folders, so the sidebar's
                                // list is refreshed with the items it groups.
                                vault.folderNames = self.service.decryptFolderNames(
                                    keyring: vault.keyring, snapshot: snapshot
                                )
                                session.items = vault.items
                            }
                            session.vaultwarden = vault
                        }
                    case .failure(let error):
                        session.syncError = Self.message(for: error)
                    }
                }
                if succeeded {
                    // A sync can add or remove items while the panel is up;
                    // the panel must not keep searching the list it opened on.
                    self.refreshQuickSearchAfterOpenOrSync()
                }
            }
        case .proton:
            spawnTracked(account) {
                let result = await self.protonService.refresh()
                guard self.isCurrent(account, generation) else { return }
                // A refresh replaces the listing, so the secrets fetched
                // against the previous one are no longer known to be current.
                // Dropping them makes the next open re-read; keeping them would
                // show a value the provider may have changed since, under a
                // freshly updated "last synced" time — the most misleading
                // form the answer could take.
                if case .success = result { self.dropFetchedSecrets(for: account) }
                self.mutate(account) { session in
                    session.isSyncing = false
                    switch result {
                    case .success(let refresh):
                        session.proton = refresh.snapshot
                        session.items = refresh.projections
                        session.lastSyncedAt = refresh.snapshot.capturedAt
                        session.syncError = nil
                    case .failure(let error):
                        session.syncError = Self.message(for: error)
                    }
                }
                if case .success = result {
                    self.refreshQuickSearchAfterOpenOrSync()
                }
            }
        case .onePassword:
            let accountUUID = account.rawValue
            spawnTracked(account) {
                let result = await self.onePasswordService.refresh(accountUUID: accountUUID)
                guard self.isCurrent(account, generation) else { return }
                // Same as Proton: a new listing invalidates the secrets fetched
                // against the old one.
                if case .success = result { self.dropFetchedSecrets(for: account) }
                self.mutate(account) { session in
                    session.isSyncing = false
                    switch result {
                    case .success(let refresh):
                        session.onePassword = refresh.snapshot
                        session.items = refresh.projections
                        session.lastSyncedAt = refresh.snapshot.capturedAt
                        session.syncError = nil
                    case .failure(let error):
                        session.syncError = Self.message(for: error)
                    }
                }
                if case .success = result {
                    self.refreshQuickSearchAfterOpenOrSync()
                }
            }
        }
    }

    // MARK: - Session plumbing

    /// The one funnel every session change goes through, which is also where
    /// the two derived collections are refreshed: the vault's container list
    /// and the scoped item list.
    ///
    /// Rebuilding costs a pass over the vault plus a localized sort each, so
    /// the rebuilds are gated on the values they actually derive from: groups
    /// on the item set and the folder names, the item lists on the item set
    /// and the open state. A mutation that only toggles `isSyncing` or clears
    /// a `syncError` now costs a few equality comparisons instead of two
    /// full passes — which matters when every mutation republishes and the
    /// whole window redraws once per change.
    private func mutate(_ account: AccountID, _ body: (inout VaultSlot) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.account == account }) else { return }
        let before = sessions[index]
        body(&sessions[index])
        let after = sessions[index]
        if before.isOpen && !after.isOpen,
           decryptedItemMemo?.itemID.account == account {
            // The memo's plaintext belongs to the session that just ended.
            // Done here rather than in the lock callers so every close path —
            // including a future one — drops it.
            decryptedItemMemo = nil
        }
        let itemsChanged = before.items != after.items
        if itemsChanged || before.vaultwarden?.folderNames != after.vaultwarden?.folderNames {
            sessions[index].refreshGroups()
        }
        if itemsChanged || before.isOpen != after.isOpen {
            rebuildItems()
        }
    }

    /// Whether a vault is still on the generation an async task started under.
    /// A lock advances it, so a stale result is discarded rather than published
    /// into a vault the user closed.
    private func isCurrent(_ account: AccountID, _ generation: UInt64) -> Bool {
        session(for: account)?.generation == generation
    }

    /// Re-reads the model into a visible Quick Search panel after an open or a
    /// successful sync, so the panel never keeps searching an item set that
    /// changed underneath it. Cheap when no panel is up: the coordinator
    /// answers for itself.
    private func refreshQuickSearchAfterOpenOrSync() {
        ApplicationCoordinator.shared.refreshQuickSearch()
    }

    // MARK: - Messages

    private static func message(for error: ProtonServiceError) -> String {
        switch error {
        case .cliNotInstalled:
            return "The Proton Pass CLI isn't installed where VaultSquire can find it."
        case .unsupportedVersion(let version):
            return "The installed Proton Pass CLI (\(version)) isn't a version VaultSquire has verified yet."
        case .unparseableVersion:
            return "VaultSquire couldn't read the Proton Pass CLI's version."
        case .notAuthenticated:
            return "The Proton Pass CLI isn't signed in. Sign in with the official CLI in your terminal, then try again."
        case .incompleteVaultRead:
            return "VaultSquire couldn't read every Proton Pass vault, so it kept the previous offline snapshot."
        case .unreadableOutput:
            return "The Proton Pass CLI returned output VaultSquire couldn't read."
        case .executionFailed:
            return "VaultSquire couldn't run the Proton Pass CLI."
        }
    }

    private static func message(for error: OnePasswordServiceError) -> String {
        switch error {
        case .cliNotInstalled:
            return "The 1Password CLI isn't installed where VaultSquire can find it."
        case .unsupportedVersion(let version):
            return "The installed 1Password CLI (\(version)) isn't a version VaultSquire has verified yet."
        case .unparseableVersion:
            return "VaultSquire couldn't read the 1Password CLI's version."
        case .notAuthorized:
            // The CLI reports a locked app, a disabled integration, and a
            // declined prompt the same way, so name all three rather than
            // guessing which one happened.
            return "1Password didn't authorize the read. Make sure the 1Password app is running and unlocked with \"Integrate with 1Password CLI\" turned on in Settings › Developer, then try again and approve its prompt."
        case .unusableAccount:
            return "This vault's 1Password account is no longer one the CLI will accept. Remove the vault and add it again."
        case .incompleteVaultRead:
            return "VaultSquire couldn't read every 1Password vault, so it kept the previous offline snapshot."
        case .unreadableOutput:
            return "The 1Password CLI returned output VaultSquire couldn't read."
        case .executionFailed:
            return "VaultSquire couldn't run the 1Password CLI."
        }
    }

    private static func message(for error: VaultwardenUnlockError) -> String {
        switch error {
        case .wrongPassword:
            return "That master password didn't unlock the vault."
        case .unsupportedKDF:
            return "This account uses a key-derivation method VaultSquire can't run yet (Argon2id)."
        case .legacyEncryptionUnsupported:
            return "This vault uses an older encryption VaultSquire won't read. Open it once with the official Bitwarden app to migrate it, sync here, and try again."
        case .malformedVault:
            return "The stored vault is unreadable. Add the account again to rebuild it."
        }
    }

    private static func message(for error: VaultwardenWriteError) -> String {
        switch error {
        case .sessionExpired:
            return "Your session expired. Add the account again to make changes."
        case .transient:
            return "Couldn't reach the server. The change was not saved."
        case .encryptionFailed:
            return "The item could not be encrypted, so nothing was sent."
        case .rejected(let status, let serverMessage):
            // The server's status and its own words. Without them every
            // failure from a malformed body to a server fault read as the same
            // sentence, which told the user nothing and told a bug report
            // less.
            //
            // Trimmed and bounded, because the text is the server's and not
            // ours: it can arrive as blanks, which would leave a sentence
            // ending in a space, and it has no length of its own that this
            // alert has to honour.
            // Interior runs collapse as well as the ends: a server message can
            // arrive with newlines in it, and this goes into one alert line.
            let collapsed = (serverMessage ?? "")
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            guard !collapsed.isEmpty else {
                return "The server rejected the change (\(status))."
            }
            let detail = collapsed.count > 300
                ? String(collapsed.prefix(300)) + "…"
                : collapsed
            return "The server rejected the change (\(status)). \(detail)"
        case .notPermitted:
            // Not "to this item": a refused create has no item to refer to.
            return "VaultSquire can't make that change."
        case .conflict:
            return "This item changed on the server since your last sync, so the change was not saved. Sync, then make it again."
        }
    }

    private static func message(for error: VaultwardenSyncError) -> String {
        switch error {
        case .sessionExpired:
            return "Your session expired. Add the account again to keep syncing."
        case .transient:
            return "Couldn't reach the server. Showing the last synced vault."
        case .refreshFailed:
            return "The server didn't renew the session. It may be rate-limiting sign-ins; wait a minute and sync again."
        case .unexpectedStatus(let status):
            return "The server answered sync with HTTP \(status)."
        case .responseTooLarge:
            return "The sync response exceeded VaultSquire's size limit."
        case .malformedResponse:
            return "The server's sync response was unreadable."
        case .localStorageFailed:
            return "The stored account data on this Mac couldn't be read."
        }
    }

    // MARK: - Presence source

    /// Reads presence from the Keychain-backed store without loading secret
    /// bytes. Store unavailability is reported as `unknown`, never as absence.
    /// Nonisolated so it can serve as the default for the nonisolated query
    /// closure; it touches only the Sendable store.
    nonisolated static func keychainAccountPresence() -> AccountPresence {
        do {
            let present = try KeychainCredentialStore().hasCredentials(for: .primary)
            return present ? .present : .none
        } catch {
            return .unknown
        }
    }
}

extension AppModel: QuickSearchDataSource {
    /// Quick Search always spans every open vault, whatever the browser is
    /// scoped to; a locked vault contributes nothing.
    var quickSearchItems: [VaultItemProjection] { allOpenItems }

    var quickSearchIsUnlocked: Bool { isUnlocked }

    /// One title per configured vault, so a merged result names its source.
    /// Built with a reduce rather than `uniqueKeysWithValues`, which would trap
    /// if two sessions ever shared an account.
    var quickSearchVaultTitles: [AccountID: String] {
        sessions.reduce(into: [:]) { titles, session in
            titles[session.account] = session.title
        }
    }

    func openFromQuickSearch(_ id: VaultItemID) {
        quickSearchSelection = id
    }

    func deliverFromQuickSearch(
        _ value: QuickSearchCopy,
        of id: VaultItemID,
        via delivery: SecretDelivery,
        beforeDelivery: @escaping @MainActor () -> Void
    ) async -> SecretDeliveryOutcome {
        let resolved: String
        switch value {
        case .username:
            // Not a secret, always present without a fetch, and already legible
            // on the row the user is looking at.
            guard let owner = session(for: id.account), owner.isOpen,
                  let username = owner.items.first(where: { $0.id == id })?.username,
                  !username.isEmpty else {
                return .noSuchValue
            }
            resolved = username
        case .password, .oneTimeCode:
            let kind: CopyableSecret = value == .password ? .password : .oneTimeCode
            switch await resolveSecretAwaitingFetch(kind, of: id) {
            case .success(let secret): resolved = secret
            case .failure(let outcome): return outcome
            }
        }

        // The panel comes down and the target application comes forward before
        // anything is delivered. Keystrokes go to whatever is frontmost when
        // they are posted, so this ordering is the difference between a
        // password reaching the login field and reaching the search panel that
        // was on its way out.
        beforeDelivery()

        if case .typed(let process) = delivery,
           await SecretInjector.type(resolved, into: process) {
            return .typed
        }
        // No Accessibility grant, or nowhere to type into. The clipboard is
        // what this did before typing existed, and it still works.
        if value == .username {
            clipboard.copyPlain(resolved)
        } else {
            clipboard.copySecret(resolved)
        }
        return .copied
    }

    func cancelQuickSearchCopy(of id: VaultItemID) {
        cancelPendingCopy(of: id)
    }

    func clearQuickSearchSelection() {
        quickSearchSelection = nil
    }
}
