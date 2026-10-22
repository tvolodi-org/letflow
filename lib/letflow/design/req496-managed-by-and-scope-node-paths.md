# REQ-496 / GH #2530: `managed_by` write lock and the `scope_node_paths` security index

Design artefact (CODE-DESIGNER, WF-02 step 3). Decision records: 0050 D7, D8, Deviation 1,
Security MUST M4; 0051 D2/D3 (consumers of the read API). Read on main `fde30dcab`.
Signatures and shapes only; no implementation code.

## Revision 1 (2026-10-14, after SECURITY-REVIEWER PASS and CODE-DESIGN-VALIDATOR FAIL)

| Item | Change | Where |
|---|---|---|
| B1 | `POST /entities/definitions` gets a ROUTER managed-name check right after `object_body/1`, before `validate_schema/2` (`entities.ex:446`); the core check in `create_definition/3` stays as the backstop for the pack path. T-09 restated. | 3.2, T-09 |
| B2 | In all four record handlers the managed check is the FIRST statement, before `object_body/1`, `cast_record_id/1`, `records_within_cap/1` and `Records`. Table fixed to match D6; malformed-body test added. | 3.1, T-05 |
| A1 | `create_definition/3` takes a transaction-scoped advisory lock on (tenant, name) before `check_create/3`; key derivation and range stated. | 2.4, 2.5, T-33 |
| A2 | Operator recovery for a squatted name documented. | OQ-2 |
| A3 | Calling `write/2` BEFORE the `org_unit` row write is a MUST for REQ-495; deadlock / lock errors raise (no `lock_timeout` set). SUPERSEDED by Revision 3: the table lock comes first on every path (insert: `lock!/1` -> `create_record/2` -> `write/2`); see 6.2. | 6.2 |
| A4 | `owner_of/2` and `check_tenant_write/2` return `:unmanaged` / `:ok` with no query for a name failing `^[a-z][a-z0-9_]{0,63}$`; manifest names must match it. | 2.3, 2.4 |
| A5 | Update-apply guard decodes `content` only when `is_binary/1`. | 3.3 |
| A6 | `check_create/3` matches `%Owner{}` structs only; any other term raises `FunctionClauseError`. | 2.4 |
| A7 | Consistency 200 body built as an explicit string-keyed map in the router. | 6.5 |
| A9 | Trigger also refuses changing `name` or `tenant_id` on a stamped row. | 2.1 |
| R2-B1 | Revision 2 (CDV round 2 blocker on 2.5): the create transaction now `Repo.rollback`s every error with the unchanged term (same `{:error, reason}` shapes, same HTTP mapping); a failed insert also rolls back step 3's `artifact_versions` row (intended fix, `definitions_test.exs:272-295` changes `ArtifactVersion` count 2 -> 1); all nested callers listed and verified. | 2.5, T-35 |
| R2-A4 | Revision 2, SEC r2 advisory 4: a pack install takes all its name locks up front, sorted, before any insert (`ManagedTypes.lock_names/2`); `435_001` cited at `login_directory.ex:75`. | 2.5, T-33 |
| R3 | Revision 3 (ORCH option (ii)): verified that `create_record/2` takes `FOR UPDATE` on the shared per-type `instance_sequence` row (`event_store.ex:606-640`, via `records.ex:308-329`), so insert-after-record deadlocks with a lock-first move. New `Letflow.ScopeNodePaths.lock!/1` (`LOCK TABLE ... SHARE ROW EXCLUSIVE`, raises `ArgumentError` outside a transaction, re-entrant). Insert: `lock!/1` -> `create_record/2` -> `write/2`; move/retire: `write/2` first. Table lock is taken before every seq-row / org-row lock, so no cycle. On an insert refusal the caller MUST `Repo.rollback`. Option (a) rejected (out of scope); option (b) withdrawn. Writer scan unchanged (allows `lock!(`). | 6.2, T-26 |
| CDV | `install_error` types extended; AC3 key-rejection levels stated; test file named; boundary rule documented as an advisory plus a textual test (T-34); moduledoc notes listed. | 2.6, 2.7, 3.5, 7, T-34 |

## 0. Facts verified for this design (beyond the REQ's own FACTS block)

| # | Fact | Evidence |
|---|---|---|
| F1 | `POST /solution-packs/:pack_id/update-apply` writes NO entity definition today. `apply_pack_update/6` only inserts `pack_update_resolutions` rows and advances `solution_pack_artefact_bases`. The REQ's claim that it reaches `create_definition/2` is inaccurate; only `/install` does (via `run_install/5` -> `create_packed_entity_definitions/3`). | `lib/letflow/definitions/solution_pack.ex:546-576, 608-646, 707-718`; `create_packed_entity_definitions` called only at `:1381` |
| F2 | The pack `definition_json` key whitelist already rejects an unknown key such as `"managed_by"` with `:invalid_pack_document`. The entity ENTRY level (`parse_entity_definition/1`) and the document top level (`parse_document/1`) fetch named keys and IGNORE extra keys. | `solution_pack.ex:1073-1083, 1141-1148` (whitelist); `:1028-1045`, `:939-963` (ignore extras) |
| F3 | `build_definition_document/1` (HTTP create) copies only known keys; an extra `"managed_by"` body key is silently DROPPED today. | `lib/letflow/routers/entities.ex:509-524` |
| F4 | `Installs.install/3` calls `SolutionPack.install(document, actor_id, opts)` with the SAME public function the HTTP route uses; `opts` is built by the caller (`TenantModules` router: `prefix:` + `rationale:`). | `lib/letflow/modules/installs.ex:222-238`; `lib/letflow/routers/tenant_modules.ex:71` |
| F5 | `Records.*` call `Repo.transaction/1` per command; inside a caller's transaction Ecto joins the outer transaction, so a caller `Repo.rollback` undoes the record write. | `lib/letflow/entities/records.ex:308-329` |
| F6 | Problem bodies carry `trace_id`; existing INV-5 byte-identity tests pin it with the `x-trace-id` header. | `lib/letflow/api/response.ex:117-123, 231-232`; `test/letflow/routers/entities_test.exs:69-82, 576` |
| F7 | `AuthorizedRouter` exposes `__authz_routes__/0` (method, local path, policy key) per router. | `lib/letflow/api/authorized_router.ex:101-104` |
| F8 | Tenant-scoped immutability triggers have a precedent (schema-qualified plpgsql function from `prefix()`). | `priv/repo/migrations/20260830020001_create_audit_entries_tenant_scoped.exs:72-107` |
| F9 | Last tenant-scoped migration on main is `20261008000001`; manifest at `lib/letflow/tenant_provisioning.ex:491-649`. | glob of `priv/repo/migrations/202610*` |
| F10 | `:UsersGroupsRolesManage` is a tenant-scope permission (TENANT_ADMIN, PLATFORM_ADMIN). Policy keys map to permissions via `required_permission/1`. | `lib/letflow/api/authorization.ex:298, 414, 1217-1218, 1280` |
| F11 | `Letflow.Scheduler.RecordDeadlineSweep` updates records of a configured type via `Records.update_record/2`; config is deploy-time, operator-only. | `lib/letflow/scheduler/record_deadline_sweep.ex:26-46, 254` |

## 1. Decisions

