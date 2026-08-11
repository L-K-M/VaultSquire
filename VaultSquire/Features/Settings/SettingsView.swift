import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var siteIcons: SiteIconStore

    var body: some View {
        TabView {
            Form {
                LabeledContent("App shortcut", value: "Command-Shift-Space")
                LabeledContent("Vault state", value: vaultStateDescription)

                Picker("Lock after inactivity", selection: autoLockMinutes) {
                    Text("Never").tag(0.0)
                    Text("1 minute").tag(1.0)
                    Text("5 minutes").tag(5.0)
                    Text("15 minutes").tag(15.0)
                    Text("30 minutes").tag(30.0)
                    Text("1 hour").tag(60.0)
                }
                .accessibilityIdentifier("settings-autolock")

                Divider()

                biometricSection

                Text("Screen lock, sleep, and the screensaver always lock every vault; this clock only covers an idle, unlocked screen. A configurable global shortcut is enabled only after its interaction and security tests pass.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
        .frame(width: 540, height: 380)
        .accessibilityIdentifier("settings-view")
    }

    /// The auto-lock picker, bound to the controller's defaults key. Writing
    /// re-arms the inactivity timer so the new timeout applies immediately
    /// rather than at the next launch. An absent value reads as the default
    /// (15 minutes); a non-positive value is the policy's documented "Never".
    private var autoLockMinutes: Binding<Double> {
        Binding(
            get: {
                let key = AutoLockController.inactivityMinutesKey
                guard let stored = UserDefaults.standard.object(forKey: key) as? Double else {
                    return AutoLockController.defaultInactivityTimeout / 60
                }
                return stored > 0 ? stored : 0
            },
            set: { minutes in
                UserDefaults.standard.set(minutes, forKey: AutoLockController.inactivityMinutesKey)
                AutoLockController.shared.reloadPolicy()
            }
        )
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
