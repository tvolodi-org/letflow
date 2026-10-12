# REQ-465 run report addendum: AC 6 affected-scenario listing and persona proviso

Source: PR #2417 (Q-1051 / GH #2395), head be55b235, read-only via git show origin/feat/Q-1051-l1-cro-escalation-and-assessment-sod. No checkout writes. Written 2026-10-12 as the REQ-465 AC 6 record.
Verified against PR #2417 head be55b235. The audited files are identical on main bc6febba (git diff --stat, empty). The Q-1049 drift list is tracked on Q-1049 / GH #2391, not here.

## 1. REQ-465 AC 6: affected scenarios (every UAT or simulation scenario that would change outcome)

Scanned: test/fixtures/uat/scenarios/meridian/*.yaml (8 files), test/fixtures/simulation/meridian/scenarios/*.yaml (3 files). Actor ids come from each file's actors block.

Result: NONE changes outcome under the Q-1051 change (new CRO L1 escalation node; five assessment nodes plus the new node named in distinct_from of disburse-loan and of escalate-disburse-loan-to-loan-ops-lead).

Per-scenario check (verified step numbers):
- loan-origination-below-threshold.yaml (UAT): L1 approve at step 4 by l1_approver = actor-meridian-lars. No timeout. Disbursement at step 6 by loan_ops = actor-meridian-marcus (not an assessor, so the new distinct_from does not refuse it). Outcome unchanged.
- loan-origination-kyc-manual-review.yaml (UAT): L1 approve at step 5 by actor-meridian-lars. Disbursement at step 7 by actor-meridian-marcus. Outcome unchanged.
- loan-origination-above-threshold.yaml (UAT): committee votes at steps 4-6 (thomas, julia, eva); disbursement at step 7 by actor-meridian-marcus. Outcome unchanged.
- refusal-loan-approval-and-disbursement.yaml (UAT): refusals stay refusals (role gate). actor-meridian-ben (credit_manager) at step 6 (committee CEO vote, refused) and step 12 (disbursement, refused). actor-meridian-sophie (analyst) at steps 4, 7, 13 (refused). actor-meridian-marcus (loan_ops) at step 5 (committee director vote, refused; not listed in the PR body) and step 14 (disbursement, succeeds; he completes none of the 12 ids). actor-meridian-miriam (risk_manager) at step 8 (export refused). Assessment steps 2 (ben) and 3 (miriam) and committee approvals at steps 9-11 are unchanged. Outcome unchanged.
- loan-origination-*: no L1 timeout; no scenario completes escalate-l1-approval-to-cro (role-cro).
- regulatory-compliance-review-bafin.yaml, -ceo-override.yaml, -cro-signoff.yaml, refusal-compliance-signoff-and-user-changes.yaml (UAT): regulatory definition, unchanged on #2417 (only the loan JSON changes in test/fixtures/qa). Out of scope for the loan change; unchanged.
- Simulation loan-origination-above-threshold.yaml: steps 1-8 (lars starts; julia credit memo and remaining assessment; thomas, julia, eva committee votes). No disbursement or payment step. Outcome unchanged.
- Simulation loan-origination-below-threshold.yaml: steps 1-2b (lars starts; julia credit memo). No payment step. Outcome unchanged.
- Simulation regulatory-compliance-review-bafin.yaml: regulatory definition. Unchanged.

Scenario files edited: none.

## 2. Persona proviso (AC: marcus and hannah hold no assessment role)

- test/fixtures/uat/actors.yaml 47-51: actor-meridian-marcus, routing_roles [role-loan-ops] (routing_roles at line 50).
- test/fixtures/uat/actors.yaml 67-71: actor-meridian-hannah, routing_roles [role-loan-ops-lead] (routing_roles at line 70).
- scripts/seed_meridian_persona_actors.sh PERSONAS: line 50 "actor-meridian-marcus|role-loan-ops"; line 54 "actor-meridian-hannah|role-loan-ops-lead".
- Holds: neither holds role-credit-manager, role-credit-director, role-risk-manager, role-cro or role-compliance-officer.
- Twelve-id set on disburse-loan and escalate-disburse-loan-to-loan-ops-lead (QA, #2417): exactly l1-approval, l2-approval, escalate-l2-approval-to-ceo, committee-vote-cro, committee-vote-director, committee-vote-ceo, credit-memo-review, credit-memo-escalation-review, risk-assessment, risk-assessment-escalation-review, kyc-manual-review, escalate-l1-approval-to-cro. Verified by set comparison.

