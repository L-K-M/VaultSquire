#if SANDBOX_PROCESS_PROBE
import AppKit
import SwiftUI

@MainActor
private final class SandboxProcessProbeModel: ObservableObject {
    enum ProbeState: Equatable {
        case idle
        case running
        case result(String)
    }

    @Published private(set) var executableName: String?
    @Published private(set) var sessionDirectoryName: String?
    @Published private(set) var state: ProbeState = .idle

    private var executableURL: URL?
    private var sessionDirectoryURL: URL?

    var canRun: Bool {
        executableURL != nil && state != .running
    }

    var statusText: String {
        switch state {
        case .idle:
            "No probe has run."
        case .running:
            "Running with bounded output and a five-second timeout..."
        case let .result(message):
            message
        }
    }

    func selectExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Select the user-installed pass-cli executable"
        panel.prompt = "Select"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        executableURL = selectedURL
        executableName = selectedURL.lastPathComponent
        state = .idle
    }

    func selectSessionDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Select the existing CLI session directory"
        panel.prompt = "Select"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        sessionDirectoryURL = selectedURL
        sessionDirectoryName = selectedURL.lastPathComponent
        state = .idle
    }

    func runStartupProbe() {
        run(arguments: [])
    }

    func runSessionProbe() {
        run(arguments: ["info"])
    }

    private func run(arguments: [String]) {
        guard let executableURL else {
            return
        }

        let selectedSessionDirectoryURL = sessionDirectoryURL
        let executableAccess = executableURL.startAccessingSecurityScopedResource()
        let sessionAccess = selectedSessionDirectoryURL?.startAccessingSecurityScopedResource() ?? false
        state = .running

        Task { [weak self, selectedSessionDirectoryURL] in
            defer {
                if executableAccess {
                    executableURL.stopAccessingSecurityScopedResource()
                }
                if sessionAccess {
                    selectedSessionDirectoryURL?.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let result = try await ProcessProbe().run(
                    executableURL: executableURL,
                    arguments: arguments
                )
                self?.state = .result(
                    "Exited with status \(result.exitStatus). Read \(result.standardOutputBytes) stdout bytes and \(result.standardErrorBytes) stderr bytes; neither stream was retained."
                )
            } catch let error as ProcessProbeError {
                self?.state = .result(Self.message(for: error))
            } catch {
                self?.state = .result("The executable could not be launched.")
            }
        }
    }

    private static func message(for error: ProcessProbeError) -> String {
        switch error {
        case .executableMustBeAbsolute:
            "The selected executable did not resolve to an absolute file URL."
        case .invalidOutputLimit:
            "The probe output bound was invalid."
        case .outputLimitExceeded:
            "The CLI exceeded the probe output bound."
        case .timedOut:
            "The CLI did not finish before the probe timeout."
        }
    }
}

struct SandboxProcessProbeView: View {
    @StateObject private var model = SandboxProcessProbeModel()

    var body: some View {
        Form {
            Section("Selected resources") {
                LabeledContent("Executable", value: model.executableName ?? "Not selected")
                Button("Select executable...", action: model.selectExecutable)

                LabeledContent(
                    "Session directory",
                    value: model.sessionDirectoryName ?? "Not selected"
                )
                Button("Select session directory...", action: model.selectSessionDirectory)
            }

            Section("Feasibility checks") {
                HStack {
                    Button("Probe startup", action: model.runStartupProbe)
                    Button("Probe session and keyring", action: model.runSessionProbe)
                }
                .disabled(!model.canRun)

                Text(model.statusText)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
            }

            Text("The session probe invokes the documented non-interactive `info` command. It never starts login, displays raw CLI output, changes HOME or XDG variables, or persists selected paths.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .accessibilityIdentifier("sandbox-process-probe")
    }
}
#endif
