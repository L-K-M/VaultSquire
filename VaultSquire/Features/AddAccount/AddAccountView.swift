import SwiftUI

/// The add-account sheet: a single sign-in form that, on a second-factor
/// challenge, swaps to the two-factor screen and back. Presented as a sheet so
/// the app keeps its single main window.
struct AddAccountView: View {
    @ObservedObject var model: AddAccountModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.phase {
            case .challenged:
                TwoFactorChallengeView(model: model)
            case .succeeded:
                successView
            default:
                signInForm
            }
        }
        .padding(24)
        .frame(width: 420)
        .accessibilityIdentifier("add-account-view")
    }

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Vaultwarden Account")
                .font(.title2.weight(.semibold))
            Text("Sign in to an existing account on your server.")
                .foregroundStyle(.secondary)
                .font(.callout)

            VStack(alignment: .leading, spacing: 8) {
                labeledField("Server URL") {
                    TextField("https://vault.example.com", text: $model.serverURL)
                        .textContentType(.URL)
                        .disableAutocorrection(true)
                        .accessibilityIdentifier("add-account-url")
                }
                labeledField("Email") {
                    TextField("you@example.com", text: $model.email)
                        .textContentType(.username)
                        .disableAutocorrection(true)
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
                    Task { await model.signIn() }
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
