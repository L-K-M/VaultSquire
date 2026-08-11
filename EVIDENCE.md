# External Evidence Register

- Owner: `L-K-M`
- Baseline date: 2026-07-31
- Status: protocol and compatibility evidence only

These revisions document observed public behavior. They are not product
dependencies or permission to copy source expression. Implementation consumes
the approved requirements and independently generated fixtures, not these source
repositories.

## Vaultwarden And Bitwarden

| Evidence | Exact identity | Purpose | License boundary |
|---|---|---|---|
| Vaultwarden | Release `1.37.1`; commit `2629bcbe1380c894e3a7f52cafcac3988edb8fbb` | Initial server contract target | AGPL-3.0; evidence only |
| Vaultwarden container | `docker.io/vaultwarden/server:1.37.1@sha256:ebdfe70701c60ac0c28c697e787cea767d7972940b786037b29fe0d507f821e8` | OCI multi-platform integration-test input | Pull by digest; do not treat tag as immutable |
| Container Linux `amd64` manifest | `sha256:e9efdf001bf0d68c21f2cbfb8e1d9b5961a7ca9c85e0a7e58bf51a13b997d744` | Hosted test-server architecture | Container runtime input only |
| Container Linux `arm64` manifest | `sha256:2bfaa5744f8bf4b407145cf698405372057091958e9508887746f279df522219` | Hosted test-server architecture | Container runtime input only |
| Bitwarden clients | `cfc7e4d3376127713dafa7a5924a17f4d101a05f` | Public client protocol/behavior evidence | GPL-3.0 outside restricted paths; evidence only |
| Bitwarden server | `85890318551ee8a2036bfbfb3c1135b98f1a4dce` | Comparison and trademark evidence | AGPL-3.0 outside restricted paths; evidence only |
| Bitwarden internal SDK | `4bf6b5b58f4a099e2a39ff230d5804396560aff8` | Format/model evidence | GPL-3.0 or SDK License with restricted paths excluded; never adopt |
| Vaultwarden wiki | `82490385e58ccc6e32707c0621ff15828e6616ab` | Operational context | License not recorded; do not copy expression |

Canonical origins:

- <https://github.com/dani-garcia/vaultwarden/releases/tag/1.37.1>
- <https://hub.docker.com/v2/repositories/vaultwarden/server/tags/1.37.1>
- <https://github.com/bitwarden/clients/tree/cfc7e4d3376127713dafa7a5924a17f4d101a05f>
- <https://github.com/bitwarden/server/tree/85890318551ee8a2036bfbfb3c1135b98f1a4dce>
- <https://github.com/bitwarden/sdk-internal/tree/4bf6b5b58f4a099e2a39ff230d5804396560aff8>

## Proton CLI And Public Research

| Evidence | Exact identity | Purpose | License boundary |
|---|---|---|---|
| Proton Pass CLI candidate | Release `2.2.3`; tag commit `554fa9217c9451c3accaa52ad39d9141a9089911` | Initial command/schema research candidate; not supported | GPL-3.0; user-installed process only |
| CLI 2.2.3 macOS arm64 | SHA-256 `8318e5af39d899780214ec62c6d1c2cfdc7628bb2036dba8f72af74c9a63c732` | Candidate executable artifact | Identity/signature/notarization still unapproved |
| CLI 2.2.3 macOS x86_64 | SHA-256 `2babdfaf4badf1c428d66acd784377e5a9312c8a35b1fb6dea19e7eb051ae839` | Research comparison only | Initial VaultSquire app is arm64-only |
| Proton Pass CLI drift candidate | Release `2.2.4`; commit `f03ec43268d190102e4039f11cfeafedfa7e049b` | Explicitly unsupported until tests pass | GPL-3.0 |
| CLI 2.2.4 macOS arm64 | SHA-256 `0ed5dcc0256969ea7438f90530edef2c960dc1f06d0a5ea39d56a3e1c3125924` | Drift fixture candidate | Not a supported executable |
| Proton iOS | `9f0a0f6399154943c561ebcdae718da04905c007` | Public model/sync research | GPL-3.0; evidence only |
| Proton Android | `cb4bc258f5b3e4091548a66215f3d23e3506366e` | License evidence | GPL-3.0; evidence only |
| Proton Pass common | `65bb8448a41098686c9305265d2312c79d4dcef8` | License/internal-package evidence | GPL-3.0; evidence only |
| Proton item schema | `8c88394ed97752e4a8c00cb2e1c4e495bd9a505b` | Schema research | No detected license; never copy or generate product models from it |

Canonical CLI releases:

- <https://github.com/protonpass/pass-cli/releases/tag/2.2.3>
- <https://github.com/protonpass/pass-cli/releases/tag/2.2.4>

No Proton version is supported yet. Release tags are not sufficient executable
identity. Workstream 10 must record selected path, resolved path, hash, code
signature/team/notarization result, exact version output, schemas, and capability
manifest revision from clean-Mac tests.

## 1Password CLI

This provider has no immutable pin and cannot have one. The `op` binary is
proprietary, 1Password publishes no source repository for it, and its API and
SDK Terms prohibit reverse engineering. Its evidence is therefore documentation
only, and is weaker than every other row in this file.

| Evidence | Exact identity | Purpose | License boundary |
|---|---|---|---|
| 1Password CLI documentation | `www.1password.dev`, captured 2026-08-11; no archive hash | Command, JSON, and authentication research | Proprietary; documentation only, never copied into product code |
| 1Password CLI release history | `app-updates.agilebits.com/product_history/CLI2`, captured 2026-08-11 | Version allowlist source; latest stable `2.38.1` (2026-07-30) | Proprietary; mutable page |
| API and SDK Terms of Service | `1password.com/legal/api-sdk-terms-of-service`, last updated 2026-06-16 | Licensing and competing-product analysis | Proprietary; unresolved release gate |
| Terms of Service | `1password.com/legal/terms-of-service`, last updated 2024-09-12 | Automation and redistribution analysis | Proprietary |

No 1Password version is supported yet, and no executable identity has been
recorded. The allowlisted stable releases in
`OnePasswordCLIVersionGate.declaredSupportedVersions` come from the release
history above, not from a tested binary. Before release, record the selected
path, resolved path, hash, code-signature and notarization result, exact
`--version` output, observed JSON schemas, and the `whoami` payload from
clean-Mac tests — and resolve the terms question in
[`ONEPASSWORD_CLI_RESEARCH.md`](ONEPASSWORD_CLI_RESEARCH.md) §14.

## Unresolved Evidence

- Exact Xcode, Swift compiler, macOS SDK build, and Apple Team ID await a real
  macOS implementation environment.
- `Bitwarden-Client-Version` remains unset until contract tests justify an exact
  compatibility declaration.
- Official-client binary identities and synthetic fixture-generator revisions
  must be recorded with the fixture PRs that use them.
- Mutable provider documentation and terms need archive hashes where they become
  release-critical. The whole 1Password evidence base is of that kind, and its
  terms question is already release-critical.
- The 1Password CLI's TTY-less authorization behavior, and whether App Sandbox
  permits reaching its desktop app, are unmeasured. No evidence exists either
  way until a clean-Mac spike runs.
- Evidence with unknown or restricted licenses remains non-copyable even when it
  is useful to explain a protocol fact.

## Update Policy

Revalidate immutable objects before every compatibility change and release.
Record moved tags or changed registry manifests as a supply-chain incident; do
not silently replace a pin. New evidence updates requirements only through a
reviewed documentation PR with corresponding fixture and support-policy changes.
