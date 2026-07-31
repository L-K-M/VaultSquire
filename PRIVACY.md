# Privacy

VaultSquire is currently documentation only. There is no application, account
service, telemetry, analytics, local vault database, or runtime network traffic.

## Planned application posture

The planned app is local-first and has no project-operated backend or default
telemetry. It will communicate with:

- the user's configured Vaultwarden server over HTTPS with system trust; and
- Proton only through a separately installed official Proton Pass CLI.

Planned local storage contains provider-native Vaultwarden ciphertext and
VaultSquire-AEAD-wrapped Proton snapshots inside database-level encryption.
Device-only keys and reusable tokens belong in non-synchronizing Keychain
records. Decrypted projections and search indexes remain memory-only and are
destroyed on lock as far as the runtime permits.

These are design requirements, not claims about an implemented product.

## Repository automation

The optional GLM review workflow sends an explicitly labeled pull-request diff
to Z.ai for automated review. Do not add the `glm-review` label to embargoed
security reports, licensing/provenance work, suspected source contamination, or
any diff containing secrets or real vault data.

GitHub Actions and Dependabot process repository source in GitHub's environment.
No real account, vault, CLI, server, or diagnostic data may be committed or
uploaded to those systems.
