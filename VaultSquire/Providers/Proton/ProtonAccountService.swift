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

    /// The most items whose secret fields are hydrated with a per-item read
    /// during one refresh. Beyond this, items are kept as list summaries so a
    /// very large vault cannot spawn an unbounded number of child processes.
    static let maximumHydratedItems = 500

    let locator: ProtonCLILocator
    let executor: any ProtonCLIExecuting
    let versionGate: ProtonCLIVersionGate
    let cache: ProtonSnapshotCache
    private let now: @Sendable () -> Date

    init(
        locator: ProtonCLILocator = ProtonCLILocator(),
        executor: any ProtonCLIExecuting = ProtonCLIProcessExecutor(),
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

    /// Runs a full authoritative read: version gate, vault list, per-vault item
    /// list, bounded secret hydration, then seals the snapshot to the cache and
    /// returns projections. A cache write failure is non-fatal to the in-memory
    /// result.
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
        var hydrationBudget = Self.maximumHydratedItems
        for vault in vaults {
            let vaultItems: [ProtonItem]
            do {
                vaultItems = try ProtonReadModel.decodeItems(
                    try await runner.itemListJSON(shareID: vault.shareID),
                    shareID: vault.shareID,
                    vaultName: vault.name
                )
            } catch ProtonCLIRunnerError.commandFailed {
                // A single unreadable vault is skipped, not fatal to the refresh.
                continue
            } catch is ProtonReadModelError {
                return .failure(.unreadableOutput)
            } catch {
                return .failure(.executionFailed)
            }
            items.append(contentsOf: await hydrate(vaultItems, runner: runner, budget: &hydrationBudget))
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
    /// compound identity. Returns nil when the item is not in the snapshot.
    func detail(for itemID: VaultItemID, snapshot: ProtonSnapshot) -> VaultItemDetail? {
        guard let item = snapshot.items.first(where: { candidate in
            candidate.itemID == itemID.rawValue && candidate.shareID == Self.shareID(of: itemID)
        }) else {
            return nil
        }
        return ProtonReadModel.detail(for: item, account: Self.accountID)
    }

    // MARK: - Private

    private func makeRunner(_ binary: ProtonCLIBinary) -> ProtonCLIRunner {
        ProtonCLIRunner(binary: binary, executor: executor, versionGate: versionGate)
    }

    private func hydrate(
        _ items: [ProtonItem],
        runner: ProtonCLIRunner,
        budget: inout Int
    ) async -> [ProtonItem] {
        var result: [ProtonItem] = []
        result.reserveCapacity(items.count)
        for item in items {
            guard budget > 0 else {
                result.append(item)
                continue
            }
            budget -= 1
            if let data = try? await runner.itemViewJSON(shareID: item.shareID, itemID: item.itemID),
               let content = try? ProtonReadModel.decodeItemContent(data) {
                result.append(item.merging(content))
            } else {
                result.append(item)
            }
        }
        return result
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
