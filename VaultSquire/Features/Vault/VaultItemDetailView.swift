import AppKit
import SwiftUI

/// Renders one decrypted item. Secret fields stay concealed until revealed and
/// are never logged; a TOTP field shows the live rotating code, not the seed.
struct VaultItemDetailView: View {
    let detail: VaultItemDetail
    @State private var revealed: Set<String> = []
    /// A website the user asked to open, awaiting their confirmation. The
    /// effective scheme and host are shown before VaultSquire hands off, per
    /// SECURITY_AND_TESTING.md § "URI Opening".
    @State private var pendingOpenDestination: SafeURI.Destination?

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
            "Open this website?",
            isPresented: openConfirmation,
            presenting: pendingOpenDestination
        ) { destination in
            Button("Open \(destination.displayOrigin)") {
                NSWorkspace.shared.open(destination.url)
            }
            Button("Cancel", role: .cancel) {}
        } message: { destination in
            Text("VaultSquire will leave the app and open \(destination.displayOrigin) in your default browser. Only open sites you recognize.")
        }
    }

    /// True while a website open is awaiting confirmation.
    private var openConfirmation: Binding<Bool> {
        Binding(
            get: { pendingOpenDestination != nil },
            set: { newValue in if !newValue { pendingOpenDestination = nil } }
        )
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
            copyButton(field.value)
        }
    }

    private func uriRow(_ field: VaultItemDetail.DetailField) -> some View {
        HStack {
            if let destination = SafeURI.destination(for: field.value) {
                Button {
                    pendingOpenDestination = destination
                } label: {
                    Text(field.value).underline()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("open-uri-\(field.label)")
            } else {
                // Not an openable http(s) destination: a custom/file/javascript/
                // data scheme, a URL carrying credentials, or unparseable input.
                // Render as inert text so it can never leave the app from here.
                Text(field.value).textSelection(.enabled)
            }
            Spacer()
            copyButton(field.value)
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
            copyButton(field.value)
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
                    copyButton(generated.code)
                }
            } else {
                Text("Unreadable one-time code seed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func copyButton(_ value: String) -> some View {
        Button {
            copyToPasteboard(value)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy")
    }

    private func toggleReveal(_ id: String) {
        if revealed.contains(id) {
            revealed.remove(id)
        } else {
            revealed.insert(id)
        }
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
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
