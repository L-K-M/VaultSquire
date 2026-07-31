# Keyguard Rejection And Source-Isolation Decision

- Status: accepted and final; history-isolation gate satisfied for the attested implementation repository
- Decision date: 2026-07-31
- Applies to: all VaultSquire design, implementation, tests, assets, and releases

## 1. Decision

VaultSquire will not fork Keyguard.

VaultSquire will not copy, translate, port, adapt, link, vendor, or derive its
implementation from Keyguard source. Keyguard may provide only vague,
product-level inspiration based on ordinary use of the released application.
Its source repository is not an implementation reference for VaultSquire.

This decision is not a temporary go/no-go gate. Written permission, a license
change, or technical convenience does not reopen the fork path without a new
explicit project decision replacing this document.

## 2. Reason

At the researched revision, Keyguard's `LICENSE` says only `All Rights Reserved`
[KG-LICENSE], and its README says the source code is available for personal use
only [KG-README-LICENSE]. Those terms do not provide the broad modification and
distribution rights required for VaultSquire.

VaultSquire also has an independently defined objective: a new native macOS
application written for Apple platform APIs, not a renamed or modified existing
client.

This is an engineering source-hygiene decision, not legal advice.

## 3. Prohibited Uses

Future contributors and implementation agents must not use Keyguard for:

- source code or snippets;
- mechanical or manual translation between programming languages;
- class, protocol, module, package, or database designs;
- authentication, cryptographic, sync, merge, or conflict algorithms;
- provider abstractions or capability interfaces;
- tests, fixtures, test vectors, mocks, or expected outputs;
- UI source, layouts, component hierarchy, navigation, or interaction details;
- copy, labels, help text, translations, or documentation wording;
- icons, screenshots, artwork, sounds, or other assets;
- build scripts, dependency selections, release workflows, or packaging;
- reverse engineering of private implementation behavior;
- source-level comparison during code review or debugging.

Do not include Keyguard source, a Keyguard checkout, or source-derived notes in
an implementation prompt, coding-agent context, fixture generator, or build
environment.

### History Isolation Before Implementation

Earlier commits in the planning repository contained source-derived Keyguard
research. Removing that text from its current tree did not remove it from Git
history, so that repository history is not an approved implementation input.
A history-isolated coding context must:

- contains only the current approved product requirements and governance record,
  not superseded Keyguard research or old checkouts;
- prevents implementation agents and contributors from receiving prior
  Keyguard-derived notes or commits as design context;
- independently rederives architecture, tests, UI, and storage from approved
  requirements, public platform documentation, protocol evidence, and synthetic
  black-box fixtures;
- records reviewer attestation that no retained design depends on the superseded
  research.

The project created the non-fork private repository
`L-K-M/VaultSquire-Implementation` with one clean root and no inherited Git
objects. [`IMPLEMENTATION_CONTEXT.md`](IMPLEMENTATION_CONTEXT.md) records the
procedure, exact attested root, checks, reviewer, and residual limitations. The
gate is satisfied only for that root and its reviewed descendants. The planning
repository and any context containing its superseded history remain blocked
implementation inputs.

## 4. Permitted Inspiration

Only vague observations available from normal product use are permitted, for
example:

- a password manager benefits from fast search;
- local/offline access is useful;
- users value clear account and provider selection;
- desktop keyboard workflows should be efficient;
- conflicts and unsupported operations should be visible.

These are general product goals, not protectable implementation details and not
instructions to reproduce Keyguard's expression or behavior. VaultSquire must
develop its own interaction design, terminology, architecture, and code.

## 5. Clean-Room VaultSquire Policy

VaultSquire is designed and implemented from these allowed inputs:

- the user-approved product requirements in `PLAN.md`;
- public Apple platform documentation;
- public protocol behavior and independently generated interoperability tests
  needed to communicate with Vaultwarden;
- the official, user-installed Proton Pass CLI as an external process;
- public standards and permissively or compatibly licensed dependencies that
  pass explicit review;
- synthetic test accounts and data created for VaultSquire.

VaultSquire must remain independently expressed:

- use original Swift types, names, modules, and control flow;
- use original SwiftUI/AppKit interface design;
- write independent tests from protocol requirements and observed black-box
  behavior;
- keep a dependency and provenance record for every imported artifact;
- document the source of protocol facts without copying upstream expression;
- reject patches whose provenance cannot be explained.

The canonical VaultSquire identity is:

- product name: `VaultSquire`;
- implementation: new native macOS Swift code;
- canonical source artwork: `media-sources/icon.png`;
- bundle identifiers, screenshots, copy, and generated assets: original
  VaultSquire material.

## 6. Review And Release Gates

Before accepting implementation code, reviewers must verify:

- the contributor did not use Keyguard source as a reference;
- outside this mandatory governance record, no Keyguard names, comments,
  strings, assets, or distinctive structure appear in product code or artifacts;
- no dependency contains copied or repackaged Keyguard material;
- every nontrivial external source has a recorded license and purpose;
- protocol fixtures are synthetic or independently generated;
- UI and documentation are original VaultSquire work;
- current implementation-source and binary scans find no Keyguard package names
  or artifacts; the retained governance record is an expected documentation
  match.

If suspected contamination is found:

1. Stop work on the affected component.
2. Do not attempt to cosmetically rewrite the questionable code.
3. Remove the affected implementation and tests.
4. Reimplement from the approved requirements with a contributor who has not
   relied on the prohibited material where practical.
5. Record the incident and the clean replacement's provenance.

## 7. Product Consequence

The only implementation path is a completely new native VaultSquire codebase.
Vaultwarden support uses an independently written protocol adapter. Proton Pass
support invokes the official CLI through a separately designed process boundary.
Neither path depends on Keyguard code or internals.

This file is retained because future implementers must understand that the fork
alternative was considered and definitively rejected. It is not an invitation
to repeat source-level Keyguard research.

## References

Sources were accessed on 2026-07-31.

[KG-LICENSE]: https://github.com/AChep/keyguard-app/blob/5d26ed1e5c72619856bfbb26b836abf4c08e22d1/LICENSE
[KG-README-LICENSE]: https://github.com/AChep/keyguard-app/blob/5d26ed1e5c72619856bfbb26b836abf4c08e22d1/README.md#license
