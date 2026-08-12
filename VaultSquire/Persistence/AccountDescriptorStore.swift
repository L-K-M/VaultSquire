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
        decodedDescriptors() ?? []
    }

    func descriptor(for account: AccountID) -> AccountDescriptor? {
        all().first { $0.account == account }
    }

    /// Inserts or replaces a descriptor, keyed by its account. Corrupt existing
    /// preferences are never treated as an empty list and overwritten; callers
    /// get `false` and keep the account transaction incomplete/locked.
    @discardableResult
    func upsert(_ descriptor: AccountDescriptor) -> Bool {
        guard Self.isValid(descriptor),
              var current = decodedDescriptors() else {
            return false
        }
        current.removeAll { $0.account == descriptor.account }
        current.append(descriptor)
        return write(current)
    }

    @discardableResult
    func remove(_ account: AccountID) -> Bool {
        guard let current = decodedDescriptors() else { return false }
        return write(current.filter { $0.account != account })
    }

    private func decodedDescriptors() -> [AccountDescriptor]? {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        guard data.count <= 256 * 1024,
              let decoded = try? JSONDecoder().decode([AccountDescriptor].self, from: data),
              decoded.count <= 100,
              Set(decoded.map(\.account)).count == decoded.count,
              decoded.allSatisfy(Self.isValid) else {
            return nil
        }
        return decoded
    }

    private func write(_ descriptors: [AccountDescriptor]) -> Bool {
        guard descriptors.count <= 100,
              Set(descriptors.map(\.account)).count == descriptors.count,
              descriptors.allSatisfy(Self.isValid),
              let data = try? JSONEncoder().encode(descriptors),
              data.count <= 256 * 1024 else {
            return false
        }
        defaults.set(data, forKey: Self.key)
        return defaults.data(forKey: Self.key) == data
    }

    private static func isValid(_ descriptor: AccountDescriptor) -> Bool {
        !descriptor.account.provider.rawValue.isEmpty
            && descriptor.account.provider.rawValue.utf8.count <= 64
            && !descriptor.account.rawValue.isEmpty
            && descriptor.account.rawValue.utf8.count <= 256
            && !descriptor.serverDisplay.isEmpty
            && descriptor.serverDisplay.utf8.count <= 2_048
            && descriptor.email.utf8.count <= 320
            && descriptor.serverDisplay.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
            && descriptor.email.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }
}
