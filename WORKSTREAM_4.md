# Workstream 4 Environment, Transport, And Authentication Record

- Status: headless slice implemented; automated exit criteria run in the
  `macOS Product` lane via `scripts/ci.sh`; the merged PR's green run is the
  controlling evidence
- Owner: `L-K-M`
- Started: 2026-08-05
- Scope: the HEADLESS discovery/authentication contract slice only — URL and
  environment parsing, an ephemeral bounded HTTP transport, `/api/config`
  discovery, prelogin, the password token grant, 2FA continuation, token
  refresh, and a typed error taxonomy. No account UI, no persistence, and no
  Keychain (those are the remainder of Workstream 4 and later workstreams).

Per PLAN.md, this slice is the Phase 0 headless portion of Workstream 4 and
does not pull the add-account UI or storage forward. Tokens and key material
stay in memory; the caller owns them. No real vault or account data is valid
test input; every fixture is synthetic `VSQ-Canary` material.

## Implemented Surface

`VaultSquire/Providers/Vaultwarden/Network/`:

- **Environment** (`VaultwardenEnvironment`, `VaultwardenOrigin`). Parses the
  configured base URL, preserving the port and path prefix and normalizing
  only trailing slashes, and rejects userinfo, query, fragment, unsupported
  schemes, and non-HTTPS (outside an explicit development-only loopback).
  Derives the API/identity/icons/notifications/events service URLs and the
  same-origin, HTTPS-preserving, within-base-path redirect predicate.
- **Transport** (`VaultwardenTransport`, `VaultwardenRedirectPolicy`). An
  ephemeral `URLSession` with no URL cache, cookie store, or credential store;
  a per-request redirect delegate that refuses any cross-origin, downgrading,
  or path-escaping redirect; a byte-bounded streaming read; the fixed client
  headers (`Device-Type: 7`, `Bitwarden-Client-Name`, no-store on GET) with
  `Bitwarden-Client-Version` deliberately unset; and a transport error surface
  that never carries the failing URL.
- **Discovery and authentication** (`VaultwardenAuthenticator`). The headless
  login transaction: fetch `/api/config` before any email is sent, resolve and
  approve effective API/identity origins, normalize the email, prelogin (with
  the legacy alias fallback), validate KDF bounds and route any change through
  the confirmation policy, derive the master key and auth hash locally with the
  Workstream 3 module, submit the form-urlencoded password grant
  (`grant_type=password`, `client_id=desktop`, `device_type=7`,
  `scope=api offline_access`, the Base64 auth hash as the `password` field),
  and continue a 2FA challenge.
- **Two-factor** (`VaultwardenTwoFactor`). The fixed provider identifiers and
  this release's support decision: authenticator (0), email (1), and recovery
  code (8) are user-completable; Duo (2), YubiKey (3), legacy U2F (4), org Duo
  (6), and WebAuthn (7) are parsed and reported unsupported; the remember token
  (5) is internal.
- **Token refresh** (`VaultwardenTokenRefresher`). A per-account actor
  enforcing one in-flight refresh (concurrent callers share it), atomic
  refresh-token replacement on success, and `invalid_grant` mapped to session
  expiry without deleting cached state.
- **Error taxonomy** (`VaultwardenAPIError`, `VaultwardenErrorDecoder`). The
  eight categories with the fixed decode precedence (identity
  `error_description`, then `message`, then `errorModel.message`, then
  flattened `validationErrors`, then a generic status message), keeping the
  machine code, HTTP status, and retry disposition separate from the safe
  display message.

Wire models tolerate both PascalCase identity fields and camelCase API fields,
accept number-or-decimal-string integers, and preserve unknown fields. No
logging event is added, so the fixed-enum allowlist and `DiagnosticsTests` are
unchanged, and the leakage requirement holds by construction (nothing is
logged). No dependency is added; primitives are Apple system frameworks only.

## Exit Criteria

| Criterion | Evidence |
|---|---|
| Path prefixes and ports preserved; no double slash (ENV-01) | `VaultwardenEnvironmentTests` service-URL cases |
| Non-HTTPS rejected before credentials; userinfo/query/fragment rejected (ENV-02) | `VaultwardenEnvironmentTests` rejection cases |
| `/api/config` parsed as protocol compatibility, fetched before email (ENV-03/04) | `VaultwardenAuthenticatorTests` config-before-prelogin and origin-approval cases |
| Redirects only same-origin, HTTPS-preserving, within base path | `VaultwardenEnvironmentTests` redirect-policy cases |
| PBKDF2 password login yields a session; wire auth hash equals the known-answer (AUTH-01) | `VaultwardenAuthenticatorTests.testPBKDF2PasswordLoginSucceeds` |
| Argon2id account fails closed at derivation (AUTH-02) | `VaultwardenAuthenticatorTests.testArgon2idAccountFailsClosed` |
| KDF change requires confirmation; unchanged does not (AUTH-12) | `VaultwardenAuthenticatorTests` KDF-change cases |
| Every claimed 2FA provider handled: complete supported, report unsupported | `VaultwardenAuthenticatorTests` 2FA cases; `VaultwardenTwoFactor` support map |
| Refresh replacement, invalid-grant expiry, one in-flight refresh | `VaultwardenTokenRefresherTests` |
| Typed error precedence and rate-limit backoff (ERR-01/02) | `VaultwardenErrorTests` |
| Passwords/tokens/URLs absent from bodies, errors, cookies, and cache | `VaultwardenLeakageTests`; `VaultwardenTransportTests` ephemeral-session case |

Contract tests run against a `URLProtocol` stub with synthetic pinned JSON
fixtures; no sockets, signing, or network are used. TLS-trust behavior
(private CAs, hostname/validity/chain failures) and the exact wire field
casing cannot be exercised by a stub and are gathered on the blocking pinned
Vaultwarden 1.37.1 container, private-CA, and reverse-proxy contract lanes,
per SECURITY_AND_TESTING.md. The recorded request field names follow
`IMPLEMENTATION_REPORT.md`; their byte-exact acceptance by the real server is
that contract lane's evidence, not this PR's. The `send-email-login` request
authenticates with the server-auth hash and device identifier (mirroring the
token grant); its exact field set is not enumerated in the recorded facts and
is verified on the same contract lane. `Bitwarden-Client-Version`
remains unset until a contract lane justifies a value (EVIDENCE.md).

## Outstanding Workstream 1 Exit Evidence

Workstream 4's headless slice consumes no outstanding Workstream 1 evidence.
Per [ADR 0006](docs/adr/0006-workstream-1-merge-with-outstanding-evidence.md)
and [`WORKSTREAM_1.md`](WORKSTREAM_1.md), these rows remain owed, block Phase 0
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
- Generated 16/32/64 px icon review (blocked by `ICON_PROVENANCE.md`).

The Phase 0 crypto/transport proof additionally owes the pinned Vaultwarden
1.37.1 container, private-CA, and reverse-proxy contract lanes named above.
Presence in `main` is not evidence that a criterion passed; a row is marked
passed only when the evidence exists.
