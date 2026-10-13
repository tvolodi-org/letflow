# REQ-447 / Q-964 -- infra contract: QA realm role mapping PLATFORM_ADMIN -> TENANT_ADMIN

Status: CONTRACT (CODE-DESIGNER), companion of `lib/letflow/design/req447-tenant-admin-role.md` (section 5 there is the overall procedure; this file is the realm side only). Names only: no passwords, no tokens, no secret values anywhere in this file. Infra (`ai-dala-infra`) executes this as a separate task; letflow code does not touch Keycloak.

Evidence base (read-only, from `ai-dala-infra`): run `2026-10-06-qa-realm-platform-admin-roles-check-001` step 06 (probe of all realms: `PLATFORM_ADMIN` is a plain direct realm role mapping everywhere, not composite, no Keycloak groups, `default-roles-<realm>` holds no app role); `scripts/qa-uat-env.sh` lines 13, 16, 19, 24, 35 and `scripts/qa-uat-env.ps1` (registry role column); `scripts/qa-login.sh` lines 30-35 and `qa-login.ps1`; tasks T-0150, T-0168 (forward note), T-0169. Letflow side: `test/fixtures/uat/actors.yaml:80,157-165`; realm file `priv/keycloak/realms/bpm-default.json:10-19,119`.

## 0. Hard preconditions (STOP if any fails; report to ORCH)

