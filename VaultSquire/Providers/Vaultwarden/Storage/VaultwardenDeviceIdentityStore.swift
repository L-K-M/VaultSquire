import Foundation

/// Provides the persistent device identity sent on token grants. The
/// identifier is a random UUID generated once and retained in app preferences
/// (it is a non-secret installation identifier); the name is the user-visible
/// computer name. Preferences hold no secret values.
enum VaultwardenDeviceIdentityStore {
    static let identifierKey = "ch.lkmc.VaultSquire.vaultwarden.deviceIdentifier"

    static func current(
        defaults: UserDefaults = .standard,
        deviceName: String = defaultDeviceName()
    ) -> VaultwardenDeviceIdentity {
        let identifier: String
        if let existing = defaults.string(forKey: identifierKey), !existing.isEmpty {
            identifier = existing
        } else {
            identifier = UUID().uuidString
            defaults.set(identifier, forKey: identifierKey)
        }

        return VaultwardenDeviceIdentity(identifier: identifier, name: deviceName)
    }

    static func defaultDeviceName() -> String {
        // ProcessInfo reads the local host name without the deprecated `Host`
        // API. Trim a trailing ".local" so the device label reads cleanly.
        var name = ProcessInfo.processInfo.hostName
        if name.hasSuffix(".local") {
            name = String(name.dropLast(".local".count))
        }
        return name.isEmpty ? "Mac" : name
    }
}
