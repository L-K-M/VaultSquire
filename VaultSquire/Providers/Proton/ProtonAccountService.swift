import Foundation

/// The outcome of probing the CLI for the connection pane. Every case is an
/// honest, non-secret state the UI can render directly; no case implies a
/// nearby version would work or that a password was collected.
enum ProtonConnectionStatus: Equatable, Sendable {
    /// No allowlisted binary was found at any candidate path.
    case notInstalled
    /// A binary was found but its reported version is outside the tested
    /// allowlist. Carries the exact rejected version.
    case unsupportedVersion(String)
    /// The binary produced no recognizable version token.
    case unparseableVersion
    /// The binary is supported but has no authenticated session; the user signs
    /// in with the official CLI, never through VaultSquire.
    case notAuthenticated
    /// The binary is supported and authenticated; reads are available.
    case ready(version: String, approvedPath: String, resolvedRealPath: String)
    /// The binary produced output VaultSquire could not read, or a command
    /// failed for a reason other than an unauthenticated session.
    case error
}

enum ProtonServiceError: Error, Equatable, Sendable {
    case cliNotInstalled
    case unsupportedVersion(String)
    case unparseableVersion
    case notAuthenticated
    case unreadableOutput
    case executionFailed
}

/// The result of a full read refresh: the sealed-ready snapshot and its display
/// projections.
struct ProtonRefreshResult: Sendable {
    let snapshot: ProtonSnapshot
    let projections: [VaultItemProjection]
}

/// Orchestrates the Proton read flow end to end: locate the binary, gate its
/// version, list vaults, list and hydrate items, publish a sealed lossy
/// snapshot, and project items for display. It is read-only — no method mutates
/// a remote item — and every command runs through `ProtonCLIRunner`, so nothing
/// sensitive can reach argv or the environment. Vaultwarden is unaffected: this
/// is a self-contained provider vertical.
struct ProtonAccountService: Sendable {
    /// The single local Proton account identity for this installation.
    static let accountID = AccountID(provider: .protonCLI, rawValue: "proton-cli-primary")

    /// The most vaults a single refresh will enumerate. Each vault costs one
    /// child process; a pathological account cannot spawn an unbounded number.
    static let maximumVaults = 50

    let locator: ProtonCLILocator
    let executor: any CLIExecuting
    let versionGate: ProtonCLIVersionGate
    let cache: ProtonSnapshotCache
    private let now: @Sendable () -> Date

