# Adding an application module

This is the end-to-end guide ISS-0846 asks for: how to add a new **application
module** (HR, WMS, ERP, project management, …) to Letflow, per
[`docs/migration/decisions/0039-platform-module-solution-layering.md`](../migration/decisions/0039-platform-module-solution-layering.md)
(0039) D1–D8. 0039 D8 is explicit that no such module is built speculatively —
this guide exists so that when a real client solution needs one, the
implementing agent does not have to reverse-engineer the contract from the one
module that exists today, `exam`. Every path, module and function cited below
is taken directly from the current `exam` module (`lib/letflow/modules/exam/`,
`priv/modules/exam/`, `web/src/modules/exam/`) — treat it as the worked
example throughout, not as a template to imitate structurally without reading
its own moduledocs.

Read [`docs/migration/stage-11-modular-platform.md`](../migration/stage-11-modular-platform.md)
for the phase history (P1 mechanism, P2 exam extraction, P3 solutions) and
0039 in full before starting; this guide assumes both.

## 1. Layout

A module has up to three directories, mirroring the three places platform
code already lives:

| Layer | Path | Contains |
|---|---|---|
| Backend | `lib/letflow/modules/<id>/` | Entry module `Letflow.Modules.<Id>` at `lib/letflow/modules/<id>/<id>.ex` (never at `lib/letflow/modules/<id>.ex` — that path is reserved for core mechanism files), plus the module's own runtime code, e.g. `lib/letflow/modules/exam/session.ex`, `lib/letflow/modules/exam/router.ex`, `lib/letflow/modules/exam/certificate.ex`. |
| Pack/data | `priv/modules/<id>/` | The module's solution-pack document (`pack.json`) and any entity-definition JSON it installs, e.g. `priv/modules/exam/pack.json`, `priv/modules/exam/entity_definitions/*.json`. |
| Frontend | `web/src/modules/<id>/` | The module's `ModuleDefinition` export (`index.ts`), its route components, API client, and its own `__tests__/`, e.g. `web/src/modules/exam/index.ts`, `web/src/modules/exam/examRoutes.tsx`, `web/src/modules/exam/exam.api.ts`. |

Core mechanism files that a module must **never** duplicate or fork live
one level up, with no subdirectory, and are shared by every module:

- `lib/letflow/modules/module.ex` — the `Letflow.Modules.Module` behaviour.
- `lib/letflow/modules/catalog.ex` — `Letflow.Modules.Catalog`, the only core
  file permitted to reference a file inside a module's own subdirectory (D3).
- `lib/letflow/modules/installs.ex` — `Letflow.Modules.Installs`, the tenant
  install/list/settings context.
- `lib/letflow/modules/tenant_module.ex` — `Letflow.Modules.TenantModule`,
  the Ecto schema for the `tenant_modules` table.
- `web/src/modules/registry.ts` and `web/src/modules/types.ts` — the frontend
  mirror of the same split; `registry.ts` is the one sanctioned importer of
  module code on the frontend.

## 2. The `Letflow.Modules.Module` behaviour and `defmanifest`

Every module's entry file (`lib/letflow/modules/<id>/<id>.ex`) implements
`@behaviour Letflow.Modules.Module` (`lib/letflow/modules/module.ex`), which
declares three callbacks:

- `manifest/0` — **required**, returns the `t:Letflow.Modules.Module.manifest/0`
  map (see §3 below for its fields).
- `router/0` — **optional** (`@optional_callbacks router: 0, on_install: 2, on_install: 3`),
  returns the `Plug.Router`-implementing module itself, not a started process.
- `on_install/2` — **optional**, `(prefix :: String.t(), settings :: map()) ::
  :ok | {:error, term()}`, run inside the install transaction after the
  module's pack installs.
- `on_install/3` — **optional** (decision 0052 D3, GH 2531), `(prefix, settings,
  ctx)` where `ctx` is the `t:Letflow.Modules.InstallContext.t/0` struct (GH 2541):
  `%Letflow.Modules.InstallContext{actor_id: installer_user_id, rationale: text,
  tenant_prefix: prefix, pack_entity_definition_ids: %{name => id}}`. Its four keys
  are enforced: a caller that omits one fails at struct construction, in
  `Installs.install/3`, not inside your module. `pack_entity_definition_ids` holds the
  definitions this install's own pack inserted. Use it when
  `on_install` needs an actor and a justification, which activating entity
  definitions does (see §5a). **If a module exports both arities, ONLY
  `on_install/3` runs.**

Rather than hand-writing `def manifest/0`, import and call the
`defmanifest/1` macro (`Letflow.Modules.Module.defmanifest/1`), which both
generates `manifest/0` and raises a `CompileError` at compile time if any
`role_grants` atom is missing from `permissions`. `Letflow.Modules.Exam`
(`lib/letflow/modules/exam/exam.ex:20-76`) is the worked example:

