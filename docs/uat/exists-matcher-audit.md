# The `exists` matcher of the UAT runner, and the audit of every use (T-3107)

The runner of the UAT scenarios (`scripts/uat/runner.py`) judges one answer against one path with
one matcher. `{"exists": true}` used to mean **"the path was found"**, so a value of `null` passed:
the step said the value was there while the answer carried nothing. T-3107 fixes the matcher and
audits every use of it in `test/uat/processes`.

## The rule

| matcher | means | on a list |
|---|---|---|
| `{"exists": true}` | a value is really there: the path was found and the value is neither `null` nor empty (`''`, `[]`, `{}`) | the list holds at least one item |
| `{"present": true}` | the key is there: the value may be `null` or empty | the list may be empty |
| `{"absent": true}` | the path is missing, or the value is `null` | - |
| `{"absent": false}` | the path is there and the value is not `null` | - |

`false`, `0` and a number are values: `exists` accepts them. A `null` and an empty string, list or
map are not: `exists` refuses them.

`present` is the explicit "the key is there" matcher. A step that uses it says so in its own
words (`says`), so a reader of the scenario knows that the `null` or the empty list is intended and
not an accident. The old `exists` proved exactly what `present` proves today (the key is there),
so no step lost a proof by the change; the steps that carry a real value keep the stronger
`exists`.

The defect and the red proof: `scripts/uat/tests/test_runner.py`, `test_exists_needs_a_value`
(a `null` passed `exists` on the code before this change), `test_exists_false_is_the_negation`
and `test_present_allows_a_null_or_an_empty_value`.

## The passes that proved nothing

One, and it is the one the PM named:

| scenario | step | path | the value in the last real smoke output | what it proved |
|---|---|---|---|---|
| BP-PLATFORM-01-register-tenant | C3 | `$.idp_realm_id` | `null` (smoke `smoke-T-2906-bpm-default`, run `20261127T032640Z-77fe89`, step C3, `2026-11-27T03:47:42Z`; the same value in `smoke-T-2986-bpm-default`, run `20261127T024554Z-db6538`, `2026-11-27T02:46:34Z`) | nothing: the realm of the new tenant was not proved, the step passed on a `null` |

The step itself did not prove nothing: it also asserted `$.slug` and `$.status`, and those two
were real. The void claim was the realm.

**Does BP-PLATFORM-01 C3 "realm bound" still pass with `idp_realm_id` null? No.** The assertion
left C3 and is now the step C3r, which carries a `blocked_by` marker: it is reported as NOT RUN
(blocked), never as a pass, until a throwaway tenant has a realm. The realm is now either proved
or reported as not proved; it is never a pass on a `null`. C3 itself asserts what is true on QA
(the tenant exists and is active) and no longer claims a realm.

## The audit

Every `exists` (and the one `{"absent": false}`) in `test/uat/processes` as it was before this
change, with the value the **last real smoke output** produced at that path. The value is quoted
from `state/uat-runs/*/run.jsonl`: the newest record of a step that passed. A scenario that never
ran on a recorded smoke says so; such a row never passed, so it cannot have relied on a `null`.

"relied on null?" is the answer to the question the PM asked: did the pass rest on a value that
was not there?

