# Contributing

VaultSquire is currently accepting documentation, research, governance, and
repository-hygiene contributions only. Application implementation is blocked by
the pending reviewer attestation in
[IMPLEMENTATION_CONTEXT.md](IMPLEMENTATION_CONTEXT.md).

Contributions are released under the
[Apache License 2.0](LICENSE).

## Before contributing

Read [README.md](README.md), the controlling documents it lists, and
[AGENTS.md](AGENTS.md). A proposal must identify:

- the controlling document and section it changes;
- whether it affects Vaultwarden, Proton CLI, shared platform behavior, or governance;
- primary or immutable evidence for external claims;
- security, privacy, compatibility, licensing, and provenance consequences;
- unsupported or deferred behavior that remains after the change.

## Clean-room requirements

- Do not use Keyguard source or source-derived implementation details.
- Do not copy or mechanically translate Bitwarden, Vaultwarden, or Proton code.
- Do not paste upstream private implementation into issues, pull requests, or prompts.
- Use original wording and design derived from approved requirements and public evidence.
- Explain the provenance of every nontrivial artifact and dependency proposal.

## Test data and reports

Use synthetic examples only. Never provide production vault records, real
credentials, tokens, TOTP seeds, private keys, CLI output, databases, logs, or
unsanitized URLs. Security and contamination concerns must be reported privately.

## Verification

There is no product build or test command yet. Verify documentation links,
formatting, cited revisions, internal consistency, and repository hygiene. Do
not add placeholder product CI or fictional commands.

GLM review is optional and external. Add the `glm-review` label only when the
entire diff is suitable for submission to Z.ai. Human security and provenance
review remains mandatory regardless of automated feedback.
