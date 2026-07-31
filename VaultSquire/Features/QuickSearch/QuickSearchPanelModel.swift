import Foundation

@MainActor
final class QuickSearchPanelModel: ObservableObject {
    @Published var query = ""

    func clear() {
        query.removeAll(keepingCapacity: false)
    }
}
