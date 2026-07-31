# ADR 0005: Synthetic Fixtures And Source Hygiene

- Status: Accepted
- Date: 2026-07-31
- Owner: `L-K-M`
- Required second reviewer: clean-room or security reviewer
- Controlling documents/sections: `KEYGUARD_FORK_ASSESSMENT.md`;
  `SECURITY_AND_TESTING.md` section 7

## Context

Interoperability tests need realistic encrypted records and hostile inputs, but
production vaults and copied upstream tests would violate the secret and
clean-room boundaries.

## Decision

- Use only synthetic, disposable identities, credentials, organizations,
  records, attachments, and CLI accounts.
- Prefix fixture canaries with a documented non-production marker and make each
  suite's values unique enough for artifact leakage scans.
- Generate protocol fixtures from a versioned VaultSquire recipe or controlled
  black-box operation against an exact tested official client/provider artifact.
- Record generator revision, tool/client identity, provider version, inputs,
  expected behavior, output hash, and license/provenance for every fixture set.
- Separate observed bytes from VaultSquire-authored assertions. Do not copy an
  upstream test, expected output, schema expression, UI string, or source-level
  algorithm into product tests.
- Keep source-evidence repositories and prohibited material out of coding-agent
  prompts, implementation checkouts, fixture generators, and build environments.
- Never commit raw Proton CLI output. Convert validated synthetic output directly
  into an encrypted test envelope or an independently authored minimal fixture.
- Never place production data, tokens, logs, databases, URLs, private keys, or
  support bundles in Git, CI, issues, or reviews.

## Security And Privacy Consequences

Synthetic fixture secrets are still treated as sensitive canaries because their
appearance proves a leakage path. Disposable external accounts must be isolated,
rotated after shared testing, and contain no personal identifiers.

## Alternatives

Sanitized production vaults, copied provider/client fixtures, source-derived
expected values, and recordings from real user sessions are rejected.

## Verification

Every fixture PR requires provenance review, deterministic regeneration where
possible, hash comparison, positive and malformed cases, and recursive canary
scans of logs, files, crash output, test results, and support artifacts.

## Rollback Or Revisit Trigger

Quarantine and remove a fixture set if its provenance cannot be explained, a
real secret is suspected, a source-isolation violation is reported, or its
generator cannot be reproduced from approved inputs.
