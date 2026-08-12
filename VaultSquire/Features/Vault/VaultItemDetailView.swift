import AppKit
import SwiftUI

/// Renders one decrypted item. Secret fields stay concealed until revealed and
/// are never logged; a TOTP field shows the live rotating code, not the seed.
/// Copies of a secret go through `ClipboardService` so they expire and are
/// cleared on lock; a website leaves the app only through `URIOpeningPolicy`
/// with the effective scheme and host confirmed first.
struct VaultItemDetailView: View {
    let detail: VaultItemDetail
    /// True while the provider's CLI is being asked for this item's secret
    /// fields. Both CLI providers list without secrets, so an item can be fully
    /// drawn seconds before its password exists; without this the view would be
    /// indistinguishable from an item that simply has no password.
    var isFetchingSecrets = false

    /// How long a revealed secret stays on screen before it re-conceals. The
    /// clipboard already expires a copy after thirty seconds; a password left
    /// in plain sight until the next lock outlived it by a quarter of an hour.
    static let revealTimeout: TimeInterval = 30

    @State private var revealed: Set<String> = []
    /// The live reveal window per field, so a re-reveal cannot be cut short by
    /// the timer belonging to an earlier one.
    @State private var revealTokens: [String: UUID] = [:]
    /// The last copy made from this item, so the button can confirm it happened
    /// and — for a secret — say how long it stays on the clipboard.
    @State private var lastCopy: CopyReceipt?
    /// The URI awaiting the user's confirmation to open, shown with the
    /// effective scheme and host the system browser will actually visit.
    @State private var pendingOpen: URIOpeningDecision?
    @State private var showOpenConfirmation = false

    /// A copy that just happened: which row it came from, and when the
    /// clipboard drops it (nil for a value that carries no expiry).
    private struct CopyReceipt: Equatable {
        let fieldID: String
        let expiresAt: Date?
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if isFetchingSecrets {
                    fetchingNotice
                }
                // The divider goes above each field but the first, so the list
                // does not end on a rule hanging in the bottom padding.
                ForEach(Array(detail.fields.enumerated()), id: \.element.id) { index, field in
                    if index > 0 {
                        Divider()
                    }
                    fieldRow(field)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background { copyShortcuts }
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

    /// Says plainly that the secret fields are still on their way, rather than
    /// leaving the item looking complete without them.
    private var fetchingNotice: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Reading this item's secret fields through the provider's CLI…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("vault-item-fetching")
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

            if lastCopy?.fieldID == field.id {
                copyReceipt(lastCopy)
            }
        }
    }

    private func plainRow(_ field: VaultItemDetail.DetailField) -> some View {
        HStack(alignment: .firstTextBaseline) {
            // Notes are a plain field and run to several lines, so the value
            // wraps instead of being squeezed onto one by the trailing button.
            selectable(Text(field.value), field)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            copyButton(field, isSecret: false)
        }
    }

    private func uriRow(_ field: VaultItemDetail.DetailField) -> some View {
        HStack(alignment: .firstTextBaseline) {
            selectable(Text(field.value), field)
                .fixedSize(horizontal: false, vertical: true)
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
            Spacer(minLength: 12)
            copyButton(field, isSecret: false)
        }
    }

