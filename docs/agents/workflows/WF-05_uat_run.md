# WF-05 — UAT Run

**Trigger:** a running Letflow instance exists and a stage's scenario corpus is ready
to validate against. In practice this does not become live until S7
(`docs/migration/stage-7-simulation-uat-parity.md`) — MVP-1's manual GUI walkthrough
(REQ-107) is a narrower precedent, not a full WF-05 run.
**Owner:** `ORCH`

## Overview

```
[INPUT: a running Letflow instance + a scenario corpus to validate]
        │
        ▼
┌───────────────────────┐
│  STEP 0: ENVIRONMENT  │ ← ORCH derives the PRECONDITIONS manifest, runs
│  PREPARATION          │   scripts/uat_preflight.sh, closes gaps (letflow seeds /
└──────────┬─────────────┘   ai-dala-infra request), re-checks. Unmet after prep →
           │                 run is ENV_NOT_READY, never PASS/FAIL. Skipped → same.
           ▼
┌───────────────────────┐
│  STEP 0b: PROCESS     │ ← ORCH digests each scope's files; PROCESS-AUDITOR reviews the
│  AUDIT (per scope)    │   scope's process design unless an unchanged audit exists. A FAIL
└──────────┬─────────────┘   blocks that scope's UAT only, never the other scopes.
           ▼
┌───────────────────────┐
│  STEP 1: READINESS    │ ← ORCH verifies the instance is actually reachable
│  CHECK                │   (health endpoint, or equivalent) before dispatching
└──────────┬─────────────┘   UAT-RUNNER — do not dispatch first and discover it's
           │                 down afterward.
           ▼
┌───────────────────────┐
│  STEP 2: RUN          │ ← UAT-RUNNER
│  SCENARIOS            │   Executes each scenario against the real running
│                        │   instance (real HTTP calls, real DB state) — no mocks,
│                        │   same "real system, not simulated" principle as
│                        │   docs/guides/test_developer_guide.md's Directive T-2.
└──────────┬─────────────┘
           ▼
┌───────────────────────┐
│  STEP 3: REPORT       │ ← UAT-RUNNER writes test/uat-reports/uat-<date>-<run-id>.yaml
│                        │   Verdict per scenario stated as "system did X after
│                        │   action Y" — not "no errors were thrown."
└──────────┬─────────────┘
           ▼
      Run ENV_NOT_READY (Step 0 skipped, or BLOCKED-by-environment remain)?
      ├─ YES → no UAT result; back to Step 0 / ai-dala-infra. UAT gate NOT satisfied.
      └─ NO  → Any scenario FAIL?
      ├─ NO  → PASS, stage's UAT parity confirmed for this scenario batch
      └─ YES → file per WORK_BOARD.md section 7 (or, if it blocks the current stage gate,
               route directly to WF-03 for this specific run rather than
               forwarding — a UAT failure on a stage-defining scenario is this run's
               own blocker, not an incidental one)
```

## Step 0 — Environment preparation (mandatory)

**Agent:** `ORCH`

A run dispatched against an unprepared environment produces BLOCKED scenarios, not UAT
evidence (`WF05-FULL-20260929`: 26 of 31 scenarios BLOCKED for missing tenants, Keycloak
realms/actors, deployed definitions, and specs needing local Postgres). Prepare first.