```elixir
defmodule Letflow.Modules.Exam do
  @behaviour Letflow.Modules.Module
  import Letflow.Modules.Module, only: [defmanifest: 1]

  @impl true
  defmanifest(
    id: "exam",
    version: "0.1.0",
    depends_on: [],
    pack: "modules/exam/pack.json",
    permissions: [:ExamSessionStart, :ExamSessionRead, :ExamSessionSave,
                  :ExamSessionSubmit, :ExamSessionReportEvent, :ExamCertificateIssue,
                  :ExamAuthoringWrite],
    role_grants: %{CANDIDATE: [:ExamSessionStart, :ExamSessionRead, :ExamSessionSave,
                                :ExamSessionSubmit, :ExamSessionReportEvent, :ExamCertificateIssue]},
    required_roles: [],
    settings_schema: nil,
    route_policies: [
      {"POST", "/exam-sessions", :ExamSessionStart},
      {"GET", "/exam-sessions/:id", :ExamSessionRead},
      # ...
    ]
  )

  @impl true
  def router, do: Letflow.Modules.Exam.Router

  @impl true
  def on_install(prefix, _settings) when is_binary(prefix) do
    # seeds entity_field_restrictions rows; see the real function for the shape
    :ok
  end
end
```

`defmanifest`'s keyword-list argument must be a **compile-time literal** at
the call site (see `lib/letflow/modules/module.ex`'s own `@doc` for the full
argument contract table); a module unable to supply literals for every field
implements `def manifest/0` by hand instead — `defmanifest` is additive, not
a replacement for the `@callback` contract.

## 3. Manifest fields, permissions, role_grants, route_policies, and the Catalog fallback

The manifest map shape (`t:Letflow.Modules.Module.manifest/0`,
`lib/letflow/modules/module.ex:63-73`):

| Field | Shape | Meaning |
|---|---|---|
| `:id` | `String.t()` | the module's id, e.g. `"exam"` |
| `:version` | `String.t()` | opaque version string |
| `:depends_on` | `[String.t()]` | other module ids required installed first |
| `:pack` | `String.t() \| nil` | path (relative to `priv/`) to the module's solution-pack document |
| `:permissions` | `[atom()]` | permission atoms this module declares and owns |
| `:role_grants` | `%{atom() => [atom()]}` | which existing platform roles get which of this module's own permissions |
| `:required_roles` | `[String.t()]` | advisory only (0029 §2), not enforced |
| `:settings_schema` | `map() \| nil` | JSON-Schema-shaped description of the module's configurable settings |
| `:route_policies` | `[{method, path_pattern, permission}]` | maps each of the module's own routes, relative to its own mount, to the permission that gates it |
| `:widens_grants` (optional) | `[{role, permission}]` | declares a NARROWING (a role losing one of this module's atoms) in this version; never authorises a widening. See section 6a |

A module **declares its own permission atoms and grants them only to
existing platform roles** — it cannot create a role and cannot grant a core
permission (checked by `Letflow.Modules.Catalog.validate/1`,
`lib/letflow/modules/catalog.ex:130-169`, whose six rules are
`{:unknown_role, _}`, `{:ungranted_permission_declared, _}`,
`{:core_permission_collision, _}`, `{:unknown_dependency, _}`,
`{:duplicate_module_id, _}`, `{:undeclared_route_permission, _}`).

Two fallback points in `lib/letflow/api/authorization.ex` are how core code
picks up a module's permissions and grants without ever naming the module:

- `Letflow.Api.Authorization.permissions/0` (`authorization.ex:448`) —
  `core_permissions() ++ Letflow.Modules.Catalog.permissions()`.
- `Letflow.Api.Authorization.role_allows?/2` (`authorization.ex:1106-1108`) —
  `core_role_allows?(role, permission) or permission in Letflow.Modules.Catalog.role_grants(role)`.
  This is the **last** `role_allows?/2` clause; `:PLATFORM_ADMIN`'s existing
  catch-all (`authorization.ex:1113`) and every other core per-role clause
  are checked first, and the Catalog fallback only fires once none of them
  matched.

A module's own HTTP routes resolve their required permission through a third
fallback, `endpoint_policy_key/2`'s Catalog clause (`authorization.ex:883-895`,
`module_route_permission/3`), which matches the request's method and
sub-path against the module's own `route_policies` list.

## 4. Router mounting and the 404 gate

`Letflow.Plugs.ApiPipeline` mounts `Letflow.Routers.Modules` at `/modules`
(full path `/api/v1/modules/<module_id>/<rest...>`, `lib/letflow/plugs/api_pipeline.ex:166`),
a **plain `Plug`**, not `Letflow.Api.AuthorizedRouter` — see
`lib/letflow/routers/modules.ex`'s own moduledoc for why the authorization
check must come from the module's own `router/0`, not this dispatcher.

`Letflow.Routers.Modules.call/2` (`lib/letflow/routers/modules.ex:81-90`)
looks up `module_id` in the path, and `resolve/2` (`modules.ex:127-145`)
decides in this order:

1. `Letflow.Modules.Installs.installed?/2` — a real DB round trip, computed
   **unconditionally** (see the moduledoc's "INV-5 timing parity" section —
   this must never be skipped by a short-circuiting `with`-chain, or the
   response latency itself leaks whether the module exists).
2. `Letflow.Modules.Catalog.fetch/1` — is the id registered at all.
3. `function_exported?(entry_module, :router, 0)` — does it export a router.

All three failure modes collapse into the same `Letflow.Api.Response.not_found/1`
call — a caller cannot distinguish "module doesn't exist" from "module
exists but isn't installed for you" from "module exists, installed, but has
no router" (D5: "a module's absence is not information to leak").

