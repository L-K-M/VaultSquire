# Dependency Register

VaultSquire currently has no application dependencies because implementation
has not started.

Every future dependency must be recorded before adoption with:

| Field | Required information |
| --- | --- |
| Name | Package, framework, binary, tool, or data source |
| Purpose | Why standard Apple APIs or local code are insufficient |
| Exact version | Immutable version or commit |
| Origin | Canonical source and artifact URL |
| Integrity | Checksum, signature, or reproducible-build evidence |
| License | License and redistribution obligations |
| Transitives | Runtime/build dependency inventory |
| Security owner | Person responsible for advisories and upgrades |
| Update policy | Supported window and review cadence |
| Secret surface | Whether it handles keys, credentials, plaintext, network, or release assets |
| Removal plan | Migration or fallback if the dependency becomes unsafe |

The proposed Argon2 and encrypted-SQLite choices remain decisions, not approved
dependencies. Proton's CLI is user-installed external software and must still
have exact executable identity/version command contracts before use.
