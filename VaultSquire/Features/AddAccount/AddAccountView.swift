import SwiftUI

/// The provider choices offered by the add-account sheet. Vaultwarden signs in
/// with a form; Proton Pass and 1Password are credential-free detection panes
/// over their own official user-installed CLIs, bound by
/// PROTON_PASS_RESEARCH.md and ONEPASSWORD_CLI_RESEARCH.md.
enum AddAccountProvider: Hashable {
    case vaultwarden
    case protonPass
    case onePassword
}

/// The add-account sheet: a provider selector over a single sign-in form
/// that, on a second-factor challenge, swaps to the two-factor screen and
/// back. A cross-origin service advertisement replaces the sheet content with
/// an approval panel until the user decides. Presented as a sheet so the app
/// keeps its single main window.
struct AddAccountView: View {
    @ObservedObject var model: AddAccountModel
    let onClose: () -> Void
    /// Invoked when the user opens their Proton vault from the detection pane.
    /// The shell wires this to the read-only open flow and dismisses the sheet.
    var onOpenProtonVault: () -> Void = {}
    /// The same, for the 1Password detection pane. It carries the account the
    /// user chose, because a person can have several signed in at once and
    /// each becomes its own vault.
    var onOpenOnePasswordVault: (OnePasswordAccount) -> Void = { _ in }

    @StateObject private var protonConnect = ProtonConnectModel()
    @StateObject private var onePasswordConnect = OnePasswordConnectModel()
    @State private var provider: AddAccountProvider = .vaultwarden

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let request = model.originApproval {
                originApprovalPanel(request)
            } else if model.phase == .challenged {
                TwoFactorChallengeView(model: model)
            } else if model.phase == .succeeded {
                successView
            } else {
                providerHeader
                switch provider {
                case .vaultwarden: signInForm
                case .protonPass: protonPanel
                case .onePassword: onePasswordPanel
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        // Cancel any in-flight sign-in or two-factor work when the sheet is
        // dismissed, so a cancelled flow never persists credentials. This also
        // declines a pending origin approval, so its continuation cannot leak.
        .onDisappear { model.cancel() }
        // Keep this a named container that still exposes its children as
        // individual accessibility elements; applying an identifier alone
        // collapses the subtree into one element under macOS SwiftUI.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("add-account-view")
    }

    private var providerHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Account")
                .font(.title2.weight(.semibold))
            Picker("Provider", selection: $provider) {
                Text("Vaultwarden").tag(AddAccountProvider.vaultwarden)
                Text("Proton Pass").tag(AddAccountProvider.protonPass)
                Text("1Password").tag(AddAccountProvider.onePassword)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Mid-transaction provider hopping would hide the form the flow
            // reports into.
            .disabled(model.phase == .connecting)
            .accessibilityIdentifier("add-account-provider")
        }
    }

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to an existing account on your Vaultwarden server.")
                .foregroundStyle(.secondary)
                .font(.callout)

