import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    /// Vault-access dimension as the shell needs it: locked, an unlock in
    /// flight, or unlocked with decrypted items available.
    enum AccessState: Equatable, Sendable {
        case locked
        case unlocking
        case unlocked
    }

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

    /// Which provider's vault is currently open. Unlocking is mutually
    /// exclusive: one vault is open at a time, and writes and sync route to the
    /// active provider. Proton is read-only, so write actions are disabled while
    /// it is active.
    enum ActiveVault: Equatable, Sendable {
        case none
        case vaultwarden
        case proton
    }

    @Published private(set) var accessState: AccessState = .locked
    @Published private(set) var activeVault: ActiveVault = .none
    @Published private(set) var accountPresence: AccountPresence = .unknown
    /// The configured accounts, for display in the shell and unlock prompt.
    @Published private(set) var accounts: [AccountDescriptor] = []
    /// Decrypted item projections, populated only while unlocked and cleared on
    /// lock. Secrets are not here; the detail view decrypts on demand.
    @Published private(set) var items: [VaultItemProjection] = []
    /// A non-blocking unlock failure message shown on the unlock prompt.
    @Published private(set) var unlockError: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var syncError: String?
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var isWriting = false
    @Published private(set) var writeError: String?
    /// Set when Quick Search opens an item; the vault view consumes it to select
    /// that item, then clears it.
    @Published var quickSearchSelection: VaultItemID?

    private let queryAccountPresence: () -> AccountPresence
    private let service: VaultwardenAccountService
    private let protonService: ProtonAccountService
    /// The unlocked keyring, snapshot, and items. Held only while unlocked and
    /// dropped on lock, so decrypted state never outlives the session.
    private var unlocked: VaultwardenUnlockedVault?
    /// The open Proton snapshot, held only while the Proton vault is open and
    /// dropped on lock. It is a lossy, device-sealed capture, never a write
    /// source.
    private var protonSnapshot: ProtonSnapshot?

    init(
        queryAccountPresence: @escaping () -> AccountPresence = AppModel.keychainAccountPresence,
        service: VaultwardenAccountService = VaultwardenAccountService(),
        protonService: ProtonAccountService = ProtonAccountService()
    ) {
        self.queryAccountPresence = queryAccountPresence
        self.service = service
        self.protonService = protonService
    }

    var isLocked: Bool { accessState == .locked }
    var isUnlocking: Bool { accessState == .unlocking }
    var isUnlocked: Bool { accessState == .unlocked }

    /// True only when the store answered definitively that no credentials
    /// exist; `unknown` deliberately reads as locked, not as empty.
    var hasNoAccounts: Bool { accountPresence == .none }

    var primaryAccount: AccountDescriptor? { accounts.first }

    // MARK: - Presence and accounts

    /// Refreshes the account-presence signal from the credential store and the
    /// descriptor list; the shell calls this when it appears.
    func refreshAccountPresence() {
        accountPresence = queryAccountPresence()
        accounts = service.descriptorStore.all()
        lastSyncedAt = (try? service.loadSnapshot())?.syncedAt
    }

    /// Notes a just-configured account without another store round trip.
    func noteAccountConfigured() {
        accountPresence = .present
        accounts = service.descriptorStore.all()
    }

    // MARK: - Unlock / lock

    func unlock(password: String) {
        guard !password.isEmpty, accessState != .unlocking else { return }
        accessState = .unlocking
        unlockError = nil
        let passwordBytes = Data(password.utf8)

        Task { [service] in
            var bytes = passwordBytes
            defer { VaultwardenCryptoZeroize.zero(&bytes) }
            do {
                let vault = try await service.unlock(masterPasswordBytes: bytes)
                self.unlocked = vault
                self.items = vault.items
                self.activeVault = .vaultwarden
                self.accessState = .unlocked
                self.syncNow()
                return
            } catch let error as VaultwardenUnlockError {
                self.finishFailedUnlock(Self.message(for: error))
            } catch VaultwardenAccountError.noVault {
                self.finishFailedUnlock("No stored vault was found. Add the account again to sync it.")
            } catch VaultwardenAccountError.missingKeyMaterial {
                self.finishFailedUnlock("Couldn't fetch your vault key from the server. Check your connection and try again.")
            } catch {
                self.finishFailedUnlock("The vault could not be opened.")
            }
        }
    }

    private func finishFailedUnlock(_ message: String) {
        accessState = .locked
        unlockError = message
    }

    /// Locks unconditionally and idempotently, dropping the keyring, the Proton
    /// snapshot, and every decrypted projection.
    func lock() {
        accessState = .locked
        activeVault = .none
        unlocked = nil
        protonSnapshot = nil
        items = []
        unlockError = nil
        ApplicationCoordinator.shared.dismissQuickSearch()
        AppLog.record(.vaultLocked)
    }

    /// The decrypted detail for an item, or nil when locked or unknown. Computed
    /// on demand so secrets are materialized only when a detail is shown. A
    /// Proton item resolves from its lossy snapshot; every other item from the
    /// Vaultwarden keyring.
    func detail(for itemID: VaultItemID) -> VaultItemDetail? {
        if itemID.provider == .protonCLI {
            guard let protonSnapshot else { return nil }
            return protonService.detail(for: itemID, snapshot: protonSnapshot)
        }
        guard let unlocked else { return nil }
        return service.detail(for: itemID, keyring: unlocked.keyring, snapshot: unlocked.snapshot)
    }

    // MARK: - Proton (read-only)

    /// Opens the Proton vault read-only: runs a full CLI refresh, publishes its
    /// projections, and seals the snapshot for offline read. Failure returns to
    /// the locked shell with an honest message; no Proton credential is ever
    /// collected here.
    func openProtonVault() {
        guard accessState != .unlocking else { return }
        accessState = .unlocking
        unlockError = nil

        Task { [protonService] in
            let result = await protonService.refresh()
            switch result {
            case .success(let refresh):
                self.protonSnapshot = refresh.snapshot
                self.items = refresh.projections
                self.activeVault = .proton
                self.accessState = .unlocked
                self.lastSyncedAt = refresh.snapshot.capturedAt
                self.syncError = nil
            case .failure(let error):
                self.accessState = .locked
                self.unlockError = Self.message(for: error)
            }
        }
    }

    // MARK: - Writes

    /// Whether the active vault supports creating items. Proton is read-only,
    /// so this is false while it is active.
    var canCreateItems: Bool {
        isUnlocked && activeVault == .vaultwarden
            && VaultwardenAccountService.capabilities.contains(.createItem)
    }

    /// Whether the active vault supports archiving items. Proton has no archive
    /// operation, so this is false while it is active.
    var canArchiveItems: Bool {
        isUnlocked && activeVault == .vaultwarden
            && VaultwardenAccountService.capabilities.contains(.archiveItem)
    }

    /// An editable draft for an item, or nil when locked or the item is not
    /// editable (only login items are editable in this slice).
    func draft(for itemID: VaultItemID) -> VaultItemDraft? {
        guard let unlocked else { return nil }
        return service.draft(for: itemID, keyring: unlocked.keyring, snapshot: unlocked.snapshot)
    }

    /// Whether a given item can be edited (an unlocked login item).
    func canEdit(_ itemID: VaultItemID) -> Bool {
        draft(for: itemID) != nil
    }

    /// Saves a create or edit, then re-syncs to pull the authoritative state.
    func save(_ draft: VaultItemDraft) {
        guard let vault = unlocked, !isWriting else { return }
        isWriting = true
        writeError = nil
        Task { [service] in
            let result = draft.isEditing
                ? await service.update(draft: draft, keyring: vault.keyring)
                : await service.create(draft: draft, keyring: vault.keyring)
            self.isWriting = false
            switch result {
            case .success:
                self.syncNow()
            case .failure(let error):
                self.writeError = Self.message(for: error)
            }
        }
    }

    func archive(_ itemID: VaultItemID) {
        guard unlocked != nil, !isWriting else { return }
        isWriting = true
        writeError = nil
        Task { [service] in
            let result = await service.archive(itemID: itemID)
            self.isWriting = false
            switch result {
            case .success:
                self.syncNow()
            case .failure(let error):
                self.writeError = Self.message(for: error)
            }
        }
    }

    // MARK: - Sync

    func syncNow() {
        guard !isSyncing else { return }
        if activeVault == .proton {
            syncProton()
            return
        }
        isSyncing = true
        syncError = nil

        Task { [service] in
            let result = await service.sync()
            self.isSyncing = false
            switch result {
            case .success(let snapshot):
                self.lastSyncedAt = snapshot.syncedAt
                self.syncError = nil
                if var vault = self.unlocked {
                    vault.snapshot = snapshot
                    vault.items = service.projections(keyring: vault.keyring, snapshot: snapshot)
                    self.unlocked = vault
                    self.items = vault.items
                }
            case .failure(let error):
                self.syncError = Self.message(for: error)
            }
        }
    }

    /// Re-runs the Proton read refresh, refreshing the projections and the
    /// sealed snapshot. A failure surfaces on the sync status line without
    /// dropping the currently shown items.
    private func syncProton() {
        isSyncing = true
        syncError = nil
        Task { [protonService] in
            let result = await protonService.refresh()
            self.isSyncing = false
            switch result {
            case .success(let refresh):
                self.protonSnapshot = refresh.snapshot
                self.items = refresh.projections
                self.lastSyncedAt = refresh.snapshot.capturedAt
                self.syncError = nil
            case .failure(let error):
                self.syncError = Self.message(for: error)
            }
        }
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
    var quickSearchItems: [VaultItemProjection] { items }
    var quickSearchIsUnlocked: Bool { isUnlocked }

    func openFromQuickSearch(_ id: VaultItemID) {
        quickSearchSelection = id
    }

    func clearQuickSearchSelection() {
        quickSearchSelection = nil
    }
}
