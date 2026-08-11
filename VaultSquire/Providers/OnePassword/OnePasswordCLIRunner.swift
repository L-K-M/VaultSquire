import Foundation

/// A resolved CLI binary: the allowlisted absolute path VaultSquire was
/// configured to invoke, and the symlink-resolved real path it points at. Both
/// are shown to the user during connection so a redirected or unexpected target
/// is visible rather than hidden behind the friendly path.
struct OnePasswordCLIBinary: Equatable, Sendable {
    /// The allowlisted absolute path selected for invocation. Always the value
    /// actually passed to the process, so approval and execution cannot diverge.
    let approvedPath: String
    /// The fully symlink-resolved real path, for display and signature review.
    let resolvedRealPath: String

    var executableURL: URL {
        URL(fileURLWithPath: approvedPath)
    }
}

/// Locates the user-installed `op` binary among a fixed allowlist of absolute
/// paths. It never searches `PATH`, never accepts a relative path, and resolves
/// symlinks so the real target is recorded. The install locations are where
/// 1Password's documented install methods place the binary; a maintainer
/// adjusts the list rather than letting discovery roam the filesystem.
struct OnePasswordCLILocator: Sendable {
    /// Absolute candidate paths, tried in order. `/usr/local/bin/op` comes
    /// first because it is the documented canonical location: the `.pkg`
    /// installer's default, the exact path the upgrade instructions require,
    /// and the only location 1Password for Mac 8.10.12 and earlier will talk to
    /// (ONEPASSWORD_CLI_RESEARCH.md §10). The Homebrew Apple Silicon prefix
    /// follows.
    static func defaultCandidatePaths() -> [String] {
        [
            "/usr/local/bin/op",
            "/opt/homebrew/bin/op"
        ]
    }

    let candidatePaths: [String]
    private let isExecutable: @Sendable (String) -> Bool
    private let resolveRealPath: @Sendable (String) -> String

    init(
        candidatePaths: [String] = OnePasswordCLILocator.defaultCandidatePaths(),
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
    func locate() -> OnePasswordCLIBinary? {
        for path in candidatePaths where path.hasPrefix("/") && isExecutable(path) {
            let real = resolveRealPath(path)
            guard real.hasPrefix("/") else { continue }
            return OnePasswordCLIBinary(approvedPath: path, resolvedRealPath: real)
        }
        return nil
    }
}

enum OnePasswordCLIRunnerError: Error, Equatable, Sendable {
    /// An opaque identifier failed validation (empty, too long, disallowed
    /// characters, or a leading dash that a parser could read as an option).
    case invalidIdentifier
    /// The CLI exited non-zero. Carries only the exit code; standard error
    /// content is never surfaced because it is treated as secret-bearing.
    case commandFailed(Int32)
    /// The `--version` output contained no recognizable version token.
    case unparseableVersion
    /// The reported version is not in the tested allowlist.
    case unsupportedVersion(String)
    case execution(CLIExecutionError)
}

/// Drives the located `op` binary through the executor with only fixed
/// subcommands, fixed switches, and validated opaque identifiers. No method
/// accepts a search term, secret, user-authored field, item content, or
/// credential, so nothing sensitive can reach argv or the environment. Version
/// probing runs through the fail-closed gate; every read command runs only
/// after the version is admitted by the caller.
///
/// VaultSquire never collects a 1Password credential. Authentication is the
/// desktop app's business: `op` reaches it over XPC and the app prompts the
/// user for biometric authorization (ONEPASSWORD_CLI_RESEARCH.md §4). The
/// runner therefore has no sign-in command and no session concept at all.
struct OnePasswordCLIRunner: Sendable {
    let binary: OnePasswordCLIBinary
    let executor: any CLIExecuting
    let versionGate: OnePasswordCLIVersionGate
    /// The opaque account identifier to scope every command to, when one was
    /// resolved. Commands are always addressed to a named account rather than
    /// relying on "the most recently signed-in account", whose documented
    /// meaning differs between 1Password's own reference pages.
    let accountID: String?

    /// Maximum accepted length of an opaque identifier. 1Password item, vault,
    /// and account identifiers are short fixed-width alphanumeric tokens;
    /// anything longer is treated as malformed input and refused.
    static let maximumIdentifierLength = 256

    /// Read commands may block on the 1Password app's authorization prompt,
    /// which waits for the user's fingerprint, so they get a longer deadline
    /// than a purely local call. Lock, logout, and account removal still cancel
    /// and terminate the child immediately.
    static let readTimeout = Duration.seconds(60)
    /// `--version` is answered locally by the binary and never prompts.
    static let versionTimeout = Duration.seconds(15)

    init(
        binary: OnePasswordCLIBinary,
        executor: any CLIExecuting,
        versionGate: OnePasswordCLIVersionGate = .production,
        accountID: String? = nil
    ) {
        self.binary = binary
        self.executor = executor
        self.versionGate = versionGate
        self.accountID = accountID
    }

    /// Returns a copy scoped to a resolved account identifier. An identifier
    /// that fails validation is dropped rather than passed through, so a
    /// surprising `whoami` payload can never place an unvetted string in argv;
    /// the commands then fall back to the CLI's own default account.
    func scoped(toAccount identifier: String?) -> OnePasswordCLIRunner {
        let admissible = identifier.flatMap { Self.isValidOpaqueIdentifier($0) ? $0 : nil }
        return OnePasswordCLIRunner(
            binary: binary,
            executor: executor,
            versionGate: versionGate,
            accountID: admissible
        )
    }

