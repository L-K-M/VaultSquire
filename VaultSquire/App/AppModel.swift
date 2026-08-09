import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum AccessState: Equatable, Sendable {
        case locked
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

    private let queryAccountPresence: () -> AccountPresence

    init(
        queryAccountPresence: @escaping () -> AccountPresence = AppModel.keychainAccountPresence
    ) {
        self.queryAccountPresence = queryAccountPresence
    }

    var isLocked: Bool {
        accessState == .locked
    }

    /// True only when the store answered definitively that no credentials
    /// exist; `unknown` deliberately reads as locked, not as empty.
    var hasNoAccounts: Bool {
        accountPresence == .none
    }

    func lock() {
        accessState = .locked
        ApplicationCoordinator.shared.dismissQuickSearch()
        AppLog.record(.vaultLocked)
    }

    /// Refreshes the account-presence signal from the credential store; the
    /// shell calls this when it appears.
    func refreshAccountPresence() {
        accountPresence = queryAccountPresence()
    }

    /// Notes a just-configured account without another store round trip.
    func noteAccountConfigured() {
        accountPresence = .present
    }

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
