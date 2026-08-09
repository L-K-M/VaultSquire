# Workstream 4 Environment, Transport, And Authentication Record

- Status: headless slice and the add-account UI / Keychain slice implemented;
  automated exit criteria run in the `macOS Product` lane via `scripts/ci.sh`;
  the merged PR's green run is the controlling evidence
- Owner: `L-K-M`
- Started: 2026-08-05
- Scope: the HEADLESS discovery/authentication contract slice — URL and
  environment parsing, an ephemeral bounded HTTP transport, `/api/config`
  discovery, prelogin, the password token grant, 2FA continuation, token
  refresh, and a typed error taxonomy — plus the add-account UI, the 2FA
  challenge screen, and Keychain credential storage (see the addendum below).

## Add-Account UI And Keychain Storage Addendum

The remainder of Workstream 4 adds the user-facing sign-in flow and durable
credential storage on top of the headless authenticator:

- **Credential storage** (`Providers/Vaultwarden/Storage/`). A
  `VaultwardenCredentialStore` protocol with a `KeychainCredentialStore`
  implementation stores only the refresh token and, when the user chose to be
  remembered, the remembered second-factor token — never the access token
  (memory only) and never the master password. Records use the Data Protection
  Keychain (`kSecUseDataProtectionKeychain`),
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and
  `kSecAttrSynchronizable = false`, carry a version label, and are keyed by an
  opaque account key (the single-account `primary` key here; a SHA-256-derived
  per-account key is provided for the later multi-account workstream, so no
  email appears in Keychain metadata). The refresh token is replaced with an
  atomic `SecItemUpdate` that preserves the remembered token. A persistent
  random device identifier is retained in app preferences (a non-secret
  installation identifier).
- **Add-account UI** (`Features/AddAccount/`). One SwiftUI form (server URL,
  email, master password in a `SecureField`) drives the M03 authenticator; on
  a second-factor challenge it swaps to a challenge screen showing only the
  server-advertised, user-completable providers (authenticator, email,
  recovery code), a remembered-device toggle, a recovery-code destructive
  warning, and an unsupported-only state, with Back preserving the non-secret
  fields. The master password is copied to bytes and the stored `String` is
  cleared immediately. The flow is presented as a sheet, so the app keeps its
  single main window (verified by
  `testAddAccountOpensAsASheetWithoutASecondWindow`). Typed error categories
  map to fixed, secret-free messages.

Scope boundaries for this slice:

- **Interactive KDF-change approval is deferred.** A KDF change on a later
  re-authentication fails closed with a clear message until its confirmation
  UI exists. Interactive origin approval is implemented (2026-08-09): a
  config-advertised HTTPS service origin that differs from the entered one
  surfaces an in-sheet approval panel — the one place origins are displayed —
  before any credential-derived data leaves, and a decline or dismissal still
  fails closed. A plaintext-http advertisement (typically a server whose
  `DOMAIN` setting is unset advertising `http://localhost`) is discarded in
  favor of the entered origin without a prompt, since approving it would
  downgrade the transport. First-login same-origin servers — the common case —
  invoke neither policy. Evidence:
  `VaultwardenAuthenticatorTests.testHTTPAdvertisedServiceURLsFallBackToEnteredOriginWithoutApproval`
  and the `AddAccountModelTests` origin-approval cases (present, decline,
  approve-and-use-advertised-host, dismiss-while-pending).
- **No unlock or vault display.** The flow ends at "account configured,
  credentials stored"; unlock, sync, and the vault UI are Workstreams 5-7.
  Reloading the stored credentials on a later launch is Workstream 5.
- **Keychain testing under ad-hoc signing.** The CI host is ad-hoc signed with
  no keychain-access-group entitlement, so the `KeychainCredentialStore`
  round-trip test `XCTSkip`s when the store reports itself unavailable; the
  storage logic (atomic replacement, delete, round-trip) is fully covered by an
  in-memory store, and the add-account flow is driven end to end against the
  `URLProtocol` stub. Real-Keychain behavior on named hardware remains contract
  evidence.

### Provider Choice And Shell Presence Addendum (2026-08-09)

The add-account sheet now opens with a provider choice: Vaultwarden (the
default, functional, its form unchanged) and Proton Pass, listed as staged and
unavailable with an informational pane that collects no credentials, executes
no CLI, performs no CLI presence or version detection, and consumes no
outstanding Workstream 1 evidence. Proton Pass functionality remains gated by
`PROTON_PASS_RESEARCH.md` and its workstream; the pane states that sign-in
stays with the official user-installed CLI. Its wording mirrors the factual
compatibility statements `README.md` already carries — no logo, no
official-client implication — and remains subject to the pre-availability
Proton outreach and legal review `PROTON_PASS_RESEARCH.md` records. `PLAN.md`
("Meaning Of Add Account" and the Workstream 4 deliverable line),
`ARCHITECTURE.md`, and `README.md` were amended in the same change so the
controlling documents and the implementation agree.

The locked shell now distinguishes "no accounts yet" from "vault locked". On
appearance it probes the credential store for record existence only
(`hasCredentials`, a metadata query that loads no secret bytes); this is not
the credential reloading that remains Workstream 5's boundary below. A store
that reports itself unavailable (for example the ad-hoc-signed CI host) keeps
the locked wording — the safe default that claims less than "no accounts
exist" does. A successful add-account reports through `onAccountConfigured`;
failed attempts leave nothing behind except the documented non-secret device
identifier above.

The headless slice's scope note below is retained unchanged.

### Headless Slice

Per PLAN.md, this slice was originally the Phase 0 headless portion of
Workstream 4 and did not pull the add-account UI or storage forward; that
boundary has since been extended by the addendum above, which is the current
scope. The properties below describe the headless authenticator itself and
still hold: tokens and key material stay in memory and the caller owns them.
No real vault or account data is valid test input; every fixture is synthetic
`VSQ-Canary` material.

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
- Generated 16/32/64 px icon review (assets derived and recorded in
  `ICON_PROVENANCE.md` on 2026-08-09; the 1:1 review remains owed).

The Phase 0 crypto/transport proof additionally owes the pinned Vaultwarden
1.37.1 container, private-CA, and reverse-proxy contract lanes named above.
Presence in `main` is not evidence that a criterion passed; a row is marked
passed only when the evidence exists.
