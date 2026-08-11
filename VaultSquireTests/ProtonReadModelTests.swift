import XCTest
@testable import VaultSquire

final class ProtonReadModelTests: XCTestCase {
    private let account = AccountID(provider: .protonCLI, rawValue: "VSQ-proton-account")
    private let generation = SnapshotGeneration(rawValue: 3)

    // MARK: - Vaults

    func testDecodesVaultsFromAWrapperObject() throws {
        let json = Data("""
        {"vaults":[
          {"shareId":"S1","vaultId":"V1","name":"Personal"},
          {"share_id":"S2","name":"Work"}
        ]}
        """.utf8)
        let vaults = try ProtonReadModel.decodeVaults(json)
        XCTAssertEqual(vaults.count, 2)
        XCTAssertEqual(vaults[0], ProtonVault(shareID: "S1", vaultID: "V1", name: "Personal"))
        XCTAssertEqual(vaults[1], ProtonVault(shareID: "S2", vaultID: nil, name: "Work"))
    }

    func testDecodesVaultsFromABareArray() throws {
        let json = Data("""
        [{"ShareID":"S9","name":"Shared"}]
        """.utf8)
        let vaults = try ProtonReadModel.decodeVaults(json)
        XCTAssertEqual(vaults, [ProtonVault(shareID: "S9", vaultID: nil, name: "Shared")])
    }