```
1. Derive the PRECONDITIONS manifest from the scenario corpus (per scenario): tenants
   (`company_id`/`scope`), Keycloak realms, actors + roles (`actors:`), deployed process
   definitions (`process_id`), credentials for those actors, deployed build == origin/main
   SHA, required spec files (`pipeline_test` exists and is not an unresolved
   `NOTE (ISS-05xx)` forward-reference), and no local-only dependencies (e.g. a spec that
   shells out to `docker compose exec psql`).
1a. Tenant preparation (seed scripts) runs with a tenant token of the least role the script
   needs, never a platform account's token (REQ-454): TENANT_ADMIN for the persona and
   entity seeds (`seed_*_persona_actors.sh`, `seed_vortex_entities.sh`), PROCESS_DESIGNER for
   the definition seeds (`seed_*_definition.sh`). Each script's header lists the role per call
   and checks the token at start (`GET /api/v1/me/access`); a short token exits 1 naming the
   missing permission before anything is written.
2. Run the preflight (read-only):
     scripts/uat_preflight.sh --base-url <url> --environment <slug> \
        --credential-source <path> --out <preflight.json>
   Save the output as `test/uat-reports/preflight-<date>-<environment>.txt`.
3. For each GAP, by remediation owner:
   - letflow-seed: run the idempotent `scripts/seed_*.sh` where one exists.
   - ai-dala-infra (Keycloak realm/users, tenant creation, deploy, exposing a build SHA):
     file a request to / dispatch a run in `ai-dala-infra`
     (`c:\Users\tvolo\dev\ai-dala\ai-dala-infra`, own orchestrator workflow + approval
     gate). Letflow never changes QA infrastructure directly.
   - feature-gap (missing/forward-reference spec, unbuilt feature): not environment; file
     per `WORK_BOARD.md` section 7. The scenario is UNBUILT_FEATURE, not BLOCKED-by-environment.
   - environment-structural (permanent): a
     `test/fixtures/uat/scenario-env-limitations/<scenario_id>.yaml` sidecar
     says this scenario cannot pass on this `--environment` slug for a
     structural reason (not a seeding/credential gap). No remediation is
     attempted. Confirm the sidecar's `applies_to_environments` and `review`
     condition are still accurate; if so, this GAP is expected and reported
     every run by design — do not loop trying to close it, and do not
     re-file it as a new issue (cite the sidecar's `issue_ref` instead). A
     sidecar's condition may additionally be scoped to specific expected
     outcomes via `applies_to_expected_outcomes: [<EO-id>, ...]`; when
     present, only those expected outcomes are exempted from Step 0
     remediation and are reported BLOCKED-by-environment — every other
     expected outcome in the same scenario is not exempted and must be
     verified normally by UAT-RUNNER.
   Re-run the preflight after each remediation round.
4. Only scenarios still unmet after prep are BLOCKED. Classify each:
   - BLOCKED-by-environment: `ENV_*`, `CREDENTIALS_MISSING`, `PRECONDITION_NOT_MET`,
     `ENV_NOT_SUPPORTED`.
   - `UNBUILT_FEATURE`: a real product gap, reported as such.
5. Verdict: a run where Step 0 was skipped, or where >0 BLOCKED-by-environment scenarios
   remain, is reported **`ENV_NOT_READY`** — never PASS/FAIL, never a UAT result, and it
   does not satisfy the UAT stage gate (`ORCHESTRATOR.md` §8). ORCH may still dispatch
   UAT-RUNNER for the scenarios whose manifest is met; the run as a whole stays
   `ENV_NOT_READY` until the rest are.
6. Dispatch UAT-RUNNER only with the preflight report path in the handoff `context`.
```

## Step 0b — Process audit (gate per scope)

**Agent:** `ORCH` dispatches `PROCESS-AUDITOR` once per scope. Runs after Step 0 (the environment is
prepared, so the deployed definitions can be reached) and before Step 1. Role and checklist:
`.claude/agents/process-auditor.md`.

**DIGEST-RULE.** ORCH dispatches PROCESS-AUDITOR for a scope unless an audit artefact exists whose
input digests match the current files. An unchanged scope is not re-audited: ORCH cites the existing
artefact by path instead. A `FAIL` verdict blocks UAT-RUNNER for that scope only. The `platform` scope
is included and follows the same rule. This keeps the gate off the per-run path when nothing changed.