| Id | Decision | Why |
|---|---|---|
| D1 | `managed_by` is a new nullable `text` COLUMN on `entity_definitions` (tenant schema), NOT a key in `definition_json`. | Tenant-writable JSON (HTTP body, pack) can never carry it into storage; the content hash and logical shape are unchanged, so no existing definition changes version. No new table (Deviation 1 allows only `scope_node_paths`). |
| D2 | A type NAME is "managed by M" iff at least one `entity_definitions` row of that name has `managed_by = M`. | Name-level lock (activation is by name and demotes siblings, `definitions.ex:376-393`); one stamped row is enough, so no later row can "un-manage" the name. |
| D3 | The stamp is written only at INSERT, never by UPDATE. DB trigger refuses any UPDATE that changes `managed_by` (any direction) and any DELETE of a row whose `managed_by` is not null. Code: `EntityDefinition.changeset/2` never casts `:managed_by`. | Immutable at both levels; "re-install/upgrade cannot clear it" holds by construction. |
| D4 | A module declares managed names in its manifest under a new OPTIONAL key `manages_entity_types: [String.t()]`. Absent means `[]`. | Existing manifests (exam, fixtures) stay valid; `defmanifest` passes unknown keys through (`module.ex:177-181`). |
| D5 | The owner travels as an explicit ARGUMENT, never inside `opts` or request data: `Definitions.create_definition/3` and `SolutionPack.install/4` take `owner :: :tenant | ManagedTypes.Owner.t()`. The `/2` and `/3` arities keep their names and mean `:tenant`. An `Owner` is built only by `ManagedTypes.module_owner/1` from a Catalog entry module's compiled manifest; `Installs.install/3` is its only caller. | "Identified by caller, never by request data": the HTTP routers call the arities that hard-code `:tenant`; no request field, header, opts key or pack key can produce an `Owner`. |
| D6 | Generic record routes refuse in the ROUTER before any other check: `ManagedTypes.check_tenant_write/2` is the first step of the four handlers. `Records.*` gets no check. | Modules call `Records.*` directly (0050 D7 placement notes); the 403 is decided before Records, so a non-owner never reaches the append-only 422 and the answer is independent of record id, body and record existence. |
| D7 | One uniform 403 body, `Error.entity_type_managed/0` (section 4), for records routes, definitions routes and both solution-pack routes. | M4 "uniform 403"; constant body, no argument, so it cannot carry type, module, record or append-only status. |
| D8 | Pack refusal for a managed name: the uniform 403 (not `:invalid_pack_document`). `:invalid_pack_document` (422) is reserved for a pack that CARRIES the `managed_by` key. | AC3 lets the designer pick; one refusal body for "you may not write this type" everywhere. |
| D9 | `scope_node_paths`: one core module `Letflow.ScopeNodePaths` with ONE write function `write/2` taking an operation tuple (insert / move / retire). STABLE PUBLIC NAME for REQ-495: **`Letflow.ScopeNodePaths.write/2`**. | One function = one writer for the scan rule (section 7); arguments follow the codebase convention "prefix last" (`Records.create_record(attrs, prefix)`). |
| D10 | Writer locking: `LOCK TABLE "<prefix>".scope_node_paths IN SHARE ROW EXCLUSIVE MODE` as its first statement, held until the CALLER's transaction ends. | Serialises all writers of one tenant's tree (closes the concurrent A-under-B / B-under-A cycle race); does not block readers (ACCESS SHARE); per-schema, so no cross-tenant contention and no extra table. |
| D11 | Admin consistency endpoint permission: `:UsersGroupsRolesManage` (the 0050 D8 proposal), via a new POLICY KEY `:ScopeNodePathsConsistencyRead`. No new permission atom, so no `docs/roles.md` change. | Same holders as the tree-write permission (0050 D7); tenant scope; read-only. |
| D12 | The "mix check" for writers is a new static Mix task `mix letflow.check_scope_node_paths_writers` added to `@check_static_steps` (so `mix letflow.check` runs it). The consistency "mix check test" is an ExUnit test run by `mix letflow.check` (`letflow.check.test`) calling the shared core function `Letflow.ScopeNodePaths.Consistency.check/1`. | A static scan needs no DB; a consistency check needs data, so its check lives in the suite with seeded rows; the endpoint calls the same function. |

## 2. `managed_by` storage, declaration and stamping

### 2.1 Migration `priv/repo/migrations/20261014000001_add_managed_by_to_entity_definitions.exs`

Module `Letflow.Repo.Migrations.AddManagedByToEntityDefinitions`. TENANT-SCOPED: body under the
mandatory `if prefix() do` guard; second half: one entry appended to
`@tenant_scoped_migration_manifest` (`tenant_provisioning.ex:647-648` is the current last entry)
plus the moduledoc count update.

