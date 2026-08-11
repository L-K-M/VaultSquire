import Foundation

/// A resolved CLI binary: the allowlisted absolute path VaultSquire was
/// configured to invoke, and the symlink-resolved real path it points at. Both
/// are shown to the user during connection so a redirected or unexpected target
/// is visible rather than hidden behind the friendly path.
struct ProtonCLIBinary: Equatable, Sendable {
    /// The allowlisted discovery path shown to the user.
    let approvedPath: String
    /// The fully symlink-resolved real path, for display and signature review.
    let resolvedRealPath: String

    /// Execute the path whose symlink resolution was displayed and reviewed,
    /// not the mutable friendly symlink. A future live identity gate still
    /// revalidates the target immediately before every launch.
    var executableURL: URL {
        URL(fileURLWithPath: resolvedRealPath)
    }
}

/// Locates the user-installed CLI among a fixed allowlist of absolute paths.
/// It never searches `PATH`, never accepts a relative path, and resolves
/// symlinks so the real target is recorded. The install locations are where
/// the documented install methods place the `pass-cli` binary; a maintainer
/// adjusts the list rather than letting discovery roam the filesystem.
struct ProtonCLILocator: Sendable {
    /// Absolute candidate paths, tried in order: the Homebrew prefixes
    /// (`brew install protonpass/tap/pass-cli`) and the official install
    /// script's user-local location. The home directory is the account's real
    /// home, used for discovery only; execution always passes the resolved
    /// absolute path.
    static func defaultCandidatePaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/pass-cli",
            "/usr/local/bin/pass-cli",
            "\(home)/.local/bin/pass-cli",
            "\(home)/bin/pass-cli"
        ]
    }

    let candidatePaths: [String]
    private let isExecutable: @Sendable (String) -> Bool
    private let resolveRealPath: @Sendable (String) -> String

    init(
        candidatePaths: [String] = ProtonCLILocator.defaultCandidatePaths(),
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        resolveRealPath: @escaping @Sendable (String) -> String = {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
    ) {
        self.candidatePaths = candidatePaths
        self.isExecutable = isExecutable
        self.resolveRealPath = resolveRealPath
    }

    /// Returns the first allowlisted path that exists and is executable, with
    /// its symlink-resolved real path. A candidate whose resolved real path is
    /// not absolute is rejected: it can never become the executable of a
    /// no-shell process.
    func locate() -> ProtonCLIBinary? {
        for path in candidatePaths where path.hasPrefix("/") && isExecutable(path) {
            let real = resolveRealPath(path)
            guard real.hasPrefix("/") else { continue }
            return ProtonCLIBinary(approvedPath: path, resolvedRealPath: real)
        }
        return nil
    }
}

enum ProtonCLIRunnerError: Error, Equatable, Sendable {
    /// An opaque identifier failed validation (empty, too long, disallowed
    /// characters, or a leading dash that a parser could read as an option).
    case invalidIdentifier
    /// The CLI exited non-zero. Carries only the exit code; standard error
    /// content is never surfaced because it is treated as secret-bearing.
    case commandFailed(Int32)
    /// The `version` output contained no recognizable version token.
    case unparseableVersion
    /// The reported version is not in the tested allowlist.
    case unsupportedVersion(String)
    case execution(CLIExecutionError)
}

/// Drives the located binary through the executor with only fixed subcommands
/// and validated opaque identifiers. No method accepts a search term, secret,
/// user-authored field, item content, or credential, so nothing sensitive can
/// reach argv or the environment. Version probing runs through the fail-closed
/// gate; every read command runs only after the version is admitted by the
/// caller.
struct ProtonCLIRunner: Sendable {
    let binary: ProtonCLIBinary
    let executor: any CLIExecuting
    let versionGate: ProtonCLIVersionGate

    /// Maximum accepted length of an opaque identifier. Proton share and item
    /// identifiers are short base64url-style tokens; anything longer is treated
    /// as malformed input and refused.
    static let maximumIdentifierLength = 256

