import AppKit
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
    /// Whether the password is shown as text. A password that cannot be read
    /// back cannot be checked, and one that was pasted or generated is exactly
    /// the one worth checking.
    @State private var revealsPassword = false
    @State private var showsGenerator = false
    @State private var generatorOptions = PasswordGenerator.Options()
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
                    passwordRow
                    TextField("One-time code (otpauth:// or Base32)", text: $draft.totp)
                        .accessibilityIdentifier("edit-totp")
                }
                Section("Websites") {
                    boundedEditor(text: $websitesText, minHeight: 54)
                        .accessibilityIdentifier("edit-websites")
                    Text("One URL per line.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Notes") {
                    boundedEditor(text: $draft.notes, minHeight: 70)
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

    // MARK: - Password

    /// The password field, with the two things a create form has to have: a way
    /// to see what was typed, and a way to be handed something better.
    private var passwordRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if revealsPassword {
                    TextField("Password", text: $draft.password)
                        .accessibilityIdentifier("edit-password")
                } else {
                    SecureField("Password", text: $draft.password)
                        .accessibilityIdentifier("edit-password")
                }

                Button {
                    revealsPassword.toggle()
                } label: {
                    Image(systemName: revealsPassword ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealsPassword ? "Hide the password" : "Show the password")
                .accessibilityIdentifier("edit-password-reveal")

                Button {
                    showsGenerator = true
                } label: {
                    Image(systemName: "key.fill")
                }
                .buttonStyle(.borderless)
                .help("Generate a password")
                .accessibilityIdentifier("edit-password-generate")
                .popover(isPresented: $showsGenerator, arrowEdge: .bottom) {
                    generatorPopover
                }
            }

            if !draft.password.isEmpty {
                strengthMeter
            }
        }
    }

    /// Four segments and a word. It ranks length and variety, and its own
    /// documentation is honest that it cannot see a dictionary word — which is
    /// why the generator sits next to it.
    private var strengthMeter: some View {
        let strength = PasswordGenerator.strength(of: draft.password)
        return HStack(spacing: 6) {
            ForEach(PasswordGenerator.Strength.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step <= strength ? color(for: strength) : Color.secondary.opacity(0.2))
                    .frame(height: 4)
            }
            Text(strength.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Password strength: \(strength.label)")
        .accessibilityIdentifier("edit-password-strength")
    }

    private func color(for strength: PasswordGenerator.Strength) -> Color {
        switch strength {
        case .weak: return .red
        case .fair: return .orange
        case .strong: return .green
        case .excellent: return .green
        }
    }

    private var generatorPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generate a Password")
                .font(.callout.weight(.semibold))

            HStack {
                Text("Length")
                Slider(
                    value: Binding(
                        get: { Double(generatorOptions.length) },
                        set: { generatorOptions.length = Int($0) }
                    ),
                    in: Double(PasswordGenerator.Options.minimumLength)
                        ... Double(PasswordGenerator.Options.maximumLength),
                    step: 1
                )
                Text("\(generatorOptions.effectiveLength)")
                    .font(.body.monospacedDigit())
                    .frame(width: 28, alignment: .trailing)
            }

            ForEach(PasswordGenerator.CharacterClass.allCases, id: \.rawValue) { characterClass in
                Toggle(Self.label(for: characterClass), isOn: classBinding(characterClass))
            }
            Toggle("Allow lookalike characters (l, I, 1, O, 0)", isOn: $generatorOptions.allowsAmbiguous)

            HStack {
                Spacer()
                Button("Use Password") {
                    if let generated = PasswordGenerator.generate(generatorOptions) {
                        draft.password = generated
                        revealsPassword = true
                    }
                    showsGenerator = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!generatorOptions.isSatisfiable)
                .accessibilityIdentifier("edit-password-generate-confirm")
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func classBinding(_ characterClass: PasswordGenerator.CharacterClass) -> Binding<Bool> {
        Binding(
            get: { generatorOptions.classes.contains(characterClass) },
            set: { isOn in
                if isOn {
                    generatorOptions.classes.insert(characterClass)
                } else {
                    generatorOptions.classes.remove(characterClass)
                }
            }
        )
    }

    private static func label(for characterClass: PasswordGenerator.CharacterClass) -> String {
        switch characterClass {
        case .lowercase: return "Lowercase letters"
        case .uppercase: return "Uppercase letters"
        case .digits: return "Digits"
        case .symbols: return "Symbols"
        }
    }

    /// A text editor that looks like a field. Inside a grouped form a bare
    /// `TextEditor` draws no border and no background on macOS, so both of
    /// these read as stray text rather than as something to type into.
    private func boundedEditor(text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.28), lineWidth: 1)
            )
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
}
