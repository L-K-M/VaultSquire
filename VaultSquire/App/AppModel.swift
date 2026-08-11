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
    @Published private(set) var sessions: [VaultSlot] = []
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
    private let onePasswordService: OnePasswordAccountService
    private let biometricStore: any BiometricVaultKeyStoring
    /// Secret fields fetched on demand for opened Proton items. In memory only
    /// for the life of the session — never sealed into the snapshot — and
    /// dropped when that vault locks.
    @Published private var protonContent: [VaultItemID: ProtonItemContent] = [:]
    /// The same, for opened 1Password items.
    @Published private var onePasswordContent: [VaultItemID: OnePasswordItemContent] = [:]
    private var hydratingItems: Set<VaultItemID> = []

    init(
        queryAccountPresence: @escaping () -> AccountPresence = AppModel.keychainAccountPresence,
        service: VaultwardenAccountService = VaultwardenAccountService(),
        protonService: ProtonAccountService = ProtonAccountService(),
        onePasswordService: OnePasswordAccountService = OnePasswordAccountService(),
        biometricStore: any BiometricVaultKeyStoring = BiometricVaultKeyStore()
    ) {
        self.queryAccountPresence = queryAccountPresence
        self.service = service
        self.protonService = protonService
        self.onePasswordService = onePasswordService
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
    var items: [VaultItemProjection] {
        let scoped: [VaultItemProjection]
        if case .group(_, let group) = scope {
            scoped = scopedSessions.flatMap { $0.items(inGroup: group) }
        } else {
            scoped = scopedSessions.flatMap(\.items)
        }
        return scoped.sorted { lhs, rhs in
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
        // One unlock gesture opens the app, not just this vault.
        openCredentialFreeVaults()
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
    func openCredentialFreeVaults() {
        for account in sessions.filter({ !$0.needsCredentialToOpen }).map(\.account) {
            open(account)
        }
    }

    private func failOpen(_ account: AccountID, generation: UInt64, message: String) {
        guard isCurrent(account, generation) else { return }
        mutate(account) { $0.state = .failed(message) }
        unlockError = message
    }

    /// Records a failed open on that vault's row alone. `unlockError` drives the
    /// master-password prompt, and a Proton CLI that is signed out says nothing
    /// about the Vaultwarden password — so a vault opened alongside another must
    /// not be able to put its message on that prompt.
    private func failOpenLocally(_ account: AccountID, generation: UInt64, message: String) {
        guard isCurrent(account, generation) else { return }
        mutate(account) { $0.state = .failed(message) }
    }

    /// Opens the Proton vault read-only: a CLI refresh, its projections, and a
    /// sealed snapshot for offline read. No Proton credential is ever collected.
    private func openProton(_ account: AccountID) {
        guard let current = session(for: account) else { return }
        let generation = current.generation
        mutate(account) { $0.state = .opening }

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
            case .failure(let error):
                self.failOpenLocally(
                    account, generation: generation, message: Self.message(for: error)
                )
            }
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
        Task { [onePasswordService] in
            let result = await onePasswordService.refresh(accountUUID: accountUUID)
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
            case .failure(let error):
                self.failOpenLocally(
                    account, generation: generation, message: Self.message(for: error)
                )
            }
        }
    }

    /// Closes one vault, dropping only its decrypted state.
    func lock(_ account: AccountID) {
        guard session(for: account) != nil else { return }
        mutate(account) { $0.close() }
        dropFetchedContent(for: account)
        unlockError = nil
        refreshBiometricAvailability()
        if !isUnlocked {
            ApplicationCoordinator.shared.dismissQuickSearch()
        }
        clearClipboardIfOwned()
        AppLog.record(.vaultLocked)
    }

    /// Closes every vault. Idempotent, and the shell's lock-everything action.
    func lock() {
        for account in sessions.map(\.account) {
            mutate(account) { $0.close() }
        }
        protonContent = [:]
        onePasswordContent = [:]
        hydratingItems = []
        unlockError = nil
        refreshBiometricAvailability()
        ApplicationCoordinator.shared.dismissQuickSearch()
        clearClipboardIfOwned()
        AppLog.record(.vaultLocked)
    }

    /// Clears the system clipboard if this app still owns the last copied
    /// secret, so a copied value does not outlive the session that produced it.
    /// The conditional clear leaves another application's later copy untouched.
    private func clearClipboardIfOwned() {
        SecretPasteboard.shared.clearIfOwning()
    }

    /// Drops every on-demand secret fetched for one vault. Both CLI providers
    /// hold theirs in memory only, so closing a vault must clear its entries
    /// from each map.
    private func dropFetchedContent(for account: AccountID) {
        protonContent = protonContent.filter { $0.key.account != account }
        onePasswordContent = onePasswordContent.filter { $0.key.account != account }
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
            return service.detail(for: itemID, keyring: vault.keyring, snapshot: vault.snapshot)
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
            Task { [protonService] in
                let content = await protonService.content(shareID: shareID, itemID: itemID.rawValue)
                self.hydratingItems.remove(itemID)
                // Never publish a secret into a vault the user locked meanwhile.
                guard self.isCurrent(itemID.account, generation), let content else { return }
                self.protonContent[itemID] = content
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
            Task { [onePasswordService] in
                let content = await onePasswordService.content(
                    itemID: itemID.rawValue,
                    vaultID: vaultID,
                    accountUUID: accountUUID
                )
                self.hydratingItems.remove(itemID)
                guard self.isCurrent(itemID.account, generation), let content else { return }
                self.onePasswordContent[itemID] = content
            }
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
        return service.draft(for: itemID, keyring: vault.keyring, snapshot: vault.snapshot)
    }

    /// Whether a given item can be edited.
    func canEdit(_ itemID: VaultItemID) -> Bool {
        draft(for: itemID) != nil
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
                            // A sync can add or rename folders, so the sidebar's
                            // list is refreshed with the items it groups.
                            vault.folderNames = service.decryptFolderNames(
                                keyring: vault.keyring, snapshot: snapshot
                            )
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
        case .onePassword:
            let accountUUID = account.rawValue
            Task { [onePasswordService] in
                let result = await onePasswordService.refresh(accountUUID: accountUUID)
                guard self.isCurrent(account, generation) else { return }
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
            }
        }
    }

    // MARK: - Session plumbing

    private func mutate(_ account: AccountID, _ body: (inout VaultSlot) -> Void) {
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
