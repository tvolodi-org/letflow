# GH #2590 / REQ-501: module write handlers for managed entity types (decision 0054 D4 option A, D6)

Author: CODE-DESIGNER, 2026-10-16. Branch `design/GH-2590-module-write-handlers`, from `origin/main`
`ac9f6c13` ("feat(GH #2627): %StepSource{} struct ...", #2649). Merged on main and relied on:
REQ-499 PR A, #2621, #2623, PR B1, B2, B3, C0 (`%StepSource{}`), #2583 (typed write authority,
`4242547e` via #2599) and #2550. NOT merged: REQ-499 PR C2 (service-task apply) and C1 (service-task
activation); their design (`gh2587-req499-pr-c-service-task-writes.md`, branch
`design/GH-2587-pr-c`, rulings binding) is the composition target of section 4.6 and PR R5.

Design only. Signatures, type shapes, step lists, tables and test briefs; no function bodies.

## Changelog

### Revision 0 (2026-10-16): first design

Supervisor correction applied before the first draft: GH #2583 is CLOSED (merged `4242547e`); section 7
builds on its typed authority (`:tenant | %Owner{}`, `owner_for!/1`, `check_write_authority/3`, the
static caller scan) and does not fold or redo it. The `@authority_callers` allow-list (and the exam
files) belong to #2596: section 7.5 states the single one-line edit this design needs there and why.

## 1. Summary, sizing and proposed split

### 1.1 What REQ-501 delivers

