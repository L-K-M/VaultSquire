import SwiftUI

/// The second-factor challenge screen. It shows only the providers the server
/// advertised that this release can complete, a remembered-device control, and
/// a destructive warning for recovery codes. Back returns to the form with the
/// non-secret fields preserved.
struct TwoFactorChallengeView: View {
    @ObservedObject var model: AddAccountModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Two-Factor Verification")
                .font(.title2.weight(.semibold))

            if model.hasUnsupportedOnlyChallenge {
                unsupportedView
            } else {
                challengeForm
            }
        }
        // A named container that still exposes its children individually; an
        // identifier alone collapses the subtree into one element.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("two-factor-view")
    }

    private var challengeForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.offeredProviders.count > 1 {
                Picker("Method", selection: $model.selectedProvider) {
                    ForEach(model.offeredProviders, id: \.self) { provider in
                        Text(Self.label(for: provider)).tag(Optional(provider))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("two-factor-method")
            } else if let provider = model.selectedProvider {
                Text(Self.label(for: provider))
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            if model.selectedProvider == .recoveryCode {
                Text("A recovery code can be used only once and disables two-factor authentication for this account. Use it only if you cannot use your other method.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("two-factor-recovery-warning")
            }

            SecureField(fieldPrompt, text: $model.twoFactorCode)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("two-factor-code")

            if model.selectedProvider?.requiresChallengeDispatch == true {
                Button("Send Code") {
                    Task { await model.sendEmailChallengeIfNeeded() }
                }
                .disabled(model.isSendingEmailChallenge)
                .accessibilityIdentifier("two-factor-send-email")
            }

            Toggle("Remember this device", isOn: $model.rememberDevice)
                .accessibilityIdentifier("two-factor-remember")

            if let failure = model.failureMessage {
                Text(failure)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .accessibilityIdentifier("two-factor-error")
            }

            HStack {
                Button("Back") { model.returnToForm() }
                    .accessibilityIdentifier("two-factor-back")
                Spacer()
                Button {
                    Task { await model.submitTwoFactor() }
                } label: {
                    if model.phase == .connecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Verify")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.twoFactorCode.isEmpty || model.phase == .connecting)
                .accessibilityIdentifier("two-factor-submit")
            }
        }
    }

    private var unsupportedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This account requires a two-factor method this app does not support yet.")
                .font(.callout)
            Button("Back") { model.returnToForm() }
                .accessibilityIdentifier("two-factor-back")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("two-factor-unsupported")
    }

    private var fieldPrompt: String {
        switch model.selectedProvider {
        case .email:
            return "Emailed code"
        case .recoveryCode:
            return "Recovery code"
        default:
            return "Authenticator code"
        }
    }

    private static func label(for provider: VaultwardenTwoFactorProvider) -> String {
        switch provider {
        case .authenticator:
            return "Authenticator app"
        case .email:
            return "Email"
        case .recoveryCode:
            return "Recovery code"
        default:
            return "Unsupported"
        }
    }
}
