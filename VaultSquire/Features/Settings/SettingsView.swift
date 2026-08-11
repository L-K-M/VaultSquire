import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var siteIcons: SiteIconStore
    @AppStorage(ApplicationCoordinator.clipboardExpirationPreference)
    private var clipboardExpirationSeconds = 30

    var body: some View {
        TabView {
            Form {
                LabeledContent("App shortcut", value: "Command-Shift-Space")
                LabeledContent("Vault state", value: vaultStateDescription)

                Divider()

                biometricSection

                Text("A configurable global shortcut and lock policy are enabled only after their interaction and security tests pass.")
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

                clipboardSection

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
        .frame(width: 540, height: 340)
        .accessibilityIdentifier("settings-view")
    }

    /// How many vaults are open, which is the honest answer now that several
    /// can be. The old wording reported "Unavailable" for an open vault.
    private var vaultStateDescription: String {
        if appModel.hasNoAccounts { return "No accounts" }
        let open = appModel.sessions.filter(\.isOpen).count
        guard open > 0 else { return "Locked" }
        return open == 1 ? "1 vault open" : "\(open) vaults open"
    }

    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Clear copied vault values after", selection: $clipboardExpirationSeconds) {
                Text("5 seconds").tag(5)
                Text("10 seconds").tag(10)
                Text("15 seconds").tag(15)
                Text("30 seconds").tag(30)
            }
            .accessibilityIdentifier("settings-clipboard-expiration")
            Text("VaultSquire clears only a value it still owns. A clipboard manager or another app may already have read it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
            Text("Fetches each login's icon from that site itself. The site learns that this Mac holds an entry for it, so this is off until you ask for it. IP literals and local-only names are blocked, redirects are refused, and no icon is written to disk; a public hostname still controls where its DNS resolves.")
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
