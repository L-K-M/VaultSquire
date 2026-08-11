import AppKit
import SwiftUI

/// Renders one decrypted item. Secret fields stay concealed until revealed and
/// are never logged; a TOTP field shows the live rotating code, not the seed.
struct VaultItemDetailView: View {
    let detail: VaultItemDetail
    @State private var revealed: Set<String> = []
    /// The http(s) destination awaiting the user's confirmation before it is
    /// handed to the system URL opener. A vault record never opens a link on
    /// its own.
    @State private var pendingURI: URL?

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
            isPresented: uriConfirmationBinding,
            presenting: pendingURI
        ) { url in
            Button("Open \(Self.linkLabel(for: url))") {
                NSWorkspace.shared.open(url)
                pendingURI = nil
            }
            Button("Cancel", role: .cancel) {
                pendingURI = nil
            }
        } message: { url in
            Text("VaultSquire will open \(url.absoluteString) in your default browser.")
        }
    }

    private var uriConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingURI != nil },
            set: { if !$0 { pendingURI = nil } }
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
            if let url = Self.safeLinkURL(from: field.value) {
                Button {
                    pendingURI = url
                } label: {
                    Text(field.value)
                        .foregroundStyle(.tint)
                        .underline()
                }
                .buttonStyle(.plain)
                .help("Open in browser")
            } else {
                Text(field.value).textSelection(.enabled)
            }
            Spacer()
            copyButton(field.value)
        }
    }

    private func secretRow(_ field: VaultItemDetail.DetailField) -> some View {
        if !detail.canRevealSecrets {
            // Hide-passwords policy: the value is not offered for reveal or
            // copy even though the ciphertext decrypts locally.
            return AnyView(
                HStack {
                    Text("Hidden by your organization's policy")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            )
        }
        return AnyView(
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
                copyButton(field.value, expires: true)
            }
        )
    }

    private func totpRow(_ field: VaultItemDetail.DetailField) -> some View {
        if !detail.canRevealSecrets {
            return AnyView(
                HStack {
                    Text("Hidden by your organization's policy")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            )
        }
        return AnyView(
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
                        copyButton(generated.code, expires: true)
                    }
                } else {
                    Text("Unreadable one-time code seed")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        )
    }

    private func copyButton(_ value: String, expires: Bool = false) -> some View {
        Button {
            copyToPasteboard(value, expires: expires)
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

    private func copyToPasteboard(_ value: String, expires: Bool) {
        // A copied secret expires after a short lifetime and is cleared on
        // lock and termination; the change count guard ensures a later user
        // copy is never erased.
        ClipboardValueController.shared.copy(value, expires: expires)
    }

    /// The only destinations VaultSquire ever hands to the system URL opener:
    /// absolute `http`/`https` URLs with a host and no embedded credentials.
    /// `file:`, `javascript:`, `data:`, privileged system schemes, and arbitrary
    /// custom schemes are refused and rendered as plain selectable text. A bare
    /// domain ("github.com") is completed to https. The effective host and
    /// scheme are shown to the user in the confirmation dialog before anything
    /// opens.
    static func safeLinkURL(from raw: String) -> URL? {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }
        if !candidate.contains("://") {
            candidate = "https://\(candidate)"
        }
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              // `.url` applies RFC 3986 validation, so an authority like
              // "javascript:alert(1)" (a non-numeric port) fails here even
              // though URLComponents parsed it leniently.
              let url = components.url else {
            return nil
        }
        // Defense in depth: a host that is not a plausible reg-name or IPv6
        // literal is refused, so nothing odd can be handed to the system
        // opener.
        let allowedHostCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._:"
        )
        guard host.unicodeScalars.allSatisfy({ allowedHostCharacters.contains($0) }) else {
            return nil
        }
        return url
    }

    /// The confirmation button's label: the effective host with its port, so
    /// the user sees where the link goes without leaving the app.
    static func linkLabel(for url: URL) -> String {
        var label = url.host ?? url.absoluteString
        if let port = url.port {
            label += ":\(port)"
        }
        return label
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
