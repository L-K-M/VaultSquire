import Foundation

/// The outcome of probing the CLI for the connection pane. Every case is an
/// honest, non-secret state the UI can render directly; no case implies a
/// nearby version would work or that a credential was collected.
enum OnePasswordConnectionStatus: Equatable, Sendable {
    /// No allowlisted binary was found at any candidate path.
    case notInstalled
    /// A binary was found but its reported version is outside the tested
    /// allowlist. Carries the exact rejected version.
    case unsupportedVersion(String)
    /// The binary produced no recognizable version token.
    case unparseableVersion
    /// The binary is supported but could not obtain authorization from the
    /// 1Password desktop app. The app may not be running, CLI integration may
    /// be off, or the user may have declined or not answered the prompt — the
    /// CLI reports these the same way, and its standard error is treated as
    /// secret-bearing, so VaultSquire does not guess between them.
    case notAuthorized
    /// The binary is supported and authorized; reads are available.
    case ready(version: String, approvedPath: String, resolvedRealPath: String)
    /// The binary produced output VaultSquire could not read, or a command
    /// failed for a reason other than missing authorization.
    case error
}

enum OnePasswordServiceError: Error, Equatable, Sendable {
    case cliNotInstalled
    case unsupportedVersion(String)
    case unparseableVersion
    case notAuthorized
    case unreadableOutput
    case executionFailed
}

/// The result of a full read refresh: the sealed-ready snapshot and its display
/// projections.
struct OnePasswordRefreshResult: Sendable {
    let snapshot: OnePasswordSnapshot
    let projections: [VaultItemProjection]
}

/// Orchestrates the 1Password read flow end to end: locate the binary, gate its
/// version, confirm the desktop app authorized the CLI, list vaults, list items
/// per vault, publish a sealed lossy snapshot, and project items for display.
///
/// It is read-only — no method mutates a remote item — and every command runs
/// through `OnePasswordCLIRunner`, so nothing sensitive can reach argv or the
/// environment. VaultSquire never asks for a 1Password account password, Secret
/// Key, or one-time code: authorization is the desktop app's biometric prompt.
/// The other providers are unaffected; this is a self-contained vertical.
struct OnePasswordAccountService: Sendable {
    /// The single local 1Password account identity for this installation.
    static let accountID = AccountID(provider: .onePasswordCLI, rawValue: "onepassword-cli-primary")

    /// Read-only, matching the read model's capability set.
    static let capabilities = OnePasswordReadModel.capabilities

    /// The most vaults a single refresh will enumerate. Each vault costs one
    /// child process, so a pathological account cannot spawn an unbounded
    /// number — and 1Password's own guidance warns that listing costs one
    /// request per accessible vault.
    static let maximumVaults = 50

    let locator: OnePasswordCLILocator
    let executor: any CLIExecuting
    let versionGate: OnePasswordCLIVersionGate
    let cache: OnePasswordSnapshotCache
    private let now: @Sendable () -> Date

