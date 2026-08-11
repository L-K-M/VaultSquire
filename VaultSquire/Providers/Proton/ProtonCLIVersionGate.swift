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
    /// bounded token, or `<invalid>` when retaining untrusted output would be
    /// unsafe; never claims a nearby version would work.
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

    /// Releases observed in provider documentation and retained only as future
    /// live-test candidates. They are not a production compatibility claim.
    static let documentedCandidateVersions: Set<String> = ["2.2.3", "2.2.4"]

    /// The gate the app runs. No CLI build has completed the required live
    /// executable-identity, command, schema, cancellation, and sandbox matrix,
    /// so production must admit none. Documentation review is evidence for a
    /// future candidate; it is not an executed compatibility test.
    static let production = ProtonCLIVersionGate(supportedVersions: [])

    /// Admits a reported version or throws. An empty allowlist rejects every
    /// version, so a misconfigured gate can never silently admit an untested
    /// build.
    func admit(_ version: ProtonCLIVersion) throws {
        guard Self.isSafeVersion(version.raw) else {
            throw ProtonCLIVersionGateError.unsupportedVersion("<invalid>")
        }
        guard supportedVersions.contains(version.raw) else {
            throw ProtonCLIVersionGateError.unsupportedVersion(version.raw)
        }
    }

    /// Extracts the first dotted numeric version token (`MAJOR.MINOR.PATCH`)
    /// from arbitrary `version` output. Returns nil when none is present, which
    /// the caller maps to `unparseableVersion` and fails closed on.
    static func parseVersion(from output: String) -> ProtonCLIVersion? {
        guard let range = output.range(
            of: #"(?<![0-9])[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}(?![0-9A-Za-z.-])"#,
            options: .regularExpression
        ) else {
            return nil
        }
        let raw = String(output[range])
        guard isSafeVersion(raw) else { return nil }
        return ProtonCLIVersion(raw: raw)
    }

    private static func isSafeVersion(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.utf8.count <= 64 else { return false }
        return raw.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || $0.value == 46
        }
    }
}
