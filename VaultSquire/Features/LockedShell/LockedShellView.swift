import SwiftUI

struct LockedShellView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var addAccountModel: AddAccountModel?

    var body: some View {
        HStack(spacing: 0) {
            identityRail
            mainContent
        }
        .frame(minWidth: 680, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("locked-shell")
        .onAppear { appModel.refreshAccountPresence() }
        .sheet(item: $addAccountModel) { model in
            AddAccountView(model: model) { addAccountModel = nil }
        }
    }

    /// True when the credential store definitively reported that no account
    /// exists; the shell then presents the empty state instead of claiming a
    /// nonexistent vault is locked.
    private var hasNoAccounts: Bool {
        appModel.hasNoAccounts
    }

    private var identityRail: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.16, blue: 0.21),
                    Color(red: 0.18, green: 0.25, blue: 0.29)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 34, weight: .medium))
                    .accessibilityHidden(true)

                Text("VAULTSQUIRE")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .tracking(2.4)

                Text("A native place for the vaults you control.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                Label(hasNoAccounts ? "NO ACCOUNTS" : "LOCKED", systemImage: "circle.fill")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(hasNoAccounts ? "No accounts configured" : "Vault locked")
            }
            .padding(32)
        }
        .foregroundStyle(.white)
        .frame(width: 270)
        .accessibilityElement(children: .combine)
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 48)

            Text(hasNoAccounts ? "No accounts yet" : "The vault is locked")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .accessibilityIdentifier("locked-shell-title")

            Text(hasNoAccounts
                ? "Add an account to bring its vault under VaultSquire's watch. Credentials are stored only after a sign-in completes."
                : "Unlock arrives in its provider milestone. This shell keeps decrypted state closed.")
                .font(.body)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .frame(maxWidth: 430, alignment: .leading)
                .padding(.top, 12)

            Divider()
                .padding(.vertical, 30)

            VStack(alignment: .leading, spacing: 14) {
                Label("Quick Search opens in locked mode", systemImage: "command")
                Label("No vault content is loaded", systemImage: "externaldrive.badge.xmark")
                Label("Diagnostics accept allowlisted events only", systemImage: "waveform.path.ecg")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 12) {
                Button {
                    addAccountModel = AddAccountModel(
                        credentialStore: KeychainCredentialStore(),
                        deviceIdentity: VaultwardenDeviceIdentityStore.current(),
                        onAccountConfigured: { [weak appModel] _ in
                            appModel?.noteAccountConfigured()
                        }
                    )
                } label: {
                    Label("Add Account", systemImage: "person.badge.plus")
                }
                // With no accounts, adding one is the primary action; with a
                // configured account, Quick Search keeps that role.
                .keyboardShortcut(hasNoAccounts ? .defaultAction : KeyboardShortcut("n", modifiers: .command))
                .accessibilityIdentifier("open-add-account")

                Button {
                    ApplicationCoordinator.shared.showQuickSearch()
                } label: {
                    Label("Quick Search", systemImage: "magnifyingglass")
                }
                .keyboardShortcut(hasNoAccounts ? nil : .defaultAction)
                .accessibilityIdentifier("open-quick-search")

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("open-settings")
            }
        }
        .padding(.horizontal, 52)
        .padding(.vertical, 38)
    }
}
