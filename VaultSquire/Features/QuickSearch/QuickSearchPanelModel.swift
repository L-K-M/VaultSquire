import Foundation

@MainActor
final class QuickSearchPanelModel: ObservableObject {
    @Published var query = ""

    /// Incremented by the controller once the panel has been made key. The
    /// search field's focus is driven from this rather than from `onAppear`,
    /// which fires only for the first presentation and can run before the panel
    /// holds key status.
    @Published private(set) var presentationID = 0

    func clear() {
        query.removeAll(keepingCapacity: false)
    }

    func notePresented() {
        presentationID += 1
    }
}
