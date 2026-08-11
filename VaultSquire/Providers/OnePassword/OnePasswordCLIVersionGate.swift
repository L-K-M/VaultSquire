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
    /// bounded token, or `<invalid>` when retaining untrusted output would be
    /// unsafe; never claims a nearby version would work.
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

    /// Stable releases observed in provider documentation and retained only as
    /// future live-test candidates. They are not a production compatibility
    /// claim; beta releases and CLI 1.x remain excluded even from this list.
    static let documentedCandidateVersions: Set<String> = [
        "2.33.1", "2.34.0", "2.34.1", "2.35.0", "2.38.1"
    ]

    /// The gate the app runs. Production admits no build until the terms gate,
    /// TTY-less authorization spike, executable-identity check, and exact live
    /// command/schema matrix have all passed. A release number observed in
    /// documentation is only a candidate, never a tested compatibility claim.
    static let production = OnePasswordCLIVersionGate(supportedVersions: [])

    /// Admits a reported version or throws. An empty allowlist rejects every
    /// version, so a misconfigured gate can never silently admit an untested
    /// build.
    func admit(_ version: OnePasswordCLIVersion) throws {
        guard Self.isSafeVersion(version.raw) else {
            throw OnePasswordCLIVersionGateError.unsupportedVersion("<invalid>")
        }
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
            of: #"(?<![0-9])[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}(-[0-9A-Za-z][0-9A-Za-z.]{0,31})?(?![0-9A-Za-z.-])"#,
            options: .regularExpression
        ) else {
            return nil
        }
        let raw = String(output[range])
        guard isSafeVersion(raw) else { return nil }
        return OnePasswordCLIVersion(raw: raw)
    }

    private static func isSafeVersion(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.utf8.count <= 64 else { return false }
        return raw.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57)
                || ($0.value >= 65 && $0.value <= 90)
                || ($0.value >= 97 && $0.value <= 122)
                || $0.value == 45 || $0.value == 46
        }
    }
}