    /// Runs the binary's `--version` output through the gate. Throws a runner
    /// error on an unparseable or unsupported version so the caller can present
    /// the exact state without any partial trust.
    func probeVersion() async throws -> OnePasswordCLIVersion {
        let execution = try await run(
            ["--version"], timeout: Self.versionTimeout, outputLimit: 64 * 1024, scoped: false
        )
        let text = String(decoding: execution.standardOutput, as: UTF8.self)
        guard let version = OnePasswordCLIVersionGate.parseVersion(from: text) else {
            throw OnePasswordCLIRunnerError.unparseableVersion
        }
        do {
            try versionGate.admit(version)
        } catch OnePasswordCLIVersionGateError.unsupportedVersion(let raw) {
            throw OnePasswordCLIRunnerError.unsupportedVersion(raw)
        }
        return version
    }

    /// Fetches the raw JSON of the accounts configured on this device
    /// (`op account list --format json`).
    ///
    /// This reads local configuration and needs no authorization, so it never
    /// raises the desktop app's prompt. It is deliberately unscoped: it is the
    /// call that *discovers* which accounts exist, so it cannot be addressed to
    /// one of them.
    ///
    /// `op whoami` is not used for this. It is a status query that reports
    /// "account is not signed in" rather than starting the authorization
    /// ceremony, so probing with it fails on every fresh session no matter how
    /// the machine is configured.
    func accountListJSON() async throws -> Data {
        try await run(["account", "list", "--format", "json"], scoped: false).standardOutput
    }

    /// Fetches the raw JSON of the vaults the account can read
    /// (`op vault list --account ID --format json`). Parsing belongs to the
    /// read model; the runner only guarantees safe invocation and bounded
    /// output.
    ///
    /// This is also the call that triggers authorization: unlike a status
    /// query, a real read makes the 1Password app raise its biometric prompt
    /// when the terminal session is not already authorized.
    func vaultListJSON() async throws -> Data {
        try await run(["vault", "list", "--format", "json"]).standardOutput
    }

    /// Fetches the raw JSON item summaries for one vault, selected by a
    /// validated opaque vault identifier
    /// (`op item list --vault ID --format json`).
    ///
    /// Archived items are deliberately not requested: they are excluded by the
    /// CLI's own default, VaultSquire has no unarchive action to offer for
    /// 1Password, and listing them beside active items would present an
    /// archived record as a live one.
    func itemListJSON(vaultID: String) async throws -> Data {
        try validateIdentifier(vaultID)
        return try await run(
            ["item", "list", "--vault", vaultID, "--format", "json"]
        ).standardOutput
    }

    /// Fetches the raw JSON of one item, including the secret field values the
    /// CLI prints to standard output
    /// (`op item get ID --vault ID --format json --reveal`). The bytes are
    /// bounded, held transiently, and never persisted raw or logged.
    ///
    /// `--reveal` is required because concealed fields are otherwise masked;
    /// whether that masking also applies to JSON output is undocumented, so the
    /// flag is passed rather than relying on a behavior no page states.
    func itemGetJSON(itemID: String, vaultID: String) async throws -> Data {
        try validateIdentifier(itemID)
        try validateIdentifier(vaultID)
        return try await run(
            ["item", "get", itemID, "--vault", vaultID, "--format", "json", "--reveal"]
        ).standardOutput
    }

    /// The single execution entry point. Maps executor errors and non-zero
    /// exits into runner errors; the caller never sees process internals.
    ///
    /// `scoped` appends the resolved `--account` selector. It is off only for
    /// `--version`, which reports the binary rather than an account.
    func run(
        _ arguments: [String],
        timeout: Duration = OnePasswordCLIRunner.readTimeout,
        outputLimit: Int = 4 * 1024 * 1024,
        scoped: Bool = true
    ) async throws -> CLIExecution {
        var arguments = arguments
        if scoped, let accountID {
            arguments.append(contentsOf: ["--account", accountID])
        }
        let invocation = CLIInvocation(
            arguments: arguments,
            timeout: timeout,
            outputLimit: outputLimit
        )
        let execution: CLIExecution
        do {
            execution = try await executor.execute(invocation, executableURL: binary.executableURL)
        } catch let error as CLIExecutionError {
            throw OnePasswordCLIRunnerError.execution(error)
        }
        guard execution.exitCode == 0 else {
            throw OnePasswordCLIRunnerError.commandFailed(execution.exitCode)
        }
        return execution
    }

    private func validateIdentifier(_ identifier: String) throws {
        guard Self.isValidOpaqueIdentifier(identifier) else {
            throw OnePasswordCLIRunnerError.invalidIdentifier
        }
    }

    /// A conservative allowlist for opaque identifiers. Because the executor
    /// runs no shell, the residual risk is option injection — an identifier the
    /// CLI's own parser reads as a flag — so a leading dash is refused and the
    /// character set is restricted to the alphanumeric tokens 1Password issues
    /// for items, vaults, and accounts.
    static func isValidOpaqueIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty, identifier.count <= maximumIdentifierLength else {
            return false
        }
        guard identifier.first != "-" else { return false }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=")
        return identifier.allSatisfy { allowed.contains($0) }
    }
}
