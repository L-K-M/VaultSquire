import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        TabView {
            Form {
                LabeledContent("App shortcut", value: "Command-Shift-Space")
                LabeledContent(
                    "Vault state",
                    value: appModel.hasNoAccounts
                        ? "No accounts"
                        : (appModel.isLocked ? "Locked" : "Unavailable")
                )

                Text("A configurable global shortcut and lock policy are enabled only after their interaction and security tests pass.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }

            VStack(alignment: .leading, spacing: 12) {
                Label("No telemetry", systemImage: "hand.raised")
                    .font(.headline)
                Text("VaultSquire records only fixed, allowlisted lifecycle and performance events. Account and item values are never diagnostic metadata.")
                    .foregroundStyle(.secondary)
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
        .frame(width: 540, height: 300)
        .accessibilityIdentifier("settings-view")
    }
}
