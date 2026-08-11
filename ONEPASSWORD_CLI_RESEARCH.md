# 1Password CLI Provider Research

- Status: accepted third-provider evidence; read-only provider implemented,
  release still gated (see the implementation note below)
- Research date: 2026-08-11
- Candidate integration: official user-installed 1Password CLI (`op`, CLI 2)
  executed as an external process
- Latest stable CLI release observed: 2.38.1, published 2026-07-30; a
  2.38.2-beta.01 followed on 2026-07-31 [OP-RELEASES]
- Documentation host: every `developer.1password.com/docs/cli/*` page observed
  during research issues a permanent redirect to `www.1password.dev`; citations
  below use the destination host

This document answers one question: could VaultSquire support 1Password as an
additional provider through the official 1Password CLI, the way it supports
Proton Pass through `pass-cli`? It records the documented integration surface,
the safety boundaries such a provider would require, and the gates that are not
yet passed.

> Implementation status (added at build time): the scope gate of §1 was
> accepted by the project owner and recorded in
> [ADR 0007](docs/adr/0007-onepassword-third-provider.md); `PLAN.md` now scopes
> three providers. The read-only provider is implemented in
> `VaultSquire/Providers/OnePassword/` — an allowlisted absolute-path locator
> with symlink resolution, a fail-closed version gate, a runner that emits only
> fixed subcommands and validated opaque identifiers, tolerant decoding of the
> documented `vault`/`item`/`whoami` JSON into the shared read projection, and a
> device-sealed snapshot that carries no secret at all. The no-shell bounded
> process executor is now the shared `CLIProcessExecutor` both CLI providers
> run through. Every write stays disabled.
>
> The two remaining gates of §1 are NOT discharged. The terms question (§14) is
> open and blocks any release presenting 1Password support. The TTY-less
> authorization and sandbox spike (§12) has not been run: the command and JSON
> contract follows the documented surface in §5 and §8 and is gated to the
> stable releases in §1, but it has not been exercised against a live CLI in
> this environment. On a real machine the version allowlist
> (`OnePasswordCLIVersionGate.declaredSupportedVersions`), the JSON key
> spellings in `OnePasswordReadModel`, and the `whoami` payload are the points
> to confirm against an installed build. Mismatched output fails closed with an
> honest error, never a false success. All boundary logic is unit-tested over a
> fake executor.

Unlike the Proton research, no source-derived evidence tier exists here: the
`op` binary is proprietary and its terms prohibit reverse engineering (§14).
Every claim in this document is either documented on a mutable 1Password web
page or an explicit VaultSquire assessment, and each documented claim must be
revalidated against the exact tested CLI version before it enters a command
contract.

## 1. Conclusion

A read-first `OnePasswordCLIProvider` is technically credible and fits the
provider seams VaultSquire already built for the Proton CLI: a user-installed
official binary, no-shell bounded execution, opaque-identifier argv, JSON read
contracts gated per tested version, and AEAD-wrapped lossy snapshots. In some
respects the fit is better than Proton's — the CLI's desktop-app integration
means VaultSquire would never touch a 1Password credential at all, item
creation accepts a complete JSON template over standard input, the archive is a
real distinct state, and the macOS install artifacts have a documented
signature-verification procedure — a GPG-signed zip and a pkg with a named
Developer ID Installer certificate [OP-VERIFY].

Three gates stand before any implementation decision, and the first is not an
engineering task:

1. **Terms gate.** 1Password's API and SDK Terms of Service define "Developer
   Tools" to include its CLI tools, grant no affirmative license for the CLI,
   and prohibit using Developer Tools to build a product "that competes
   directly or indirectly with 1Password or the Services, or that replicates a
   substantial portion of the functionality of the Services"
   [OP-API-SDK-TERMS]. A native third-party vault client plausibly does exactly
   that. Written clarification from 1Password or qualified legal review must
   precede implementation, not merely release (§14).
2. **Authorization spike gate.** The only acceptable interactive
   authentication mode — desktop-app integration — documents its macOS session
   credential as derived from the invoking terminal's tty plus start time
   [OP-APP-SECURITY]. VaultSquire spawns CLI processes without a controlling
   terminal. Whether authorization prompts, sessions, or failures result is
   undocumented and must be proven by a standalone spike before any further
   design (§4, §12).
3. **Scope gate.** A `PLAN.md` decision and ADR, as above. *Resolved: accepted
   in [ADR 0007](docs/adr/0007-onepassword-third-provider.md); gates 1 and 2
   remain open and now bind release rather than implementation.*

Binding integration policy, if the provider is adopted:

1. Build `OnePasswordCLIProvider` only after the shared foundations and the
   committed Vaultwarden and Proton work; a third provider never jumps the
   `DELIVERY.md` queue.
2. Delegate every 1Password credential, Secret Key, session, key operation,
   and network exchange to the official CLI and desktop app. VaultSquire never
   collects, proxies, stores, or observes a 1Password account password, Secret
   Key, one-time code, or session token.
3. Support only the desktop-app-integration authentication mode. Manual
   sign-in (session tokens in environment variables or argv) and service
   accounts (bearer token in an environment variable, no access to built-in
   personal vaults) are rejected as prohibited secret channels (§4).
4. Require reads through a tested machine-readable command contract and fail
   closed on unsupported versions, build identities, or output schemas.
5. Treat CLI JSON as decrypted and lossy. Wrap every persisted snapshot with
   VaultSquire AEAD under a device-only Keychain key before persistence; never
   call it 1Password-native ciphertext.
