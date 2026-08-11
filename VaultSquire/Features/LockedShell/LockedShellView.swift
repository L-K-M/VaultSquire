import SwiftUI

/// The app's root. With no vault configured it shows the empty shell and the
/// Add Account affordance; once at least one vault exists it hands over to the
/// multi-vault browser, which owns per-vault locking and unlocking.
struct LockedShellView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var addAccountModel: AddAccountModel?

    var body: some View {
        Group {
            if appModel.sessions.isEmpty {
                emptyShell
            } else {
                VaultBrowserView(onAddAccount: presentAddAccount)
            }
        }
        .sheet(item: $addAccountModel) { model in
            AddAccountView(
                model: model,
                onClose: { addAccountModel = nil },
                onOpenProtonVault: {
                    addAccountModel = nil
                    appModel.addProtonVault()
                },
                onOpenOnePasswordVault: { account in
                    addAccountModel = nil
                    appModel.addOnePasswordVault(account)
                }
            )
        }
        .onAppear {
            appModel.refreshAccountPresence()
            ApplicationCoordinator.shared.quickSearchDataSource = appModel
        }
    }

    // MARK: - Empty shell

    private var emptyShell: some View {
        HStack(spacing: 0) {
            identityRail
            mainContent
        }
        .frame(minWidth: 680, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("locked-shell")
    }

    /// True when the store definitively reported that no credentials exist.
    private var hasNoAccounts: Bool { appModel.hasNoAccounts }

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
            lockedHeadline
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
            : "This vault is locked. If the unlock prompt doesn't appear, add the account again to rebuild it.")
            .font(.body)
            .foregroundStyle(.secondary)
            .lineSpacing(4)
            .frame(maxWidth: 430, alignment: .leading)
            .padding(.top, 12)
    }

    /// Builds and presents the add-account flow. Shared by the empty shell and
    /// the browser's sidebar so there is one sheet and one construction site.
    private func presentAddAccount() {
        addAccountModel = AddAccountModel(
            credentialStore: KeychainCredentialStore(),
            deviceIdentity: VaultwardenDeviceIdentityStore.current(),
            onAccountConfigured: { [weak appModel] _ in
                appModel?.noteAccountConfigured()
            }
        )
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                presentAddAccount()
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
}
