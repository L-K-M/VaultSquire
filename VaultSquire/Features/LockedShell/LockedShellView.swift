import SwiftUI

struct LockedShellView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var addAccountModel: AddAccountModel?
    @State private var masterPassword = ""

    var body: some View {
        Group {
            if appModel.isUnlocked {
                VaultView()
            } else {
                lockedShell
            }
        }
        .sheet(item: $addAccountModel) { model in
            AddAccountView(model: model) { addAccountModel = nil }
        }
        .onAppear { appModel.refreshAccountPresence() }
    }

    // MARK: - Locked / empty / unlock shell

    private var lockedShell: some View {
        HStack(spacing: 0) {
            identityRail
            mainContent
        }
        .frame(minWidth: 680, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("locked-shell")
    }

    /// True when the store definitively reported that no account exists; the
    /// shell then presents the empty state instead of an unlock prompt.
    private var hasNoAccounts: Bool { appModel.hasNoAccounts }

    /// Whether a stored account exists that can be unlocked with a password.
    private var unlockableAccount: AccountDescriptor? {
        hasNoAccounts ? nil : appModel.primaryAccount
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

            if let account = unlockableAccount {
                unlockPrompt(account)
            } else {
                lockedHeadline
            }

            Spacer()

            actionRow
        }
        .padding(.horizontal, 52)
        .padding(.vertical, 38)
    }

    @ViewBuilder
    private var lockedHeadline: some View {
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
    }

    @ViewBuilder
    private func unlockPrompt(_ account: AccountDescriptor) -> some View {
        Text("Unlock your vault")
            .font(.system(size: 34, weight: .semibold, design: .rounded))
            .accessibilityIdentifier("locked-shell-title")

        Text("\(account.email) at \(account.serverDisplay)")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 6)

        SecureField("Master password", text: $masterPassword)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 360)
            .padding(.top, 18)
            .onSubmit(submitUnlock)
            .accessibilityIdentifier("unlock-password")

        if let error = appModel.unlockError {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .padding(.top, 8)
                .accessibilityIdentifier("unlock-error")
        }

        Button(action: submitUnlock) {
            if appModel.isUnlocking {
                ProgressView().controlSize(.small)
            } else {
                Text("Unlock")
            }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(masterPassword.isEmpty || appModel.isUnlocking)
        .padding(.top, 14)
        .accessibilityIdentifier("unlock-submit")
    }

    private var actionRow: some View {
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
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityIdentifier("open-add-account")

            Button {
                ApplicationCoordinator.shared.showQuickSearch()
            } label: {
                Label("Quick Search", systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("open-quick-search")

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .accessibilityIdentifier("open-settings")
        }
    }

    private func submitUnlock() {
        guard !masterPassword.isEmpty else { return }
        appModel.unlock(password: masterPassword)
        masterPassword = ""
    }
}
