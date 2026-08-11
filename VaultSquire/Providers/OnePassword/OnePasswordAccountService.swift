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
    /// The binary is supported but no 1Password account is set up on this
    /// device, so there is nothing to open.
    case noAccounts
    /// The binary is supported and at least one account is configured. Each
    /// account can be opened as its own vault.
    ///
    /// Detection deliberately stops here rather than proving authorization:
    /// confirming it would mean running a real read, which raises the desktop
    /// app's biometric prompt. Prompting merely because the user opened the Add
    /// Account sheet would be rude, so authorization happens when a vault is
    /// actually opened.
    case ready(
        version: String,
        accounts: [OnePasswordAccount],
        approvedPath: String,
        resolvedRealPath: String
    )
    /// The binary produced output VaultSquire could not read, or a command
    /// failed for a reason other than a missing account.
    case error
}

enum OnePasswordServiceError: Error, Equatable, Sendable {
    case cliNotInstalled
    case unsupportedVersion(String)
    case unparseableVersion
    /// The desktop app did not authorize the read: it may be locked, CLI
    /// integration may be off, or the prompt may have been declined or left
    /// unanswered. The CLI reports these the same way, and its standard error
    /// is treated as secret-bearing, so VaultSquire does not guess between them.
    case notAuthorized
    /// The account identifier this vault was configured with is no longer one
    /// the CLI will accept, so no command can be safely addressed to it.
    case unusableAccount
    case unreadableOutput
    case executionFailed
    case localStorageFailed
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
    /// The local identity for one 1Password account, keyed by the CLI's own
    /// opaque account identifier.
    ///
    /// A person can have several 1Password accounts signed in at once — a
    /// personal one and a work one is ordinary — so each becomes its own vault
    /// rather than one of them being silently chosen. The account is part of
    /// the compound identity, which is what keeps two accounts' items distinct
    /// even when they share vault names.
    static func vaultIdentity(for accountUUID: String) -> AccountID {
        AccountID(provider: .onePasswordCLI, rawValue: accountUUID)
    }

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
        CLIProcessExecutor(mode: .onePasswordDesktopAuthorization)
    }

    // MARK: - Detection

    /// Probes the CLI for the connection pane: locate it, gate its version, and
    /// enumerate the accounts configured on this device.
    ///
    /// It deliberately does NOT prove authorization. Proving it means running a
    /// real read, which raises the 1Password app's biometric prompt, and
    /// prompting merely because someone opened the Add Account sheet would be
    /// rude. Authorization is established when a vault is actually opened.
    ///
    /// `op whoami` is not used here or anywhere. It is a status query: with no
    /// established session it reports "account is not signed in" instead of
    /// starting the ceremony, so probing with it fails on every fresh session
    /// however the machine is configured.
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

        let accounts: [OnePasswordAccount]
        do {
            var data = try await runner.accountListJSON()
            defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
            accounts = try OnePasswordReadModel.decodeAccounts(data)
        } catch is OnePasswordReadModelError {
            return .error
        } catch {
            // `account list` reads local configuration and needs no
            // authorization, so a failure here is a broken install or an
            // unreadable config, not a refused prompt.
            return .error
        }

        guard !accounts.isEmpty else { return .noAccounts }

        return .ready(
            version: version.raw,
            accounts: accounts,
            approvedPath: binary.approvedPath,
            resolvedRealPath: binary.resolvedRealPath
        )
    }

    // MARK: - Refresh

    /// Runs a full authoritative read for one account: version gate, vault
    /// list, and one item list per vault, then seals the snapshot and returns
    /// projections. Publication requires that sealed cache commit to succeed.
    ///
    /// The vault list is also what establishes authorization — a real read is
    /// what makes the 1Password app raise its prompt — so a refusal surfaces
    /// here rather than during detection.
    ///
    /// Secret fields are deliberately NOT fetched. `op item get` is one child
    /// process — and, per 1Password's own request accounting, several server
    /// reads — per item, so hydrating a whole vault up front would make opening
    /// it slow and burn request budget. Secrets are fetched on demand by
    /// `content(itemID:vaultID:accountUUID:)` when an item is actually opened,
    /// which also keeps them out of the at-rest snapshot entirely.
    func refresh(
        accountUUID: String
    ) async -> Result<OnePasswordRefreshResult, OnePasswordServiceError> {
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

        // Every account-bearing command names this account explicitly, so a
        // second signed-in account can never answer one meant for this vault.
        let runner = unscoped.scoped(toAccount: accountUUID)
        guard runner.accountID != nil else { return .failure(.unusableAccount) }

        let vaults: [OnePasswordVault]
        do {
            var data = try await runner.vaultListJSON()
            defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
            vaults = try OnePasswordReadModel.decodeVaults(data)
        } catch OnePasswordCLIRunnerError.commandFailed {
            // The first real read is where authorization is decided, so a
            // non-zero exit here means the desktop app did not grant it.
            return .failure(.notAuthorized)
        } catch is OnePasswordReadModelError {
            return .failure(.unreadableOutput)
        } catch {
            return .failure(.executionFailed)
        }

        var items: [OnePasswordItem] = []
        for vault in vaults.prefix(Self.maximumVaults) {
            guard !Task.isCancelled else { return .failure(.executionFailed) }
            do {
                var data = try await runner.itemListJSON(vaultID: vault.vaultID)
                defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
                items.append(contentsOf: try OnePasswordReadModel.decodeItems(
                    data,
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

        guard !Task.isCancelled else { return .failure(.executionFailed) }
        let snapshot = OnePasswordSnapshot(
            cliVersion: version.raw,
            accountIdentifier: accountUUID,
            capturedAt: now(),
            vaults: Array(vaults.prefix(Self.maximumVaults)),
            items: items
        )
        // Publish only a complete generation that has already been sealed and
        // atomically committed. A failed cache write leaves the prior snapshot
        // usable and cannot create a visible-only generation.
        do {
            try cache.save(snapshot, for: Self.vaultIdentity(for: accountUUID))
        } catch {
            return .failure(.localStorageFailed)
        }

        return .success(OnePasswordRefreshResult(
            snapshot: snapshot,
            projections: projections(from: snapshot, accountUUID: accountUUID)
        ))
    }

    // MARK: - Offline read

    /// The last sealed snapshot for one account, if any, for offline listing
    /// without invoking the CLI. Returns nil when none exists or the seal
    /// cannot be opened.
    func cachedSnapshot(accountUUID: String) -> OnePasswordSnapshot? {
        let account = Self.vaultIdentity(for: accountUUID)
        guard OnePasswordCLIRunner.isValidOpaqueIdentifier(accountUUID),
              let snapshot = try? cache.load(for: account),
              snapshot.accountIdentifier == accountUUID,
              (try? versionGate.admit(OnePasswordCLIVersion(raw: snapshot.cliVersion))) != nil else {
            return nil
        }
        return snapshot
    }

    func projections(
        from snapshot: OnePasswordSnapshot,
        accountUUID: String
    ) -> [VaultItemProjection] {
        let generation = Self.generation(for: snapshot)
        let identity = Self.vaultIdentity(for: accountUUID)
        return snapshot.items.map {
            OnePasswordReadModel.projection(
                for: $0, account: identity, captureGeneration: generation
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
        // The item's own compound identity names the account, so a detail is
        // always built for the vault the item was actually listed in.
        return OnePasswordReadModel.detail(for: item, account: itemID.account, content: content)
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
    /// authorization prompt. The account comes from the vault the item was
    /// listed in, so the read cannot be answered by a different signed-in
    /// account.
    func content(
        itemID: String,
        vaultID: String,
        accountUUID: String
    ) async -> OnePasswordItemContent? {
        guard let binary = locator.locate() else { return nil }
        let runner = makeRunner(binary)
        guard (try? await runner.probeVersion()) != nil else { return nil }
        let scoped = runner.scoped(toAccount: accountUUID)
        guard scoped.accountID != nil else { return nil }
        guard !Task.isCancelled,
              var data = try? await scoped.itemGetJSON(
            itemID: itemID, vaultID: vaultID
        ) else {
            return nil
        }
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        guard !Task.isCancelled else { return nil }
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