    private func secretRow(_ field: VaultItemDetail.DetailField) -> some View {
        HStack {
            selectable(
                Text(revealed.contains(field.id) ? field.value : "••••••••••")
                    .font(.body.monospaced()),
                field
            )
            Spacer(minLength: 12)
            Button {
                toggleReveal(field.id)
            } label: {
                Image(systemName: revealed.contains(field.id) ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(revealed.contains(field.id)
                ? "Hide"
                : "Reveal for \(Int(Self.revealTimeout)) seconds")
            .accessibilityIdentifier("reveal-\(field.label)")
            copyButton(field, isSecret: true)
        }
    }

    private func totpRow(_ field: VaultItemDetail.DetailField) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let generated = VaultwardenTOTP.generate(seed: field.value, at: context.date) {
                let remaining = max(
                    0, Int(generated.periodEnd.timeIntervalSince(context.date).rounded(.up))
                )
                HStack(spacing: 12) {
                    Text(spacedCode(generated.code))
                        .font(.title3.monospaced())
                    countdownRing(
                        remaining: remaining,
                        period: max(1, generated.period)
                    )
                    Text("\(remaining)s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(remaining <= 5 ? Color.orange : Color.secondary)
                    Spacer(minLength: 12)
                    copyButton(field, value: generated.code, isSecret: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("One-time code, \(remaining) seconds remaining")
            } else {
                Text("Unreadable one-time code seed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The window the current code is still good for. A ring drains where a
    /// bare number only counted, and it turns amber in the last five seconds —
    /// which is exactly when it matters whether to use this code or wait.
    private func countdownRing(remaining: Int, period: Int) -> some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.22), lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(1, max(0, Double(remaining) / Double(period))))
                .stroke(
                    remaining <= 5 ? Color.orange : Color.accentColor,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 15, height: 15)
        .accessibilityHidden(true)
    }

    /// The copy button for a field, optionally copying a derived value (the
    /// generated one-time code rather than its seed, which must never reach the
    /// clipboard).
    private func copyButton(
        _ field: VaultItemDetail.DetailField,
        value: String? = nil,
        isSecret: Bool
    ) -> some View {
        let confirmed = lastCopy?.fieldID == field.id
        return Button {
            copy(value ?? field.value, from: field, isSecret: isSecret)
        } label: {
            Image(systemName: confirmed ? "checkmark" : "doc.on.doc")
                .foregroundStyle(confirmed ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help("Copy \(field.label)")
        .accessibilityLabel("Copy \(field.label)")
    }

    /// Confirms the copy and, for a secret, counts down the clipboard's own
    /// expiry. The expiry is one of the app's real protections and was
    /// previously invisible — nothing on screen said a copy would vanish, so
    /// nobody could rely on it or be surprised by it.
    @ViewBuilder
    private func copyReceipt(_ receipt: CopyReceipt?) -> some View {
        if let expiresAt = receipt?.expiresAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(expiresAt.timeIntervalSince(context.date).rounded(.up)))
                Label(
                    remaining > 0
                        ? "Copied — the clipboard clears in \(remaining)s"
                        : "Copied — the clipboard has been cleared",
                    systemImage: "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } else if receipt != nil {
            Label("Copied", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func copy(_ value: String, from field: VaultItemDetail.DetailField, isSecret: Bool) {
        if isSecret {
            ClipboardService.shared.copySecret(value)
            lastCopy = CopyReceipt(
                fieldID: field.id,
                expiresAt: Date().addingTimeInterval(ClipboardService.defaultSecretExpiry)
            )
        } else {
            ClipboardService.shared.copyPlain(value)
            lastCopy = CopyReceipt(fieldID: field.id, expiresAt: nil)
        }
        let receipt = lastCopy
        Task { @MainActor in
            // A non-secret confirmation is a flash; a secret's stays as long as
            // the value it is counting down.
            let seconds = receipt?.expiresAt == nil ? 2.0 : ClipboardService.defaultSecretExpiry + 1
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1_000)))
            if lastCopy == receipt {
                lastCopy = nil
            }
        }
    }

    /// Enables text selection only where the domain model permits it.
    ///
    /// A secret must not be selectable. A selection can be copied with the
    /// system's own ⌘C, which goes straight to `NSPasteboard` and bypasses
    /// `ClipboardService` — and with it the thirty-second expiry, the clear on
    /// lock, and the concealed/transient hints that are the only reason a
    /// copied password is safer here than anywhere else.
    @ViewBuilder
    private func selectable(_ text: Text, _ field: VaultItemDetail.DetailField) -> some View {
        if field.allowsTextSelection {
            text.textSelection(.enabled)
        } else {
            text
        }
    }

    private func toggleReveal(_ id: String) {
        if revealed.contains(id) {
            revealed.remove(id)
            return
        }
        revealed.insert(id)
        // Each reveal carries its own token. Hiding and revealing the same
        // field again starts a fresh window instead of inheriting the first
        // one's deadline, which would re-conceal the second reveal early.
        let token = UUID()
        revealTokens[id] = token
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.revealTimeout))
            guard revealTokens[id] == token else { return }
            revealTokens[id] = nil
            revealed.remove(id)
        }
    }

    /// Shortcuts for the two copies that make up nearly every use of this app.
    /// Deliberately not plain ⌘C, which belongs to the text selection the
    /// non-secret rows enable — and which, for a secret, would bypass the
    /// clipboard expiry entirely, which is why secrets are not selectable.
    @ViewBuilder
    private var copyShortcuts: some View {
        Group {
            if let username = firstField(labelled: "Username") {
                Button("Copy Username") { copy(username.value, from: username, isSecret: false) }
                    .keyboardShortcut("c", modifiers: [.command, .option])
            }
            if let password = detail.fields.first(where: { $0.kind == .secret }) {
                Button("Copy Password") { copy(password.value, from: password, isSecret: true) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func firstField(labelled label: String) -> VaultItemDetail.DetailField? {
        detail.fields.first { $0.label == label && $0.kind == .plain }
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
