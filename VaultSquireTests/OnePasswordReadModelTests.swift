import XCTest
@testable import VaultSquire

/// All fixtures are synthetic. Secret-looking values are prefixed `VSQ-` so a
/// leakage assertion can search for them unambiguously.
final class OnePasswordReadModelTests: XCTestCase {
    private let account = OnePasswordAccountService.vaultIdentity(for: "ACCOUNT1")

    private let itemJSON = """
    {
      "id": "kiramv6tpjijkuci7fig4lndta",
      "title": "Example Service",
      "version": 3,
      "vault": { "id": "uteieiwkhgv6hau7xkorejyvru", "name": "Private" },
      "category": "LOGIN",
      "urls": [ { "label": "website", "primary": true, "href": "https://example.com" } ],
      "fields": [
        { "id": "username", "type": "STRING", "purpose": "USERNAME",
          "label": "username", "value": "squire@example.com" },
        { "id": "password", "type": "CONCEALED", "purpose": "PASSWORD",
          "label": "password", "value": "VSQ-password" },
        { "id": "notesPlain", "type": "STRING", "purpose": "NOTES",
          "label": "notesPlain", "value": "A synthetic note" },
        { "id": "totp", "type": "OTP", "label": "one-time password",
          "value": "otpauth://totp/Example?secret=VSQABC" },
        { "id": "rk", "section": { "id": "s1", "label": "Recovery" },
          "type": "CONCEALED", "label": "recovery key", "value": "VSQ-recovery" },
        { "id": "pin", "section": { "id": "s1", "label": "Recovery" },
          "type": "STRING", "label": "hint", "value": "the usual" }
      ]
    }
    """

    // MARK: - Vaults