    init(
        binary: ProtonCLIBinary,
        executor: any CLIExecuting,
        versionGate: ProtonCLIVersionGate = .production
    ) {
        self.binary = binary
        self.executor = executor
        self.versionGate = versionGate
    }

    /// Runs the binary's `--version` output through the gate. Throws a
    /// runner error on an unparseable or unsupported version so the caller can
    /// present the exact state without any partial trust.
    func probeVersion() async throws -> ProtonCLIVersion {
        var execution = try await run(
            ["--version"], timeout: .seconds(10), outputLimit: 64 * 1024
        )
        defer { execution.discardStandardOutput() }
        let text = String(decoding: execution.standardOutput, as: UTF8.self)
        guard let version = ProtonCLIVersionGate.parseVersion(from: text) else {
            throw ProtonCLIRunnerError.unparseableVersion
        }
        do {
            try versionGate.admit(version)
        } catch ProtonCLIVersionGateError.unsupportedVersion(let raw) {
            throw ProtonCLIRunnerError.unsupportedVersion(raw)
        }
        return version
    }

    /// Fetches the raw JSON of the accessible vaults (documented as
    /// `pass-cli vault list --output json`). Parsing belongs to the read
    /// model; the runner only guarantees safe invocation and bounded output.
    func vaultListJSON() async throws -> Data {
        try await run(["vault", "list", "--output", "json"]).standardOutput
    }

    /// Fetches the raw JSON item summaries for one vault/share, selected by a
    /// validated opaque share identifier (documented as
    /// `pass-cli item list --share-id ID --output json`).
    func itemListJSON(shareID: String) async throws -> Data {
        try validateIdentifier(shareID)
        return try await run(
            ["item", "list", "--share-id", shareID, "--output", "json"]
        ).standardOutput
    }

    /// Fetches the raw JSON of one item, including secret fields the CLI prints
    /// to standard output (documented as
    /// `pass-cli item view --share-id ID --item-id ID --output json`). The
    /// bytes are bounded, held transiently, and never persisted raw or logged.
    func itemViewJSON(shareID: String, itemID: String) async throws -> Data {
        try validateIdentifier(shareID)
        try validateIdentifier(itemID)
        return try await run(
            ["item", "view", "--share-id", shareID, "--item-id", itemID, "--output", "json"]
        ).standardOutput
    }

    /// The single execution entry point. Maps executor errors and non-zero
    /// exits into runner errors; the caller never sees process internals.
    func run(
        _ arguments: [String],
        timeout: Duration = .seconds(20),
        outputLimit: Int = 4 * 1024 * 1024
    ) async throws -> CLIExecution {
        let invocation = CLIInvocation(
            arguments: arguments,
            timeout: timeout,
            outputLimit: outputLimit
        )
        var execution: CLIExecution
        do {
            execution = try await executor.execute(invocation, executableURL: binary.executableURL)
        } catch let error as CLIExecutionError {
            throw ProtonCLIRunnerError.execution(error)
        }
        guard execution.exitCode == 0 else {
            let exitCode = execution.exitCode
            execution.discardStandardOutput()
            throw ProtonCLIRunnerError.commandFailed(exitCode)
        }
        return execution
    }

    private func validateIdentifier(_ identifier: String) throws {
        guard Self.isValidOpaqueIdentifier(identifier) else {
            throw ProtonCLIRunnerError.invalidIdentifier
        }
    }

    /// A conservative allowlist for opaque identifiers. Because the executor
    /// runs no shell, the residual risk is option injection — an identifier the
    /// CLI's own parser reads as a flag — so a leading dash is refused and the
    /// character set is restricted to base64url-style tokens.
    static func isValidOpaqueIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty, identifier.count <= maximumIdentifierLength else {
            return false
        }
        guard identifier.first != "-" else { return false }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=")
        return identifier.allSatisfy { allowed.contains($0) }
    }
}