    func testVaultMissingAShareIdentifierIsSkipped() throws {
        let json = Data(#"{"vaults":[{"name":"No Share"},{"shareId":"S1","name":"Ok"}]}"#.utf8)
        let vaults = try ProtonReadModel.decodeVaults(json)
        XCTAssertEqual(vaults.map(\.shareID), ["S1"])
    }

    // MARK: - Items

    func testDecodesItemsWithNestedContentAndMixedCasing() throws {
        let json = Data("""
        {"items":[
          {"id":"i1","type":"login","title":"GitHub",
           "content":{"username":"octocat","password":"VSQ-secret","totp":"otpauth://x",
                      "urls":["https://github.com","https://gist.github.com"]}},
          {"id":"i2","type":"note","name":"My Note","content":{"note":"remember this"}}
        ]}
        """.utf8)
        let items = try ProtonReadModel.decodeItems(json, shareID: "S1", vaultName: "Personal")
        XCTAssertEqual(items.count, 2)

        let login = items[0]
        XCTAssertEqual(login.itemID, "i1")
        XCTAssertEqual(login.type, .login)
        XCTAssertEqual(login.title, "GitHub")
        XCTAssertEqual(login.username, "octocat")
        XCTAssertEqual(login.urls, ["https://github.com", "https://gist.github.com"])
        XCTAssertEqual(login.shareID, "S1")
        XCTAssertEqual(login.vaultName, "Personal")

        let note = items[1]
        XCTAssertEqual(note.type, .note)
        XCTAssertEqual(note.title, "My Note")
        XCTAssertNil(note.username)
    }

    /// No secret a build's `item list` happens to print is ever retained in
    /// the summary: passwords, one-time-password seeds, and notes decode as
    /// nil by policy, so nothing secret can reach the sealed snapshot. The
    /// 1Password decoder holds the same line.
    func testListPayloadSecretsAreNeverCapturedIntoSummaries() throws {
        let json = Data("""
        {"items":[
          {"id":"i1","type":"login","title":"GitHub",
           "content":{"username":"octocat","password":"VSQ-secret","totp":"otpauth://x",
                      "note":"VSQ-note","urls":["https://github.com"]}}
        ]}
        """.utf8)
        let items = try ProtonReadModel.decodeItems(json, shareID: "S1", vaultName: "Personal")
        let login = try XCTUnwrap(items.first)
        XCTAssertNil(login.password)
        XCTAssertNil(login.totp)
        XCTAssertNil(login.note)
        // Non-secret display fields still decode.
        XCTAssertEqual(login.username, "octocat")
        XCTAssertEqual(login.urls, ["https://github.com"])
    }

    func testItemMissingAnIdentifierIsSkipped() throws {
        let json = Data(#"{"items":[{"type":"login","title":"x"},{"id":"i2","type":"login","title":"y"}]}"#.utf8)
        let items = try ProtonReadModel.decodeItems(json, shareID: "S1", vaultName: "V")
        XCTAssertEqual(items.map(\.itemID), ["i2"])
    }

    func testDecodesItemContentFromAReadForRevealMerging() throws {
        let json = Data(#"{"login":{"password":"pw-from-read","totp":"otp-from-read"}}"#.utf8)
        let content = try ProtonReadModel.decodeItemContent(json)
        XCTAssertEqual(content.password, "pw-from-read")
        XCTAssertEqual(content.totp, "otp-from-read")
        XCTAssertNil(content.username)
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try ProtonReadModel.decodeVaults(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? ProtonReadModelError, .malformedJSON)
        }
    }

    // MARK: - Type mapping

    func testTypeMappingIsTolerantOfCasingAndSpelling() {
        XCTAssertEqual(ProtonItemType.from(raw: "Login"), .login)
        XCTAssertEqual(ProtonItemType.from(raw: "credit_card"), .creditCard)
        XCTAssertEqual(ProtonItemType.from(raw: "SSH_KEY"), .sshKey)
        XCTAssertEqual(ProtonItemType.from(raw: "wifi"), .wifi)
        XCTAssertEqual(ProtonItemType.from(raw: "something-new"), .unknown)
        XCTAssertEqual(ProtonItemType.creditCard.category, .card)
        XCTAssertEqual(ProtonItemType.alias.category, .unsupported)
    }

    // MARK: - Mapping to projections and details

    private func sampleItem() -> ProtonItem {
        ProtonItem(
            itemID: "i1", shareID: "S1", vaultName: "Personal", type: .login,
            title: "GitHub", username: "octocat", password: "VSQ-secret",
            totp: "otpauth://x", urls: ["https://github.com"], note: nil
        )
    }

    func testProjectionCarriesCompoundIdentityAndReadOnlyCapabilities() {
        let projection = ProtonReadModel.projection(
            for: sampleItem(), account: account, captureGeneration: generation
        )
        XCTAssertEqual(projection.id.rawValue, "i1")
        XCTAssertEqual(projection.id.account, account)
        XCTAssertEqual(projection.id.space.scope, .providerSpace("S1"))
        XCTAssertEqual(projection.displayTitle, "GitHub")
        XCTAssertEqual(projection.displaySubtitle, "octocat")
        XCTAssertEqual(projection.category, .login)
        XCTAssertEqual(projection.websites, ["https://github.com"])
        XCTAssertEqual(projection.groupingLabels, ["Personal"])
        XCTAssertEqual(projection.capabilities, [.viewItems, .searchItems, .revealSecret, .copySecret])
        // No write capability is ever offered for a Proton item.
        XCTAssertFalse(projection.capabilities.contains(.createItem))
        XCTAssertFalse(projection.capabilities.contains(.updateItem))
        XCTAssertFalse(projection.capabilities.contains(.archiveItem))
    }

    func testDetailMarksSecretAndTotpFields() {
        let detail = ProtonReadModel.detail(for: sampleItem(), account: account)
        XCTAssertEqual(detail.title, "GitHub")
        XCTAssertEqual(detail.fields.first { $0.label == "Password" }?.kind, .secret)
        XCTAssertEqual(detail.fields.first { $0.label == "One-time code" }?.kind, .totpSeed)
        XCTAssertEqual(detail.fields.first { $0.label == "Website" }?.kind, .uri)
        // No empty field is emitted for the absent note.
        XCTAssertNil(detail.fields.first { $0.label == "Note" })
    }

    func testMergingOverlaysSecretsFromARead() {
        let summary = ProtonItem(
            itemID: "i1", shareID: "S1", vaultName: "Personal", type: .login,
            title: "GitHub", username: "octocat", password: nil, totp: nil,
            urls: ["https://github.com"], note: nil
        )
        let merged = summary.merging(ProtonItemContent(
            username: nil, password: "revealed", totp: "revealed-totp", urls: [], note: nil
        ))
        XCTAssertEqual(merged.password, "revealed")
        XCTAssertEqual(merged.totp, "revealed-totp")
        XCTAssertEqual(merged.username, "octocat")
        XCTAssertEqual(merged.urls, ["https://github.com"])
    }
}