`Letflow.Modules.Exam.Router` (`lib/letflow/modules/exam/router.ex`) is the
module's own `AuthorizedRouter`-based router, reached only after all three
checks above pass; its routes live at
`/api/v1/modules/exam/exam-sessions/…`.

## 5. Pack location and `on_install/2` / `on_install/3`

A module's solution-pack document lives under `priv/modules/<id>/`, e.g.
`priv/modules/exam/pack.json` (`pack_id` `"bilimbaga-question-bank"`), with
any entity-definition JSON alongside it in `priv/modules/exam/entity_definitions/`.
The manifest's `:pack` field is a path **relative to `priv/`**
(`"modules/exam/pack.json"`), resolved via
`Path.join(Application.app_dir(:letflow, "priv"), pack_path)`
(`lib/letflow/modules/installs.ex`'s `read_pack_document/1`).

`Letflow.Modules.Installs.install/3` (`lib/letflow/modules/installs.ex:70-84`)
does all of this inside **one** `Repo.transaction/1`:

1. reject an unknown module id, an already-installed module, or a module
   whose `depends_on` isn't fully satisfied;
2. if `manifest.pack` is set, install it through the **existing**
   `Letflow.Definitions.SolutionPack.install/3` (no second pack installer);
3. insert the `tenant_modules` row;
4. call the module's `on_install/3` if exported, otherwise its `on_install/2` if
   exported (never both).

Any step failing rolls back every write, pack install included.

> **BREAKING (PR #2539, GH #2531).** `POST /api/v1/tenant/modules` and `POST /api/v1/tenant/solutions` now REQUIRE a non-blank `rationale` in the body; a missing or blank one is 422 `rationale is required` and nothing is installed (`lib/letflow/routers/tenant_modules.ex:66-76`, `lib/letflow/routers/tenant_solutions.ex:44-51`). A solution install applies ONE rationale to each of its modules. Internal, non-HTTP callers of `Installs.install/3` pass a fixed, reviewed constant (`lib/letflow/modules/installs.ex:31-35`, `fetch_rationale/1` at `:267`). `on_install/3` receives `ctx`, a `%Letflow.Modules.InstallContext{actor_id: installer_user_id, rationale: text, tenant_prefix: prefix, pack_entity_definition_ids: ...}` struct (`lib/letflow/modules/install_context.ex`; the callback contract is `lib/letflow/modules/module.ex:33-40`). A module whose `on_install/3` calls `Letflow.Modules.EntityActivation.activate_and_promote/3` activates and promotes its own pack's entity definitions (`entity_activation.ex:61-67`; activation is not automatic: a module that does not call the helper gets none). If a same-name definition already exists in the tenant, active or not, the install fails with `{:entity_name_conflict, name}` and rolls back (`entity_activation.ex:98-100`; section 5a).

**The install rationale is required (decision 0052 D3, breaking).** `install/3`
takes `opts[:rationale]`: a non-blank string, the installer's own justification.
Missing, non-string or blank returns `{:error, :rationale_required}` before anything
is written. The HTTP routes require it in the body and never synthesise one:
`POST /api/v1/tenant/modules` `{"module_id": "...", "rationale": "..."}` and
`POST /api/v1/tenant/solutions` `{"solution_id": "...", "rationale": "..."}` (one
rationale for every module of the solution); a missing or blank value is 422
`rationale is required`. An internal, non-HTTP caller passes a fixed, reviewed
constant naming its cause (for example `mix letflow.seed.exam_fixtures`:
`"seed: exam fixtures (mix letflow.seed.exam_fixtures)"`). This applies to every
module, including ones that only export `on_install/2`.
`Letflow.Modules.Exam.on_install/2` (`lib/letflow/modules/exam/exam.ex:97-120`)
is the worked example: it seeds four `entity_field_restrictions` rows,
idempotently (`on_conflict: :nothing`), so calling it twice against the same
tenant schema is a safe no-op.

### 5a. Making packed entity types writable at install (decision 0052 D2, D5, D6)

A pack installs entity definitions `:inactive`, and activation alone creates no
table or constraint. A module whose entity types must be writable and constrained
right after install does that in its reviewed `on_install/3`, inside the install
transaction, with the shared helper:

```elixir
@impl true
def on_install(prefix, _settings, ctx) do
  # FK-DAG order: FK targets before referrers (pack content; state it explicitly).
  Letflow.Modules.EntityActivation.activate_and_promote(prefix, ctx, ["parent", "child"])
end
```

For each name it checks, by id, that the tenant has exactly one definition of that
name and that it is the one THIS install's pack just inserted, still `:inactive`
(`ctx.pack_entity_definition_ids`). A name the pack did not ship is
`{:entity_definition_missing, name}`; any other same-name definition, active or not, is
`{:entity_name_conflict, name}`, so install never adopts or supersedes a tenant's own
type. It activates the row with the installer as activator and the rationale verbatim,
re-checks that the activated row is that one, and registers and runs
the column promotions that create the table with its real `REFERENCES` and unique
constraints. It then fails the install if any promotion row for these types is
`pending` or `ddl_failed`. A test (`test/letflow/modules/install_activation_test.exs`,
D7) proves that on a failure everything rolls back: no table, constraint,
definition, promotion or `tenant_modules` row survives. Process definitions are NOT
activated this way (0052 D4).

### 5b. Process-writable entity types (`writable_by_process`, GH #2587, decision 0054 D4a.2)

`writable_by_process` is an optional top-level boolean of an entity definition
document. Absent or `false` means a process step may NOT write records of the type;
`true` declares that it may (the write path itself is a later PR). Rules:

- **Who may set it.** Only a principal holding `:EntitiesDefinitionsWrite`, through
  `POST /entities/definitions` followed by `POST /entities/definitions/:name/activate`.
  It is part of the logical shape, so setting or clearing it is a new version to activate.
- **Module-managed types never carry it.** `Letflow.Entities.Definitions.create_definition/3`
  refuses `true` on a type with a `managed_by` stamp, so a module's packed types must
  not declare it.
- **A solution pack cannot carry it.** A pack install (`:DefinitionsCreate`) containing
  `writable_by_process: true` is refused and nothing is installed (GH #2619 tracks a
  reviewed pack path). Until then an administrator sets the flag AFTER install, by
  creating and activating a new version under `:EntitiesDefinitionsWrite`. Pack export
  emits `definition_json` verbatim, so an exported pack that carries the flag is refused
  on re-import until #2619.
- **Denied names (interim, fail closed).** No metadata classifies entity types yet, so
  `true` is also refused when the type name (compared lower-cased) matches one of these
  (`Letflow.Entities.ProcessWritable`; adding an entry is a reviewed diff; GH #2618
  replaces the list with a type classification):
  - prefixes: `org_`, `user_`, `users_`, `role_`, `roles_`, `permission_`,
    `permissions_`, `principal_`, `principals_`, `group_`, `groups_`, `membership_`,
    `attachment_`, `attachments_`;
  - exact names: `org`, `orgs`, `user`, `users`, `role`, `roles`, `permission`,
    `permissions`, `principal`, `principals`, `group`, `groups`, `membership`,
    `memberships`, `attachment`, `attachments`.
- **The refusal message names the matched rule.** The stable rule code is
  `writable_by_process_not_permitted` (HTTP 422, path `writable_by_process`); the message
  is one of `the entity type is managed by a module`, `the name matches the denied prefix
  "<prefix>"` or `the name "<name>" is denied`. A false positive such as `user_feedback`
  therefore explains itself; rename the type or wait for GH #2618.

**`entity_writes` on a HUMAN_TASK node (GH #2587 / REQ-499 PR B1 validation, PR B2 execution).** A
HUMAN_TASK node may declare up to 20 `create` lines in its `entity_writes` attribute
(`op`, `entity_type`, `fields` as `{"var": name}` / `{"const": value}` sources, optional
`output_record_id_var` of the strict shape `_sys.<one [A-Za-z0-9_]+ segment>`). Every line is
validated at each activation path (activate, version rollback, promotion apply) by
`Letflow.Entities.StepWrites.validate_lines/2`, and a refusal is 422 `entity_writes_invalid`
(node id, line index, stable code; no field name or value). A line may target only a type that
is ACTIVE, non-managed, `writable_by_process` and `append_only`; a `managed_by` type is never a
declarative target (a module writes its own types through its own handler). The activating
principal must hold `:EntitiesRecordsWrite` and be an active user of the tenant: its authority
is recorded in `process_definitions.activated_by` (never settable through a request body).
Activated lines RUN when the task is completed (PR B2): in the same transaction as the task
completion, through `Records` with the tenant authority, as the delegated privilege recorded in
`activated_by` (the completer's own role is not what authorises the write; the completer's
field restrictions are still applied). At completion the engine re-checks, on the pinned graph
and the CURRENT type definition: the 20-line cap, create-only, the recorded `(entity_type,
"create")` pair, `writable_by_process`, `append_only`, not managed, and that the activator is
still an active user (checked before the transaction, so a deactivation is honoured one
completion late). A refusal rolls everything back, the task stays pending, and the response is
one code and the declared line index: 403 `write_not_permitted` (one body for every cause),
422 `validation_failed`/`entity_append_only`/`idempotency_conflict`/`entity_type_inactive`, 503
`entity_write_contention` (retryable), 409 `entity_write_needs_reactivation` (the activator was
deactivated, or its recorded `activated_by` is unsigned, forged, edited or copied, or the
signing key is rotated or disabled (GH #2644): cancel the instance and re-activate the definition,
which re-signs it; rollback and promotion also sign). The
engine-written `_sys.*` values are never returned to a client. `line_index: 20` with
`validation_failed` means the 20-line cap was exceeded (a hand-edited snapshot), not a declared
line. Pilot limit: scoped-type and
scope-column refusals are vacuous until decision 0051 `scope_node` exists.

**`entity_writes` on a SERVICE_TASK node (GH #2587 / REQ-499 PR C).** A SERVICE_TASK node
(HTTP route or script-bound) may declare the same `entity_writes` lines, under the same activation
validation, the same recorded activator authority and the same line shape (sources `var` and `const`
only, `create` on append-only `writable_by_process` types). The lines run in the same transaction
as the apply of the service result, with the platform actor as event actor and the recorded
`activated_by` as the delegated privilege. A service completion has no client and no pending task,
so a refusal of the entity step lands the instance in ERROR with a DLQ entry (and rolls the apply
back, nothing partial) instead of answering a request; see
`docs/runbooks/service-task-entity-write-refusal.md`. `module_writes` (section 5c) is accepted on
a SERVICE_TASK node too since REQ-501 R5. As for a HUMAN_TASK node, the recorded `activated_by` authority is the graph-wide set of (entity type, `create`) pairs, not a per-node set.

Pilot limits: (a) the activation-time activator check requires `:EntitiesRecordsWrite`, not
`:DefinitionsActivate`, so a rollback or promotion activator legitimately omits the latter; (b)
promotion and tenant promote resolve the activator in the TARGET tenant, so a promoting
principal who is not a user of the target tenant (a test-tenant actor, a platform operator in
another tenant) gets 422 `entity_write_activator_not_in_target_tenant` and nothing is written:
create the graph as a draft in the target tenant and activate it there; (c)
`process_definitions.activated_by` is part of the `definition.activate` audit entry's
`after_state` (the whole row is serialised), so it travels with any wholesale `after_state`
fan-out; (d) treat `activated_by` as untrusted data in any consumer (a sandbox fixture loader
can set any column in a sandbox schema).

### 5c. Write handlers (GH #2590 / REQ-501, decision 0054 D6)

A module that must write its OWN managed entity types from a process step declares write
handlers in its manifest (`write_handlers:`, validated by `Catalog.validate/2` rule 10) and
implements them in a module under its own namespace. The engine runs a handler inside
a HUMAN_TASK completion (REQ-501 R4b) or inside the apply of a SERVICE_TASK result, HTTP or
script-bound (R5); this section is the contract a handler is written against.

* A handler is `fun(multi, ctx, args)` returning `{:ok, multi}` or `{:error, :invalid_arguments |
  :not_permitted}`. `ctx` is a `Letflow.Entities.HandlerContext` (ids and names only, no
  authority); `args` are resolved argument values only (never the instance variables).
* The ONLY writer is `Letflow.Entities.HandlerWrites.create(multi, ctx, %{entity_type: type,
  field_values: map})`, which returns `{:ok, multi}` or `{:error, :target_not_registered |
  :too_many_writes | :invalid_write_command}`. It writes only the handler's registered `targets`
  (each in `manages_entity_types`), at most 49 creates per call, with the field restrictions of
  the completing user, an `Owner` the platform derives from the Catalog registration, and a
  platform-built `StepSource` (module, handler, ordinal). A handler never supplies a key, an
  actor, a prefix or an `Owner`.
* A handler reads no table, holds no `repo`, opens no transaction, performs no I/O, starts no
  process, and uses `Ecto.Multi` only to compose (`new/0`, `append/2`). The scan H4 in
  `test/letflow/entities/handler_writes_callers_test.exs` flags a handler file that references
  `Repo`, `Records`, `Owner`, `StepSource`, `EventStore`, `Ecto.Query`, a process or I/O module, an
  atom-creating call, or any `HandlerWrites` function but `create/3`.
* The manifest hash covers the declared surface only (`id`, `version`, managed types, each
  handler's name, function, targets and args), not handler CODE: bump `version` when handler
  behaviour changes.
* The handler's update/delete behaviour does not exist: `create` only (OQ-R4).
* The same handler runs from a HUMAN_TASK and from a SERVICE_TASK node. On a SERVICE node there is
  no completing user: the event actor is the platform sentinel, the field restrictions applied are
  the ACTIVATOR's (`ctx.subject_id`, `ctx.activator_id`), and `ctx.origin` is `{:dispatch, id}`
  (a HUMAN node: `{:task, id}`). A handler never branches on the origin: write the same
  `create/3` calls. A refusal there lands the instance in ERROR + DLQ (it cannot stay pending),
  so keep argument validation strict and total: a `var` argument may be fed by a service response
  or a script output, and values are byte-capped (64 KiB per value, 256 KiB per line). A `var`
  argument on a SERVICE_TASK node is EXTERNAL data: validate its type, shape and size in the handler.

## 6. Registration: `config/config.exs`, `config/test.exs`, and `catalog_test.exs`

`Letflow.Modules.Catalog` reads its module list once, at compile time, via
`Application.compile_env(:letflow, :modules, [])` (`lib/letflow/modules/catalog.ex:57`).
Registering a new module means editing **both** config files, plus the test
that pins their contents:

- `config/config.exs:60` — `config :letflow, :modules, [Letflow.Modules.Exam, Letflow.Modules.Org, Letflow.Modules.CatalogItems]`
  — the real, production module list. Add your entry module here.
- `config/test.exs:294` — `config :letflow, :modules, [...]` — the test-env
  list, currently `[Letflow.Modules.Exam, Letflow.Modules.Org, Letflow.Modules.CatalogItems,
  Letflow.Modules.Fixture, Letflow.Modules.FixtureDependent,
  Letflow.Modules.FixtureFailingInstall, ...]` (more fixtures follow;
  prod entries first, then the test-only fixtures under
  `test/support/modules/`). Add your entry module here too if it needs to be
  exercised in the test env (a genuinely new production module should be
  registered exactly like `Letflow.Modules.Exam` and `Letflow.Modules.Org` were).
- `test/letflow/modules/catalog_test.exs` — **this is ISS-0846's flagged
  root cause of the stale-`CatalogTest` issue.** Two assertions there
  hardcode the module list and go stale unless updated in the same change:
  - `"entry_modules/0 returns the registered test-only fixtures, in config
    order"` asserts `Catalog.entry_modules() ==
    [Letflow.Modules.Exam, Letflow.Modules.Org, Letflow.Modules.CatalogItems, Letflow.Modules.Fixture, ...]` literally — add
    your module to this literal list, in the same order as `config/test.exs`.
  - `"config/config.exs registers exactly [Exam, Org, CatalogItems]"` greps the
    real file (`~r/config :letflow, :modules, \[\s*Letflow\.Modules\.Exam,\s*Letflow\.Modules\.Org,\s*Letflow\.Modules\.CatalogItems\s*\]/`;
    the line is wrapped by `mix format` once it passes 98 columns, hence the `\s*`)
    — update this regex to match your new `config/config.exs` line.

Forgetting either edit does not fail compilation — it fails exactly these
two assertions the next time `mix test` runs, which is why ISS-0846 calls
this out by name.

## 6a. The effective-permission golden file (GH #2586 / REQ-498)

`priv/permission_matrix/effective.golden` is the committed effective
permission matrix: one line per role x permission atom
(`Authorization.roles/0` x `Authorization.permissions/0`) with `allowed`,
the atom's `owner` (`core` or `module:<id>`) and `via` (`core` when the row
is true without any manifest `role_grants`, `grant` when only a manifest's
`role_grants` makes it true, `-` when false). Grants are compiled code
evaluated without a tenant, so a module version that adds a role grant
takes effect for every tenant at deploy; this file is the control
(decision 0055 D7).

`mix letflow.permission_matrix --check` runs two checks. FRESHNESS: the
working-tree golden must equal the matrix the code computes. CLASSIFICATION:
the golden as committed at the BASE commit (read from git, never your copy)
against the computed matrix. The diff rule:

- The only pre-approved change: a NEW atom of your module that only your
  module's `route_policies` name (no core route policy, no other module),
  true for exactly `PLATFORM_ADMIN` and `TENANT_ADMIN`.
- WIDENING `role_grants` (any role gaining an atom it did not hold, an
  existing atom granted to a new role, a new atom granted to any role
  other than PLATFORM_ADMIN/TENANT_ADMIN, an atom a core route policy uses)
  is REFUSED, with no override, until per-tenant grant snapshots exist.
  Regenerating the golden in the same PR does not help: classification
  never reads the working-tree golden.
- NARROWING (a role losing one of your atoms, or an atom removed) is allowed
  but must be declared exactly in the manifest as
  `widens_grants: [{:ROLE, :Atom}]` AND the manifest `version` must change in
  the same PR (a declaration is only evaluated for a module whose version
  changed; otherwise it is inert). An undeclared narrowing fails, and so does
  a declaration that matches no narrowing. A declaration naming a widening
  row is itself a failure. Clear the list at the next version bump.
- A CORE change (a new core atom, a `core_role_allows?/2` clause, `@roles`)
  is not refused but must regenerate the golden in the same PR; the report
  prints `CORE MATRIX CHANGE` and SECURITY-REVIEWER must review it.
- Fail closed: a CORE rule that makes a module atom true for any role other
  than PLATFORM_ADMIN/TENANT_ADMIN is refused as `:core_rule_on_module_atom`
  (such a core role cannot land until per-tenant grant snapshots exist).

Commands (run `git fetch origin main` first; the local baseline is
`git merge-base HEAD origin/main`):

- check: `MIX_ENV=dev mix letflow.permission_matrix --check`
  (PowerShell: `$env:MIX_ENV='dev'; mix letflow.permission_matrix --check`);
- regenerate: `MIX_ENV=dev mix letflow.permission_matrix --write`.

It never runs under `MIX_ENV=test` (the task refuses it): `config/test.exs`
registers the `test/support/modules` fixtures, so that would not be the
production matrix. For the same reason it is not part of
`mix letflow.check.static`; CI runs it as its own `backend_static` step.

Rules the check enforces on the module list and manifests:

- `config :letflow, :modules` may be set only in `config/config.exs` and
  `config/test.exs`, and the lists `Config.Reader` yields for `:prod` and for
  `:dev` must both equal the compiled one (no override in `prod.exs`,
  `dev.exs` or `runtime.exs`).
- One permission atom may be declared by only one module
  (`Catalog.validate/1` rule 9, `{:permission_declared_by_other_module, _, _}`).
- Every production manifest must pass `Catalog.validate/1`, even when it is
  not registered in `config/test.exs`.
- Removing a module: drop it from `config/config.exs` AND delete
  `lib/letflow/modules/<id>/` in the same PR (a module dropped from the list
  while its directory remains fails the check).

## 7. `tenant_modules` backfill migrations

`tenant_modules` (created by `priv/repo/migrations/20260925000001_create_tenant_modules.exs`)
is a **tenant-scoped** table — the `if prefix() do` guard is mandatory, and
so is registering the migration file in `Letflow.TenantProvisioning`'s
`@tenant_scoped_migration_manifest` (both halves, per that migration's own
comment).

If your new module replaces functionality that existing tenants already have
installed some other way (the way `exam` replaced BilimBaga's direct pack
install), write a **second**, separate migration that backfills a
`tenant_modules` row for every tenant that qualifies — otherwise D5's 404
gate cuts those tenants off the day the module ships. The worked example is
`priv/repo/migrations/20260926010001_backfill_exam_tenant_modules.exs`: for
every tenant schema, it derives the tenant's UUID from the schema name
(`Letflow.TenantProvisioning.tenant_id_for_schema_name/1`), then inserts an
`INSERT ... SELECT ... WHERE EXISTS (SELECT 1 FROM public.solution_pack_installs
WHERE tenant_id = $1 AND pack_id = 'bilimbaga-question-bank') ON CONFLICT
(module_id) DO NOTHING`. If your module has no such predecessor state to
backfill (a genuinely new module, per 0039 D8), skip this step — a
brand-new module starts with zero tenants having it, which is correct.

## 8. `settings_schema` and the settings write route

A module's configurable settings are declared in its own manifest's
`:settings_schema` (a JSON-Schema-shaped map, or `nil` if the module has no
settings — `exam`'s is `nil`, so it has no live worked example in this
codebase yet; follow `Letflow.Modules.Installs.put_settings/3`'s validation
rules below regardless).

`PUT /api/v1/tenant/modules/:module_id/settings` (`authz_put "/:module_id/settings"`,
`lib/letflow/routers/tenant_modules.ex:44-46`, gated by `:ModulesManage`)
delegates to `Letflow.Modules.Installs.put_settings/3`
(`lib/letflow/modules/installs.ex`), which:

1. looks the module up via `Catalog.fetch/1` — unknown id →
   `{:error, {:module_not_installed, module_id}}`;
2. validates `settings` against `manifest().settings_schema`: `nil` schema
   accepts only `%{}` (any non-empty map is
   `{:error, {:settings_validation_failed, :no_schema}}`); a real schema is
   checked with the existing `Letflow.EventStore.Registry.JsonSchema.validate/2`;
3. requires a `tenant_modules` row to already exist for that tenant (not
   installed → `{:error, {:module_not_installed, module_id}}`);
4. updates the row's `settings` field via `TenantModule.settings_changeset/2`.

The `prefix` used throughout is `conn.assigns.scoped_opts`'s prefix only
(INV-1) — never a body field.

## 9. Solution manifests

A solution (`priv/solutions/<id>.json`) is a manifest, not code — "a list of
modules, versions and default settings," per 0039 D6. Two exist today:

```json
// priv/solutions/bilimbaga.json
{
  "id": "bilimbaga",
  "modules": [{"module_id": "exam", "version": "0.1.0", "settings": {}}]
}
```

```json
// priv/solutions/fixture-bundle.json (test-only, exercises dependency order)
{
  "id": "fixture-bundle",
  "modules": [
    {"module_id": "fixture_dependent", "version": "0.1.0", "settings": {}},
    {"module_id": "fixture", "version": "0.1.0", "settings": {}}
  ]
}
```

Installing a solution installs each listed module in dependency order, then
writes each module's declared default `settings`. A solution has no runtime
identity of its own after install — the tenant simply ends up with the
modules. If your new module ships as part of a client solution, add or
extend a `priv/solutions/<id>.json` file; if it's meant to be installed
standalone (`POST /api/v1/tenant/modules` with `module_id` and the required `rationale`), no solution
manifest is required at all.

## 10. Frontend `ModuleDefinition` and the registry

`web/src/modules/types.ts` defines `ModuleDefinition`:

```ts
export interface ModuleDefinition {
  id: string
  depends_on?: string[]
  routeObjects: RouteObject[]   // plain routes -- no guard wrapper, registry adds it
  navItems: ModuleNavItem[]
}
```

A module exports exactly one of these from `web/src/modules/<id>/index.ts`.
The worked example, `web/src/modules/exam/index.ts`:

```ts
export const examModuleDefinition: ModuleDefinition = {
  id: 'exam',
  depends_on: [],
  routeObjects: examRouteObjects,
  navItems: [
    { to: '/exam', label: 'Exams', roles: ['CANDIDATE'] },
    { to: '/admin/bilimbaga', label: 'Question Bank', roles: ['PLATFORM_ADMIN', 'PROCESS_OPERATOR'] },
  ],
}
```

`web/src/modules/registry.ts` is the **one sanctioned importer** of module
code (0039 D3): it holds `REGISTERED_MODULES: ModuleDefinition[]` (today just
`[examModuleDefinition]`), wraps each module's `routeObjects` in
`ModuleGuard` (`web/src/components/routing/ModuleGuard`) to derive
`REGISTERED_MODULE_ROUTE_OBJECTS`, and exposes
`getInstalledModuleDefinitions/2` and `getInstalledModuleNavItems/2`, both
filtered by the tenant's actual `installed_modules` list (read from `GET
/me`, per `Letflow.Routers.Me`'s `installed_modules` field, backed by
`Letflow.Modules.Installs.list_installed/1`). Adding a module means: write
its `index.ts`, then add exactly one line —
`import { yourModuleDefinition } from './your_id/index'` plus one array
entry in `REGISTERED_MODULES` — in `registry.ts`. No other frontend file
should import module code directly.

## 11. Boundary checks

Two checks enforce D3 — that core code never names a module, and a module
only reaches the modules its own `depends_on` lists — and both run in CI:

- **Backend** — `mix letflow.check_boundaries`
  (`lib/mix/tasks/letflow.check_boundaries.ex`), built on `mix xref graph
  --format plain` with no new dependency. It fails the build if any file
  outside `lib/letflow/modules/<id>/` references a file inside one (except
  `lib/letflow/modules/catalog.ex`, the one sanctioned exception), or a file
  in module `a` references a file in module `b` when `b` is not in `a`'s
  `depends_on`. Wired into the `mix letflow.check` alias, after `compile
  --warnings-as-errors` and before the test alias.
- **Frontend** — the ESLint `no-restricted-imports` rule in
  `web/.eslintrc.json`: the default override (lines 25–34) blocks any file
  from importing `@/modules/**` or `**/modules/**` except `registry` and
  `types`; a per-module override (lines 47–60, scoped to
  `src/modules/exam/**`) permits that module's own files to import
  `@/modules/exam/**` (and the two core files) but not another module's
  subdirectory; and a separate override (line 41) turns the rule off
  entirely inside `src/modules/registry.ts` itself, since it is the
  sanctioned importer. A new module needs its own `files:
  ["src/modules/<id>/**"]` override block added to `web/.eslintrc.json`,
  mirroring the `exam` block with `<id>` substituted throughout.

## 12. Explicitly out of scope (do not build this as part of adding a module)

- **Uninstall.** 0039 D5: "No uninstall in S11" — removing a module safely
  means deciding what happens to its definitions and tenant data, which is
  not decided anywhere yet. `docs/migration/stage-11-modular-platform.md`'s
  "Open items" section records it as open, not assigned.
- **Client scripts.** 0039 D7: tenant-attached Lua extension points need a
  runtime invocation path and an audit path that do not exist yet (0029 §1).
  A module's `on_install/2` / `on_install/3` is reviewed **code**, not pack
  content, and does not reopen this.
- **The `CANDIDATE` role.** It is exam-specific but stays a **platform** role
  atom in `Letflow.Api.Authorization.roles/0` (`@roles`,
  `role_from_string("CANDIDATE")`) — moving it into the exam module is an
  open item (0039 "Relationship to earlier decisions", 0013) needing its own
  design, not something a new module's implementer should attempt as a side
  effect.
- **New pack sections.** The solution-pack section set stays closed
  (0026/0027/0029); a module wraps a pack, it does not add pack sections. A
  requirement that seems to need a new section needs its own decision record
  first.
- **A supervised process per module.** REQ-045 stands: a module is a code
  boundary, not a process. `Letflow.Modules.Catalog` and
  `Letflow.Modules.Installs` are both plain modules, not `GenServer`s — no
  module gets its own supervision entry unless its own design justifies one
  through the normal gates.

## Checklist for adding module `<id>`

1. [ ] Confirm 0039 D8's gate: a real client solution needs this module now —
   don't build it speculatively.
2. [ ] `lib/letflow/modules/<id>/<id>.ex` — entry module, `@behaviour
   Letflow.Modules.Module`, `defmanifest(...)` with `id`, `version`,
   `depends_on`, `pack`, `permissions`, `role_grants` (existing roles only,
   `Authorization.roles/0`), `required_roles`, `settings_schema`,
   `route_policies`.
3. [ ] Module runtime code and (if any) `router/0`, `on_install/2` under
   `lib/letflow/modules/<id>/`.
4. [ ] If the module has a pack: `priv/modules/<id>/pack.json` (+ entity
   definitions), manifest `:pack` set to the path relative to `priv/`.
5. [ ] Register the entry module in `config/config.exs`, and in
   `config/test.exs` if it needs test-env coverage.
6. [ ] Update `test/letflow/modules/catalog_test.exs`'s two hardcoded
   assertions (`entry_modules/0` literal list; the `config/config.exs` regex).
6a. [ ] Regenerate the effective-permission golden
   (`MIX_ENV=dev mix letflow.permission_matrix --write`) and run `--check`
   (section 6a): a new atom is pre-approved only when it is true for exactly
   PLATFORM_ADMIN and TENANT_ADMIN and named only by its own module's
   `route_policies`; any `role_grants` widening is refused.
7. [ ] If existing tenants need to be backfilled onto this module (replacing
   prior ad hoc functionality), write a tenant-scoped backfill migration,
   `if prefix() do` guarded, registered in
   `Letflow.TenantProvisioning.@tenant_scoped_migration_manifest`.
8. [ ] If the module has settings, confirm `Letflow.Modules.Installs.put_settings/3`'s
   JSON-Schema validation covers your `settings_schema` shape.
9. [ ] If the module belongs to a client solution, add/extend
   `priv/solutions/<id>.json`.
10. [ ] `web/src/modules/<id>/index.ts` exporting one `ModuleDefinition`; add
    it to `REGISTERED_MODULES` in `web/src/modules/registry.ts` — the only
    file that imports it.
11. [ ] Add a `files: ["src/modules/<id>/**"]` override block to
    `web/.eslintrc.json`, mirroring the `exam` block.
12. [ ] Run `mix letflow.check_boundaries` and the frontend ESLint boundary
    rule; both must pass with zero new violations.
13. [ ] Run `mix letflow.check` end to end before handoff.
14. [ ] Do not build uninstall, client scripts, a new pack section, the
    `CANDIDATE` role move, or a supervised process for this module — flag
    each as a separate decision/requirement if the work seems to need one.