            VStack(alignment: .leading, spacing: 8) {
                labeledField("Server URL") {
                    TextField("https://vault.example.com", text: $model.serverURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("add-account-url")
                }
                labeledField("Email") {
                    TextField("you@example.com", text: $model.email)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("add-account-email")
                }
                labeledField("Master Password") {
                    SecureField("Master password", text: $model.masterPassword)
                        .textContentType(.password)
                        .accessibilityIdentifier("add-account-password")
                }
            }

            if case .failed(let message) = model.phase {
                Text(message)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .accessibilityIdentifier("add-account-error")
            }

            HStack {
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    model.beginSignIn()
                } label: {
                    if model.phase == .connecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Sign In")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("add-account-submit")
            }
        }
    }

    /// The Proton Pass connection pane. It reads through the official
    /// user-installed CLI and collects no Proton credential: sign-in stays with
    /// the CLI. The pane reports the detected status honestly and offers to open
    /// the vault read-only when a supported, authenticated CLI is present.
    private var protonPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Proton Pass")
                .font(.callout.weight(.semibold))
            Text("VaultSquire reads your Proton Pass vault through the official Proton Pass CLI that you install and sign in to yourself. It never asks for your Proton password.")
                .foregroundStyle(.secondary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            protonStatusContent

            HStack {
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Recheck") { protonConnect.probe() }
                    .accessibilityIdentifier("add-account-proton-recheck")
                if protonConnect.isReady {
                    Button("Open Vault") { onOpenProtonVault() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("add-account-proton-open")
                }
            }
        }
        .onAppear { protonConnect.probe() }
        .onDisappear { protonConnect.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("add-account-proton")
    }

    @ViewBuilder
    private var protonStatusContent: some View {
        switch protonConnect.stage {
        case .probing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for the Proton Pass CLI…").foregroundStyle(.secondary)
            }
        case .status(let status):
            protonStatusMessage(status)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("add-account-proton-status")
        }
    }

    @ViewBuilder
    private func protonStatusMessage(_ status: ProtonConnectionStatus) -> some View {
        switch status {
        case .notInstalled:
            Text("No Proton Pass CLI was found. Install the official CLI, sign in with it, then recheck.")
                .foregroundStyle(.secondary)
        case .unsupportedVersion(let version):
            Text("Found a Proton Pass CLI reporting version \(version), which VaultSquire hasn't verified. Reads stay disabled until a tested version is installed.")
                .foregroundStyle(.secondary)
        case .unparseableVersion:
            Text("VaultSquire couldn't read the Proton Pass CLI's version, so reads stay disabled.")
                .foregroundStyle(.secondary)
        case .notAuthenticated:
            Text("The Proton Pass CLI is installed but not signed in. Sign in with the official CLI in your terminal, then recheck.")
                .foregroundStyle(.secondary)
        case .ready(let version, let approvedPath, let resolvedRealPath):
            VStack(alignment: .leading, spacing: 4) {
                Label("Proton Pass CLI \(version) is ready.", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
                Text(approvedPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if resolvedRealPath != approvedPath {
                    Text("→ \(resolvedRealPath)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        case .error:
            Text("VaultSquire couldn't read the Proton Pass CLI's output, so reads stay disabled.")
                .foregroundStyle(.secondary)
        }
    }

    /// The 1Password connection pane. It reads through the official
    /// user-installed `op` CLI and collects no 1Password credential: the account
    /// password and Secret Key stay with 1Password's own desktop app, which
    /// authorizes the CLI with a biometric prompt. The pane reports the detected
    /// status honestly and offers to open the vault read-only when a supported,
    /// authorized CLI is present.
    private var onePasswordPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1Password")
                .font(.callout.weight(.semibold))
            Text("VaultSquire reads your 1Password vaults through the official 1Password CLI that you install, alongside the 1Password app that authorizes it. It never asks for your account password or Secret Key.")
                .foregroundStyle(.secondary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            onePasswordStatusContent

            HStack {
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Recheck") { onePasswordConnect.probe() }
                    .accessibilityIdentifier("add-account-onepassword-recheck")
            }
        }
        .onAppear { onePasswordConnect.probe() }
        .onDisappear { onePasswordConnect.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("add-account-onepassword")
    }

    @ViewBuilder
    private var onePasswordStatusContent: some View {
        switch onePasswordConnect.stage {
        case .probing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for the 1Password CLI…").foregroundStyle(.secondary)
            }
        case .status(let status):
            onePasswordStatusMessage(status)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("add-account-onepassword-status")
        }
    }

    @ViewBuilder
    private func onePasswordStatusMessage(_ status: OnePasswordConnectionStatus) -> some View {
        switch status {
        case .notInstalled:
            Text("No 1Password CLI was found. Install the official CLI, then recheck.")
                .foregroundStyle(.secondary)
        case .unsupportedVersion(let version):
            Text("Found a 1Password CLI reporting version \(version), which VaultSquire hasn't verified. Reads stay disabled until a tested version is installed.")
                .foregroundStyle(.secondary)
        case .unparseableVersion:
            Text("VaultSquire couldn't read the 1Password CLI's version, so reads stay disabled.")
                .foregroundStyle(.secondary)
        case .noAccounts:
            Text("The 1Password CLI is installed, but no 1Password account is set up on this Mac. Add one in the 1Password app, then recheck.")
                .foregroundStyle(.secondary)
        case .ready(let version, let accounts, let approvedPath, let resolvedRealPath):
            VStack(alignment: .leading, spacing: 8) {
                Label("1Password CLI \(version) is ready.", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
                Text(approvedPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if resolvedRealPath != approvedPath {
                    Text("→ \(resolvedRealPath)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Divider()
                Text(accounts.count == 1 ? "Account" : "Accounts")
                    .font(.callout.weight(.medium))
                // Each account opens as its own vault, so two signed-in
                // accounts never merge into one list.
                ForEach(accounts) { account in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.url)
                            if !account.email.isEmpty {
                                Text(account.email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Open") { onOpenOnePasswordVault(account) }
                            .accessibilityIdentifier("add-account-onepassword-open")
                    }
                }
                Text("1Password will ask you to authorize VaultSquire when a vault opens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .error:
            Text("VaultSquire couldn't read the 1Password CLI's output, so reads stay disabled.")
                .foregroundStyle(.secondary)
        }
    }

    /// Displays the entered origin against the server's advertised service
    /// origins and asks for an explicit decision. This panel is the one place
    /// origins are shown; error messages stay fixed and origin-free. Only
    /// HTTPS advertisements reach this panel — the authenticator discards
    /// plaintext-http ones and stays on the entered origin.
    private func originApprovalPanel(_ request: OriginApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Confirm Server Addresses")
                .font(.title2.weight(.semibold))
            Text("The server reports its services on a different address than the one you entered. Your credentials are sent only to addresses you approve. If these addresses look wrong, correct the server's domain configuration instead of approving.")
                .foregroundStyle(.secondary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                labeledOrigin("You entered", request.entered)
                labeledOrigin("Sign-in service", request.effectiveIdentity)
                labeledOrigin("API service", request.effectiveAPI)
            }

            HStack {
                Button("Cancel") {
                    model.resolveOriginApproval(approved: false)
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("add-account-origin-cancel")
                Spacer()
                Button("Approve and Continue") {
                    model.resolveOriginApproval(approved: true)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("add-account-origin-approve")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("add-account-origin-approval")
    }

    private func labeledOrigin(_ label: String, _ origin: VaultwardenOrigin) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout.weight(.medium))
                .frame(width: 120, alignment: .leading)
            Text(origin.displayString)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
    }

    private var successView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Account Added")
                .font(.title2.weight(.semibold))
            Text("Your account credentials are stored securely. Close this and unlock your vault with your master password.")
                .foregroundStyle(.secondary)
                .font(.callout)
            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("add-account-done")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("add-account-success")
    }

    @ViewBuilder
    private func labeledField<Field: View>(
        _ label: String,
        @ViewBuilder _ field: () -> Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout.weight(.medium))
            field().textFieldStyle(.roundedBorder)
        }
    }
}
