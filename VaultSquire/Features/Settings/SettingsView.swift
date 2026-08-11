import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var siteIcons: SiteIconStore

    /// The configured idle timeout, read once when Settings opens and written
    /// straight through to the controller. `AutoLockController` is not
    /// observable and nothing else changes this while the window is up.
    @State private var autoLockMinutes = AutoLockController.shared.inactivityMinutes

    var body: some View {
        TabView {
            Form {
                LabeledContent("Quick Search", value: "Command-Shift-Space")
                LabeledContent("Vault state", value: vaultStateDescription)

                Divider()

                autoLockSection

                Divider()

                biometricSection
            }
            .padding(24)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No telemetry", systemImage: "hand.raised")
                        .font(.headline)
                    Text("VaultSquire records only fixed, allowlisted lifecycle and performance events. Account and item values are never diagnostic metadata.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                siteIconSection
                Spacer()
            }
            .padding(28)
            .tabItem {
                Label("Privacy", systemImage: "lock")
            }

#if SANDBOX_PROCESS_PROBE
            SandboxProcessProbeView()
                .tabItem {
                    Label("Sandbox Probe", systemImage: "terminal")
                }
#endif
        }
        // A minimum rather than a fixed size: these tabs are mostly prose, and
        // at any increased text size a pinned height clips the last paragraph.
        .frame(minWidth: 560, minHeight: 400)
        .accessibilityIdentifier("settings-view")
    }

    /// The idle timeout, which until now could only be set with `defaults
    /// write` — while Settings said a lock policy was not enabled yet and the
    /// app was in fact locking itself after fifteen minutes.
    ///
    /// The system triggers are listed but not offered as choices: locking on
    /// screen lock, screensaver, sleep, and session resignation is what makes
    /// an unattended Mac safe, and it is not a preference.
    @ViewBuilder
    private var autoLockSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Lock after", selection: $autoLockMinutes) {
                ForEach(AutoLockController.offeredInactivityMinutes, id: \.self) { minutes in
                    Text(Self.timeoutLabel(minutes)).tag(minutes)
                }
            }
            .accessibilityIdentifier("settings-auto-lock")
            .onChange(of: autoLockMinutes) { _, minutes in
                AutoLockController.shared.setInactivityMinutes(minutes)
            }

            Text(autoLockMinutes > 0
                ? "VaultSquire locks every open vault after \(Self.timeoutLabel(autoLockMinutes).lowercased()) without keyboard or pointer activity."
                : "The idle timer is off, so VaultSquire keeps your vaults open until something below closes them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Vaults always lock when the screen locks, the screensaver starts, this Mac sleeps, or you switch users — and with Command-Shift-L. Locking drops every decrypted value, cancels work in flight, and clears a secret VaultSquire put on the clipboard.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func timeoutLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "Never"
        case 1: return "1 minute"
        case 60: return "1 hour"
        default: return "\(minutes) minutes"
        }
    }

    /// How many vaults are open, which is the honest answer now that several
    /// can be. The old wording reported "Unavailable" for an open vault.
    private var vaultStateDescription: String {
        if appModel.hasNoAccounts { return "No accounts" }
        let open = appModel.sessions.filter(\.isOpen).count
        guard open > 0 else { return "Locked" }
        return open == 1 ? "1 vault open" : "\(open) vaults open"
    }

    /// Site-icon opt-in. Off by default, and the wording says plainly what
    /// turning it on costs rather than describing it as a display preference:
    /// it is the one setting that sends anything derived from vault content to
    /// a host that is not the user's own server.
    @ViewBuilder
    private var siteIconSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Show site icons", isOn: $siteIcons.isEnabled)
                .accessibilityIdentifier("settings-site-icons")
            Text("Fetches each login's icon from that site itself. The site learns that this Mac holds an entry for it, so this is off until you ask for it. VaultSquire never uses an icon service, which would receive your whole list of sites instead, and no icon is written to disk.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("With this off, each login still gets a letter on a colour derived from its address — no network, and the same colour every time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Touch ID opt-in. Enrolling needs the vault open, because the key it
    /// stores exists only while the vault is unlocked.
    @ViewBuilder
    private var biometricSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if appModel.canUnlockWithBiometrics {
                Button("Turn Off Touch ID Unlock") {
                    appModel.disableBiometricUnlock()
                }
                .accessibilityIdentifier("settings-biometrics-disable")
                Text("VaultSquire opens with your fingerprint. Your vault key is stored on this Mac, protected by the current set of enrolled fingerprints, and is discarded if they change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if appModel.canEnrollBiometrics {
                Button("Unlock With Touch ID Next Time") {
                    appModel.enableBiometricUnlock()
                }
                .accessibilityIdentifier("settings-biometrics-enable")
                Text("Stores this vault's key on this Mac behind Touch ID so you don't retype your master password. Your master password itself is never stored, and the stored key cannot sign in to your server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(appModel.isUnlocked
                    ? "Touch ID isn't available on this Mac."
                    : "Unlock your vault to set up Touch ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = appModel.biometricError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