```
1. List the scopes of this run: the scope of every scenario in the corpus under test (a directory under
   test/fixtures/uat/scenarios/ whose name does not start with `_`), `platform` included.
2. For each scope, build its file list with the closed rule in `.claude/agents/process-auditor.md`
   ("Audited inputs of a scope", groups S1-S5). The list is built by the rule, not by judgment. REQ-454 and REQ-457 each edit the roster and so
   each re-audits all five scopes; roster edits should be batched into as few merges as possible.
3. Compute the digest of each file with the command (Git Bash, run from the repo root):
     sha256sum <path>
   The digest is the first field of the output: 64 lowercase hex characters, the SHA-256 of the file
   bytes as checked out. Keep the path and the digest together. (A checkout whose line endings differ
   produces a different digest: the only effect is one extra audit, which is the safe direction.)
4. Look for an existing artefact: every file test/uat-reports/process-audit-<scope>-*.yaml. It MATCHES
   when its `audited_inputs` have exactly the same set of paths as step 2 and every digest is equal to
   the one from step 3. If one or more match, take the one with the latest `generated_at`: do NOT
   dispatch PROCESS-AUDITOR for this scope; go to step 8 with that artefact's path and verdict. (The
   validator output and the other scopes' files are not part of the match.)
5. Otherwise produce the definition validator output for each deployed process definition of the scope.
   For each `test/fixtures/uat/process-definition-aliases/*.yaml` whose `company_id` is the scope, take
   its `definition_name` (once per name). Get a bearer token for any roster actor of this scope from
   the credential source with the `qa-uat-env` token protocol of `scripts/uat_preflight.sh`
   (`fetch_credential`, line ~311: it runs `<credential_source> token <actor_id>` and takes the first
   stdout line that `parse_token_line`, line ~297, accepts: `Token: <jwt>` or a bare JWT; any built-in
   role in `docs/roles.md` that can read definitions suffices). Then run, literally:
     curl -s -H "Authorization: Bearer <token>" <base_url>/api/v1/definitions/active/<url-encoded name>
     curl -s -X POST -H "Authorization: Bearer <token>" <base_url>/api/v1/definitions/<id>/validate
   `<id>` is the top-level `id` field of the JSON body of the first call. From the second answer keep:
   for a 200 body its `warnings` list and `violation_codes: []`; for a 422 body the `code` of every
   entry of `errors` as `violation_codes` (a 422 body has no `warnings`). If a call cannot be made
   (definition not deployed, no token), record `status: NOT_AVAILABLE` for that definition; never
   invent output. Never write the token into any file or handoff. A scope with no process definition
   has an empty `validator_output`.
6. Also compute the digests of the process definition files of every OTHER scope (the S3 group of each
   other scope): this is `cross_scope_inputs`, used only by checklist item F1.
7. Dispatch PROCESS-AUDITOR with `context`: `scope`, `run_id`, `commit_sha` (current `HEAD`),
   `input_digests`, `validator_output`, `cross_scope_inputs`. Commit its report
   (`test/uat-reports/process-audit-<scope>-<run_id>.yaml`) with the handoff. If the report breaks the
   schema rules in the role file, re-dispatch once; a second failure leaves the scope with no audit
   (verdict MISSING in step 8).
8. Act on the verdict of the matched or new artefact:
   - `PASS` or `PASS_WITH_FINDINGS`: the scope proceeds to Step 1.
   - `FAIL`: the scope is BLOCKED for this run. Do not dispatch UAT-RUNNER for its scenarios and do not
     dispatch its BA-<VERTICAL> sign-off. Other scopes proceed. The scope's scenarios are not counted in
     the run's `ENV_NOT_READY` determination (that status stays environment-only). The scope stays
     blocked on every later run until an audited file changes (its digests then differ and step 4 no
     longer matches); ORCH never overrides a FAIL.
   - no artefact (step 7 failed twice): treat as `MISSING`; the scope is blocked as for `FAIL`.
   If the owner of a BLOCKER finding disputes it, the owner records the dispute with evidence in the filed issue; ORCH dispatches PROCESS-AUDITOR once more for that scope as a fresh agent that is not given the first report; the later artefact governs (step 4 already takes the latest generated_at). If the second audit repeats the finding, it stands; a further dispute goes to the user. ORCH itself still never overrides a verdict.
9. File every BLOCKER and MAJOR finding of a NEW artefact per docs/agents/protocols/WORK_BOARD.md section 7
   (MINOR findings are not filed; they stay listed in the artefact only, as in REQ-458) (one issue per finding
   id; one issue for a cross-scope pair reported by two scopes). A finding's `suggested_owner` tells
   where it goes (BA-<VERTICAL> or REQ-ANALYST for business decisions, ELIXIR-DEV through WF-03 for a
   definition defect, ORCH for roster or seed scripts, SECURITY-REVIEWER for an access concern). Do not
   file a cited (matched) artefact's findings again.
10. Record in the handoff to UAT-RUNNER and PRODUCT-OWNER `context.audit_artefacts`: a map scope -> path
   of the artefact used (new or cited) for EVERY scope of step 1, blocked ones included; and in the
   PRODUCT-OWNER handoff `context.audit_blocked_scopes`: the list of scopes blocked in step 8.
```

## Step 1 — Readiness check

**Agent:** `ORCH`

```
1. Confirm the target instance responds (health check, or a simple GET against a
   known route).
2. Confirm the scenario corpus for this stage exists under
   `test/fixtures/uat/scenarios/<company>/*.yaml` and
   `test/fixtures/uat/scenarios/platform/*.yaml` (see `.claude/agents/uat-runner.md`
   and ISS-0526/ISS-0527's design docs for the full shape).
3. Confirm this run's dispatch to UAT-RUNNER will carry an explicit environment target:
   `base_url` and `credential_source` (see `.claude/agents/uat-runner.md`'s "Environment
   target" section). Do not dispatch with an implicit/default target.
4. Confirm Step 0 completed and its preflight report path is available for the handoff.
4a. Confirm Step 0b completed for every scope of this run: each scope has an audit artefact path and a
    verdict. Remove every scope whose verdict is FAIL or MISSING from this dispatch. If no scope is
    left, do not dispatch UAT-RUNNER; log BLOCKED, name the blocked scopes.
5. If any check fails: do not dispatch UAT-RUNNER. Log BLOCKED, name what's missing.
```

## Step 2-3 — Run and report

**Agent:** `UAT-RUNNER`

```
0. Refuse a dispatch whose `context` lacks the preflight report path (return FAILED,
   naming it), and do not run any scenario the preflight lists as GAP — record it
   BLOCKED with the preflight's reason.
1. For each scenario: perform the described action against the real running instance
   via real HTTP calls (or, once web/ integration exists per S8, by driving the actual
   GUI — see REQ-107's manual-walkthrough precedent for what this looks like before a
   browser-automation tool is wired in).
2. For a scenario using the `branches:` construct (`docs/agents/uat-scenario-schema.md`),
   evaluate each branch's `when:` condition against this run's actual observed facts and
   run only the first matching branch, per `.claude/agents/uat-runner.md`'s "Evaluating a
   `when:` branch" procedure. Record which branch was run in the report.
3. Observe actual resulting state (not just "no error thrown") — query the instance
   back to confirm the expected state was reached.
3a. For a step with `expect_refusal: true`, follow `.claude/agents/uat-runner.md`'s "Refusal
   steps and actor access"; record `actors_observed` per scenario.
4. Record PASS/FAIL per scenario with the observed evidence, not an inferred one.
5. Write test/uat-reports/uat-<date>-<run-id>.yaml.
6. Complete the handoff: PASS if all scenarios passed, FAIL otherwise with each
   failing scenario named. If any scenario is BLOCKED-by-environment (not
   UNBUILT_FEATURE), the report's `result_overall` is `ENV_NOT_READY` instead — an
   all-BLOCKED run is never reported as a normal FAIL.
```

## Step 4 — PRODUCT-OWNER release recommendation

**Agent:** `PRODUCT-OWNER`

Runs once every `BA-<VERTICAL>` sign-off for this run_id has been written (see
`.claude/agents/ba-analyst.md`'s SIGN-OFF responsibility — dispatched by ORCH
per vertical, same as Step 2-3's UAT-RUNNER dispatch, for each vertical with
scenarios in this run's UAT report). Never runs in parallel with a
`BA-<VERTICAL>` sign-off step, and always runs strictly before
`RELEASE-VALIDATOR` — see `.claude/agents/product-owner.md`'s Relationship
section for why these are separate, non-substitutable gates.

```
1. Read every test/uat-reports/ba-signoff-*-<run_id>.yaml for this run_id, and
   test/uat-reports/uat-<date>-<run_id>.yaml. Also read the audit artefact of every scope named in your handoff `context.audit_artefacts`.
2. Cross-check MUST-severity acceptance criteria for the requirement/stage batch
   under test against passing-scenario coverage.
3. Apply the single-BLOCKER-blocks-release rule.
3a. Apply the access gate: read `access_verdict` and `access_note` from every BA sign-off. The
    recommendation is NOT `APPROVED` if any sign-off has `access_verdict: FAIL`, or
    `access_verdict: NOT_COVERED` for a vertical that is not listed in `refusal_coverage_exempt`
    in `test/fixtures/uat/actors.yaml`. A missing `access_verdict` counts as `NOT_COVERED`.
    For platform-scope scenarios read the UAT report directly: any `expect_refusal` step recorded FAIL
    makes `release_recommendation` BLOCKED, with the same no-override rule.
3b. Apply the audit gate: read the audit verdict of every scope in `context.audit_artefacts`. The
    recommendation is NOT `APPROVED` if any scope has no PASS or PASS_WITH_FINDINGS audit (its verdict is
    FAIL, or the artefact is missing). A scope without a PASS or PASS_WITH_FINDINGS audit is not
    APPROVED. This applies to `platform` and to a scope blocked at Step 0b, which has no UAT result.
4. Arbitrate any cross-vertical disagreement found; route to REQ-ANALYST if the
   underlying requirement is ambiguous.
5. Write test/uat-reports/po-signoff-<run_id>.yaml.
6. Complete the handoff: PASS if release_recommendation == APPROVED, FAIL
   (BLOCKED) otherwise, naming every blocking issue and its suggested_action.
```

PASS → this stage's UAT parity is confirmed **and** business-approved for
release; ORCH proceeds toward RELEASE-VALIDATOR / the stage-gate check in
`ORCHESTRATOR.md` §8.
FAIL (BLOCKED) → route per each issue's `suggested_action` (`route_to_wf03` /
`route_to_req_analyst` / `route_to_uat_runner` / `route_to_security_review`); an issue
with `route_to_security_review` is dispatched by ORCH to SECURITY-REVIEWER, never to WF-03
directly; then re-run this step once
resolved, per `.claude/agents/product-owner.md`'s rework policy (`max_rework: 1`).
A scope blocked by its process audit is routed by the findings ORCH already filed at Step 0b (not by a new issue from PRODUCT-OWNER's side); once the audited files change, the next run re-audits the scope at Step 0b.
