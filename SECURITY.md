# Security Policy

## Supported versions

VaultSquire has no application implementation or supported release. This
repository currently contains design and security research only.

## Reporting a vulnerability

Do not open a public issue for a security or source-contamination concern. Use
the maintainer's private contact details from their GitHub profile. GitHub
private vulnerability reporting is not currently enabled for this repository;
when it is enabled, this policy will link the private advisory form directly.

Never submit real vault contents, master passwords, tokens, encrypted vault
databases, Proton CLI output, server logs, URLs containing credentials, signing
material, or unsanitized diagnostics. Use synthetic reproduction data and
describe sensitive evidence instead of attaching it.

## Current scope

Reportable concerns include:

- contamination by prohibited Keyguard-derived material;
- unsafe protocol, cryptographic, storage, Keychain, lock, clipboard, or sync design;
- guidance that could expose secrets through argv, environment, files, logs, or diagnostics;
- unsafe dependency, signing, notarization, update, or release recommendations;
- repository automation that exposes source, secrets, or security reports to an external service.

Future implementation security requirements are normative in
[SECURITY_AND_TESTING.md](SECURITY_AND_TESTING.md). The clean-room gate in
[KEYGUARD_FORK_ASSESSMENT.md](KEYGUARD_FORK_ASSESSMENT.md) remains binding.