| Element | Shape |
|---|---|
| column | `entity_definitions.managed_by text NULL` (no default; existing rows stay NULL) |
| index | `entity_definitions_managed_by_name_idx` on `(tenant_id, name) WHERE managed_by IS NOT NULL` (partial; serves every `owner_of/2` lookup) |
| function | `"<schema>".entity_definitions_managed_by_guard()` returning trigger, plpgsql. On UPDATE: if `NEW.managed_by IS DISTINCT FROM OLD.managed_by`, or (Revision 1, A9) `OLD.managed_by IS NOT NULL` and (`NEW.name IS DISTINCT FROM OLD.name` or `NEW.tenant_id IS DISTINCT FROM OLD.tenant_id`), raise exception `entity_definitions.managed_by is immutable`; else return NEW. On DELETE: if `OLD.managed_by IS NOT NULL` raise the same exception; else return OLD. |
| triggers | `entity_definitions_managed_by_no_update` BEFORE UPDATE FOR EACH ROW; `entity_definitions_managed_by_no_delete` BEFORE DELETE FOR EACH ROW; both execute the function above |
| down | drop both triggers, the function, the index, the column (each `execute/2` with its reverse, as in F8's precedent) |

Status flips (`promote_and_demote_siblings/2`, `update_all` on `status`) keep `managed_by`
unchanged, so they pass the trigger. No code path deletes `entity_definitions` rows today (grep
`delete_all|DELETE FROM .*entity_definitions` over lib/test/priv: no hits).

### 2.2 Schema `Letflow.Entities.EntityDefinition`

* Add `field(:managed_by, :string)`. NOT added to `@required_fields`, NOT cast by `changeset/2`.
* New function, the only code that can set it:

  `@spec put_managed_by(Ecto.Changeset.t(), module_id :: String.t()) :: Ecto.Changeset.t()`

  Applies `put_change(:managed_by, module_id)` only when the changeset's data is not yet loaded
  from the DB (`Ecto.get_meta(data, :state) == :built`); on a loaded struct it adds a changeset
  error on `:managed_by` ("is immutable") instead.

### 2.3 Manifest key

`Letflow.Modules.Module.manifest()` gains `optional(:manages_entity_types) => [String.t()]`
(typedoc: "entity type names this module owns; the install step stamps `managed_by` on them;
0050 D7"). `Catalog.validate/2` gains a seventh rule, run after the existing six:

| Rule | Error |
|---|---|
| key absent: ok. Present: must be a list of binaries, each matching `^[a-z][a-z0-9_]{0,63}$` (Revision 1, A4), with no duplicates | `{:error, {:invalid_manages_entity_types, value}}` |

### 2.4 `Letflow.Entities.ManagedTypes` (new, `lib/letflow/entities/managed_types.ex`)

```
Struct Letflow.Entities.ManagedTypes.Owner, both keys enforced:
  @type t :: %Letflow.Entities.ManagedTypes.Owner{module_id: String.t(), manages: MapSet.t(String.t())}

@type owner :: :tenant | Owner.t()

@spec module_owner(entry_module :: module()) :: Owner.t()
@spec owner_of(name :: String.t(), prefix :: String.t()) ::
        {:ok, module_id :: String.t()} | :unmanaged | {:error, :invalid_schema_name}
@spec check_tenant_write(name :: String.t(), prefix :: String.t()) ::
        :ok | {:error, :entity_type_managed} | {:error, :invalid_schema_name}
@spec check_create(name :: term(), owner(), prefix :: String.t()) ::
        {:ok, stamp :: String.t() | nil}
        | {:error, :entity_type_managed}
        | {:error, {:managed_name_taken, String.t()}}
        | {:error, :invalid_schema_name}
```

* `module_owner/1`: `%Owner{module_id: manifest.id, manages: MapSet.new(Map.get(manifest, :manages_entity_types, []))}`.
* `owner_of/2`: one query, `entity_definitions` in `prefix`, `tenant_id = <from prefix> AND name = ^name AND managed_by IS NOT NULL`, `limit 1`, selecting `managed_by` (bound params only).
* `check_tenant_write/2`: `owner_of/2` -> `{:ok, _}` gives `{:error, :entity_type_managed}`; `:unmanaged` gives `:ok`.
* Revision 1, A4: `owner_of/2` returns `:unmanaged` WITHOUT a query when `name` does not match
  `@managed_name_format ~r/^[a-z][a-z0-9_]{0,63}$/` (so `check_tenant_write/2` returns `:ok` and the
  existing route flow answers as before). Sound because every managed name satisfies the format
  (Catalog rule 7, section 2.3), so a name failing it can never be managed.
* Revision 1, A6: `check_create/3` has exactly two owner clauses, `:tenant` and
  `%Letflow.Entities.ManagedTypes.Owner{}` (struct pattern). Any other term (a plain map with
  `:module_id`, a string) raises `FunctionClauseError`: a programmer error, never request data.
* Revision 1, A1: `check_create/3` is always called inside a transaction (section 2.5) that already
  holds the per-(tenant, name) advisory lock, so two concurrent creates of one name (a tenant pack
  and a module install, or two module installs) cannot both pass the "no row of `name` exists" /
  "no stamped row exists" reads. Lock key: the TWO-int4 form
  `pg_advisory_xact_lock(496_001, hashtext($1))` with `$1 = "<tenant_id>:<name>"` (bound
  parameter). Range and non-collision: Postgres keeps two-int4 keys (`objsubid = 2`) in a separate
  key space from single-bigint keys (`objsubid = 1`), so it cannot collide with the single-bigint
  keys in use (`hashtext(schema_name)` in `tenant_provisioning.ex:307, :1503, :2307`; the
  tenant-template lock; #2547's tenant-admin key outside the int32 range). Within the two-int4
  space the class id `496_001` differs from the only other one, `435_001`
  (`login_directory.ex:75, :508`). `hashtext` collisions between two names only serialise them,
  never wrongly allow. Constant `@create_lock_namespace 496_001` in `ManagedTypes`, with a comment
  listing the namespaces above. Activation-by-id was not chosen: the race is at create time.
* `check_create/3` decision table (`name` not a binary: `{:ok, nil}`, the Validator rejects it later):

| `owner_of(name)` | owner | result |
|---|---|---|
| `{:ok, m}` | `:tenant` | `{:error, :entity_type_managed}` |
| `{:ok, m}` | `%Owner{module_id: m}` with `name in manages` | `{:ok, m}` (new version, stamped) |
| `{:ok, m}` | any other `%Owner{}` | `{:error, :entity_type_managed}` |
| `:unmanaged` | `:tenant` | `{:ok, nil}` |
| `:unmanaged` | `%Owner{}` with `name in manages`, and NO row of `name` exists | `{:ok, owner.module_id}` |
| `:unmanaged` | `%Owner{}` with `name in manages`, and an unmanaged row of `name` exists | `{:error, {:managed_name_taken, name}}` (never lock a tenant's own type) |
| `:unmanaged` | `%Owner{}`, `name not in manages` | `{:ok, nil}` |

### 2.5 `Letflow.Entities.Definitions`

```
@spec create_definition(create_attrs(), prefix :: String.t()) :: {:ok, EntityDefinition.t()} | create_error()
@spec create_definition(create_attrs(), prefix :: String.t(), ManagedTypes.owner()) ::
        {:ok, EntityDefinition.t()} | create_error()

@type create_error ::
        {:error, {:validation, [Validator.violation()]}}
        | {:error, {:repository, term()}}
        | {:error, {:persistence, Ecto.Changeset.t()}}
        | {:error, :invalid_schema_name}
        | {:error, :entity_type_managed}                       # new
        | {:error, {:managed_name_taken, String.t()}}          # new
```

`create_definition/2` = `create_definition(attrs, prefix, :tenant)`. Step order of `/3`
(Revision 1, A1, corrected by Revision 2: steps 0-4 run inside `Repo.transaction/1`, which joins
the caller's transaction when there is one. EVERY error branch (steps 0-4) calls
`Repo.rollback(error)` with the unchanged error term, so `create_definition/3` returns exactly the
same `{:error, reason}` shapes as today (`{:error, {:persistence, changeset}}` etc.; the success is
unwrapped from `{:ok, entity_definition}`), and the HTTP mapping is unchanged
(`entities.ex:652`, `{:persistence, _}` -> 409, test `entities_test.exs:784-794`). Returning the
error without rolling back is NOT possible: a UNIQUE violation at step 4 aborts the Postgres
transaction, so the wrapper would yield `{:error, :rollback}` / a 500.

INTENDED BEHAVIOUR CHANGE (Revision 2): on a failed step 4 the `repository_artifacts` /
`artifact_versions` rows written by step 3 are now rolled back too. This is a deliberate fix: no
orphan artifact version (it removes the "accepted cost" of design req226 §4 Scenario B / OQ-1,
quoted in the `Definitions` moduledoc, which ELIXIR-DEV updates). Test change for TEST-DESIGNER,
`test/letflow/entities/definitions_test.exs:272-295`: keep the
`{:error, {:persistence, changeset}}` and `%{name: ["has already been taken"]}` assertions and the
`EntityDefinition` count of 1; change `ArtifactVersion` count from `2` to `1` and replace the
comment at :290-292 ("a second artifact_versions row WAS created") with "the rejected attempt's
artifact_versions row is rolled back with it (REQ-496 Revision 2)".

Callers verified (grep `create_definition(` over lib/test/priv on `fde30dcab`): in `lib/` there
are exactly two. (1) `Letflow.Routers.Entities.handle_create_definition/1` (`entities.ex:450`), no
caller transaction, so the wrapper is the outermost one. (2)
`SolutionPack.create_packed_entity_definitions/3` (`solution_pack.ex:1599`), nested inside
`run_install/5`'s `Repo.transaction` (`:1369`), whose `with`/`else` already does
`Repo.rollback(reason)` on any `{:error, _}` (`:1393-1395`); that transaction is itself nested in
`Installs.install/3`'s (`installs.ex:89-105`), which also rolls back on `{:error, _}`. So every
nested caller already treats `{:error, _}` as a rollback; none relies on a partial commit or the
orphan row. `test/letflow/definitions/solution_pack_test.exs:574-590` asserts the same
`{:error, {:persistence, _}}` shape and full rollback, unchanged. No seed task (`lib/mix/tasks`)
calls `create_definition`; `test/support/exam_fixtures.ex:253-258` and the other test callers
assert `{:ok, _}` outside any caller transaction. The only test depending on the orphan row is
`definitions_test.exs:294` (changed above).

Revision 2, SEC r2 advisory 4, lock order: a pack install takes ALL its name locks up front, in
`run_install/5` as the first step inside its transaction (before `insert_install_row`, `:1370`):
the distinct `definition_json.name` values of `parsed.entity_definitions` that are binaries
matching the managed-name format, sorted ascending (`Enum.sort/1`, byte order), one
`ManagedTypes.lock_names/2` call. Two concurrent installs therefore acquire overlapping locks in
the same order and cannot deadlock. Step 0a below re-takes the same lock for one name, which
Postgres grants immediately to the holding transaction (advisory locks are re-entrant per
session). New function:

`@spec lock_names([String.t()], prefix :: String.t()) :: :ok | {:error, :invalid_schema_name}`

(sorts and deduplicates itself as well; skips names failing the format; one
`pg_advisory_xact_lock(496_001, hashtext($1))` per name, bound parameter.) The `496_001`
namespace was chosen against `login_directory.ex:75` (`@lock_namespace 435_001`, used at `:508`),
read on `fde30dcab`; ELIXIR-DEV re-confirms that line before merging.

Steps:
**0a.** when `Map.get(definition, :name)` is a binary matching the managed-name format, take
`pg_advisory_xact_lock(496_001, hashtext("<tenant_id>:<name>"))` (section 2.4).
**0.** `ManagedTypes.check_create(Map.get(definition, :name), owner, prefix)`; an error returns
immediately (no Validator call, no `Repository.create/2`, no write). **1-4.** unchanged; at step 4
`insert_entity_definition` pipes the changeset through `EntityDefinition.put_managed_by/2` when the
stamp is a binary. `activate_definition/4` is NOT changed (modules activate their own types
through it, `entity_activation.ex:105`); its refusal is in the router (section 3.2).

### 2.6 Pack path

* `SolutionPack.install/3` = `install(document, actor_id, opts, :tenant)`. New
  `@spec install(map(), Ecto.UUID.t(), Definitions.opts(), ManagedTypes.owner()) :: {:ok, install_result()} | install_error()`.
  `run_install` and `create_packed_entity_definitions` gain the `owner` argument and call
  `Letflow.Entities.Definitions.create_definition(create_attrs, prefix(opts), owner)`.
* `install_error()` already includes `Letflow.Entities.Definitions.create_error()` (`:294`);
  Revision 1 (CDV) also lists the two members EXPLICITLY in `SolutionPack.install_error()`:
  `{:error, :entity_type_managed}` and `{:error, {:managed_name_taken, String.t()}}`.
* `managed_by` key handling (AC3), exact levels:

  | Level | Behaviour |
  |---|---|
  | pack document top level | REJECTED, `{:error, :invalid_pack_document}` (new check in `parse_document/1`) |
  | `entity_definitions[]` entry | REJECTED, same (new check in `parse_entity_definition/1`) |
  | inside `definition_json` | REJECTED, same (already, `@top_level_keys` whitelist, F2; test added) |
  | inside a process `definitions[]` entry or its `graph`, `variable_schemas[]`, `manifest` | IGNORED (not entity-definition data; never reaches `entity_definitions`) |
  | HTTP `POST /entities/definitions` body top level | REJECTED with the uniform 403 (section 3.2) |
  | HTTP body nested (`fields[]` etc.) | IGNORED (the builder copies only known keys, F3); never stored in the column |

  All rejections happen before any query.
* The managed check uses `definition_json.name` (the stored name), not the entry-level `name`.

### 2.7 `Letflow.Modules.Installs.install/3`

After `fetch_module/1`: `owner = ManagedTypes.module_owner(entry_module)`. `maybe_install_pack/3`
calls `SolutionPack.install(document, actor_id, opts, owner)`. After the pack step and before
`insert_tenant_module/2`: every name in `owner.manages` must be a key of
`pack_entity_definition_ids`, else `{:error, {:pack_install_failed, {:managed_type_not_in_pack, name}}}`
(rollback; a module with `pack: nil` and a non-empty list fails the same way). Revision 1 (CDV):
`Installs.install_error()` becomes `{:error, {:pack_install_failed, SolutionPack.install_error() | {:managed_type_not_in_pack, String.t()}}}`
(which includes `{:managed_name_taken, String.t()}` through `install_error()`). The existing
`TenantModules` mapping of `{:pack_install_failed, _}` (422 "module installation failed") covers it;
no router change. Re-install stays `{:error, :already_installed}` (`installs.ex:196-201`); there is no
upgrade path today, and any future one must go through `create_definition/3` and cannot clear a
stamp (D3).

### 2.8 Test fixture module

`test/support/modules/fixture_managed/fixture_managed.ex`, `Letflow.Modules.FixtureManaged`,
id `"fixture_managed"`, registered in `config/test.exs` only. Pack
`priv/module_fixtures/managed_foundation.json` with eight entity definitions (each: one
`name :: string` field, no `queried`, no FKs, so activation creates no promotions):
`org_legal_entity`, `org_site`, `org_unit`, `org_unit_membership`, `catalog_item`, `catalog_uom`,
`fxm_ledger` (`append_only: true`), `fxm_free` (NOT managed, control). Manifest
`manages_entity_types:` the first seven. `on_install/3` calls
`EntityActivation.activate_and_promote(prefix, ctx, <all eight>)`. Public helpers (test-only, the
"owning module's own path"): `create_record(type, field_values, prefix)`,
`update_record(type, record_id, field_values, prefix)`, `delete_record(type, record_id, prefix)`,
each a direct `Letflow.Entities.Records.*` call with `actor_id` and a fresh idempotency key.
No router, no permissions (avoids changing permission/role-count tests).

## 3. Refusal points (file:line on `fde30dcab`)

### 3.1 Generic record routes, `lib/letflow/routers/entities.ex`

| Route (line) | Handler (line) | New first step |
|---|---|---|
| `POST /records/:entity_type` (:293) | `handle_create_record/2` (:946) | `ManagedTypes.check_tenant_write(entity_type, prefix)` as the FIRST statement, before `object_body/1` |
| `PUT /records/:entity_type/:record_id` (:297) | `handle_update_record/3` (:996) | same FIRST statement, before `cast_record_id/1` and `object_body/1` |
| `DELETE /records/:entity_type/:record_id` (:301) | `handle_delete_record/3` (:1041) | same FIRST statement, before `cast_record_id/1` and the query-param parse |
| `POST /records/:entity_type/import` (:314) | `handle_import_records/2` (:1116) | same FIRST statement, before `object_body/1`, `records_within_cap/1` and the version/type checks |

(Revision 1, B2: in every handler nothing reads the body, path id or query string before this
check; D6 and this table now say the same thing.)

`{:error, :entity_type_managed}` -> `Response.send_problem(conn, Error.entity_type_managed())`;
`{:error, :invalid_schema_name}` -> `Response.internal_error(conn)` (unreachable, INV-1, mapped).
Order per request: route-level permission (existing generic 403) -> managed check -> everything
existing. Consequences: the 403 bytes do not depend on record id (existing, absent or malformed),
body, headers, query string or record state; `Records` is never called, so the append-only 422
(`entities.ex:1415-1416`) is unreachable for a non-owner (AC4). Unmanaged types: one extra indexed
read, otherwise byte-for-byte unchanged. NOT covered (OQ-3): the attachment routes.

### 3.2 Entity-definition routes, `lib/letflow/routers/entities.ex`

| Route (line) | Handler (line) | Refusal |
|---|---|---|
| `POST /definitions/:name/activate` (:257) | `handle_activate_definition/2` (:720) | first step `check_tenant_write(name, prefix)` (before body parse) -> uniform 403 |
| `POST /definitions` (:261) | `handle_create_definition/1` (:441) | Revision 1, B1. Right after `object_body/1` (:445) and BEFORE `validate_schema/2` (:446): (a) body has key `"managed_by"` (any value, incl. null) -> uniform 403; (b) `body["name"]` is a binary and `check_tenant_write(body["name"], prefix)` errs -> uniform 403, whatever the rest of the body holds (missing fields, bad types, invalid fields). A non-binary or absent `name` skips (b) and the existing 422 path answers. (c) Backstop: core `create_definition/2` step 0 still returns `{:error, :entity_type_managed}` (reachable only on a race or through the pack path) -> new `render_create_definition` clause -> uniform 403 |

No update/deprecate/delete entity-definition route exists. Inheritance rule (written into the
router moduledoc): any future entity-definition write route MUST call `check_tenant_write/2` first;
test T-08 fails when a write route under `/definitions` is not in the guarded set.

### 3.3 Solution packs, `lib/letflow/routers/solution_packs.ex`

| Route (line) | Refusal |
|---|---|
| `POST /solution-packs/install` (:171) | Core: `SolutionPack.install/3` (`:tenant`) -> `create_definition/3` step 0 -> `{:error, :entity_type_managed}` -> `Repo.rollback` of the whole install (no `solution_pack_installs` row, no definition, no artifact) -> new `render_install/2` clause -> uniform 403. Also a clause for `{:error, {:managed_name_taken, _}}` -> `Response.internal_error/1` (unreachable with `:tenant`; mapped per the type-table-vs-error-map rule). The existing module-owned `pack_id` 409 (`:275-279`) still runs first. |
| `POST /solution-packs/:pack_id/update-apply` (:186) | Router guard in `run_update_apply/3` after field validation and before `apply_with_actor/6`: for every entry of `theirs_artefacts`, `incoming_artefacts` and `resolutions` whose `artefact_type == "entity_definition"`, the candidate names are `artefact_id` and, only when `content` (or a resolution's `resolved_content`) `is_binary/1` (Revision 1, A5) and decodes (`Jason.decode/1`, failure ignored) to a JSON object with a binary `"name"`, that name; any candidate for which `check_tenant_write/2` errs -> uniform 403, nothing written. Today the route writes no definition (F1); if it ever does, it must use `create_definition/2`, which refuses again (defence in depth). |

### 3.4 Not covered (scope boundary, see OQs)

Process-step entity writes (REQ-484), 0053 hook 2, 0051 scope-column / `tenant_wide`
declarations: out of scope per REQ. `RecordDeadlineSweep` (F11): operator config, not a tenant
path; unchanged (OQ-4).

### 3.5 Caller restriction and moduledoc notes (Revision 1, CDV advisories)

* Boundary rule: `mix letflow.check_boundaries` classifies xref FILE edges into
  `lib/letflow/modules/<id>/` directories (Rules 0-5, `lib/mix/tasks/letflow.check_boundaries.ex:9-36`);
  it has no per-function caller allow-list, so "only `Installs` may call
  `ManagedTypes.module_owner/1` and `SolutionPack.install/4` with an `Owner`" is NOT added there
  (advisory, not built). Instead T-34, a textual test, asserts that across `lib/` the only files
  containing `module_owner(` are `lib/letflow/entities/managed_types.ex` (definition) and
  `lib/letflow/modules/installs.ex`, and that the `Owner` struct is constructed only in
  `managed_types.ex`.
* Moduledoc notes ELIXIR-DEV writes: `ManagedTypes` (the caller restriction above, the name format,
  the advisory-lock namespace list); the update-apply guard in `Letflow.Routers.SolutionPacks` is
  defence in depth only (the route writes no entity definition today, F1); the writer-scan task
  states its roots (`lib/letflow/modules`, `priv/modules`) and its string-splitting limit;
  `Consistency.check/1` loads every row of the tenant's table, uncapped (only the response lists
  are capped).

## 4. Uniform 403 body: `Letflow.Api.Error.entity_type_managed/0`

`@spec entity_type_managed() :: t()`, no argument.

| Member | Value |
|---|---|
| `type` | `@problems_base <> "entity-type-managed"` |
| `title` | `"Entity Type Is Managed by a Module"` |
| `status` | `403` |
| `detail` | `"this entity type is reserved for or managed by a module and cannot be changed through this route"` |
| `extensions` | `%{"code" => "entity_type_managed"}` |

No type name, module id, record id, field value, or append-only wording (INV-2, INV-4, AC4). The
existing `error.ex:288` doc line stays true. The only per-request member is `trace_id` (F6); the
byte-identity tests pin it.

## 5. `scope_node_paths` migration

`priv/repo/migrations/20261014000002_create_scope_node_paths.exs`, module
`Letflow.Repo.Migrations.CreateScopeNodePaths`, TENANT-SCOPED (guard + manifest entry), house
header comment, reversible (`change/0` with `create table`/`create index`).

| Column | Type | Null | Notes |
|---|---|---|---|
| `node_id` | `text` | no | primary key, constraint `scope_node_paths_pkey` (this is the `node_id` index) |
| `path` | `text` | no | `"/" <> id1 <> "/" <> ... <> idN <> "/"`, root first, ends with the node's own id |
| `depth` | `smallint` | no | number of path segments; root = 1; CHECK `depth >= 1` (`scope_node_paths_depth_positive`); NO upper-bound CHECK (the bound is enforced by `write/2` and detected by the consistency check, which must be able to see a depth-13 row) |
| `retired_at` | `utc_datetime_usec` | yes | set by retire |
| `inserted_at`, `updated_at` | `utc_datetime_usec` | no | |

Indexes: `scope_node_paths_pkey (node_id)`; `scope_node_paths_path_pattern_idx` UNIQUE on
`(path text_pattern_ops)` (raw `execute/2` with reverse `DROP INDEX`, schema-qualified from
`prefix()`). No `tenant_id` column: schema-per-tenant is the isolation mechanism (INV-1) and the
table has no global twin. No FK to any module table (0050 D8). Also: add `"scope_node_paths"` to
`test/support/tenant_fixture.ex` `@expected_tenant_tables` in the same change (anti-patterns
"new tenant-scoped migration's tables must be added ...").

## 6. `Letflow.ScopeNodePaths` (new, `lib/letflow/scope_node_paths.ex`)

### 6.1 Types and schema

```
@type node_id :: String.t()        # 1..64 bytes, valid UTF-8, no "/" and no control chars
@type change ::
        {:insert, node_id(), parent_id :: node_id() | nil}
        | {:move, node_id(), new_parent_id :: node_id() | nil}
        | {:retire, node_id()}
@type write_error ::
        :invalid_node_id | :node_exists | :node_not_found | :node_retired
        | :parent_not_found | :parent_retired | :cycle | :depth_exceeded
        | :invalid_schema_name
@max_depth 12

Letflow.ScopeNodePaths.Node  -- Ecto schema "scope_node_paths", documented as read model only
  primary key: node_id :string (not autogenerated)
  fields: path :string, depth :integer, retired_at :utc_datetime_usec,
          inserted_at / updated_at :utc_datetime_usec
  @type t :: %Letflow.ScopeNodePaths.Node{}
```

### 6.2 The one writer

```
@spec write(change(), prefix :: String.t()) :: {:ok, Node.t()} | {:error, write_error()}
```

Common steps: validate every id in the tuple (`:invalid_node_id`); `TenantProvisioning.tenant_id_for_schema_name(prefix)`
(`:invalid_schema_name`); if `Repo.in_transaction?()` is false, run the rest inside
`Repo.transaction/1` (standalone use; an error result rolls that own transaction back and is returned
unwrapped); if true, run in the caller's transaction and NEVER call `Repo.rollback/1` (every refusal is
detected by reads before the first write, so a refusal leaves the caller's transaction usable).
Then `LOCK TABLE "<prefix>".scope_node_paths IN SHARE ROW EXCLUSIVE MODE` (identifier from the
validated server-side prefix, no tenant data in SQL text; same precedent as `records.ex` `build_upsert_sql`).

| Op | Checks, in order | Write |
|---|---|---|
| `{:insert, n, nil}` | `n` absent (`:node_exists`) | row `path "/n/"`, `depth 1` |
| `{:insert, n, p}` | `n` absent; `p` present (`:parent_not_found`); `p.retired_at` nil (`:parent_retired`); `p.depth + 1 <= 12` (`:depth_exceeded`) | row `path p.path <> n <> "/"`, `depth p.depth + 1` |
| `{:move, n, np}` | `n` present (`:node_not_found`); `n.retired_at` nil (`:node_retired`); if `np` non-nil: `np == n` -> `:cycle` (direct); `np` present (`:parent_not_found`); `String.starts_with?(np.path, n.path)` -> `:cycle` (transitive: new parent inside n's subtree); `np.retired_at` nil (`:parent_retired`); unchanged parent -> `{:ok, n}` with no write; `subtree_max = max(depth) WHERE path LIKE like_prefix_pattern(n.path)`; `new_depth = (np && np.depth + 1) || 1`; `subtree_max + (new_depth - n.depth) <= 12` (`:depth_exceeded`) | ONE `UPDATE` over `WHERE path LIKE <escaped n.path>%` setting `path = new_prefix || substr(path, length(n.path) + 1)`, `depth = depth + delta`, `updated_at = now` (bound params; includes n itself) |
| `{:retire, n}` | `n` present (`:node_not_found`); already retired -> `{:ok, n}` unchanged (idempotent) | `retired_at = now`, `updated_at = now`; descendants untouched |

Return: the node row as stored after the operation.

Call order, a MUST for REQ-495 (Revision 3, ORCH option (ii); keeps the Revision 1 A3 lock-first
rule; written into the moduledoc). Every org transaction takes the table lock L BEFORE any
`org_unit` record write:

| Op | Caller sequence, one transaction |
|---|---|
| insert | `lock!(prefix)` -> `Records.create_record/2` (mints the `record_id` = node id) -> `write({:insert, id, parent}, prefix)` |
| move | `write({:move, id, new_parent}, prefix)` -> `Records.update_record/2` |
| retire | `write({:retire, id}, prefix)` -> `Records.update_record/2` |

New public function (signature only):

`@spec lock!(prefix :: String.t()) :: :ok`

Takes `LOCK TABLE "<prefix>".scope_node_paths IN SHARE ROW EXCLUSIVE MODE` (the same statement
`write/2` takes first, D10). Raises `ArgumentError` when `Repo.in_transaction?()` is false (an
xact lock outside a transaction would be released at once) or when the prefix fails
`TenantProvisioning.tenant_id_for_schema_name/1`. Re-entrant: a second `LOCK TABLE` by the same
transaction is granted at once, so `write/2` re-taking it after `lock!/1` is harmless. It writes
nothing and is not a writer; modules call it (never raw SQL). The writer scan (section 7) is
unchanged and allows it: `ScopeNodePaths.lock!(` neither names the table nor matches
`ScopeNodePaths\.[A-Z{]`.

Refusals: for move/retire `write/2` refuses before the record write, so nothing to undo (the
caller still rolls back or returns the error). For insert the record already exists, so on any
`{:error, _}` from `write/2` the caller MUST `Repo.rollback/1`, which removes the record.

Deadlock analysis. Evidence, `fde30dcab`:
* An insert cannot go first: `Records.create_record/2` mints `record_id` inside the command
  (`records.ex:186`), so the node id does not exist before the record does.
* `create_record/2` DOES lock an existing, shared row. `Records.run_command/2`
  (`records.ex:308-329`) resolves ONE synthetic instance per entity type
  (`EntityTypeInstance.get_or_create(entity_type, prefix)`) and appends through
  `EventStore.append_multi/3`, whose M2 step `assign_sequence/3` takes `SELECT ... FOR UPDATE` on
  that instance's `instance_sequence` row (`event_store.ex:606-640`) and holds it to commit; the
  `instance_projections` row of the same instance is updated in the same step chain. So every
  `org_unit` create, update or delete in a tenant holds the same row lock S ("org_unit's sequence
  row") until commit.
* Insert-after without `lock!/1` deadlocks: T1 (insert) holds S after `create_record`, then
  waits for L in `write/2`; T2 (move) holds L, then waits for S in `update_record`. Cycle
  S -> L -> S; Postgres aborts one with `deadlock_detected`. Hence `lock!/1` for inserts.
* With the table above, every org transaction takes L before S and before any `org_unit` row lock.
  Two org transactions therefore contend on L first and are fully serialised there; the one
  holding L then takes S and row locks that no other org transaction can hold (they are all
  waiting on L). No cycle is possible.
* The other locks `create_record/2` can take do not change this: the idempotency claim
  (`event_store.ex:649-674`, `on_conflict: :nothing` on `idempotency_key`) and the promoted-table
  upsert (`records.ex:471, :620`, `ON CONFLICT (record_id)`) can only wait on a transaction with
  the same key / record id, i.e. another `org_unit` writer, which is already behind L; a unique
  business-code index wait likewise only involves another `org_unit` writer; slice 1 promotes no FK
  (0050 D3.6), and if one is promoted later the `KEY SHARE` it takes on a referenced `org_unit`
  row does not conflict with a mover's non-key `UPDATE` (`FOR NO KEY UPDATE`).
* Residual: several `write/2` / `lock!/1` calls in one transaction are fine (L is re-entrant).
  An `org_unit_membership` write does not take L; if a REQ-495 transaction writes a membership
  AND calls `lock!/1`/`write/2`, it MUST take L before the membership record write too (same
  rule: L before any record write in an org transaction).

`write/2`'s own guarantee is unchanged: it detects every refusal before its first write and never
calls `Repo.rollback/1` itself inside a caller's transaction.

Rejected: option (a), a caller-supplied `record_id` for `create_record/2` (would let an insert
call `write/2` first), changes the core `Records` contract and idempotency semantics; out of scope
for REQ-496. The ORCH option (b) mixed order (insert after, move/retire first) is withdrawn: it
deadlocks (first bullet).

API delta: `lock!/1` is added (above); no change to `write/2`, its error atoms, reads, or D10.

Lock waits: `write/2` sets NO `lock_timeout` (a `SET LOCAL` would leak into the rest of the
caller's transaction). A wait ends when the holder commits; a Postgres deadlock
(`deadlock_detected`) or a server-side `lock_timeout`/`statement_timeout` RAISES
`Postgrex.Error` out of `write/2` (not a typed `{:error, _}`): it aborts the caller's transaction,
and through HTTP surfaces as the pipeline's logged, detail-free 500 (INV-8: an internal fault, not
caller input). Stated in the moduledoc. `write/2` audits nothing (OQ-5).

### 6.3 Reads

```
@spec ancestors(node_id(), prefix :: String.t()) ::
        {:ok, [Node.t()]} | {:error, :invalid_node_id | :node_not_found | :invalid_schema_name}
@spec descendants_of([node_id()], prefix :: String.t()) ::
        {:ok, [Node.t()]} | {:error, :invalid_node_id | :too_many_nodes | :invalid_schema_name}
@spec like_prefix_pattern(path :: String.t()) :: String.t()
```

* `ancestors/2`: load the node; take its path segments minus the last; one query
  `node_id = ANY(^segments)` ordered by `depth` asc. Root first, the node itself excluded. No LIKE.
* `descendants_of/2`: input deduplicated, at most 500 ids (`:too_many_nodes`); `[]` -> `{:ok, []}`.
  Query 1: paths of the given ids (`node_id = ANY(^ids)`; unknown ids ignored). Query 2:
  `path LIKE ANY(^patterns)` where `patterns = Enum.map(paths, &like_prefix_pattern/1)` (a bound
  `text[]`), ordered by `path`. Result includes the given nodes themselves (0051 D2 subtree
  semantics) and retired nodes (caller filters on `retired_at`).
* `like_prefix_pattern/1` (public, `@doc`, the single escaping helper 0051 reuses; anti-pattern
  "duplicating a fragment literal"): replaces `\` with `\\`, `%` with `\%`, `_` with `\_`, then
  appends `%`. Single-pattern queries pass `ESCAPE '\'` explicitly; `LIKE ANY` relies on
  Postgres's documented default escape character (backslash). Both are bound parameters (INV-7).

### 6.4 Consistency check (shared core function)

`Letflow.ScopeNodePaths.Consistency` (`lib/letflow/scope_node_paths/consistency.ex`):

```
@type report :: %{
        status: :ok | :inconsistent,
        checked_nodes: non_neg_integer(),
        max_depth: 12,
        counts: %{orphans: n, cycles: n, depth_exceeded: n, malformed: n, stale_paths: n},
        orphans: [node_id()], cycles: [node_id()], depth_exceeded: [node_id()],
        malformed: [node_id()], stale_paths: [node_id()],
        truncated: boolean()
      }
@spec check(prefix :: String.t()) :: {:ok, report()} | {:error, :invalid_schema_name}
@spec analyse([Node.t()]) :: report()        # pure; check/1 = load all rows of prefix + analyse/1
```

Rules (segments = `path` split on `/`, empty ends dropped; parent = second-last segment):

1. `malformed`: path not of the form `/seg/(seg/)*`, or last segment != `node_id`, or `depth != length(segments)`. Excluded from rules 2-4.
2. `cycles`: a path with a repeated segment, or a node lying on a loop when following parent links through existing non-malformed rows (seeded example: A `/B/A/`, B `/A/B/` -> both).
3. `orphans`: not in `cycles`, non-root, parent segment has no row.
4. `stale_paths`: not in 1-3, parent row exists but `parent.path <> node_id <> "/" != path`.
5. `depth_exceeded`: `depth > 12` or `length(segments) > 12` (any row).

Lists sorted ascending, each capped at 1000 ids (`truncated: true` if any cap hit; `counts` are
exact). `status` is `:ok` iff all five counts are 0. Read-only: no write, no lock.

### 6.5 Admin endpoint

| Item | Value |
|---|---|
| Route | `GET /api/v1/tenant/scope-node-paths/consistency` |
| Router | new `Letflow.Routers.TenantScopeNodePaths` (`use Letflow.Api.AuthorizedRouter`), `authz_get "/consistency", :ScopeNodePathsConsistencyRead`, `authz_unmatched(:ordinary)` |
| Mount | `forward("/tenant/scope-node-paths", to: Letflow.Routers.TenantScopeNodePaths)` in `lib/letflow/plugs/api_pipeline.ex`, next to `/tenant/modules` (:150) |
| Authorization | `endpoint_policy_key("GET", "/tenant/scope-node-paths/consistency") -> :ScopeNodePathsConsistencyRead`; `required_permission(:ScopeNodePathsConsistencyRead) -> :UsersGroupsRolesManage`; policy key added to the `endpoint_policy_key()` type. Tenant-scope permission, so the REQ-448 platform-route inventory (24) is unchanged. |
| Tenant | `Keyword.fetch!(conn.assigns.scoped_opts, :prefix)` only; path has no tenant segment; query string and body are never read (INV-1) |
| 200 body | `{"status": "ok"\|"inconsistent", "checked_nodes": N, "max_depth": 12, "counts": {"orphans": n, "cycles": n, "depth_exceeded": n, "malformed": n, "stale_paths": n}, "orphans": [...], "cycles": [...], "depth_exceeded": [...], "malformed": [...], "stale_paths": [...], "truncated": bool}` via `Response.ok/2`. Revision 1, A7: the router builds this body as an explicit string-keyed map field by field from the `report()` (status atom -> `"ok"`/`"inconsistent"`); it never passes the report struct/map through, so a future `report()` key cannot leak into the response |
| Errors | missing permission: existing generic 403; `{:error, :invalid_schema_name}` -> `Response.internal_error/1` |

Node ids only; no record data (INV-2). Another tenant's rows are in another schema (INV-1/INV-5).

## 7. Writer scan: `mix letflow.check_scope_node_paths_writers`

`lib/mix/tasks/letflow.check_scope_node_paths_writers.ex`, `Mix.Tasks.Letflow.CheckScopeNodePathsWriters`,
added to `@check_static_steps` in `mix.exs` right after `"letflow.check_uat_scenario_schema"` (a
non-compiling textual scan, same class as `check_issue_refs`).

```
@type violation :: %{path: String.t(), line: pos_integer(), rule: :table_name | :internal_module, text: String.t()}
@spec run([String.t()]) :: :ok                              # Mix.raise/1 listing violations
@spec scan(roots :: [Path.t()]) :: [violation()]            # default roots: ["lib/letflow/modules", "priv/modules"]
@spec audit(content :: String.t(), path :: String.t()) :: [violation()]
```

Scanned: every regular file under the roots (all extensions: `.ex`, `.exs`, `.json`, `.sql`, `.lua`, ...).

| Rule | Violation when a line matches |
|---|---|
| `:table_name` | `~r/scope_node_paths/i` anywhere (SQL, string, atom, comment) |
| `:internal_module` | `~r/ScopeNodePaths\.[A-Z{]/` (the `Node` schema, `Consistency`, or a multi-alias), so a module cannot `Repo.insert/update/delete` via the schema |

Allowed by construction: `Letflow.ScopeNodePaths.write(`, `.ancestors(`, `.descendants_of(`,
`.like_prefix_pattern(`, `alias Letflow.ScopeNodePaths`. Known limit (stated in the moduledoc):
a string split across concatenation is not caught; REVIEWER and 0050 D8's "no module-side SQL" rule
cover it. Module authors must not name the table even in comments (anti-pattern "a grep-shaped
AC can be tripped by the module's own moduledoc").

## 8. Acceptance-criteria map

| AC | Design sections | Tests |
|---|---|---|
| 1 generic routes | D5, D6, 2.4, 2.8, 3.1, 4 | T-01, T-02, T-03, T-04, T-05, T-06, T-07, T-08 |
| 2 definitions API | D1-D3, D7, 2.4, 2.5, 3.2, 3.5, 4 | T-08, T-09, T-10, T-11, T-12, T-33, T-34, T-35 |
| 3 pack | D3, D5, D8, 2.1, 2.4 (A1 lock), 2.5 (R2 lock order), 2.6 (key-rejection levels), 2.7, 3.3 | T-12, T-13, T-14, T-15, T-16, T-17, T-18, T-19, T-33, T-35 |
| 4 append_only ordering | D6, 3.1, 4 | T-20 |
| 5 writer | D9, D10, 6.2 | T-21, T-22, T-23, T-24, T-25, T-26 |
| 6 writer scan | D12, 7 | T-27 |
| 7 consistency | D11, D12, 6.4, 6.5 | T-28, T-29 |
| 8 reads, INV-7 | 6.3 | T-30 |
| 9 migration | 2.1, 5 | T-31 |
| 10 gates | all | T-32 |

## 9. Test list (for TEST-DESIGNER; ids binding, file placement suggested)

Byte-identity comparisons pin `x-trace-id` (F6). "Six types" = the 0050 foundation names, all
managed by `fixture_managed` installed in the test tenant.

| Id | File | Assertion |
|---|---|---|
| T-01 | `test/letflow/routers/entities_managed_by_test.exs` | POST `/entities/records/<each of six>` as PROCESS_OPERATOR and as TENANT_ADMIN -> 403, body == `Error.entity_type_managed()` serialised; no `entity_record_latest` row |
| T-02 | same | PUT on each of six with (a) an existing record id (created by the owner helper), (b) an absent uuid, (c) a malformed id -> all 403, (a) and (b) bodies byte-identical; record unchanged |
| T-03 | same | DELETE, same three ids -> 403, (a)/(b) byte-identical, record not deleted |
| T-04 | same | POST `/records/<type>/import` with a valid 2-entry batch -> 403; zero records created |
| T-05 | same | bypass: body `"managed_by": "fixture_managed"`, `"module": "fixture_managed"`, header `x-letflow-module: fixture_managed`, query `?module=fixture_managed`, on all four routes -> still 403. Revision 1, B2 order pin: on a managed type, a non-object / malformed JSON body (POST, PUT, import), a body failing schema validation, an import batch over the 200 cap, and a DELETE with `?expected_last_event_global_seq=abc` each get the uniform 403 (not 400/413/422) |
| T-06 | same | owner path: `FixtureManaged.create_record/3` for each of six -> `{:ok, _}`; `update_record/4` -> `{:ok, _}` |
| T-07 | same | control: same four HTTP calls on `fxm_free` -> 201 / 200 / 200 / 200 as before |
| T-08 | same | route coverage: every `{method, path, _}` in `Letflow.Routers.Entities.__authz_routes__()` with method POST/PUT/PATCH/DELETE whose path starts `/records/:entity_type` (excluding `/attachments` and `/export` suffixes) or `/definitions` is in the guarded set {POST /records/:entity_type, PUT and DELETE /records/:entity_type/:record_id, POST /records/:entity_type/import, POST /definitions, POST /definitions/:name/activate} |
| T-09 | same | Revision 1, B1. PROCESS_DESIGNER POST `/entities/definitions` with `"name"` = each of six gets the uniform 403 for: a valid body; a body missing `display_name`/`fields`; a body with an invalid field type; a body with an extra `managed_by` key. `get_active_definition_by_name/2` id and row count by name unchanged after each. Control: an INVALID body with an unmanaged name (`fxm_new`) still gets the existing 422 with its violation list; an invalid body with a non-binary `name` (e.g. `123`) gets 422, not 403 |
| T-10 | same | PROCESS_DESIGNER POST `/definitions/<each of six>/activate` (valid rationale) -> 403; active definition unchanged; no `artifact_activations` change |
| T-11 | same | create a NEW type named `catalog_uom` with a different field set -> 403; no row |
| T-12 | same + `test/letflow/entities/managed_types_test.exs` | POST `/definitions` with `managed_by` key (new unmanaged name; managed name; value null) -> 403, no row; `Repo.update_all` setting `managed_by` to nil or another id on a managed row raises `Postgrex.Error` (trigger); deleting a managed row raises; `EntityDefinition.changeset/2` ignores `:managed_by`; `put_managed_by/2` on a loaded struct gives a changeset error |
| T-13 | `test/letflow/definitions/solution_pack_managed_by_test.exs` | `managed_by` at document top level, entity entry, and inside `definition_json` -> `SolutionPack.install/3` returns `{:error, :invalid_pack_document}`; HTTP `/solution-packs/install` 422 "invalid pack document"; nothing written |
| T-14 | `test/letflow/modules/installs_managed_by_test.exs` | `Installs.install("fixture_managed", ...)` -> every row of the seven managed names has `managed_by == "fixture_managed"`; `fxm_free` row has nil; all eight active |
| T-15 | same | second `Installs.install` -> `{:error, :already_installed}`, stamps unchanged; `SolutionPack.install/4` with `module_owner(FixtureManaged)` and a new shape of `org_unit` -> new row stamped `fixture_managed`; with an `Owner` for another module id -> `{:error, :entity_type_managed}` |
| T-16 | `test/letflow/routers/solution_packs_managed_by_test.exs` | tenant pack (non-module `pack_id`) defining `org_unit` plus one unmanaged type -> 403 uniform; no new `entity_definitions` row under either name; no `solution_pack_installs` row |
| T-17 | same | update-apply with an `incoming_artefacts` entry `artefact_type "entity_definition"`, `artefact_id "org_unit"` -> 403; same with the name only in `content`; no `pack_update_resolutions` row; no new definition version |
| T-18 | `installs_managed_by_test.exs` | tenant first creates its own unmanaged `org_site` definition; installing `fixture_managed` fails `{:error, {:pack_install_failed, {:managed_name_taken, "org_site"}}}`; nothing stamped, nothing installed |
| T-19 | `test/letflow/modules/catalog_test.exs` (extend) + installs test | `Catalog.validate/2` rejects `manages_entity_types` not a list / empty string / duplicate; accepts absent; a manifest declaring a name absent from its pack -> `{:pack_install_failed, {:managed_type_not_in_pack, name}}` |
| T-20 | `entities_managed_by_test.exs` | `fxm_ledger` (managed + append_only): non-owner PUT and DELETE -> 403, body byte-identical to T-02's, and the body text contains neither `append` nor `entity_append_only`; owner `update_record/4` and `delete_record/3` -> `{:error, {:entity_append_only, "fxm_ledger"}}`, which `render_record_command/3` maps to the 422 `Error.entity_append_only()` (status asserted 422 on the struct) |
| T-21 | `test/letflow/scope_node_paths/write_test.exs` | insert root / child / retire happy paths; inside `Repo.transaction`: `Records.create_record` of an `org_unit` record + `write({:insert, ...})`, then `Repo.rollback/1` -> neither the record nor the projection row exists; standalone `write/2` outside a transaction commits |
| T-22 | same | chain r/a/b/c + sibling x; move `a` under `x` -> a, b, c paths start `/r/x/a/`, depths +1, siblings untouched |
| T-23 | same | move `a` under `a` -> `{:error, :cycle}`; move `a` under `c` (grandchild) -> `{:error, :cycle}`; table unchanged |
| T-24 | same | 12-deep chain inserts ok; 13th -> `{:error, :depth_exceeded}`; a move that pushes a subtree past 12 -> `{:error, :depth_exceeded}`, unchanged |
| T-25 | same | `:parent_not_found`, `:parent_retired`, `:node_exists`, `:node_not_found`, `:node_retired`, `:invalid_node_id` ("", "a/b", 65 bytes); a refusal inside a caller transaction leaves it usable (a later insert in the same transaction commits) |
| T-26 | same | inside a caller transaction after `write/2`, `pg_locks` shows a `ShareRowExclusiveLock` on the tenant's `scope_node_paths` relation, held by the caller's backend. Revision 3: `lock!/1` inside a transaction returns `:ok` and shows the same lock; calling it twice, then `write({:insert, ...})`, succeeds (re-entrant); `lock!/1` outside a transaction raises `ArgumentError`; the documented insert sequence (`lock!` -> `create_record` -> `write`) commits, and with a refused `write` (`:parent_not_found`) followed by `Repo.rollback` leaves neither record nor projection row; T-27's allowed fixture also contains `Letflow.ScopeNodePaths.lock!(` and still scans clean |
| T-27 | `test/mix/tasks/letflow.check_scope_node_paths_writers_test.exs` | `scan/1` on the real default roots -> `[]`; on a tmp dir seeded with (a) a `.ex` file doing raw SQL on `scope_node_paths`, (b) `alias Letflow.ScopeNodePaths.Node`, (c) a `.json` naming the table -> one violation each with the right rule; a seeded file using only `Letflow.ScopeNodePaths.write(` -> `[]`; `run/1` raises on violations |
| T-28 | `test/letflow/scope_node_paths/consistency_check_test.exs` (the "mix check test", runs in `mix letflow.check`) | clean tree -> `status: :ok`; raw-seeded (insert_all in the test) orphan -> in `orphans`; A/B cycle -> both in `cycles`; 13-deep consistent chain -> deepest in `depth_exceeded`; each `status: :inconsistent`; `analyse/1` unit cases for `malformed` and `stale_paths` |
| T-29 | `test/letflow/routers/tenant_scope_node_paths_test.exs` | TENANT_ADMIN 200 on clean data with the documented shape; each seeded defect reported; PROCESS_DESIGNER and PROCESS_OPERATOR -> 403; `?tenant=<other slug>` / `?prefix=` ignored; tenant B's seeded orphan never in tenant A's response; rows unchanged after the call; POST to the path -> not 200 |
| T-30 | `test/letflow/scope_node_paths/read_test.exs` | `ancestors/2` root-first, excludes self; `descendants_of/2` includes inputs, unions two subtrees, ignores unknown ids, `[]` -> `[]`, 501 ids -> `:too_many_nodes`; nodes `a%` and `ab` (each with a child): `descendants_of(["a%"])` excludes `ab`'s subtree; `a_` vs `ax` likewise; `like_prefix_pattern/1` unit cases incl. backslash |
| T-31 | `test/letflow/scope_node_paths/migration_test.exs` | in a fresh tenant schema: up, insert rows, down (table gone), up again; `pg_indexes` has `scope_node_paths_pkey` with `(node_id)` and `scope_node_paths_path_pattern_idx` whose `indexdef` contains `text_pattern_ops`; managed_by migration up/down on a schema with definitions (column, index, triggers present then absent) |
| T-32 | TEST-RUNNER / RELEASE-VALIDATOR | AC10 commands, real output quoted. `test/letflow/routers/entities_managed_by_test.exs` and `solution_packs_managed_by_test.exs` fall within AC10's `test/letflow/routers/entities*` / `solution_packs*` globs |
| T-33 | `test/letflow/entities/managed_types_test.exs` | Revision 1, A1/A4/A6/A9. Inside a test transaction after `create_definition/3` for name `org_unit`, `pg_locks` shows an `advisory` lock with `classid = 496001`, `objsubid = 2`, held by the backend; `owner_of/2` and `check_tenant_write/2` on `"Org Unit"`, `"a%"`, a 65-char name return `:unmanaged` / `:ok` and issue no query (`Ecto` telemetry `[:letflow, :repo, :query]` handler counts 0); `check_create/3` with a plain map `%{module_id: "fixture_managed", manages: ...}` raises `FunctionClauseError`; `Repo.update_all` changing `name` or `tenant_id` of a stamped row raises (trigger), while changing `status` of it succeeds |
| T-35 | `test/letflow/entities/definitions_test.exs:272-295` (CHANGED, Revision 2) | duplicate name + shape: still `{:error, {:persistence, changeset}}` with `name: ["has already been taken"]`, one `EntityDefinition`, and now exactly ONE `ArtifactVersion` (was 2). Plus, in `managed_types_test.exs` (T-33 extension): inside a test transaction, `ManagedTypes.lock_names(["b_type", "a_type", "b_type", "Bad Name"], prefix)` returns `:ok` and `pg_locks` shows exactly two advisory locks with classid 496001 held by the backend; inside a test transaction, `SolutionPack.install/3` of a pack defining `b_type` and `a_type` succeeds and afterwards both locks are held. `entities_test.exs:784-794` (409) and `solution_pack_test.exs:574-590` pass unchanged |
| T-34 | `test/letflow/entities/managed_types_callers_test.exs` | Revision 1, CDV. Textual scan of `lib/**/*.ex`: files containing `module_owner(` are exactly `lib/letflow/entities/managed_types.ex` and `lib/letflow/modules/installs.ex`; `%Owner{` / `%Letflow.Entities.ManagedTypes.Owner{` occurs only in `managed_types.ex` |

## 10. Cross-module dependencies and files touched

New: `lib/letflow/entities/managed_types.ex`, `lib/letflow/scope_node_paths.ex`,
`lib/letflow/scope_node_paths/node.ex`, `lib/letflow/scope_node_paths/consistency.ex`,
`lib/letflow/routers/tenant_scope_node_paths.ex`, `lib/mix/tasks/letflow.check_scope_node_paths_writers.ex`,
two migrations, `test/support/modules/fixture_managed/fixture_managed.ex`,
`priv/module_fixtures/managed_foundation.json`.
Changed: `entities/entity_definition.ex`, `entities/definitions.ex`, `definitions/solution_pack.ex`,
`modules/installs.ex`, `modules/module.ex` (type only), `modules/catalog.ex`, `api/error.ex`,
`api/authorization.ex`, `plugs/api_pipeline.ex`, `routers/entities.ex`, `routers/solution_packs.ex`,
`tenant_provisioning.ex` (manifest), `mix.exs`, `config/test.exs`, `test/support/tenant_fixture.ex`.
`Records` unchanged. Boundary: core never names a concrete module (`Installs` passes the Catalog
entry module); `check_boundaries` unaffected.

## 11. Invariants

* I1 A tenant request can never create, activate or write records of a managed name; only code
  holding an `Owner` built from a compiled manifest can create versions of it (D5).
* I2 `managed_by` never changes after insert and a managed row is never deleted (DB trigger, D3).
* I3 The 403 is decided before `Records`, and its body is constant (D6, D7).
* I4 `scope_node_paths` has exactly one writer, `Letflow.ScopeNodePaths.write/2`; module code never
  names the table or its schema (D9, section 7).
* I5 Every row written by `write/2` has `depth <= 12`, a path ending in its own id, an existing
  non-retired parent at insert/move time, and no cycle; writers of one tenant are serialised (D10).
* I6 Every LIKE pattern is built by `like_prefix_pattern/1` and passed as a bound parameter (INV-7).

## 12. Open questions (each with the default ELIXIR-DEV builds unless a gate overrules)

* OQ-1 Migration versions `20261014000001` / `20261014000002`: re-check `origin/main` and open PRs
  (#2533, 0053 7b) for a collision before committing. Default: these two.
* OQ-2 Squatting: a tenant can create a name a REGISTERED but not-installed module declares, which
  then blocks that module's install (0052 D6 / T-18). AC says "any installed module". Default (superseded by GH #2581: a first creation of such a name is now refused with `entity_type_managed` while the module is not installed in the tenant; this procedure remains for squats that pre-date it): not
  refused at create time. Revision 1, A2, operator recovery: there is no API to delete or rename an
  entity definition, so recovery is a manual, platform-operator procedure inside that one tenant's
  schema, recorded in an issue with the tenant's consent: (1) confirm the squat
  (`GET /api/v1/entities/definitions/by-name/<name>` returns a row with no stamp, and the module
  install answers 422 "module installation failed" with `managed_name_taken` in the server log);
  (2) if the type holds records the tenant wants, export them first
  (`POST /entities/records/<name>/export`); (3) in ONE transaction in the tenant schema, delete the
  unmanaged `entity_definitions` rows of that name, its `artifact_activations` pointer and any
  promoted per-type table (the `repository_artifacts` / `artifact_versions` rows are immutable and
  stay as harmless history); the managed_by trigger does not block this because the rows are
  unstamped; (4) install the module; (5) re-import records only if they fit the module's shape.
  A tooled, audited path is a follow-up issue (not filed by this design).
* OQ-3 Attachment routes (`POST/DELETE /records/:entity_type/:record_id/attachments...`) on a managed
  type: default NOT locked (record fields are unaffected); revisit in the org/catalog_items requirements.
* OQ-4 `RecordDeadlineSweep` (F11) and other core `Records` callers can write managed types; operator
  config only, not tenant-reachable. Default: unchanged; the general engine-path lock is REQ-484 / 0053 hook 2.
* OQ-5 Auditing of tree changes (0050 D7 last bullet, 0051 D8): default the `org` module (REQ-495)
  audits; `write/2` does not.
* OQ-6 Fixture names collide with the future real `org` / `catalog_items` modules in the test env
  (both registered, same managed names). Default: fine per tenant; the requirement adding the real
  modules renames or retires `fixture_managed`'s types.
* OQ-7 `definition_map` responses do not expose `managed_by` (SPA could hide edit buttons). Default:
  not exposed in this requirement.
* OQ-8 `SolutionPack.export` of a managed type produces a pack without the stamp; importing it into a
  tenant where the module is installed is refused (T-16), elsewhere it creates an unmanaged type.
  Default: export unchanged.
* OQ-9 Retiring a node with non-retired children is allowed by `write/2`; the org module decides its
  own policy. Default: no core check.
* OQ-10 AC4's "owner gets the 422" is proven at the domain level plus the existing renderer mapping
  (T-20), not through an owner HTTP route (no fixture router, to avoid permission-count churn).
  Default: as designed; a gate may require a fixture route.

## Amendment 2026-10-16 (GH #2596): D3 has ONE documented exception

D3 says the stamp is written only at INSERT. GH #2596 adds a single exception: the platform stamp of the exam module's six frozen runtime type names (`certificate`, `session`, `session_answer`, `session_event`, `session_question`, `session_question_score`), NULL to `'exam'` only, written by `Letflow.Entities.ManagedTypes.Stamp` inside a transaction that sets the transaction-local `letflow.managed_by_stamp` setting, with the row otherwise unchanged. It is opened in the database by the tenant migration `20261016120001_allow_exam_managed_by_stamp.exs` (see its header) and nowhere else; the tenant and definitions APIs still cannot stamp or unstamp. The earlier "all 16 exam types" wording is superseded by the supervisor ruling of 2026-10-16: the ten authoring types stay unmanaged. Design: `lib/letflow/design/gh2596-exam-managed-types.md`.