6. Never synthesize a write from the lossy snapshot. Enable a write only when
   the exact tested command accepts all private input over standard input or
   another reviewed protected channel, then refresh after success or
   ambiguity. Under this rule item creation is the only current candidate;
   item edit stays disabled (§8).
7. Never copy, bundle, vendor, or link 1Password software. The terms prohibit
   distributing the CLI, and the user installs it themselves (§14).
8. Complete terms, trademark, and disclosure review before implementation
   begins, because the competing-product clause reaches development, not only
   distribution (§14).

## 2. Evidence Classification

| Label | Meaning |
|---|---|
| Documented | A 1Password product, developer, or legal page states it |
| Assessment | VaultSquire engineering recommendation or risk conclusion |
| Unknown | No public statement was found |

There is no source-derived tier: the CLI is closed source, so behavior that the
documentation does not state can only be established by black-box fixtures
against a specific tested binary. The cited pages are mutable and were not
archived; §References records the access date and the caveat.

## 3. Supported Integration Surface

### Documented Features

1Password's developer surface relevant to an interactive desktop client:

- the 1Password CLI (`op`), positioned for terminal use, scripting, secret
  injection, and item management, with biometric sign-in through the desktop
  app [OP-CLI] [OP-GET-STARTED];
- desktop-app integration: the CLI authenticates through the installed
  1Password app with Touch ID or system authentication instead of a typed
  password [OP-APP-INTEGRATION] [OP-BIOMETRIC];
- service accounts: machine authentication through a bearer token in the
  `OP_SERVICE_ACCOUNT_TOKEN` environment variable, vault-scoped at creation,
  rate limited, and barred from built-in Personal/Private/Employee vaults
  [OP-SA-CLI] [OP-SA-SECURITY] [OP-SDKS];
- 1Password Connect: a self-hosted server exposing a private REST API for a
  company's own infrastructure [OP-CONNECT];
- official SDKs for Go, JavaScript, and Python, currently version 0, which
  support both service-account tokens and a desktop-app authentication mode
  described as best "for integrations that run locally on a user's machine"
  [OP-SDKS] [OP-SDKS-CONCEPTS].

The CLI supports macOS Big Sur 11.0.0 or later, Windows, and Linux; macOS
installation is Homebrew (`brew install 1password-cli`), a `.pkg` installer
targeting `/usr/local/bin`, or a manual zip [OP-GET-STARTED]. A paid 1Password
subscription is listed as a requirement [OP-GET-STARTED]. Stable releases in
2026 arrived roughly monthly to quarterly with interleaved betas: 2.33.1
(2026-03-24), 2.34.0 (2026-04-16), 2.34.1 (2026-06-10), 2.35.0 (2026-07-10),
2.38.1 (2026-07-30); 2.36.x and 2.37.x shipped only as betas [OP-RELEASES].

### Surfaces Not Found

The research did not find a documented public surface for:

- any JSON output schema, or a stability/versioning policy for the JSON that
  `--format json` emits — the reference documents the switch but never the
  payload shape or its compatibility across releases [OP-REFERENCE];
- a breaking-change policy inside CLI 2 (the only documented break is the
  v1-to-v2 migration, where updated scripts stopped working on v1
  [OP-UPGRADE]);
- a Swift or other native-macOS SDK (only Go, JavaScript, Python exist
  [OP-SDKS]);
- a third-party client review, certification, or compatibility program;
- pagination, result limits, or documented maximums for `vault list`,
  `item list`, or `document list`;
- an event cursor or incremental-sync interface in the CLI;
- rate limits for interactive (non-service-account) CLI use — the item
  reference alludes to "API rate limits" without numbers [OP-ITEM];
- an affirmative license grant covering execution of the CLI by a third-party
  application (§14);
- any statement about invoking `op` from a process without a controlling
  terminal, from a sandboxed app, or over SSH.

These are absence findings; private or future interfaces may exist.

### The Official SDKs Are Not Yet An Alternative

The SDK route deserves a note because its documentation, unlike the CLI's,
describes exactly VaultSquire's shape: "integrations that run locally on a
user's machine" with "human-in-the-loop approval" through desktop-app
authorization prompts, granting temporary access that expires after ten
minutes of inactivity [OP-SDKS-CONCEPTS]. The API and SDK Terms also contain
the one affirmative distribution grant 1Password offers: the SDK may be
incorporated and distributed "in object code form only, as part of an
Application" [OP-API-SDK-TERMS]. The SDK functionality matrix covers full item and vault
management including archiving [OP-SDKS-FUNCTIONALITY]. But no Swift SDK
exists, version 0 carries possible breaking changes between minor releases
with three months of support per version [OP-SDKS], and embedding a Go or
JavaScript runtime inside a native Swift app fails VaultSquire's dependency
policy. Assessment: reassess
the SDK route if 1Password ships a stable native SDK usable from Swift; the
competing-product clause applies to it equally (§14).

## 4. Authentication And Session Model

### Documented Modes

| Mode | Intended use | Relevant constraints |
|---|---|---|
| Desktop-app integration | Interactive accounts on a machine with the 1Password app | OS biometric/system-auth prompt per terminal session; no session token |
| Manual sign-in | Interactive accounts without the app | Prompts for sign-in address, email, Secret Key, account password; emits a session token via `OP_SESSION` or `--session` |
| Service account | Automation | `OP_SERVICE_ACCOUNT_TOKEN` environment variable; vault-scoped; no built-in personal vault |
| Connect | Self-hosted infrastructure | Credentials file and access tokens on a server |

### Desktop-App Integration Mechanics

