# ADR 0007: 1Password As A Third Provider, And One Shared Process Runner

- Status: Accepted
- Date: 2026-08-11
- Owners: `L-K-M`
- Controlling documents/sections: `PLAN.md` sections 1 and 6 provider scope;
  `ARCHITECTURE.md` sections 4 and 6; `SECURITY_AND_TESTING.md` CLI boundary
  invariants; [ADR 0002](0002-provider-boundary.md) revisit trigger

## Context

`PLAN.md` scoped VaultSquire to two providers: Vaultwarden and Proton Pass
through the official CLI. `ONEPASSWORD_CLI_RESEARCH.md` then assessed 1Password
through its official `op` CLI and found a read-first provider technically
credible on the seams the Proton provider already proved, while recording three
gates: 1Password's API and SDK Terms, an unproven authorization path for a CLI
spawned by a GUI process, and this scope decision.

ADR 0002 named exactly this moment as its revisit trigger: "Revisit only if a
third provider demonstrates a repeated seam that cannot be expressed by the
narrow facade without moving provider-specific security rules into shared code."
A third provider now exists, so the question must be answered rather than
assumed.

## Decision

### Scope

- 1Password is accepted as a third provider, read-only, through the official
  user-installed `op` CLI. It is sequenced after the committed Vaultwarden and
  Proton work and jumps no `DELIVERY.md` queue position.
- Desktop-app integration is the only supported authentication mode. Manual
  sign-in and service accounts are rejected, not deferred: both deliver their
  credential through argv or the environment, which the CLI boundary prohibits,
  and service accounts additionally cannot reach a built-in Personal, Private,
  or Employee vault.
- Every write stays disabled. `op item edit` places field values in argv, its
  template path would require rebuilding an item from lossy output, and no
  unarchive or restore command exists at all.

### Provider boundary

- The narrow facade holds. A third provider needed no new shared concept: it
  reuses compound identity, per-action capabilities, the fidelity-labelled
  cache envelope, and the small display projection unchanged. ADR 0002's
  boundary is therefore reaffirmed, not widened.
- One seam did repeat, and it is not provider-specific: no-shell bounded process
  execution. `ARCHITECTURE.md` section 4 already models that as `ProcessRunner`,
  a component distinct from any provider, so the executor is extracted to a
  single shared `CLIProcessExecutor` rather than copied. The rules it enforces —
  no shell, argument vector only, allowlisted environment, bounded output,
  stderr counted and discarded, timeout, cancellation, kill escalation — are
  VaultSquire-wide, and one reviewed implementation is easier to audit than
  three.
- Cache encryption is NOT shared. `ARCHITECTURE.md` section 4 assigns "app cache
  wrapping" to each provider and ADR 0002 keeps it inside the provider, so
  `OnePasswordSnapshotCache` is a sibling of the Proton cache with its own
  device-only key, schema version, and file extension. Both call the one shared
  `CacheEnvelopeCipher`, so the cryptography itself is not duplicated — only the
  typed plumbing each provider owns.

### Two 1Password-specific rules

- The child process pins `OP_BIOMETRIC_UNLOCK_ENABLED=true`. Because the base
  environment is an allowlist rather than a filter, no inherited `OP_SESSION`,
  `OP_SERVICE_ACCOUNT_TOKEN`, or `OP_CONNECT_TOKEN` can reach the CLI; pinning
  the documented mode switch on top states the requirement at the boundary
  instead of leaving it implied. It is a fixed non-secret constant and does not
  change the user's own setting.
- Every account-bearing command names a resolved account. 1Password's own
  reference pages disagree on what the default account means, so the provider
  resolves an opaque identifier from `whoami`, records it in the snapshot, and
  addresses later reads — including an on-demand item read — to that account. An
  identifier that fails opaque-token validation is dropped rather than passed.

## Security and Privacy Consequences

VaultSquire never learns a 1Password account password, Secret Key, or one-time
code; the desktop app performs the authorization ceremony and VaultSquire never
wraps, automates, or proxies it. No secret enters argv, the environment, a log,
or any plaintext file.

The snapshot is deliberately stricter than the Proton one: it carries no
concealed value, no one-time-password seed, and no note. Even if a build's
`item list` returned field values — its payload is undocumented — the read model
drops them before anything is sealed. Secrets are fetched only when an item is
opened and live in memory for that session.

Two residual risks are accepted and stated rather than mitigated in code. The
desktop app's authorization is a device-local factor, not a user secret, so a
1Password vault's local gate is weaker than Vaultwarden's master-password
unlock — the same disclosure Proton already carries. And 1Password documents
that a root process, or a macOS app holding Accessibility permission, may
circumvent the authorization prompt while the app is unlocked; that is a
property of the platform boundary, not of VaultSquire.

## Alternatives

- Embed an official 1Password SDK. Rejected for now: no Swift SDK exists, the
  SDKs are version 0 with breaking changes possible between minor releases, and
  embedding a Go or JavaScript runtime fails the dependency policy. Reassess if
  a stable Swift-usable SDK ships.
- Service accounts or Connect. Rejected: automation surfaces, bearer tokens in
  the environment, no access to built-in personal vaults, and a self-hosted
  server respectively. None is an end-user vault surface.
- Copy the Proton executor into the 1Password provider. Rejected: it would
  triplicate the security-critical process rules against the component boundary
  `ARCHITECTURE.md` already draws.
- Generalize the snapshot cache too. Rejected: both controlling documents assign
  cache wrapping to the provider, and the shared cipher already removes the
  duplication that matters.
- Defer the provider until the terms and authorization gates clear. Rejected as
  the sequencing, not the substance: the gates below still bind release, and
  building the boundary now is what makes the authorization spike cheap to run.

## Verification

Every CLI-boundary behavior is unit-tested over the shared fake executor:
version gating including a beta that must not inherit its stable's admission,
identifier validation and option-injection refusal, exact command construction,
account scoping, honest status for each failure mode, and the sealed cache's
fail-closed behavior on a wrong key, a foreign account, and tampered bytes. A
dedicated leakage suite asserts the contract end to end: nothing secret in argv,
an environment that is a fixed allowlist, and no secret in the sealed snapshot
or on disk.

Two gates from `ONEPASSWORD_CLI_RESEARCH.md` section 1 remain open and are NOT
discharged by this decision:

1. **Terms.** 1Password's API and SDK Terms define CLI tools into "Developer
   Tools", grant no affirmative CLI licence, and prohibit building a product
   that competes with or replicates a substantial portion of the Services.
   Written clarification or qualified legal review is required before any
   release that presents 1Password support.
2. **Authorization and sandbox.** The documented macOS session credential
   derives from the invoking terminal's tty plus start time, and VaultSquire
   spawns `op` with no controlling terminal. That path, and App Sandbox
   feasibility, are unproven and must be exercised on a real Mac against a
   disposable account before the provider is presented as working.

As with the Proton provider, the version allowlist and JSON key spellings are
written against documented surfaces and have not been exercised against a live
CLI. Mismatched output fails closed with an honest error, never a false success,
and an empty allowlist disables 1Password reads entirely.

## Rollback or Revisit Trigger

Revisit if the terms question resolves against the integration, in which case
the provider is withdrawn rather than reworked; if the authorization spike shows
a GUI-spawned `op` cannot be authorized safely, in which case 1Password is
recorded as unsupported; if 1Password ships a stable Swift-usable SDK, which
would reopen the route comparison; or if a fourth provider needs a shared
concept this facade does not already carry, which would reopen ADR 0002 itself.
