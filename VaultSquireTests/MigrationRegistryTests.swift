import XCTest
@testable import VaultSquire

final class MigrationRegistryTests: XCTestCase {
    private func migration(_ version: Int, _ name: String) -> SchemaMigration {
        SchemaMigration(version: SchemaVersion(rawValue: version), name: name)
    }

    private func registry(_ versions: [Int]) throws -> MigrationRegistry {
        try MigrationRegistry(migrations: versions.map { migration($0, "v\($0)") })
    }

    func testFreshDatabaseAppliesAllMigrationsInOrder() throws {
        let registry = try registry([1, 2, 3])
        let pending = try registry.pendingMigrations(installedVersion: .empty)
        XCTAssertEqual(pending.map(\.version.rawValue), [1, 2, 3])
    }

    func testUpToDateDatabaseAppliesNoMigrations() throws {
        let registry = try registry([1, 2, 3])
        let pending = try registry.pendingMigrations(installedVersion: SchemaVersion(rawValue: 3))
        XCTAssertTrue(pending.isEmpty)
    }

    func testPartialDatabaseAppliesOnlyThePendingTail() throws {
        let registry = try registry([1, 2, 3])
        let pending = try registry.pendingMigrations(installedVersion: SchemaVersion(rawValue: 1))
        XCTAssertEqual(pending.map(\.version.rawValue), [2, 3])
    }

    func testLatestVersion() throws {
        XCTAssertEqual(try registry([1, 2, 3]).latestVersion, SchemaVersion(rawValue: 3))
        XCTAssertEqual(try registry([]).latestVersion, .empty)
    }

    func testEmptyRegistryIsValidAndHasNoPendingMigrations() throws {
        let registry = try registry([])
        XCTAssertTrue(try registry.pendingMigrations(installedVersion: .empty).isEmpty)
    }

    func testMalformedSequenceRejected() {
        // Gap.
        XCTAssertThrowsError(try registry([1, 3])) { XCTAssertEqual($0 as? MigrationRegistryError, .malformedSequence) }
        // Duplicate.
        XCTAssertThrowsError(try registry([1, 1])) { XCTAssertEqual($0 as? MigrationRegistryError, .malformedSequence) }
        // Does not start at 1.
        XCTAssertThrowsError(try registry([2])) { XCTAssertEqual($0 as? MigrationRegistryError, .malformedSequence) }
        // Out of order.
        XCTAssertThrowsError(try registry([2, 1])) { XCTAssertEqual($0 as? MigrationRegistryError, .malformedSequence) }
    }

    func testWellFormedSequenceAccepted() throws {
        XCTAssertEqual(try registry([1, 2, 3, 4]).migrations.count, 4)
    }

    func testDatabaseFromNewerBuildRejected() throws {
        let registry = try registry([1, 2])
        XCTAssertThrowsError(
            try registry.pendingMigrations(installedVersion: SchemaVersion(rawValue: 3))
        ) { error in
            XCTAssertEqual(
                error as? MigrationRegistryError,
                .databaseFromNewerBuild(
                    installed: SchemaVersion(rawValue: 3),
                    latest: SchemaVersion(rawValue: 2)
                )
            )
        }
    }
}
