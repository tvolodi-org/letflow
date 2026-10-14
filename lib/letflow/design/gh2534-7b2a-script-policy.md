# GH 2534 PR 7b-2a: script policy (kill switch) and interim readable masters (decision 0053 D5, D7 kill switch; advisor Q3)

Decision: `docs/migration/decisions/0053-tenant-scripted-rules.md` (ratified), D5 (principal and reads),
D7 "Kill switch" paragraph, D6 plus the "D6 amendment 2026-10-14" and "7b rulings" (docs PR #2559).
Split ruled by the supervisor: 7a runtime (merged) -> 7b-1 registry (PR #2560, not merged; this
branch is stacked on it) -> **7b-2a policy (this)** -> 7b-2b `scripts.sod`
(`gh2534-7b2b-script-sod.md`, after GH #2547) -> 7c handler. Rulings applied: advisor Q3 (interim
read rule), the 7b ruling "every script-registry write requires an OIDC credential" (extended here
to every policy write), the ISS-1032 / GH 2351 audit split (commit 9a8aa7ca) for platform-operator
writes, 0051 D11 (admin plane tenant-wide only) and D8 (audit shape).
Revision 2: SECURITY-REVIEWER F1-F4 and CODE-DESIGN-VALIDATOR 1-4 resolved, tagged [SEC Fn] /
[CDV n]; supervisor ruling on P2 recorded in its row.

7b-2a adds tenant policy STATE and its management routes, relaxes the 7b-1 manifest rule
`reads_not_allowed` for flagged types, and publishes the read contract 7c calls. It adds NO
execution path for published scripts (7c) and performs NO entity read (7c pre-fetches).

## 0. Verified facts (this branch, 7b-1 head b3758de2)

* 7b-1 context `Letflow.Scripts` (`lib/letflow/scripts.ex`): actor map `%{user_id, credential}`
  (:28); `require_interactive/1` refuses anything but `credential: :oidc` (:471-472);
  `publish/6` pre-checks then runs test cases with no connection held, then one transaction with
  `lock_key!/2` + `lock_row!/3` (:209-253); `run_case/4` passes `test_case["input"]` unchanged
  (:327-355); `dry_run/5` (:428-450); audit via `Audit.insert_entry/3` inside the transaction,
  `trace_id: nil` (:571-599).
* `Letflow.Scripts.Validation.manifest/1` (`scripts/validation.ex:39-55`) refuses a non-empty
  `reads` with `:reads_not_allowed` before any other part check; `valid_case?/2` accepts exactly 3
  keys (`map_size(case) == 3`, :181-182); `reason/1` (:215-224); `key?/1` regex
  `^[a-z][a-z0-9_]{0,63}$` (:22, :228).
* Router `Letflow.Routers.ScriptRules` mounted `forward("/script-rules", ...)`
  (`plugs/api_pipeline.ex:161`); `actor/1` reads `auth_context.credential` (:279-282).
* `auth_context.credential :: :oidc | :api_token` set by `attach_auth_context/5`
  (`plugs/auth_pipeline.ex:403-425`).
* Authorization: `TENANT_ADMIN` holds every `:tenant`-scope permission
  (`authorization.ex:1416-1417`); `PLATFORM_ADMIN` holds all, honoured only in the platform tenant
  (`has_permission_in_scope?/3`, :1348-1362); `@platform_permissions [:TenantsManage,
  :PlatformServicesManage]` (:465). Precedent for a distinct route key mapped to an existing
  permission: `:ScriptRulesList`/`:ScriptRulesRead` -> `:ScriptsWrite` (:1309) and 0051 D11's
  `:GroupsManage` -> `:UsersGroupsRolesManage`.
* `role_scope_grants` / any `tenant_wide` grant notion: NOT FOUND in `lib/` (0051 stage 1 is GH
  #2533, unmerged). Today every TENANT_ADMIN is tenant-wide.
* Platform-operator precedent (9a8aa7ca): `Identity.patch_tenant/3` writes, in ONE transaction,
  the change, a TARGET-tenant chain entry with `actor_id: nil`, `trace_id: nil`, `after_state`
  carrying `"actor_class" => "platform_operator"`, then a PLATFORM-chain entry carrying the
  operator id; lock order tenant row, tenant chain, platform chain (`identity.ex:1145-1225`).
  `Routers.Tenants.verified_platform_prefix/1` (`routers/tenants.ex:390-399`) returns the platform
  prefix only when it equals the caller's DB-resolved schema, else nil (fail closed, 500, nothing
  written). Every `:slug` handler calls `TenantTarget.authorize_target_tenant/2` first
  (`api/tenant_target.ex:30`). `authz_unmatched(:platform_prefix)` closes the mount (:228).
* Entity types: `entity_definitions` (tenant schema), name regex `^[a-z][a-z0-9_]{0,63}$`
  (`entities/definition/validator.ex:48`); the authoritative active version is
  `Definitions.get_active_definition_by_name(name, prefix) :: {:ok, EntityDefinition.t()} |
  {:error, :not_found | :invalid_schema_name}` (`entities/definitions.ex:254-277`); field list is
  `definition_json["fields"][*]["name"]` (jsonb, string keys; `definition.ex:42` types it
  `required(:fields) => [field_def()]`). Per-type read restriction: `entity_type_restrictions`
  table (`entities/type_access.ex`, REQ-394; a type with a row is hidden from every user without a
  `user_entity_type_grants` row; the script principal has no user, so it would be denied).
* Tenant migrations: latest `20261014000001_create_script_rules.exs`; manifest entry
  `tenant_provisioning.ex:651`.
* `Letflow.Identity.Tenant` (public `tenants`): `slug, display_name, status, idp_realm_id,
  settings, storage_allowance_bytes, login_disclosure_mode` (`identity/tenant.ex:76-94`). No tier
  or enterprise notion exists (grep `enterprise|tier` over `lib/`: no tenant-related hit).

## 1. Decisions taken in this design (each with its reason)

| # | Decision | Reason |
|---|---|---|
| P1 | The kill switch is TWO latches in one row: `tenant_kill_switch` (set by a tenant-wide TENANT_ADMIN) and `platform_kill_switch` (set by the platform operator). Effective state = either latch on. Each actor can flip only its own latch. | 0053 D7 lets both actors set "the" switch. A single shared bit would let a tenant admin undo an operator's incident stop (the compromised-tenant case the operator stop exists for), and would let the operator clear a tenant's own stop. Two latches keep both powers and make neither undoable by the other. |
| P2 | While the effective switch is on, 7b-2a REFUSES dry-run and publish (409 `scripts_disabled`); publish re-checks before EVERY stored test case and once inside the publish transaction. Draft create/save/discard, retire and revoke stay allowed. | Dry-run and publish's stored tests execute tenant Lua in the same sandbox as a production run; dry-run takes arbitrary caller input and returns author detail, so it is the easiest way to reach a sandbox defect. A kill switch that stopped only production runs would leave the most attacker-friendly execution path open. Retire and revoke REDUCE exposure (revoke is the expected incident action) and drafts execute nothing. **Ruled by the supervisor 2026-10-14 (ACCEPTED):** while on, refuse dry-run, publish and every runtime invocation (7c: fail closed, `script_rejected` incident) with the stable code `scripts_disabled`; ALLOW draft create/save/discard, reads and list, retire and revoke (they only reduce risk and are never blocked by the switch). Turning a latch OFF takes the same gate as turning it ON (its owner: tenant-wide TENANT_ADMIN for the tenant latch, the operator for the platform latch; OIDC, mandatory reason, audited). |
| P3 | Route permissions reuse existing permissions through DISTINCT policy keys: `:ScriptPolicyRead` -> `:ScriptsWrite`, `:ScriptPolicyManage` -> `:ScriptsPublish`; platform routes use `:TenantsManage`. No new permission, no `docs/roles.md` row. | Holders are exactly right already: `:ScriptsPublish` = TENANT_ADMIN (+ PLATFORM_ADMIN in the platform tenant only); designers (`:ScriptsWrite`) must read the masters list to author `reads` and read the switch to understand a refused dry-run. 0051 D11 classifies the admin plane BY ROUTE KEY (the `:GroupsManage` precedent), so a distinct key is what 0051 stage 1's route-walk needs; a new permission would add a matrix row with identical holders. |
| P4 | Every policy WRITE (tenant and platform routes) requires `credential == :oidc`, else 403 `api_token_not_allowed`, checked first. Reads allowed for token callers. | The 7b ruling's reason (a tenant admin can mint a token for any user, tokens record no issuer, GH #2552) applies unchanged: a minted token would otherwise let an admin stop or widen scripts under another user's id. |
| P5 | Clearing a readable-master flag is NEVER blocked by referencing scripts. It takes effect immediately; 7c fails a run closed (`script_rejected`) when any declared read's type is not flagged at run time; the clear response and its audit entry list the referencing published/retired versions. Publish re-checks the flags under `FOR SHARE`, so a clear and a publish serialise. | Clearing narrows what scripts may read: a security action that existing scripts must not be able to veto (blocking would force revoking, which is irreversible and fails pinned instances anyway). A run-time re-check is required regardless (a clear can always race a run), so fail-closed at 7c is the authoritative mechanism; listing the references makes the clear not silent. |
| P6 | A type may be flagged only if it has an ACTIVE definition and NO `entity_type_restrictions` row (422 otherwise). 7c re-checks both at run time (fail closed). | A type-restricted type is by definition not tenant-wide readable, and the script principal (no user) would be denied by `TypeAccess` anyway: flagging it would publish a script whose read always misses. |
| P7 | The singleton `script_policy` row is created by the migration itself (`INSERT ... id = 1`, so existing tenants get it through the boot replay and new tenants through provisioning). `kill_switch_on?/1` returns `true` when the row is absent (fail closed). | No lazy creation on a run path (same class as the 0053 D9 secret rule); a missing row is a provisioning defect and must stop scripts, not run them. |
| P8 | 7b-2b's `scripts.sod` columns are NOT pre-created; 7b-2b adds them to `script_policy` with its own migration. | 7b-2b depends on GH #2547's unmerged helper and may change shape; unused columns would be dead schema with no writer and no trigger rule. The singleton row-per-tenant layout is the room left for it. |
| P9 | A no-op flip (requested state equals stored state) returns 200 with the current state, writes nothing and audits nothing. | Every state change is audited; a no-op is not a change. The reason is still validated (422 first) so the contract is uniform. |
| P10 | The operator's kill-switch REASON is stored in the tenant row and shown to the tenant; the operator's identity is not (platform chain only). The platform GET AND the platform PUT return the same allowlisted `platform_policy_map/1`: the tenant latch's on/off and time only, never the tenant's reason or user id [SEC F2]. | The tenant needs to know why its scripts stopped; 9a8aa7ca forbids the operator id in tenant-readable places; 0046 D4 keeps tenant content (the tenant admin's free text) from PLATFORM_ADMIN. |
| P11 | [CDV 3] RESIDUAL, not refused: a PLATFORM_ADMIN authenticated in the PLATFORM tenant passes `:ScriptPolicyManage` (`:ScriptsPublish`) for the platform tenant's OWN policy, exactly as it passes 7b-1's publish/retire/revoke there. No extra role check is added in either PR. | INV-10 already confines it to the platform tenant (`has_permission_in_scope?/3`), where it holds every permission including `:UsersGroupsRolesManage`, so it can make itself TENANT_ADMIN at will: a TENANT_ADMIN-only check would add no protection and would leave a platform tenant without a TENANT_ADMIN unable to manage its own masters. In another tenant it holds nothing on these routes (its only lever there is the platform latch). The same statement applies to 7b-1's `:ScriptsPublish` routes. 7b-2b's solo publish, solo switch and confirm exclude it anyway (it is never in `tenant_wide_admin_user_ids/1`). |
| P12 | [SEC F1] A `match.field` that is restricted (an `entity_field_restrictions` row exists for `(entity_type, field)`) MUST also be listed in that read's `restricted_fields`; checked against the CURRENT restrictions at save, at publish and at every 7c run. A restricted field listed only in `fields` (not in `restricted_fields`) is allowed and is REDACTED by 7c. | Filtering on a restricted field turns the match into an oracle on that field's value even when the field itself is never returned. Requiring the opt-in routes it through the publisher's `:EntitiesRestrictionsManage` check (D5); the run-time re-check catches a restriction added after publish. |
| P13 | [CDV 4] `fields`, `restricted_fields` and `match.field` must not contain `"id"` (422 `invalid_manifest`). Every delivered row carries the record id under `"id"`; a definition field literally named `id` (if a definition declares one) cannot be read by a script. Matching by record id uses `match.id_from`. | Avoids a key collision in the delivered row and keeps one meaning for `id`. |

## 2. Tables (tenant migration `20261014000002_create_script_policy.exs`)

One migration, `if prefix()` guard, registered in `@tenant_scoped_migration_manifest` after
`20261014000001`. No SQL interpolates anything but `prefix()` (INV-7).

### 2.1 `script_policy` (exactly one row per tenant schema)

| Column | Type | Notes |
|---|---|---|
| `id` | smallint PK | CHECK `id = 1` (singleton) |
| `tenant_kill_switch` | boolean NOT NULL default false | |
| `tenant_kill_switch_set_by` | uuid null | user id of the tenant admin; NULL until first set |
| `tenant_kill_switch_set_at` | utc_datetime_usec null | |
| `tenant_kill_switch_reason` | text null | CHECK `char_length <= 500` |
| `platform_kill_switch` | boolean NOT NULL default false | |
| `platform_kill_switch_set_at` | utc_datetime_usec null | NO operator id column (P10) |
| `platform_kill_switch_reason` | text null | CHECK `char_length <= 500` |
| `inserted_at`, `updated_at` | utc_datetime_usec | |

* The migration inserts the row `id = 1` with defaults (`ON CONFLICT (id) DO NOTHING`, so a replay
  is idempotent) (P7).
* Trigger `script_policy_guard()` (`BEFORE DELETE OR UPDATE`, ERRCODE `LF001`): DELETE always
  refused; UPDATE refused if `id` or `inserted_at` changes. The function names no other column, so
  7b-2b's added columns need no change to it (7b-2b does NOT replace it).
* Ecto schema `Letflow.Scripts.ScriptPolicy` (`@primary_key {:id, :integer, autogenerate: false}`),
  fields as above. [SEC F4] Two changesets, each casting ONLY its writer's own columns:
  `tenant_latch_changeset/2` casts `tenant_kill_switch`, `tenant_kill_switch_set_by`,
  `tenant_kill_switch_set_at`, `tenant_kill_switch_reason`; `platform_latch_changeset/2` casts the
  three `platform_kill_switch*` columns. No other changeset exists in 7b-2a; the context builds the
  attrs itself (never from the request body).

### 2.2 `script_readable_masters` (advisor Q3 interim flag; replaced by 0051 stage 2 `tenant_wide`)

| Column | Type | Notes |
|---|---|---|
| `entity_type` | text PK | CHECK `entity_type ~ '^[a-z][a-z0-9_]{0,63}$'` |
| `set_by` | uuid NOT NULL | tenant admin user id |
| `set_at` | utc_datetime_usec NOT NULL | |
| `reason` | text NOT NULL | CHECK `char_length <= 500` |
| `inserted_at` | utc_datetime_usec | |

* A row means "flagged". Clearing DELETEs the row (history lives in the audit chain). At most 200
  rows per tenant (application check, 422 `too_many_masters`), so the list route needs no
  pagination.
* No FK to `entity_definitions` (definitions are versioned by name; same convention as
  `entity_type_restrictions`).
* Ecto schema `Letflow.Scripts.ReadableMaster` (`@primary_key {:entity_type, :string,
  autogenerate: false}`).

## 3. Manifest `reads` (relaxes 7b-1 section 3 `reads_not_allowed`)

### 3.1 Shape (validated by `Validation.manifest/1`, pure, no DB)

```
"reads": [                                   // optional; 0..8 entries
  { "name":        "<^[a-z][a-z0-9_]{0,63}$>",          // unique within reads
    "entity_type": "<^[a-z][a-z0-9_]{0,63}$>",
    "match":       {"id_from": "<input prop>"}                         // by id, at most 1 row
                 | {"field": "<definition field>", "value_from": "<input prop>"},  // equality
    "fields":      ["<definition field>", ...],         // 1..64, unique; the projection (D5 field-minimal)
    "restricted_fields": ["<field>", ...],              // optional, subset of fields (D5 opt-in)
    "limit":       1..50                                // REQUIRED with "field" match; absent or 1 with "id_from"
  } ]
```

* Any other key in an entry or in `match` -> 422 `invalid_manifest`. Every field name and input
  prop name matches `^[a-z][a-z0-9_]{0,63}$`. `"id"` is refused in `fields`, `restricted_fields`
  and `match.field` (P13).
* `id_from` / `value_from` must be a key of `input_schema.properties`; for `id_from` that
  property's `type` must be `"string"`; for `value_from` one of `string, integer, number, boolean`.
* Sum of row caps (`limit`, or 1 for an id match) over all entries <= 200 (D5 "row-capped").
* When `reads` is non-empty, `input_schema.properties` must NOT contain the key `"reads"`
  (reserved: section 4 and 7c deliver read results under `input["reads"][name]`, always a list of
  row objects with keys `id` plus `fields`).
* The 7b-1 `restricted_inputs` publisher check (`:EntitiesRestrictionsManage` at publish) extends
  to: any entry with a non-empty `restricted_fields`.
* `reads_not_allowed` stays as the code for a DB-level refusal (3.2); shape errors are
  `invalid_manifest`.

### 3.2 Tenant checks (`Letflow.Scripts.Policy.check_reads/2`, needs the DB)

`check_reads(prefix, manifest) :: :ok | {:error, :reads_not_allowed}`: for every entry, the
`entity_type` has a `script_readable_masters` row, an ACTIVE definition
(`get_active_definition_by_name/2`), no `entity_type_restrictions` row, every `fields` /
`restricted_fields` / `match.field` name is a field of that active definition, and (P12, SEC F1)
if `match.field` currently has an `entity_field_restrictions` row (`entity_type`, `field_name`;
one query per entry, bound parameters, same table `FieldGrants.load_restrictions/3` reads, but
WITHOUT the per-user grant anti-join: the script principal has no user and no grants) it is in
`restricted_fields`. Any failure ->
`:reads_not_allowed` (one code; the tenant's own admin can list masters and definitions, so no
per-cause detail is needed and none is echoed). An empty `reads` -> `:ok` without a query.

Called at:
1. **Save**: `create_draft/4` and `save_draft/5`, after `content/1`, before the transaction (a
   concurrent clear is caught by 2 and 3).
2. **Publish**: in the pre-checks (before test cases) AND inside the publish transaction after the
   row lock, reading the master rows with `FOR SHARE` (`check_reads/3` with `lock: :share`), so a
   concurrent clear's DELETE waits for the publish to commit and its reference listing (section
   6.3) then includes the new version (P5).
3. **Run time (7c)**: the contract in section 8.

## 4. Stored test cases and dry-run with reads (D10 "no reads except fixtures")

* A test case may carry a 4th key `"reads": {"<read name>": [row, ...]}` (`valid_case?/2` accepts 3
  or 4 keys). Each key must be a declared read name; each row is an object whose keys are a subset
  of `["id"] ++ fields` of that read; at most that read's row cap rows; fixture canonical size <=
  16 KiB per case; a declared read absent from the fixture is `[]`. The 256 KiB `test_cases` cap
  still bounds the whole. Fixtures are part of `test_cases`, hence of `sha256` (7b-1 section 2).
  `reads` in a case when the manifest declares none -> 422 `invalid_test_case`.
* `run_case/4` passes `Map.put(input, "reads", normalised_fixtures)` when the manifest declares
  reads (otherwise `input` unchanged, as in 7b-1).
* Dry-run body becomes `{version, input, reads?}` with the same fixture rules (422 `invalid_input`
  on violation); it STILL performs no read (7b-1 section 7 unchanged). Dry-run does not call
  `check_reads/2` (it reads nothing, so a cleared flag cannot leak anything through it).

## 5. Kill switch: effect on 7b-1 paths (P2)

`Letflow.Scripts.Policy.kill_switch_on?(prefix) :: boolean()`: one query of row `id = 1`;
`tenant_kill_switch or platform_kill_switch`; `true` when the row is absent (P7); a DB error
raises (never read as "off").

| Path | Change |
|---|---|
| `dry_run/5` | after `get/3` (so unknown versions keep the plain 404), `kill_switch_on?` -> `{:error, :scripts_disabled}` before input validation and before any run. The refusal is not audited as a dry-run (no run happened). |
| `publish/6` pre-checks | after the credential check and `fetch/3`, before SoD and before the tests: `kill_switch_on?` -> `{:error, :scripts_disabled}`. |
| `run_test_cases/2` -> `run_test_cases/3` | before EACH case: `kill_switch_on?` -> halt `{:error, :scripts_disabled}` (no further case runs). [CDV 2] Test seam: `run_test_cases(prefix, rule, opts)` calls `opts[:before_case]` (a 1-arity function given the 1-based case index) immediately BEFORE that case's kill-switch check. `publish/6` stays the public entry and passes `[]`; `publish/7` (`opts`) exists, and `:before_case` is honoured only when `Application.get_env(:letflow, :scripts_test_hooks, false) == true`, set only in `config/test.exs` (no route, no runtime config in `config/runtime.exs` or prod config reaches it). |
| publish transaction | after `lock_row!/3`: `kill_switch_on?` -> `Repo.rollback(:scripts_disabled)`. Plain read, no lock (a flip committing after this read only means a version got published; it still cannot run, 7c checks at run time). |
| create / save / discard / retire / revoke | unchanged (P2). |

Router: `{:error, :scripts_disabled}` -> 409 `{"error": "scripts_disabled", "detail":
"scripts_disabled"}` (added to `reply/3` beside `version_immutable`/`content_changed`).

Stated residual: a run already executing when the switch flips finishes within its own wall
clock (<= 5 s per run, 7a; a publish stops before its next case). The switch stops NEW executions.

## 6. Context `Letflow.Scripts.Policy` (`lib/letflow/scripts/policy.ex`)

Actor maps (built only from the DB-resolved auth context):
`tenant_actor :: %{user_id: Ecto.UUID.t(), credential: :oidc | :api_token | nil, trace_id: String.t() | nil}`;
`operator :: %{user_id: Ecto.UUID.t(), credential: ..., trace_id: String.t() | nil, platform_prefix: String.t() | nil}`.

Errors (stable atoms, nothing echoes input): `:not_found | :api_token_not_allowed |
:invalid_reason | :invalid_state | :unknown_entity_type | :entity_type_restricted |
:too_many_masters | :reads_not_allowed | :scripts_disabled | :policy_missing | :audit_failed`.

### 6.1 Reads

* `get(prefix) :: {:ok, ScriptPolicy.t()}` (row absent -> `{:error, :not_found}`, router 500:
  provisioning defect, never fabricated).
* `kill_switch_on?(prefix) :: boolean()` (section 5).
* `list_readable_masters(prefix) :: [ReadableMaster.t()]` ordered by `entity_type`.
* `readable_master?(prefix, entity_type) :: boolean()`.
* `check_reads(prefix, manifest) :: :ok | {:error, :reads_not_allowed}` and
  `check_reads(prefix, manifest, lock: :share)` (section 3.2).
* `references(prefix, entity_type) :: {[%{key, version, status}], non_neg_integer()}`: versions with
  status `published` or `retired` whose `manifest -> 'reads'` contains an element with that
  `entity_type` (jsonb containment `@>` with a BOUND parameter, INV-7); list capped at 100 by
  `(key, version)`, plus the total count.

### 6.2 Kill switch writes

* `set_tenant_kill_switch(prefix, on :: boolean(), reason, tenant_actor) :: {:ok, ScriptPolicy.t()} | {:error, error}`
  Order: `credential == :oidc` (else `:api_token_not_allowed`); `on` boolean (else
  `:invalid_state`); `Validation.reason/1`. One transaction: `SELECT ... FOR UPDATE` row 1 (absent
  -> rollback `:policy_missing`, see the missing-row rule in 9.1); equal state -> return row, no write (P9); else update
  `tenant_kill_switch`, `_set_by = user_id`, `_set_at = now`, `_reason`; audit (section 7).
* `set_platform_kill_switch(prefix, tenant_id, on, reason, operator) :: same`
  Same order plus `operator.platform_prefix` binary (else `:audit_failed`, nothing written: the
  9a8aa7ca fail-closed rule). Transaction: row 1 `FOR UPDATE`; no-op rule; update the three
  `platform_*` columns; tenant-chain entry then platform-chain entry (lock order: policy row, tenant
  chain, platform chain, as 9a8aa7ca).

### 6.3 Readable-master writes

* `set_readable_master(prefix, entity_type, reason, tenant_actor) :: {:ok, :created | :unchanged, ReadableMaster.t()} | {:error, error}`
  Order: credential; `entity_type` regex (else `:unknown_entity_type`); reason. Then: active
  definition exists (else `:unknown_entity_type`); no `entity_type_restrictions` row (else
  `:entity_type_restricted`, P6). One transaction with `pg_advisory_xact_lock(hashtext($1))`,
  `$1 = prefix <> ":script_readable_masters"` (BOUND): row exists -> `:unchanged`, no write; count
  >= 200 -> `:too_many_masters`; insert; audit.
  [SEC F3] Stated residual: the definition and type-restriction checks run BEFORE the transaction,
  without a lock, so a concurrent deactivation of the definition or a concurrent
  `entity_type_restrictions` insert can let a flag be set on a type that is, at commit, inactive
  or type-restricted. No read can follow from it: `check_reads/2` re-checks both at save, at
  publish (in the transaction) and at every 7c run, so such a flag only makes those checks refuse.
* `clear_readable_master(prefix, entity_type, reason, tenant_actor) :: {:ok, %{entity_type, referenced_by, referenced_total}} | {:error, error}`
  Order: credential; regex (else `:not_found`); reason. One transaction: `DELETE ... WHERE
  entity_type = $1 RETURNING *` (no row -> rollback `:not_found`); then `references/2` (sees any
  publish that held `FOR SHARE` on the row, P5); audit with the reference list; return it.

## 7. Audit (0053 D9; 0051 D8 shape: actor, before/after, UTC time, trace id, same transaction)

`Audit.insert_entry/3` inside the transaction of the change (as 7b-1); a failure rolls back
(`{:audit_failed, _}` -> 500). `trace_id` = `tenant_actor.trace_id` (the request's
`conn.assigns[:trace_id]`) on entries by a tenant actor; `nil` on tenant-chain entries by the
operator (9a8aa7ca). Values never include source, inputs or fixtures.

| Action | Chain | actor_id | resource | before_state / after_state |
|---|---|---|---|---|
| `script_policy.kill_switch_set` | tenant | tenant user | `script_policy` / `"1"` | `{"tenant_kill_switch": bool}` / `{"tenant_kill_switch": bool, "reason": text, "effective": bool}` |
| `script_policy.platform_kill_switch_set` | tenant | nil | `script_policy` / `"1"` | `{"platform_kill_switch": bool}` / `{"platform_kill_switch": bool, "reason": text, "effective": bool, "actor_class": "platform_operator"}` |
| `platform.tenant_script_kill_switch.set` | platform | operator | `tenant` / tenant id | nil / `{"tenant_id", "platform_kill_switch": bool, "reason": text}` |
| `script_policy.readable_master_set` | tenant | tenant user | `script_readable_master` / entity type | nil / `{"entity_type", "reason"}` |
| `script_policy.readable_master_cleared` | tenant | tenant user | `script_readable_master` / entity type | `{"entity_type", "set_by", "set_at"}` / `{"entity_type", "reason", "referenced_by": [...], "referenced_total": n}` |

## 8. Read contract for 7c (normative for the 7c design)

7c calls, per run, in the dispatcher BEFORE acquiring the `ScriptAdmission` slot and before any
pre-fetch. Both refusals are outcome class `script_rejected` (instance ERROR + DLQ incident, not
retried; D7) and carry a stable DETAIL code [CDV 1]:
1. `Letflow.Scripts.Policy.kill_switch_on?(prefix)` -> `true`: fail closed, detail code
   **`scripts_disabled`** (supervisor ruling on P2). No script executes.
2. `Letflow.Scripts.Policy.check_reads(prefix, pinned_version.manifest)` -> `{:error,
   :reads_not_allowed}`: fail closed, detail code **`reads_not_allowed`** (a type unflagged,
   inactive or type-restricted; a declared field gone since publish; or a `match.field` that is
   restricted NOW and not in `restricted_fields`, P12). This is a type/field-level decision
   independent of any record id, so it is not a per-record existence oracle (INV-5); per-record
   misses and out-of-scope rows follow D5 (same value as a miss).
3. **Redaction, normative [SEC F1]:** every field in a read's `fields` that has an
   `entity_field_restrictions` row at run time and is NOT in that read's `restricted_fields` is
   REDACTED in the delivered row (the D5 filter for the script principal, which holds no grants).
   A field in `restricted_fields` enters unredacted only while the publisher's
   `:EntitiesRestrictionsManage` re-check of D5 passes (7c's), for `restricted_inputs` likewise.
   **[SEC N1]** That re-check also gates the FILTER: when it fails and a read's `match.field` is
   restricted at run time, the run fails closed (`script_rejected`, detail `reads_not_allowed`)
   before any query runs, so the equality filter can never act as an existence oracle after the
   publisher loses the permission.
7c must not cache any of these across runs.

## 9. Routes

### 9.1 Tenant: `Letflow.Routers.ScriptPolicy`, mounted `forward("/script-policy", ...)` in `api_pipeline.ex`

| Route | Policy key -> permission | Body | Effect |
|---|---|---|---|
| `GET /` | `:ScriptPolicyRead` -> `:ScriptsWrite` | | `policy_map/1` |
| `PUT /kill-switch` | `:ScriptPolicyManage` -> `:ScriptsPublish` | `{on: bool, reason}` | 6.2 tenant latch; 200 `policy_map` |
| `GET /readable-masters` | `:ScriptPolicyRead` -> `:ScriptsWrite` | | `{items: [master_map]}` |
| `PUT /readable-masters/:entity_type` | `:ScriptPolicyManage` -> `:ScriptsPublish` | `{reason}` | 201 (created) or 200 (unchanged), `master_map` |
| `POST /readable-masters/:entity_type/clear` | `:ScriptPolicyManage` -> `:ScriptsPublish` | `{reason}` | 200 `{entity_type, referenced_by: [{key, version, status}], referenced_total}` |

* `policy_map/1` (allowlist, INV-2): `{"kill_switch_on": effective, "tenant": {"on", "set_by",
  "set_at", "reason"}, "platform": {"on", "set_at", "reason"}}` (P10).
* `master_map/1`: `{"entity_type", "set_by", "set_at", "reason"}`.
* Status mapping: `:api_token_not_allowed` 403; `:invalid_reason`, `:invalid_state`,
  `:unknown_entity_type`, `:entity_type_restricted`, `:too_many_masters` 422 with the code;
  `:not_found` plain 404; `:audit_failed` 500. Bodies never echo values.
* Missing-row rule (REVIEWER F1, 2026-10-14): a missing `script_policy` row is a provisioning
  defect (P7), never an unknown resource: it answers **500** on every route that needs the row,
  the GET (`get/1` `:not_found`) AND the latch writes (`lock_policy!` rolls back
  `:policy_missing`), on the tenant route and the platform route alike, with nothing written or
  audited. Never a 404 (which would read as "no such tenant"), never a fabricated row.

### 9.2 Platform: added to `Letflow.Routers.Tenants` (mount `/tenants`)

| Route | Policy key | Body | Effect |
|---|---|---|---|
| `GET /:slug/script-policy` | `:TenantsManage` | | `platform_policy_map/1` (P10) |
| `PUT /:slug/script-policy/kill-switch` | `:TenantsManage` | `{on: bool, reason}` | 6.2 platform latch; 200 `platform_policy_map/1` (the SAME map as the GET, SEC F2) |

`platform_policy_map/1` (allowlist; exact key set): `{"kill_switch_on", "platform": {"on",
"set_at", "reason"}, "tenant": {"on", "set_at"}}`. Never `tenant_kill_switch_reason` or
`tenant_kill_switch_set_by`.

Handler order (both): `TenantTarget.authorize_target_tenant/2` -> `Identity.get_tenant_by_slug/1`
-> the tenant's `TenantProvisioning.Registration` row (its `schema_name`), looked up as
`Identity.patch_tenant/3` does (any failure: the existing plain 404). Implementation note
(2026-10-14): NOT `schema_name_for_tenant/1`, which is pure (derives a name from the id) and so
would "succeed" for a tenant row with no provisioned schema; the Registration lookup makes an
unprovisioned tenant the same plain 404 as an unknown slug instead of a query against a missing
schema. A provisioned tenant whose policy row is missing is 500 (missing-row rule, 9.1);
PUT then builds `operator` with `platform_prefix: verified_platform_prefix(conn)` (existing private
function) and calls `set_platform_kill_switch/5`. Unchanged `authz_unmatched(:platform_prefix)`.

### 9.3 Authorization touch points (`lib/letflow/api/authorization.ex`)

* `@type endpoint_policy_key` add `:ScriptPolicyRead`, `:ScriptPolicyManage` (NOT added to
  `@permissions` or `@type permission`: they are route keys, P3).
* `endpoint_policy_key/2`: `("GET", "/script-policy")`, `("GET", "/script-policy/readable-masters")`
  -> `:ScriptPolicyRead`; `("PUT", "/script-policy/kill-switch")`,
  `("PUT", "/script-policy/readable-masters/:entity_type")`,
  `("POST", "/script-policy/readable-masters/:entity_type/clear")` -> `:ScriptPolicyManage`;
  `("GET", "/tenants/:slug/script-policy")`, `("PUT", "/tenants/:slug/script-policy/kill-switch")`
  -> `:TenantsManage`.
* `required_permission/1`: `:ScriptPolicyRead -> :ScriptsWrite`; `:ScriptPolicyManage ->
  :ScriptsPublish`.
* No role clause changes; `docs/roles.md` unchanged.
* **0051 obligation (GH #2533):** the five `/script-policy` routes are classified in the D5/D11
  route walk: the two `:ScriptPolicyManage` writes as **admin-plane** (a scoped TENANT_ADMIN is
  refused), the reads as `:tenant_wide`. Until 0051 stage 1 lands every TENANT_ADMIN is tenant-wide
  (section 0), so no runtime check is added here; the route keys are the extension point.

## 10. Changes to 7b-1 files

* `scripts/validation.ex`: `manifest/1` validates `reads` shape (3.1) instead of refusing non-empty;
  `test_cases/2` accepts the optional `reads` fixture (4); `dry_run_input/2` becomes
  `dry_run_input(input, reads_fixture, manifest)`.
* `scripts.ex`: `create_draft/4`, `save_draft/5` call `Policy.check_reads/2` (3.2); `publish/6` adds
  the kill-switch checks (5), `check_reads/2` in the pre-checks and `check_reads/3` (`lock: :share`)
  in the transaction, and the restricted-fields extension of the publisher check (3.1);
  `run_case/4` merges fixtures (4); `dry_run/5` -> `dry_run/6` (`reads` fixture) with the kill-switch
  check (5); `@type error` adds `:scripts_disabled`; `actor` gains optional `trace_id` (7b-1 entries
  keep `trace_id: nil`; changing 7b-1's audit is out of scope).
* `routers/script_rules.ex`: dry-run passes `conn.body_params["reads"]`; `reply/3` maps
  `:scripts_disabled` -> 409.

## 11. Acceptance criteria

* AC1 Migration creates both tables and the singleton row in every tenant schema (fresh
  provisioning and boot replay); replay is idempotent; DELETE of the policy row and a second row
  are refused at the DB.
* AC2 `PUT /script-policy/kill-switch` by an OIDC TENANT_ADMIN flips the tenant latch, stores
  set_by/set_at/reason, writes `script_policy.kill_switch_set` in the same transaction; reason
  missing/blank/over 500/control chars -> 422 `invalid_reason`; non-boolean `on` -> 422
  `invalid_state`; no-op -> 200, no audit.
* AC3 `PUT /tenants/:slug/script-policy/kill-switch` by a platform-tenant PLATFORM_ADMIN (OIDC)
  flips the platform latch; tenant-chain entry has nil actor and `actor_class` platform_operator; a
  platform-chain entry carries the operator id; both in one transaction; unverifiable platform
  prefix -> 500, nothing written. A PLATFORM_ADMIN of a non-platform tenant -> 403; unknown slug ->
  404. [SEC F2] The PUT and the GET responses both have EXACTLY the `platform_policy_map/1` key set
  (top level `kill_switch_on, platform, tenant`; `platform`: `on, set_at, reason`; `tenant`: `on,
  set_at`), with a tenant reason and set_by stored.
* AC4 Neither actor can change the other's latch; effective = OR; a tenant admin cannot clear an
  operator stop. [SEC F4] Context-level: a tenant-latch write whose attrs (built by a test calling
  `tenant_latch_changeset/2` directly) include `platform_kill_switch*` keys leaves those columns
  unchanged, and a `platform_latch_changeset/2` with `tenant_kill_switch*` keys leaves the tenant
  columns unchanged.
* AC5 While effective on: dry-run -> 409 `scripts_disabled` (no run, no dry-run audit); publish ->
  409 before any test case; a switch turned on between two test cases (via the `:before_case`
  seam, section 5) stops the publish before the next case (case 2 never runs); draft
  create/save/discard, retire and revoke succeed.
* AC6 Every policy write via an API token (tenant and platform routes) -> 403
  `api_token_not_allowed`, nothing written; reads via token allowed.
* AC7 Readable masters: set for an active, unrestricted type -> 201 and audit; again -> 200, no
  audit; unknown/inactive type -> 422 `unknown_entity_type`; type with an `entity_type_restrictions`
  row -> 422 `entity_type_restricted`; 201st -> 422 `too_many_masters`; clear unknown -> 404; clear
  returns and audits the referencing published/retired versions.
* AC8 Manifest `reads`: shape rules of 3.1 enforced (each violation 422 `invalid_manifest`); a read
  of an unflagged/inactive/restricted type or an unknown field -> 422 `reads_not_allowed` at save
  AND at publish (flag cleared between save and publish refuses the publish); `"reads"` key in
  `input_schema.properties` with non-empty reads refused.
* AC9 A publish holding `FOR SHARE` on a master row blocks a concurrent clear until commit; the
  clear's `referenced_by` then lists the published version.
* AC10 Test-case and dry-run `reads` fixtures validated (unknown read name, extra row key, too many
  rows, oversize -> 422); a script reading `input.reads.<name>` passes its stored tests with
  fixtures; dry-run performs no entity query (query-count assertion).
* AC11 `restricted_fields` non-empty requires `:EntitiesRestrictionsManage` at publish (403
  `restricted_inputs_not_allowed`).
* AC11a [SEC F1] A `match.field` with an `entity_field_restrictions` row and NOT in
  `restricted_fields` -> 422 `reads_not_allowed` at save; a restriction on `match.field` added
  between save and publish -> publish refused `reads_not_allowed` (pre-check and in-transaction);
  added after publish -> `check_reads/2` returns `{:error, :reads_not_allowed}` (the 7c refusal);
  listed in `restricted_fields` -> accepted, and the publish then requires
  `:EntitiesRestrictionsManage`. A restricted field listed only in `fields` is accepted at save
  and publish (its redaction is 7c's, section 8 item 3).
* AC11b [CDV 4] `"id"` in `fields`, `restricted_fields` or `match.field` -> 422 `invalid_manifest`.
* AC12 Permissions: TENANT_ADMIN reads and writes; PROCESS_DESIGNER reads only (403 on writes);
  TENANT_AUDITOR, PROCESS_OPERATOR, TASK_WORKER, AGENT_RUNNER, CANDIDATE 403 on all five tenant
  routes; `authorization_test.exs` endpoint pairs include the seven new paths.
* AC13 `kill_switch_on?/1` returns true when the row is absent; `check_reads/2` returns
  `:reads_not_allowed` for each run-time cause listed in section 8 item 2.

## 12. Tests (TEST-DESIGNER brief)

* New `test/letflow/scripts/policy_test.exs`: AC1 (row present after provisioning; raw
  `Repo.delete_all` / insert of `id = 2` refused, `pg_code == "LF001"` for delete, check violation
  for id), AC4, AC13, `references/2` (published and retired listed, draft/discarded/revoked not;
  cap 100 with total), concurrency AC9 (two processes, sandbox `:shared` or a task with explicit
  allowance, publish holding the share lock while clear waits).
* New `test/letflow/routers/script_policy_test.exs`: AC2, AC5 (route level), AC6, AC7, AC12;
  hand-built `auth_context` with `credential: :oidc` for writes and `:api_token` for refusals;
  responses compared to the allowlist maps (no extra keys).
* Extend `test/letflow/routers/` tenants tests (or a new `tenants_script_policy_test.exs`): AC3,
  including the platform-chain entry and the nil-actor tenant entry, 404 for an unknown and an
  unprovisioned slug, 403 for a non-platform PLATFORM_ADMIN.
* Extend the 7b-1 suites: `Validation` (AC8 shape, AC10 fixtures, AC11b), `Scripts.publish` (AC5
  per-case stop: a two-case script, `publish/7` with `before_case: fn 2 -> set_tenant_kill_switch
  on; _ -> :ok end`, asserting `{:error, :scripts_disabled}` and that case 2 never ran, e.g. via a
  `print`-free script whose case 2 would fail if run; AC8 publish refusal; AC11; AC11a), dry-run
  (AC5, AC10 query count via Ecto telemetry). A test asserts `:before_case` is ignored when
  `:scripts_test_hooks` is false.
* SEC F4: AC4's changeset-isolation tests in `policy_test.exs`.
* SEC F2: AC3's exact-key-set assertion on both the platform GET and the platform PUT. Existing "non-empty reads refused" test changes to "read of an
  unflagged type refused (`reads_not_allowed`)".
* `authorization_test.exs`: new endpoint pairs; `authorization_enforcement_test.exs` route walk
  finds no `:Unknown` key.
* Audit assertions: every write test asserts exactly one tenant entry (two entries: tenant +
  platform for AC3) with the section 7 shape, and none on no-op or refusal.

## 13. Security (INV mapping)

* INV-1: the tenant prefix comes only from `conn.assigns.scoped_opts` (tenant routes) or from the
  DB-resolved target tenant after `authorize_target_tenant/2` and `:TenantsManage` (platform
  routes); no body or path value selects a schema. Tables live in the tenant schema.
* INV-2: responses are built by `policy_map/1`, `master_map/1`, `platform_policy_map/1` and the
  clear map only; the platform GET and PUT omit the tenant's reason and user id (P10). Restricted
  read fields are redacted unless opted in, and a restricted match field must be opted in (P12).
* INV-3: the kill switch stops every sandbox entry point that exists after 7b-2a (dry-run, publish
  tests) and 7c's run (section 8); fixtures enter the sandbox as plain input (no new host function).
* INV-4: no secret touched.
* INV-5: an unknown flagged type on clear is the plain 404; masters and policy are tenant-local (no
  cross-tenant id is accepted); the 7c type-level refusal is independent of record ids (section 8).
* INV-6: two new tenant tables and seven routes; this section is the scoping statement.
* INV-7: the advisory-lock key and the jsonb containment value are bound parameters; the migration
  interpolates only `prefix()`.
* INV-8: every error is a stable atom mapped to a fixed status; a missing policy row is a 500 on GET
  (never a crash elsewhere: `kill_switch_on?` reads it as on).
* INV-10: the platform latch is writable only with `:TenantsManage` (platform scope, platform tenant
  only) and the verified platform prefix; a tenant route can never write it.

## 14. Deferred

* 7b-2b: `scripts.sod`, auto-strict, `self_published`, pending-review list, confirmation, the
  platform "forbid solo_audited" flag (`gh2534-7b2b-script-sod.md`).
* 7c: the run-time calls of section 8, pre-fetch, the read port, field redaction at run time.
* 0051 stage 1 (GH #2533): route-walk classification of section 9.3; 0051 stage 2: module-declared
  `tenant_wide` replaces `script_readable_masters` (migration of existing flags is that record's).
* GH #2548 (auditor source read); Record P (policy travel through packs/promotion); a web UI.