The security page documents the macOS design precisely [OP-APP-SECURITY]:

- the app exposes an XPC service ("1Password Browser Helper"); both the CLI
  and the app connect to it, and "authenticity of both is confirmed by
  verifying the code signature";
- when `op` needs authorization, the OS-native biometric (or device-password)
  prompt is shown, naming the account and "the process being authorized (for
  example, iTerm2 or Terminal)";
- authorization creates a 10-minute session that refreshes on use, with a
  12-hour hard cap; it is scoped per terminal window and extends to sub-shell
  processes in that window;
- the macOS session credential "is an ID that's based on the current tty,
  plus the start time";
- locking the 1Password app revokes all prior CLI authorization; authorizing
  while the app is locked unlocks the app; an in-flight `op` process is
  allowed to finish after revocation;
- documented accepted risks: a root/administrator process can circumvent the
  measures while the app is unlocked, and a macOS app holding Accessibility
  permission may be able to bypass the authorization prompt;
- the app logs CLI activity — the command, time, invoking application, and
  account — by default [OP-APP-INTEGRATION].

Under this mode no session token exists to handle: the reference states the
CLI "outputs session tokens for successful `op signin` commands when
1Password app integration is not enabled" [OP-REFERENCE], and the documented
flow is simply to run a command and confirm the prompt [OP-APP-INTEGRATION].
Assessment: this is the only mode compatible with VaultSquire's invariants.
It also means the 1Password desktop app — installed, running, with
"Integrate with 1Password CLI" enabled — becomes a hard runtime dependency
alongside the CLI itself.

### The TTY-Less Unknown

Every documented description of app-integration scope assumes a terminal:
per-window authorization, tty-derived session credentials, sub-shell
inheritance. VaultSquire executes CLI processes through `Foundation.Process`
with pipes and standard input bound to the null device — no controlling
terminal exists. The documentation is silent on what happens then.

**Partially answered on 2026-08-11.** Against CLI 2.38.1 with app integration
enabled, an account-scoped read succeeded from a fully cleared environment
(`env -i` with only `HOME`, `LANG`, `LC_ALL`, `PATH`, and
`OP_BIOMETRIC_UNLOCK_ENABLED`) with standard input bound to `/dev/null`, and
raised the biometric prompt normally. So the environment allowlist and the
null-device stdin — the two things VaultSquire controls — are not obstacles.
What remains untested is the last step: that observation came from a shell that
still owned a tty, so a process with *no* controlling terminal at all is still
unproven. The spike below is narrowed to that question rather than closed.

The spike must establish which of the following occurs, and the provider must
fail closed on all of them until proven:

- each invocation (or some grouping of invocations) triggers an authorization
  prompt naming VaultSquire, and succeeds;
- invocations fail because no session credential can be constructed;
- authorization succeeds but with session semantics different from the
  documented tty scoping.

The prompt-per-invocation case has a usability consequence the product must
accept honestly: a vault refresh is one prompt only if a session forms, and
possibly many if it does not.

### Manual Sign-In And Service Accounts Are Rejected

Manual mode requires `op account add`, which interactively collects the
sign-in address, email, Secret Key, and account password — the page requires
turning app integration off first — and then delivers a session token through
`eval $(op signin)` into the `OP_SESSION` environment variable or via `--raw`
for manual export, expiring after 30 minutes of inactivity [OP-SIGNIN-MANUAL]
[OP-SIGNIN] [OP-ACCOUNT]. The global `--session` flag places the token in
argv [OP-REFERENCE]. 1Password's own documentation warns that with manual
sign-in "any process running under the current user can, on some platforms,
potentially access your 1Password account" [OP-SIGNIN-MANUAL]. Every delivery
channel this mode offers — environment variable, argv, captured stdout token
— is prohibited by VaultSquire's security invariants, and VaultSquire could
not launch the interactive collection without owning a credential flow it
must never own. The mode is rejected, not deferred.

Service accounts authenticate through `OP_SERVICE_ACCOUNT_TOKEN` — a bearer
secret in an environment variable, again a prohibited channel — and
additionally "can't access your built-in Personal, Private, or Employee
vault" [OP-SDKS], carry hard hourly/daily rate limits [OP-SA-RATE-LIMITS],
and support only a command subset [OP-SA-CLI]. They are automation
credentials, not an end-user vault surface. Rejected.

### Account Selection

Multiple accounts are supported; the `--account` flag accepts an account ID
or user ID as well as a sign-in address or shorthand [OP-REFERENCE], so
account routing can use reviewed opaque identifiers. The documented default
when no account is specified differs subtly between pages (most recent
sign-in "in any terminal window" versus "in the current terminal"
[OP-SIGNIN] [OP-ACCOUNT]); VaultSquire must always pass `--account`
explicitly rather than rely on that ambiguity.

## 5. Provider-Native Data Model

### Identity

Accounts contain vaults; vaults contain items. Documented example identifiers
are 26-character lowercase alphanumeric strings for items and vaults and a
26-character uppercase string for users, but no page documents the format,
character set, or uniqueness scope of any identifier [OP-ITEM]
[OP-ITEM-TEMPLATE]. Two documented behaviors constrain identity handling:

