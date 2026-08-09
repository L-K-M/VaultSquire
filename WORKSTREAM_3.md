# Workstream 3 Vaultwarden Crypto Harness Record

- Status: implemented; automated exit criteria run in the `macOS Product` lane
  via `scripts/ci.sh`; the merged PR's green run is the controlling evidence
- Owner: `L-K-M`
- Started: 2026-08-05
- Scope: the pure Vaultwarden cryptographic surface only — key derivation,
  key hierarchy stretch and unwrap, authenticated `EncString`, and legacy
  detection. No network, persistence, Keychain, account, or UI work.

Workstream 3 adds no dependency. It performs no network or database I/O and
holds no session state; it exposes narrow operations that `VaultwardenProvider`
will call in later workstreams. No real vault or account data is valid test
input; every fixture is synthetic `VSQ-Canary` material.

## Implemented Surface

`VaultSquire/Providers/Vaultwarden/Crypto/`:

- **Key derivation** (`VaultwardenKeyDerivation`). PBKDF2-HMAC-SHA256 master
  key from the exact master-password bytes and the normalized-email salt
  (email trimmed and lowercased; the master password is never trimmed,
  normalized, or case-folded). The 1-iteration Base64 authentication hash the
  token grant carries. HKDF-SHA256 Expand-only stretch (master key as PRK, no
  extract, no salt) with info `enc` then `mac` into the 64-byte stretched key.
- **KDF validation** (`VaultwardenKDFConfiguration`). Reviewed floors and
  ceilings for PBKDF2 iterations (5,000 / 2,000,000) and Argon2id iterations
  (2 / 10), memory MiB (16 / 1,024), and parallelism (1 / 16), with a checked
  MiB→KiB conversion, validated before any allocation using non-trapping
  arithmetic so hostile prelogin values are errors, not crashes.
- **Argon2id fails closed.** Parameters are validated, then derivation throws
  `argon2idUnavailable`: no reviewed Argon2 implementation is adopted (see
  `docs/dependencies/argon2.md`), the account ciphertext is preserved, and
  PBKDF2 or weaker parameters are never substituted. Adoption is a separate
  dependency PR under ADR 0003.
- **Authenticated `EncString`** (`VaultwardenEncString`, `VaultwardenCipher`).
  Type-2 parse/verify/decrypt/encrypt: AES-256-CBC/PKCS7 under the first 32
  key bytes, HMAC-SHA256 over IV‖ciphertext under the last 32, verified in
  constant time (CryptoKit `isValidAuthenticationCode`) before any decryption.
  Serialization is `2.<b64 iv>|<b64 ct>|<b64 mac>`. Every MAC, padding, tag,
  or malformed-input failure returns one generic `integrityFailure` so no CBC
  oracle exists. Fresh CSPRNG IV per encryption; type 2 is the only emitted
  form.
- **Legacy and unknown handling.** Type 0 is detected and refused
  (`legacyEncryptionDetected`) with the ciphertext retained and no plaintext
  returned; asymmetric types 3–6 parse read-only; every other type fails
  closed (`unsupportedEncryptionType`) with no near-miss fallback.
- **Key unwrap** (`VaultwardenKeyUnwrap`). 64-byte user key from its type-2
  wrapping under the stretched master key (both legacy type-0 user-key
  lengths detected and refused); user RSA private key decryption; RSA-2048
  OAEP-SHA1 organization-key decapsulation through the user private key, with
  a strict definite-length DER reader that extracts the PKCS#1 key from the
  PKCS#8 rsaEncryption envelope.

Primitives come only from Apple system frameworks (CommonCrypto, CryptoKit,
Security) — OS-supplied surfaces, not dependency candidates under ADR 0003.
No cryptographic primitive is implemented from scratch. Best-effort
zeroization is provided, documented as best-effort, exercised by
`authenticationHash` on the derived buffer it solely owns, and covered by a
test; it is not a claim that no copy of key material survives elsewhere. The
64-byte composite key copies each half into its own zero-based buffer instead
of retaining index-inheriting `Data` slices. No logging event is added, so the
fixed-enum allowlist is unchanged.

