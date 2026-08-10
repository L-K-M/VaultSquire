import Foundation

/// An exact CLI version token, e.g. `2.2.4`, as reported by the binary. The raw
/// string is compared verbatim against the allowlist: the gate never treats a
/// version as a range or infers compatibility across patch releases.
struct ProtonCLIVersion: Equatable, Hashable, Sendable {
    let raw: String
}

enum ProtonCLIVersionGateError: Error, Equatable, Sendable {
    /// The binary's `version` output had no recognizable version token.
    case unparseableVersion
    /// The reported version is not in the tested allowlist. Carries the exact
    /// version so the UI can report which build was rejected, never a claim
    /// that a nearby version would work.
    case unsupportedVersion(String)
}

/// Fail-closed gate over the CLI's reported version. Only versions whose exact
/// command and JSON contracts have been declared tested are admitted; every
/// other build — including an unreleased patch — is unsupported until added.
/// An empty allowlist admits nothing (PROTON_PASS_RESEARCH.md §12).
struct ProtonCLIVersionGate: Sendable {
    let supportedVersions: Set<String>

    init(supportedVersions: Set<String>) {
        self.supportedVersions = supportedVersions
    }

    /// The versions whose documented `vault`/`item`/`version` contracts this
    /// build maps. A maintainer adds a version here only after confirming the
    /// installed CLI's machine output against the read model on macOS; anything
    /// else fails closed. These are the latest releases recorded in
    /// PROTON_PASS_RESEARCH.md at implementation time.
    static let declaredSupportedVersions: Set<String> = ["2.2.3", "2.2.4"]

    /// The gate the app runs. Swapping to an empty set here disables Proton
    /// reads entirely without touching any other code.
    static let production = ProtonCLIVersionGate(
        supportedVersions: declaredSupportedVersions
    )

    /// Admits a reported version or throws. An empty allowlist rejects every
    /// version, so a misconfigured gate can never silently admit an untested
    /// build.
    func admit(_ version: ProtonCLIVersion) throws {
        guard supportedVersions.contains(version.raw) else {
            throw ProtonCLIVersionGateError.unsupportedVersion(version.raw)
        }
    }

    /// Extracts the first dotted numeric version token (`MAJOR.MINOR.PATCH`)
    /// from arbitrary `version` output. Returns nil when none is present, which
    /// the caller maps to `unparseableVersion` and fails closed on.
    static func parseVersion(from output: String) -> ProtonCLIVersion? {
        guard let range = output.range(
            of: #"[0-9]+\.[0-9]+\.[0-9]+"#,
            options: .regularExpression
        ) else {
            return nil
        }
        return ProtonCLIVersion(raw: String(output[range]))
    }
}