A module M (compiled into the build, listed in `config :letflow, :modules`) declares write handlers
in its manifest. A process definition VERSION that the module's install stamped with
`owner_module = M` may declare, on a HUMAN_TASK node, `module_writes` lines naming M's handlers. At
completion the handler runs INSIDE the step transaction, appends Multi steps that write only M's
registered target types through `Records.command_multi/3` with an `%Owner{}` authority the PLATFORM
builds from the Catalog-resolved registration (never request data, never the handler's choice). The
completer stays the event actor; the activator stays provenance. A managed type is still never the
target of a declarative `entity_writes` line (REQ-499 refuses every one).

### 1.2 Size: cannot be one PR

Six serial PRs, each independently mergeable and reviewed, none leaving a half-open door:

| PR | Content | Independent value | Depends on |
|---|---|---|---|
| **R1** | Catalog: `:write_handlers` manifest key, `validate/2` rule 10, `Catalog.write_handler/2`, `Catalog.manifest_hash/1`, `ManifestHash`, `WriteHandler` struct, `call_write_handler/4`; `Module` typedoc | Mechanism and its validation exist and are tested; nothing can call a handler yet (no execution path); manifests are hash-able | main |
| **R2** | Stamp STORAGE: two tenant migrations (`process_definitions.owner_*`, `tenant_modules.manifest_hash`) + TenantProvisioning entries; `Owner` gains `version`/`manifest_hash`; `Installs` stamps pack definitions via `Definitions.create_owned/3`; API refusal of the fields (POST/PUT/PATCH/import/export); stamped-row immutability; DB trigger; forge tests | Stamp can exist only by install and cannot be forged or edited; no consumer yet | R1 |
| **R3** | Declaration + ACTIVATION: node attribute `module_writes`, `EntityPort.validate_module_writes/2` and `authorize_module_writes/2`, activation checks on the three paths (stamp, line shape, hash), `activated_by` extension, PinRebind guard | A definition that cannot legitimately call a handler is refused at activation; a legitimate one activates but its handler lines are NOT executed (fail-closed guard refuses a completion, see 6.1) | R2 |
| **R4a** | Entities core: `StepSource` `handler`/`write_ordinal`, `Records` line-key derivation, `EventStore` lock-only primitive, `ManagedTypes.owner_for_handler/2`, `HandlerContext`, `HandlerWrites` (create/step/lock/recheck), the handler contract and its static scans, fixture module | The write path is complete and unit-testable below the engine; engine still refuses | R3 |
| **R4b** | Engine HUMAN_TASK integration: plan phase, `prepare/2` extension, `multi/3` composition, failure mapping, audit/event shape, replay/atomicity/lock-order/contention tests, EE-12 moduledoc | First end-to-end handler write from a process | R4a |
| **R5** | SERVICE_TASK composition AFTER PR C2/C1: plan carries `module_writes`/`owner`, activation fence opens for `module_writes` on SERVICE_TASK, platform-actor tests | Same handlers from a service result | R4b, C2, C1 |

R1 and R2 can be built while PR C0/C2 are in flight (no shared file except `step_source.ex`, which
R1-R3 do not touch). R4a edits `step_source.ex`: it merges after C0 (already on main) and must be
rebased over C2 only if C2 touches `step_source.ex` (it does not, per PR C section 13).
Merge order is serial (one functional PR in CI at a time): R1 -> R2 -> R3 -> R4a -> R4b -> (C2, C1 per
their own order) -> R5. WMS slice 5 needs R4b plus a separate update-kind prerequisite (OQ-R4).

## 2. Sources and verification (all on `main` `ac9f6c13`)

| # | Claim | Source |
|---|---|---|
| S1 | Catalog is a plain module over `Application.compile_env(:letflow, :modules, [])`; API `entry_modules/0`, `fetch/1` (by manifest id string), `module_pack_ids/0`, `permissions/0`, `role_grants/1`, `validate/1,2`, `all_manifests/0`; `validate/2` runs 9 rules, last is rule 9 | `modules/catalog.ex:49,60,64,167-181` |
| S2 | `manifest()` type has optional `:manages_entity_types`, `:widens_grants`; `defmanifest/1` evaluates the keyword literal with `Code.eval_quoted` and `Macro.escape`s the map (a `{Mod, :fun}` tuple of aliases survives, a function capture would not) | `modules/module.ex:74-84,179-193` |
| S3 | `ManagedTypes`: `%Owner{module_id, manages}` built only in `managed_types.ex`; `module_owner/1` (callers: managed_types.ex, installs.ex); `owner_for!/1` (raises unless entry module is a Catalog entry module with managed types); `check_record_write/3`: a managed type is writable only by an Owner whose `module_id` equals the stamp AND whose `manages` names the type; an UNMANAGED type (`nil`) is writable by ANY authority | `entities/managed_types.ex:90-100,117-150,152-195` |
| S4 | `Records.command_multi(command, prefix, authority)`: authority guard `is_authority/1`, `check_write_authority/3` after the active definition read and again in `:recheck_definition`; only `kind: :create`; line key = `source.line_index` (`line_key: source.line_index`, `records.ex:714`); key = `StepSource.idempotency_key/1`; event metadata = `StepSource.to_metadata/1` | `entities/records.ex:546-600,659-680,1416-1423` |
| S5 | `%StepSource{}` closed 9 fields; `new/1` closed atom key set; `to_metadata/1` emits exactly 8 flat `source.*` keys; `idempotency_key/1` = `sys:step:<origin id>:<line_index>` | `entities/step_source.ex:1-170` |
| S6 | `StepWrites.multi/3`: lines built in one `Multi.merge`, sorted `(entity_type, index)`, per line deadline guard (10 s), `Records.command_multi(command, prefix, :tenant)` with the LITERAL `:tenant`, `:process_policy` step, closing `:entity_writes` step; `prepare/2` creates synthetic instances only for process-writable types, one short transaction, `SET LOCAL` 2 s/2 s; `interpret_failure/2` | `entities/step_writes.ex:100-160,465-640,696-734` |
| S7 | Engine: `plan_entity_writes/3` (P0) matches only `attributes["entity_writes"]`; `resolve_entity_plan/4` does cap, activator (`recorded_activator/1`, `check_activator_active/2`), `prepare/2`; `maybe_entity_writes/4` builds the port `multi_ctx`; `check_entity_writes_planned/3` fail-closed matches only `"entity_writes"`; `run_transaction/2` maps contention only with a plan; tail: `append_entity_write_audits`, `append_sys_variables_event`, `append_entity_writes_applied_event`; failed `{:line,_,_}` routed to `EntityPort.impl().interpret_failure/2` | `engine.ex:2813-2900,2932-2970,3024-3150,5336-5346,6921-7060` |
| S8 | `EntityPort` callbacks: `prefetch/3`, `prepare/2`, `validate_lines/2`, `multi/3`, `interpret_failure/2`; `impl/0` reads `config :letflow, :entity_port`; Rule 6 forbids engine -> entities DIRECT file edges | `engine/entity_port.ex`, `mix/tasks/letflow.check_boundaries.ex:26-58` |
| S9 | `process_definitions` schema: `activated_by :map` (never cast); `create_changeset` casts `[:name,:version,:description,:stage,:graph,:created_by]`, `update_changeset` the same minus `created_by`; no `owner_*` field anywhere | `definitions/process_definition.ex:120-170` |
| S10 | Activation: `run_activate_transaction/5` calls `check_entity_writes(definition, prefix, activator)` (`definitions.ex:2368`); rollback swap calls it (`:3024`); promotion apply calls it (`promotion.ex:427`); `entity_writes_activated_by/3` builds the document (`:2527`); `entity_write_nodes/1` selects nodes with `attributes["entity_writes"]` | `definitions.ex:2347-2380,2449-2560,3024-3060`, `definitions/promotion.ex:422-427,531-533` |
| S11 | A pack's `definitions` are created by `SolutionPack.create_packed_definitions/3` through `Definitions.create(attrs, opts)` (the same function as POST), as drafts; `SolutionPack.install/4` threads an Owner only to entity definitions | `definitions/solution_pack.ex:486-516,1414-1435,1505-1525` |
| S12 | `Installs.install/3`: `owner = ManagedTypes.module_owner(entry_module)`, one `Repo.transaction`, `maybe_install_pack/4`, `insert_tenant_module/2` (stores `module_id`, `version`, `installed_at`, `settings` only) | `modules/installs.ex:96-135,237-290`; `20260925000001_create_tenant_modules.exs` |
| S13 | `PinRebind.rebind_pins/3` rebinds PIN entries of kind `catalog_entry | module | variable_schema` (`:script` is never rebindable); `:module` is the SUB_PROCESS `module_ref` pin, NOT a platform module and NOT the instance's definition. It never reads or writes `instance_projections.definition_id`. The engine consumes `:script` and `:catalog_entry` pins only (`pin_for` at `engine.ex:1251,1287`); no `:module` pin consumer exists | `engine/pin_rebind.ex:163,329-376,415-440`; `engine/pin_resolver.ex:64-65,191,356-362,690-720` |
| S14 | Snapshots: `instance_definition_snapshots` holds `definition_id`, `definition_name`, `definition_ver`, `graph` (the pinned copy the engine executes); `fetch_graph/2` reads it | `definitions/instance_definition_snapshot.ex:95-103`; `engine.ex:3316-3322` |
| S15 | Boundary rules: Rule 1 only `catalog.ex` may reference files under `lib/letflow/modules/<id>/`; Rule 6 engine may not reference `lib/letflow/entities/**`; EE-12 moduledoc enumerates the engine locks | `mix/tasks/letflow.check_boundaries.ex`; `engine.ex:285-410` |
| S16 | Static caller scans: `managed_types_callers_test.exs` R1 asserts `r1_files(files) == @authority_callers` (EQUALITY, currently `[@fixture_managed]`), R2 `owner_for!` only `__MODULE__`/own directory, R3 `module_owner` only managed_types.ex and installs.ex, R4 Owner built only in managed_types.ex, R5 `SolutionPack.install/4` non-tenant owner only in installs.ex; `command_multi_callers_test.exs` `@command_multi_callers [@step_writes]`; `step_source_callers_test.exs` `@new_callers [@records, @step_writes]` | `test/letflow/entities/*_callers_test.exs` |
| S17 | Test registration: `config/test.exs` lists the fixture entry modules (Exam, Fixture, FixtureDependent, FixtureFailingInstall, FixtureFkPack(+Failing), FixtureCtxRecorder, FixtureManaged, FixtureManagedNoPack); `FixtureManaged` is the owner-path fixture (`owner_for!(__MODULE__)`) | `config/test.exs:296-310`; `test/support/modules/fixture_managed/fixture_managed.ex` |
| S18 | `EventStore.append_multi` step order per line: `active_instance_guard` (unlocked read), `assign_sequence` (insert-if-absent then `FOR UPDATE` on the type's `instance_sequences` row, then increment), `idempotency`, `insert_event`, `update_projection`. A writer therefore always takes the SEQUENCE row before the projection row | `event_store.ex:597-625,700-735` |

### 2.1 Findings that change or sharpen the issue

| Id | Finding | Consequence |
|---|---|---|
| **F-R1** | The issue's "NOT FOUND" list is stale: `EntityPort`, `StepWrites`, `command_multi`, `write_not_permitted`, `StepSource`, `activated_by`, the typed authority and `owner_for!` all exist. `owner_module` and every stamp column are still NOT FOUND. | This design builds on them (sections 4, 7). |
| **F-R2** | #2583 is merged: `Records.*` already refuses a managed type unless the authority is that module's `%Owner{}` naming the type. The only gap is the unmanaged branch (S3): an `%Owner{}` may write ANY unmanaged type, so "a handler cannot write an unmanaged type that lacks `writable_by_process`" is NOT given by the authority check. | `HandlerWrites` refuses any write whose type is not in the handler's registered targets BEFORE `command_multi` (D-R.9), and narrows the Owner's `manages` to those targets as a second layer. |
| **F-R3** | PinRebind cannot move an instance to another definition version, and its `:module` kind is the sub-process reference pin. 0054 D6 property 4 (written against a different mental model) has no direct operation to guard. | Section 4.9 / D-R.14: the rule becomes a fail-closed structural guard on `:module` entries plus a regression test pinning "PinRebind cannot change `definition_id`". Flagged OQ-R1. |
| **F-R4** | The `defmanifest` macro `Macro.escape`s the evaluated map, so a handler MFA must be `{Module, :fun}` data; the handler module lives under `lib/letflow/modules/<id>/` where Rule 1 lets ONLY `catalog.ex` reference it as a file edge. | The call goes through `Catalog.call_write_handler/4` (an `apply/3` on registered data): no file edge from entities or engine to a module file. |
| **F-R5** | `command_multi/3` supports only `kind: :create`. A ledger handler that must update a balance or enforce "no negative stock under lock" needs update support. | REQ-501 ships create-only handler writes (inherits REQ-499 MVP); update-kind is a separate prerequisite of WMS slice 5 (OQ-R4). The mechanism, lock order and stamp are complete without it. |
| **F-R6** | `plan_entity_writes/3` and `check_entity_writes_planned/3` match only the `"entity_writes"` attribute. A node with only `module_writes` would today run with NO plan and NO fail-closed guard. | R3 must extend `check_entity_writes_planned/3` in the same PR that lets such a graph activate (section 6.1); otherwise an activated module-writes graph would silently skip its writes. |
| **F-R7** | `prepare/2` skips types that are not process-writable, and a managed type can never be (D4a.2(b)); `command_multi` never inserts the synthetic instance. | `prepare/2` ctx gains `module_writes`/`owner`; the impl creates instances for the REGISTERED targets of a verified handler (4.5). |
| **F-R8** | `check_record_write(nil, ...)` makes the Owner a universal key for unmanaged types, and `managed_types_callers_test` R1 pins the Owner-passing callers by EQUALITY. A new Owner-passing file is a closed-set change in a test #2596 owns. | One-line allow-list entry, called out in 7.5; all new scan rules live in a NEW test file so #2596's file otherwise stays untouched. |
| **F-R9** | `source.*` metadata is 8 flat keys; a handler write needs the module id, handler name and a per-write ordinal for the idempotency key and namespace uniqueness (`{:line, key}` must be unique per write). | `StepSource` gains optional `handler` + `write_ordinal`; declarative lines stay byte-identical (4.4). |

## 3. Decisions (one-line rationale each)

* **D-R.1 Registration is manifest data, resolved only by `Catalog`.** A closed `:write_handlers` list of maps `{name, function: {Mod, :fun}, targets, args}`; the Catalog is the single resolver and the single `apply` site, so no engine/entities file names a module file (Rule 1, F-R4). Rationale: 0039 D3, issue scope 1.
* **D-R.2 Resolution is string comparison over the compiled list.** `write_handler(module_id, name)` compares binaries with manifest values (`fetch/1` precedent); non-binaries answer `:not_found`; no `String.to_atom`, `Module.concat`, `binary_to_term` on request data. Rationale: threat list "no string -> atom".
* **D-R.3 Handler MFA must live in the registering module's own namespace.** Validation refuses a handler whose module is not the entry module or nested under it. Rationale: a manifest cannot point at `Letflow.Repo` or another module's code.
* **D-R.4 The handler contract is `fun(multi, ctx, args) :: {:ok, multi} | {:error, closed_atom}`.** It receives a fresh Multi, an opaque `HandlerContext`, and resolved args only (no instance variables). Rationale: least privilege; closed error vocabulary cannot leak detail (INV-4/5).
* **D-R.5 The handler never touches `Records`, `Repo`, `Owner` or `StepSource`.** It writes through `HandlerWrites.create/3` and `HandlerWrites.step/4` (section 4.6). The platform derives source, key, authority, namespace. Rationale: the owner path is "identified by the caller" = the platform, not module code (7.2); a handler cannot supply or override a key (AC).
* **D-R.6 `module_writes` is a node attribute of its own, not a line kind inside `entity_writes`.** B's `entity_writes` line schema is closed (`@line_keys`, `op` create-only, `entity_write_*` codes); REQ-499 refuses every managed-type line there. A separate attribute leaves declarative bytes, hashes, caps' semantics and `activated_by` pairs untouched. Rationale: byte-identity (F-R9), smaller diff. Flagged OQ-R5.
* **D-R.7 Engine orders the type locks; the handler cannot reorder them.** For a node with `module_writes` the port impl emits one lock step per type in the ASCENDING union of declarative line types and registered handler targets BEFORE any write step (6.2). Rationale: 0054 D3 rule 4 for opaque code.
* **D-R.8 The stamp is four columns on the version row; the install hash lives on `tenant_modules`.** `owner_module`, `owner_module_version`, `owner_manifest_hash` (compared to `tenant_modules.manifest_hash` and, strictly, to the current compiled manifest), `owner_body_hash` (canonical hash of the definition graph at stamping, compared to the pinned snapshot at run time). Rationale: ruling "hash lives on the version row beside owner_module"; the body hash is what makes "verified at run time from the pinned snapshot" bite a hand-edited snapshot (S14). Flagged OQ-R2.
* **D-R.9 Writes outside the registered targets are refused in the writer, before `command_multi`.** Plus the Owner is narrowed to the targets. Rationale: F-R2.
* **D-R.10 Owner for a handler is built by `ManagedTypes.owner_for_handler/2` from a `WriteHandler` the Catalog resolved.** `owner_for!` stays for a module's own files; a platform file may not call it with a variable (R2). Rationale: section 7.
* **D-R.11 Handler writes carry `%StepSource{}` with `handler` and `write_ordinal`.** Idempotency key `sys:step:<origin>:<line_index>:<ordinal>`, namespace key `20 + line_index*50 + ordinal`, metadata +3 keys only when set. Rationale: F-R9, PR C D-C.16(a)(c).
* **D-R.12 Declarative lines run first (sorted), then handler calls in declared order.** All type locks are already held (D-R.7). Rationale: deterministic, one result, one hash.
* **D-R.13 The completer is the actor and the field-restriction subject on the HUMAN path; the platform sentinel is the actor and the activator the subject on the service path.** Same `multi_ctx` fields PR C introduces (`origin`, `actor_id`, `subject_id`). Rationale: D4c, 0054 D4.
* **D-R.14 PinRebind refuses `:module` entries for an instance whose pinned definition is stamped.** Fail-closed until PLC-01 gives module pins a resolver; plus a pin test that no rebind can change `definition_id`. Flagged OQ-R1.
* **D-R.15 A module-owned version is immutable to the tenant API.** `update/3` of a stamped row is refused; the DB trigger refuses a raw change of `owner_*` or `graph` on a stamped row. Rationale: 0054 D6 property 2; precedent `managed_by` trigger (0050 D3).
* **D-R.16 Activation requires the same activator authority as declarative lines.** A graph with `module_writes` records `activated_by` through the existing function (pairs possibly empty, plus an additive `"module_handlers"` list) and needs `:EntitiesRecordsWrite` + an active user. Rationale: reuse `recorded_activator/1` unchanged. Flagged OQ-R6.
* **D-R.17 Handler writes are create-only.** F-R5 / OQ-R4.
* **D-R.18 No handler on the script paths.** A script output is never a command (0053/0054 D2); `module_writes` is refused on any node type other than HUMAN_TASK until PR C1/R5 admits SERVICE_TASK. Rationale: scope.
* **D-R.19 Replay never runs a handler.** No handler call site exists outside the completion Multi build; a test double fails the test if invoked (AC).

## 4. Interfaces, specs and shapes (no bodies)

### 4.1 `Letflow.Modules.Module` and `Letflow.Modules.Catalog` (R1)

Manifest addition (optional key; absent means `[]`):

```
@type write_handler_spec :: %{
        required(:name) => String.t(),                 # ^[a-z][a-z0-9_]{0,63}$
        required(:function) => {module(), atom()},     # exported arity 3
        required(:targets) => [String.t()],            # non-empty, each in manages_entity_types
        required(:args) => %{String.t() => %{kind: :value | :sys_ref, required: boolean()}}
      }
optional(:write_handlers) => [write_handler_spec()]
```

`Catalog.validate/2` gains rule 10, run after rule 9, first failure returned, `{:error, {atom, term}}`:

| Condition | Error |
|---|---|
| `:write_handlers` present but not a list of maps with exactly the four keys, a name outside the format, `targets` not a list of binaries, `args` malformed | `{:invalid_write_handlers, value}` |
| two entries with the same `name` | `{:duplicate_write_handler, name}` |
| handlers declared and `manifest.id` outside `^[a-z][a-z0-9_]{0,63}$` (metadata value, 4.4) | `{:invalid_module_id_for_handlers, id}` |
| handlers declared and no `:manages_entity_types` (absent or `[]`) | `{:write_handler_without_managed_types, name}` |
| `targets == []` | `{:write_handler_no_targets, name}` |
| a target not in the SAME manifest's `manages_entity_types` | `{:write_handler_target_not_managed, name, target}` |
| handler module is neither the entry module nor nested under its namespace | `{:write_handler_outside_module, name}` |
| `Code.ensure_loaded?(mod)` false or `function_exported?(mod, fun, 3)` false | `{:write_handler_function_not_exported, name}` |

New functions (Catalog is the only file that resolves or calls a handler):

```
@spec write_handler(module_id :: term(), name :: term()) ::
        {:ok, WriteHandler.t()} | {:error, :not_found}
@spec call_write_handler(WriteHandler.t(), Ecto.Multi.t(), ctx :: struct(), args :: %{String.t() => term()}) ::
        term()                      # the raw handler return; the caller validates the shape
@spec manifest_hash(entry_module :: module() | module_id :: String.t()) ::
        {:ok, String.t()} | {:error, :not_found}
```

```
%Letflow.Modules.Catalog.WriteHandler{      # built only in catalog.ex (scan H2)
  module_id: String.t(), name: String.t(),
  entry_module: module(), function: {module(), atom()},
  targets: [String.t()],                    # sorted, unique
  args: %{String.t() => %{kind: :value | :sys_ref, required: boolean()}}
}
```

`call_write_handler/4` is an `apply/3` on the registered data of a `WriteHandler` it just built; it
is the only `apply` of handler code. `Letflow.Modules.ManifestHash` (R1, one file, pure):

```
@spec compute(Module.manifest()) :: String.t()     # lowercase hex SHA-256
```

Hashed surface, canonical JSON with sorted object keys (the `PromotionDigest.canonicalize/1`
algorithm: keys sorted, arrays keep order, atoms by `Atom.to_string/1`, tuples as lists): `id`,
`version`, sorted `manages_entity_types`, and per handler (sorted by name) `name`,
`inspect(module)`, function name, sorted `targets`, `args`. It does NOT cover permissions, routes,
settings, pack content or handler CODE: a change of handler behaviour without a manifest change is
not detected; the discipline is "bump `version` when handler code changes" (stated in the
`Module` moduledoc, OQ-R3 note). The hash is a function of the compiled manifest only (no clock,
no environment).

### 4.2 `Letflow.Definitions.OwnerStamp` (R2, pure)

```
@type t :: %{module_id: String.t(), module_version: String.t(),
             manifest_hash: String.t(), body_hash: String.t()}
@spec graph_hash(graph_map :: map()) :: String.t()        # canonical SHA-256 of the definition graph
@spec from_row(row :: map()) :: {:ok, t()} | :none        # all four present, else :none
```

`graph_hash/1` canonicalizes the persisted `graph` map exactly as `PromotionDigest` does
(NOT the numeric-normalising `Repository.Canonicaliser`; the two must not be merged, per that
module's moduledoc). The same function hashes the PINNED snapshot graph at run time.

### 4.3 `Letflow.Entities.ManagedTypes` (R2, R4a)

```
%Owner{ module_id: String.t(), manages: MapSet.t(String.t()),
        version: String.t() | nil, manifest_hash: String.t() | nil }     # R2: two nil-default fields
```

`module_owner/1` (callers unchanged: managed_types.ex, installs.ex; scan R3) fills `version` and
`manifest_hash` from `manifest()` and `Catalog.manifest_hash/1`. The two fields exist so the
EXISTING `SolutionPack.install/4` owner argument (scan R5: only `installs.ex`) carries the stamp
inputs without a new arity. Every existing `Owner` pattern match is unaffected.

R4a adds the platform-side builder (the only new Owner-producing function):

```
@spec owner_for_handler(module_id :: term(), handler_name :: term()) ::
        {:ok, Owner.t()} | {:error, :unknown_handler}
```

It re-resolves `Catalog.write_handler(module_id, handler_name)` itself (so a forged
`WriteHandler` cannot reach it) and returns `%Owner{module_id, manages: MapSet.new(handler.targets)}`
(narrowed to the handler's targets, `version`/`manifest_hash` nil). Callers: `managed_types.ex` and
`handler_writes.ex` only (scan H1, 7.4).

### 4.4 `StepSource`, `Records`, `EventStore` (R4a)

```
# new optional fields; nil for every declarative line
handler: nil | %{module_id: String.t(), name: String.t()}
write_ordinal: nil | 1..49
@spec line_key(t()) :: non_neg_integer()
```

`new/1`: closed key set gains `:handler` and `:write_ordinal`, which are both-or-neither; each of
`module_id`/`name` matches `^[a-z][a-z0-9_]{0,63}$`. A foreign shape is `{:error, :invalid_step_source}`.

| Function | nil `write_ordinal` (declarative) | set |
|---|---|---|
| `line_key/1` | `line_index` | `20 + line_index * 50 + write_ordinal` |
| `idempotency_key/1` | `sys:step:<id>:<line_index>` (unchanged) | `sys:step:<id>:<line_index>:<ordinal>` |
| `to_metadata/1` | the 8 existing keys, byte-identical | + `source.handler_module`, `source.handler_name`, `source.write_ordinal` (decimal string) |

The key stays inside `\Asys:step:[A-Za-z0-9:_.-]+\z` and 255 bytes (closed charset of 0054 D9.2).
The namespace key range is disjoint from declarative indexes (`0..19`); ordinal `0` of each call is
reserved for call-level steps (4.6). `Records.command_multi/3`'s only edit: `line_key:
source.line_index` becomes `StepSource.line_key(source)` (S4). `interpret_in_multi/1` reports the
KEY; `StepWrites`/`HandlerWrites.interpret_failure` maps a key `>= 20` back to
`div(key - 20, 50)` (the call's `line_index`) so the public `line_index` is always the declared
index. PR C's test C-18 ("`StepSource` accepts no `handler` key") is edited in R4a to its negation.

`EventStore` gains one lock-only primitive (R4a, one function plus its test):

```
@spec lock_instance_sequence(repo :: Ecto.Repo.t(), instance_id :: Ecto.UUID.t(), prefix :: String.t()) ::
        {:ok, :locked} | {:error, term()}
```

It performs sub-steps (i) insert-if-absent and (ii) `FOR UPDATE` of `assign_sequence/3` without the
increment, using the same query composition (no SQL string; INV-7). Holding the sequence row
serialises every writer of the type (S18).

### 4.5 `Letflow.Engine.EntityPort` (R3, R4b)

Additive callbacks and context keys; existing ones unchanged:

```
@type module_write_line :: %{required(String.t()) => term()}      # string-keyed, as pinned
@type owner_stamp :: %{module_id: String.t(), module_version: String.t(),
                       manifest_hash: String.t(), body_hash: String.t()}

# R3, activation (reads only, no lock):
@callback validate_module_writes([module_write_line()], module_write_ctx()) ::
            :ok | {:error, [line_violation()]}
@type module_write_ctx :: %{prefix: String.t(), node_id: String.t(), node_type: atom(),
                            owner: owner_stamp() | nil, graph_map: map(),
                            entity_write_count: non_neg_integer(),
                            graph_output_vars: [String.t()]}

# R4b, run time, pre-transaction (P0), before prepare/2:
@callback authorize_module_writes([module_write_line()], %{prefix: String.t(),
            owner: owner_stamp() | nil, snapshot_graph: map(), node_id: String.t()}) ::
            :ok | {:error, {index :: non_neg_integer(), detail :: atom()}}
```

`prepare_ctx` gains `optional(:module_writes) => [module_write_line()]` and `optional(:owner)`;
`multi_ctx` gains `optional(:module_writes)`, `optional(:owner)`, `optional(:entity_write_count)`.
The implementation (`EntityPortImpl`) delegates to `HandlerWrites`. The engine never names a module,
a Catalog function or a handler: it carries the stamp as opaque strings read from the definition row.

`prepare/2` with `module_writes` non-empty: AFTER authorization succeeded (the engine calls
`authorize_module_writes/2` first), the impl resolves each line through the Catalog and calls
`EntityTypeInstance.get_or_create/2` for every REGISTERED TARGET in ascending byte order, merged
into the same sorted type list and the same short transaction as the declarative lines. The
process-writable filter does not apply to a registered target of a verified handler (a managed
type can never carry the flag, F-R7); it applies unchanged to declarative lines.

`applied_line` gains optional `handler_module`, `handler`, `write_ordinal` (strings/integers, ids
and names only). `failure()`/`refusal_code()` are unchanged (no new public code).

### 4.6 `Letflow.Entities.HandlerWrites` and `HandlerContext` (R4a)

```
%Letflow.Entities.HandlerContext{          # built only in handler_writes.ex (scan H2)
  prefix: String.t(),
  instance_id: Ecto.UUID.t(),
  origin: {:task, Ecto.UUID.t()} | {:dispatch, Ecto.UUID.t()},
  node_id: String.t(),
  definition_id: Ecto.UUID.t(),
  definition_version: String.t(),
  line_index: non_neg_integer(),
  actor_id: Ecto.UUID.t(),                 # completer | platform sentinel
  subject_id: Ecto.UUID.t(),               # completer | activator (restriction subject)
  activator_id: Ecto.UUID.t(),
  handler: %{module_id: String.t(), name: String.t(), targets: [String.t()]},
  authority: ManagedTypes.Owner.t()        # never read by handler code (opaque), see 7.2
}

@type write_command :: %{required(:entity_type) => String.t(), required(:field_values) => map()}
@type handler_error :: :invalid_arguments | :not_permitted

@spec create(Ecto.Multi.t(), HandlerContext.t(), write_command()) ::
        {:ok, Ecto.Multi.t()} | {:error, :target_not_registered | :too_many_writes | :invalid_write_command}
@spec step(Ecto.Multi.t(), HandlerContext.t(),
           fun :: (Ecto.Repo.t(), view :: %{non_neg_integer() => term()} ->
                     {:ok, term()} | {:error, handler_error()})) ::
        {:ok, Ecto.Multi.t()} | {:error, :too_many_writes}
```

The handler function registered in the manifest has the shape:

```
@spec handler(Ecto.Multi.t(), HandlerContext.t(), args :: %{String.t() => term()}) ::
        {:ok, Ecto.Multi.t()} | {:error, handler_error()}
```

Contract (moduledoc of `HandlerContext`, pinned by tests):

1. The handler BUILDS steps; it does no work at build time other than computing arguments for them.
   Database reads happen only inside a `step/3` function, through the `repo` argument it is given,
   in the step transaction. It never calls `Repo.transaction`, `Repo.rollback`, never rescues a
   database error and continues (a failed statement aborts the transaction: `25P02`), never starts
   a process or performs network/file I/O, never writes a table other than through `create/3`.
2. `create/3` is the ONLY writer: it builds the `%StepSource{}` (with `handler`, next
   `write_ordinal`), derives the key and namespace, refuses a type not in `ctx.handler.targets`
   (`:target_not_registered`) and a call with more than 49 `create`/`step` additions
   (`:too_many_writes`), applies the completer-subject field restrictions (D-R.13), then calls
   `Records.command_multi/3` with `ctx.authority`, then appends a `:policy` step (scoped types
   refused until 0051) and the engine-readable `applied` bookkeeping.
3. `step/3` adds one named read/check step. Its `view` carries only this call's own earlier results
   by ordinal (no instance variables, no other call). It returns `{:ok, term}` or a closed error.
4. The handler receives resolved argument VALUES, never the instance variables map.
5. Step names are assigned by `HandlerWrites`; a returned Multi containing a name outside the call's
   own `{:line, key, _}` range is a contract violation (`:handler_shape`, internal).

`HandlerWrites` also owns (all pure functions of the registered data and the context):

```
@spec validate_module_writes([module_write_line()], module_write_ctx()) :: :ok | {:error, [line_violation()]}
@spec authorize_module_writes([module_write_line()], map()) :: :ok | {:error, {non_neg_integer(), atom()}}
@spec prepare_targets([module_write_line()], prefix :: String.t()) :: [String.t()]
@spec multi(Ecto.Multi.t(), [module_write_line()], EntityPort.multi_ctx(), declarative_types :: [String.t()]) :: Ecto.Multi.t()
@spec interpret_failure(failed_step :: term(), reason :: term()) :: EntityPort.failure()
```

### 4.7 Engine (`engine.ex`), R3 and R4b, private unless stated

* `plan_entity_writes/3` / `resolve_entity_plan/4`: select the node when `entity_writes` OR
  `module_writes` is a non-empty list (F-R6); the combined count `length(entity_writes) +
  length(module_writes)` is capped at 20 at run time on the pinned snapshot (reuse of
  `@max_entity_write_lines`, `:validation_failed` index 20 as today). The plan gains
  `module_writes`, `owner :: owner_stamp | nil` (read from the definition row the plan already
  fetches by `get_by_id`), `snapshot_graph` (the raw snapshot map), and `entity_write_count`.
* New P0 step, AFTER `recorded_activator`/`check_activator_active` and BEFORE `prepare/2`:
  `EntityPort.impl().authorize_module_writes/2` (INV-3: stamp, hash and body checks precede the
  `prepare/2` transaction and every entity lock). A refusal writes the existing best-effort
  refusal audit (`record_entity_write_refusal_audit/6`) and returns
  `{:error, {:entity_write_refused, index, :write_not_permitted}}` (detail atom in the audit only).
* `check_entity_writes_planned/3`: also matches `"module_writes"` (F-R6).
* `maybe_entity_writes/4` passes the extra ctx keys; `interpret_complete_result/3` is unchanged
  (handler failures arrive as `{:line, key, step}` and go through the same door).
* `append_entity_write_audits/7` and `append_entity_writes_applied_event/7` copy the three optional
  applied keys when present (opaque, no module named). `lines_hash` for a node WITH `module_writes`
  is computed by the impl over `%{"entity_writes" => lines, "module_writes" => module_lines}`;
  for a node without it, unchanged (byte-identical, regression test).
* EE-12 moduledoc: one added sentence for handler type locks (D-R.7), in R4b.

### 4.8 Definitions, Installs, SolutionPack, routers (R2, R3)

```
# ProcessDefinition: four fields, NEVER in a cast list
field :owner_module, :string; field :owner_module_version, :string
field :owner_manifest_hash, :string; field :owner_body_hash, :string

@spec Definitions.create_owned(attrs :: map(), opts :: keyword(), ManagedTypes.owner()) ::
        {:ok, ProcessDefinition.t()} | Definitions.create_error()
# :tenant owner -> identical to create/2 (no stamp); %Owner{} with non-nil version/manifest_hash ->
# the row is stamped: put_change of the four fields, body_hash = OwnerStamp.graph_hash(graph).
# callers: solution_pack.ex only (scan H6).
@spec Definitions.update(...) :: ... | {:error, :module_owned_definition}      # stamped row
```

* `TenantModule`: `field :manifest_hash, :string` (nullable); `insert_changeset` casts it; the
  settings changeset does not. `Installs.insert_tenant_module/2` stores `Catalog.manifest_hash/1`.
  `Installs` exposes `installed_manifest_hash(module_id, prefix) :: {:ok, String.t()} | :error`
  (the only reader; used by `HandlerWrites`, not by core).
* `SolutionPack.create_packed_definitions/3` becomes `/4` taking the `owner`; a packed definition of
  a module install is created through `Definitions.create_owned/3`; a plain pack (`:tenant`) is
  `create/2` exactly as today.
* Routers (`routers/definitions.ex`): POST, PUT, PATCH, import and `/rollback` bodies containing any
  of `owner_module`, `owner_module_version`, `owner_manifest_hash`, `owner_body_hash` (also
  `activated_by`, same defect class) answer 422 with a field error, before any write; the key is
  refused even when the value is null. `definition_map/1` exposes `owner_module` and
  `owner_module_version` read-only; the hashes are never serialised. Export omits all stamp fields.
  `Definitions.update` of a stamped row (including `variable_schemas` of PATCH) is 409
  `module_owned_definition`. Activate/deprecate/archive/rollback-to of a stamped row are allowed
  (activation runs the hash check). Hard delete of a stamped DRAFT is not restricted (OQ-R9).

### 4.9 `PinRebind` (R3)

Refusal point: `run_rebind_pins/9`, a new `Multi.run(:owner_guard, ...)` between `:eligibility`
(`pin_rebind.ex:329-352`) and `:effective_pins`. It runs only when the request contains at least one
`:module` entry; it reads `projection.definition_id` (already locked by `:instance_projection`),
the definition row's `owner_module`, and if non-nil refuses:

```
{:error, {:rebind_refused_owned_definition, :module, ref :: String.t()}}
```

All other entry kinds and instances with an unstamped definition are unchanged (byte-identical
event, same codes). Rationale and the vacuity finding are F-R3; the router maps the new tuple to
the existing 409/422 pin-rebind refusal family (ELIXIR-DEV picks the renderer used for
`:instance_not_rebindable`). Test brief: 9, row PR-1.

### 4.10 Migrations (R2)

| File (version chosen at build time, next free; anti-pattern 574) | Effect |
|---|---|
| `add_owner_stamp_to_process_definitions` | `alter table(:process_definitions)`: add `owner_module` string(255), `owner_module_version` string(255), `owner_manifest_hash` string(64), `owner_body_hash` string(64), all NULL, no default, no backfill; CHECK `process_definitions_owner_stamp_all_or_none`; trigger `process_definitions_owner_stamp_immutable` (BEFORE UPDATE: raises when OLD.owner_module is not null and any `owner_*` column or `graph` changes, or when OLD.owner_module is null and NEW.owner_module is not null) |
| `add_manifest_hash_to_tenant_modules` | add `manifest_hash` string(64) NULL; no backfill (an earlier install cannot reconstruct its hash) |

Both: `if prefix() do` guard, constant SQL (INV-7), registered in
`Letflow.TenantProvisioning` `@tenant_scoped_migration_manifest` (S12 style, `tenant_provisioning.ex`
~`:697`), reversible. The trigger is a belt for raw SQL and `update_all`; the application guard
(4.8) is the primary one.

## 5. Declaration and activation validation (R3)

### 5.1 Node attribute

```
attributes["module_writes"] :: [ %{
    "module"  => String.t(),                     # a Catalog module id
    "handler" => String.t(),                     # a registered handler name
    "args"    => %{ String.t() => arg_source }   # closed: only names the handler declares
} ]
arg_source :: %{"var" => String.t()} | %{"const" => json} | %{"sys" => String.t()}
```

Closed keys per line (`module`, `handler`, `args`); each `arg_source` has exactly one key.
`var`/`const` are admissible for a `kind: :value` arg; `sys` only for a `kind: :sys_ref` arg and
only naming an `output_record_id_var` (or its `.seq`) declared by a declarative line of the same
graph; at run time the value is read with `VariableMerge.check_sys_entry/2` and a failure is a
refusal (CO-7), never assumed to be a UUID or int64. A `var` naming a reserved `_sys` key keeps
the A1 refusal (`:module_write_arg_sys_reference`). Values from a form output may feed a `var`
arg; the handler validates it (`:invalid_arguments`).

Position/caps: HUMAN_TASK only (R3; SERVICE_TASK opens in R5). `entity_writes` count + `module_writes`
count <= 20 (`:entity_writes_too_many_lines` at index 20, as today). Handler call `j` has
`line_index = length(entity_writes) + j`.

### 5.2 Violations (all inside the existing `{:entity_writes_invalid, [%{node_id, index, code}]}` envelope)

Evaluated by extending `check_entity_writes/3` (so the three activation paths, S10, need no new call
site) with the definition ROW's stamp; the ctx stamp is `nil` for a plain map (promotion `new_row`,
import) = unstamped. Reads only, no lock.

| Code | Condition |
|---|---|
| `:module_writes_not_a_list` | attribute present, not a list |
| `:module_writes_node_type_not_supported` | node is not HUMAN_TASK |
| `:module_write_line_malformed` / `:module_write_unknown_key` | non-map line, non-string keys / key outside the closed set |
| `:module_write_module_missing` / `:module_write_handler_missing` | `module`/`handler` absent or not a non-blank string |
| `:module_write_stamp_missing` | row has no `owner_module` (every tenant-created, edited, imported, promoted, rolled-back-copy version) |
| `:module_write_stamp_mismatch` | line `module` differs from the row's `owner_module` (M2's stamp, or a line naming another module) |
| `:module_write_module_not_installed` | no `tenant_modules` row for the stamp's module in this tenant |
| `:module_write_handler_unknown` | `Catalog.write_handler(module, handler)` is `:not_found` (module not compiled in, or handler removed) |
| `:module_write_hash_mismatch` | stamp `owner_manifest_hash` differs from `tenant_modules.manifest_hash`, or (strict, OQ-R3) the installed hash differs from the current compiled manifest hash, or the installed hash is NULL |
| `:module_write_body_changed` | `graph_hash(row.graph)` differs from `owner_body_hash` |
| `:module_write_arg_unknown` / `:module_write_arg_missing` | arg name not declared / declared `required` arg absent |
| `:module_write_arg_source_invalid` | `arg_source` not exactly one of `var`/`const`/`sys`, or a blank `var` |
| `:module_write_arg_sys_reference` | `var` names a reserved `_sys` key |
| `:module_write_sys_source_not_allowed` | `sys` source on a `:value` arg, or `var`/`const` on a `:sys_ref` arg |
| `:module_write_sys_ref_unknown` | `sys` names no declared `output_record_id_var`/`.seq` of the graph |
| `:entity_write_activator_required` | reuse (D-R.16): the activator lacks `:EntitiesRecordsWrite` or is not an active user |

The activation response reveals module/handler presence to a definition author only; run-time
refusals are uniform (section 8).

`entity_writes_activated_by/3` records the document for a graph with `module_writes` (the column
stays NULL only when the graph has neither attribute): `"authorized"` = the declarative pairs
(possibly `[]`), plus additive `"module_handlers"` = sorted `["<module>/<handler>"]`. `recorded_activator/1`
ignores unknown keys, so no run-time reader changes.

## 6. Execution (R4a, R4b)

### 6.1 Completion order on the HUMAN path (normative)

```
-- before the transaction ---------------------------------------------------------------
P0  plan_entity_writes: task pending, snapshot graph, node, cap, definition row,
    recorded_activator + check_activator_active                         (as B2)
P0b EntityPort.authorize_module_writes: stamp present, line.module == stamp, module installed,
    handler registered NOW, stamp hash == tenant_modules hash [== compiled hash, OQ-R3],
    graph_hash(snapshot graph) == owner_body_hash                       (reads only; INV-3)
P1  EntityPort.prepare: synthetic instances for declarative types (process-writable) and for the
    REGISTERED targets of the verified handlers, sorted ascending, one short transaction
-- one Repo.transaction ----------------------------------------------------------------
S0  SET LOCAL lock_timeout 2s / statement_timeout 5s                    (plan only)
... tasks lock, projection lock, merge, transition (unchanged) ...
M1  :entity_writes_started
M2  {:type_lock, type} per type in the ascending UNION of declarative types and handler targets
    (EventStore.lock_instance_sequence; only when module_writes is non-empty)
M3  declarative lines sorted (entity_type, index): deadline, build, A2 steps, process_policy  (as B2)
M4  per handler call j ascending:
      {:line, k0, :deadline}            call-level guard (k0 = line key with ordinal 0)
      {:line, k0, :owner_recheck}       tenant_modules.manifest_hash re-read, no lock (TOCTOU)
      handler build (rescue ONLY build-time exceptions) -> returned Multi
      handler steps/writes, each {:line, key, ...}, then {:line, k0, :policy}
M5  :entity_writes   (applied list incl. handler lines; lines_hash as 4.7)
... tail: per-line audit, sys event, APPLIED event, TASK_COMPLETED (unchanged order) ...
```

A handler call that errors at build time (`{:error, atom}`, shape violation, raise) becomes
`Multi.error` named `{:line, k0, :build}` so nothing commits and the task stays pending.

### 6.2 Lock and transaction analysis

* New cross-instance locks: exactly the type `instance_sequences` rows for the registered targets
  (`M2`), the same row class and the same ascending `(entity_type)` position as 0054 D3 rule 4. A
  handler cannot take a lock earlier or in another order: it receives no `repo` outside `step/3`,
  and `create/3` goes through `command_multi/3`, which re-takes only already-held rows.
* Union sorting makes (A,B) vs (B,A) completions, declarative-vs-handler mixes and handler-vs-handler
  mixes acquire in one global order. Locks of types the handler never writes are held longer
  (accepted; documented in the EE-12 sentence).
* Projection rows: not taken by `M2` by design (S18: any writer takes the sequence row first), so
  there is no `M2` inversion with `Records.update` or the exam path.
* `SET LOCAL` and the contention rescue (`run_transaction/2`) apply unchanged because a plan exists.
* The 10 s wall-clock guard runs per call (`{:line, k0, :deadline}`) in addition to the
  declarative per-line guards.
* A handler `step/3` that triggers a database error aborts the transaction; the mapping is the
  contention rescue around exactly `Repo.transaction` (0054 D3), never inside the step.
* REQ-045: no process per instance, no new process, no ETS, no GenServer anywhere in R1-R5
  (`Catalog` stays a plain module; handlers are called inline).

## 7. The managed-type guard owner path (builds on merged #2583)

### 7.1 What exists

`Records.command_multi(command, prefix, authority)` with `authority :: :tenant | %Owner{}`;
`check_write_authority/3` after the definition read and in `:recheck_definition`; `owner_for!/1`
callable only from `__MODULE__` of a `defmanifest` module or from files under that module's own
directory; the AST scan (S16). Everything below keeps that guard exactly as is.

### 7.2 Mechanism

1. The platform resolves the handler: `HandlerWrites` takes `module` and `handler` from the PINNED
   line after `authorize_module_writes/2` verified the stamp, then `Catalog.write_handler/2`
   (string compare; data from a stored definition, never a request field or settings key).
2. It builds the authority with `ManagedTypes.owner_for_handler/2` (4.3): inputs are the two
   Catalog-resolved strings; output is an `%Owner{}` whose `manages` is the handler's registered
   target set. `owner_for!/1` is NOT used by the platform (its argument must be a compile-time
   alias in the module's own directory, R2).
3. The Owner lives inside the opaque `HandlerContext` (`authority` field). The handler cannot
   read it by contract and cannot construct one (scan R4: `%Owner{}` literals only in
   managed_types.ex; scan H2: `%HandlerContext{}` only in handler_writes.ex). It cannot pass a
   different authority to `Records` because it does not call `Records` (D-R.5; scan H4 forbids it
   in handler files).
4. `HandlerWrites.create/3` calls `Records.command_multi(command, prefix, ctx.authority)`: the
   third argument is a non-literal, which is why `handler_writes.ex` is an `@authority_callers`
   file (7.5).
5. Declarative lines are untouched: `StepWrites` keeps the LITERAL `:tenant` (S6). Because
   `step_writes.ex` stays OUT of `@authority_callers`, the existing R1 scan keeps proving that no
   declarative path can ever pass an Owner. This is the reason the handler logic is a separate
   file instead of a branch inside `StepWrites`.

### 7.3 Who is refused, and by what

| Caller | Mechanism | Result |
|---|---|---|
| Declarative `entity_write` line on a managed type | activation `:entity_type_managed`; run time `command_multi(.., :tenant)` -> `check_record_write(m, _, :tenant)` | `write_not_permitted` |
| Handler of M writing M's registered target | `%Owner{module_id: M, manages: targets}` names the type | allowed |
| Handler of M writing another managed type of M (not registered target) | writer refusal `:target_not_registered` (and narrowed Owner would refuse) | `write_not_permitted` |
| Handler of M writing M2's managed type | writer refusal (not in targets); Owner `module_id` mismatch | `write_not_permitted` |
| Handler writing an UNMANAGED type (F-R2) | writer refusal `:target_not_registered` (registration requires targets managed by the module, rule 10) | `write_not_permitted` |
| Handler invoking another module's handler | no API exists; `module` must equal the stamp (`:module_write_stamp_mismatch` at activation, authorize at run time) | refused |
| HUMAN task path without module line | literal `:tenant` only | as REQ-499 |
| SERVICE_TASK path (R5) | same `HandlerWrites`; Owner built the same way from the pinned line | allowed iff stamped |
| Script paths | never call `command_multi`; D-R.18 | n/a |
| Plain core caller (`RecordDeadlineSweep`, any `Records.*` caller without an Owner) | `:tenant` default (`/2` arities) | `:entity_type_managed` (existing #2583 tests) |
| Request data (field in definition, record, request, settings) | none of them is read by 7.2 steps 1-2 except the stored pinned line, which must also equal the install-time stamp and body hash | no effect |

### 7.4 New scan rules (new file `test/letflow/entities/handler_writes_callers_test.exs`, R4a)

Pure AST over `lib/**/*.ex` and `test/support/**/*.ex`, pipe-normalised, same helper shapes and
accepted limits as the three existing scans; each rule has a synthetic non-vacuity case:

* **H1** calls/captures/applies named `owner_for_handler` only in `managed_types.ex` and `handler_writes.ex`.
* **H2** `%WriteHandler{}`/`%HandlerContext{}` literals, `struct/2`, map `__struct__` forms only in
  `catalog.ex` / `handler_writes.ex` respectively.
* **H3** `write_handler(` and `call_write_handler(` with a Catalog receiver only in `catalog.ex`,
  `handler_writes.ex`, `installs.ex` (hash reader) and `lib/letflow/definitions*` NOT allowed (the
  activation path goes through the port).
* **H4** handler-purity: the set of handler FILES is derived at test time from
  `Catalog.all_manifests()` (module -> compile source path); in each such file no reference to
  `Repo` (outside a `step/3` closure is not statically separable, so: any `Repo.`/`Ecto.Multi.insert|
  update|delete|insert_all|update_all|delete_all|merge`), `Records`, `Owner`, `StepSource`,
  `ManagedTypes`, `EventStore`, `Task`, `Process`, `GenServer`, `spawn`, `send`, `:httpc`, `Req`,
  `Finch`, `HTTPoison`, `System`, `File`, `IO`, `Code`, `String.to_atom`, `Module.concat`,
  `apply/3` with a non-literal module. Allowed: `Ecto.Multi` constructors that only compose
  (`new/0`, `append/2`, `run/3` is NOT allowed: use `HandlerWrites.step/3`). Non-vacuity: the
  fixture handler file is in the set; a synthetic violating snippet is flagged.
* **H5** `create_owned(` callers only in `solution_pack.ex`.

### 7.5 Reviewed closed-set changes (state in the R4a PR body)

| File | Change | Why unavoidable |
|---|---|---|
| `test/letflow/entities/managed_types_callers_test.exs` | `@authority_callers [@fixture_managed]` -> `[@fixture_managed, @handler_writes]` plus the module attribute; nothing else (owned by #2596, do not touch exam entries; a textual merge conflict on this one line is trivial and resolved by union) | R1 asserts equality; `handler_writes.ex` passes a non-literal Owner |
| `test/letflow/entities/command_multi_callers_test.exs` | `@command_multi_callers [@step_writes]` -> `[@step_writes, @handler_writes]` | `HandlerWrites.create/3` calls `command_multi` |
| `test/letflow/entities/step_source_callers_test.exs` | `@new_callers [@records, @step_writes]` -> `[@records, @step_writes, @handler_writes]` | `HandlerWrites` builds the source |
| `lib/mix/tasks/letflow.check_boundaries.ex` | none (engine still names no entities/module file; handler files are referenced only by their entry module file and `catalog.ex`) | verified by the unchanged task run |

The fixture modules are NOT added to any allow-list: their handlers use `HandlerWrites` only.

## 8. Failure mapping, refusal table and HTTP codes (D8 union; no new public code)

Public envelope for every row: `{"error": <code>, "line_index": <declared index> | null}` through
`Response.entity_write_refused/3` (`response.ex:291`); bytes are a function of `(status, code,
index)` alone. `write_not_permitted` is therefore byte-identical to REQ-499's for every cause (INV-5).

| Cause | Where raised | Public code | HTTP | Audit detail atom (tenant audit only) |
|---|---|---|---|---|
| Stamp missing/foreign, module not installed, handler unknown now, hash or body mismatch (P0b) | pre-transaction | `write_not_permitted` | 403 | `:stamp_missing`, `:stamp_mismatch`, `:module_not_installed`, `:handler_unknown`, `:hash_mismatch`, `:body_changed` |
| `owner_recheck` hash drift inside the transaction | `{:line,k0,:owner_recheck}` | `write_not_permitted` | 403 | `:hash_mismatch` |
| Write outside registered targets, managed authority refusal, scoped type, field restricted for subject, instance missing | `create/3`, `:recheck_definition`, `:policy` | `write_not_permitted` | 403 | `:target_not_registered`, `:managed`, `:scoped`, `:field_restricted`, `:not_writable` |
| Handler `{:error, :not_permitted}` | `{:line,k0,:build}` or handler step | `write_not_permitted` | 403 | `:handler_not_permitted` |
| Handler `{:error, :invalid_arguments}`; type payload invalid | build / `command_multi` | `validation_failed` | 422 | `:handler_invalid_arguments` |
| `record_version_conflict` (not reachable in create-only MVP) | `Records.interpret_in_multi/1` | `record_version_conflict` | 409 | `:step` |
| append-only violation | `command_multi` | `entity_append_only` | 422 | `:step` |
| duplicate `sys:step:` key | `:idempotency` | `idempotency_conflict` | 422 | `:step` |
| definition inactive/changed | `command_multi`, `:recheck_definition` | `entity_type_inactive` | 422 | `:build` |
| `40P01`, `55P03`, `57014`, pool timeout, 10 s guard, `prepare/2` contention | raised out of `Repo.transaction` / guard | `entity_write_contention` | 503 | `:deadline` |
| Handler raised at build, returned an unexpected shape or step name, exceeded 49 additions | build | (internal) `{:entity_write_failed, index, :handler}` | 500, no body detail | none (log: module id, handler name, exception module only) |
| Activator inactive / `activated_by` unreadable | P0 | `entity_write_needs_reactivation` | 409 | as B2 |
| Cap exceeded | P0 | `validation_failed`, `line_index: 20` | 422 | `:too_many_lines` |

No exception text, field name, record id or type name is in any response (INV-2/4). A handler
exception is rescued at BUILD time only (pure code; no database state to corrupt) and reduces to
the internal failure; a database error inside a step is never rescued by `HandlerWrites`.

## 9. Audit, events, idempotency, replay

* **Entity event** (each `create/3`): `actor_id` = completer; metadata = the 8 flat keys + `source.handler_module`,
  `source.handler_name`, `source.write_ordinal`; `source.line_index` = the call's declared index;
  metadata set by the platform only (`Records` already refuses client `source`/`metadata`, S4).
* **Instance stream**: ONE `TASK_ENTITY_WRITES_APPLIED` event; lines carry `(line_index, entity_type,
  record_id, event_global_seq)` and, for handler lines, `handler_module`, `handler`, `write_ordinal`;
  `lines_hash` as 4.7; no field values. The SYS event is unchanged (handlers produce no `_sys` output).
* **Tenant audit**: `Audit.insert_entry` per applied line, action `entity_write.process_step`
  (unchanged for declarative lines), handler lines add `handler_module`, `handler`, `write_ordinal`
  to `after_state`. A refusal writes the existing `entity_write.refused` entry with the closed detail
  atom of section 8.
* **Idempotency**: per write `sys:step:<task_id>:<line_index>:<ordinal>` (HUMAN) or
  `sys:step:<dispatch_id>:<line_index>:<ordinal>` (R5); derived from the struct, closed charset, a
  handler can neither supply nor override one; `command_multi` refuses a command carrying a key
  (`:invalid_step_source`). A duplicate is `idempotency_conflict` and rolls back (T-4).
* **Replay**: no handler call site exists outside the completion Multi build. Event replay,
  `rebuild_projection`, timers, escalations, cancellation and PinRebind never reach `HandlerWrites`;
  test double fails the test if invoked.

## 10. Test fixtures and registration

New entry modules (R4a) under `test/support/modules/fixture_ledger/` (own directory, so scan R2 is
satisfied if they ever call `owner_for!(__MODULE__)`; they do not):

* `Letflow.Modules.FixtureLedger`, id `fixture_ledger`: pack `priv/module_fixtures/ledger_foundation.json`
  (two entity definitions `fxl_ledger` (append-only) and `fxl_balance`, plus one process
  definition `fxl_post` with a HUMAN_TASK node carrying `module_writes`), manifest
  `manages_entity_types: ["fxl_ledger", "fxl_balance"]`, `write_handlers`: `post_entry` (targets
  both, args `item` `:value` required, `quantity` `:value` required), `post_balance_only` (target
  `fxl_balance`), plus `on_install/3` activating the entity types through `EntityActivation`.
  Handler module `Letflow.Modules.FixtureLedger.Handlers` in the same directory.
* `Letflow.Modules.FixtureLedgerOther`, id `fixture_ledger_other`: one managed type `fxo_other`,
  one handler, used for cross-module refusal tests (M1 handler -> M2 type; M2 stamp used by an M1
  definition).
* Negative manifests for rule 10 are inline maps in `catalog_write_handlers_test.exs`, not
  registered modules.

Registration: `config/test.exs` appends both modules; assertions that enumerate the registered
module ids (`catalog_test.exs`, `installs_managed_by_test.exs`, any golden listing) are updated in
the same PR (NOT VERIFIED exhaustively; ELIXIR-DEV greps `fixture_managed_no_pack`/`entry_modules`
and quotes the result). Fixtures declare no permissions, so the permission-matrix golden is
unaffected. The fixture handlers satisfy scans R1-R5 and the three callers tests unchanged and are
inside H4's scanned set.

## 11. AC -> design -> test brief

| Issue AC | Design | Test (new file) |
|---|---|---|
| Registration only from module code | D-R.1/2; 4.1; no route reads `write_handlers` | `modules/catalog_write_handlers_test.exs` (resolution from a fixture manifest; non-binary -> `:not_found`); `routers/write_handler_registration_surface_test.exs` (POST/PUT/PATCH/import of definitions, entities, `/modules` install and settings, pack documents, tenant settings, `on_install` ctx: handler declarations refused or ignored; resolving an uncompiled name `:not_found`) |
| Manifest validation | 4.1 rule 10 | `catalog_write_handlers_test.exs`: one case per row of the rule table, tuple asserted |
| Boundary | D-R.1; 4.5; section 7.5 last row | `mix letflow.check_boundaries` quoted; `engine/entity_port_boundary_test.exs` extended (engine names no `HandlerWrites`/`Catalog`/module) |
| Unknown/unregistered handler refused at activation | 5.2 | `definitions/module_write_activation_test.exs`: handler unknown, module not compiled, module not installed, on the three paths (activate, rollback, promotion) |
| Stamp required; forged/copied refused; API refuses fields | D-R.8/15; 4.8; 5.2 | `definitions/owner_module_stamp_test.exs`: tenant create/edit/import/rollback copy of a stamped definition has no stamp and its handler line is refused; POST/PUT/PATCH/import with each of the four keys and `activated_by` -> 422; forge test at `ProcessDefinition` changeset level (`cast` of the four keys is a no-op); raw `update_all` of a stamped row refused by the trigger; stamped `update/3` -> 409 |
| Hash check at activation | 4.1 hash, 5.2 | `owner_module_stamp_test.exs`: row hash != installed hash; installed NULL; installed != compiled (strict); body edited via raw SQL on an unstamped path is not possible (trigger), covered by the trigger test |
| Stamp check at run time from the pinned snapshot | 6.1 P0b, `owner_recheck`; 4.2 | `engine/module_write_runtime_stamp_test.exs`: hand-edited snapshot graph (body hash), nulled/foreign stamp on the row, tampered `tenant_modules.manifest_hash`, handler removed from the compiled manifest (test seam swaps the compiled list via the existing config pattern) -> `write_not_permitted`, task `pending`, nothing committed, refusal audit entry |
| PinRebind | 4.9, F-R3 | `engine/pin_rebind_owner_module_test.exs`: `:module` entry on an instance of a stamped definition refused (exact tuple); same on unstamped unchanged (golden event bytes); non-`:module` kinds unchanged; pin that no rebind changes `instance_projections.definition_id` |
| Same-name supersession cannot transfer the stamp | D-R.15; new version is a new row | `owner_module_stamp_test.exs`: create version "1.1" under the key of a stamped definition: no stamp, handler line refused at activation, running pinned instance still executes |
| Handler runs inside the step Multi with the D3 lock order | 6.1, 6.2, D-R.7/12 | `engine/module_write_atomicity_test.exs` (records, entity events, audit, instance event, task completion in one transaction; failing handler step leaves task pending); `engine/module_write_lock_order_test.exs` (N-parallel completions, handler + declarative lines on (A,B) and (B,A), no deadlock; step-name probe asserts the `{:type_lock, _}` steps are ascending and precede every write) |
| No I/O, no nested transaction | D-R.4/5; 4.6 contract; scan H4 | `entities/module_write_contract_test.exs`: a fixture handler variant calling `Repo.transaction`, performing an HTTP/process call, or rescuing a DB error is flagged by H4 (synthetic) and, for the rescue case, aborts with `25P02` -> internal failure, nothing committed |
| SERVICE_TASK path | R5; 4.6 `origin`/`subject_id` | `engine/module_write_service_task_test.exs`: created in R4b as `@tag :skip` with the reason "PR C2/C1 not merged"; un-skipped in R5 |
| Actor and scope | D-R.13 | `engine/module_write_actor_test.exs`: event `actor_id` = completer; a completer outside the role scope is refused before the handler; `source.activator_id` = activator; field restriction applied with the completer as subject |
| Codes | section 8 | `engine/module_write_failure_codes_test.exs`: one case per row; response byte-compare for `write_not_permitted` against a REQ-499 declarative refusal; handler raise -> 500 with no text; contention via held lock |
| Owner path through `Records.*` | section 7 | `entities/module_write_owner_path_test.exs` (handler of M writes M's target; declarative line, M2 handler, plain core caller, and a `create/3` for an unregistered/unmanaged type are refused), `entities/handler_writes_callers_test.exs` (H1-H5), the three updated allow-list tests |
| A handler cannot widen privilege | 7.3, F-R2, D-R.9 | `entities/module_write_privilege_test.exs`: unmanaged type without `writable_by_process`, inactive type, invalid field values, restricted field for the subject, scoped type (seam list) |
| Audit and event shape | 4.4, 9 | `engine/module_write_audit_test.exs`: metadata keys and values exact; declarative line metadata byte-identical to a pre-R4a golden; one APPLIED event; audit entry per line; no field value anywhere |
| Idempotency key | D-R.11, 4.4 | `engine/module_write_idempotency_test.exs`: ordinals 1..n keys exact, handler cannot supply a key, a key outside the task namespace is unrepresentable, duplicate -> `idempotency_conflict`, 50th addition -> `:too_many_writes` |
| Replay never re-runs | D-R.19 | `engine/module_write_replay_test.exs` with a handler test double that fails if invoked (rebuild, `rebuild_projection`, timers, cancel, PinRebind) |
| Regression | byte-identity | REQ-499 B/C0 suites, `Records`, `complete_task`, `engine_concurrency_test.exs` unchanged and green; golden step-name test for a node without `module_writes` unchanged |

## 12. Invariants

Design invariants:

* **INV-1** Tenant prefix only from the server (plan/auth context); `HandlerContext.prefix` is set by `HandlerWrites` from the port ctx.
* **INV-2** No field value, field name or record id of a refused write in any response, log or audit detail; ids and closed atoms only.
* **INV-3** Authorization before data: P0b (stamp, hash, body) precedes `prepare/2`, every entity lock and the handler build.
* **INV-4** No exception text in a response; a handler exception reduces to `entity_write_failed`.
* **INV-5** All stamp/target/managed/scope/restriction denials share ONE public body.
* **INV-6** Scope ceiling: scoped types refused (`:policy`) for the completer and the platform actor alike until 0051.
* **INV-7** No SQL string interpolation: constant `SET LOCAL`, the lock primitive and the trigger are constant SQL or Ecto queries.
* **INV-8** Bounded: 20 combined lines, 49 additions per call, 2 s lock / 5 s statement / 10 s wall-clock, no handler-controlled timeout.
* **INV-10** Permission classification: the stamp fields are not writable through any permission; the definitions API refusal is an authorization-independent 422.
* **INV-R1** A stamp exists only on a row created by `Installs` (scan R5 + H5 + trigger); never from a cast list.
* **INV-R2** The stamp is per version row and immutable (trigger + `update/3` refusal).
* **INV-R3** A handler's writes are a subset of its registered targets, enforced twice (writer, narrowed Owner).
* **INV-R4** Declarative paths never hold an `%Owner{}` (`step_writes.ex` outside `@authority_callers`).
* **INV-R5** The engine, definitions core and entities-core files name no module file; handlers are reached by `apply/3` on Catalog data only.
* **INV-R6** Declarative-line bytes (metadata, key, hash, events) are unchanged by REQ-501.

Threat list (0054 plus this issue):

| Threat | Closed by |
|---|---|
| T-1 managed bypass: tenant definition | declarative managed lines refused (REQ-499); handler lines need stamp (D-R.8) |
| T-1 type becomes managed after activation | `check_write_authority` in `:recheck_definition` (S4) + `:policy` row re-read; handler targets are managed by construction |
| T-1 same-name supersession / new, edited, imported versions inheriting the stamp | D-R.15, per-version row, `create_owned` only from `solution_pack.ex`, API refusal, trigger |
| T-1 PinRebind | 4.9, F-R3 (vacuity stated, fail-closed guard) |
| T-2 privilege escalation | completer role/scope check unchanged; activator authority reused (D-R.16); writer applies field restrictions; narrowed Owner |
| T-4 idempotency squatting / duplicate as success | derived keys, `idempotency_conflict`, `sys:` reserved (#2550) |
| T-9 replay re-running a handler | D-R.19 |
| T-10 service-task platform actor | R5: sentinel actor, activator subject, same `HandlerWrites` |
| NEW tenant-supplied module/handler resolved by string to code | D-R.2: compare against compiled manifests only; H1-H3 scans; no atom creation |
| NEW handler writes outside registered targets | D-R.9, INV-R3 |
| NEW handler invokes another module's handler / writes M2 type | no API; stamp equality; Owner `module_id` |
| NEW hand-edited pinned snapshot | `owner_body_hash` vs `graph_hash(snapshot graph)` at P0b |
| NEW module code upgraded under an old stamp | strict compiled-hash check (OQ-R3) |
| NEW handler holds/extends locks or opens transactions | D-R.7, contract, H4, `25P02` |

## 13. Files touched per PR

**R1**: `modules/catalog.ex`, `modules/module.ex` (typedoc + moduledoc), `modules/manifest_hash.ex` (new);
tests `modules/catalog_write_handlers_test.exs`, `routers/write_handler_registration_surface_test.exs`.

**R2**: `priv/repo/migrations/*` (2 new), `tenant_provisioning.ex` (2 manifest entries),
`definitions/process_definition.ex` (fields, no cast), `definitions/owner_stamp.ex` (new),
`definitions.ex` (`create_owned/3`, `update/3` refusal), `definitions/solution_pack.ex`
(`create_packed_definitions/4`), `entities/managed_types.ex` (`Owner` fields, `module_owner/1`),
`modules/tenant_module.ex`, `modules/installs.ex` (hash store, `installed_manifest_hash/2`),
`routers/definitions.ex` (refusal, `definition_map/1`), `definitions/export_import.ex` (omit);
tests `definitions/owner_module_stamp_test.exs`, trigger test, `tenant_fixture` column pins if any.

**R3**: `definitions.ex` (`check_entity_writes/3`, `entity_write_nodes/1`, `entity_writes_activated_by/3`),
`engine/entity_port.ex` (callbacks, types, moduledoc), `entities/entity_port_impl.ex` (delegation),
`entities/handler_writes.ex` (validation + authorization halves; execution half arrives in R4a),
`engine/pin_rebind.ex` (`:owner_guard`), `engine.ex` (`check_entity_writes_planned/3`: fail-closed
guard only; no execution), `routers/pin_rebind` renderer;
tests `definitions/module_write_activation_test.exs`, `engine/pin_rebind_owner_module_test.exs`,
`entity_writes_gates_test.exs` edit (guard case).

**R4a**: `entities/step_source.ex`, `entities/records.ex` (one line), `event_store.ex`
(`lock_instance_sequence/3`), `entities/managed_types.ex` (`owner_for_handler/2`),
`entities/handler_context.ex` (new), `entities/handler_writes.ex` (execution half), fixture modules and
pack (`test/support/modules/fixture_ledger/**`, `priv/module_fixtures/ledger_foundation.json`),
`config/test.exs`; tests `handler_writes_callers_test.exs`, the three allow-list edits, `step_source_test.exs`
and PR C's C-18 case edited, `module_write_owner_path_test.exs`, `module_write_privilege_test.exs`,
`module_write_contract_test.exs`, `module_write_idempotency_test.exs` (below-engine level).

**R4b**: `engine.ex` (plan, P0b, ctx, tail copies, EE-12 sentence), `engine/entity_port.ex` (`prepare`/`multi`
ctx), `entities/step_writes.ex` (delegation of `prepare`/`multi`/`interpret_failure`/`lines_hash` when
`module_writes` present), `routers/tasks.ex` (no change expected), tests of section 11 rows
engine/*.

**R5**: `engine.ex` service plan and S4 guard (`module_writes`, `owner`), `definitions.ex` fence
(`:module_writes_node_type_not_supported` accepts SERVICE_TASK), `docs/guides/adding-an-application-module.md`
(handler section), `module_write_service_task_test.exs` un-skipped.

Docs: DOC-UPDATER bookkeeping; 0050's consistency list and 0054 get the D6 amendment note in R2's PR;
`docs/guides/adding-an-application-module.md` gets the handler contract in R4a.

## 14. Migration, seed and inventory pins affected

| Item | PR | Effect |
|---|---|---|
| Tenant migrations | R2 | two new files; manifest entries; tenant-template staleness (anti-pattern 3396) resolved by the boot replay; versions chosen against open branches (anti-pattern 574) |
| `@expected_tenant_tables` oracle | R2 | no new table; ELIXIR-DEV greps for any column-set pin of `process_definitions`/`tenant_modules` (NOT VERIFIED) |
| Event types / seed counts | none | `TASK_ENTITY_WRITES_APPLIED` exists; payload keys additive |
| Registered-module list pins | R4a | `config/test.exs` +2 modules; `catalog_test.exs` and any golden updated |
| `source.*` metadata | R4a | declarative: byte-identical (golden); handler: +3 keys |
| `lines_hash` | R4b | unchanged without `module_writes` |
| Allow-lists | R4a | three one-line edits (7.5) |
| Existing installs | R2 | `tenant_modules.manifest_hash` NULL: such a tenant cannot activate a handler-calling definition until reinstall or the 0055 upgrade path (OQ-R7) |
| Pre-merge inventory (R3) | R3 | count of non-terminal instances and definitions whose graph already carries a `module_writes` attribute (should be zero: no code reads it today); result in the PR body |

## 15. Open questions needing a supervisor ruling

* **OQ-R1 PinRebind semantics (F-R3).** D6 property 4 has no operation to guard: PinRebind cannot
  change an instance's definition; `:module` is the sub-process reference pin with no consumer.
  Recommend D-R.14 (fail-closed refusal of `:module` entries for stamped instances + a pin test).
  Alternative: test-only, no PinRebind code change. Ruling needed because this edits PinRebind.
* **OQ-R2 Body hash (D-R.8).** Four stamp columns instead of three. Recommend yes: without
  `owner_body_hash` the stamp does not detect a hand-edited snapshot or graph, contradicting "re-verified
  at run time from the pinned snapshot". Alternative: three columns plus row/graph immutability only.
* **OQ-R3 Strict compiled-hash equality.** Recommend requiring `installed hash == current compiled
  hash` at activation and run time (a module build whose handler surface changed fails closed until the
  0055 upgrade path re-stamps). Cost: after a deploy that changes a module's manifest, handler flows
  refuse until upgrade. Alternative: require only `row == installed`, and let the compiled registry
  decide (a removed handler is still refused).
* **OQ-R4 Create-only handlers.** `command_multi/3` supports only create (F-R5). A handler that
  updates a balance or checks stock under lock needs `command_multi` update support, with its own lock
  and `expected` rules. Recommend a separate requirement before WMS slice 5; REQ-501 ships the
  mechanism with create-only writes.
* **OQ-R5 Declaration shape (D-R.6).** Separate `module_writes` attribute (recommended) versus a
  line kind inside `entity_writes`.
* **OQ-R6 Activator authority (D-R.16).** Recommend reusing `:EntitiesRecordsWrite` + active-user for a
  graph with `module_writes`. Alternative: `:DefinitionsActivate` only, which changes
  `recorded_activator/1` (it requires `EntitiesRecordsWrite` in the recorded set).
* **OQ-R7 Pre-existing installs.** Tenants that installed a module before R2 have no installed hash
  and cannot call handlers until reinstall or 0055. Acceptable? (No handler ships before WMS slice 5.)
* **OQ-R8 Allow-list edit in #2596's test.** One line in `managed_types_callers_test.exs`. Confirm the
  ordering with #2596 (whichever merges second resolves the one-line union), or authorise R4a to hold the
  scan inside the new file by splitting R1 out of the shared helper (larger diff; not recommended).
* **OQ-R9 Stamped-row lifecycle.** Hard delete of a stamped DRAFT, and deprecation/archival, are left
  to the tenant (a tenant owns its tenant). Confirm.
* **OQ-R10 `sys` argument source.** Included (kind `:sys_ref`) because the issue lists it in scope;
  with create-only handlers it has no consumer except reading a minted id. Veto allowed: dropping it
  removes `:module_write_sys_*` codes and the `sys` source from 5.1 with no other effect.
* **OQ-R11 Read access of stamp fields.** `owner_module`/`owner_module_version` are returned by
  `GET /definitions` (read-only); hashes are not. Confirm.

## 16. Deferred (not REQ-501)

* update/delete kinds in `command_multi` and handler record-version/`expected` semantics (OQ-R4);
* the first real ledger handler and the `(instance, node, attempt)` stock business key (WMS slice 5);
* script outputs as commands (0053 hook 1/2, #2534 7c); after-commit triggers (outbound mirror);
* module upgrade/re-stamp and migration semantics (0055); uninstall; per-module hash recording of
  handler CODE (only the declared surface is hashed);
* a tenant-defined handler of any kind; `{"response": key}` sources; handler `_sys` outputs;
* scoped types and the `scope_node_paths` rule-3a lock (0051);
* cross-tenant promotion of stamped definitions (refused by construction: the promoted row is unstamped).
