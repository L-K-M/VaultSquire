# VaultSquire Vaultwarden Client Implementation Report

- Status: pinned research and implementation evidence; subordinate to
  `PLAN.md`, `ARCHITECTURE.md`, and `SECURITY_AND_TESTING.md`
- Target: Vaultwarden 1.37.1
- Research cutoff: 2026-07-31
- Primary target revision: `2629bcbe1380c894e3a7f52cafcac3988edb8fbb`

## Executive Decision

For its Vaultwarden provider, VaultSquire should independently implement the
private client API rather than Bitwarden's Public API. The Public API does not
manage individual vault items, while the documented Vault Management API is a
local HTTP facade started by the official Bitwarden CLI. Neither is the remote
protocol implemented by normal vault clients. [D: Password Manager APIs](https://bitwarden.com/help/bitwarden-apis.md) [D: Public API](https://bitwarden.com/help/public-api/)

This report is the low-level Vaultwarden evidence catalog for the selected
clean-room native implementation. The controlling product sequence is
[`PLAN.md`](PLAN.md). Keyguard is permanently rejected and source-excluded under
[`KEYGUARD_FORK_ASSESSMENT.md`](KEYGUARD_FORK_ASSESSMENT.md). Proton Pass is the
selected second provider through the official user-installed CLI; required reads
and per-command secret-safe write gates are defined in
[`PROTON_PASS_RESEARCH.md`](PROTON_PASS_RESEARCH.md).

The Vaultwarden-specific delivery sequence is deliberately narrower than the
full server:

| Decision | Recommendation |
|---|---|
| Server target | Vaultwarden 1.37.1 only, with explicit compatibility probes |
| Account encryption | Implement current authenticated V1; detect but reject legacy type-0 and V2 account state |
| Core vault items | Read in the first preview; add tested online writes in the next phase |
| Offline behavior | Allow offline unlock and read except after a durably observed key-hierarchy rotation; do not queue offline mutations |
| Synchronization | Treat `GET /api/sync` as authoritative and notifications as invalidation hints |
| Conflicts | Preflight the latest cipher, use the server guard, disclose its nearly two-second acceptance window, and never blindly retry |
| Local storage | Store canonical Vaultwarden server ciphertext; never persist plaintext fields or live keys |
| Attachments | Authenticate the complete ciphertext before producing any plaintext |
| Organizations | Decrypt organization items and enforce server-returned collection restrictions |
| Registration | Defer until login, sync, crypto, and recovery paths are mature |
| Naming | Keep original VaultSquire identity/artwork; do not use vendor or third-party client logos, assets, or trade dress |

The principal engineering risk is not HTTP plumbing. It is preserving cryptographic and synchronization invariants while following an API that is intentionally compatible but not publicly versioned. Vaultwarden itself describes its interface as an alternative implementation of the Bitwarden client API. [VW: README](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/README.md#L1-L35)

## Evidence Legend

| Label | Meaning |
|---|---|
| `[D]` | Public product or API documentation |
| `[VW]` | Behavior in pinned Vaultwarden 1.37.1 source |
| `[C]` | Behavior in the pinned official clients source |
| `[SDK]` | Cryptographic behavior in the pinned SDK source |
| `[UP]` | Comparison with the pinned upstream server source |
| `[I]` | Design recommendation or inference for VaultSquire |
| `[U]` | Private or unstable behavior that must be verified by compatibility tests |

Public documentation links were accessed on 2026-07-31. Source links are immutable commit permalinks.

Uncited prescriptive statements using "should" or "must" are `[I]` recommendations. A source citation establishes observed behavior at the pinned revision, not a stability promise.

## Source Baseline

| Repository | Revision | Use |
|---|---|---|
| `dani-garcia/vaultwarden` | tag `1.37.1`, commit `2629bcbe1380c894e3a7f52cafcac3988edb8fbb` | Target server behavior |
| `bitwarden/clients` | `cfc7e4d3376127713dafa7a5924a17f4d101a05f` | Client transport, sync, and notification behavior |
| `bitwarden/server` | `85890318551ee8a2036bfbfb3c1135b98f1a4dce` | Upstream comparison and licensing |
| `bitwarden/sdk-internal` | `4bf6b5b58f4a099e2a39ff230d5804396560aff8` | Cryptographic formats and current API models |
| `dani-garcia/vaultwarden.wiki` | `82490385e58ccc6e32707c0621ff15828e6616ab` | Operational context only |

Vaultwarden's `/api/config` reports an upstream compatibility version, currently `2026.6.0`; this is not the Vaultwarden release number. Its source says clients use this value for compatibility decisions. [VW: config response](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/mod.rs#L210-L262)

## Compatibility Boundary

The remote vault protocol is private and has no published compatibility contract. `[U]` applies to behavior outside the pinned source and black-box fixtures, including:

- Independent-client values for `Bitwarden-Client-Name` and `Bitwarden-Client-Version`.
- Future interpretation of `/api/config` feature states and compatibility version.
- Future account-encryption V2 routes, upgrade requirements, and downgrade behavior.
- Future write support for cipher types 6 through 8.
- Proxy-specific WebSocket, path-prefix, and cross-origin service arrangements.
- Whether a failed non-idempotent request committed before the connection failed.
- Error status, body casing, and aliases not represented by the pinned test corpus.

The implementation must therefore preserve unknown response data, avoid speculative capabilities, and reconcile ambiguous writes through authoritative reads.

## Vaultwarden Provider Internals

### Components

Within `VaultwardenProvider`, use a small set of hard boundaries rather than
allowing UI code to call the protocol directly. The complete two-provider
application architecture, including `ProtonCLIProvider` and `ProcessRunner`, is
defined in [`ARCHITECTURE.md`](ARCHITECTURE.md).

| Component | Responsibility | Must not do |
|---|---|---|
| Environment | Normalize the user-entered base URL and derive service URLs | Hold tokens or keys |
| Transport | HTTPS, headers, bearer tokens, refresh, retries, errors, upload/download | Decrypt vault data |
| Protocol models | Loss-tolerant wire parsing and exact request serialization | Contain UI state |
| Crypto core | KDF, key hierarchy, `EncString`, RSA, attachment and Send crypto | Perform network or database I/O |
| Account session | Logged-out, locked, and unlocked state transitions | Persist raw master or user keys |
| Vault repository | Per-account canonical ciphertext and revision metadata | Store plaintext fields |
| Sync engine | Revision checks, aggregate replacement, targeted refresh, notifications | Merge competing ciphertext automatically |
| Mutation service | Validate permission, encrypt full object, write, reconcile response | Queue offline writes in the MVP |
| Attachment service | Encrypt, upload, download, authenticate, and atomically publish files | Expose unauthenticated plaintext |
| Presentation | Decrypted views while unlocked and policy-aware actions | Retain keys after lock |

### Vaultwarden Session State

Model network authentication and vault unlock separately.

| State | Access token | Refresh token | User/org keys | Allowed work |
|---|---:|---:|---:|---|
| Logged out | No | No | No | Discovery, prelogin, login |
| Authenticated and locked | Optional/in memory | OS credential store | No | Refresh tokens, download encrypted sync data |
| Unlocked | In memory | OS credential store | In protected process memory | Decrypt, search, copy, and mutate |

Locking must deterministically release references to the master key, user key,
private RSA key, organization keys, cipher keys, Send keys, attachment keys,
decrypted object graph, and in-memory search index, and best-effort overwrite
application-owned mutable secret buffers. Swift and framework copies cannot be
guaranteed to zeroize. Logging out must additionally remove tokens, device
session state, and the account cache. The master password must never be stored.
This matches the documented distinction that a derived encryption key exists in
memory only while unlocked. [D: Security FAQs](https://bitwarden.com/help/security-faqs/#q-is-my-bitwarden-master-password-stored-locally)

### Vaultwarden Local Store

Store the Vaultwarden server response in its encrypted form and preserve
unrecognized JSON fields. A practical per-account schema is:

| Table | Canonical data |
|---|---|
| `account` | Server URLs, normalized email, KDF parameters, wrapped user key, wrapped private key, public key, security stamp, last successful sync time |
| `organization` | Organization response JSON and RSA-wrapped organization key |
| `folder` | ID, revision, encrypted name, raw response JSON |
| `collection` | ID, organization ID, encrypted name, ACL flags, raw response JSON |
| `cipher` | ID, revision, deletion date, ownership IDs, raw encrypted response JSON |
| `send` | ID, revision and raw encrypted response JSON |
| `pending_file` | Upload/download operation state and encrypted temporary-file path only |

Database-level encryption is required because IDs, URLs, timestamps, ownership,
and access patterns are metadata, even when Vaultwarden fields remain encrypted.
It is defense in depth, not a substitute for the protocol's end-to-end
encryption. Proton CLI output follows a different rule: it is decrypted, lossy
JSON that must be validated and immediately AEAD-wrapped by VaultSquire before
persistence. It is never provider-native ciphertext or a source for writes.

Do not persist a decrypted search index. Build an in-memory index after unlock and destroy it on lock. Preserve malformed or unsupported encrypted records in the database and show a per-item compatibility error instead of dropping them during sync.

## Environment and Transport

### Service Discovery

Given a normalized base URL `B`, derive these defaults:

| Service | Default |
|---|---|
| Web/base | `B` |
| API | `B/api` |
| Identity | `B/identity` |
| Icons | `B/icons` |
| Notifications | `B/notifications` |
| Events | `B/events` |

These are the official self-hosted defaults; explicitly supplied advanced URLs take precedence. [C: environment derivation](https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/common/src/platform/services/default-environment.service.ts#L369-L490)

Fetch `GET {API}/config` before login and retain the complete response. Vaultwarden returns environment URLs, registration status, push technology, feature states, server identity, and its compatibility version. [C: config request](https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/common/src/platform/services/config/config-api.service.ts#L6-L20) [VW: config response](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/mod.rs#L210-L262)

Security rules for environment data:

- Require HTTPS outside an explicit local-development mode.
- Normalize trailing slashes without changing a configured path prefix.
- Validate every returned service URL before use.
- Never forward a bearer token to a different origin through a redirect.
- Permit cross-origin Azure-style presigned uploads only when the upload type says Azure, and send no Vaultwarden bearer token there.
- Display and obtain approval for effective API and identity origins before
  prelogin sends the email when either differs from the entered origin.
- Approve a different notifications origin before the first token-bearing
  connection and an upload origin before sending data. Approval creates a
  role-specific allowlist entry; it never permits cross-origin redirects.
- Derive the icons URL for completeness only. VaultSquire does not call the icon
  service by default, because each request discloses a plaintext item domain to
  the server operator and its network path; see the icon rule in
  [`SECURITY_AND_TESTING.md`](SECURITY_AND_TESTING.md#network-and-self-hosted-servers).

### Headers and Version Signaling

Send these headers consistently:

| Header | Value |
|---|---|
| `Authorization` | `Bearer <access token>` on protected API requests |
| `Device-Type` | Numeric device type selected for the platform |
| `Bitwarden-Client-Name` | A stable VaultSquire client identifier |
| `Bitwarden-Client-Version` | Independently validated compatibility declaration; value unresolved in Phase 0 `[U]` |
| `User-Agent` | `VaultSquire/<application version>` where the platform permits it |
| `Cache-Control` | `no-store` on GET |
| `Pragma` | `no-cache` on GET |

Official clients reject non-HTTPS URLs outside development, disable GET caching, and attach platform headers. [C: fetch and headers](https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/common/src/services/api.service.ts#L1320-L1388)

Do not put VaultSquire's normal `0.x` application version into
`Bitwarden-Client-Version`. Vaultwarden uses that header as an upstream feature
version; for example, it suppresses SSH keys below `2024.12.0`. [VW: sync
version gate](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/ciphers.rs#L121-L137)
Do not mirror the server's advertised maximum `2026.6.0`: that could opt the
client into response shapes it has not implemented. Phase 0 must test a matrix
of candidate values and select the lowest declaration that enables every
implemented feature. Keep application and protocol versions separate and
advance the declaration only after the compatibility suite passes.

### Token Refresh

Use one in-flight refresh operation per account. Requests waiting on an expiring token should share it. A protected request that receives `401` may refresh once and retry once. Do not automatically retry a non-idempotent request after an ambiguous network failure, because the server may already have committed it.

Refresh `invalid_grant` is an account-session failure, not a transient network
failure. Remove network credentials and move to `reauthenticationRequired`, but
do not silently delete a last known-good encrypted cache unless the server sent
an explicit revocation/logout signal whose policy requires deletion. Vaultwarden
returns two-hour access tokens and creates 30-day refresh tokens, or 90-day
refresh tokens for mobile device types. [VW: token
validity](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/auth.rs#L40-L47)
[VW: token
creation](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/auth.rs#L1250-L1298)

## Authentication

### Password Login Sequence

1. Fetch configuration without transmitting the email or password-derived data.
2. Resolve and approve any effective identity/API origin change.
3. Normalize the email with `trim()` and lowercase it.
4. Send `POST {IDENTITY}/accounts/prelogin/password` with JSON
   `{ "email": normalizedEmail }` to the approved origin.
5. Accept the legacy alias `POST {IDENTITY}/accounts/prelogin` as a fallback.
6. Validate KDF parameters against safe lower and upper bounds.
7. Derive the 32-byte master key locally.
8. Derive the server-authentication hash locally.
9. Send a form-urlencoded password grant to `POST {IDENTITY}/connect/token`.
10. If the response requests 2FA, collect the selected proof and repeat the
    password grant with the 2FA fields.
11. Store the returned refresh token in the OS credential store and keep the
    access token in memory.
12. Decrypt the wrapped user key and initialize the unlocked key hierarchy.

Vaultwarden exposes both prelogin routes and the single token route. [VW: identity routes](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/identity.rs#L44-L59) [VW: prelogin aliases](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/identity.rs#L1026-L1034)

The password grant is form-urlencoded:

| Field | Required value |
|---|---|
| `grant_type` | `password` |
| `username` | Normalized email |
| `password` | Base64 server-authentication hash, never the master password |
| `scope` | `api offline_access` |
| `client_id` | `desktop`; never `mobile`, `cli`, or another class |
| `device_identifier` | Persistent random UUID for this installation/account context |
| `device_name` | User-visible device name |
| `device_type` | Numeric platform type |
| `two_factor_provider` | Provider ID when responding to a challenge |
| `two_factor_token` | Provider proof when responding to a challenge |
| `two_factor_remember` | `1` only when the user chooses remember-me |

Vaultwarden validates the grant, exact scope, and device fields before password login. [VW: token dispatch](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/identity.rs#L59-L126) [VW: form aliases](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/identity.rs#L1105-L1154)

The device identifier should be generated once with a cryptographically secure random UUID and retained. VaultSquire is a macOS desktop application: it sends `Device-Type: 7` (macOS desktop) and `client_id=desktop`, and it must not send any other value. Vaultwarden's device-type enum also defines SDK `21`, Server `22`, Windows CLI `23`, macOS CLI `24`, Linux CLI `25`, and DuckDuckGo browser `26`. The CLI values classify terminal clients and gate CLI-specific behavior, so sending `24` would misclassify the application. Do not claim a mobile device type (Android `0`, iOS `1`) to obtain the 90-day mobile refresh-token validity. Unknown future device-type values on the server must not affect client behavior; VaultSquire always sends its fixed desktop declaration. [VW: device types](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/db/models/device.rs#L275-L365)

### Login Response

The success response contains OAuth fields plus encryption bootstrap material. Parse both the current structured fields and legacy aliases:

| Field | Use |
|---|---|
| `access_token`, `refresh_token`, `expires_in`, `token_type`, `scope` | Network session |
| `Kdf`, `KdfIterations`, `KdfMemory`, `KdfParallelism` | Legacy KDF representation |
| `Key` | Master-key-wrapped user key |
| `PrivateKey` | User-key-encrypted RSA private key |
| `AccountKeys.publicKeyEncryptionKeyPair` | Current V1 private/public key representation |
| `UserDecryptionOptions.MasterPasswordUnlock` | Current KDF, salt, and wrapped user key representation |
| `TwoFactorToken` | Remember-me token, when requested and allowed |

Vaultwarden emits these structures directly. [VW: authenticated response](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/identity.rs#L484-L581)

### Two-Factor Authentication

A missing proof or invalid provider selection can return an HTTP `400` identity
error with `error: "invalid_grant"`, `error_description`, and optional
`TwoFactorProviders`/`TwoFactorProviders2` challenge maps. A submitted but failed
TOTP or other validator may return a generic `400` without those maps. Parse
challenge fields only when present and use the local login state to distinguish
a failed submitted proof from a bad password. [VW: 2FA
challenge](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/identity.rs#L913-L1023)

| ID | Provider | MVP behavior |
|---:|---|---|
| 0 | Authenticator/TOTP | Support |
| 1 | Email | Support; call `/api/two-factor/send-email-login` for current clients |
| 2 | Duo | Parse and report unsupported initially |
| 3 | YubiKey OTP | Parse and report unsupported initially; add with hardware tests |
| 4 | Legacy U2F | Parse; do not newly implement |
| 5 | Remember token | Support internally |
| 6 | Organization Duo | Parse and report unsupported initially |
| 7 | WebAuthn | Support after browser/native credential integration is tested |
| 8 | Recovery code | Support with an explicit destructive warning |

The IDs are fixed in Vaultwarden's model. [VW: 2FA IDs](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/db/models/two_factor.rs#L27-L48) The login validator handles TOTP, WebAuthn, YubiKey, Duo, email, remember tokens, and recovery codes. [VW: 2FA validation](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/identity.rs#L775-L906)

WebAuthn as a second factor is supported. Passkey login is a different feature and is not supported by Vaultwarden 1.37.1; its compatibility route intentionally returns an empty list. [VW: passkey-login placeholder](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/mod.rs#L198-L207)

### Refresh and Logout

Refresh with the same identity endpoint:

```text
grant_type=refresh_token
refresh_token=<token>
client_id=<same client class>
```

Invalid or missing refresh tokens return HTTP `400` and
`{"error":"invalid_grant"}`. A successful refresh returns a refresh JWT that
must atomically replace the locally stored value. At this target, the JWT is
signed from the unchanged device token, so the prior JWT can remain usable until
expiry or device revocation; do not rely on one-time rotation or reuse
detection. [VW: refresh
behavior](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/identity.rs#L152-L190)

Normal logout is local token and key destruction. Account-wide deauthorization is represented by security-stamp rotation and logout notifications. Do not invent a remote logout endpoint.

## Encryption V1

### KDF

KDF IDs are PBKDF2-SHA256 `0` and Argon2id `1`. The normalized email is the salt input.

PBKDF2 derivation:

```text
masterKey = PBKDF2-HMAC-SHA256(
  password = UTF8(masterPassword),
  salt = UTF8(trim(lowercase(email))),
  iterations = prelogin.kdfIterations,
  outputLength = 32
)
```

Argon2id derivation:

```text
argonSalt = SHA256(UTF8(trim(lowercase(email))))
masterKey = Argon2id-v1.3(
  password = UTF8(masterPassword),
  salt = argonSalt,
  iterations = prelogin.kdfIterations,
  memoryKiB = prelogin.kdfMemory * 1024,
  parallelism = prelogin.kdfParallelism,
  outputLength = 32
)
```

The pinned SDK implements this normalization, PBKDF2 minimum, Argon2 salt hashing, and 32-byte output. [SDK: KDF implementation](https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/crates/bitwarden-crypto/src/keys/kdf.rs#L14-L99)

Use these defensive limits:

| Parameter | Prelogin minimum | Official setting maximum/safety threshold | New-account default |
|---|---:|---:|---:|
| PBKDF2 iterations | 5,000 | 2,000,000 | 600,000 |
| Argon2 iterations | 2 | 10 | 6 |
| Argon2 memory MiB | 16 | 1,024 | 32 |
| Argon2 parallelism | 1 | 16 | 4 |

The official client model distinguishes permissive prelogin minimums from stricter settings used when changing the KDF. [C: KDF ranges](https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/key-management/src/models/kdf-config.ts#L14-L159) The maximum column is a setting maximum and recommended default safety threshold, not evidence that prelogin rejects every larger value. Fail before unsafe allocation with a clear diagnostic; any configurable override needs an explicit resource warning and hard process limit.

The minimum column is a security control in the opposite direction and deserves
equal weight. Prelogin parameters are attacker-controlled if the configured
server is hostile or compromised, and returning the permissive floor makes the
master key and the server-authentication hash cheap to attack offline. Persist
the last accepted algorithm and parameters per account, require explicit user
confirmation before deriving after any algorithm or parameter difference, and
refuse anything below the reviewed floor outright. This intentionally avoids
inventing an ordering for cross-algorithm or mixed-parameter changes. Unchanged
settings need no prompt. A first login has no baseline to compare against, which
is a documented residual.

### Server-Authentication Hash

The token endpoint receives a proof derived from the master key and master password:

```text
authHash = Base64(
  PBKDF2-HMAC-SHA256(
    password = masterKey[32],
    salt = UTF8(masterPassword),
    iterations = 1,
    outputLength = 32
  )
)
```

The SDK's server-authorization purpose is numeric value `1` and is passed as the PBKDF2 iteration count. [SDK: master-key hash](https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/crates/bitwarden-crypto/src/keys/master_key.rs#L23-L25) [SDK: derivation](https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/crates/bitwarden-crypto/src/keys/master_key.rs#L75-L85)

### Key Hierarchy

```text
master password + normalized email
  -> KDF
  -> 32-byte master key
  -> HKDF-SHA256-Expand only, PRK = master key, info "enc" and "mac"
  -> 64-byte stretched master key
  -> decrypt current type-2 wrapped 64-byte user key

legacy path observed by the reference implementation
  -> raw 32-byte master key
  -> decrypt type-0 wrapped 32-byte or 64-byte user key

user key
  -> decrypt user RSA private key
  -> decrypt or wrap personal cipher keys
  -> decrypt RSA-wrapped organization keys through the private key

organization key
  -> decrypt or wrap organization cipher keys

resolved cipher key
  -> decrypt item fields
  -> encrypt attachment filename and attachment key
```

The master key stretch is HKDF-Expand only, as defined in RFC 5869 section 2.3.
The 32-byte master key is used directly as the PRK; there is no extract step and
no salt. Two independent expands produce 32 bytes each, with `info` = `enc` and
`info` = `mac`, concatenated into the 64-byte stretched key. An implementation
that applies RFC 5869 end to end, extracting with an empty salt before expanding,
derives different bytes and every user-key unwrap fails. [SDK:
key stretch](https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/crates/bitwarden-crypto/src/keys/utils.rs#L9-L17)
New V1 user keys are random AES-256-CBC-HMAC composite keys encrypted under the
stretched master key. The reference also recognizes legacy type-0 wrappers under
the raw master key and legacy 32-byte user keys. [SDK: user-key
wrapping](https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/crates/bitwarden-crypto/src/keys/master_key.rs#L156-L204)

VaultSquire's initial product policy is stricter than the reference: detect the
legacy type-0 path, retain the ciphertext, and ask the user to migrate with a
compatible client. Do not return unauthenticated legacy plaintext. Keep fixtures
for both legacy key lengths so detection does not misclassify the account. Emit
only the current 64-byte/type-2 form when a later write phase creates keys.

The V1 asymmetric pair is RSA-2048. The public key is Base64 SPKI DER; the private key is PKCS#8 DER encrypted as an `EncString` under the user key. RSA sharing uses OAEP-SHA1 for the current V1 key path. [SDK: RSA key pair](https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/crates/bitwarden-crypto/src/rsa.rs#L13-L70) Organization keys are decapsulated through the user private key. [SDK: organization key initialization](https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/crates/bitwarden-core/src/client/encryption_settings.rs#L84-L130)

### EncString

Vaults primarily use type `2`:

```text
2.<base64(iv)>|<base64(ciphertext)>|<base64(mac)>
```

Parameters:

| Part | Rule |
|---|---|
| Encryption key | First 32 bytes of the 64-byte composite key |
| MAC key | Last 32 bytes of the 64-byte composite key |
| Cipher | AES-256-CBC with random 16-byte IV and PKCS7 padding |
| MAC | HMAC-SHA256 over `IV \|\| ciphertext` |
| Verification | Constant-time MAC comparison before CBC decryption |

The serialization and type numbers are fixed by the SDK. Type `0` is legacy
unauthenticated AES-CBC; the initial product detects but does not decrypt it.
Symmetric type `7` is a newer COSE envelope and is outside the V1 write target.
[SDK: EncString
format](https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/crates/bitwarden-crypto/src/enc_string/symmetric.rs#L36-L83)
[SDK: parser](https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/crates/bitwarden-crypto/src/enc_string/symmetric.rs#L133-L164)

The authenticated construction is encrypt-then-MAC over the IV and ciphertext. [SDK: AES-CBC-HMAC](https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/crates/bitwarden-crypto/src/hazmat/symmetric_encryption/aes256_cbc_hmac_sha256_ae.rs#L1-L98)

The parser should accept legacy asymmetric `EncString` types `3` through `6` for existing shared material, but V1 emission should use the format proven by compatibility fixtures. Unknown types must fail closed for that object while retaining its original ciphertext.

### Account Encryption V2 Decision

Do not implement V2 account creation or rotation for Vaultwarden 1.37.1.

The upstream server has V2 account state, signing keys, signed public keys, security state, and V1-to-V2 upgrade-token handling. [UP: V2 rotation](https://github.com/bitwarden/server/blob/85890318551ee8a2036bfbfb3c1135b98f1a4dce/src/Core/KeyManagement/UserKey/Implementations/RotateUserAccountKeysCommand.cs#L168-L293) The SDK likewise models bidirectional upgrade tokens. [SDK: V2 upgrade token](https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/crates/bitwarden-core/src/key_management/v2_upgrade_token.rs#L23-L182)

Vaultwarden's user schema has only `akey`, `private_key`, `public_key`, and KDF fields. It has no V2 security-state or signature-key storage. [VW: user schema](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/db/schema.rs#L192-L220) Its current account rotation request contains only the V1 wrapped private key and public key. [VW: rotation model](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/accounts.rs#L761-L803)

Ordinary V1 profiles can contain V2-named fields such as `signedPublicKey`,
`securityState`, and `signatureKeyPair` with null values. Field presence alone
is not a V2 discriminator. Phase 0 must pin V1 fixtures containing those nulls
and define V2 only from a tested semantic version/state or non-null structure.
When the bootstrap cannot be represented safely, preserve the response, show an
unsupported-account message, and never downgrade or rewrite it.

## Sync and Concurrency

### Aggregate Sync

`GET {API}/sync` is the authoritative snapshot. Vaultwarden returns:

| Root field | Content |
|---|---|
| `profile` | Account, key material, organizations, and security stamp |
| `folders` | User folders |
| `collections` | Visible collection details and restrictions |
| `policies` | Applicable organization policies |
| `ciphers` | Visible personal and organization vault items |
| `domains` | Equivalent-domain settings unless excluded |
| `sends` | User Sends |
| `userDecryption` | Current master-password unlock data |

The target source constructs this snapshot from the user's visible records. [VW: aggregate sync](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/ciphers.rs#L115-L203)

Use this algorithm:

1. Keep the last observed server revision separately from local scheduling times.
2. For a non-forced check, call `GET {API}/accounts/revision-date`.
3. If that server-derived value equals the stored server-derived revision, stop.
4. For a full sync, read `revisionBefore` from the server.
5. Fetch and parse `/sync` without discarding unknown fields.
6. Read `revisionAfter` from the server.
7. If the two server revisions differ, discard the candidate and retry a bounded
   number of times; retain the prior snapshot if matching revisions are not
   reached.
8. If they match, replace folders, collections, ciphers, Sends, policies,
   domains, and profile and store `revisionAfter` in one database transaction.
9. Rebuild decrypted views only if the account is unlocked.

Vaultwarden's revision endpoint returns `user.updated_at` in epoch milliseconds.
Never compare it to a client-clock timestamp; a Mac clock ahead of the server
could suppress later changes indefinitely. [VW: revision
date](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/accounts.rs#L1257-L1262)
The official client checks that watermark before fetching and then replaces its
logical datasets. [C: revision-gated
sync](https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/common/src/platform/sync/default-sync.service.ts#L133-L237)
The matching-before/after check and one local transaction are stronger
VaultSquire requirements for watermarked account changes. Initial login,
explicit full refresh, periodic repair, and broad
organization/policy/settings invalidations force `/sync` because not every
relevant change reliably advances the user revision.

Matching account revisions do not prove server-side snapshot isolation.
Unwatermarked organization, policy, or settings updates can race while the
server constructs the response. Treat a committed `/sync` result as a complete
best-effort response and use periodic forced sync plus future broad
notifications for eventual repair. Permission-sensitive mutations must be
revalidated online; cached read permissions may be stale offline.

Master-password, KDF, and key-hierarchy changes made on another client surface
in `profile` and `userDecryption`. Before committing a full-sync candidate,
compare its KDF parameters, wrapped user key, wrapped private key, and security
stamp with the current bootstrap data. When they differ, do not promote the
candidate. First reject new secret operations, invalidate any live session
generation, and enter the locked rotation transition; only then persist
`reauthenticationRequired` while retaining the current snapshot and bootstrap
data, invalidate quick unlock, and discard the candidate. The full
re-authentication transaction validates the replacement hierarchy and commits it
with a newly fetched full snapshot before clearing the marker.

After the marker commits, failure, cancellation, or process death leaves the
prior generation intact and the marker set. A marker-write failure leaves the
running process locked; death before that durable boundary is equivalent to a
client that did not observe the rotation. The previous password is blocked after
rotation has been durably observed, while an unobserved rotation cannot prevent
ordinary offline unlock of the pre-rotation snapshot. Never carry the previous
hierarchy's in-memory user key across the replacement transaction or promote
changed bootstrap data before its key hierarchy is authenticated.

A locked client may still synchronize ciphertext. Official documentation also states that the currently active account can sync while locked. [D: vault sync](https://bitwarden.com/help/vault-sync/#manual-sync)

### Targeted Refresh

Notifications may trigger these optimizations:

| Notification | Action |
|---|---|
| Cipher create/update | Compare item revision, then `GET /api/ciphers/{id}` |
| Cipher delete | Delete local item |
| Folder create/update | Compare revision, then `GET /api/folders/{id}` |
| Folder delete | Delete local folder |
| Send create/update | Compare revision, then `GET /api/sends/{id}` |
| Send delete | Delete local Send |
| Broad vault/settings/org/policy | Revision-gated full sync; force when account revision may not change |
| Logout | Lock and terminate the account session according to reason |

This mirrors the official targeted-fetch behavior. [C: targeted sync](https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/common/src/platform/sync/core-sync.service.ts#L93-L218) [C: Send targeted sync](https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/common/src/platform/sync/core-sync.service.ts#L221-L272)

Always force a full sync after notification transport connection or
reconnection. Events can be lost while disconnected, and the official client
performs catch-up sync on connection. [C: reconnect catch-up](https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/common/src/platform/server-notifications/internal/default-server-notifications.service.ts#L149-L173)

### Cipher Stale Writes

Immediately before an existing-cipher write, fetch the latest cipher and compare
its exact server revision with the edit base. Then include that server-provided
ISO 8601 value as `lastKnownRevisionDate`. Vaultwarden rejects when
`serverUpdatedAt - lastKnownRevisionDate`, truncated to whole seconds, is
greater than `1`. Missing values are accepted for older clients, so omission is
not safe conflict handling. The check is directional, so a future client
timestamp is not rejected; send the server revision verbatim. [VW: stale
check](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/ciphers.rs#L420-L433)

The preflight narrows but cannot eliminate the race between that read and the
write. Because a positive delta is truncated and rejected only when greater than
one, a stale delta just under two seconds can pass. Product claims and tests must
disclose this residual; do not claim linearizable writes.

Conflict flow:

1. Stop retrying the write.
2. Fetch the latest remote cipher.
3. Retain the user's unsaved plaintext only in memory.
4. Show remote and local versions with timestamps.
5. Let the user discard local changes, copy fields manually, or explicitly overwrite after re-encrypting against the newest revision.
6. Record no plaintext conflict copy on disk.

Do not perform field-level automatic merges of ciphertext. A cipher write replaces the encrypted object, and a merge can resurrect deleted values or bypass organization-policy changes.

The current attachment-v2 client request includes `lastKnownRevisionDate`, but Vaultwarden's request model does not deserialize that field. Unknown JSON fields are ignored, so attachment slot creation does not receive the upstream stale-item protection. [SDK: attachment request](https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/crates/bitwarden-vault/src/cipher/attachment_client/create.rs#L60-L95) [VW: attachment request](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/ciphers.rs#L1116-L1172)

Folders and Sends have no equivalent stale-write guard in this target and remain
last-write-wins at the server. Defer their writes from the first general-use
release. Enabling them later requires an explicit residual-data-loss decision,
online preflight, per-object serialization, and interruption tests. [VW: folder
handlers](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/folders.rs#L14-L108)
[VW: Send
handlers](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/sends.rs#L41-L60)

Archive and unarchive belong to the same unguarded family and are the one member
the product ships early, because their residual risk is materially smaller.
`PUT /api/ciphers/{id}/archive` and its unarchive counterpart check only
`is_accessible_to_user`, apply no `lastKnownRevisionDate` precondition, and write
per-user state: the archived timestamp lives in a separate per-user record rather
than on the shared cipher, and `archivedDate` is computed for the requesting user
when the cipher is serialized. A lost race therefore changes one reversible
per-user flag and cannot damage item content or affect another organization
member. [VW: archive handlers and per-user archive state](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/ciphers.rs#L1741-L1768)

Two consequences bind the implementation. First, `update_cipher_from_data` also
accepts `archived_date`, so archiving through a full-object update is possible
and must not be used: that path puts the entire encrypted object into a race
whose blast radius is item content. Use the dedicated routes only. Second, the
bulk `PUT /api/ciphers/archive` and `/api/ciphers/unarchive` routes have no
defined reconciliation for a partially applied batch, so they stay outside the
first write manifest.

The reviewed delete, restore, permanent-delete, and partial favorite/folder
routes also expose no equivalent revision precondition. Defer those destructive
or partial mutations with the other last-write-wins operations; endpoint success
tests alone do not establish conflict safety. [VW: delete, restore, and partial
handlers](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/ciphers.rs#L1462-L1592)

### Offline Policy

The MVP must be read-only offline. Users may unlock cached data and use view/copy/autofill functions, but create, edit, delete, attach, share, Send, and organization-management actions stay disabled until online and synchronized.

This is both the safest conflict model and the documented official behavior: offline clients cannot add or edit items, attachments, Sends, or imports. [D: offline mode](https://bitwarden.com/help/using-bitwarden-offline/)

## Realtime Notifications

Vaultwarden mounts `GET {NOTIFICATIONS}/hub` only when WebSockets are enabled. If disabled, realtime sync is unavailable and polling/manual sync remains authoritative. [VW: notification routes](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/notifications.rs#L40-L53) [VW: authenticated hub](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/notifications.rs#L121-L203)

Use a standard SignalR client configured as follows:

| Setting | Value |
|---|---|
| URL | `{NOTIFICATIONS}/hub` |
| Transport | WebSocket only |
| Negotiation | Skip |
| Hub protocol | MessagePack |
| Token | SignalR access-token factory, resulting in `access_token` query parameter |
| Target | `ReceiveMessage` |
| Reconnect | Backoff with jitter, then catch-up sync |

The official client uses exactly that SignalR setup and redacts the query token in logs. [C: SignalR connection](https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/common/src/platform/server-notifications/internal/signalr-connection.service.ts#L34-L99) [C: reconnect](https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/common/src/platform/server-notifications/internal/signalr-connection.service.ts#L105-L170)

The invocation argument is:

```json
{
  "ContextId": "device UUID or null",
  "Type": 0,
  "Payload": {}
}
```

Vaultwarden serializes a SignalR MessagePack invocation for `ReceiveMessage` with those three fields. [VW: notification frame](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/notifications.rs#L612-L643)

Core notification IDs are:

| ID | Meaning | Action |
|---:|---|---|
| 0, 1 | Cipher update/create | Targeted refresh |
| 2, 9 | Cipher delete aliases | Local delete |
| 3, 7, 8 | Folder delete/create/update | Targeted operation |
| 4, 5, 6, 10 | Broad ciphers/vault/org keys/settings | Full sync |
| 11 | Logout | End or update session |
| 12, 13, 14 | Send create/update/delete | Targeted operation |
| 15, 16 | Authentication request/response | Deferred feature |
| 17-19, 25 | Organization/policy invalidation | Forced full sync |

Vaultwarden 1.37.1 emits the core subset through ID 16 and maps cipher delete to ID 2. [VW: emitted update types](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/notifications.rs#L670-L704) Parse the wider current client enum so future server events fail harmlessly. [C: notification IDs](https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/common/src/enums/notification-type.enum.ts#L1-L41)

Ignore a notification when `ContextId` equals the current persistent device ID, but do not rely on that optimization for catch-up. The official client also verifies payload user ID and maps broad events to full sync. [C: notification processing](https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/common/src/platform/server-notifications/internal/default-server-notifications.service.ts#L184-L249)

## Vault Models and Operations

### Cipher Model

Canonical response fields include:

| Category | Fields |
|---|---|
| Identity | `id`, `object`, `type`, `creationDate`, `revisionDate`, `deletedDate` |
| Ownership | `organizationId`, `collectionIds`, `folderId` |
| Crypto | `key`, `name`, `notes`, `fields`, `passwordHistory`, subtype object, `attachments` |
| User state | `favorite`, `archivedDate`, `reprompt` |
| Permissions | `edit`, `viewPassword`, `permissions.delete`, `permissions.restore` |

Vaultwarden returns `object: "cipherDetails"`, includes all subtype keys with nonmatching ones set to null, and attaches permission fields for user sync. [VW: cipher response](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/db/models/cipher.rs#L321-L407)

For writes, start from a freshly fetched raw encrypted object, update only
fields VaultSquire understands and is authorized to change, preserve opaque
properties unchanged, and send the complete object plus
`lastKnownRevisionDate`. If a property cannot be preserved safely or the
endpoint rejects unknown passthrough fields, refuse the write rather than
serialize a lossy model. Vaultwarden's write path accepts these types:

| ID | Type | Write support in 1.37.1 |
|---:|---|---|
| 1 | Login | Yes |
| 2 | Secure Note | Yes |
| 3 | Card | Yes |
| 4 | Identity | Yes |
| 5 | SSH Key | Yes |
| 6 | Bank Account | Response model only; write rejects |
| 7 | Driver's License | Response model only; write rejects |
| 8 | Passport | Response model only; write rejects |

The response model has forward-looking keys for types 6 through 8, but `update_cipher_from_data` rejects every write type other than 1 through 5. [VW: write model](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/ciphers.rs#L249-L301) [VW: write dispatch](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/ciphers.rs#L507-L536)

Treat subtype JSON as extensible encrypted data. Preserve unknown properties, including future login credentials, rather than reserializing from a lossy model.

### Folder Model

A folder has `id`, encrypted `name`, `revisionDate`, and `object: "folder"`. [VW: folder response](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/db/models/folder.rs#L37-L61)

### Collection and Organization Model

A collection carries `id`, `organizationId`, encrypted `name`, optional `externalId`, `type`, and ACL flags `readOnly`, `hidePasswords`, and `manage`. [VW: collection response](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/db/models/collection.rs#L24-L82) [VW: collection details](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/db/models/collection.rs#L99-L153)

Membership values are:

| Value | Role |
|---:|---|
| 0 | Owner |
| 1 | Admin |
| 2 | User |
| 3 | Manager |
| 4 | Custom on some wire paths; Vaultwarden maps it to Manager internally |

Statuses are Revoked `-1`, Invited `0`, Accepted `1`, and Confirmed `2`. [VW: roles and statuses](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/db/models/organization.rs#L73-L130)

Do not compare the numeric role values as normal ascending privilege. Vaultwarden defines a custom order of User, Manager, Admin, Owner. Full organization access requires confirmed membership plus Owner/Admin role or `accessAll`. [VW: role ordering](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/db/models/organization.rs#L121-L183) [VW: full access](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/db/models/organization.rs#L823-L833)

For a cipher in multiple collections, Vaultwarden applies direct user assignments before group assignments, ANDs `readOnly` and `hidePasswords` across applicable collections, and ORs `manage`. [VW: cipher restrictions](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/db/models/cipher.rs#L592-L665) VaultSquire should normally consume the server's resulting `edit` and `viewPassword` flags rather than independently recomputing access.

`hidePasswords` is a client enforcement requirement. Disable password/TOTP/hidden-field reveal, copy, export, and autofill actions when the returned policy forbids them, even if the client technically possesses decryptable ciphertext.

`reprompt` is likewise client-enforced. A cipher with master-password reprompt
requires successful re-verification before reveal, copy, edit, or autofill of
any field. Verification re-derives unwrap material from a newly entered master
password and attempts to open the stored wrapped user key. Quick unlock and an
already-unlocked session are not proof of master-password knowledge and cannot
substitute. The re-entered password is never persisted or logged, and failure
returns one generic error.

### Domains and Profile

Equivalent domains use:

```json
{
  "equivalentDomains": [["example.com", "example.org"]],
  "excludedGlobalEquivalentDomains": [1, 2]
}
```

The response contains `equivalentDomains`, expanded `globalEquivalentDomains`, and `object: "domains"`. [VW: domain settings](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/mod.rs#L75-L145)

Profile name writes accept POST and PUT and enforce a 50-character maximum. [VW: profile routes](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/accounts.rs#L501-L533)

## Endpoint Contract

All paths in this section are relative to `{API}` unless marked `{IDENTITY}` or `{NOTIFICATIONS}`. This is a compatibility table, not a public API guarantee.

### Core and Auth

| Method | Path | Purpose | Source status |
|---|---|---|---|
| GET | `/config` | Capability and environment discovery | `[VW]` |
| POST | `{IDENTITY}/accounts/prelogin/password` | Current password prelogin | `[VW]` |
| POST | `{IDENTITY}/accounts/prelogin` | Legacy prelogin alias | `[VW]` |
| POST | `{IDENTITY}/connect/token` | Password, refresh, API-key, and Send token grants | `[VW]` |
| GET | `/sync?excludeDomains=false` | Authoritative encrypted snapshot | `[VW]` |
| GET | `/accounts/revision-date` | Coarse sync watermark in epoch milliseconds | `[VW]` |
| GET | `/accounts/profile` | Current profile | `[VW]` |
| PUT/POST | `/accounts/profile` | Update display name | `[VW]` |
| GET | `/settings/domains` | Equivalent domains | `[VW]` |
| PUT/POST | `/settings/domains` | Replace equivalent-domain settings | `[VW]` |
| POST | `/two-factor/send-email-login` | Send current email 2FA challenge | `[VW]` |
| GET | `{NOTIFICATIONS}/hub` | Authenticated SignalR WebSocket | `[VW]`, optional |

Wire-model parsing rules:

- Keep identity-response PascalCase aliases separate from API/sync lower-camel fields.
- Accept documented number-or-decimal-string fields such as attachment size, Send size, and maximum access count.
- Treat missing, null, and empty arrays according to each model rather than through one global coercion.
- Parse list envelopes as `object`, `data`, and optional `continuationToken` even though Vaultwarden commonly returns null continuation tokens.
- Retain the raw object beside typed fields so a read-modify-write does not erase unknown encrypted properties.
- Serialize writes with the exact canonical field names shown by the pinned request models; tolerant reading does not justify ambiguous writing.

### Folders and Ciphers

| Method | Path | Purpose | Notes |
|---|---|---|---|
| GET | `/folders` | List folders | Full sync is preferred |
| GET | `/folders/{id}` | Targeted folder fetch | Used by notifications |
| POST | `/folders` | Create | Body contains encrypted `name` |
| PUT/POST | `/folders/{id}` | Update aliases | Full replacement |
| DELETE | `/folders/{id}` | Delete | POST `/{id}/delete` is alias |
| GET | `/ciphers` | List visible ciphers | Full sync is preferred |
| GET | `/ciphers/{id}` | Targeted cipher fetch | `/admin` and `/details` aliases exist |
| POST | `/ciphers` | Create personal cipher | Types 1 through 5 |
| POST | `/ciphers/create` | Create/clone with collection sharing | Organization path |
| PUT/POST | `/ciphers/{id}` | Update aliases | Include `lastKnownRevisionDate` |
| PUT/POST | `/ciphers/{id}/partial` | Favorite/folder partial update | Not a general patch |
| PUT | `/ciphers/{id}/delete` | Soft delete to trash | Do not confuse with POST |
| DELETE | `/ciphers/{id}` | Permanent delete | POST `/{id}/delete` is also permanent |
| PUT | `/ciphers/{id}/restore` | Restore from trash | Admin alias exists |
| PUT | `/ciphers/{id}/archive` | Archive one cipher for the requesting user | Per-user state; no revision precondition |
| PUT | `/ciphers/{id}/unarchive` | Remove that user's archived state | Per-user state; no revision precondition |
| PUT | `/ciphers/archive` | Bulk archive | Partial-batch behavior untested; out of the first write manifest |
| PUT | `/ciphers/unarchive` | Bulk unarchive | Partial-batch behavior untested; out of the first write manifest |
| PUT/POST | `/ciphers/{id}/share` | Share/transfer | Collection IDs plus encrypted cipher |
| PUT/POST | `/ciphers/{id}/collections_v2` | Replace collection assignment | Permission checked |

Folder route aliases are implemented together. [VW: folder routes](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/folders.rs#L14-L108) Cipher aliases and write routes are registered together. [VW: cipher route set](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/ciphers.rs#L33-L103) The DELETE/POST/PUT distinction is explicit in the target. [VW: delete and restore semantics](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/ciphers.rs#L1462-L1592)

### Collections

| Method | Path | Purpose | Access |
|---|---|---|---|
| GET | `/collections` | Current user's visible collections | Authenticated user |
| GET | `/organizations/{orgId}/collections/details` | Detailed organization collection ACLs | Manager or higher, assigned visibility |
| POST | `/organizations/{orgId}/collections` | Create | Manager requires `accessAll`; Admin/Owner allowed |
| PUT/POST | `/organizations/{orgId}/collections/{id}` | Replace collection and ACL assignments | Manage permission on collection |
| DELETE | `/organizations/{orgId}/collections/{id}` | Delete | Manage permission on collection |
| POST | `/organizations/{orgId}/collections/{id}/delete` | Delete alias | Same guard |
| GET | `/organizations/{orgId}/collections/{id}/details` | Collection ACL detail | Manage permission |

The target applies explicit manager guards and collection-level manage checks. [VW: manager guards](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/auth.rs#L865-L982) [VW: collection CRUD](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/organizations.rs#L496-L755)

## Attachments

| Method | API path | Purpose |
|---|---|---|
| GET | `/ciphers/{cipherId}/attachment/{attachmentId}` | Return encrypted metadata and a short-lived download URL |
| POST | `/ciphers/{cipherId}/attachment/v2` | Create metadata/upload slot |
| POST multipart | `/ciphers/{cipherId}/attachment/{attachmentId}` | Upload encrypted bytes for a v2 slot |
| DELETE | `/ciphers/{cipherId}/attachment/{attachmentId}` | Delete attachment |
| POST | `/ciphers/{cipherId}/attachment/{attachmentId}/delete` | Delete alias |
| POST multipart | `/ciphers/{cipherId}/attachment` | Legacy one-step upload |
| POST multipart | `/ciphers/{cipherId}/attachment/{attachmentId}/share` | Legacy re-upload while sharing |

Admin-specific upload/delete aliases also exist, but use the normal routes unless the selected organization operation requires admin scope. [VW: attachment routes](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/ciphers.rs#L1088-L1459)

### Current Upload Flow

1. Resolve the cipher content key. If the cipher has an individual key, unwrap it with the user or organization key; legacy ciphers use the owner key directly.
2. Generate a random 64-byte AES-256-CBC-HMAC attachment key.
3. Encrypt the filename under the resolved cipher key as type-2 `EncString`.
4. Wrap the attachment key under the resolved cipher key as type-2 `EncString`.
5. Encrypt the file bytes under the attachment key using the attachment wire format below.
6. Send metadata to `POST /api/ciphers/{cipherId}/attachment/v2`.
7. Upload the encrypted bytes according to `fileUploadType`.
8. Reconcile the returned cipher response.
9. Best-effort delete the attachment slot if encryption/upload/finalization fails after slot creation.

Metadata request:

```json
{
  "key": "2....",
  "fileName": "2....",
  "fileSize": 12345,
  "lastKnownRevisionDate": "2026-07-31T12:34:56.789Z",
  "adminRequest": false
}
```

Vaultwarden consumes `key`, `fileName`, `fileSize`, and optional `adminRequest`; it ignores `lastKnownRevisionDate`. It returns `attachmentId`, a relative direct-upload `url`, `fileUploadType: 0`, and either `cipherResponse` or `cipherMiniResponse`. [VW: attachment slot](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/ciphers.rs#L1116-L1172)

For direct upload, POST multipart field `data` to `/api/ciphers/{cipherId}/attachment/{attachmentId}`. The target accepts an actual encrypted size within 1 MiB of the declared value and updates the stored size when it differs within that range. [VW: direct upload](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/ciphers.rs#L1275-L1374)

The older single multipart `POST /api/ciphers/{cipherId}/attachment` remains available, but new writes should use v2. [VW: legacy upload](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/ciphers.rs#L1376-L1416)

### Attachment Wire Format

Current V1 attachment bytes are:

```text
0x02 || IV[16] || HMAC[32] || AES-256-CBC-PKCS7 ciphertext
```

The HMAC is HMAC-SHA256 over `IV || ciphertext`, using the attachment key's MAC half. The discriminator and framing are fixed by the streaming attachment cipher. [SDK: discriminator](https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/crates/bitwarden-crypto/src/stream/streaming_attachment_cipher.rs#L1-L53) [SDK: legacy stream format](https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/crates/bitwarden-crypto/src/stream/aes256_cbc_hmac_legacy_stream.rs#L1-L60)

This format authenticates only at end of stream. A decryptor may produce CBC plaintext before it knows whether the whole-file HMAC is valid. Those bytes are untrusted. [SDK: streaming contract](https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/crates/bitwarden-crypto/src/stream/mod.rs#L46-L80) [SDK: final HMAC check](https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/crates/bitwarden-crypto/src/stream/aes256_cbc_hmac_legacy_stream.rs#L290-L404)

Safe download implementation:

1. Fetch attachment metadata with
   `GET /api/ciphers/{cipherId}/attachment/{attachmentId}`.
2. Validate the returned URL scheme and origin policy.
3. Download ciphertext to a permission-restricted app temporary file.
4. Parse framing and make a complete first pass that computes HMAC over
   `IV || ciphertext` without decrypting.
5. Compare the expected HMAC in constant time. On failure, delete the ciphertext
   file and return one generic integrity error; no plaintext has been produced.
6. Only after successful authentication, make a second pass to decrypt. For an
   explicit Save operation, write a restricted partial file in the user's chosen
   destination and atomically rename it after padding/finalization succeeds. For
   in-app viewing, use a bounded memory consumer or defer unsupported large
   previews rather than writing an app-managed plaintext temporary file.
7. Remove ciphertext and partial output on every failure or cancellation.

Vaultwarden's metadata includes `id`, URL, encrypted `fileName`, encrypted attachment `key`, `size`, and `sizeName`. Local-storage download URLs use a five-minute signed token. [VW: attachment metadata](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/db/models/attachment.rs#L23-L78) [VW: download-token validity](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/auth.rs#L407-L430)

Do not support range reads for this format; authenticate the complete ciphertext
before producing any plaintext.

## Sends

Sends are independent encrypted objects with Text type `0` and File type `1`. Vaultwarden stores encrypted `name`, `notes`, subtype data, a user-key-wrapped Send secret, access limits, optional password proof, and lifecycle dates. [VW: Send model](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/db/models/send.rs#L22-L68) [VW: Send response](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/db/models/send.rs#L143-L174)

| Method | API path | Purpose |
|---|---|---|
| GET | `/sends` | List the authenticated user's Sends |
| GET | `/sends/{sendId}` | Get one owned Send |
| POST | `/sends` | Create a text Send |
| POST | `/sends/file/v2` | Create a file Send upload slot |
| POST multipart | `/sends/{sendId}/file/{fileId}` | Upload encrypted file bytes |
| PUT | `/sends/{sendId}` | Replace mutable Send fields |
| DELETE | `/sends/{sendId}` | Delete an owned Send |
| PUT | `/sends/{sendId}/remove-password` | Remove access password |
| POST | `/sends/access` | Access with a short-lived Send bearer token |
| POST | `/sends/access/{accessId}` | Legacy public access with optional password proof |
| POST | `/sends/access/file/{fileId}` | Obtain token-authenticated file download data |

The target registers these current and legacy routes together. [VW: Send routes](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/sends.rs#L41-L60)

Current recipient-access flow:

1. Parse the public access ID from the URL path and `K` from its fragment; never transmit or log the fragment.
2. For a password-protected Send, compute standard-Base64 `PBKDF2-HMAC-SHA256(password, K, 100000)` as `password_hash_b64`.
3. Submit form-urlencoded `client_id=send`, `grant_type=send_access`, `scope=api.send.access`, `send_id={accessId}`, and the optional proof to `POST {IDENTITY}/connect/token`.
4. Keep the returned two-minute bearer token only as long as needed. Token issuance validates accessibility and increments the access count.
5. Call `POST {API}/sends/access` with that bearer token. For a file, also call `POST {API}/sends/access/file/{fileId}` and consume its signed download URL.
6. Authenticate and decrypt the returned fields or downloaded file using the Send key derived from `K`.

The official payload shape fixes the client ID, grant, and scope. [SDK: Send access-token payload](https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/crates/bitwarden-auth/src/send_access/api/token_request_payload.rs#L51-L109) The target accepts anonymous or password-proof token requests and returns a two-minute token scoped to that Send. [VW: Send token dispatch](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/identity.rs#L111-L124) [VW: Send token claims](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/auth/send.rs#L16-L45) [C: Send password proof](https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/common/src/key-management/sends/services/default-send-password.service.ts#L1-L26)

Creation crypto:

1. Generate a random 16-byte Send secret `K`.
2. Compute `PRK = HMAC-SHA256(key = "bitwarden-send", message = K)`.
3. HKDF-expand `PRK` with info `"send"` to a 64-byte AES-CBC-HMAC key.
4. Encrypt the Send fields and file under that derived key.
5. Encrypt raw `K` under the user's key for the owner's stored Send record.
6. Place Base64URL `K` in the public URL fragment so browsers do not send it to the server.

The shareable-key derivation is explicit in the SDK. [SDK: shareable key](https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/crates/bitwarden-crypto/src/keys/shareable_key.rs#L11-L34) The Send implementation generates a 16-byte secret, wraps it with the user key, and derives the content key with `"send"`. [SDK: Send encryption](https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/crates/bitwarden-send/src/send.rs#L554-L593)

Important target constraints:

- Deletion date cannot be more than 31 days in the future.
- Email-verification recipients are not supported by Vaultwarden 1.37.1.
- Organization policy or server configuration may forbid create/edit while still permitting delete.
- File Send v2 first creates metadata at `POST /api/sends/file/v2`, then uploads multipart bytes to the returned direct path.
- Public access returns encrypted fields that are decrypted only from the URL-fragment key.

These constraints and routes are enforced by the target. [VW: Send creation](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/sends.rs#L72-L172) [VW: Send file v2](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/sends.rs#L308-L448) [VW: public access](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/sends.rs#L451-L623)

Sends are a later milestone because they combine public unauthenticated access, fragment-key handling, optional passwords, access counters, expiry, and file transfer. Product documentation confirms their temporary end-to-end encrypted design. [D: About Send](https://bitwarden.com/help/about-send/#send-security)

## Registration

The initial "add account" experience is not this protocol. VaultSquire presents
one form for the existing account's Vaultwarden URL, email, and master password,
then a separate 2FA step only when challenged. This section concerns creating a
new user on the remote Vaultwarden server.

Vaultwarden exposes:

| Method | Identity path | Purpose |
|---|---|---|
| POST | `/accounts/register/send-verification-email` | Validate eligibility and send/return a verification token |
| POST | `/accounts/register/finish` | Current verified/invited registration completion |
| POST | `/accounts/register` | Legacy/direct registration flow |

The current V1 completion payload contains normalized email, optional name and hint, matching authentication/unlock KDF data, the server-authentication hash, master-key-wrapped user key, RSA public key, user-key-encrypted RSA private key, and any invitation or verification token. [VW: registration model](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/accounts.rs#L81-L213) [VW: registration routes](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/identity.rs#L1036-L1103)

Registration availability depends on server signup settings, email verification, invitation state, allowed email domains, SMTP, and emergency-access flows. [VW: registration validation](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/api/core/accounts.rs#L258-L435)

Defer registration from the first release. A registration bug can create an unrecoverable vault, and V2 account-registration models are changing upstream. When implemented, generate V1 only and verify immediate login, full sync, logout, and fresh-device recovery before declaring success.

## Error Handling

Vaultwarden's normal API error body may contain all of these fields:

```json
{
  "message": "...",
  "validationErrors": { "": ["..."] },
  "errorModel": { "message": "...", "object": "error" },
  "error": "",
  "error_description": "",
  "object": "error"
}
```

Its default serializer intentionally duplicates the user message into multiple compatibility shapes. [VW: API error serialization](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/error.rs#L218-L280)

Decode errors in this order:

1. Structured identity `error` plus nonempty `error_description`.
2. `message`.
3. `errorModel.message`.
4. Flattened `validationErrors`.
5. HTTP status and a generic message.

Keep the status, machine code, endpoint class, and retryability separate from the displayed message. Never log request bodies, encrypted keys, bearer/refresh tokens, WebSocket URLs, Send fragments, presigned URLs, or decrypted errors containing user data.

Vaultwarden's login and unauthenticated limits are IP-keyed and return `429` without requiring a retry to succeed immediately. [VW: rate limits](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/src/ratelimit.rs#L1-L55) On `429`, honor `Retry-After` if present; otherwise use exponential backoff with full jitter and stop automated password/2FA retries.

Recommended retry policy:

| Failure | Retry |
|---|---|
| DNS/TLS/connect before request | Backoff for safe reads; user action for writes |
| `401` protected API | One refresh and one replay only |
| `400 invalid_grant` refresh | No; terminate session |
| `400` stale cipher | No; conflict flow |
| `403`/`404` | No; refresh permission/snapshot if appropriate |
| `429` | Delayed with jitter; never tight-loop |
| `500`/`502`/`503`/`504` read | Limited backoff |
| Ambiguous write timeout | Reconcile with targeted GET/full sync before user retry |

## Vaultwarden Supplemental Security Requirements

The following Vaultwarden-specific requirements are release-blocking when their
feature is in the declared release manifest. Global security requirements and
all Proton CLI process/cache rules are defined in
[`SECURITY_AND_TESTING.md`](SECURITY_AND_TESTING.md), which controls conflicts.

| Area | Requirement |
|---|---|
| Randomness | Use the operating system CSPRNG for keys, IVs, and device IDs |
| Key memory | Use zeroizing/locked buffers where available; minimize copies and immutable strings |
| Crypto API | Make authenticated decryption return plaintext only on successful verification |
| CBC oracles | Return one generic integrity/decryption error; do not distinguish MAC and padding failures |
| Vaultwarden cache | No plaintext fields, notes, passwords, TOTP seeds, filenames, or Send text on disk |
| Clipboard | Clear copied secrets after a user-configurable interval |
| Logs | Structured allowlist; redact tokens, URLs with tokens, ciphertext, and decrypted content |
| Screens | Hide secrets by default and respect OS screen-capture protections where available |
| URLs | HTTPS by default, origin validation, no bearer forwarding across origins |
| Redirects | Disable or validate redirects for token, sync, and upload requests |
| KDF | Enforce minimums and resource ceilings before allocation |
| Attachments | Authenticate complete ciphertext before producing plaintext |
| Policies | Enforce `edit`, `viewPassword`, `hidePasswords`, and Send policy in every UI/action path |
| Unknown data | Preserve ciphertext and fail closed; never coerce an unknown encryption type |
| Backup/export | Out of MVP until an explicit secure-export threat model exists |

V1 does not cryptographically bind every ciphertext to its item ID or field name, and it lacks the newer signed account security state. A malicious or compromised server can attempt rollback, replay, omission, or ciphertext substitution. TLS, local revision checks, and HMACs mitigate transport tampering and ciphertext corruption, but they do not turn the V1 server into a fully untrusted storage oracle. Document this trust boundary.

## Vaultwarden Evidence Delivery Sequence

These stages organize the protocol evidence in this report. They are not the
complete product phases. [`PLAN.md`](PLAN.md) alone controls product sequence;
[`ARCHITECTURE.md`](ARCHITECTURE.md) controls component and data boundaries. The
plan includes the Proton CLI process/sandbox spike and later provider milestones.

### Vaultwarden Stage 0: Protocol And Crypto Harness

- Establish pinned JSON fixtures from a disposable Vaultwarden 1.37.1 instance.
- Add known-answer tests for PBKDF2, Argon2id, master hash, HKDF stretch, type-2
  `EncString`, RSA wrapping, attachment framing, and detection of both legacy
  type-0 user-key lengths without returning plaintext.
- Build strict secret-redaction tests before adding network logging.
- Build the endpoint client with raw-response capture disabled by default.

Exit criterion: all crypto fixtures cross-decrypt with an official client-created test vault.

### Vaultwarden Stage 1: Read-Only Vault

- Base URL discovery and `/api/config`.
- Password login, refresh, TOTP, email 2FA, and recovery-code handling.
- V1 user and organization key hierarchy.
- Revision-gated `/api/sync` and encrypted local cache.
- Offline master-password unlock and read-only item browsing/search.
- Types 1 through 5 read support, including unknown-field preservation.
- Per-user `archivedDate` reads: archived items excluded from default lists and
  search, exposed behind their own filter, never conflated with trash.
- Collection display, server permission enforcement, and negative reveal/copy
  tests.
- Lock/logout/key zeroization.

Exit criterion: fresh login, restart, offline unlock, locked sync, organization-item decrypt, and session expiry pass.

### Vaultwarden Stage 2: Safe Core Writes

- Personal cipher create/update for types 1 through 5.
- Archive and unarchive through the dedicated single-item routes, with the
  recorded last-write-wins ADR; bulk routes excluded.
- Cipher stale-write conflict UI.
- Post-write targeted reconciliation.

Exit criterion: latest-record preflight and the server guard detect deterministic
stale writes outside the documented tolerance; the nearly two-second race
window and ambiguous
network outcomes are characterized and no request is blindly retried.

### Vaultwarden Stage 3: Advanced Mutations And Attachments

- Folder, profile, domain, organization, sharing, and manager collection writes
  only after an explicit last-write-wins decision and permission tests.
- Soft delete, restore, permanent delete, and favorite/partial writes under the
  same endpoint-specific residual-risk process.
- Attachment v2 create/direct upload, signed download, delete, legacy read.
- Ciphertext-first whole-file authentication and orphan cleanup.

Exit criterion: tampered and truncated attachments produce no plaintext; every
failed upload/download removes app-owned partial artifacts.

### Vaultwarden Stage 4: Realtime And Sends

- SignalR MessagePack notifications and reconnect catch-up.
- Text Sends, then file Sends and public recipient access.
- Notification/polling convergence tests.

Exit criterion: dropped, duplicated, reordered, and same-device notifications all converge to `/sync` state.

### Deferred

- Encryption V2 creation, migration, downgrade, or rotation.
- Passkey login and trusted-device encryption.
- SSO and login-with-device.
- Offline mutation queues or automatic conflict merge.
- Cipher types 6 through 8 writes.
- Organization lifecycle, member invitation, recovery administration, and policy administration.
- Import/export, emergency access, API-key login, and mobile push relay.

## Compatibility Test Matrix

Run the matrix against an isolated Vaultwarden 1.37.1 instance in CI. Seed some
records with an official client and, after writes exist, some with VaultSquire.
`P0` and `P1` are test priorities, not product phases. A row blocks only the
first release whose feature manifest contains the behavior:

| Scenario family | First applicable milestone |
|---|---|
| ENV, password/TOTP/email/recovery AUTH, KDF baseline changes, current CRYPTO, read SYNC including archived-state reads, ERR, V1/V2 detection | Read-only preview |
| CIPHER create/update, single-item archive/unarchive, and write-side unknown preservation | Core-write beta |
| CIPHER delete/restore/favorite and other unguarded mutations | Advanced mutation phase |
| FOLDER mutation and advanced organization mutation | Advanced mutation phase |
| Notification SYNC | Realtime phase |
| ATT | Attachment phase |
| SEND | Send phase |
| WebAuthn/YubiKey AUTH | Additional-2FA phase |

| ID | Priority | Scenario | Expected result |
|---|---|---|---|
| ENV-01 | P0 | Base URL with/without trailing slash and path prefix | Correct service URLs, no double slash |
| ENV-02 | P0 | HTTP URL outside dev mode | Connection rejected before credentials |
| ENV-03 | P0 | `/api/config` advertises `2026.6.0` | Parsed as protocol compatibility, not server release |
| ENV-04 | P0 | Cross-origin redirect on identity/API request | Bearer/password form not forwarded |
| ENV-05 | P0 | Config discovers different identity/API origins | Explicit role-scoped approval before email/prelogin |
| AUTH-01 | P0 | PBKDF2 password login | User key and test item decrypt |
| AUTH-02 | P0 | Argon2id password login | User key and test item decrypt |
| AUTH-03 | P0 | Unicode password and mixed-case/space-padded email | Normalization and UTF-8 match official client |
| AUTH-04 | P0 | Wrong password | Generic login failure; no key material persisted |
| AUTH-05 | P0 | TOTP challenge | `invalid_grant` challenge parsed and retry succeeds |
| AUTH-06 | P1 | Email challenge on protocol version 2026.6.0 | Explicit send-email endpoint and login succeed |
| AUTH-07 | P1 | WebAuthn 2FA | Native/browser proof succeeds where supported |
| AUTH-08 | P0 | Refresh replacement | Returned refresh token committed atomically; no reuse assumption |
| AUTH-09 | P0 | Invalid refresh token | Reauthentication required; encrypted cache retained absent revocation |
| AUTH-10 | P0 | Security-stamp/logout notification | Correct account locks/logs out and keys clear |
| AUTH-11 | P0 | Password/key rotation while the client is offline, then re-login | Candidate is not promoted when changed bootstrap data is observed; old snapshot remains current but blocked by persisted reauthentication state; validated hierarchy and fresh full sync replace it atomically before decrypted views |
| AUTH-11A | P0 | Failure, cancellation, or process death around rotation-marker and replacement commits | Any live generation changes before suspended cleanup; marker-write failure leaves the running process locked; death before marker commit is treated as unobserved rotation; after marker commit the prior snapshot stays current and blocked; no old or candidate plaintext publishes |
| AUTH-12 | P0 | Prelogin KDF algorithm or any parameter differs from last accepted | Every difference requires explicit confirmation; unchanged settings do not; below-floor values are refused; no derivation occurs before the decision |
| CRYPTO-01 | P0 | Type-2 known-answer vector | Exact plaintext and serialization round trip |
| CRYPTO-02 | P0 | Flip IV, ciphertext, and MAC bits | All fail with one generic error |
| CRYPTO-03 | P0 | Legacy type-0 user-key wrappers, 32/64-byte keys | Detected, retained, no plaintext, migration guidance |
| CRYPTO-04 | P0 | RSA-2048 OAEP-SHA1 organization key | Organization cipher decrypts |
| CRYPTO-05 | P0 | Unknown encryption type | Item retained, not displayed or rewritten |
| SYNC-01 | P0 | Empty local database | Full snapshot commits atomically |
| SYNC-02 | P0 | Server revision unchanged and no force condition | `/sync` is skipped without client-clock comparison |
| SYNC-02A | P0 | Account revision changes during `/sync` | Candidate discarded; bounded retry or old snapshot retained |
| SYNC-02B | P0 | Unwatermarked org/policy change during `/sync` | Next forced repair converges; no atomic-snapshot claim |
| SYNC-03 | P0 | Parse/database failure during snapshot | Old snapshot and last-sync value remain |
| SYNC-04 | P0 | Sync while locked | Ciphertext updates; no keys loaded |
| SYNC-05 | P0 | Unknown response fields | Fields survive read and subsequent write path |
| SYNC-06 | P0 | WebSocket disabled | Poll/manual sync remains functional |
| SYNC-07 | P1 | Notification reconnect after missed writes | Catch-up full sync converges |
| SYNC-08 | P1 | Same-device and duplicate notification | No duplicate mutation; final state converges |
| CIPHER-01 | P0 | Create/read/update each type 1 through 5 | Official client cross-reads all values |
| CIPHER-02 | P0 | Attempt write type 6, 7, or 8 | UI blocks unsupported operation |
| CIPHER-03 | P0 | Two clients update same cipher with a deterministic three-second revision delta | Stale client enters conflict flow |
| CIPHER-03A | P0 | Concurrent updates at 0, 0.5, 1, 1.5, 1.999, 2, and 3 second deltas | Server tolerance characterized and disclosed |
| CIPHER-04 | P0 | Soft delete then restore | Item moves to/from trash without data loss |
| CIPHER-05 | P0 | POST/DELETE permanent delete confirmation | Correct hard-delete behavior |
| CIPHER-06 | P0 | Archive then unarchive a personal item | State toggles through the dedicated routes; content and revision-sensitive fields unchanged |
| CIPHER-07 | P0 | Archive an organization item, read as a second member | Archived state is per-user; the other member's view is unaffected |
| CIPHER-08 | P0 | Archived item in default list, search, and Archived filter | Excluded from default list and search; visible only under its filter; never shown as trashed |
| CIPHER-09 | P0 | Two clients race archive against unarchive | Final state is one of the two; item content intact; loser converges on authoritative read |
| CIPHER-10 | P0 | Archive request issued while the item is trashed, and a trash request while archived | The two states stay independent; neither action is presented or recorded as the other |
| FOLDER-01 | P1 | Folder CRUD and move cipher | Official client sees matching placement |
| ORG-01 | P0 | Owner/Admin/User/Manager/Custom profile | Role mapping and actions are correct |
| ORG-02 | P0 | Read-only collection cipher | Edit/delete actions blocked |
| ORG-03 | P0 | Hide-passwords collection cipher | Reveal/copy/autofill/export blocked |
| ORG-04 | P1 | Cipher in multiple collections with mixed ACLs | Server-returned effective permissions honored |
| ATT-01 | P0 | Empty, one-byte, block-boundary, and large files | Cross-client decrypt and exact byte equality |
| ATT-02 | P0 | Tampered HMAC/ciphertext and truncated stream | No plaintext produced; ciphertext/partial output removed |
| ATT-03 | P0 | Metadata created but upload fails | Best-effort orphan slot cleanup |
| ATT-04 | P1 | Declared/actual size within and beyond 1 MiB leeway | Target acceptance/rejection matched |
| ATT-05 | P0 | Expired signed URL | Metadata is refreshed; URL is not persisted as durable |
| SEND-01 | P1 | Text Send opened in clean browser | Fragment-key decryption succeeds |
| SEND-02 | P1 | Password, max count, expiry, disable, deletion | Each access policy enforced |
| SEND-03 | P1 | File Send direct upload/download | Exact bytes and filename cross-decrypt |
| ERR-01 | P0 | Default, compact, identity, and validation errors | Stable typed error and safe display text |
| ERR-02 | P0 | Repeated failed login reaches `429` | Backoff, no automatic credential retry |
| V2-01 | P0 | V1 profile with null V2-named fields | V1 accepted; field presence is not a discriminator |
| V2-02 | P0 | Semantically verified V2 account fixture | Clear unsupported state; no downgrade/write |

Before supporting a newer Vaultwarden release, rerun every P0 row applicable to
the release manifest, plus defensive parser/unknown-data sentinels. Diff route
and model source from the pinned target and inspect changes to `/api/config`,
account keys, `EncString`, cipher types, attachment upload models, and
notification IDs.

## Vaultwarden Risks And Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Private API drift | Login or writes break after server update | Pin supported versions, feature probe, fixture tests, fail closed |
| Crypto implementation defect | Vault disclosure or permanent loss | Small audited core, known-answer/cross-client/fuzz tests, no custom primitives |
| Incorrect protocol version header | Server hides or changes behavior | Separate protocol version from app version; compatibility suite before advancing |
| KDF resource attack | Client memory/CPU denial of service | Validate minimum and maximum before allocation |
| Attachment early plaintext | Corrupted/malicious file reaches user | First-pass ciphertext HMAC before any decryption |
| Ambiguous write retry | Duplicate or overwritten data | No blind non-idempotent retry; targeted reconciliation |
| Offline write conflicts | Silent data loss | Read-only offline MVP |
| ACL enforcement gap | Restricted secrets revealed | Central capability checks and negative UI/action tests |
| Token in WebSocket URL | Credential leakage through logs/proxies | Redact query strings and disable verbose transport logs |
| Cross-origin upload | Bearer leakage or exfiltration | Upload-type/origin policy; never send bearer to presigned origin |
| Unknown model loss | Future data removed on save | Vaultwarden encrypted raw-object preservation and merge-aware serializer |
| V2 partial implementation | Account becomes unreadable | Detect and refuse all V2 mutation paths |
| Local compromise | Cached vault or live keys exposed | OS credential store, encrypted DB, short key lifetime, lock hardening |

## Legal and Branding Boundary

This section is engineering risk guidance, not legal advice.

Independent VaultSquire source uses the Apache License 2.0. That does not grant
permission to copy third-party code, and compatible licensing alone does not
override the project's independent-implementation and source-isolation rules.

| Source | Default license at pinned revision | Engineering consequence |
|---|---|---|
| Vaultwarden | AGPLv3 | Protocol evidence only under current policy; do not copy, translate, vendor, or link implementation code |
| Bitwarden clients | GPLv3 outside `bitwarden_license` | Protocol evidence only; do not copy, translate, vendor, or link client code |
| Bitwarden server | AGPLv3 outside `bitwarden_license` | Comparison evidence only; restricted directories are not implementation inputs |
| Bitwarden SDK | Choice of GPLv3 or SDK License except restricted directories | Cryptographic evidence only; not an adoption candidate under the selected architecture |
| Keyguard | All rights reserved at the researched revision | Permanently source-excluded; do not consult or derive implementation detail from it |
| Proton CLI | GPLv3 at the researched revision | User-installed external process only; do not copy, bundle, vendor, or link it |

Sources: [VW: AGPLv3](https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/LICENSE.txt#L1-L12), [C: client license](https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/LICENSE.txt#L1-L17), [UP: server license](https://github.com/bitwarden/server/blob/85890318551ee8a2036bfbfb3c1135b98f1a4dce/LICENSE.txt#L1-L17), [SDK: SDK license](https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/LICENSE#L1-L20).
Keyguard and Proton licensing evidence and the controlling use restrictions are
recorded in [`KEYGUARD_FORK_ASSESSMENT.md`](KEYGUARD_FORK_ASSESSMENT.md) and
[`PROTON_PASS_RESEARCH.md`](PROTON_PASS_RESEARCH.md#14-licensing-terms-and-branding).

Keep VaultSquire independently written. Permitted pinned sources may establish
interoperability facts and guide independently generated black-box fixtures, but
their implementation expression is not pasted, mechanically translated, or
adapted. Keyguard source is never consulted. The Bitwarden SDK remains research
evidence rather than an implementation dependency. Proton integration executes
the official user-installed CLI and does not copy or link Proton code.

Copyright licenses do not grant Bitwarden trademark rights. The guidelines prohibit branding or marketing third-party products with Bitwarden marks without permission and prohibit confusing product names, logos, and trade dress. Truthful compatibility references must not imply sponsorship or affiliation. [UP: trademark guidelines](https://github.com/bitwarden/server/blob/85890318551ee8a2036bfbfb3c1135b98f1a4dce/TRADEMARK_GUIDELINES.md#L9-L32) [UP: names and logos](https://github.com/bitwarden/server/blob/85890318551ee8a2036bfbfb3c1135b98f1a4dce/TRADEMARK_GUIDELINES.md#L52-L95) [UP: logo restriction](https://github.com/bitwarden/server/blob/85890318551ee8a2036bfbfb3c1135b98f1a4dce/TRADEMARK_GUIDELINES.md#L159-L176)

Vaultwarden-specific compatibility wording:

> VaultSquire is an independent client compatible with selected Vaultwarden server versions. It is not affiliated with or endorsed by Bitwarden, Inc. or the Vaultwarden project.

Proton compatibility wording must likewise state that VaultSquire uses a
separately installed official CLI and is not affiliated with or endorsed by
Proton. Use original VaultSquire artwork from `media-sources/icon.png`; do not
use Keyguard, Bitwarden, Vaultwarden, or Proton logos, screenshots, assets, or
trade dress.

Do not use a Bitwarden logo, an imitation shield, official screenshots as product art, or "Bitwarden" in the application name, package ID, domain, social handle, or icon. Protocol field names such as `Bitwarden-Client-Version` are wire compatibility identifiers and should remain confined to the transport implementation.

## Final Recommendation

Proceed with the Vaultwarden stages in this report only after accepting these
Vaultwarden-specific constraints. `PLAN.md` controls the full two-provider
product sequence:

- Vaultwarden 1.37.1 is the sole initial server target.
- Encryption V1 is the sole account write format.
- Offline is read-only.
- `/sync` is authoritative; realtime events are hints.
- Cipher conflicts require an explicit user decision.
- Attachments are unavailable until their complete ciphertext is authenticated.
- Unsupported encryption/model variants are retained but never rewritten.
- No Keyguard or vendor implementation expression is copied into the codebase;
  only reviewed dependencies with recorded license and provenance may be
  imported.

Apply the security and release gates in
[`SECURITY_AND_TESTING.md`](SECURITY_AND_TESTING.md) before promoting any stage.
Keyguard remains permanently rejected under its accepted source-isolation
decision. The official CLI is the selected Proton route; its read and per-command
write gates determine which capabilities ship, not whether VaultSquire falls
back to a private Proton API.

That scope produces a useful client without taking on the highest-risk operations, especially account registration/rotation, partial V2 support, offline conflict resolution, and unauthenticated public-file workflows, before the core can prove cross-client cryptographic compatibility.
