import Foundation

/// Drives the Proton Pass connection pane. It probes the user-installed CLI for
/// its detection status and never collects a Proton credential: sign-in stays
/// entirely with the official CLI. Opening the vault is delegated to the app
/// model, which performs the read-only refresh.
@MainActor
final class ProtonConnectModel: ObservableObject {
    enum Stage: Equatable {
        case probing
        case status(ProtonConnectionStatus)
    }

    @Published private(set) var stage: Stage = .probing

    private let service: ProtonAccountService
    private var task: Task<Void, Never>?

    init(service: ProtonAccountService = ProtonAccountService()) {
        self.service = service
    }

    /// Probes the CLI status off the main actor and publishes the result. Any
    /// prior probe is cancelled so a stale result cannot overwrite a newer one.
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

    /// True when a supported, authenticated CLI is ready to read.
    var isReady: Bool {
        if case .status(.ready) = stage { return true }
        return false
    }
}
