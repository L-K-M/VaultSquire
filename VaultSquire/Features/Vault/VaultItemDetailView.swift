import AppKit
import SwiftUI

/// Renders one decrypted item. Secret fields stay concealed until revealed and
/// are never logged; a TOTP field shows the live rotating code, not the seed.
struct VaultItemDetailView: View {
    let detail: VaultItemDetail
    @State private var revealed: Set<String> = []

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
            if let url = normalizedURL(field.value) {
                Link(field.value, destination: url)
            } else {
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
                let interval = max(0, generated.periodEnd.timeIntervalSince(context.date))
                let remaining = max(0, Int(interval.rounded(.up)))
                let progress = max(0, min(1, interval / Double(generated.period)))
                HStack(spacing: 14) {
                    Text(spacedCode(generated.code))
                        .font(.title3.monospaced())
                    totpRing(remaining: remaining, progress: progress)
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

    /// A shrinking arc over the code's validity window with the seconds
    /// remaining at its centre. It turns amber inside the final five seconds,
    /// the authenticator-app convention that a code is about to roll.
    private func totpRing(remaining: Int, progress: Double) -> some View {
        let isLow = remaining <= 5
        let color = isLow ? Color.orange : Color.accentColor
        return ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.snappy(duration: 0.2), value: progress)
            Text("\(remaining)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isLow ? color : .secondary)
        }
        .frame(width: 34, height: 34)
        .accessibilityElement()
        .accessibilityLabel("\(remaining) seconds remaining")
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

    private func normalizedURL(_ raw: String) -> URL? {
        if let url = URL(string: raw), url.scheme != nil { return url }
        return URL(string: "https://\(raw)")
    }

    private func spacedCode(_ code: String) -> String {
        // Group digits for legibility: 6 -> 3+3, 7 -> 3+4, 8 -> 4+4. The TOTP
        // parser allows 6-8 digits, so the old "count == 6" guard left longer
        // codes unspaced.
        let count = code.count
        guard count >= 6 else { return code }
        let split: Int
        switch count {
        case 6, 7: split = 3
        case 8: split = 4
        default: split = count / 2
        }
        let middle = code.index(code.startIndex, offsetBy: split)
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
