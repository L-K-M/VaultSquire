import Foundation

/// A monotonic on-disk schema version. Version 0 is a database with no schema
/// yet; the first migration produces version 1.
struct SchemaVersion: Hashable, Sendable, Codable, Comparable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// A database that has had no migration applied.
    static let empty = SchemaVersion(rawValue: 0)

    static func < (lhs: SchemaVersion, rhs: SchemaVersion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One ordered schema migration, identified by the version it produces. The real
/// engine runs each migration's statements inside a transaction; this seam fixes
/// the identity, order, and contiguity of the sequence so the schema history is
/// reviewed and stable independent of the storage engine. Migrations are
/// append-only: a shipped version's identity never changes.
struct SchemaMigration: Hashable, Sendable {
    /// The version the database is at once this migration has been applied.
    let version: SchemaVersion
    /// A short, stable identifier for the migration, used in diagnostics.
    let name: String

    init(version: SchemaVersion, name: String) {
        self.version = version
        self.name = name
    }
}

enum MigrationRegistryError: Error, Equatable, Sendable {
    /// The migration list is not a strictly increasing, gap-free sequence
    /// starting at version 1.
    case malformedSequence
    /// The database is at a version newer than the registry knows — it was
    /// written by a newer build and must not be opened or migrated by this one.
    case databaseFromNewerBuild(installed: SchemaVersion, latest: SchemaVersion)
}

/// The ordered registry of schema migrations for an account database. It
/// validates that its migrations form a strictly increasing, contiguous
/// sequence starting at version 1, and computes which migrations a database at a
/// given installed version still needs. The real store applies the pending
/// migrations transactionally on open; the registry itself performs no I/O, so
/// the migration order is a reviewed, engine-independent fact.
struct MigrationRegistry: Sendable {
    let migrations: [SchemaMigration]

    /// Creates a registry, validating the sequence. Throws `malformedSequence`
    /// if the versions are not 1, 2, 3, … in order with no gaps or duplicates.
    /// An empty registry (no migrations yet) is valid.
    init(migrations: [SchemaMigration]) throws {
        var expected = 1
        for migration in migrations {
            guard migration.version.rawValue == expected else {
                throw MigrationRegistryError.malformedSequence
            }
            expected += 1
        }
        self.migrations = migrations
    }

    /// The version a fully migrated database is at (`.empty` when there are no
    /// migrations).
    var latestVersion: SchemaVersion {
        migrations.last?.version ?? .empty
    }

    /// The migrations a database at `installedVersion` must still apply, in
    /// order. A database already at the latest version needs none; a database at
    /// a version newer than the registry is rejected with `databaseFromNewerBuild`
    /// rather than silently downgraded.
    func pendingMigrations(installedVersion: SchemaVersion) throws -> [SchemaMigration] {
        if installedVersion > latestVersion {
            throw MigrationRegistryError.databaseFromNewerBuild(
                installed: installedVersion,
                latest: latestVersion
            )
        }
        return migrations.filter { $0.version > installedVersion }
    }
}