    init(
        locator: OnePasswordCLILocator = OnePasswordCLILocator(),
        executor: any CLIExecuting = OnePasswordAccountService.makeExecutor(),
        versionGate: OnePasswordCLIVersionGate = .production,
        cache: OnePasswordSnapshotCache = OnePasswordSnapshotCache(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.locator = locator
        self.executor = executor
        self.versionGate = versionGate
        self.cache = cache
        self.now = now
    }

    /// The production executor, pinned to desktop-app authentication.
    ///
    /// `OP_BIOMETRIC_UNLOCK_ENABLED=true` is the documented switch selecting the
    /// app integration, which is the only authentication mode VaultSquire
    /// permits: manual sign-in would put a session token in the environment or
    /// argv, and a service account would put a bearer token there, both of
    /// which are prohibited channels. Pinning it for the child process only is
    /// not a change to the user's own setting. The base environment is an
    /// allowlist, so no inherited `OP_SESSION`, `OP_SERVICE_ACCOUNT_TOKEN`, or
    /// `OP_CONNECT_TOKEN` can reach the child either.
    static func makeExecutor() -> any CLIExecuting {
        CLIProcessExecutor(environmentOverlay: ["OP_BIOMETRIC_UNLOCK_ENABLED": "true"])
    }

    // MARK: - Detection

    /// Probes the CLI for the connection pane without a full refresh: locate,
    /// gate the version, then confirm the desktop app authorizes it. Returns an
    /// honest status for every failure mode.
    func probeStatus() async -> OnePasswordConnectionStatus {
        guard let binary = locator.locate() else { return .notInstalled }
        let runner = makeRunner(binary)

        let version: OnePasswordCLIVersion
        do {
            version = try await runner.probeVersion()
        } catch OnePasswordCLIRunnerError.unsupportedVersion(let raw) {
            return .unsupportedVersion(raw)
        } catch OnePasswordCLIRunnerError.unparseableVersion {
            return .unparseableVersion
        } catch {
            return .error
        }

        do {
            _ = try await runner.whoAmIJSON()
        } catch OnePasswordCLIRunnerError.commandFailed {
            // A non-zero exit on a supported binary means the CLI could not get
            // authorization from the desktop app.
            return .notAuthorized
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

    /// Runs a full authoritative read: version gate, authorization probe, vault
    /// list, and one item list per vault, then seals the snapshot and returns
    /// projections. A cache write failure is non-fatal to the in-memory result.
    ///
    /// Secret fields are deliberately NOT fetched here. `op item get` is one
    /// child process — and, per 1Password's own request accounting, several
    /// server reads — per item, so hydrating a whole vault up front would make
    /// opening it slow and burn request budget. Secrets are fetched on demand
    /// by `content(itemID:vaultID:accountIdentifier:)` when an item is actually
    /// opened, which also keeps them out of the at-rest snapshot entirely.
    func refresh() async -> Result<OnePasswordRefreshResult, OnePasswordServiceError> {
        guard let binary = locator.locate() else { return .failure(.cliNotInstalled) }
        let unscoped = makeRunner(binary)

        let version: OnePasswordCLIVersion
        do {
            version = try await unscoped.probeVersion()
        } catch OnePasswordCLIRunnerError.unsupportedVersion(let raw) {
            return .failure(.unsupportedVersion(raw))
        } catch OnePasswordCLIRunnerError.unparseableVersion {
            return .failure(.unparseableVersion)
        } catch {
            return .failure(.executionFailed)
        }

        // Resolve the account first, then address every later command to it, so
        // a second signed-in account cannot answer a command meant for this one.
        let accountIdentifier: String?
        do {
            accountIdentifier = OnePasswordReadModel.decodeAccountID(try await unscoped.whoAmIJSON())
        } catch OnePasswordCLIRunnerError.commandFailed {
            return .failure(.notAuthorized)
        } catch {
            return .failure(.executionFailed)
        }
        let runner = unscoped.scoped(toAccount: accountIdentifier)

        let vaults: [OnePasswordVault]
        do {
            vaults = try OnePasswordReadModel.decodeVaults(try await runner.vaultListJSON())
        } catch OnePasswordCLIRunnerError.commandFailed {
            return .failure(.notAuthorized)
        } catch is OnePasswordReadModelError {
            return .failure(.unreadableOutput)
        } catch {
            return .failure(.executionFailed)
        }

        var items: [OnePasswordItem] = []
        for vault in vaults.prefix(Self.maximumVaults) {
            do {
                items.append(contentsOf: try OnePasswordReadModel.decodeItems(
                    try await runner.itemListJSON(vaultID: vault.vaultID),
                    vaultID: vault.vaultID,
                    vaultName: vault.name
                ))
            } catch OnePasswordCLIRunnerError.commandFailed,
                    OnePasswordCLIRunnerError.invalidIdentifier {
                // A single unreadable vault is skipped, not fatal to the
                // refresh: a vault the account cannot list, one whose
                // identifier the build will not accept for `--vault`, or one
                // whose identifier failed validation before any command ran,
                // should not cost the user every other vault. A malformed
                // payload is different and still fails the refresh below,
                // because that means the decoder itself may be wrong.
                continue
            } catch is OnePasswordReadModelError {
                return .failure(.unreadableOutput)
            } catch {
                return .failure(.executionFailed)
            }
        }

        let snapshot = OnePasswordSnapshot(
            cliVersion: version.raw,
            accountIdentifier: runner.accountID,
            capturedAt: now(),
            vaults: vaults,
            items: items
        )
        // Best-effort: a host without the device Keychain key still returns the
        // in-memory result; offline read simply won't be available until it can
        // seal.
        try? cache.save(snapshot, for: Self.accountID)

        return .success(OnePasswordRefreshResult(
            snapshot: snapshot, projections: projections(from: snapshot)
        ))
    }

    // MARK: - Offline read

    /// The last sealed snapshot, if any, for offline listing without invoking
    /// the CLI. Returns nil when none exists or the seal cannot be opened.
    func cachedSnapshot() -> OnePasswordSnapshot? {
        try? cache.load(for: Self.accountID)
    }

    func projections(from snapshot: OnePasswordSnapshot) -> [VaultItemProjection] {
        let generation = Self.generation(for: snapshot)
        return snapshot.items.map {
            OnePasswordReadModel.projection(
                for: $0, account: Self.accountID, captureGeneration: generation
            )
        }
    }

    /// The detail for one item, resolved from a snapshot by its compound
    /// identity. `content` is the on-demand secret payload when it has already
    /// been fetched; without it the detail shows the item's non-secret fields
    /// only. Returns nil when the item is not in the snapshot.
    func detail(
        for itemID: VaultItemID,
        snapshot: OnePasswordSnapshot,
        content: OnePasswordItemContent? = nil
    ) -> VaultItemDetail? {
        guard let item = snapshot.items.first(where: { candidate in
            candidate.itemID == itemID.rawValue && candidate.vaultID == Self.vaultID(of: itemID)
        }) else {
            return nil
        }
        return OnePasswordReadModel.detail(for: item, account: Self.accountID, content: content)
    }

    /// The vault identifier for an item, for the on-demand content fetch.
    static func vaultIdentifier(of itemID: VaultItemID) -> String? {
        vaultID(of: itemID)
    }

    /// Fetches one item's secret content on demand, for an item the user just
    /// opened. Returns nil when the CLI is gone, its version is no longer
    /// admitted, or the read fails — the caller then shows the item's
    /// non-secret fields rather than inventing a value.
    ///
    /// The version gate runs on this path too: it is the control that keeps
    /// VaultSquire from parsing an untested CLI's output, so a read never
    /// bypasses it. `--version` is answered locally with no round trip and no
    /// authorization prompt. The account identifier comes from the snapshot the
    /// item was listed in, so the read cannot be answered by a different
    /// signed-in account.
    func content(
        itemID: String,
        vaultID: String,
        accountIdentifier: String?
    ) async -> OnePasswordItemContent? {
        guard let binary = locator.locate() else { return nil }
        let runner = makeRunner(binary)
        guard (try? await runner.probeVersion()) != nil else { return nil }
        let scoped = runner.scoped(toAccount: accountIdentifier)
        guard let data = try? await scoped.itemGetJSON(itemID: itemID, vaultID: vaultID) else {
            return nil
        }
        return try? OnePasswordReadModel.decodeItemContent(data)
    }

    // MARK: - Private

    private func makeRunner(_ binary: OnePasswordCLIBinary) -> OnePasswordCLIRunner {
        OnePasswordCLIRunner(binary: binary, executor: executor, versionGate: versionGate)
    }

    private static func vaultID(of itemID: VaultItemID) -> String? {
        if case .providerSpace(let vaultID) = itemID.space.scope {
            return vaultID
        }
        return nil
    }

    private static func generation(for snapshot: OnePasswordSnapshot) -> SnapshotGeneration {
        SnapshotGeneration(rawValue: UInt64(max(0, snapshot.capturedAt.timeIntervalSince1970)))
    }
}
