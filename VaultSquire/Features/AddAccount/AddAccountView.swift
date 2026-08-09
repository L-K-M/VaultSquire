import SwiftUI

/// The provider choices offered by the add-account sheet. Vaultwarden is the
/// implemented provider; Proton Pass is listed with its staged status so the
/// selection surface exists ahead of the CLI-based integration bound by
/// PROTON_PASS_RESEARCH.md. The domain's provider namespace already reserves
/// `ProviderID.protonCLI` for it.
enum AddAccountProvider: Hashable {
    case vaultwarden
    case protonPass
}

/// The add-account sheet: a provider selector over a single sign-in form
/// that, on a second-factor challenge, swaps to the two-factor screen and
/// back. A cross-origin service advertisement replaces the sheet content with
/// an approval panel until the user decides. Presented as a sheet so the app
/// keeps its single main window.
struct AddAccountView: View {
    @ObservedObject var model: AddAccountModel
    let onClose: () -> Void

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
                if provider == .vaultwarden {
                    signInForm
                } else {
                    protonPanel
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

    /// The honest Proton Pass status: the integration route is decided (the
    /// official user-installed CLI) but gated behind the Vaultwarden
    /// foundations, so no Proton credentials are collected here.
    private var protonPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Proton Pass accounts are not available yet.")
                .font(.callout.weight(.medium))
            Text("VaultSquire integrates Proton Pass through the official Proton Pass CLI that you install yourself, rather than a reimplementation of Proton's private protocol. That integration arrives once the Vaultwarden foundations are complete. VaultSquire never asks for your Proton password; sign-in stays with the official CLI.")
                .foregroundStyle(.secondary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("add-account-proton")
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
            Text("Your account credentials are stored securely. The vault stays locked until unlock arrives in a later update.")
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
