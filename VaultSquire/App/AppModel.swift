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

    @Published private(set) var accessState: AccessState = .locked
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
    /// The unlocked keyring, snapshot, and items. Held only while unlocked and
    /// dropped on lock, so decrypted state never outlives the session.
    private var unlocked: VaultwardenUnlockedVault?

    init(
        queryAccountPresence: @escaping () -> AccountPresence = AppModel.keychainAccountPresence,
        service: VaultwardenAccountService = VaultwardenAccountService()
    ) {
        self.queryAccountPresence = queryAccountPresence
        self.service = service
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
                self.accessState = .unlocked
                self.syncNow()
                return
            } catch let error as VaultwardenUnlockError {
                self.finishFailedUnlock(Self.message(for: error))
            } catch VaultwardenAccountError.noVault {
                self.finishFailedUnlock("No stored vault was found. Add the account again to sync it.")
            } catch {
                self.finishFailedUnlock("The vault could not be opened.")
            }
        }
    }

    private func finishFailedUnlock(_ message: String) {
        accessState = .locked
        unlockError = message
    }

    /// Locks unconditionally and idempotently, dropping the keyring and every
    /// decrypted projection.
    func lock() {
        accessState = .locked
        unlocked = nil
        items = []
        unlockError = nil
        ApplicationCoordinator.shared.dismissQuickSearch()
        AppLog.record(.vaultLocked)
    }

    /// The decrypted detail for an item, or nil when locked or unknown. Computed
    /// on demand so secrets are materialized only when a detail is shown.
    func detail(for itemID: VaultItemID) -> VaultItemDetail? {
        guard let unlocked else { return nil }
        return service.detail(for: itemID, keyring: unlocked.keyring, snapshot: unlocked.snapshot)
    }

    // MARK: - Writes

    /// Whether the unlocked account supports creating items.
    var canCreateItems: Bool {
        isUnlocked && VaultwardenAccountService.capabilities.contains(.createItem)
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

    // MARK: - Messages

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
        case .malformedResponse:
            return "The server's sync response was unreadable."
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
