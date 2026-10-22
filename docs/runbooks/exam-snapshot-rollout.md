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

## Authoring grants BEFORE the GH #2784 deploy (deploy-breaking if skipped)
`Exam.on_install/2` and `ensure_answer_key_restrictions/1` insert the restriction rows and NO grants. Since GH #2784 the generic record write routes apply those rows to the caller: without a grant, `POST answer_option` naming `is_correct` is 403, a `PUT` of `question`, `answer_option` or `session` whose body names a restricted key is 403 (since GH #2812 a PUT naming none keeps the stored restricted values; a stored value that no longer validates is also 403), and import entries naming a restricted key are `field_restricted`. A `TENANT_ADMIN` is not exempt. The SPA authoring pages (`web/src/pages/entities/EntityCrudPage.tsx`, `web/src/config/bilimbagaEntities.ts`) hit these 403s. `DELETE` still works and shows the redaction sentinel.

1. List the tenants and types that hold field restrictions (per tenant schema):
   `SELECT entity_type, field_name FROM "<tenant_schema>".entity_field_restrictions ORDER BY 1, 2;`
   Every row is a field the generic record write routes now refuse to an actor without a grant.
2. BEFORE deploying, grant the authoring staff (by name) the answer-key fields, through
   `POST /api/v1/entities/restrictions/import` (permission `EntitiesRestrictionsManage`), body
   `{"field_grants": [{"user_id": "<uuid>", "entity_type": "<type>", "field_name": "<field>"}, ...]}`.
   The route is idempotent. The exam fields (`Letflow.Modules.Exam.answer_key_fields/0`) are:
   `question.explanation`; `answer_option.is_correct`, `answer_option.likert_weight`,
   `answer_option.likert_polarity`; `session.exam_snapshot`. An author who edits an answer option
   needs ALL THREE `answer_option` grants plus `question.explanation` for questions.
3. Grant `session.exam_snapshot` ONLY to admins who genuinely PUT sessions. NEVER grant any
   answer-key field to a `TASK_WORKER` or candidate user: the grant lifts the redaction on every
   read route too.
4. Other tenants with their own restrictions (for example QA vortex `production_batch.cost_figure`)
   need the same list-then-grant pass for the staff who write those types; the seeding account of
   `scripts/seed_vortex_entities.sh` is `SEED_ACTOR_USERNAME`.
5. After the deploy, check as an authoring user: `PUT /api/v1/entities/records/answer_option/<id>`
   with the whole `field_values` answers 200 (not 403), and `POST /api/v1/entities/records/answer_option`
   naming `is_correct` answers 201. A 403 with detail `one or more requested fields are restricted
   for this caller` means a grant is missing.