| scenario | step | path | matcher | value in the last passing smoke run | relied on null? | fix in this change |
|---|---|---|---|---|---|---|
| BP-01-receive-goods.json | s5 | $.entry_id | exists | "6fddd9d4-d35f-4856-9906-09ec4b27b64a" | no | unchanged |
| BP-02-issue-goods.json | s8 | $.entry_id | exists | "c71f2a04-7bac-41eb-9e06-8ccb1e6f2ab4" | no | unchanged |
| BP-03-transfer.json | s8 | $.entry_id | exists | "6058fd76-058d-41d9-8e4d-37d31108b2c0" | no | unchanged |
| BP-04-count.json | s2 | $.entry_id | exists | "0b8c19f1-2053-4de3-8ef4-084cd50721ad" | no | unchanged |
| BP-05-reversal.json | s4 | $.entry_id | exists | "5af4d449-73da-4420-b790-befb469d3d6d" | no | unchanged |
| BP-05-reversal.json | s12 | $.reversed_at | exists | "2026-11-26T16:38:13Z" | no | unchanged |
| BP-07-new-company-onboarding.json | s3 | $.entry_id | exists | "8e114466-db94-44d5-86da-bc31163fae70" | no | unchanged |
| BP-08-old-app-phone-operations.json | s2 | $.skus[0].id | exists | "***" | no | unchanged |
| BP-08-old-app-phone-operations.json | s2 | $.locations[1].id | exists | "***" | no | unchanged |
| BP-08-old-app-phone-operations.json | s5 | $.id | exists | "***" | no | unchanged |
| BP-10-formal-count-order.json | s7 | $.cut_off_at | exists | no smoke run on record | ? | unchanged |
| BP-10-formal-count-order.json | s17 | $.sheet_signed_at | exists | no smoke run on record | ? | unchanged |
| BP-10-formal-count-order.json | s18 | $.differences_number | exists | no smoke run on record | ? | unchanged |
| BP-10-formal-count-order.json | s20 | $.differences_signed_at | exists | no smoke run on record | ? | unchanged |
| BP-10-old-address-retry-by-client-id.json | s2 | $.skus[0].id | exists | no smoke run on record | ? | unchanged |
| BP-10-old-address-retry-by-client-id.json | s2 | $.locations[0].id | exists | no smoke run on record | ? | unchanged |
| BP-11-excel-load-and-quick-count.json | s7 | $.entry_id | exists | no smoke run on record | ? | unchanged |
| BP-DESIGNER-34-sub-process-proof.json | A6 | $.instance_id | exists | "15bcdb7f-428c-4b4b-ba08-536dcc2f1555" | no | unchanged |
| BP-DESIGNER-34-sub-process-proof.json | A7 | $.items[0].instance_id | exists | "c6315277-a1e7-4b73-ba21-ee67941bfaac" | no | unchanged |
| BP-DESIGNER-34-sub-process-proof.json | A14 | $.steps[1].result | exists | "completed" | no | unchanged |
| BP-DESIGNER-34-sub-process-proof.json | F5 | $.instance_id | exists | "abbe7195-4d79-4a91-8bf5-e41b5f01976b" | no | unchanged |
| BP-DESIGNER-34-sub-process-proof.json | F6 | $.items[0].instance_id | exists | "77b7317f-da29-4763-84ac-173838caa14f" | no | unchanged |
| BP-DESIGNER-34-sub-process-proof.json | F11 | $.items | exists | [{"context_json": null, "created_at": "2026-11-27T08:21:4... | no | the matcher is now `present` (the list may be empty) |
| BP-DESIGNER-34-sub-process-proof.json | U3 | $.instance_id | exists | "cbe966c3-e0da-453d-a6b4-e23b063348b1" | no | unchanged |
| BP-DESIGNER-34-sub-process-proof.json | U8 | $.items[0].instance_id | exists | "0652917d-02b4-4644-8ba7-b309f59cfa4b" | no | unchanged |
| BP-EXAM-01-write-the-question-bank.json | s1 | $.record_id | exists | no smoke run on record | ? | unchanged |
| BP-EXAM-01-write-the-question-bank.json | s2 | $.record_id | exists | no smoke run on record | ? | unchanged |
| BP-EXAM-02-build-an-exam.json | s1 | $.record_id | exists | no smoke run on record | ? | unchanged |
| BP-EXAM-02-build-an-exam.json | s2 | $.record_id | exists | no smoke run on record | ? | unchanged |
| BP-EXAM-02-build-an-exam.json | s3 | $.record_id | exists | no smoke run on record | ? | unchanged |
| BP-EXAM-02-build-an-exam.json | s4 | $.record_id | exists | no smoke run on record | ? | unchanged |
| BP-MASTER-04-location-tree.json | s1 | $.record_id | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-01-register-tenant.json | A3a | $.items[1].inputs[0].name | exists | "tenant_id" | no | unchanged |
| BP-PLATFORM-01-register-tenant.json | A3a | $.items[2].outputs[0].name | exists | "tenant_id" | no | unchanged |
| BP-PLATFORM-01-register-tenant.json | B1 | $.instance_id | exists | "20861e51-8c0b-4e6e-8d37-c9ccc1e94a6d" | no | unchanged |
| BP-PLATFORM-01-register-tenant.json | B2 | $.steps[1].step | absent-false | "tenant.validate" | no | unchanged |
| BP-PLATFORM-01-register-tenant.json | C2 | $.steps[1].started_at | exists | "2026-11-27T03:49:56.106751Z" | no | unchanged |
| BP-PLATFORM-01-register-tenant.json | C2 | $.steps[1].duration_ms | exists | 909 | no | unchanged |
| BP-PLATFORM-01-register-tenant.json | C3 | $.idp_realm_id | exists | null | **YES** | moved to step C3r (blocked_by: the realm of a throwaway tenant) |
| BP-PLATFORM-01-register-tenant.json | E1 | $.instance_id | exists | "044c059c-9e11-44ab-90f9-b83410642e5d" | no | unchanged |
| BP-PLATFORM-01-register-tenant.json | E3 | $.steps[10].last_failure_kind | exists | "platform_call_notify_refused" | no | unchanged |
| BP-PLATFORM-01-register-tenant.json | E4 | $.items[0].id | exists | "18fb215e-11d6-476d-ab0a-ae35db8363fe" | no | unchanged |
| BP-PLATFORM-01-register-tenant.json | F6 | $.instance_id | exists | "c7380966-eded-4233-af5d-ffc7aa588dfc" | no | unchanged |
| BP-PLATFORM-01-register-tenant.json | G3 | $.instance_id | exists | "df5323c9-1c48-46ff-97dd-5d036017c700" | no | unchanged |
| BP-PLATFORM-02-tenant-lifecycle-process.json | B1 | $.instance_id | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-02-tenant-lifecycle-process.json | C1 | $.instance_id | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-02-tenant-lifecycle-process.json | C3 | $.steps[2].last_failure_kind | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-02-tenant-lifecycle-process.json | D1 | $.instance_id | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-02-tenant-lifecycle-process.json | E1 | $.instance_id | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-02-tenant-lifecycle-process.json | E3 | $.steps[2].last_failure_kind | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-02-tenant-lifecycle-process.json | F1 | $.instance_id | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-02-tenant-lifecycle-process.json | G1 | $.instance_id | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-02-tenant-lifecycle-process.json | G3 | $.instance_id | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-03-host-name.json | s2 | $.onboarding_id | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-03-host-name.json | s11 | $.changed | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-04-script-policy.json | s2 | $.solo_audited.allowed | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-05-onboarding-records.json | s1 | $.errors[0].field | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-05-onboarding-records.json | s11 | $.onboarding_id | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-05-onboarding-records.json | s12 | $.login.status | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-05-onboarding-records.json | s14 | $.pending_admins | exists | no smoke run on record | ? | the matcher is now `present` (the list may be empty) |
| BP-PLATFORM-07-module-rollout-read-only.json | s1 | $.rollouts | exists | no smoke run on record | ? | the matcher is now `present` (the list may be empty) |
| BP-PLATFORM-07-module-rollout-read-only.json | s5 | $.rollout.module_id | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-08-migration-fanout-read-only.json | s3 | $.errors[0].field | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-09-event-retention.json | s1 | $.computed_at | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-09-event-retention.json | s1 | $.tenant_schema_count | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-09-event-retention.json | s1 | $.protected_record_count | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-10-watch-platform.json | s1 | $.configured | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-10-watch-platform.json | s1 | $.jobs | exists | no smoke run on record | ? | the matcher is now `present` (the list may be empty) |
| BP-PLATFORM-10-watch-platform.json | s2 | $.items[0].slug | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-11-service-catalogue.json | s1 | $.items | exists | no smoke run on record | ? | the matcher is now `present` (the list may be empty) |
| BP-PLATFORM-12-problem-reports.json | s1 | $.reports | exists | no smoke run on record | ? | the matcher is now `present` (the list may be empty) |
| BP-PLATFORM-12-problem-reports.json | s2 | $.reports | exists | no smoke run on record | ? | the matcher is now `present` (the list may be empty) |
| BP-PLATFORM-24-definition-drives-execution.json | A4 | $.instance_id | exists | "0a5551c1-40e5-4f05-a44b-84f5aa7df56b" | no | unchanged |
| BP-PLATFORM-24-definition-drives-execution.json | B4 | $.instance_id | exists | "189a0c5f-5851-47f0-84cc-ee7665d2d0fa" | no | unchanged |
| BP-PLATFORM-24-definition-drives-execution.json | B6 | $.steps[0].result | exists | "completed" | no | unchanged |
| BP-PLATFORM-24-definition-drives-execution.json | B6 | $.steps[4].result | exists | "running" | no | unchanged |
| BP-PLATFORM-24-definition-drives-execution.json | B10 | $.steps[0].result | exists | "completed" | no | unchanged |
| BP-PLATFORM-24-definition-drives-execution.json | B10 | $.steps[5].result | exists | "running" | no | unchanged |
| BP-PLATFORM-24-definition-drives-execution.json | C3 | $.instance_id | exists | "f13f1aef-fd12-41be-b656-1b84215ac123" | no | unchanged |
| BP-PLATFORM-24-definition-drives-execution.json | C5 | $.steps[0].result | exists | "completed" | no | unchanged |
| BP-PLATFORM-24-definition-drives-execution.json | C5 | $.steps[3].result | exists | "running" | no | unchanged |
| BP-PLATFORM-24-definition-drives-execution.json | D3 | $.instance_id | exists | "ca9cf022-d19c-445f-bf9c-30e940482d6b" | no | unchanged |
| BP-PLATFORM-24-definition-drives-execution.json | D5 | $.steps[0].result | exists | "completed" | no | unchanged |
| BP-PLATFORM-24-definition-drives-execution.json | D5 | $.steps[5].result | exists | "running" | no | unchanged |
| BP-PLATFORM-24-definition-drives-execution.json | E3 | $.instance_id | exists | "13816192-3c06-4cf1-83c0-5e900543e434" | no | unchanged |
| BP-PLATFORM-24-definition-drives-execution.json | E5 | $.steps[0].result | exists | "completed" | no | unchanged |
| BP-PLATFORM-24-definition-drives-execution.json | E5 | $.steps[3].result | exists | "running" | no | unchanged |
| BP-PLATFORM-25-designer.json | B1 | $.items | exists | [{"activation_state": "ok", "archived_at": null, "created... | no | unchanged |
| BP-PLATFORM-25-designer.json | B3 | $.instance_id | exists | "45baad88-01f4-4527-9a5e-09f45c770b1a" | no | unchanged |
| BP-PLATFORM-25-designer.json | B4 | $.items | exists | [{"correlation_key": null, "definition_id": "0a952a68-e60... | no | unchanged |
| BP-PLATFORM-25-designer.json | B6 | $.steps[1].last_failure_kind | exists | "platform_call_invalid_slug" | no | unchanged |
| BP-PLATFORM-25-designer.json | B7 | $.items[0].id | exists | "d240d0f9-3b57-4528-aec2-2d0989833883" | no | unchanged |
| BP-PLATFORM-26-no-bypass.json | R1a | $.instance_id | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-26-no-bypass.json | R1a | $.slug | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-26-no-bypass.json | R2a | $.instance_id | exists | no smoke run on record | ? | unchanged |
| BP-PLATFORM-26-no-bypass.json | R2a | $.slug | exists | no smoke run on record | ? | unchanged |
| BP-QOIMEKS-REHEARSAL-03.json | r1 | $.instance_id | exists | no smoke run on record | ? | unchanged |
| BP-TENANT-ADMIN-01-sign-in-company-address.json | s1 | $.client_id | exists | no smoke run on record | ? | unchanged |
| BP-TENANT-ADMIN-01-sign-in-company-address.json | s1 | $.tenant_type | exists | no smoke run on record | ? | unchanged |
| BP-TENANT-ADMIN-01-sign-in-company-address.json | s2 | $.user_id | exists | no smoke run on record | ? | unchanged |
| BP-TENANT-ADMIN-01-sign-in-company-address.json | s2 | $.roles | exists | no smoke run on record | ? | unchanged |
| BP-TENANT-ADMIN-32-my-tasks-read-and-unknown-task.json | s1 | $.items | exists | no smoke run on record | ? | the matcher is now `present` (the list may be empty) |
| BP-TENANT-ADMIN-32-my-tasks-read-and-unknown-task.json | s2 | $.items | exists | no smoke run on record | ? | the matcher is now `present` (the list may be empty) |
| SEC-ASSETS-02-cross-tenant-refused.json | s2 | $.rows[0].id | exists | "0e978d0e-cafc-47fc-a3dc-40fb906e99e3" | no | unchanged |
| SEC-ASSETS-02-cross-tenant-refused.json | s3 | $.rows[0].id | exists | "5fe55f52-3d04-4130-8252-7e4ac8782072" | no | unchanged |
| SEC-ID-01-login-host-and-realm-lookup.json | s1 | $.oidc_authority | exists | "https://auth.qa.bizdala.com/realms/bpm-default" | no | unchanged |
| SEC-ID-01-login-host-and-realm-lookup.json | s1 | $.client_id | exists | "letflow-web" | no | unchanged |
| SEC-ID-01-login-host-and-realm-lookup.json | s2 | $.tenant_type | exists | "test" | no | unchanged |
| SEC-ID-01-login-host-and-realm-lookup.json | s10 | $.realm_url | exists | "https://auth.qa.bizdala.com/realms/bpm-default" | no | unchanged |
| SEC-ID-02-other-company-token.json | s2 | $.user_id | exists | "442b89dc-e944-493c-bec5-bdaece48eb9f" | no | unchanged |
| SEC-ID-02-other-company-token.json | s3 | $.rows[0].id | exists | "0e978d0e-cafc-47fc-a3dc-40fb906e99e3" | no | unchanged |
| SEC-ID-02-other-company-token.json | s9 | $.id | exists | "***" | no | unchanged |
| SEC-ID-02-other-company-token.json | s14 | $.revoked_at | exists | "2026-11-26T16:12:30Z" | no | unchanged |
| SEC-ID-03-admin-routes-per-role.json | s1 | $.items[0].definition_name | exists | "assets_opening" | no | unchanged |
| SEC-ID-03-admin-routes-per-role.json | s2 | $.items[0].registration | exists | "stock" | no | unchanged |
| SEC-ID-04-shared-access-lifecycle.json | s7 | $.value | exists | "***" | no | unchanged |
| SEC-ID-04-shared-access-lifecycle.json | s8 | $.created_at | exists | "2026-11-26T16:12:44.351432Z" | no | unchanged |
| SEC-ID-04-shared-access-lifecycle.json | s10 | $.value | exists | "***" | no | unchanged |
| SEC-ID-04-shared-access-lifecycle.json | s11 | $.rotated_at | exists | "2026-11-26T16:12:46.477030Z" | no | unchanged |
| SEC-ID-05-platform-routes-need-platform-role.json | s9 | $.items[0].slug | exists | "bpm-default" | no | unchanged |
| SEC-ID-08-other-company-changes-refused.json | s1 | $.user_id | exists | "442b89dc-e944-493c-bec5-bdaece48eb9f" | no | unchanged |
| SEC-ID-08-other-company-changes-refused.json | s2 | $.id | exists | "86e0ed58-dc7a-472f-9c99-b6f47b6147a6" | no | unchanged |
| SEC-OLD-01-revoked-and-rotated-value-refused.json | s7 | $[0].sku_id | exists | "***" | no | unchanged |
| SEC-OLD-03-only-the-old-app-calls-are-served.json | s3 | $.skus[0].id | exists | "***" | no | unchanged |
| SEC-OLD-03-only-the-old-app-calls-are-served.json | s3 | $.locations[0].id | exists | "***" | no | unchanged |
| SEC-OLD-03-only-the-old-app-calls-are-served.json | s5 | $[0].sku_id | exists | "***" | no | unchanged |
| SEC-OLD-05-client-id-idempotency-and-body-refusals.json | s4 | $[0].sku_id | exists | "***" | no | unchanged |
| SEC-OLD-06-count-switch-on-waits-for-the-administrator.json | s5 | $[0].qty | exists | "***" | no | unchanged |
| SEC-OLD-06-count-switch-on-waits-for-the-administrator.json | s10 | $.rows[0].id | exists | "0dde8314-2748-4c68-a71a-1cce49976cef" | no | unchanged |
| SEC-OLD-07-zero-count-and-negative-count.json | s5 | $[0].qty | exists | "***" | no | unchanged |
| SEC-OLD-07-zero-count-and-negative-count.json | s10 | $.rows[0].id | exists | "65072848-9d3f-42e1-b3ba-739647f209f0" | no | unchanged |
| SEC-OLD-08-count-switch-off-posts-at-once.json | s5 | $[0].qty | exists | "***" | no | unchanged |
| SEC-OLD-09-code-lookup-voice-and-reads-refuse-bad-input.json | s3 | $[0].sku_id | exists | "***" | no | unchanged |
| SEC-STOCK-03-completion-write-targets-refused.json | s16 | $.entry_id | exists | "3dca6d72-17ff-48a6-be26-95c7fc166798" | no | unchanged |
| SEC-STOCK-04-cross-tenant-refused.json | s15 | $.rows[0].id | exists | "5fe55f52-3d04-4130-8252-7e4ac8782072" | no | unchanged |
| SEC-STOCK-05-permission-matrix.json | s20 | $.items | exists | [{"changed_at": null, "changed_by": null, "changed_by_nam... | no | the matcher is now `present` (the list may be empty) |
| SEC-STOCK-05-permission-matrix.json | s27 | $.items | exists | [{"changed_at": null, "changed_by": null, "changed_by_nam... | no | the matcher is now `present` (the list may be empty) |
| SEC-STOCK-06-quick-count-four-eyes.json | s0 | $.rows[0].quantity | exists | "15.000000000" | no | unchanged |
| SEC-STOCK-07-quick-count-self-approval-own-only.json | s0 | $.rows[0].quantity | exists | "15.000000000" | no | unchanged |
| SEC-STOCK-08-negative-balance-refused.json | s1 | $.rows[0].quantity | exists | "15.000000000" | no | unchanged |
| SEC-STOCK-09-negative-balance-allowed.json | s1 | $.rows[0].quantity | exists | "15.000000000" | no | unchanged |
| SEC-STOCK-09-negative-balance-allowed.json | s5 | $.entry_id | exists | "d56e599f-da4c-4fa6-aa2e-de89320f340e" | no | unchanged |
| SEC-STOCK-10-workbook-load-permissions.json | s0 | $.rows[0].document_id | exists | "dc4102ff-c17f-419a-b9f4-8b4a2b41c234" | no | unchanged |
| SEC-STOCK-11-idempotency-replay.json | s0 | $.rows[0].quantity | exists | "15.000000000" | no | unchanged |


Totals: 144 matcher rows in 62 scenario files. 90 rows have a value in the last real smoke
output (all of them a real value: not null, not empty). 1 row rests on a `null` (BP-PLATFORM-01
C3, fixed above). 53 rows belong to scenarios that never ran on a recorded smoke, so there is no
value to quote and no pass that could have relied on a `null`.

What this change does with the rows:

* 1 row (BP-PLATFORM-01 C3 `$.idp_realm_id`) moved into the step C3r, which is `blocked_by`.
* 11 rows changed their matcher to `present`: the value is a list that may be empty on this
  environment and the step says so (BP-DESIGNER-34 F11 the dead-letter list, BP-PLATFORM-05 s14
  the pending administrators, BP-PLATFORM-07 s1 the rollouts, BP-PLATFORM-10 s1 the backup jobs,
  BP-PLATFORM-11 s1 the catalogue, BP-PLATFORM-12 s1 and s2 the problem reports, BP-TENANT-ADMIN-32
  s1 and s2 the task inbox, SEC-STOCK-05 s20 and s27 the approval rules).
* 132 rows keep `exists` (the 133rd row is the one `{"absent": false}`, unchanged). Their value in
  the last real smoke output was a real value, and the matcher is now the stronger one: a `null` or
  an empty list would fail them.

## How to reproduce the audit

```bash
# the audit itself (the script is in the task folder of T-3107):
python3 -B <team-root>/state/tasks/T-3107/audit_exists.py

# every matcher of the scenario tree:
grep -rn '"exists"' test/uat/processes/

# the value of the one void pass, in the run the PM named:
grep -h '"step": "C3"' state/uat-runs/*/run.jsonl | grep '"what": "$.idp_realm_id"'
```

## The rule for the next matcher

An assertion names what it proves. `exists` says "a value is there"; when a step only wants the
key, say `present` and say so in the step's own words. A step that cannot be proved on the
environment carries a `blocked_by` with its owner; it is reported as NOT RUN, never as a pass.