## Fixtures

`scripts/generate-crypto-fixtures.py` (recipe revision 1) is the versioned
VaultSquire fixture recipe required by ADR 0005. It derives every expected
value from fixed synthetic `VSQ-Canary` inputs using the Python standard
library and the system OpenSSL tool, and emits
`VaultSquireTests/VaultwardenCryptoFixtures.swift`. All symmetric vectors are
deterministic and regenerable (`--check` verifies the committed file against
the recipe); the RSA key pair and OAEP ciphertext are synthetic fixture data
that is not byte-regenerable because OAEP encryption is randomized, and the
private-key PEM is kept outside the repository so no key block is committed.
No production data, provider source, or upstream test value is consulted or
copied.

## Exit Criteria

| Criterion | Evidence |
|---|---|
| Known-answer vectors for PBKDF2, auth hash, HKDF stretch, type-2 EncString, user-key unwrap, and RSA-2048 OAEP-SHA1 org-key unwrap | `VaultwardenKeyDerivationTests`, `VaultwardenEncStringTests`, `VaultwardenKeyUnwrapTests` (CRYPTO-01, CRYPTO-04) |
| No plaintext before authentication; one generic error for MAC/padding/tag/malformed | `VaultwardenEncStringTests` bit-flip, wrong-key, and malformed cases all assert `integrityFailure` (CRYPTO-02) |
| Legacy type-0 detected for both key lengths, retained, no plaintext | `VaultwardenKeyUnwrapTests` and `VaultwardenEncStringTests` (CRYPTO-03) |
| Unknown/unsupported types retained, never downgraded | `VaultwardenEncStringTests` unsupported-type and asymmetric cases (CRYPTO-05) |
| KDF bounds, overflow, and Argon2id fail-closed | `VaultwardenKeyDerivationTests` floor/ceiling and `argon2idUnavailable` cases |
| Bounded PR fuzz smoke over the base64/EncString parser and KDF arithmetic | `VaultwardenCryptoFuzzTests` (deterministic SplitMix64; extended fuzzing remains a scheduled lane) |

`IMPLEMENTATION_REPORT.md` records a further release-gated exit criterion —
every crypto fixture cross-decrypts with an official-client-created test
vault — which requires a live disposable Vaultwarden 1.37.1 instance and is
gathered on the pinned-container contract lane, not in PR CI. This PR's
known-answer vectors are self-consistent and independently derived; the
cross-client differential remains owed and is release evidence, not a merge
gate.

## Outstanding Workstream 1 Exit Evidence

Workstream 3 consumes no outstanding Workstream 1 evidence. Per
[ADR 0006](docs/adr/0006-workstream-1-merge-with-outstanding-evidence.md) and
[`WORKSTREAM_1.md`](WORKSTREAM_1.md), these rows remain owed, block Phase 0
certification and any release, and are restated here unchanged:

- Cold launch p95 at or below 750 ms on named baseline hardware.
- Warm Quick Search p95 at or below 100 ms on named baseline hardware.
- Keyboard focus and Escape dismissal manual confirmation.
- VoiceOver and Full Keyboard Access interactive test.
- Multiple Spaces and full-screen auxiliary presentation interactive test.
- Direct versus sandbox executable launch behavior on a disposable account.
- Direct versus sandbox session and keyring behavior (not implemented; blocks
  Workstream 10).
- Security-scoped bookmark round trip across launches (not implemented; blocks
  Workstream 10).
- Executable code signature and notarization status recorded at approval (not
  implemented; blocks Workstream 10).
- Generated 16/32/64 px icon review (assets derived and recorded in
  `ICON_PROVENANCE.md` on 2026-08-09; the 1:1 review remains owed).

The Phase 0 crypto proof additionally owes the pinned Vaultwarden 1.37.1
cross-client differential named above. Presence in `main` is not evidence
that a criterion passed; a row is marked passed only when the evidence exists.
