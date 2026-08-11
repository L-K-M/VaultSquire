import Foundation

/// Drives the 1Password connection pane. It probes the user-installed CLI for
/// its detection status and never collects a 1Password credential: the account
/// password, Secret Key, and any second factor stay with 1Password's own desktop
/// app, which authorizes the CLI with a biometric prompt. Opening the vault is
/// delegated to the app model, which performs the read-only refresh.
@MainActor
final class OnePasswordConnectModel: ObservableObject {
    enum Stage: Equatable {
        case probing
        case status(OnePasswordConnectionStatus)
    }

    @Published private(set) var stage: Stage = .probing

    private let service: OnePasswordAccountService
    private var task: Task<Void, Never>?

    init(service: OnePasswordAccountService = OnePasswordAccountService()) {
        self.service = service
    }

    /// Probes the CLI status off the main actor and publishes the result. Any
    /// prior probe is cancelled so a stale result cannot overwrite a newer one.
    ///
    /// The probe can take a moment: its authorization step may raise the
    /// 1Password app's prompt and wait for the user's fingerprint.
    func probe() {
        task?.cancel()
        stage = .probing
        task = Task { [service] in
            let status = await service.probeStatus()
            guard !Task.isCancelled else { return }
            self.stage = .status(status)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// True when a supported, authorized CLI is ready to read.
    var isReady: Bool {
        if case .status(.ready) = stage { return true }
        return false
    }
}
