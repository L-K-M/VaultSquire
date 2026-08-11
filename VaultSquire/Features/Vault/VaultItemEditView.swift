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
                    SecureField("Password", text: $draft.password)
                        .accessibilityIdentifier("edit-password")
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
            // A failure from an earlier write must not greet a fresh sheet.
            appModel.noteEditorPresented()
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
}
