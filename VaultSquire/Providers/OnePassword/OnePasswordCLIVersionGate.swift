import Foundation

/// An exact CLI version token, e.g. `2.38.1`, as reported by the binary. The
/// raw string is compared verbatim against the allowlist: the gate never treats
/// a version as a range or infers compatibility across patch releases.
struct OnePasswordCLIVersion: Equatable, Hashable, Sendable {
    let raw: String
}

enum OnePasswordCLIVersionGateError: Error, Equatable, Sendable {
    /// The binary's `--version` output had no recognizable version token.
    case unparseableVersion
    /// The reported version is not in the tested allowlist. Carries the exact
    /// version so the UI can report which build was rejected, never a claim
    /// that a nearby version would work.
    case unsupportedVersion(String)
}

/// Fail-closed gate over the CLI's reported version. Only versions whose exact
/// command and JSON contracts have been declared tested are admitted; every
/// other build — including an unreleased patch and every beta — is unsupported
/// until added. An empty allowlist admits nothing
/// (ONEPASSWORD_CLI_RESEARCH.md §12).
struct OnePasswordCLIVersionGate: Sendable {
    let supportedVersions: Set<String>

    init(supportedVersions: Set<String>) {
        self.supportedVersions = supportedVersions
    }

    /// The stable releases this build maps against 1Password's documented
    /// `vault list` / `item list` / `item get` / `whoami` contract and its
    /// `--format json` switch, recorded in ONEPASSWORD_CLI_RESEARCH.md §1 and
    /// §8 from the published release history.
    ///
    /// Only stable releases appear. 2.36.x, 2.37.x, and 2.38.0 shipped as betas
    /// and are deliberately absent: a beta's machine output is not a contract.
    /// A 1.x build can never be admitted either, because CLI 2's noun-verb
    /// command surface is a documented breaking change from it.
    ///
    /// None of these has been exercised against a live CLI here, so a
    /// maintainer must confirm an installed build's machine output against
    /// `OnePasswordReadModel` on macOS. Output that does not match still fails
    /// closed with an honest error rather than a false success, and narrowing
    /// this set to an empty allowlist disables 1Password reads entirely.
    static let declaredSupportedVersions: Set<String> = [
        "2.33.1", "2.34.0", "2.34.1", "2.35.0", "2.38.1"
    ]

    /// The gate the app runs. Swapping to an empty set here disables 1Password
    /// reads entirely without touching any other code.
    static let production = OnePasswordCLIVersionGate(
        supportedVersions: declaredSupportedVersions
    )

    /// Admits a reported version or throws. An empty allowlist rejects every
    /// version, so a misconfigured gate can never silently admit an untested
    /// build.
    func admit(_ version: OnePasswordCLIVersion) throws {
        guard supportedVersions.contains(version.raw) else {
            throw OnePasswordCLIVersionGateError.unsupportedVersion(version.raw)
        }
    }

    /// Extracts the first version token from arbitrary `--version` output,
    /// tolerating surrounding text. Returns nil when none is present, which the
    /// caller maps to `unparseableVersion` and fails closed on.
    ///
    /// Any pre-release suffix is captured as part of the token rather than
    /// stripped, so `2.38.1-beta.01` is compared — and rejected — as itself
    /// instead of collapsing onto the allowlisted stable `2.38.1`. Shedding the
    /// suffix would let a beta inherit a tested release's admission, which is
    /// exactly what this gate exists to prevent.
    static func parseVersion(from output: String) -> OnePasswordCLIVersion? {
        guard let range = output.range(
            of: #"[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.]*)?"#,
            options: .regularExpression
        ) else {
            return nil
        }
        return OnePasswordCLIVersion(raw: String(output[range]))
    }
}