- the docs recommend IDs over names for disambiguation and rate limits
  ("If you have multiple items with the same name, or if you're concerned
  about API rate limits, specify the item by its ID") [OP-ITEM];
- `op item move` "creates a copy of the item in the destination vault and
  deletes the item from the current vault. As a result, the item gets a new
  ID" [OP-ITEM].

Required local identity shape, matching the core's compound rule:

```text
ProviderAccountID
ProviderVaultID
ProviderItemKey = ProviderAccountID + ProviderVaultID + ProviderItemID
```

An item ID must never be assumed globally unique or stable across vault
moves; a cross-vault move is modeled as delete-plus-create, never as a
container-field update.

### Items, Categories, And Fields

The item-fields page lists 22 categories (API Credential, Bank Account,
Credit Card, Crypto Wallet, Database, Document, Driver License, Email
Account, Identity, Login, Medical Record, Membership, Outdoor License,
Passport, Password, Reward Program, Secure Note, Server, Social Security
Number, Software License, SSH Key, Wireless Router) [OP-ITEM-FIELDS]; the
item reference lists only 19, omitting Crypto Wallet, Medical Record, and SSH
Key [OP-ITEM]. Assessment: a documentation discrepancy to resolve per tested
version; map only categories whose fields project losslessly and present the
rest as explicitly unsupported records, as the shared projection rules
require.

The only complete item JSON example in the documentation shows top-level keys
`id`, `title`, `version` (integer), `vault {id}`, `category`,
`last_edited_by`, `created_at`, `updated_at`, `sections[]`, and `fields[]`;
fields carry `id`, `type`, `label`, `value`, optional `purpose` (observed:
`USERNAME`, `PASSWORD`, `NOTES`) and an optional nested `section`
[OP-ITEM-TEMPLATE]. Documented assignment field types map to JSON types
`CONCEALED`, `STRING`, `EMAIL`, `URL`, `DATE`, `MONTH_YEAR`, `PHONE`, `OTP`,
plus a `file` assignment type with no JSON form [OP-ITEM-FIELDS]; a `MENU`
type appears in the example JSON without appearing in the field-type table.
Item templates "are formatted similarly to the JSON output for
`op item get`" [OP-ITEM-TEMPLATE]. No key for favorite, tags, website URLs,
archive state, or file attachments appears in any documented item JSON, even
though `--favorite`, `--tags`, and `--url` flags exist — the complete
at-rest JSON shape is undocumented and must come from fixtures.

TOTP is stored as an `OTP`-type field whose value is an `otpauth://` URI; the
current code is retrieved with `op item get <item> --otp` [OP-ITEM]. Whether
JSON output carries a computed code, and whether concealed values appear in
JSON at all or only under `--reveal`, is undocumented — a fixture question
with direct leakage consequences (§8).

Passkeys are embedded in items and are not representable in JSON templates:
"If you use a JSON template to update an item that contains a passkey, the
passkey will be overwritten", with recovery only through item history in the
official apps [OP-ITEM-EDIT-GUIDE].

### Item States

1Password has three documented non-active dispositions, and they are not
interchangeable:

- **Archive.** `op item delete --archive` moves an item to the Archive; `get`
  and `list` ignore archived items unless the item is addressed by ID or
  `--include-archive` is passed [OP-ITEM]. No CLI command to unarchive or
  restore was found — the reference lists only create, delete, edit, get,
  list, move, share, and template subcommands.
- **Recently Deleted.** Plain `op item delete` is recoverable: "Deleted items
  remain available for 30 days in Recently Deleted. You can restore or
  permanently delete items from Recently Deleted in the 1Password apps"
  [OP-ITEM] — restore is an app feature, not a CLI feature, and no CLI
  surface lists Recently Deleted contents.
- **Permanent deletion.** Documented only as a Recently Deleted action inside
  the official apps.

Assessment: archive maps naturally onto VaultSquire's existing archived-state
reads, but the write is one-way from the CLI; the UI must not present an
unarchive action it cannot perform, and must not describe deletion as either
permanent or as Vaultwarden-style trash. Vaults additionally support Travel
Mode, which hides non-travel-safe vaults from the user's apps when active
[OP-VAULT]; a vault disappearing from a listing is therefore not evidence of
deletion.

### Vault Permissions

Teams and Families expose three vault permissions; Business adds granular
ones (view_items, view_and_copy_passwords, view_item_history, create_items,
edit_items, archive_items, delete_items, and others) [OP-VAULT]. Capabilities
must be derived from tested behavior per account and vault, never from a plan
name.

## 6. Cryptographic Model

The documentation observed for this research documents credentials, not
cryptography: manual account setup collects an account password and a Secret
Key [OP-SIGNIN-MANUAL], and the CLI's caching daemon "stores encrypted
information in memory ... It can read the information to pass to 1Password
CLI, but can't decrypt it" [OP-REFERENCE]. The encryption design itself is
implemented in closed-source software, and the terms prohibit attempting to
derive it (§14).

The consequence is the same delegation the Proton provider already made, in a
stricter form: with Proton, pinned source explains the key hierarchy the CLI
protects; with 1Password, no inspectable model exists at all. The official
CLI and desktop app own authentication, the Secret Key, key derivation,
decryption, and rotation. VaultSquire sees only bounded machine output,
wraps any persisted snapshot with its own AEAD envelope under a device-only
Keychain key, and never implements or models 1Password cryptography.

## 7. Sync And Conflict Model

No event stream, cursor, revision precondition, or conflict-handling behavior
is documented for the CLI. The item JSON carries an integer `version` whose
semantics no page explains, and `op item edit` documents no concurrency
control. Item IDs change on cross-vault moves (§5), so even identity is not
stable between refreshes.

`OnePasswordCLIProvider` therefore follows the Proton sync posture exactly:

- full CLI refreshes into a validated, AEAD-wrapped snapshot published
  atomically, with the prior complete generation retained on failure;
- no invented cursors, no offline write queue, no synthesized reconciliation;
- a remote write, where one is ever enabled, is followed by a full refresh
  before final state is presented;
- commands serialized per account, with listing kept metadata-lean and secret
  fetches deferred to item-open (the lesson the Proton provider already
  encodes: per-item CLI calls during listing made a real vault take minutes,
  and the reference's rate-limit allusion argues the same restraint here)
  [OP-ITEM].

## 8. CLI Capability Assessment

| Capability | Public CLI suitability for VaultSquire |
|---|---|
| Desktop-app-integration auth | Strong candidate; TTY-less invocation behavior undocumented and gates everything (§4, §12) |
| Manual/service-account auth | Rejected: session or bearer tokens in environment, argv, or captured stdout |
| Vault and item listing | Required after versioned JSON contract tests; opaque IDs in argv only |
| Secret item viewing | Required with bounded transient stdout; concealment behavior of JSON output is undocumented and needs leakage fixtures before use |
| TOTP | `--otp` per item, or local RFC 6238 computation from the stored `otpauth://` URI as already done for Vaultwarden; decide per fixture evidence |
| Core item creation | Primary write candidate: a complete JSON template, including concealed values, is documented over standard input (`op item create -`), and 1Password's own docs steer sensitive values away from argv |
| Item update | Disabled. Field assignments place values in argv ("Command arguments can be visible to other processes on your machine"); the template path requires reconstructing the full item from lossy JSON, which the write rules prohibit, and it destroys passkeys |
| Trash/delete | Candidate after semantics fixtures: recoverable for 30 days in Recently Deleted, restore only in official apps; must be worded honestly, neither as permanent nor as Vaultwarden trash |
| Archive | One-way candidate (`op item delete --archive`); no unarchive command found, so the action ships without an inverse or not at all |
| Favorites, tags, titles via flags | Disabled: `--favorite`, `--tags`, `--title` carry user-authored values in argv; title travels inside the create template instead |
| Documents/files | Read candidate later: `op document get` streams to stdout with bounds; file attachment upload uses argv paths and needs its own review |
| Item move / item share | Out of scope: move rewrites identity; share has documented exclusions and no product need |
| Event cursor/incremental sync | Not documented; full refresh only |
| Offline read | Supported only from a VaultSquire AEAD-wrapped lossy snapshot |
| Offline write | Unsupported; no conflict contract exists |
| Stable JSON contract | No promise found; pin exact versions and fail closed |

### Current Command-Surface Observations

Verified against the pages cited, as of 2026-08-11; revalidate against each
tested CLI version before use:

- Selectors accept opaque identifiers everywhere VaultSquire needs them:
  `op vault get { <vaultName> | <vaultID> | - }`,
  `op item get { <itemName> | <itemID> | <shareLink> | - }`, and `--account`
  by account ID [OP-VAULT] [OP-ITEM] [OP-REFERENCE]. The per-command
  `--vault` flag's description does not state name-versus-ID; fixtures must
  confirm it accepts IDs, and VaultSquire never passes a user-chosen name in
  argv either way.
- `op item create [ - ] [ <assignment>... ]` documents piping a complete JSON
  template through standard input ("Pass the - character as the first
  argument"), with the template able to carry `CONCEALED` values; `--dry-run`
  offers a preflight preview; piped input and `--template` (a file path) are
  mutually exclusive, and the file path variant is rejected because it
  materializes secrets in a plaintext file [OP-ITEM] [OP-ITEM-CREATE-GUIDE]
  [OP-ITEM-TEMPLATE].
- `op item edit` accepts argv assignments (prohibited for private values by
  1Password's own warning and VaultSquire's invariants) or a whole-item
  template; the documented template workflow is dump-JSON, edit, re-submit —
  read-modify-write over lossy output, which the write rules prohibit
  [OP-ITEM-EDIT-GUIDE].
- `op read` resolves `op://` secret references that embed vault/item/field
  names by default; identifiers are documented substitutes. VaultSquire has
  no need for `op read` while `item get` by ID suffices; if ever used, only
  ID-form references pass review [OP-READ] [OP-SECRET-REFS]
  [OP-SECRET-REF-SYNTAX].
- Output shaping uses non-secret global flags (`--format json`,
  `--iso-timestamps`, `--no-color`); equivalent `OP_*` environment toggles
  exist but VaultSquire keeps its fixed minimal environment and passes flags
  instead [OP-REFERENCE] [OP-ENV-VARS].
- A caching daemon on UNIX-like systems holds encrypted account data in
  memory ("can't decrypt it"), controlled by `--cache` (default on). What it
  stores and where is otherwise undocumented; the provider disables or
  reviews it per tested version rather than inheriting defaults [OP-REFERENCE].
- The global `--session` flag exists and must never be used (§4).
- **Corrected against a live CLI 2.38.1 on 2026-08-11.** `op whoami` is a
  *status query*: with no established session it prints
  `[ERROR] account is not signed in` and exits 1 rather than starting the
  authorization ceremony. It is therefore useless as a probe — a client that
  gates on it fails on every fresh session regardless of how the machine is
  configured. `op account list --format json` is the correct discovery call:
  it reads local configuration, needs no authorization, raises no prompt, and
  returns `url`, `email`, `user_uuid`, and `account_uuid` per account.
  Authorization is established by the first *real* read; an account-scoped
  `op vault list --format json --account ACCOUNT_UUID` raises the biometric
  prompt and then succeeds.
- Config resolution is documented: `--config` flag, then `OP_CONFIG_DIR`,
  then legacy `~/.op`-style paths, then `~/.config/op` [OP-CONFIG-DIRS].
  VaultSquire passes `HOME` through unchanged and never relocates the CLI's
  configuration, matching the Proton executor's environment rule.

## 9. Integration Route Comparison

| Route | Fidelity | Stability | License/distribution | Recommendation |
|---|---|---|---|---|
| User-installed CLI subprocess | Read-heavy subset plus gated create | CLI supported; JSON shape and embedding not promised | No distribution by VaultSquire; execution-license question open (§14) | Candidate route |
| Bundled CLI | Same subset | Same contract risk | Terms prohibit making Developer Tools available to third parties | Do not use |
| Embed official SDK | High per functionality matrix | Version 0, breaking changes, 3-month support windows | Object-code distribution affirmatively licensed, but no Swift SDK | Reassess if a stable Swift-usable SDK ships |
| Service accounts / Connect | Automation subset | Supported for automation | Token in environment; no personal vaults; self-hosted server | Do not use for an end-user client |
| Independent private API | Potentially high | Highest drift risk | Reverse engineering contractually prohibited | Do not use |

The CLI route does not become a private-API fallback when a command is
inadequate: an operation the CLI cannot expose safely is presented as
unsupported, exactly as with Proton.

## 10. VaultSquire Architecture Seams

### Reuse

The Proton workstream built the seams a second CLI provider needs, and ADR
0002 names a third provider as the moment to check whether they generalize
without moving provider-specific security rules into shared code:

- the no-shell bounded process executor (`ProtonCLIProcessExecutor`): fixed
  environment allowlist with `HOME` passthrough, argument-vector-only
  invocation, bounded captured stdout, stderr counted and discarded, timeout,
  cancellation, and kill-escalation — provider-neutral machinery that either
  becomes shared infrastructure or is deliberately duplicated per the ADR
  review;
- the allowlisted absolute-path locator with symlink resolution — for `op`
  the candidate list is `/usr/local/bin/op` (pkg default; also the location
  the upgrade doc requires, and the only supported location for Mac app
  versions 8.10.12 and earlier) and `/opt/homebrew/bin/op` (Homebrew on Apple
  Silicon) [OP-GET-STARTED] [OP-UPGRADE] [OP-BIOMETRIC];
- the fail-closed version gate, fed by the releases feed [OP-RELEASES], with
  betas never allowlisted;
- the AEAD cache envelope with `lossy: true` fidelity metadata and a separate
  device-only, user-presence-bound Keychain key, because — as with Proton —
  that key is the only gate on cached 1Password content;
- per-action capability manifests and the shared read projection.

Swift type names cannot begin with a digit, so the provider namespace is
`OnePasswordCLIProvider`/`OnePasswordCLI*`, with the user-facing name
remaining "1Password" in factual compatibility wording only (§14).

### Executable Identity

1Password documents binary verification for macOS: a GPG signature for the
zip download (key fingerprint `3FEF9748469ADBE15DA7CA80AC2D62742012EA22`) and
a pkg whose installer certificate must read "Developer ID Installer:
AgileBits Inc. (2BUA8C4S2C)" [OP-VERIFY]. Assessment: this is a stronger
identity story than the Proton CLI's package-manager builds. The provider
inspects and displays the resolved path and code-signature status honestly,
including for Homebrew installs whose signing state must be established by
the spike rather than assumed.

### Runtime Dependency Shape

Unlike Proton, correct operation requires two user-installed components: the
CLI and the desktop app with "Integrate with 1Password CLI" enabled and the
app unlockable. Status detection must distinguish, and fail closed with
honest messages for: CLI missing, app missing or integration disabled, app
locked, authorization declined, unsupported version, and unparseable output.
1Password documents that an in-flight CLI process may finish after
authorization is revoked [OP-APP-SECURITY]; VaultSquire's own lock semantics
still terminate its child processes, which covers VaultSquire's side of that
window.

## 11. What Must Not Be Generalized

Do not encode these assumptions in the core:

- a Secret Key is a password, a second factor, or something VaultSquire may
  ever collect;
- 1Password's Archive, Recently Deleted, Vaultwarden's per-user archive, and
  Proton's trash are the same state, or map onto each other;
- an item ID is globally unique, or stable across a cross-vault move;
- the integer item `version` is a revision precondition or comparable to
  Vaultwarden's revision dates;
- a 1Password vault is a Vaultwarden organization or a Proton share;
- vault visibility implies vault existence (Travel Mode hides vaults);
- permissions with the same English name grant the same actions across plans
  or providers;
- a passkey survives a round-trip that the provider's write surface performs;
- the desktop app's unlock state is VaultSquire's lock state — they are
  independent gates and both must hold;
- every provider exposes incremental sync, cursors, or conflict primitives.

## 12. Candidate CLI Provider Plan

### Preconditions

- A `PLAN.md` scope decision and provider-boundary ADR review accept the
  third provider (§1).
- The terms question in §14 is resolved in writing before implementation.
- A standalone unpublished harness establishes the process and JSON
  contracts before anything enters the application, using disposable test
  accounts only.
- The user installs both the official CLI and the desktop app; VaultSquire
  bundles neither.
- Read capability ships only for declared tested versions; every write
  starts disabled behind an operation-specific capability manifest.

### Phase-0-Style Spike, Before Any Design Commitment

1. **TTY-less authorization.** Drive a real `op` build through the executor
   seam (no shell, pipes, null stdin) against a disposable account with app
   integration enabled. Establish which of the §4 outcomes occurs, what the
   authorization prompt names as the invoking process, whether a session
   forms across invocations, and what the failure modes look like. Every
   outcome must be mappable to a fail-closed user-visible state.
2. **Sandbox feasibility.** Repeat under App Sandbox inheritance using the
   existing sandbox-probe scheme: the child must reach the desktop app's XPC
   service and its own configuration directory. If the sandbox blocks safe
   operation, the reviewed direct Developer ID Hardened Runtime fallback
   applies, as already decided for Proton.
3. **Leakage fixtures.** Confirm where concealed values appear (`item get`
   JSON with and without `--reveal`, `item list` output, stderr on failure)
   before any output-handling code is written, so bounds and redaction are
   designed against observed behavior.
4. **Multiple accounts.** A person may have several 1Password accounts signed
   in at once. Confirmed on 2026-08-11: with two configured, no default
   resolves, so an unscoped command fails. Every account-bearing command must
   name its account, and each account is its own VaultSquire vault.

### Process Boundary

The Proton process rules apply verbatim — no shell, allowlisted absolute
path, exact version allowlist, bounded and serialized execution, stdout as
untrusted data, stderr treated as secret-bearing and never persisted,
termination on lock/logout/sleep/account removal, no secrets or user-authored
values in argv or environment, opaque identifiers only after command-level
review — with these 1Password-specific additions:

- never set `OP_SESSION`, `OP_SERVICE_ACCOUNT_TOKEN`, `OP_CONNECT_*`, or the
  `--session` flag; the environment stays the fixed minimal allowlist with
  `HOME` passed through;
- never toggle the user's app-integration setting or relocate the CLI's
  configuration directory;
- treat the desktop app's authorization prompt as the credential ceremony:
  VaultSquire never wraps, automates, or proxies it, and surfaces a declined
  authorization as a normal recoverable state.

### Data Flow

1. Verify binary identity/version and authenticated status.
2. Fetch account and vault metadata by opaque identifiers.
3. Fetch item summaries per vault; never fetch secrets during listing.
4. Construct compound account/vault/item identities.
5. Validate bounds and schema; treat the result as a versioned, lossy
   snapshot.
6. Wrap the validated snapshot with VaultSquire AEAD under the device-only
   Keychain key and publish atomically, retaining the prior generation on
   failure.
7. Serve list/search from the in-memory projection; fetch full item content
   only when an item is opened, holding secrets for the session only.
8. Refresh on explicit user action or approved triggers, only while the
   VaultSquire cache context is unlocked.

### Write Capability Flow

Identical to the Proton write gates: exact command and schema recorded per
CLI version; complete private input over standard input only; content built
solely from current explicit user input plus reviewed opaque identifiers;
bounded execution; full refresh after success or ambiguity; cross-read of
every successful synthetic write with an official 1Password client;
automatic capability disable on version or schema drift. Current evidence
ranks the candidates: create first (documented stdin template), then
archive/delete after their semantics fixtures; edit remains disabled until
the CLI offers a non-argv, non-reconstruction path that also preserves
passkeys.

## 13. Production Contract And Outreach Questions

Ask 1Password to answer in writing:

- May a native third-party interactive vault client integrate through the
  CLI, given the API and SDK Terms' competing-product and
  functionality-replication clauses?
- Which agreement licenses a third-party application's execution of the
  user-installed CLI, given the Terms grant covers only APIs and SDKs?
- Is there, or will there be, a stable native SDK usable from Swift, and is
  the SDK's desktop-app authentication the recommended surface for a client
  like this?
- Is invoking `op` from a GUI process without a controlling terminal a
  supported configuration under desktop-app integration, and what session
  semantics apply?
- Will the CLI's JSON output get a documented schema or stability policy?
- What rate limits apply to interactive (non-service-account) CLI use?
- What are the Section 5 disclosure obligations in practice for a local
  client, and where are the Media Kit and Brand Guidelines that Section 7
  incorporates?
- Can `item edit` gain a complete-input stdin path that preserves passkeys?
- Is there a supported CLI path to unarchive or restore items?

Production support stops if the terms question resolves against the
integration, the spike cannot establish safe TTY-less authorization, no
tested machine-readable read contract holds, or neither App Sandbox nor the
reviewed direct-build fallback supports the process boundary. None of those
outcomes redirects VaultSquire to a private API.

## 14. Licensing, Terms, And Branding

This is engineering guidance, not legal advice.

- The `op` binary is proprietary. No source repository for the CLI exists in
  1Password's GitHub organization (which does publish MIT-licensed SDKs,
  wrappers, and shell plugins) [OP-GITHUB], the docs contain no license
  statement for the binary, and the legal index lists no CLI EULA
  [OP-LEGAL-INDEX].
- The API and SDK Terms of Service (last updated 2026-06-16) define
  "Developer Tools" to include "CLI tools (excluding any components released
  under an open source license)". Its license grant has two subsections —
  APIs and SDKs — and none for CLI tools. It prohibits, among other things:
  "sublicense, sell, resell, transfer, assign, rent, lease, loan, distribute,
  or otherwise make the Developer Tools available to any third party";
  reverse engineering; and "use the Developer Tools to build, operate, or
  offer any product or service that competes directly or indirectly with
  1Password or the Services, or that replicates a substantial portion of the
  functionality of the Services" [OP-API-SDK-TERMS].
- The same terms define "Application" broadly ("any software application ...
  that you develop using the Developer Tools"), impose disclosure obligations
  on Applications (Section 5), grant only a limited revocable trademark
  license governed by 1Password's Media Kit and Brand Guidelines (Section 7),
  and allow 1Password to terminate Developer Tools access at will
  [OP-API-SDK-TERMS].
- The general Terms of Service (last updated 2024-09-12) sweep 1Password
  software into "the Service", prohibit reverse engineering and building
  competitive products with the Services, grant no trademark rights, and
  condition access on a paid subscription [OP-TERMS].
- Assessment of the central question: a native macOS client that lists,
  reveals, creates, and archives 1Password items replicates part of what the
  official apps do. Whether that constitutes "a substantial portion of the
  functionality of the Services", and whether merely executing the user's
  own CLI makes VaultSquire an "Application ... developed using the
  Developer Tools", are questions this project cannot answer for itself.
  Contrast Proton: its terms raised automation-abuse questions requiring
  review before general availability, while 1Password's clause targets
  building the product at all. That is why §1 places legal review before
  implementation rather than before release.
- Whether the `.pkg`/zip distribution embeds a click-through EULA not
  surfaced in the web documentation was not checked and belongs in the
  spike.
- VaultSquire never redistributes the CLI (the terms prohibit it) and never
  uses 1Password logos or implies endorsement. Any eventual compatibility
  wording is factual and secondary, and follows the outreach in §13.

## 15. Final Recommendation

Yes, VaultSquire could support 1Password — as a read-first
`OnePasswordCLIProvider` executing the official user-installed CLI under
desktop-app-integration authentication, reusing the process, version-gate,
cache-envelope, and capability seams the Proton provider proved. The
technical fit is as good as or better than the Proton CLI's: no credential
ever enters VaultSquire, creation has a documented complete-input stdin
path, archive is a real state, and the binary has a documented signed
identity.

The scope gate has since been accepted and the read-only provider built to the
plan in §12. Two gates remain, and they now bind release rather than
implementation:

1. written resolution of the API and SDK Terms question — the
   competing-product and functionality-replication clause is the single
   sharpest external risk this project has recorded for any provider;
2. the TTY-less authorization and sandbox spike, which decides whether the
   only acceptable authentication mode works at all from a GUI app.

If either fails, VaultSquire records 1Password as unsupported and withdraws the
provider rather than weakening an invariant to force the integration.

## References

All links were accessed on 2026-08-11. The pages are mutable and no archive
or content hash was captured, so their exact historical state is not
reproducible from this repository. Treat claims based on them as unpinned
paraphrases and recheck each page — including the terms' last-updated dates —
before use. During research, every `developer.1password.com/docs/cli/*` URL
issued a permanent redirect to `www.1password.dev`; the destination pages are
cited. Release versions and dates come from the product-history feed
[OP-RELEASES], the only page observed to carry them.

[OP-ACCOUNT]: https://www.1password.dev/cli/reference/management-commands/account
[OP-API-SDK-TERMS]: https://1password.com/legal/api-sdk-terms-of-service
[OP-APP-INTEGRATION]: https://www.1password.dev/cli/app-integration
[OP-APP-SECURITY]: https://www.1password.dev/cli/app-integration-security
[OP-BIOMETRIC]: https://www.1password.dev/cli/about-biometric-unlock
[OP-CLI]: https://www.1password.dev/cli
[OP-CONFIG-DIRS]: https://www.1password.dev/cli/config-directories
[OP-CONNECT]: https://www.1password.dev/connect
[OP-ENV-VARS]: https://www.1password.dev/cli/environment-variables
[OP-GET-STARTED]: https://www.1password.dev/cli/get-started
[OP-GITHUB]: https://github.com/orgs/1Password/repositories?q=cli
[OP-ITEM]: https://www.1password.dev/cli/reference/management-commands/item
[OP-ITEM-CREATE-GUIDE]: https://www.1password.dev/cli/item-create
[OP-ITEM-EDIT-GUIDE]: https://www.1password.dev/cli/item-edit
[OP-ITEM-FIELDS]: https://www.1password.dev/cli/item-fields
[OP-ITEM-TEMPLATE]: https://www.1password.dev/cli/item-template-json
[OP-LEGAL-INDEX]: https://1password.com/legal-center
[OP-READ]: https://www.1password.dev/cli/reference/commands/read
[OP-REFERENCE]: https://www.1password.dev/cli/reference
[OP-RELEASES]: https://app-updates.agilebits.com/product_history/CLI2
[OP-SA-CLI]: https://www.1password.dev/service-accounts/use-with-1password-cli
[OP-SA-RATE-LIMITS]: https://www.1password.dev/service-accounts/rate-limits
[OP-SA-SECURITY]: https://www.1password.dev/service-accounts/security
[OP-SDKS]: https://www.1password.dev/sdks
[OP-SDKS-CONCEPTS]: https://www.1password.dev/sdks/concepts
[OP-SDKS-FUNCTIONALITY]: https://www.1password.dev/sdks/functionality
[OP-SECRET-REF-SYNTAX]: https://www.1password.dev/cli/secret-reference-syntax
[OP-SECRET-REFS]: https://www.1password.dev/cli/secret-references
[OP-SIGNIN]: https://www.1password.dev/cli/reference/commands/signin
[OP-SIGNIN-MANUAL]: https://www.1password.dev/cli/sign-in-manually
[OP-TERMS]: https://1password.com/legal/terms-of-service
[OP-UPGRADE]: https://www.1password.dev/cli/upgrade
[OP-VAULT]: https://www.1password.dev/cli/reference/management-commands/vault
[OP-VERIFY]: https://www.1password.dev/cli/verify
