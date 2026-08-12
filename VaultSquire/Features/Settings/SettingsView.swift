import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var siteIcons: SiteIconStore

    /// The configured idle timeout, read once when Settings opens and written
    /// straight through to the controller. `AutoLockController` is not
    /// observable and nothing else changes this while the window is up.
    @State private var autoLockMinutes = AutoLockController.shared.inactivityMinutes

    /// The Quick Search chord. Observed, not read once like `autoLockMinutes`:
    /// the recorder writes it while this window is open and the row has to
    /// redraw.
    @StateObject private var shortcuts = QuickSearchShortcutStore.shared
    @StateObject private var recorder = ShortcutRecorder()

    /// How wide a paragraph is allowed to want to be.
    ///
    /// `fixedSize(horizontal: false, vertical: true)` fixes only the vertical
    /// axis: horizontally the text stays flexible, so when SwiftUI asks for an
    /// ideal size with no width proposed, a `Text` answers with its whole
    /// sentence on one line. That ideal climbs the tree, and a `Settings` scene
    /// sizes its window from it — which is how a window wider than the display,
    /// with its labels off the left edge, comes from a paragraph.
    ///
    /// A maximum rather than a fixed width: a fixed one would refuse to shrink
    /// when the window is narrowed, which is the same failure pointed the other
    /// way.
    private static let proseWidth: CGFloat = 420

    var body: some View {
        TabView {
            Form {
                quickSearchShortcutRow
                LabeledContent("Vault state", value: vaultStateDescription)

                Divider()

                autoLockSection

                Divider()

                biometricSection
            }
            .padding(24)
            // A Form is not vertically greedy, so a short one is centred in the
            // tab's rect with a band of empty space above it.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No telemetry", systemImage: "hand.raised")
                        .font(.headline)
                    Text("VaultSquire records only fixed, allowlisted lifecycle and performance events. Account and item values are never diagnostic metadata.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: Self.proseWidth, alignment: .leading)

                Divider()

                siteIconSection
                Spacer()
            }
            .padding(28)
            .tabItem {
                Label("Privacy", systemImage: "lock")
            }

#if SANDBOX_PROCESS_PROBE
            SandboxProcessProbeView()
                .tabItem {
                    Label("Sandbox Probe", systemImage: "terminal")
                }
#endif
        }
        // A minimum rather than a fixed size: these tabs are mostly prose, and
        // at any increased text size a pinned height clips the last paragraph.
        .frame(minWidth: 560, minHeight: 400)
        // The recorder's monitor is app-wide while armed, so closing Settings
        // mid-recording must disarm it.
        .onDisappear { recorder.stop() }
        .accessibilityIdentifier("settings-view")
    }

    /// The Quick Search chord.
    ///
    /// Registered system-wide, so it opens Quick Search from whatever the user
    /// is working in. That is what a launcher is for, and it is what makes the
    /// copy actions useful: the panel hands focus back to the app it was
    /// summoned from, which had nothing to hand back to while the chord was a
    /// menu key equivalent.
    @ViewBuilder
    private var quickSearchShortcutRow: some View {
        LabeledContent("Quick Search") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button(recorder.isRecording
                        ? "Press a shortcut…"
                        : shortcuts.shortcut.displayName
                    ) {
                        if recorder.isRecording {
                            recorder.stop()
                        } else {
                            recorder.start { shortcuts.set($0) }
                        }
                    }
                    .accessibilityIdentifier("settings-quick-search-shortcut")

                    if shortcuts.shortcut != .default {
                        Button("Reset") {
                            recorder.stop()
                            shortcuts.resetToDefault()
                        }
                        .accessibilityIdentifier("settings-quick-search-shortcut-reset")
                    }
                }

                Group {
                    if recorder.isRecording {
                        Text("Press the keys you want, with at least one of Command, Control or Option. Escape leaves it as it is.")
                            .foregroundStyle(.secondary)
                    } else if let refusal = recorder.refusal {
                        Text(refusal)
                            .foregroundStyle(.red)
                    } else if shortcuts.isUnavailable {
                        Text("Another app is using \(shortcuts.shortcut.displayName), so VaultSquire could not claim it. Pick a different one.")
                            .foregroundStyle(.red)
                    } else if shortcuts.storedValueWasRejected {
                        Text("The saved shortcut wasn't usable, so VaultSquire is using \(QuickSearchShortcut.default.displayName).")
                            .foregroundStyle(.red)
                    } else {
                        Text("Opens Quick Search from any app. VaultSquire asks the system for this one chord and is told nothing else you type — no Accessibility permission is involved.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Self.proseWidth, alignment: .leading)
            }
        }
    }

    /// The idle timeout, which until now could only be set with `defaults
    /// write` — while Settings said a lock policy was not enabled yet and the
    /// app was in fact locking itself after fifteen minutes.
    ///
    /// The system triggers are listed but not offered as choices: locking on
    /// screen lock, screensaver, sleep, and session resignation is what makes
    /// an unattended Mac safe, and it is not a preference.
    @ViewBuilder
    private var autoLockSection: some View {
        LabeledContent("Lock after") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Lock after", selection: $autoLockMinutes) {
                    ForEach(offeredTimeouts, id: \.self) { minutes in
                        Text(Self.timeoutLabel(minutes)).tag(minutes)
                    }
                }
                // The Form owns the label column; the Picker drawing its own
                // would put "Lock after" twice on one row.
                .labelsHidden()
                .accessibilityIdentifier("settings-auto-lock")
                .onChange(of: autoLockMinutes) { _, minutes in
                    AutoLockController.shared.setInactivityMinutes(minutes)
                }

                Group {
                    Text(autoLockMinutes > 0
                        ? "VaultSquire locks every open vault after \(Self.timeoutLabel(autoLockMinutes).lowercased()) without keyboard or pointer activity."
                        : "The idle timer is off, so VaultSquire keeps your vaults open until something below closes them.")

                    Text("Vaults always lock when the screen locks, the screensaver starts, this Mac sleeps, or you switch users — and with Command-Shift-L. Locking drops every decrypted value, cancels work in flight, and clears a secret VaultSquire put on the clipboard.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Self.proseWidth, alignment: .leading)
            }
        }
    }

    /// The offered choices, plus whatever is actually configured if that is not
    /// one of them. A timeout set out of band with `defaults write` would
    /// otherwise match no tag, and a Picker with no matching tag shows a blank
    /// or the wrong row — telling the user their vault locks on a schedule it
    /// does not. The stored value is shown rather than normalised away, because
    /// silently rewriting someone's tighter timeout to a listed one would
    /// loosen their security to make a menu tidy.
    private var offeredTimeouts: [Int] {
        let offered = AutoLockController.offeredInactivityMinutes
        return offered.contains(autoLockMinutes) ? offered : [autoLockMinutes] + offered
    }

    private static func timeoutLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "Never"
        case 1: return "1 minute"
        case 60: return "1 hour"
        default: return "\(minutes) minutes"
        }
    }

    /// How many vaults are open, which is the honest answer now that several
    /// can be. The old wording reported "Unavailable" for an open vault.
    private var vaultStateDescription: String {
        if appModel.hasNoAccounts { return "No accounts" }
        let open = appModel.sessions.filter(\.isOpen).count
        guard open > 0 else { return "Locked" }
        return open == 1 ? "1 vault open" : "\(open) vaults open"
    }

    /// Site-icon opt-in. Off by default, and the wording says plainly what
    /// turning it on costs rather than describing it as a display preference:
    /// it is the one setting that sends anything derived from vault content to
    /// a host that is not the user's own server.
    @ViewBuilder
    private var siteIconSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Show site icons", isOn: $siteIcons.isEnabled)
                .accessibilityIdentifier("settings-site-icons")
            Text("Fetches each login's icon from that site itself. The site learns that this Mac holds an entry for it, so this is off until you ask for it. VaultSquire never uses an icon service, which would receive your whole list of sites instead, and no icon is written to disk.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("With this off, each login still gets a letter on a colour derived from its address — no network, and the same colour every time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: Self.proseWidth, alignment: .leading)
    }

    /// Touch ID opt-in. Enrolling needs the vault open, because the key it
    /// stores exists only while the vault is unlocked.
    @ViewBuilder
    private var biometricSection: some View {
        LabeledContent("Touch ID") {
            VStack(alignment: .leading, spacing: 6) {
                if appModel.canUnlockWithBiometrics {
                    Button("Turn Off Touch ID Unlock") {
                        appModel.disableBiometricUnlock()
                    }
                    .accessibilityIdentifier("settings-biometrics-disable")
                    caption("VaultSquire opens with your fingerprint. Your vault key is stored on this Mac, protected by the current set of enrolled fingerprints, and is discarded if they change.")
                } else if appModel.canEnrollBiometrics {
                    Button("Unlock With Touch ID Next Time") {
                        appModel.enableBiometricUnlock()
                    }
                    .accessibilityIdentifier("settings-biometrics-enable")
                    caption("Stores this vault's key on this Mac behind Touch ID so you don't retype your master password. Your master password itself is never stored, and the stored key cannot sign in to your server.")
                } else {
                    caption(appModel.isUnlocked
                        ? "Touch ID isn't available on this Mac."
                        : "Unlock your vault to set up Touch ID.")
                }

                if let error = appModel.biometricError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Self.proseWidth, alignment: .leading)
                }
            }
        }
    }

    /// One caption paragraph, bounded so it cannot inflate the window's ideal
    /// width the way an unbounded one did.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Self.proseWidth, alignment: .leading)
    }

}