* P1. The letflow server on QA has `LETFLOW_PLATFORM_TENANT_ID` set to the tenant id of the tenant bound to realm `bpm-default` (the platform operator's tenant). If it is unset or names another tenant, do not start: the letflow migration also refuses to run, and the `bpm-default` operators below would otherwise be treated as ordinary tenant admins.
* P2. Letflow PR 1 of REQ-447 is merged (it is gated on Q-1008 / ISS-1026 and merges after it) and deployed to QA before the letflow DB runbook (section 8) and before step R3 (R1 and R2 are add-only and may run earlier).
* P3. The letflow DB migration steps S3 and S4 of design section 5 are verified before step R4 (any removal of `PLATFORM_ADMIN`).

## 1. Realm role creation (add-only)

| Realm | Role to create | Notes |
|---|---|---|
| swiftroute | `TENANT_ADMIN` | plain realm role, not composite, same shape as the other app roles |
| vortex | `TENANT_ADMIN` | same |
| meridian | `TENANT_ADMIN` | same |
| bilimbaga | `TENANT_ADMIN` | same (realm slated for decommission, T-0149; do it anyway until then) |
| bpm-default | `TENANT_ADMIN` | the repository realm file defines it for a FRESH import only; the live QA realm needs the role created. Required so the realm role set equals the letflow role set (decision 0013) |
| master | none | not a letflow tenant realm |

The role must appear in the access-token claim path letflow reads (`realm_access.roles`, or `roles`; `lib/letflow/oidc/claim_mapping_config.ex:93`). The existing `realm-roles` protocol mapper on the `letflow-web` client already emits all realm roles of the user; nothing to change there (confirm on one token in R5).

Do not create the user `tenant-admin-user` on QA unless ORCH asks (it exists in the repository realm file for fresh developer realms only).

Scope of the new role (SECURITY-REVIEWER F5, mandatory): `TENANT_ADMIN` must be mapped ONLY to the users of section 2. It must NOT be added to `default-roles-<realm>` (the composite every new user receives), to any default group, to any Keycloak group, to any client-scope role mapping or to any composite role, in any realm. Reason: the `realm-roles` mapper emits every realm role of a user into the token, and a first-login claim sync would then bind a user to the `TENANT_ADMIN` group, making every user an administrator. Verify after R1 and again after R2 by reading, per realm, the composites of `default-roles-<realm>`, the default groups and the role scope mappings of `letflow-web`: none contains `TENANT_ADMIN` (names only). The same applies to every realm created later (section 3b).

## 2. User mapping (exact)

Legend: ADD = add the realm role mapping; REMOVE = delete the realm role mapping. Every user keeps all other role mappings unchanged.

| Realm | User | Today | After (final) | ADD | REMOVE |
|---|---|---|---|---|---|
| swiftroute | `swiftroute-admin-user` | `PLATFORM_ADMIN` | `TENANT_ADMIN` | `TENANT_ADMIN` | `PLATFORM_ADMIN` |
| swiftroute | `actor-swiftroute-alice` | `PLATFORM_ADMIN`, `TASK_WORKER` | `TENANT_ADMIN`, `TASK_WORKER` | `TENANT_ADMIN` | `PLATFORM_ADMIN` |
| vortex | `vortex-admin-user` | `PLATFORM_ADMIN` | `TENANT_ADMIN` | `TENANT_ADMIN` | `PLATFORM_ADMIN` |
| meridian | `meridian-admin-user` | `PLATFORM_ADMIN` | `TENANT_ADMIN` | `TENANT_ADMIN` | `PLATFORM_ADMIN` |
| bilimbaga | `bilimbaga-admin-user` | `PLATFORM_ADMIN` | `TENANT_ADMIN` | `TENANT_ADMIN` | `PLATFORM_ADMIN` |
| bilimbaga | `promo-reader-uat` | `PLATFORM_ADMIN` (not in the registry; T-0169 open) | `TENANT_ADMIN` (PENDING THE USER'S DECISION, T-0168/T-0169) | `TENANT_ADMIN` | `PLATFORM_ADMIN` |

Notes on names (flagged discrepancies, do not guess):

* The brief names a user `alice`. No such user exists in any realm (probe: "plain `alice`: NOT FOUND (exact)"). The account that holds `PLATFORM_ADMIN` + `TASK_WORKER` in realm swiftroute is `actor-swiftroute-alice`; the table uses that name. If another account was meant, ORCH names it.
* `promo-reader-uat` is subject to the user's pending decision in T-0169 / T-0168 (keep, remove the role, or delete the account). If the user decides "remove the role" or "delete", the row becomes REMOVE `PLATFORM_ADMIN` only (no ADD) or the account is deleted; the realm-side outcome for this row is then different from the table, and the letflow side is unaffected. The name suggests a reader (a `TENANT_AUDITOR` would fit once REQ-448 exists); the table follows the brief (`TENANT_ADMIN`) as the default.

Users that are NOT changed:

| Realm | User | Why |
|---|---|---|
| bpm-default | `admin-user` | holds `PLATFORM_ADMIN` as the platform operator (P1 must hold) |
| bpm-default | `promo-proposer-uat`, `uat-promo-conflict-proposer` | hold `PLATFORM_ADMIN` in the platform tenant's realm; staying platform operators is a T-0166/T-0168 decision, not REQ-447's |
| bpm-default | `worker-user`, `designer-user`, `operator-user`, `alice-ceo-user`, `lena-dispatcher-user`, `marco-ops-manager-user` | no admin role |
| swiftroute | `actor-swiftroute-lena`, `actor-swiftroute-marco`, `actor-swiftroute-tobias` | no admin role |
| vortex, meridian | all `actor-vortex-*` and `actor-meridian-*` | `TASK_WORKER` / `PROCESS_OPERATOR` only |
| bilimbaga | `candidate-user` | `CANDIDATE` only |

## 3. Order of operations

Always add before remove; verify between. Steps R1-R2 are add-only and safe at any time; R3 is the gate; R4 is the only destructive step.

| Step | When | Action |
|---|---|---|
| R0 | first | check P1; record the QA letflow version (build SHA) in the run notes |
| R1 | any time | create the realm role `TENANT_ADMIN` in the five realms of section 1 |
| R2 | any time after R1 (recommended: after letflow PR 1 is deployed) | for each user of section 2: ADD `TENANT_ADMIN` (keep `PLATFORM_ADMIN`). Tokens now carry both claims. |
| R3 | after the runbook of section 8 (steps A-G, letflow S3 and S4) is verified (design section 5; the migration report lists every tenant as `migrated` or `unchanged`, `failed: []`) | verify by login, per user of section 2: a fresh access token's role claim contains `TENANT_ADMIN`. Verify the HTTP checks of section 4. |
| R4 | only after R3 passes for ALL six users | for each user of section 2: REMOVE `PLATFORM_ADMIN` |
| R5 | right after R4 | repeat the section 4 checks with a NEW login for each user (existing access tokens remain valid until they expire; the server derives OIDC roles from its database anyway) |
| R6 | after R5 | update the infra registry and docs (section 5) and report to ORCH: per user, the role claims of a fresh token (names only) and the section 4 results |

If any check fails after R4: re-add `PLATFORM_ADMIN` to the failing user (restores the claim, not the legacy powers: see rollback in design section 5.3), keep the `TENANT_ADMIN` mapping, and report to ORCH. Do not delete the `TENANT_ADMIN` role.

## 3b. What the realm change does and does not do server-side (read before R2/R4)

* Existing users: their server-side roles come from the letflow DATABASE migration (section 8), not from the realm. Letflow copies a token's role claims into its tables only at a user's FIRST login. Adding `TENANT_ADMIN` in the realm therefore changes nothing server-side for an existing user; it matters for NEW users and for the web app, which reads the roles in the token until REQ-450. Removing `PLATFORM_ADMIN` from the realm does not demote an already-synced user either; to revoke an administrator, remove them from the letflow `TENANT_ADMIN` group (letflow `DELETE /groups/:id/members/:user_id`).
* New realms and new tenants: from letflow PR 1 on, a NEW tenant gets no `PLATFORM_ADMIN` binding (it is no longer seeded outside the platform tenant). A realm that issues only the `PLATFORM_ADMIN` claim therefore gives that tenant's first admin NO role. EVERY realm created after PR 1 must issue the realm role `TENANT_ADMIN` to its first administrator (and never `PLATFORM_ADMIN`). The onboarding wizard does not create that administrator or the realm (issue Q-1012 / GH #2312 / ISS-1030; not part of REQ-447): the realm and its first user remain an infra step. ISS-1030 PR 2 adds a pending administrator grant: when the operator names an `admin_email` at onboarding, that person becomes `TENANT_ADMIN` at their first sign-in through the tenant's own realm with a VERIFIED e-mail, so for that person the realm role mapping is optional; every other administrator still needs the realm role (decision 0048, `docs/runbooks/onboarding-new-tenant-realm.md`).
* The platform tenant's realm accounts: `promo-proposer-uat` and `uat-promo-conflict-proposer` stay `PLATFORM_ADMIN` only if they are accounts of the platform tenant's realm. Confirm (names only) that the realm `bpm-default` is the realm bound to the tenant that `LETFLOW_PLATFORM_TENANT_ID` names (P1). If they live in a realm of any other tenant they cannot stay `PLATFORM_ADMIN` after letflow PR 2 (the role would be dropped for them); report to ORCH.

## 4. Checks (HTTP, names of routes only; tokens never printed, per the infra secret-handling rule)

For each user of section 2 (token minted through `scripts/qa-uat-env.sh token <user>` inside one command, never echoed):

* `GET /api/v1/identity/users`: 200.
* `GET /api/v1/identity/tokens`: 200.
* `GET /api/v1/tenants`: 403 (a tenant admin has no platform scope).
* `GET /api/v1/admin/services`: 403.
* For `actor-swiftroute-alice` additionally `GET /api/v1/tasks/inbox` (exact route): she must still see her own tasks and, as `TENANT_ADMIN`, all tenant tasks (letflow behaviour defined in design 3.1).
* For `admin-user` (bpm-default, unchanged): `GET /api/v1/tenants` 200 and `GET /api/v1/admin/services` 200 (proves the operator was not demoted; this is the guard for P1).
* Negative controls (a user that must NOT be an administrator; F5): `actor-swiftroute-lena` (swiftroute), `candidate-user` (bilimbaga) and a non-admin user of the PLATFORM realm, `worker-user` (bpm-default), get 403 on `GET /api/v1/identity/users`. Run them after R2 and after R4. A 200 for either means `TENANT_ADMIN` leaked into a default role, group or client scope: stop and report.

After letflow PR 2 is deployed, repeat the same checks once (R7).

## 5. Registry and documentation updates (infra repo; names only)

* `scripts/qa-uat-env.sh` and `scripts/qa-uat-env.ps1`: the role column of the entries `swiftroute-admin-user`, `vortex-admin-user`, `meridian-admin-user`, `bilimbaga-admin-user` changes from `PLATFORM_ADMIN` to `TENANT_ADMIN` (lines 16, 19, 24, 35 in the `.sh`); `admin-user` (line 13) stays `PLATFORM_ADMIN`.
* `scripts/qa-login.sh` and `scripts/qa-login.ps1`: the description strings for the same four users (lines 30-35 in the `.sh`) change to `TENANT_ADMIN (realm <realm>)`.
* `landscape/hosts/ubuntu-16gb-nbg1-1.md` Keycloak section and `landscape/secrets-inventory.md`: roles per user as in section 2 (names only).
* `actor-swiftroute-alice` is not in the `qa-uat-env` registry as an admin entry; no registry change for her beyond what the registry already records.
* T-0168 forward note ("Forward note: legacy tenant-realm admin role") is closed by R6; T-0169 stays open for its own decision.

## 6. Letflow-side follow-ups that are NOT infra's and NOT REQ-447's (for ORCH to route)

* `test/fixtures/uat/actors.yaml`: `actor-swiftroute-alice` `builtin_roles: [PLATFORM_ADMIN, TASK_WORKER]` (line 80) and the `legacy_platform_admin` entry (lines 157-165, `removed_by: REQ-454`) change after R4, under REQ-454.
* The seed scripts (`scripts/seed_*_persona_actors.sh`, `scripts/lib/seed_persona_actors_base.sh`) say the bearer token is for "a PLATFORM_ADMIN user in the target tenant" (swiftroute line 23/44, meridian 13, vortex 13, base line 22). After letflow PR 2 such a token is no longer authorised for the tenant-scope calls those scripts make; the text and the registry user choice change to a `TENANT_ADMIN` user (REQ-454 / a docs task). Infra's `QA_AUTH_TOKEN` usage (`qa-uat-env.sh token <tenant>-admin-user`) keeps working because those users become `TENANT_ADMIN`.
* `scripts/uat_preflight.sh` lines 64, 294, 418, 638: comments and the "first seeded PLATFORM_ADMIN-ish user" selection are for the platform operator (`admin-user`) and stay valid.

## 7. Open points for ORCH (the infra task cannot decide these)

* Is the QA pin (P1) set and equal to the `bpm-default` tenant id? (cannot be read from the repository).
* `promo-reader-uat`: keep `TENANT_ADMIN` for it, listed as PENDING THE USER'S DECISION (T-0168/T-0169); the row in section 2 is executed only after that decision.
* Whether any non-QA Keycloak (a development stack from the repository realm file) needs the same mapping: the repository realm file already carries `TENANT_ADMIN` after letflow PR 1, so a fresh import needs nothing.
* The onboarding wizard administrator problem is filed separately (Q-1012 / GH #2312 / ISS-1030, direction: a pending `TENANT_ADMIN` keyed by the normalised e-mail address, bound at the first verified login). It is not part of this contract and not part of REQ-447 PR 1 or PR 2.

## 8. Runbook: the letflow DB migration on QA (release `rpc` form, NO Mix on the container)

Who and when: infra, AFTER letflow PR 1 is deployed to QA (P2) and after R1; BEFORE R4. Same command form, same rules and same pass/fail convention as `docs/runbooks/login-directory-pepper-rotation.md` section 0 (read it first: the expression goes in a one-line `.exs` file fed through STDIN into `docker exec -i letflow-qa-app-1 sh -c 'timeout 300 bin/letflow rpc "$(cat)"'`; keep stderr separate; pass = a `SUMMARY` line is present; an `ERROR` line is a refusal; do not use the exit status). Output below is tenant ids, slugs, realm ids, reason tags and counts only; if an email, a token, a hash or a group id ever appears, stop and treat it as a defect. The modules named here exist only after PR 1 is deployed; the smoke check proves it.

`bin/letflow rpc` runs inside the live release node, so these expressions see the same platform-tenant pin as the serving process.

Step A, smoke check (must print `true` twice):

```
IO.puts(Code.ensure_loaded?(Letflow.Identity.TenantAdminMigration)); IO.puts(Code.ensure_loaded?(Letflow.Identity.RoleBackfill))
```

Step B, read-only state before (save the output; it is the "before" evidence):

```
case Letflow.Identity.TenantAdminMigration.verify() do {:ok, v} -> IO.puts("pin_configured=#{v.pin_configured}"); Enum.each(v.tenants, fn s -> IO.puts("tenant #{s.tenant_id} slug=#{s.slug} platform=#{s.platform_tenant?} pa_binding=#{s.platform_admin_binding?} ta_binding=#{s.tenant_admin_binding?} ta_members=#{s.tenant_admin_member_count} pa_group_members=#{s.platform_admin_group_member_count} tokens_pa=#{s.tokens_with_platform_admin}") end); IO.puts("SUMMARY tenants=#{length(v.tenants)}"); {:error, _e} -> IO.puts("ERROR verify") end
```

Step C (S3), the backfill: gives every tenant, the platform tenant included, the `TENANT_ADMIN` group and binding; deletes nothing. Note (F6): it resets the claim markers of the users of every tenant it seeds, so the next login of such a user re-reads the token claims; if the identity provider still claims a role for a user an administrator had demoted, that role is re-added. Check for deliberately demoted users first.

```
case Letflow.Identity.RoleBackfill.run() do {:ok, r} -> IO.puts("SUMMARY seeded=#{length(r.seeded)} unchanged=#{length(r.unchanged)} markers_reset=#{r.role_claims_markers_reset}"); {:error, {:backfill_failed, t, _reason}} -> IO.puts("ERROR backfill_failed tenant=#{t}"); {:error, _other} -> IO.puts("ERROR backfill") end
```

Step D (S4a), dry run (queries only; writes nothing). Read the FIRST line: it names the pinned tenant's slug, its realm id and its operator count; `would_refuse` must be `[]`. The pinned slug must be the slug of the `bpm-default` tenant. If not: STOP and report to ORCH.

```
case Letflow.Identity.TenantAdminMigration.run(dry_run: true) do {:ok, r} -> p = r.preconditions; IO.puts("pinned slug=#{p.pinned_slug} realm=#{p.pinned_idp_realm_id} operators=#{p.operator_count} would_refuse=#{inspect(r.would_refuse)}"); Enum.each(r.migrated, fn t -> IO.puts("tenant #{t.tenant_id} slug=#{t.slug} realm=#{t.idp_realm_id} members_copied=#{t.members_copied} tokens=#{t.tokens_rewritten} binding_removed=#{t.platform_admin_binding_removed}") end); Enum.each(r.failed, fn f -> IO.puts("tenant #{f.tenant_id}: FAILED reason=#{f.reason}") end); IO.puts("SUMMARY dry_run=#{r.dry_run} migrated=#{length(r.migrated)} unchanged=#{length(r.unchanged)} failed=#{length(r.failed)}"); {:error, _e} -> IO.puts("ERROR dry_run") end
```

Expected on QA from infra's probe (confirm, do not assume): migrated tenants are the realms swiftroute, vortex, meridian, bilimbaga; `failed=0`. A non-zero `failed` is a reason tag (`role_name_taken_by_routing_role`, `platform_admin_name_is_routing_role`, `tenant_schema_missing`, `unexpected_error`): STOP, report the tag and the tenant id to ORCH; do not run step E.

Step E (S4b), the real run. The two arguments are the explicit INPUT from step D: replace `bpm-default-slug` with the slug printed in step D, and `expected_realm_id` is the realm id of the platform operator's tenant as INFRA knows it (`bpm-default` on QA), which must equal the realm id printed in step D (M2: it is infra's own statement, not copied blindly). The run refuses without either argument, with a different slug or realm id, with a pin that is not a UUID, and when the pinned tenant has no `PLATFORM_ADMIN` member). It converts, per tenant in its own transaction: members of the `PLATFORM_ADMIN` binding into the `TENANT_ADMIN` group, the binding delete, and API tokens carrying `PLATFORM_ADMIN` (rewritten in place; each plaintext token keeps working), with audit entries.

```
case Letflow.Identity.TenantAdminMigration.run(platform_tenant_slug: "bpm-default-slug", expected_realm_id: "bpm-default") do {:ok, r} -> Enum.each(r.migrated, fn t -> IO.puts("tenant #{t.tenant_id} slug=#{t.slug} realm=#{t.idp_realm_id} members_copied=#{t.members_copied} tokens=#{t.tokens_rewritten} admins_after=#{t.tenant_admin_member_count_after}") end); Enum.each(r.failed, fn f -> IO.puts("tenant #{f.tenant_id}: FAILED reason=#{f.reason}") end); IO.puts("SUMMARY dry_run=#{r.dry_run} migrated=#{length(r.migrated)} unchanged=#{length(r.unchanged)} failed=#{length(r.failed)}"); {:error, {:precondition_failed, why}} -> IO.puts("ERROR precondition #{why}"); {:error, _other} -> IO.puts("ERROR run") end
```

Step F, run step E's expression a SECOND time: every tenant must be `unchanged` (`migrated=0 failed=0`).

Step G, verification (read-only; ids and counts only). Pass criteria: for every non-platform tenant `pa_binding=false`, `ta_binding=true`, `tokens_pa=0`, `ta_members` at least 1; for the platform tenant `pa_binding=true`, `ta_binding=true`. A non-platform tenant with `ta_members=0` is reported to ORCH (lockout risk, decision 0046 open risk 6).

```
case Letflow.Identity.TenantAdminMigration.verify() do {:ok, v} -> IO.puts("pin_configured=#{v.pin_configured}"); Enum.each(v.tenants, fn s -> IO.puts("tenant #{s.tenant_id} slug=#{s.slug} platform=#{s.platform_tenant?} pa_binding=#{s.platform_admin_binding?} ta_binding=#{s.tenant_admin_binding?} ta_members=#{s.tenant_admin_member_count} pa_group_members=#{s.platform_admin_group_member_count} tokens_pa=#{s.tokens_with_platform_admin}") end); IO.puts("SUMMARY tenants=#{length(v.tenants)}"); {:error, _e} -> IO.puts("ERROR verify") end
```

Record the outputs of steps B, D, E, F, G with UTC timestamps in the run notes (this is the dated evidence for gate G2 of the design, section 5.6). Then continue with R3/R4.

Rollback. There is NO automated reverse for roles; the migration is forward-only. What each recovery does: (1) Re-running step E is safe: it is idempotent and changes nothing once converged. (2) A realm role re-added to a user (R4 undone) restores the claim only; it does not restore the deleted `PLATFORM_ADMIN` binding, and the user keeps working as `TENANT_ADMIN`. (3) A manual restore of the legacy state is possible only by an operator with database access (the legacy group and its members are kept, inert; re-create the binding by hand) and only while letflow PR 2 is not deployed; after PR 2 the binding is rejected by design. (4) A tenant reported `failed` was rolled back as a whole and is unchanged. State this in the run notes so nobody expects a down-migration.
