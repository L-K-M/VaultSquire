import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum AccessState: Equatable, Sendable {
        case locked
    }

    @Published private(set) var accessState: AccessState = .locked

    var isLocked: Bool {
        accessState == .locked
    }

    func lock() {
        accessState = .locked
        ApplicationCoordinator.shared.dismissQuickSearch()
        AppLog.record(.vaultLocked)
    }
}
