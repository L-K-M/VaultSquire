import AppKit
import SwiftUI

/// Renders one decrypted item. Secret fields stay concealed until revealed and
/// are never logged; a TOTP field shows the live rotating code, not the seed.
/// Copies of a secret go through `ClipboardService` so they expire and are
/// cleared on lock; a website leaves the app only through `URIOpeningPolicy`
/// with the effective scheme and host confirmed first.
struct VaultItemDetailView: View {
    let detail: VaultItemDetail
    @State private var revealed: Set<String> = []
    /// The URI awaiting the user's confirmation to open, shown with the
    /// effective scheme and host the system browser will actually visit.
    @State private var pendingOpen: URIOpeningDecision?
    @State private var showOpenConfirmation = false
    /// Which field's copy button is showing its transient "Copied" state.
    @State private var copiedFieldID: String?
    /// Cancels the pending "Copied" reset when another copy happens first.
    @State private var copyResetTask: Task<Void, Never>?

    /// How long a copy confirmation stays visible. Long enough to be noticed
    /// while typing, short enough not to linger on screen.
    private static let copyConfirmationDurationMS = 1_600

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                ForEach(detail.fields) { field in
                    fieldRow(field)
                    Divider()
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("vault-item-detail")
        .confirmationDialog(
            "Open this link?",
            isPresented: $showOpenConfirmation,
            titleVisibility: .visible
        ) {
            if let decision = pendingOpen {
                Button("Open \(decision.display)") {
                    NSWorkspace.shared.open(decision.url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let decision = pendingOpen {
                Text("VaultSquire will hand \(decision.display) to your default browser. Nothing from this vault is sent with it.")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ItemIconView(identity: iconIdentity, category: detail.category, size: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(detail.title)
                    .font(.largeTitle.weight(.semibold))
                    .textSelection(.enabled)
                Text(categoryLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The detail carries its websites as `.uri` fields rather than a list, so
    /// the identity is built from those — the same host the row upstream
    /// resolved, and therefore the same icon and colour.
    private var iconIdentity: ItemIconIdentity {
        ItemIconIdentity(
            title: detail.title,
            websites: detail.fields.filter { $0.kind == .uri }.map(\.value)
        )
    }

    @ViewBuilder
    private func fieldRow(_ field: VaultItemDetail.DetailField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            switch field.kind {
            case .totpSeed:
                totpRow(field)
            case .secret:
                secretRow(field)
            case .uri:
                uriRow(field)
            case .plain:
                plainRow(field)
            }
        }
    }

    private func plainRow(_ field: VaultItemDetail.DetailField) -> some View {
        HStack {
            Text(field.value)
                .textSelection(.enabled)
            Spacer()
            copyButton(field.value, isSecret: false, confirmationID: field.id)
        }
    }

    private func uriRow(_ field: VaultItemDetail.DetailField) -> some View {
        HStack {
            Text(field.value).textSelection(.enabled)
            if let decision = URIOpeningPolicy.decision(for: field.value) {
                Button {
                    pendingOpen = decision
                    showOpenConfirmation = true
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .help("Open \(decision.display)")
                .accessibilityIdentifier("open-uri-\(field.label)")
            }
            Spacer()
            copyButton(field.value, isSecret: false, confirmationID: field.id)
        }
    }

    private func secretRow(_ field: VaultItemDetail.DetailField) -> some View {
        HStack {
            Text(revealed.contains(field.id) ? field.value : "••••••••••")
                .font(.body.monospaced())
                .textSelection(.enabled)
            Spacer()
            Button {
                toggleReveal(field.id)
            } label: {
                Image(systemName: revealed.contains(field.id) ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(revealed.contains(field.id) ? "Hide" : "Reveal")
            .accessibilityIdentifier("reveal-\(field.label)")
            copyButton(field.value, isSecret: true, confirmationID: field.id)
        }
    }

    private func totpRow(_ field: VaultItemDetail.DetailField) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let generated = VaultwardenTOTP.generate(seed: field.value, at: context.date) {
                HStack(spacing: 12) {
                    Text(spacedCode(generated.code))
                        .font(.title3.monospaced())
                    let remaining = max(0, Int(generated.periodEnd.timeIntervalSince(context.date).rounded(.up)))
                    Text("\(remaining)s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    copyButton(generated.code, isSecret: true, confirmationID: field.id)
                }
            } else {
                Text("Unreadable one-time code seed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Copies a value and confirms it on the button itself: the icon becomes a
    /// green checkmark with a "Copied" label for a moment. The confirmation
    /// never echoes the value — a secret and a plain field look identical while
    /// copying — and the secret's expiry is the clipboard's own 30-second
    /// countdown, which this visual state only announces.
    private func copyButton(_ value: String, isSecret: Bool, confirmationID: String) -> some View {
        Button {
            if isSecret {
                ClipboardService.shared.copySecret(value)
            } else {
                ClipboardService.shared.copyPlain(value)
            }
            copiedFieldID = confirmationID
            copyResetTask?.cancel()
            copyResetTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Self.copyConfirmationDurationMS))
                if !Task.isCancelled {
                    copiedFieldID = nil
                }
            }
        } label: {
            if copiedFieldID == confirmationID {
                Label("Copied", systemImage: "checkmark")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "doc.on.doc")
            }
        }
        .buttonStyle(.borderless)
        .help(copiedFieldID == confirmationID ? "Copied" : "Copy")
        .animation(.snappy(duration: 0.15), value: copiedFieldID)
    }

    private func toggleReveal(_ id: String) {
        if revealed.contains(id) {
            revealed.remove(id)
        } else {
            revealed.insert(id)
        }
    }

    private func spacedCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let middle = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex..<middle]) \(code[middle...])"
    }

    private var categoryLabel: String {
        switch detail.category {
        case .login: return "Login"
        case .secureNote: return "Secure note"
        case .card: return "Card"
        case .identity: return "Identity"
        case .unsupported: return "Item"
        }
    }
}