    init(
        locator: ProtonCLILocator = ProtonCLILocator(),
        executor: any CLIExecuting = CLIProcessExecutor(),
        versionGate: ProtonCLIVersionGate = .production,
        cache: ProtonSnapshotCache = ProtonSnapshotCache(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.locator = locator
        self.executor = executor
        self.versionGate = versionGate
        self.cache = cache
        self.now = now
    }

    // MARK: - Detection

    /// Probes the CLI for the connection pane without a full refresh: locate,
    /// gate the version, then confirm an authenticated session by listing
    /// vaults. Returns an honest status for every failure mode.
    func probeStatus() async -> ProtonConnectionStatus {
        guard let binary = locator.locate() else { return .notInstalled }
        let runner = makeRunner(binary)

        let version: ProtonCLIVersion
        do {
            version = try await runner.probeVersion()
        } catch ProtonCLIRunnerError.unsupportedVersion(let raw) {
            return .unsupportedVersion(raw)
        } catch ProtonCLIRunnerError.unparseableVersion {
            return .unparseableVersion
        } catch {
            return .error
        }

        do {
            _ = try ProtonReadModel.decodeVaults(try await runner.vaultListJSON())
        } catch ProtonCLIRunnerError.commandFailed {
            // A non-zero exit on a supported binary is taken as "no session".
            return .notAuthenticated
        } catch is ProtonReadModelError {
            return .error
        } catch {
            return .error
        }

        return .ready(
            version: version.raw,
            approvedPath: binary.approvedPath,
            resolvedRealPath: binary.resolvedRealPath
        )
    }

    // MARK: - Refresh

    /// Runs a full authoritative read: version gate, vault list, and one item
    /// list per vault, then seals the snapshot to the cache and returns
    /// projections. A cache write failure is non-fatal to the in-memory result.
    ///
    /// Secret fields are deliberately NOT fetched here. `item view` is one child
    /// process and one network round trip per item, so hydrating a whole vault
    /// up front made opening it take minutes on a real account while the UI sat
    /// on a spinner. Secrets are fetched on demand by `content(shareID:itemID:)`
    /// when an item is actually opened, which also keeps them out of the
    /// at-rest snapshot entirely.
    func refresh() async -> Result<ProtonRefreshResult, ProtonServiceError> {
        guard let binary = locator.locate() else { return .failure(.cliNotInstalled) }
        let runner = makeRunner(binary)

        let version: ProtonCLIVersion
        do {
            version = try await runner.probeVersion()
        } catch ProtonCLIRunnerError.unsupportedVersion(let raw) {
            return .failure(.unsupportedVersion(raw))
        } catch ProtonCLIRunnerError.unparseableVersion {
            return .failure(.unparseableVersion)
        } catch {
            return .failure(.executionFailed)
        }

        let vaults: [ProtonVault]
        do {
            vaults = try ProtonReadModel.decodeVaults(try await runner.vaultListJSON())
        } catch ProtonCLIRunnerError.commandFailed {
            return .failure(.notAuthenticated)
        } catch is ProtonReadModelError {
            return .failure(.unreadableOutput)
        } catch {
            return .failure(.executionFailed)
        }

        var items: [ProtonItem] = []
        for vault in vaults.prefix(Self.maximumVaults) {
            do {
                items.append(contentsOf: try ProtonReadModel.decodeItems(
                    try await runner.itemListJSON(shareID: vault.shareID),
                    shareID: vault.shareID,
                    vaultName: vault.name
                ))
            } catch ProtonCLIRunnerError.commandFailed {
                // A single unreadable vault is skipped, not fatal to the refresh.
                continue
            } catch is ProtonReadModelError {
                return .failure(.unreadableOutput)
            } catch {
                return .failure(.executionFailed)
            }
        }

        let snapshot = ProtonSnapshot(
            cliVersion: version.raw, capturedAt: now(), vaults: vaults, items: items
        )
        // Best-effort: a host without the device Keychain key still returns the
        // in-memory result; offline read simply won't be available until it can
        // seal.
        try? cache.save(snapshot, for: Self.accountID)

        return .success(ProtonRefreshResult(snapshot: snapshot, projections: projections(from: snapshot)))
    }

    // MARK: - Offline read

    /// The last sealed snapshot, if any, for offline listing without invoking
    /// the CLI. Returns nil when none exists or the seal cannot be opened.
    func cachedSnapshot() -> ProtonSnapshot? {
        try? cache.load(for: Self.accountID)
    }

    func projections(from snapshot: ProtonSnapshot) -> [VaultItemProjection] {
        let generation = Self.generation(for: snapshot)
        return snapshot.items.map {
            ProtonReadModel.projection(for: $0, account: Self.accountID, captureGeneration: generation)
        }
    }

    /// The decrypted detail for one item, resolved from a snapshot by its
    /// compound identity. `content` is the on-demand secret payload when it has
    /// already been fetched; without it the detail shows the item's non-secret
    /// fields only. Returns nil when the item is not in the snapshot.
    func detail(
        for itemID: VaultItemID,
        snapshot: ProtonSnapshot,
        content: ProtonItemContent? = nil
    ) -> VaultItemDetail? {
        guard let item = snapshot.items.first(where: { candidate in
            candidate.itemID == itemID.rawValue && candidate.shareID == Self.shareID(of: itemID)
        }) else {
            return nil
        }
        let resolved = content.map { item.merging($0) } ?? item
        return ProtonReadModel.detail(for: resolved, account: Self.accountID)
    }

    /// The share identifier for an item, for the on-demand content fetch.
    static func shareIdentifier(of itemID: VaultItemID) -> String? {
        shareID(of: itemID)
    }

    // MARK: - Private

    private func makeRunner(_ binary: ProtonCLIBinary) -> ProtonCLIRunner {
        ProtonCLIRunner(binary: binary, executor: executor, versionGate: versionGate)
    }

    /// Fetches one item's secret content on demand, for an item the user just
    /// opened. Returns nil when the CLI is gone, its version is no longer
    /// admitted, or the read fails — the caller then shows the item's
    /// non-secret fields rather than inventing a value.
    ///
    /// The version gate runs on this path too: it is the control that keeps
    /// VaultSquire from parsing an untested CLI's output, so a read never
    /// bypasses it. `--version` is a local call with no network round trip.
    func content(shareID: String, itemID: String) async -> ProtonItemContent? {
        guard let binary = locator.locate() else { return nil }
        let runner = makeRunner(binary)
        guard (try? await runner.probeVersion()) != nil else { return nil }
        guard let data = try? await runner.itemViewJSON(shareID: shareID, itemID: itemID) else {
            return nil
        }
        return try? ProtonReadModel.decodeItemContent(data)
    }

    private static func shareID(of itemID: VaultItemID) -> String? {
        if case .providerSpace(let shareID) = itemID.space.scope {
            return shareID
        }
        return nil
    }

    private static func generation(for snapshot: ProtonSnapshot) -> SnapshotGeneration {
        SnapshotGeneration(rawValue: UInt64(max(0, snapshot.capturedAt.timeIntervalSince1970)))
    }
}
