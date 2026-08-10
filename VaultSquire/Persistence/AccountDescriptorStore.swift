import Foundation

/// A non-secret description of one configured account, enough to list it and to
/// name the unlock prompt without opening any encrypted cache. The server URL
/// and email are values the user typed and sees throughout the UI; no secret,
/// token, or key appears here.
struct AccountDescriptor: Sendable, Codable, Hashable, Identifiable {
    let account: AccountID
    /// The account's home, e.g. the Vaultwarden server URL, for display.
    let serverDisplay: String
    /// The login email, shown so the user knows which account they are unlocking.
    let email: String

    var id: AccountID { account }
}

/// Persists the set of configured account descriptors in app preferences, which
/// by rule hold no secret values. It is the source of truth for "which accounts
/// exist" that the shell reads to choose between its empty and locked states,
/// and that the unlock flow reads to label the prompt.
struct AccountDescriptorStore: Sendable {
    // UserDefaults is a thread-safe reference type but not marked Sendable;
    // vouch for it so the store can cross actor boundaries with the service.
    nonisolated(unsafe) private let defaults: UserDefaults
    private static let key = "ch.lkmc.VaultSquire.account-descriptors.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func all() -> [AccountDescriptor] {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([AccountDescriptor].self, from: data) else {
            return []
        }
        return decoded
    }

    func descriptor(for account: AccountID) -> AccountDescriptor? {
        all().first { $0.account == account }
    }

    /// Inserts or replaces a descriptor, keyed by its account.
    func upsert(_ descriptor: AccountDescriptor) {
        var current = all().filter { $0.account != descriptor.account }
        current.append(descriptor)
        write(current)
    }

    func remove(_ account: AccountID) {
        write(all().filter { $0.account != account })
    }

    private func write(_ descriptors: [AccountDescriptor]) {
        guard let data = try? JSONEncoder().encode(descriptors) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
