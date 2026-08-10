import Combine
import Foundation

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
    @Published private(set) var sessions: [VaultSession] = []
    /// What the item list is showing: everything open, or one vault.
    @Published var scope: VaultScope = .allVaults

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

    private let queryAccountPresence: () -> AccountPresence
    private let service: VaultwardenAccountService
    private let protonService: ProtonAccountService
    private let biometricStore: any BiometricVaultKeyStoring
    /// Secret fields fetched on demand for opened Proton items. In memory only
    /// for the life of the session — never sealed into the snapshot — and
    /// dropped when that vault locks.
    @Published private var protonContent: [VaultItemID: ProtonItemContent] = [:]
    private var hydratingItems: Set<VaultItemID> = []

    init(
        queryAccountPresence: @escaping () -> AccountPresence = AppModel.keychainAccountPresence,
        service: VaultwardenAccountService = VaultwardenAccountService(),
        protonService: ProtonAccountService = ProtonAccountService(),
        biometricStore: any BiometricVaultKeyStoring = BiometricVaultKeyStore()
    ) {
        self.queryAccountPresence = queryAccountPresence
        self.service = service
        self.protonService = protonService
        self.biometricStore = biometricStore
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
    var scopedSessions: [VaultSession] {
        switch scope {
        case .allVaults:
            return sessions.filter(\.isOpen)
        case .vault(let account):
            return sessions.filter { $0.account == account && $0.isOpen }
        }
    }

    /// The items shown for the current scope, merged across vaults when the
    /// scope is All Vaults and sorted by title so a merged list reads as one.
    var items: [VaultItemProjection] {
        scopedSessions
            .flatMap(\.items)
            .sorted { lhs, rhs in
                lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            }
    }

    /// Every open vault's items, for Quick Search — it always searches
    /// everything that is open, regardless of the browser's scope.
    var allOpenItems: [VaultItemProjection] {
        sessions.filter(\.isOpen).flatMap(\.items)
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

    func session(for account: AccountID) -> VaultSession? {
        sessions.first { $0.account == account }
    }

    /// The vault a single-vault scope names, whether or not it is open.
    var selectedSession: VaultSession? {
        guard case .vault(let account) = scope else { return nil }
        return session(for: account)
    }

    // MARK: - Presence and accounts

    /// Rebuilds the vault list from the stored descriptors, preserving the open
    /// state of vaults that are already open.
    func refreshAccountPresence() {
        accountPresence = queryAccountPresence()
        accounts = service.descriptorStore.all()

        var rebuilt: [VaultSession] = []
        for descriptor in accounts {
            if let existing = session(for: descriptor.account) {
                rebuilt.append(existing)
                continue
            }
            rebuilt.append(Self.makeSession(for: descriptor))
        }
        // Keep any open vault whose descriptor vanished rather than silently
        // dropping decrypted state on the floor.
        for open in sessions where open.isOpen && !rebuilt.contains(where: { $0.account == open.account }) {
            rebuilt.append(open)
        }
        sessions = rebuilt

        if case .vault(let account) = scope, session(for: account) == nil {
            scope = .allVaults
        }
        refreshBiometricAvailability()
    }

    private static func makeSession(for descriptor: AccountDescriptor) -> VaultSession {
        let isProton = descriptor.account.provider == .protonCLI
        return VaultSession(
            account: descriptor.account,
            kind: isProton ? .proton : .vaultwarden,
            title: isProton ? "Proton Pass" : descriptor.serverDisplay,
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

    // MARK: - Open / lock

    /// Opens a vault. Vaultwarden vaults need a password or Touch ID, so this
    /// only starts the Proton read; the password path is `unlock(_:password:)`.
    func open(_ account: AccountID) {
        guard let existing = session(for: account), !existing.isOpening, !existing.isOpen else { return }
        switch existing.kind {
        case .proton:
            openProton(account)
        case .vaultwarden:
            // Nothing to do without a credential; the UI shows the prompt.
            break
        }
    }

    func unlock(_ account: AccountID, password: String) {
        guard !password.isEmpty,
              let current = session(for: account),
              current.kind == .vaultwarden,
              !current.isOpening else {
            return
        }
        let generation = current.generation
        mutate(account) { $0.state = .opening }
        unlockError = nil
        let passwordBytes = Data(password.utf8)

        Task { [service] in
            var bytes = passwordBytes
            defer { VaultwardenCryptoZeroize.zero(&bytes) }
            do {
                let vault = try await service.unlock(masterPasswordBytes: bytes)
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
        unlockError = nil

        Task { [protonService] in
            let result = await protonService.refresh()
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
                self.unlockError = nil
            case .failure(let error):
                self.failOpen(account, generation: generation, message: Self.message(for: error))
            }
        }
    }

    /// Closes one vault, dropping only its decrypted state.
    func lock(_ account: AccountID) {
        guard session(for: account) != nil else { return }
        mutate(account) { $0.close() }
        dropProtonContent(for: account)
        unlockError = nil
        refreshBiometricAvailability()
        if !isUnlocked {
            ApplicationCoordinator.shared.dismissQuickSearch()
        }
        AppLog.record(.vaultLocked)
    }

    /// Closes every vault. Idempotent, and the shell's lock-everything action.
    func lock() {
        for account in sessions.map(\.account) {
            mutate(account) { $0.close() }
        }
        protonContent = [:]
        hydratingItems = []
        unlockError = nil
        refreshBiometricAvailability()
        ApplicationCoordinator.shared.dismissQuickSearch()
        AppLog.record(.vaultLocked)
    }

    private func dropProtonContent(for account: AccountID) {
        protonContent = protonContent.filter { $0.key.account != account }
        hydratingItems = hydratingItems.filter { $0.account != account }
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

        Task { [service, biometricStore] in
            guard let wrapped = service.currentWrappedUserKey() else {
                self.failOpen(
                    account, generation: generation,
                    message: "No stored vault was found. Add the account again to sync it."
                )
                return
            }
            do {
                var keyData = try await biometricStore.loadUserKey(
                    for: account,
                    boundTo: wrapped,
                    reason: "Unlock your VaultSquire vault"
                )
                defer { VaultwardenCryptoZeroize.zero(&keyData) }
                let vault = try service.unlock(userKeyData: keyData)
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
        guard let vault = session(for: .vaultwardenPrimary)?.vaultwarden else { return }
        let keyData = vault.keyring.userKey.encryptionKey + vault.keyring.userKey.macKey
        do {
            try biometricStore.store(
                userKey: keyData,
                boundTo: vault.snapshot.wrappedUserKey,
                for: .vaultwardenPrimary
            )
            biometricError = nil
        } catch {
            biometricError = "Touch ID couldn't be enabled for this vault."
        }
        refreshBiometricAvailability()
    }

    /// Forgets the enrolled key, so the next unlock needs the master password.
    func disableBiometricUnlock() {
        try? biometricStore.remove(for: .vaultwardenPrimary)
        biometricError = nil
        refreshBiometricAvailability()
    }

    // MARK: - Item detail

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
        case .vaultwarden:
            guard let vault = owner.vaultwarden else { return nil }
            return service.detail(for: itemID, keyring: vault.keyring, snapshot: vault.snapshot)
        }
    }

    /// Fetches a Proton item's secret fields the first time it is opened.
    /// Listing a Proton vault deliberately carries no secrets — one CLI call per
    /// item would make opening a vault take minutes — so the detail view asks
    /// for them here. A no-op for any other provider or an already-fetched item.
    func hydrateIfNeeded(_ itemID: VaultItemID) {
        guard itemID.provider == .protonCLI,
              let owner = session(for: itemID.account), owner.isOpen,
              protonContent[itemID] == nil,
              !hydratingItems.contains(itemID),
              let shareID = ProtonAccountService.shareIdentifier(of: itemID) else {
            return
        }
        let generation = owner.generation
        hydratingItems.insert(itemID)
        Task { [protonService] in
            let content = await protonService.content(shareID: shareID, itemID: itemID.rawValue)
            self.hydratingItems.remove(itemID)
            // Never publish a secret into a vault the user locked meanwhile.
            guard self.isCurrent(itemID.account, generation), let content else { return }
            self.protonContent[itemID] = content
        }
    }

    /// True while an item's secret fields are being fetched, so the detail can
    /// say so instead of looking like the item simply has no password.
    func isHydrating(_ itemID: VaultItemID) -> Bool {
        hydratingItems.contains(itemID)
    }

    // MARK: - Writes

    /// The vault a new item would be created in: the selected one when it is an
    /// open writable vault, otherwise the only open writable vault. Nil when
    /// that is ambiguous or unavailable, which is what disables Add Item.
    var createTarget: VaultSession? {
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
        return service.draft(for: itemID, keyring: vault.keyring, snapshot: vault.snapshot)
    }

    /// Whether a given item can be edited.
    func canEdit(_ itemID: VaultItemID) -> Bool {
        draft(for: itemID) != nil
    }

    /// Saves a create or edit. An edit routes to the vault that owns the item;
    /// a create goes to the unambiguous writable target.
    func save(_ draft: VaultItemDraft) {
        guard !isWriting else { return }
        let account = draft.itemID?.account ?? createTarget?.account
        guard let account,
              let owner = session(for: account),
              owner.isOpen,
              let vault = owner.vaultwarden else {
            return
        }
        isWriting = true
        writeError = nil
        Task { [service] in
            let result = draft.isEditing
                ? await service.update(draft: draft, keyring: vault.keyring)
                : await service.create(draft: draft, keyring: vault.keyring)
            self.isWriting = false
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
        isWriting = true
        writeError = nil
        Task { [service] in
            let result = await service.archive(itemID: itemID)
            self.isWriting = false
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
            Task { [service] in
                let result = await service.sync()
                guard self.isCurrent(account, generation) else { return }
                self.mutate(account) { session in
                    session.isSyncing = false
                    switch result {
                    case .success(let snapshot):
                        session.lastSyncedAt = snapshot.syncedAt
                        session.syncError = nil
                        if var vault = session.vaultwarden {
                            vault.snapshot = snapshot
                            vault.items = service.projections(keyring: vault.keyring, snapshot: snapshot)
                            session.vaultwarden = vault
                            session.items = vault.items
                        }
                    case .failure(let error):
                        session.syncError = Self.message(for: error)
                    }
                }
            }
        case .proton:
            Task { [protonService] in
                let result = await protonService.refresh()
                guard self.isCurrent(account, generation) else { return }
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
            }
        }
    }

    // MARK: - Session plumbing

    private func mutate(_ account: AccountID, _ body: (inout VaultSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.account == account }) else { return }
        body(&sessions[index])
    }

    /// Whether a vault is still on the generation an async task started under.
    /// A lock advances it, so a stale result is discarded rather than published
    /// into a vault the user closed.
    private func isCurrent(_ account: AccountID, _ generation: UInt64) -> Bool {
        session(for: account)?.generation == generation
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
        case .unreadableOutput:
            return "The Proton Pass CLI returned output VaultSquire couldn't read."
        case .executionFailed:
            return "VaultSquire couldn't run the Proton Pass CLI."
        }
    }

    private static func message(for error: VaultwardenUnlockError) -> String {
        switch error {
        case .wrongPassword:
            return "That master password didn't unlock the vault."
        case .unsupportedKDF:
            return "This account uses a key-derivation method VaultSquire can't run yet (Argon2id)."
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
        case .rejected:
            return "The server rejected the change."
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

    func openFromQuickSearch(_ id: VaultItemID) {
        quickSearchSelection = id
    }

    func clearQuickSearchSelection() {
        quickSearchSelection = nil
    }
}
