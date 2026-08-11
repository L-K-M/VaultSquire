import SwiftUI

/// A create/edit sheet for a login item. It edits a plaintext draft held only
/// while the sheet is open; the provider encrypts every field before it leaves
/// the device. Presented over the vault window as a sheet.
struct VaultItemEditView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var draft: VaultItemDraft
    @State private var websitesText: String
    /// Which vault a new item is created in. Nil until the sheet appears, then
    /// defaulted to the browser's target. An edit never uses it: the item
    /// belongs to the vault it came from.
    @State private var destination: AccountID?
    /// Whether the password field shows its plaintext instead of bullets, so a
    /// generated or typed password can be verified before saving.
    @State private var passwordRevealed = false
    /// Whether the generator options popover is presented.
    @State private var showPasswordOptions = false
    /// The generator options, remembered for the life of the sheet so a second
    /// "Generate" keeps the user's choices.
    @State private var passwordOptions = PasswordGenerator.Options()
    let onClose: () -> Void

    init(draft: VaultItemDraft, onClose: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        _websitesText = State(initialValue: draft.websites.joined(separator: "\n"))
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.isEditing ? "Edit Login" : "New Login")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 24)
                .padding(.top, 22)

            Form {
                Section {
                    TextField("Name", text: $draft.title)
                        .accessibilityIdentifier("edit-title")
                    Toggle("Favorite", isOn: $draft.favorite)
                    destinationRow
                }
                Section("Login") {
                    TextField("Username", text: $draft.username)
                        .accessibilityIdentifier("edit-username")
                    HStack(spacing: 8) {
                        Group {
                            if passwordRevealed {
                                TextField("Password", text: $draft.password)
                            } else {
                                SecureField("Password", text: $draft.password)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("edit-password")

                        Button {
                            passwordRevealed.toggle()
                        } label: {
                            Image(systemName: passwordRevealed ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(passwordRevealed ? "Hide password" : "Show password")
                        .accessibilityLabel(passwordRevealed ? "Hide password" : "Show password")

                        Button {
                            regeneratePassword()
                        } label: {
                            Image(systemName: "dice")
                        }
                        .buttonStyle(.borderless)
                        .help("Generate a password")
                        .accessibilityIdentifier("edit-generate-password")
                        .popover(isPresented: $showPasswordOptions) {
                            passwordOptionsPopover
                        }
                    }
                    TextField("One-time code (otpauth:// or Base32)", text: $draft.totp)
                        .accessibilityIdentifier("edit-totp")
                }
                Section("Websites") {
                    TextEditor(text: $websitesText)
                        .frame(minHeight: 54)
                        .font(.body)
                        .accessibilityIdentifier("edit-websites")
                    Text("One URL per line.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Notes") {
                    TextEditor(text: $draft.notes)
                        .frame(minHeight: 70)
                        .accessibilityIdentifier("edit-notes")
                }
            }
            .formStyle(.grouped)

            if let error = appModel.writeError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .accessibilityIdentifier("edit-error")
            }

            HStack {
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    submit()
                } label: {
                    if appModel.isWriting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(draft.isEditing ? "Save" : "Create")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canSubmit || appModel.isWriting)
                .accessibilityIdentifier("edit-save")
            }
            .padding(24)
        }
        .frame(width: 460, height: 560)
        // When a save succeeds the model re-syncs and clears writeError; close
        // the sheet once a submit completes without error.
        .onChange(of: appModel.isWriting) { wasWriting, isWriting in
            if wasWriting && !isWriting && appModel.writeError == nil {
                onClose()
            }
        }
        .accessibilityIdentifier("vault-item-edit")
        .onAppear {
            if destination == nil {
                destination = appModel.createTarget?.account
                    ?? appModel.writableVaults.first?.account
            }
        }
    }

    /// Where a new item lands. Shown whenever creating, even with one writable
    /// vault, so the destination is never a guess the user has to infer. An
    /// edit shows the owning vault as a fact instead: an item cannot be moved
    /// between vaults here.
    @ViewBuilder
    private var destinationRow: some View {
        if draft.isEditing {
            if let vault = draft.itemID.flatMap({ appModel.session(for: $0.account) }) {
                LabeledContent("Vault", value: vault.title)
            }
        } else if appModel.writableVaults.count > 1 {
            Picker("Vault", selection: $destination) {
                ForEach(appModel.writableVaults) { vault in
                    Text(vault.title).tag(Optional(vault.account))
                }
            }
            .accessibilityIdentifier("edit-destination")
        } else if let only = appModel.writableVaults.first {
            LabeledContent("Vault", value: only.title)
        }
    }

    private func submit() {
        draft.websites = websitesText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        appModel.save(draft, to: destination)
    }

    // MARK: - Password generation

    /// Replaces the draft password with a freshly generated one. Called from
    /// the dice button and from every option change, so the field always shows
    /// a password that matches the current options.
    private func regeneratePassword() {
        let generated = PasswordGenerator.generate(options: passwordOptions)
        if !generated.isEmpty {
            draft.password = generated
        }
    }

    /// The options popover. Every change regenerates immediately, so the field
    /// behind the popover always matches what the controls say. The last
    /// enabled character set cannot be switched off, so the password never
    /// silently falls back to a policy the controls do not describe.
    private var passwordOptionsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Password Options")
                .font(.headline)
            Stepper(
                "Length: \(passwordOptions.length)",
                value: $passwordOptions.length,
                in: PasswordGenerator.Options.lengthRange
            )
            Toggle("Uppercase (A–Z)", isOn: setBinding(\.includeUppercase))
            Toggle("Lowercase (a–z)", isOn: setBinding(\.includeLowercase))
            Toggle("Digits (0–9)", isOn: setBinding(\.includeDigits))
            Toggle("Symbols (!@#$…)", isOn: setBinding(\.includeSymbols))
            Toggle("Avoid ambiguous (0 O 1 l I)", isOn: $passwordOptions.excludeAmbiguous)
            Text("The password field updates as you change these.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { regeneratePassword() }
        .onChange(of: passwordOptions) { _, _ in regeneratePassword() }
    }

    /// A character-set toggle that refuses to turn off the last enabled set.
    private func setBinding(_ keyPath: WritableKeyPath<PasswordGenerator.Options, Bool>) -> Binding<Bool> {
        Binding(
            get: { passwordOptions[keyPath: keyPath] },
            set: { newValue in
                var updated = passwordOptions
                updated[keyPath: keyPath] = newValue
                guard updated.hasAnyCharacterSetEnabled else { return }
                passwordOptions = updated
            }
        )
    }
}
