import AppKit
import SwiftUI

enum VaultURLPolicy {
    static func safeURL(_ raw: String) -> URL? {
        guard raw.utf8.count <= 2_048,
              raw.unicodeScalars.allSatisfy(Self.isSafeScalar) else {
            return nil
        }
        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              let url = components.url else {
            return nil
        }
        return url
    }

    static func destinationLabel(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? "https"
        let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .percentEncodedHost ?? url.host ?? "website"
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    private static func isSafeScalar(_ scalar: UnicodeScalar) -> Bool {
        guard !CharacterSet.controlCharacters.contains(scalar),
              !CharacterSet.illegalCharacters.contains(scalar) else {
            return false
        }
        // Bidirectional and isolate controls can visually reverse or hide the
        // effective host in a security confirmation without changing the URL.
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return false
        default:
            return true
        }
    }
}

/// Renders one decrypted item. Secret fields stay concealed until revealed and
/// are never logged; a TOTP field shows the live rotating code, not the seed.
struct VaultItemDetailView: View {
    let detail: VaultItemDetail
    @State private var revealed: Set<String> = []
    @State private var pendingURL: URL?

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
        .confirmationDialog(
            "Open website?",
            isPresented: Binding(
                get: { pendingURL != nil },
                set: { if !$0 { pendingURL = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingURL {
                Button("Open \(VaultURLPolicy.destinationLabel(pendingURL))") {
                    let url = pendingURL
                    self.pendingURL = nil
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { pendingURL = nil }
        } message: {
            if let pendingURL {
                Text(pendingURL.scheme?.lowercased() == "http"
                    ? "This address uses unencrypted HTTP. Confirm the effective scheme and host before leaving VaultSquire."
                    : "Confirm the effective scheme and host before leaving VaultSquire.")
            }
        }
        .accessibilityIdentifier("vault-item-detail")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ItemIconView(identity: iconIdentity, category: detail.category, size: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(detail.title)
                    .font(.largeTitle.weight(.semibold))
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
            Spacer()
            copyButton(field.value, concealed: false)
        }
    }

    private func uriRow(_ field: VaultItemDetail.DetailField) -> some View {
        HStack {
            Text(field.value)
            Spacer()
            if let url = VaultURLPolicy.safeURL(field.value) {
                Button {
                    pendingURL = url
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Open after confirming the destination")
                .accessibilityLabel("Open website")
            }
            copyButton(field.value, concealed: false)
        }
    }

    private func secretRow(_ field: VaultItemDetail.DetailField) -> some View {
        HStack {
            Text(revealed.contains(field.id) ? field.value : "••••••••••")
                .font(.body.monospaced())
            Spacer()
            Button {
                toggleReveal(field.id)
            } label: {
                Image(systemName: revealed.contains(field.id) ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(revealed.contains(field.id) ? "Hide" : "Reveal")
            .accessibilityIdentifier("reveal-\(field.label)")
            copyButton(field.value, concealed: true)
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
                    copyButton(generated.code, concealed: true)
                }
            } else {
                Text("Unreadable one-time code seed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func copyButton(_ value: String, concealed: Bool) -> some View {
        Button {
            ApplicationCoordinator.shared.copyVaultValue(value, concealed: concealed)
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
