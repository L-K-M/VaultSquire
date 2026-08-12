import XCTest
@testable import VaultSquire

final class VaultItemDetailTests: XCTestCase {
    func testOnlyNonSecretFieldsAllowTextSelection() {
        XCTAssertTrue(makeField(kind: .plain).allowsTextSelection)
        XCTAssertTrue(makeField(kind: .uri).allowsTextSelection)
        XCTAssertFalse(makeField(kind: .secret).allowsTextSelection)
        XCTAssertFalse(makeField(kind: .totpSeed).allowsTextSelection)
    }

    private func makeField(kind: VaultItemDetail.DetailField.Kind) -> VaultItemDetail.DetailField {
        VaultItemDetail.DetailField(
            id: "field",
            label: "Field",
            value: "VSQ-Synthetic-value",
            kind: kind
        )
    }
}
