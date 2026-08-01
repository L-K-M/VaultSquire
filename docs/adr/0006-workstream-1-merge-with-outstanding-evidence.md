# ADR 0006: Workstream 1 Merged With Outstanding Exit Evidence

- Status: Accepted
- Date: 2026-08-01
- Owners: `L-K-M`
- Controlling documents/sections: `PLAN.md` Workstream 1 exit criteria;
  `WORKSTREAM_1.md` Exit Evidence; `DELIVERY.md` merge conditions;
  `ARCHITECTURE.md` section 10 performance gates

## Context

`WORKSTREAM_1.md` stated that the Workstream 1 pull request must not merge while
any controlling exit criterion remained pending, and `DELIVERY.md` and
`CONTRIBUTING.md` repeated that condition. Workstream 1 nevertheless merged into
`main` as PR #5 on 2026-08-01 with several criteria unmet.

The criteria that remain unmet all require either named Apple Silicon hardware,
an interactive operator, or a disposable Proton account. None of them can be
produced by hosted CI, and the repository had no such Mac available. Holding the
branch open indefinitely would have accumulated review debt against a moving
`main` without bringing any of those criteria closer to satisfaction.

This ADR records that the merge was a deliberate owner decision rather than an
oversight, and converts the unmet criteria from a merge gate into a tracked debt
with an explicit later gate.

## Evidence

- PR #5 merged as commit `d7693b3`, which also carried the Workstream 1 native
  shell originally proposed in PR #4.
- Hosted workflow `30696406614` passed the Release `arm64` build, ad-hoc
  Hardened Runtime signing, entitlement and linked-image inspection, and 19 unit
  and 3 UI test methods.
- The warm Quick Search signpost fixture produced `[5.2, 5.9, 4.8, 7.1, 3.6] ms`
  on the hosted runner. That is a five-sample hosted trend figure, not a p95 on
  named baseline hardware.
- `XCTApplicationLaunchMetric` exports no machine-readable metric from the hosted
  run. The cause is unknown and is itself outstanding.
- The criteria recorded as unmet in the `WORKSTREAM_1.md` Exit Evidence table at
  merge time are observed facts; the reclassification below is a decision.

## Decision

- Workstream 1 code is merged. Its unmet exit criteria are not waived, forgiven,
  or reduced in scope; they are reclassified as outstanding evidence owed by the
  project, tracked in the `WORKSTREAM_1.md` Exit Evidence table.
- The merge gate moves rather than disappears. No VaultSquire release, private
  preview, or distributed artifact may be produced while any Workstream 1
  criterion is outstanding, and the Phase 0 gate over Workstreams 0-3 is not met
  while any of them is outstanding, under the phase-gate rule in `PLAN.md`.
- Which later work each outstanding row blocks is stated rather than left to be
  argued at pull-request time. No outstanding row blocks Workstream 2: it models
  domain, session, and provider contracts against a fake provider facade and
  consumes no Workstream 1 hardware measurement, accessibility result, or
  sandbox outcome. The three legs recorded as not implemented block
  Workstream 10, the Proton CLI provider, which is the first work that depends on
  them. The remaining rows block the Phase 0 gate and any release.
- Merging code into `main` is therefore no longer evidence that a workstream's
  exit criteria passed. `main` is an integration branch, not a release branch,
  and nothing in it should be read as a claim about hardware, accessibility,
  signing identity, notarization, or process-sandbox behavior.
- The prohibition on claiming an unproduced result is unchanged and absolute. A
  criterion is recorded as passed only when the evidence exists.

## Security and Privacy Consequences

No secret lifetime, storage, network, permission, cancellation, diagnostic, or
supply-chain behavior changes. The merged tree is ad-hoc signed only and has no
Developer ID identity, notarization, or stapling, so it is not installable as a
trusted application and carries no release claim.

The security-relevant risk of this decision is presentational: an unreviewed
reader could mistake presence in `main` for verified behavior. The decision
above addresses that directly by stating that `main` carries no such claim, and
the outstanding rows stay in the Exit Evidence table until discharged.

## Alternatives

- Hold the branch open until a named Mac exists. Rejected: the blocking
  resources were unavailable with no committed date, and an open branch accrues
  conflict and review debt without advancing any criterion.
- Waive the unmet criteria. Rejected outright. They cover launch and search
  performance budgets, accessibility, sandbox process feasibility, and icon
  legibility, each of which gates a real product property.
- Weaken the criteria to what hosted CI can produce. Rejected: that would
  redefine a budget to match a measurement, which
  `SECURITY_AND_TESTING.md` prohibits for performance regressions and which the
  same reasoning forbids here.
- Revert the merge. Rejected: the merged work is correct as far as it has been
  verified, and reverting would discard verified fixes to obtain a governance
  property that this record supplies more cheaply.

## Verification

This decision removes the structural pressure a blocked pull request applied, and
it sets no date, because none can honestly be set while the blocking hardware,
operator time, and disposable account are unavailable. Inventing one would be the
same overclaim this repository exists to avoid. The substitute is visibility: the
outstanding rows are restated in every subsequent workstream record and in any
release-candidate checklist until they are discharged, so the debt is re-read at
each gate rather than fading. A workstream record that omits them is incomplete.

- Every outstanding row in the `WORKSTREAM_1.md` Exit Evidence table names what
  is missing and why, and is discharged only by recording the evidence.
- The named-hardware p95 measurements, VoiceOver and Full Keyboard Access,
  multiple-Spaces and full-screen presentation, and the disposable-account
  direct-versus-sandbox comparison are performed on a named Apple Silicon Mac
  and recorded before any release candidate.
- The unexplained absence of an exported launch metric is diagnosed on that same
  Mac; an absent metric is never recorded as a passing budget.
- The three legs recorded as not implemented (session and keyring discovery,
  security-scoped bookmark round trips, and signature and notarization recording
  at approval) are implemented, or explicitly withdrawn through a further ADR,
  before Workstream 10, the Proton CLI provider, depends on them.

## Rollback or Revisit Trigger

Revisit if a Workstream 1 criterion turns out to be unsatisfiable as written, if
a release is proposed while any criterion is outstanding, or if this pattern is
requested a second time. A recurring need to merge past exit criteria means the
criteria or the delivery sequence are mis-specified and belong back in `PLAN.md`,
not in a per-workstream exception.
