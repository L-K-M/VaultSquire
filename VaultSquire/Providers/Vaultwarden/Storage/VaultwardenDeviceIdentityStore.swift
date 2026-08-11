import Foundation

/// Provides the persistent device identity sent on token grants. The
/// identifier is a random UUID generated once and retained in app preferences
/// (it is a non-secret installation identifier); the name is the user-visible
/// computer name. Preferences hold no secret values.
enum VaultwardenDeviceIdentityStore {
    static let identifierKey = "ch.lkmc.VaultSquire.vaultwarden.deviceIdentifier"

    /// Main-actor isolated so the check-generate-store of the persistent
    /// identifier cannot race a concurrent caller into a lost write. The only
    /// call site is the main-actor add-account entry point.
    @MainActor
    static func current(
        defaults: UserDefaults = .standard,
        deviceName: String = defaultDeviceName()
    ) -> VaultwardenDeviceIdentity {
        let identifier: String
        if let existing = defaults.string(forKey: identifierKey),
           UUID(uuidString: existing) != nil {
            identifier = existing
        } else {
            identifier = UUID().uuidString
            defaults.set(identifier, forKey: identifierKey)
        }

        var safeName = ""
        var bytes = 0
        for character in deviceName {
            guard safeName.count < 128 else { break }
            guard character.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            }) else {
                continue
            }
            let characterBytes = String(character).utf8.count
            guard characterBytes <= 512 - bytes else { break }
            safeName.append(character)
            bytes += characterBytes
        }
        return VaultwardenDeviceIdentity(
            identifier: identifier,
            name: safeName.isEmpty ? "Mac" : safeName
        )
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
