# Runbook: exam content snapshot rollout (REQ-511, GH #2682)

Applies to every environment that receives commit a5847f1f (PR a #2730) or later. Source: the `Letflow.Release.ExamSnapshot` moduledoc and the design `lib/letflow/design/req511-exam-content-snapshot.md` (sections 9.3, 10.3, 17.2, 17.5). Written from the RELEASE-VALIDATOR report; the commands below are the moduledoc's, and this runbook has not itself been executed.

## What happens without the rollout
Until the rollout has run for a tenant, an exam start answers 503. Sessions that were started before the deploy have no snapshot: after PR b (#2732) a late snapshot is taken at the first touch; before PR b they could not be scored or autosaved (fail closed, 503 `snapshot_error`).

## Steps (after the deploy of the code that reads the snapshot)
1. Dry run: `bin/letflow rpc "IO.inspect(Letflow.Release.ExamSnapshot.rollout(dry_run: true))"`. Read the report: `upgraded_total`, `conflict_total`, `failed_total`.
2. Real run: `bin/letflow rpc "IO.inspect(Letflow.Release.ExamSnapshot.rollout(dry_run: false))"`. The rollout upgrades the `session` definition and adds the answer-key restriction rows. Only `dry_run` is accepted.
3. Verify: `bin/letflow rpc "IO.inspect(Letflow.Release.ExamSnapshot.verify())"` must return `ready: true`.
4. Only then may the infra stamp of the exam runtime types (#2596) be requested. It is a separate infra request and refuses until `verify()` is ready.

## Notes
- Mix equivalent: `mix letflow.exam_snapshot_rollout [--dry-run]`.
- QA answer keys are test fixtures only; there is no production-like answer data on QA (ops rule; not enforced by code).
- Follow-ups: #2733 (late-snapshot order enforced by convention), #2734 (`Latest.get/3` does not filter soft-deleted rows).