    func testDecodesVaultsFromABareArray() throws {
        let data = Data(#"[{"id":"VAULT1","name":"Private"},{"id":"VAULT2","name":"Shared"}]"#.utf8)
        let vaults = try OnePasswordReadModel.decodeVaults(data)
        XCTAssertEqual(vaults, [
            OnePasswordVault(vaultID: "VAULT1", name: "Private"),
            OnePasswordVault(vaultID: "VAULT2", name: "Shared")
        ])
    }

    func testDecodesVaultsFromAWrapperObject() throws {
        let data = Data(#"{"vaults":[{"id":"VAULT1","name":"Private"}]}"#.utf8)
        let vaults = try OnePasswordReadModel.decodeVaults(data)
        XCTAssertEqual(vaults, [OnePasswordVault(vaultID: "VAULT1", name: "Private")])
    }

    func testAVaultWithoutAnIdentifierIsSkippedRatherThanInvented() throws {
        let data = Data(#"[{"name":"Nameless"},{"id":"VAULT1","name":"Private"}]"#.utf8)
        let vaults = try OnePasswordReadModel.decodeVaults(data)
        XCTAssertEqual(vaults, [OnePasswordVault(vaultID: "VAULT1", name: "Private")])
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try OnePasswordReadModel.decodeVaults(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? OnePasswordReadModelError, .malformedJSON)
        }
    }

    // MARK: - Item summaries

    func testDecodesItemSummariesScopedToTheVaultTheyWereListedFrom() throws {
        let data = Data("[\(itemJSON)]".utf8)
        let items = try OnePasswordReadModel.decodeItems(
            data, vaultID: "VAULT1", vaultName: "Private"
        )
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.itemID, "kiramv6tpjijkuci7fig4lndta")
        XCTAssertEqual(item.title, "Example Service")
        XCTAssertEqual(item.category, .login)
        XCTAssertEqual(item.username, "squire@example.com")
        XCTAssertEqual(item.urls, ["https://example.com"])
        // The vault comes from the listing scope, never from the payload, so an
        // item cannot be filed under a vault it was not read from.
        XCTAssertEqual(item.vaultID, "VAULT1")
        XCTAssertEqual(item.vaultName, "Private")
    }

    /// The security property that lets a summary rest on disk: `op item list`'s
    /// payload is undocumented, so if a build returned field values, no
    /// concealed or one-time-password value may survive into the snapshot type.
    func testNoConcealedValueSurvivesIntoAnItemSummary() throws {
        let data = Data("[\(itemJSON)]".utf8)
        let items = try OnePasswordReadModel.decodeItems(
            data, vaultID: "VAULT1", vaultName: "Private"
        )
        let encoded = try JSONEncoder().encode(items)
        let text = String(decoding: encoded, as: UTF8.self)

        XCTAssertFalse(text.contains("VSQ-password"), "a concealed value reached the summary")
        XCTAssertFalse(text.contains("VSQ-recovery"), "a concealed value reached the summary")
        XCTAssertFalse(text.contains("VSQABC"), "a one-time-password seed reached the summary")
        XCTAssertFalse(text.contains("A synthetic note"), "a note reached the summary")
    }

    /// A build that marked the username concealed must yield no username rather
    /// than sealing a secret into the snapshot.
    func testAConcealedUsernameIsNotTreatedAsANonSecretSummaryField() throws {
        let json = """
        [{"id":"ITEM1","title":"Odd","category":"LOGIN","fields":[
          {"id":"username","type":"CONCEALED","purpose":"USERNAME",
           "label":"username","value":"VSQ-hidden"}
        ]}]
        """
        let items = try OnePasswordReadModel.decodeItems(
            Data(json.utf8), vaultID: "VAULT1", vaultName: "Private"
        )
        XCTAssertNil(try XCTUnwrap(items.first).username)
    }

    func testUsesTheCLIsDisplayHintAsASubtitleFallback() throws {
        let json = """
        [{"id":"ITEM1","title":"Hinted","category":"LOGIN",
          "additional_information":"squire@example.com"}]
        """
        let items = try OnePasswordReadModel.decodeItems(
            Data(json.utf8), vaultID: "VAULT1", vaultName: "Private"
        )
        let item = try XCTUnwrap(items.first)
        XCTAssertNil(item.username)
        XCTAssertEqual(item.additionalInformation, "squire@example.com")

        let projection = OnePasswordReadModel.projection(
            for: item, account: account, captureGeneration: SnapshotGeneration(rawValue: 1)
        )
        XCTAssertEqual(projection.displaySubtitle, "squire@example.com")
    }

    // MARK: - Categories

    func testMapsCategoriesOnlyWhereTheMappingIsLossless() {
        XCTAssertEqual(OnePasswordItemCategory.from(raw: "LOGIN").category, .login)
        XCTAssertEqual(OnePasswordItemCategory.from(raw: "SECURE_NOTE").category, .secureNote)
        XCTAssertEqual(OnePasswordItemCategory.from(raw: "CREDIT_CARD").category, .card)
        XCTAssertEqual(OnePasswordItemCategory.from(raw: "IDENTITY").category, .identity)
        // A Password, SSH Key, or Database item has no faithful shared category,
        // so it stays visible as unsupported instead of posing as a Login.
        XCTAssertEqual(OnePasswordItemCategory.from(raw: "PASSWORD").category, .unsupported)
        XCTAssertEqual(OnePasswordItemCategory.from(raw: "SSH_KEY").category, .unsupported)
        XCTAssertEqual(OnePasswordItemCategory.from(raw: "DATABASE").category, .unsupported)
        XCTAssertEqual(OnePasswordItemCategory.from(raw: "WHAT_IS_THIS"), .unknown)
        XCTAssertEqual(OnePasswordItemCategory.from(raw: "WHAT_IS_THIS").category, .unsupported)
    }

    // MARK: - Item content

    func testDecodesTheBuiltInFieldsOfAnOpenedItem() throws {
        let content = try OnePasswordReadModel.decodeItemContent(Data(itemJSON.utf8))
        XCTAssertEqual(content.username, "squire@example.com")
        XCTAssertEqual(content.password, "VSQ-password")
        XCTAssertEqual(content.totp, "otpauth://totp/Example?secret=VSQABC")
        XCTAssertEqual(content.note, "A synthetic note")
        XCTAssertEqual(content.urls, ["https://example.com"])
    }

    /// Most of a credit card, identity, or API credential lives in custom
    /// sections, so those fields are surfaced — qualified by section, and with
    /// their concealment preserved — rather than dropped.
    func testSurfacesCustomFieldsWithoutRepeatingTheBuiltInOnes() throws {
        let content = try OnePasswordReadModel.decodeItemContent(Data(itemJSON.utf8))
        XCTAssertEqual(content.additionalFields, [
            OnePasswordContentField(
                label: "Recovery · recovery key", value: "VSQ-recovery", isConcealed: true
            ),
            OnePasswordContentField(
                label: "Recovery · hint", value: "the usual", isConcealed: false
            )
        ])
    }

    func testDecodesAnItemDeliveredInsideAnArray() throws {
        let content = try OnePasswordReadModel.decodeItemContent(Data("[\(itemJSON)]".utf8))
        XCTAssertEqual(content.password, "VSQ-password")
    }

    // MARK: - Mapping

    func testProjectionCarriesReadOnlyCapabilitiesAndTheCompoundIdentity() throws {
        let items = try OnePasswordReadModel.decodeItems(
            Data("[\(itemJSON)]".utf8), vaultID: "VAULT1", vaultName: "Private"
        )
        let projection = OnePasswordReadModel.projection(
            for: try XCTUnwrap(items.first),
            account: account,
            captureGeneration: SnapshotGeneration(rawValue: 7)
        )
        XCTAssertEqual(projection.id.provider, .onePasswordCLI)
        XCTAssertEqual(projection.id.space.scope, .providerSpace("VAULT1"))
        XCTAssertEqual(projection.groupingLabels, ["Private"])
        XCTAssertEqual(projection.capabilities, OnePasswordReadModel.capabilities)
        XCTAssertFalse(projection.capabilities.contains(.createItem))
        XCTAssertFalse(projection.capabilities.contains(.updateItem))
        XCTAssertFalse(projection.capabilities.contains(.archiveItem))
    }

    func testDetailWithoutFetchedContentShowsOnlyNonSecretFields() throws {
        let items = try OnePasswordReadModel.decodeItems(
            Data("[\(itemJSON)]".utf8), vaultID: "VAULT1", vaultName: "Private"
        )
        let detail = OnePasswordReadModel.detail(
            for: try XCTUnwrap(items.first), account: account, content: nil
        )
        XCTAssertNil(detail.fields.first { $0.kind == .secret })
        XCTAssertNil(detail.fields.first { $0.kind == .totpSeed })
        XCTAssertEqual(detail.fields.first { $0.label == "Username" }?.value, "squire@example.com")
    }

    func testDetailWithFetchedContentMarksSecretsAndSeeds() throws {
        let items = try OnePasswordReadModel.decodeItems(
            Data("[\(itemJSON)]".utf8), vaultID: "VAULT1", vaultName: "Private"
        )
        let content = try OnePasswordReadModel.decodeItemContent(Data(itemJSON.utf8))
        let detail = OnePasswordReadModel.detail(
            for: try XCTUnwrap(items.first), account: account, content: content
        )

        let password = try XCTUnwrap(detail.fields.first { $0.label == "Password" })
        XCTAssertEqual(password.value, "VSQ-password")
        XCTAssertEqual(password.kind, .secret)

        let totp = try XCTUnwrap(detail.fields.first { $0.label == "One-time code" })
        XCTAssertEqual(totp.kind, .totpSeed)

        let recovery = try XCTUnwrap(
            detail.fields.first { $0.label == "Recovery · recovery key" }
        )
        XCTAssertEqual(recovery.kind, .secret)
        let hint = try XCTUnwrap(detail.fields.first { $0.label == "Recovery · hint" })
        XCTAssertEqual(hint.kind, .plain)

        // Row identifiers must stay unique even when two fields share a label.
        XCTAssertEqual(Set(detail.fields.map(\.id)).count, detail.fields.count)
    }

    // MARK: - Account resolution

    /// The shape `op account list --format json` emits.
    func testDecodesTheAccountsConfiguredOnThisDevice() throws {
        let json = #"""
        [
          {"url":"my.1password.com","email":"squire@example.com",
           "user_uuid":"USERA","account_uuid":"ACCOUNTA"},
          {"url":"work.1password.com","email":"squire@work.example",
           "user_uuid":"USERB","account_uuid":"ACCOUNTB"}
        ]
        """#
        XCTAssertEqual(try OnePasswordReadModel.decodeAccounts(Data(json.utf8)), [
            OnePasswordAccount(
                accountUUID: "ACCOUNTA", url: "my.1password.com", email: "squire@example.com"
            ),
            OnePasswordAccount(
                accountUUID: "ACCOUNTB", url: "work.1password.com", email: "squire@work.example"
            )
        ])
    }

    /// The account identifier goes into argv, so one that fails validation is
    /// dropped rather than offered as something the user could open.
    func testAnAccountWithAnUnusableIdentifierIsDropped() throws {
        let json = #"[{"url":"bad","account_uuid":"--oops"},{"url":"ok","account_uuid":"ACCOUNTA"}]"#
        let accounts = try OnePasswordReadModel.decodeAccounts(Data(json.utf8))
        XCTAssertEqual(accounts.map(\.accountUUID), ["ACCOUNTA"])
    }

    func testDecodesNoAccountsFromAnEmptyList() throws {
        XCTAssertTrue(try OnePasswordReadModel.decodeAccounts(Data("[]".utf8)).isEmpty)
    }

    func testMalformedAccountJSONThrows() {
        XCTAssertThrowsError(try OnePasswordReadModel.decodeAccounts(Data("nope".utf8)))
    }

    /// Two accounts must produce distinct compound identities even for
    /// identically named vaults and identically titled items.
    func testTwoAccountsProduceDistinctItemIdentities() throws {
        let json = #"[{"id":"ITEM1","title":"Shared Name","category":"LOGIN"}]"#
        let items = try OnePasswordReadModel.decodeItems(
            Data(json.utf8), vaultID: "VAULT1", vaultName: "Private"
        )
        let item = try XCTUnwrap(items.first)
        let first = OnePasswordReadModel.itemID(
            for: item, account: OnePasswordAccountService.vaultIdentity(for: "ACCOUNTA")
        )
        let second = OnePasswordReadModel.itemID(
            for: item, account: OnePasswordAccountService.vaultIdentity(for: "ACCOUNTB")
        )
        XCTAssertNotEqual(first, second)
    }
}
