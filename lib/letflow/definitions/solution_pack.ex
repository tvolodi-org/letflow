defmodule Letflow.Definitions.SolutionPack do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Solution-pack export and install — the backing context for
  `Letflow.Routers.SolutionPacks` (REQ-078, design
  `lib/letflow/design/req078-supporting-routes.md` §8). Ports the parts of
  R-Co's `src/solution/store.zig` (`exportPack` L46, `installPack` L284) that
  Letflow has subsystems for.

  ## This module had to be BUILT, not merely routed to

  PROVENANCE (historical, not current decision authority):
  REQ-078's description called all six of its route modules "a one-to-three
  handler surface over existing context functions". That was true of five of
  them and false of this one: R-Co's two solution-pack handlers are thin only
  because they delegate to roughly 700 lines of `src/solution/store.zig`, of
  which Letflow had ported **none**. REQ-041 delivered the pack-update
  three-way diff (`Letflow.Definitions.compute_pack_update_plan/5`) plus three
  global Ecto schemas; `Letflow.Definitions.SolutionPackInstall`'s entire
  public surface is `insert_changeset/2`. `Letflow.Definitions.ExportImport`
  is a **single-definition** path and is not a substitute for a
  multi-definition pack document; it is reused here only for its
  `bpm/definition/v1` schema-version constant, so there is one version string
  in the codebase rather than two.

  ## What a Letflow pack document carries, and what it drops

  PROVENANCE (historical, not current decision authority):
  R-Co's `SolutionPackDocument` (`src/api/routes/solution_packs.zig:153-351`)
  has four content arrays. Letflow supports three of them (all but
  `service_catalog_entries`), plus a fifth section, `entity_definitions`,
  that R-Co's document never had (REQ-303–306, decision
  `0026-solution-pack-entity-definitions-section.md`):

    * `definitions` — supported (`process_definitions`, REQ-027/030).
    * `variable_schemas` — supported (`variable_schemas`, REQ-109). This is
      the whole point of REQ-078's AC8: install is one of the two write paths
      that must populate that table, and without it the table ships empty and
      REQ-061's variable-schema rejection branch stays unreachable
      (ISS-0063 / GH#212).
    * `service_catalog_entries` — **still not supported, and now settled as
      permanently NOT PERMITTED**, not merely unowned. A
      `Letflow.ServiceCatalog` now exists (REQ-191), but which
      tenant-visibility policy a packed catalog entry should install under
      — tenant-scoped-to-the-installer only (consistent with every other
      `install/3` write) or a `scope: :global`, cross-tenant-visible entry
      (which no other `install/3` write does, and which raises its own
      write-authorization question) — is decided by
      `docs/migration/decisions/0027-solution-pack-service-catalog-install-policy.md`:
      the rejection is permanent, and any needed service-catalog entry is
      provisioned out-of-band, through the existing `POST /service-catalog`
      route (gated `:AdminServicesManage`, PLATFORM_ADMIN-only in the current
      role matrix), not through a pack. This bullet previously deferred the
      decision to REQ-192, on the reasoning that resolving
      `service_catalog_entries` alongside the catalog's HTTP
      write-authorization policy (SVC-04: `:AdminServicesManage`) would
      avoid inventing a second, possibly inconsistent authorization stance
      later. That deferral was stale: REQ-192 is `done` and landed the
      service-catalog route surface *without* lifting this pack restriction.
      0027 closes that gap permanently rather than reopening it. S10's gaps
      4 (email) and 5 (PDF + QR rendering) are no longer blocked on this
      policy — see
      `docs/migration/stage-10-bilimbaga-vertical.md`'s "Open questions"
      section, which records the same thing. Export still always emits `[]`;
      install still **rejects** a non-empty array with
      `{:error, :unsupported_pack_section}` rather than silently discarding
      tenant-supplied content or guessing at a policy this module was never
      asked to decide.
    * `manifest.required_roles` — supported, **read-only**: it produces the
      advisory `role_mapping_checklist` (see `install/3`). No role is created
      and no install is ever rejected because of it.
    * `entity_definitions` — supported (REQ-304 export, REQ-305 install).
      Not part of R-Co's original document; carries named
      `Letflow.Entities.EntityDefinition` records, installed `:inactive`
      only, per decision 0026.

  ## Tenant scoping (INV-1)

  Every read `export/3` performs and every write `install/3` performs runs
  with `opts[:prefix]`, which the route derives solely from
  `Letflow.Api.Context.scoped_repo_opts/1`, i.e. solely from the authenticated
  token's `tenant_id`. No function here takes a tenant id, schema name or slug
  as a caller-supplied argument. The single exception to prefix-scoping is the
  one `solution_pack_installs` row, whose table is **global** by REQ-041's own
  design — and its `tenant_id` is *derived* from the resolved prefix via
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`, never accepted as
  a caller-supplied field.

  A definition id belonging to another tenant is invisible in the caller's
  schema, so an export naming it can only produce
  `{:error, {:definition_not_found, id}}` — never that tenant's artefact in
  the document.

  ## Install is ALL-OR-NOTHING. There is no "skipped" definition

  `installed_definition.status` is **always** `"installed"`.
  `Letflow.Definitions.create/2` has no upsert, no skip and no idempotent
  branch: it inserts, or it returns `{:error, :duplicate_name_version}` when
  `uq_definition_version` fires, which the route maps to a **409 that aborts
  the entire install**. Every packed definition that reaches the result map
  was inserted by that call; any that was not aborted the transaction before a
  result map existed.

  PROVENANCE (historical, not current decision authority):
  Consequence: **re-installing a pack whose `(name, version)` pairs already
  exist in the caller's schema is a 409, not a no-op.** This is a real
  behavioural divergence from R-Co, whose `buildIdempotentResult`
  (`src/solution/store.zig:682`, called from `:337`) returns a synthetic
  success for an already-installed pack. Letflow has no such path, and
  `uq_solution_pack_install_active` additionally makes a second install of the
  same `(tenant_id, pack_id)` a `{:error, :duplicate_pack_install}`. Named as
  a deliberate non-port, not left as an accident. If idempotent re-install is
  wanted later it needs its own requirement; it is not smuggled in here.

  PROVENANCE (historical, not current decision authority):
  `status` is nonetheless kept as a field rather than dropped, so the response
  shape stays compatible with R-Co's `serializeInstallResult`
  (`solution_packs.zig:426-463`) and a future idempotent-install requirement
  has somewhere to put `"skipped"` without changing the wire shape.

  ## `VARIABLE_SCHEMA_CONFLICT` is a deliberate non-port — and it is unreachable

  PROVENANCE (historical, not current decision authority):
  R-Co pre-checks for a conflicting `variable_schemas` row before install
  (`store.zig:419-441`). Letflow has nothing to check, and the branch could
  not fire if it existed:

    1. `Letflow.Definitions.ProcessDefinition`'s primary key is
       `@primary_key {:id, :binary_id, autogenerate: true}`, so every
       successful `create/2` mints a fresh, previously-unused `definition_id`.
    2. `create/2` never returns a pre-existing row — it inserts or errors.
    3. Step 7 below writes `variable_schemas` rows keyed **only** to ids
       produced in step 6, resolved through the
       `source_definition_id -> new_definition_id` mapping.
    4. Therefore no row an install writes can collide on
       `(definition_id, variable_key)` — the id half is new in every case. The
       `ON CONFLICT DO NOTHING` inside
       `Letflow.Definitions.register_variable_schemas/3` can only ever absorb
       a duplicate *within the same pack's own entries*, which that function
       rejects earlier with `{:error, {:duplicate_variable_key, key}}`.

  **Standing condition:** this non-port is valid *only while* install creates
  every definition it writes schemas for. If a later requirement adds an
  install mode that attaches variable schemas to a pre-existing definition,
  the conflict becomes reachable and must be reinstated.

  ## Other deliberate non-ports

    PROVENANCE (historical, not current decision authority):
    * **`409 CATALOG_CONFLICT`** (`solution_packs.zig:135`) — there is no
      catalog to conflict with (S6 service catalog).
    PROVENANCE (historical, not current decision authority):
    * **`409 TenantInactive`** (`solution_packs.zig:127-134`) —
      `Letflow.Plugs.TenantStatus` runs in `Letflow.Plugs.ApiPipeline`, before
      any sub-router, and rejects an inactive tenant's request with
      `403 tenant_inactive` for every method. A 409 branch here could never
      fire.
    PROVENANCE (historical, not current decision authority):
    * **`MODULE_NON_EXPORTABLE`** (`solution_packs.zig:83`) — Letflow has no
      process-module packaging (`process_modules.zig`, S5).
    * **503 `PoolExhausted`** — Ecto/DBConnection surfaces pool exhaustion as
      a raised `DBConnection.ConnectionError`, not an error tuple, so there is
      no tuple to match and a 503 clause would be unreachable.

  ## Known gap

  `manifest.required_roles` is always `[]` on export: nothing in Letflow
  declares per-definition roles yet. The field exists so the wire shape is
  stable and so an install document that *does* carry required roles (from
  another system, or a future Letflow that populates them) produces a
  meaningful checklist.
  """

  alias Letflow.Api.Authorization
  alias Letflow.Definitions
  alias Letflow.Definitions.ExportImport
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.JsonSchemaShape
  alias Letflow.Definitions.PackUpdateResolution
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Definitions.ValidationWarnings
  alias Letflow.Engine.VariableSchema
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @typedoc "One definition inside a pack document."
  @type packed_definition :: %{
          definition_id: String.t(),
          process_key: String.t(),
          name: String.t(),
          version: String.t(),
          graph: map()
        }

  @typedoc """
  PROVENANCE (historical, not current decision authority):
  One variable-schema row inside a pack document. `schema_content` is a JSON
  *string* in R-Co's wire format (`solution_packs.zig:299`), not a decoded
  document.
  """
  @type packed_variable_schema :: %{
          definition_id: String.t(),
          schema_name: String.t(),
          schema_content: String.t()
        }

  @typedoc """
  One entity definition inside a pack document (0026 §Consequences, REQ-303 doc §1).

  `logical_shape_version` is lowercase-hex-encoded (`Base.encode16/2`, `case: :lower`)
  -- the raw digest cannot cross a `Jason.encode!/1` boundary; see
  `Letflow.Entities.Records.hex_version/1` for the same convention applied to the
  event-envelope path.
  """
  @type packed_entity_definition :: %{
          entity_definition_id: Ecto.UUID.t(),
          name: String.t(),
          display_name: String.t(),
          definition_json: map(),
          logical_shape_version: String.t()
        }

  @type pack_document :: %{
          pack_id: String.t(),
          version: String.t(),
          bpm_export_schema_version: String.t(),
          exported_at: String.t(),
          definitions: [packed_definition()],
          service_catalog_entries: [],
          variable_schemas: [packed_variable_schema()],
          entity_definitions: [packed_entity_definition()],
          manifest: %{required_roles: [String.t()]}
        }

  @type installed_definition :: %{
          source_definition_id: String.t(),
          new_definition_id: Ecto.UUID.t(),
          process_key: String.t(),
          status: String.t()
        }

  @type role_checklist_entry :: %{role_name: String.t(), bound: boolean()}

  @typedoc """
  One artefact snapshot to capture into `solution_pack_artefact_bases` at
  install time (REQ-379 design §5.1). `content` is the artefact's own
  delivered content, pre-canonicalization.
  """
  @type artefact_snapshot :: %{
          artefact_type: String.t(),
          artefact_id: Ecto.UUID.t(),
          content: map()
        }

  @typedoc "One entity definition installed by `install/3` (REQ-305)."
  @type installed_entity_definition :: %{
          source_entity_definition_id: String.t(),
          new_entity_definition_id: Ecto.UUID.t(),
          name: String.t(),
          status: String.t()
        }

  @type install_result :: %{
          pack_id: String.t(),
          version: String.t(),
          install_id: Ecto.UUID.t(),
          installed_definitions: [installed_definition()],
          installed_entity_definitions: [installed_entity_definition()],
          variable_schemas_written: non_neg_integer(),
          role_mapping_checklist: [role_checklist_entry()],
          warnings: [String.t()]
        }

  @type export_error ::
          {:error, {:definition_not_found, definition_id :: String.t()}}
          | {:error, {:entity_definition_not_found, name :: String.t()}}
          | {:error, :empty_definition_ids}
          | Definitions.common_error()

  @type install_error ::
          {:error, :invalid_pack_document}
          | {:error, {:unknown_schema_version, actual :: String.t()}}
          | {:error, :unsupported_pack_section}
          | {:error,
             {:malformed_variable_schema, variable_key :: String.t(),
              reason :: :invalid_json | :not_a_string}}
          | {:error, Definitions.variable_schema_error()}
          | {:error, :duplicate_pack_install}
          | {:error, :missing_prefix}
          | Definitions.create_error()
          | Letflow.Entities.Definitions.create_error()
          | Definitions.common_error()

  @typedoc """
  One caller-submitted conflict resolution on an `update-apply` call
  (REQ-380 design §4.3, §4.2). `resolved_content` is required iff
  `resolution == :merged`, and must be `nil` for `:keep_local`/`:take_incoming`
  -- the router's own `@update_apply_schema` validation already enforces this
  correlation before this function is ever called; `apply_pack_update/6`
  re-checks it defensively (design §4.3 step 2, mirrors
  `decode_variable_schema/1`'s own two-layer validation precedent).
  """
  @type resolution_input :: %{
          artefact_type: String.t(),
          artefact_id: String.t(),
          resolution: PackUpdateResolution.resolution(),
          resolved_content: String.t() | nil
        }

  @typedoc "One entry of `apply_pack_update/6`'s `apply_result()` (REQ-380 design §4.3)."
  @type applied_entry :: %{
          artefact_type: String.t(),
          artefact_id: String.t(),
          classification: Definitions.classification(),
          action: :advanced_to_incoming | :advanced_to_merged | :left_unchanged
        }

  @type apply_result :: %{
          pack_id: String.t(),
          target_version: String.t(),
          applied_entries: [applied_entry()],
          resolutions_recorded: non_neg_integer()
        }

  @type apply_error ::
          {:error, {:unresolved_conflict, artefact_type :: String.t(), artefact_id :: String.t()}}
          | {:error,
             {:invalid_resolution, artefact_type :: String.t(), artefact_id :: String.t(),
              reason :: :not_a_conflict}}
          | {:error, :empty_artefact_set}
          | Definitions.common_error()

  @default_pack_version "1.0.0"

  @doc """
  Builds a multi-definition pack document from `definition_ids`, all read
  within the caller's own tenant schema (`opts[:prefix]`).

  For each id, in the order given: `Letflow.Definitions.get_by_id/2`, then
  `Letflow.Engine.VariableSchema.fetch_schemas/3` for that definition's
  variable-schema rows, flattened into the document's `variable_schemas` array
  with `schema_content` re-encoded as JSON text (R-Co's wire format).

  `{:error, :not_found}` from any id becomes
  `{:error, {:definition_not_found, id}}` and no document is produced. That is
  also the cross-tenant case: an id owned by another tenant is simply not in
  this prefix (INV-1/INV-5 — the route's 422 detail must therefore not echo
  the id, or it would confirm that some id exists somewhere).

  `pack_id` is a fresh `Ecto.UUID.generate/0`; `exported_at` is
  `DateTime.utc_now/0` in ISO 8601. `bpm_export_schema_version` reuses
  `Letflow.Definitions.ExportImport`'s `bpm/definition/v1` constant —
  one version constant in the codebase, not two.
  """
  @spec export(
          definition_ids :: [String.t()],
          version :: String.t() | nil,
          opts :: Definitions.opts()
        ) :: {:ok, pack_document()} | export_error()
  def export(definition_ids, version, opts), do: export(definition_ids, [], version, opts)

  @doc """
  Same as `export/3`, plus `entity_definition_names` -- `Letflow.Entities.EntityDefinition`
  `name` values, read (in the order given) via
  `Letflow.Entities.Definitions.get_definition_by_name/2` under the caller's own
  `opts[:prefix]`, and packed into the document's `entity_definitions` array.

  `export/3` delegates here with `entity_definition_names: []`, so a
  process-definitions-only export is byte-for-byte unchanged.

  Naming zero `definition_ids` **and** zero `entity_definition_names` is still
  `{:error, :empty_definition_ids}`; naming only entity definitions (empty
  `definition_ids`) is a legitimate entity-definitions-only pack.

  An unresolvable name becomes `{:error, {:entity_definition_not_found, name}}`
  and no document is produced -- same cross-tenant-invisibility reasoning as
  `{:error, {:definition_not_found, id}}` above (INV-1/INV-5).
  """
  @spec export(
          definition_ids :: [String.t()],
          entity_definition_names :: [String.t()],
          version :: String.t() | nil,
          opts :: Definitions.opts()
        ) :: {:ok, pack_document()} | export_error()
  def export([], [], _version, _opts), do: {:error, :empty_definition_ids}

  def export(definition_ids, entity_definition_names, version, opts)
      when is_list(definition_ids) and is_list(entity_definition_names) and is_list(opts) do
    with {:ok, packed} <- pack_each_definition(definition_ids, opts),
         {:ok, entity_definitions} <-
           pack_each_entity_definition(entity_definition_names, opts) do
      {:ok,
       %{
         pack_id: Ecto.UUID.generate(),
         version: pack_version(version),
         bpm_export_schema_version: ExportImport.export_schema_version(),
         exported_at: DateTime.to_iso8601(DateTime.utc_now()),
         definitions:
           Enum.map(packed, fn {definition, _schemas} -> pack_definition(definition) end),
         service_catalog_entries: [],
         variable_schemas: Enum.flat_map(packed, &pack_variable_schemas/1),
         entity_definitions: Enum.map(entity_definitions, &pack_entity_definition/1),
         manifest: %{required_roles: []}
       }}
    end
  end

  @doc """
  Installs a pack document into the caller's own tenant schema
  (`opts[:prefix]`), transactionally.

  `document` is the **raw decoded JSON body** (string keys) — this function
  owns the structural parse so the route layer stays a thin dispatcher, and a
  shape failure surfaces as the typed `{:error, :invalid_pack_document}`
  rather than as hand-rolled parsing in a `Plug.Router` module.

  Order of operations. Steps 1-3 issue **zero** queries, so a malformed
  document never reaches the database:

    1. `service_catalog_entries` non-empty -> `{:error, :unsupported_pack_section}`.
    PROVENANCE (historical, not current decision authority):
    2. `bpm_export_schema_version` mismatch ->
       `{:error, {:unknown_schema_version, actual}}` (R-Co:
       `INVALID_PACK_DOCUMENT`, `solution_packs.zig:168-172`).
    3. Well-formedness pre-check on every `variable_schemas` entry:
       `schema_content` is decoded with `Jason.decode/1` and checked by
       `Letflow.Definitions.JsonSchemaShape.check/1`. Any failure aborts with
       `{:error, {:malformed_variable_schema, schema_name, reason}}` and
       **nothing is written**.

  Then, inside one `Letflow.Repo.transaction/1`:

    4. (No conflict pre-check — see the moduledoc; it is unreachable here.)
    5. Insert the global `solution_pack_installs` row via
       `Letflow.Definitions.SolutionPackInstall.insert_changeset/2`, with
       `tenant_id` **derived** from `opts[:prefix]`. Its
       `uq_solution_pack_install_active` partial unique index surfaces as
       `{:error, :duplicate_pack_install}`.
    6. `Letflow.Definitions.create/2` per packed definition, with
       `name: process_key` and `created_by: actor_id`, recording the
       `source_definition_id -> new_definition_id` mapping.
    6b. REQ-379: `capture_artefact_bases/4` — one insert-if-absent
       `solution_pack_artefact_bases` row per definition just created in step
       6 (`artefact_type: "process_definition"`, `artefact_id` = the new
       `ProcessDefinition.id`, `base_content` = canonicalized
       `packed.graph`), sharing this install's single `captured_at` instant
       with the `solution_pack_installs` row from step 5. Then
       `Letflow.Entities.Definitions.create_definition/2` per packed entity
       definition (`:inactive`-only, 0026 §2).
    REQ-411: step 6a (`seed_pack_specific_field_restrictions/2`) is removed.
       Answer-key field restrictions for the exam pack are now seeded by
       `Letflow.Modules.Exam.on_install/2`, called by
       `Letflow.Modules.Installs.install/3` inside the module-install
       transaction after the pack is installed (D5).  `install/3` here is
       now fully generic — no pack-specific branch remains.
    PROVENANCE (historical, not current decision authority):
    7. `Letflow.Definitions.register_variable_schemas/3` — **the single shared
       insert path into `variable_schemas`, which REQ-082's import also
       calls** — once per installed definition, with the entries whose
       `definition_id` resolves through that mapping. An entry naming a
       definition the pack does not carry is skipped and reported in
       `warnings`, matching R-Co's `continue` at `store.zig:483`.
    8. Build the advisory `role_mapping_checklist`, append one
       `unbound_task_role: ...` line to `warnings` for every role a human task
       routes to that has no `tenant_role` binding in this tenant (REQ-455,
       `Letflow.Definitions.RoleBinding`; read-only, binds nothing), and commit.

  Any error in steps 5-7 rolls the whole transaction back, so a rejected
  variable schema also un-creates the definitions the same install made.
  """
  @spec install(
          document :: map(),
          actor_id :: Ecto.UUID.t(),
          opts :: Definitions.opts()
        ) :: {:ok, install_result()} | install_error()
  def install(document, actor_id, opts) when is_list(opts) do
    with {:ok, parsed} <- parse_document(document),
         :ok <- check_unsupported_sections(parsed),
         :ok <- check_schema_version(parsed),
         {:ok, decoded_schemas} <- decode_variable_schemas(parsed.variable_schemas),
         {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix(opts)) do
      run_install(parsed, decoded_schemas, tenant_id, actor_id, opts)
    end
  end

  @doc """
  Applies a solution-pack update for one tenant's install of `pack_id`
  against `target_version` (REQ-380 design §4.3). Single atomic operation,
  entirely inside one `Letflow.Repo.transaction/1`:

    1. `TenantProvisioning.tenant_id_for_schema_name/1` on `opts[:prefix]`.
    2. Defensive structural guard on `resolutions` (`resolved_content`
       present iff `resolution == :merged`) -- the router's own validation
       already enforces this; this is a second, defensive layer, not
       user-facing (design §4.3 step 2).
    3. Insert every submitted `resolutions` entry via
       `PackUpdateResolution.insert_changeset/2`, `Repo.insert(on_conflict:
       :nothing, conflict_target: [:tenant_id, :pack_id, :target_version,
       :artefact_type, :artefact_id])` -- first-recorded resolution wins,
       permanently, for a given `(tenant_id, pack_id, target_version,
       artefact_type, artefact_id)` (design §4.3 step 3, OQ-3).
    4. `Letflow.Definitions.compute_pack_update_plan/5`, re-run **inside the
       same transaction** so it sees the resolutions step 3 just inserted.
    5. If any `:conflict`-classified entry is still unresolved, roll back
       the entire transaction -- **including step 3's inserts** (design
       §4.4) -- returning `{:error, {:unresolved_conflict, artefact_type,
       artefact_id}}` naming the first such entry in `plan.entries` order.
    6. Otherwise, for each plan entry: `:unchanged`/`:local_only` ->
       `action: :left_unchanged`, no write. `:clean_update` -> advance
       `solution_pack_artefact_bases` to `entry.incoming`, `action:
       :advanced_to_incoming`. `:conflict` (now guaranteed resolved) ->
       always look up the deciding resolution from the persisted
       `pack_update_resolutions` row (ISS-0781: never from this call's own
       `resolutions` argument, even when this call itself just submitted a
       value for that artefact -- step 3's insert is visible here via
       same-transaction read-your-writes) -- and advance the base per
       `:take_incoming`/`:merged`, or leave it untouched per `:keep_local`.
    7. Commit; return `{:ok, apply_result()}`.

  `theirs_artefacts`/`incoming_artefacts` are caller-supplied, same
  contract as `compute_pack_update_plan/5` (§2 of the design doc) --
  `apply_pack_update/6` has no other way to source them yet (OQ-2).

  `base_content`/`base_version` are advanced via
  `SolutionPackArtefactBase.upsert_changeset/2` with `on_conflict:
  {:replace, [:base_content, :base_version, :captured_at, :updated_at]}` --
  the wholesale-replace write that module's own moduledoc names this
  function as the intended caller for. Content is written as-is: both
  `entry.incoming` and a `resolutions[].resolved_content` are already
  canonical-JSON text by the time they reach this function (design §6,
  "Canonicalization is the caller's responsibility, at every entry point")
  -- unlike `capture_artefact_bases/4`'s own `packed.graph` **map** input,
  neither is re-canonicalized here.
  """
  @spec apply_pack_update(
          pack_id :: String.t(),
          target_version :: String.t(),
          theirs_artefacts :: [Definitions.artefact_input()],
          incoming_artefacts :: [Definitions.artefact_input()],
          resolutions :: [resolution_input()],
          opts :: Definitions.opts() | [prefix: String.t(), actor_id: Ecto.UUID.t()]
        ) :: {:ok, apply_result()} | apply_error()
  def apply_pack_update(
        pack_id,
        target_version,
        theirs_artefacts,
        incoming_artefacts,
        resolutions,
        opts
      )
      when is_list(opts) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix(opts)) do
      :ok = assert_resolution_shapes!(resolutions)
      actor_id = Keyword.fetch!(opts, :actor_id)
      now = DateTime.truncate(DateTime.utc_now(), :microsecond)

      Repo.transaction(fn ->
        case run_apply_update(
               pack_id,
               target_version,
               theirs_artefacts,
               incoming_artefacts,
               resolutions,
               tenant_id,
               actor_id,
               now
             ) do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  # ── apply_pack_update/6 helpers (REQ-380 design §4.3) ─────────────────────

  # Defensive, programmer-error-only guard (design §4.3 step 2): the router's
  # own `@update_apply_schema`/`validate_resolution_input/1` already reject a
  # malformed resolutions[] entry before this function is ever reached, so a
  # failure here means the router itself let a bad shape through -- not
  # something a caller can trigger via a well-formed HTTP request, hence a
  # raise (mirrors `Keyword.fetch!/2`'s own no-default stance) rather than a
  # typed apply_error() member.
  defp assert_resolution_shapes!(resolutions) do
    Enum.each(resolutions, fn
      %{resolution: :merged, resolved_content: content}
      when is_binary(content) and content != "" ->
        :ok

      %{resolution: :merged} = resolution ->
        raise ArgumentError,
              "resolution :merged requires a non-empty resolved_content: #{inspect(resolution)}"

      %{resolution: other, resolved_content: nil} when other in [:keep_local, :take_incoming] ->
        :ok

      %{resolution: other} = resolution when other in [:keep_local, :take_incoming] ->
        raise ArgumentError,
              "resolution #{other} must not carry resolved_content: #{inspect(resolution)}"
    end)

    :ok
  end

  defp run_apply_update(
         pack_id,
         target_version,
         theirs_artefacts,
         incoming_artefacts,
         resolutions,
         tenant_id,
         actor_id,
         now
       ) do
    with {:ok, recorded_count} <-
           insert_submitted_resolutions(
             resolutions,
             tenant_id,
             pack_id,
             target_version,
             actor_id,
             now
           ),
         {:ok, plan} <-
           Definitions.compute_pack_update_plan(
             tenant_id,
             pack_id,
             target_version,
             theirs_artefacts,
             incoming_artefacts
           ),
         :ok <- check_no_unresolved_conflicts(plan),
         {:ok, applied_entries} <-
           apply_plan_entries(plan.entries, tenant_id, pack_id, target_version, resolutions, now) do
      {:ok,
       %{
         pack_id: pack_id,
         target_version: target_version,
         applied_entries: applied_entries,
         resolutions_recorded: recorded_count
       }}
    end
  end

  # Insert-if-absent (design §4.3 step 3, OQ-3). `is_nil(id)` is how Ecto
  # reports an `on_conflict: :nothing` no-op: with no row returned by
  # Postgres' `RETURNING`, the autogenerated primary key is never populated
  # on the struct handed back, while every other field still reflects the
  # attempted (not necessarily persisted) attrs -- so `id == nil` is the one
  # reliable signal a fresh row was *not* inserted, distinguishing "already
  # resolved by an earlier call" from "recorded by this call" for
  # `resolutions_recorded`'s count.
  defp insert_submitted_resolutions(
         resolutions,
         tenant_id,
         pack_id,
         target_version,
         actor_id,
         now
       ) do
    Enum.reduce_while(resolutions, {:ok, 0}, fn resolution, {:ok, count} ->
      attrs = %{
        tenant_id: tenant_id,
        pack_id: pack_id,
        target_version: target_version,
        artefact_type: resolution.artefact_type,
        artefact_id: resolution.artefact_id,
        resolution: resolution.resolution,
        resolved_content: resolution.resolved_content,
        resolved_by: actor_id,
        resolved_at: now
      }

      %PackUpdateResolution{}
      |> PackUpdateResolution.insert_changeset(attrs)
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:tenant_id, :pack_id, :target_version, :artefact_type, :artefact_id]
      )
      |> case do
        {:ok, %PackUpdateResolution{id: nil}} -> {:cont, {:ok, count}}
        {:ok, %PackUpdateResolution{}} -> {:cont, {:ok, count + 1}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Design §4.3 step 5 -- names the first unresolved conflict, in
  # `plan.entries` order, i.e. `compute_pack_update_plan/5`'s own
  # deterministic first-seen order.
  defp check_no_unresolved_conflicts(plan) do
    if plan.has_unresolved_conflicts do
      entry = Enum.find(plan.entries, &(&1.classification == :conflict and not &1.resolved))
      {:error, {:unresolved_conflict, entry.artefact_type, entry.artefact_id}}
    else
      :ok
    end
  end

  # Design §4.3 step 6. All-or-nothing: the first base-advancement failure
  # aborts the whole reduce, flowing into `run_apply_update/8`'s `with` ->
  # `apply_pack_update/6`'s `Repo.transaction/1` -> `Repo.rollback/1` path,
  # same shape every other multi-step write in this module already uses.
  defp apply_plan_entries(entries, tenant_id, pack_id, target_version, resolutions, now) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case apply_entry(entry, tenant_id, pack_id, target_version, resolutions, now) do
        {:ok, applied} -> {:cont, {:ok, [applied | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp apply_entry(
         %{classification: :unchanged} = entry,
         _tenant_id,
         _pack_id,
         _target_version,
         _resolutions,
         _now
       ) do
    {:ok, applied_entry_map(entry, :left_unchanged)}
  end

  defp apply_entry(
         %{classification: :local_only} = entry,
         _tenant_id,
         _pack_id,
         _target_version,
         _resolutions,
         _now
       ) do
    {:ok, applied_entry_map(entry, :left_unchanged)}
  end

  defp apply_entry(
         %{classification: :clean_update} = entry,
         tenant_id,
         pack_id,
         target_version,
         _resolutions,
         now
       ) do
    with {:ok, _base} <-
           advance_base(tenant_id, pack_id, target_version, entry, entry.incoming, now) do
      {:ok, applied_entry_map(entry, :advanced_to_incoming)}
    end
  end

  # Guaranteed `resolved == true` by `check_no_unresolved_conflicts/1` having
  # already passed -- a matching resolution exists, either among this call's
  # own `resolutions` (submitted just now, step 3) or from an earlier call.
  # Either way, the applied action is always determined by reading the
  # persisted `pack_update_resolutions` row (`apply_from_persisted_resolution/5`),
  # never this call's own `resolutions` argument directly (ISS-0781): the row
  # is the sole source of truth `resolution_exists?/5` already treats it as,
  # and `insert_submitted_resolutions/6` (step 3) always runs earlier in this
  # same transaction, so a first-ever submission is visible here via
  # read-your-writes -- this branch is not reachable for an artefact this call
  # itself just submitted for the first time with a different outcome, because
  # the row already reflects that same submission by the time this reads it.
  defp apply_entry(
         %{classification: :conflict} = entry,
         tenant_id,
         pack_id,
         target_version,
         _resolutions,
         now
       ) do
    apply_from_persisted_resolution(tenant_id, pack_id, target_version, entry, now)
  end

  defp apply_from_persisted_resolution(tenant_id, pack_id, target_version, entry, now) do
    Repo.get_by(PackUpdateResolution,
      tenant_id: tenant_id,
      pack_id: pack_id,
      target_version: target_version,
      artefact_type: entry.artefact_type,
      artefact_id: entry.artefact_id
    )
    |> case do
      %PackUpdateResolution{resolution: :keep_local} ->
        {:ok, applied_entry_map(entry, :left_unchanged)}

      %PackUpdateResolution{resolution: :take_incoming} ->
        with {:ok, _base} <-
               advance_base(tenant_id, pack_id, target_version, entry, entry.incoming, now) do
          {:ok, applied_entry_map(entry, :advanced_to_incoming)}
        end

      %PackUpdateResolution{resolution: :merged, resolved_content: content} ->
        with {:ok, _base} <- advance_base(tenant_id, pack_id, target_version, entry, content, now) do
          {:ok, applied_entry_map(entry, :advanced_to_merged)}
        end
    end
  end

  defp advance_base(tenant_id, pack_id, target_version, entry, content, now) do
    attrs = %{
      tenant_id: tenant_id,
      pack_id: pack_id,
      artefact_type: entry.artefact_type,
      artefact_id: entry.artefact_id,
      base_version: target_version,
      base_content: content,
      captured_at: now
    }

    %SolutionPackArtefactBase{}
    |> SolutionPackArtefactBase.upsert_changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:base_content, :base_version, :captured_at, :updated_at]},
      conflict_target: [:tenant_id, :pack_id, :artefact_type, :artefact_id]
    )
  end

  defp applied_entry_map(entry, action) do
    %{
      artefact_type: entry.artefact_type,
      artefact_id: entry.artefact_id,
      classification: entry.classification,
      action: action
    }
  end

  # ── export/3 helpers ──────────────────────────────────────────────────────

  defp prefix(opts), do: Keyword.get(opts, :prefix)

  defp pack_version(version) when is_binary(version) and byte_size(version) > 0, do: version
  defp pack_version(_absent), do: @default_pack_version

  # Reads in the order the caller listed the ids, so a not-found error names
  # the first offending id deterministically.
  defp pack_each_definition(definition_ids, opts) do
    Enum.reduce_while(definition_ids, {:ok, []}, fn id, {:ok, acc} ->
      case Definitions.get_by_id(id, opts) do
        {:ok, %ProcessDefinition{} = definition} ->
          case VariableSchema.fetch_schemas(Repo, definition.id, opts) do
            {:ok, schemas} -> {:cont, {:ok, [{definition, schemas} | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, :not_found} ->
          {:halt, {:error, {:definition_not_found, to_string(id)}}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  # Hand-built, explicit key list -- never a Jason.Encoder derivation over
  # %ProcessDefinition{} (INV-2). `process_key` is the authoritative field on
  # install; `name` is the human label. Letflow's process_definitions carries
  # one `name` column, so the two are equal on export -- R-Co separates them
  # and the wire shape is kept compatible rather than collapsed.
  defp pack_definition(%ProcessDefinition{} = definition) do
    %{
      definition_id: definition.id,
      process_key: definition.name,
      name: definition.name,
      version: definition.version,
      graph: definition.graph
    }
  end

  # Reads in the order the caller listed the names, so a not-found error names
  # the first offending name deterministically -- mirrors pack_each_definition/2.
  @spec pack_each_entity_definition([String.t()], Definitions.opts()) ::
          {:ok, [EntityDefinition.t()]} | export_error()
  defp pack_each_entity_definition(entity_definition_names, opts) do
    Enum.reduce_while(entity_definition_names, {:ok, []}, fn name, {:ok, acc} ->
      case Letflow.Entities.Definitions.get_definition_by_name(name, prefix(opts)) do
        {:ok, %EntityDefinition{} = entity_definition} ->
          {:cont, {:ok, [entity_definition | acc]}}

        {:error, :not_found} ->
          {:halt, {:error, {:entity_definition_not_found, name}}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  # Hand-built, explicit key list -- never a Jason.Encoder derivation over
  # %EntityDefinition{} (INV-2). Keeps tenant_id/content_hash/artifact_version_id/
  # status (storage-only fields) out of the pack document.
  @spec pack_entity_definition(EntityDefinition.t()) :: packed_entity_definition()
  defp pack_entity_definition(%EntityDefinition{} = entity_definition) do
    %{
      entity_definition_id: entity_definition.id,
      name: entity_definition.name,
      display_name: entity_definition.display_name,
      definition_json: entity_definition.definition_json,
      logical_shape_version: encode_logical_shape_version(entity_definition.logical_shape_version)
    }
  end

  # Mirrors Letflow.Entities.Records.hex_version/1's exact convention -- the raw
  # digest is not valid UTF-8 in general and cannot cross a Jason.encode!/1
  # boundary. logical_shape_version is a non-nullable :binary column
  # (EntityDefinition's @required_fields), so every %EntityDefinition{} reaching
  # this function already has a non-nil value; no error branch is needed.
  @spec encode_logical_shape_version(binary()) :: String.t()
  defp encode_logical_shape_version(version) do
    Base.encode16(version, case: :lower)
  end

  defp pack_variable_schemas({%ProcessDefinition{} = definition, schemas}) do
    schemas
    |> Enum.sort_by(fn {variable_key, _json_schema} -> variable_key end)
    |> Enum.map(fn {variable_key, json_schema} ->
      %{
        definition_id: definition.id,
        schema_name: variable_key,
        schema_content: Jason.encode!(json_schema)
      }
    end)
  end

  # ── install/3 parsing (step 0) ────────────────────────────────────────────

  defp parse_document(document) when is_map(document) and not is_struct(document) do
    with {:ok, pack_id} <- fetch_string(document, "pack_id"),
         {:ok, version} <- fetch_string(document, "version"),
         {:ok, schema_version} <- fetch_string(document, "bpm_export_schema_version"),
         {:ok, raw_definitions} <- fetch_list(document, "definitions"),
         {:ok, raw_variable_schemas} <- fetch_list(document, "variable_schemas"),
         {:ok, raw_catalog} <- fetch_list(document, "service_catalog_entries"),
         {:ok, raw_entity_definitions} <- fetch_list(document, "entity_definitions"),
         {:ok, definitions} <- parse_definitions(raw_definitions),
         {:ok, variable_schemas} <- parse_variable_schemas(raw_variable_schemas),
         {:ok, entity_definitions} <- parse_entity_definitions(raw_entity_definitions),
         {:ok, required_roles} <- parse_required_roles(Map.get(document, "manifest")) do
      {:ok,
       %{
         pack_id: pack_id,
         version: version,
         bpm_export_schema_version: schema_version,
         definitions: definitions,
         variable_schemas: variable_schemas,
         service_catalog_entries: raw_catalog,
         entity_definitions: entity_definitions,
         required_roles: required_roles
       }}
    end
  end

  defp parse_document(_not_an_object), do: {:error, :invalid_pack_document}

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _absent_or_wrong_type -> {:error, :invalid_pack_document}
    end
  end

  defp fetch_list(map, key) do
    case Map.get(map, key, []) do
      value when is_list(value) -> {:ok, value}
      nil -> {:ok, []}
      _wrong_type -> {:error, :invalid_pack_document}
    end
  end

  defp parse_definitions(raw_definitions) do
    Enum.reduce_while(raw_definitions, {:ok, []}, fn raw, {:ok, acc} ->
      case parse_definition(raw) do
        {:ok, definition} -> {:cont, {:ok, [definition | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_definition(raw) when is_map(raw) and not is_struct(raw) do
    with {:ok, definition_id} <- fetch_string(raw, "definition_id"),
         {:ok, process_key} <- fetch_string(raw, "process_key"),
         {:ok, version} <- fetch_string(raw, "version"),
         {:ok, graph} <- fetch_object(raw, "graph") do
      {:ok,
       %{
         definition_id: definition_id,
         process_key: process_key,
         name: optional_string(raw, "name", process_key),
         version: version,
         graph: graph
       }}
    end
  end

  defp parse_definition(_not_an_object), do: {:error, :invalid_pack_document}

  # ── install/3 parsing -- entity_definitions (REQ-305, 0026) ──────────────

  defp parse_entity_definitions(raw_entity_definitions) do
    Enum.reduce_while(raw_entity_definitions, {:ok, []}, fn raw, {:ok, acc} ->
      case parse_entity_definition(raw) do
        {:ok, entity_definition} -> {:cont, {:ok, [entity_definition | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_entity_definition(raw) when is_map(raw) and not is_struct(raw) do
    with {:ok, entity_definition_id} <- fetch_string(raw, "entity_definition_id"),
         {:ok, name} <- fetch_string(raw, "name"),
         {:ok, display_name} <- fetch_string(raw, "display_name"),
         {:ok, logical_shape_version} <- fetch_string(raw, "logical_shape_version"),
         {:ok, logical_shape_version} <- decode_logical_shape_version(logical_shape_version),
         {:ok, raw_definition_json} <- fetch_object(raw, "definition_json"),
         {:ok, definition_json} <- atomize_definition_json(raw_definition_json) do
      {:ok,
       %{
         entity_definition_id: entity_definition_id,
         name: name,
         display_name: display_name,
         definition_json: definition_json,
         logical_shape_version: logical_shape_version
       }}
    end
  end

  defp parse_entity_definition(_not_an_object), do: {:error, :invalid_pack_document}

  # Non-raising counterpart to encode_logical_shape_version/1 -- this receives
  # caller-supplied pack-document content that has not yet been validated as
  # well-formed hex, unlike Records.hex_version/1's duplicate-submission replay
  # path, which decodes a value this codebase itself encoded moments earlier.
  # Odd length, non-hex characters, or wrong case (case: :lower rejects
  # uppercase hex digits) all fall through to :error here, reusing the existing
  # structural-parse-failure atom rather than inventing a new error tuple.
  @spec decode_logical_shape_version(String.t()) ::
          {:ok, binary()} | {:error, :invalid_pack_document}
  defp decode_logical_shape_version(hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, raw_bytes} -> {:ok, raw_bytes}
      :error -> {:error, :invalid_pack_document}
    end
  end

  # Translates a string-keyed `definition_json` map (as it round-trips through
  # a JSON decode, or through Ecto's `:map`/JSONB `entity_definitions.definition_json`
  # column, which never atomizes on read) into the atom-keyed
  # `Letflow.Entities.Definition.t()` shape `Letflow.Entities.Definition.Validator.validate/1`
  # requires. Static whitelist translation only -- never
  # `String.to_existing_atom/1` on caller-supplied text (INV-4/INV-8). Any key
  # or closed-set enum value not in these whitelists is rejected outright,
  # never silently dropped (0026 §4). Pure and total -- no query, never raises.
  @top_level_keys %{
    "name" => :name,
    "display_name" => :display_name,
    "description" => :description,
    "fields" => :fields,
    "indexes" => :indexes,
    "foreign_keys" => :foreign_keys,
    "constraints" => :constraints,
    # GH #2529: optional boolean; the Validator rejects a non-boolean value.
    "append_only" => :append_only
  }

  @field_keys %{
    "name" => :name,
    "type" => :type,
    "required" => :required,
    "queried" => :queried,
    "enum_values" => :enum_values,
    "decimal_precision" => :decimal_precision,
    "decimal_scale" => :decimal_scale,
    "default" => :default,
    "locales" => :locales,
    "search_strategy" => :search_strategy
  }

  @field_types %{
    "string" => :string,
    "integer" => :integer,
    "decimal" => :decimal,
    "boolean" => :boolean,
    "date" => :date,
    "datetime" => :datetime,
    "enum" => :enum,
    "json" => :json,
    "localized_text" => :localized_text
  }

  @search_strategies %{"plain" => :plain, "fulltext" => :fulltext}

  @index_keys %{"name" => :name, "fields" => :fields, "unique" => :unique}

  @fk_keys %{
    "name" => :name,
    "field" => :field,
    "references_entity" => :references_entity,
    "references_field" => :references_field
  }

  @constraint_keys %{"name" => :name, "type" => :type, "fields" => :fields}

  @spec atomize_definition_json(map()) ::
          {:ok, Letflow.Entities.Definition.t()} | {:error, :invalid_pack_document}
  defp atomize_definition_json(raw) when is_map(raw) and not is_struct(raw) do
    with {:ok, top} <- translate_keys(raw, @top_level_keys),
         {:ok, top} <- translate_list_value(top, :fields, &translate_field/1),
         {:ok, top} <- translate_list_value(top, :indexes, &translate_index/1),
         {:ok, top} <- translate_list_value(top, :foreign_keys, &translate_fk/1),
         {:ok, top} <- translate_list_value(top, :constraints, &translate_constraint/1) do
      {:ok, top}
    end
  end

  defp atomize_definition_json(_not_an_object), do: {:error, :invalid_pack_document}

  # Translates every key in `raw` via `whitelist`, rejecting on the first
  # unrecognized key. Non-map/non-binary-keyed input is not expected here --
  # every call site already guarded its input as a map via `fetch_object/2`
  # or an `Enum.all?(&is_map/1)`-style check upstream.
  defp translate_keys(raw, whitelist) do
    Enum.reduce_while(raw, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Map.fetch(whitelist, key) do
        {:ok, atom_key} -> {:cont, {:ok, Map.put(acc, atom_key, value)}}
        :error -> {:halt, {:error, :invalid_pack_document}}
      end
    end)
  end

  # Applies `translator` to each entry of `top[list_key]`, if present, and
  # replaces it with the translated list. Absent key is left untouched
  # (optional list-valued keys, e.g. `:indexes`, may be legitimately absent).
  defp translate_list_value(top, list_key, translator) do
    case Map.fetch(top, list_key) do
      :error ->
        {:ok, top}

      {:ok, entries} when is_list(entries) ->
        Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
          case translator.(entry) do
            {:ok, translated} -> {:cont, {:ok, [translated | acc]}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, Map.put(top, list_key, Enum.reverse(acc))}
          {:error, _reason} = error -> error
        end

      {:ok, _not_a_list} ->
        {:error, :invalid_pack_document}
    end
  end

  defp translate_field(raw) when is_map(raw) and not is_struct(raw) do
    with {:ok, field} <- translate_keys(raw, @field_keys),
         {:ok, field} <- translate_enum_value(field, :type, @field_types),
         {:ok, field} <- translate_enum_value(field, :search_strategy, @search_strategies) do
      {:ok, field}
    end
  end

  defp translate_field(_not_an_object), do: {:error, :invalid_pack_document}

  defp translate_index(raw) when is_map(raw) and not is_struct(raw),
    do: translate_keys(raw, @index_keys)

  defp translate_index(_not_an_object), do: {:error, :invalid_pack_document}

  defp translate_fk(raw) when is_map(raw) and not is_struct(raw),
    do: translate_keys(raw, @fk_keys)

  defp translate_fk(_not_an_object), do: {:error, :invalid_pack_document}

  defp translate_constraint(raw) when is_map(raw) and not is_struct(raw) do
    with {:ok, constraint} <- translate_keys(raw, @constraint_keys) do
      case Map.fetch(constraint, :type) do
        {:ok, "unique"} -> {:ok, Map.put(constraint, :type, :unique)}
        :error -> {:ok, constraint}
        {:ok, _other} -> {:error, :invalid_pack_document}
      end
    end
  end

  defp translate_constraint(_not_an_object), do: {:error, :invalid_pack_document}

  # Translates `map[atom_key]`'s closed-set string value via `whitelist`, if
  # the key is present. Absent key is left untouched (e.g. `search_strategy`
  # is optional).
  defp translate_enum_value(map, atom_key, whitelist) do
    case Map.fetch(map, atom_key) do
      :error ->
        {:ok, map}

      {:ok, value} ->
        case Map.fetch(whitelist, value) do
          {:ok, translated} -> {:ok, Map.put(map, atom_key, translated)}
          :error -> {:error, :invalid_pack_document}
        end
    end
  end

  defp fetch_object(map, key) do
    case Map.get(map, key) do
      value when is_map(value) and not is_struct(value) -> {:ok, value}
      _absent_or_wrong_type -> {:error, :invalid_pack_document}
    end
  end

  defp optional_string(map, key, default) do
    case Map.get(map, key) do
      value when is_binary(value) and byte_size(value) > 0 -> value
      _absent_or_wrong_type -> default
    end
  end

  defp parse_variable_schemas(raw_entries) do
    Enum.reduce_while(raw_entries, {:ok, []}, fn raw, {:ok, acc} ->
      case parse_variable_schema(raw) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_variable_schema(raw) when is_map(raw) and not is_struct(raw) do
    with {:ok, definition_id} <- fetch_string(raw, "definition_id"),
         {:ok, schema_name} <- fetch_string(raw, "schema_name") do
      {:ok,
       %{
         definition_id: definition_id,
         schema_name: schema_name,
         schema_content: Map.get(raw, "schema_content"),
         description: optional_string(raw, "description", nil)
       }}
    end
  end

  defp parse_variable_schema(_not_an_object), do: {:error, :invalid_pack_document}

  defp parse_required_roles(nil), do: {:ok, []}

  defp parse_required_roles(manifest) when is_map(manifest) and not is_struct(manifest) do
    case Map.get(manifest, "required_roles", []) do
      roles when is_list(roles) ->
        if Enum.all?(roles, &is_binary/1),
          do: {:ok, roles},
          else: {:error, :invalid_pack_document}

      nil ->
        {:ok, []}

      _wrong_type ->
        {:error, :invalid_pack_document}
    end
  end

  defp parse_required_roles(_not_an_object), do: {:error, :invalid_pack_document}

  # ── install/3 steps 1-3 (pure, zero queries) ──────────────────────────────

  # REQ-191 retains this hard-fail as-is (does not make it functional) --
  # see this module's moduledoc "service_catalog_entries" bullet. This
  # comment previously named REQ-192 as the owning follow-up for deciding
  # the install-time visibility policy a packed entry would need; that is
  # stale. REQ-192 is done and landed the service-catalog route surface
  # WITHOUT lifting this restriction. That gap is now closed, permanently, by
  # docs/migration/decisions/0027-solution-pack-service-catalog-install-policy.md:
  # the policy is settled as permanently NOT PERMITTED, not unowned. Any
  # needed service-catalog entry is provisioned out-of-band, through the
  # existing POST /service-catalog route (gated :AdminServicesManage,
  # PLATFORM_ADMIN-only in the current role matrix), not through a pack.
  # S10's gaps 4 and 5 are no longer blocked on this policy (see
  # docs/migration/stage-10-bilimbaga-vertical.md, "Open questions"). This
  # hard-fail stays permanently, per 0027.
  # NOTE (ELIXIR-DEV, REQ-305): the design doc's §3 literally specifies a
  # joint `%{service_catalog_entries: [], entity_definitions: []}` passing
  # clause -- i.e. requiring entity_definitions to ALSO be empty. Implemented
  # literally that would make `entity_definitions` un-installable through
  # `install/3` forever (this clause runs before `run_install/5`, so
  # `create_packed_entity_definitions/3`, §4, would be permanently
  # unreachable), directly contradicting AC1 and the design doc's own §4.
  # `entity_definitions` is a newly *supported* section (that is this whole
  # requirement's point), not an unsupported one like
  # `service_catalog_entries` still is -- so only the latter gates here.
  # Flagged for REVIEWER/CODE-DESIGNER: the design doc's §3 prose needs
  # correcting.
  defp check_unsupported_sections(%{service_catalog_entries: []}), do: :ok
  defp check_unsupported_sections(_parsed), do: {:error, :unsupported_pack_section}

  defp check_schema_version(%{bpm_export_schema_version: version}) do
    if version == ExportImport.export_schema_version() do
      :ok
    else
      {:error, {:unknown_schema_version, version}}
    end
  end

  # Decodes every `schema_content` JSON string and checks its shape BEFORE the
  # transaction opens. `Letflow.Definitions.register_variable_schemas/3` runs
  # the identical shape check again inside the transaction -- that is the
  # authoritative one; this one exists so a malformed document is rejected
  # without opening a transaction at all.
  defp decode_variable_schemas(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case decode_variable_schema(entry) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_variable_schema(%{schema_content: content, schema_name: name} = entry)
       when is_binary(content) do
    case Jason.decode(content) do
      {:ok, document} ->
        case JsonSchemaShape.check(document) do
          :ok ->
            {:ok, %{entry | schema_content: document}}

          {:error, {:not_well_formed, path}} ->
            {:error, {:not_well_formed, name, path}}

          {:error, :too_deep} ->
            {:error, {:schema_too_deep, name}}
        end

      {:error, %Jason.DecodeError{}} ->
        {:error, {:malformed_variable_schema, name, :invalid_json}}
    end
  end

  defp decode_variable_schema(%{schema_name: name}),
    do: {:error, {:malformed_variable_schema, name, :not_a_string}}

  # ── install/3 steps 5-8 (transactional) ───────────────────────────────────

  defp run_install(parsed, decoded_schemas, tenant_id, actor_id, opts) do
    captured_at = DateTime.truncate(DateTime.utc_now(), :microsecond)

    Repo.transaction(fn ->
      with {:ok, install} <- insert_install_row(parsed, tenant_id, captured_at),
           {:ok, installed} <- create_packed_definitions(parsed.definitions, actor_id, opts),
           {:ok, _bases} <-
             capture_artefact_bases(
               tenant_id,
               parsed.pack_id,
               parsed.version,
               artefact_snapshots_from(installed),
               captured_at
             ),
           {:ok, installed_entities} <-
             create_packed_entity_definitions(parsed.entity_definitions, actor_id, opts),
           {:ok, written, warnings} <- register_packed_schemas(installed, decoded_schemas, opts) do
        %{
          pack_id: parsed.pack_id,
          version: parsed.version,
          install_id: install.id,
          installed_definitions: installed_definition_maps(installed),
          installed_entity_definitions: installed_entity_definition_maps(installed_entities),
          variable_schemas_written: written,
          role_mapping_checklist: role_mapping_checklist(parsed.required_roles),
          warnings: warnings ++ unbound_role_warnings(installed, opts)
        }
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # REQ-455 check 4: advisory warnings for human-task roles with no
  # `tenant_role` binding in this tenant. Read-only (one `list_roles` query);
  # binds nothing. A graph that fails `from_map/1` (cannot happen after a
  # successful create) is skipped.
  defp unbound_role_warnings(installed, opts) do
    definitions =
      Enum.flat_map(installed, fn {_packed, %ProcessDefinition{name: name, graph: graph}} ->
        case Graph.from_map(graph) do
          {:ok, parsed_graph} -> [{name, parsed_graph}]
          :error -> []
        end
      end)

    ValidationWarnings.for_definitions(definitions, opts)
  end

  defp insert_install_row(parsed, tenant_id, captured_at) do
    %SolutionPackInstall{}
    |> SolutionPackInstall.insert_changeset(%{
      tenant_id: tenant_id,
      pack_id: parsed.pack_id,
      installed_version: parsed.version,
      installed_at: captured_at
    })
    |> Repo.insert()
    |> case do
      {:ok, install} ->
        {:ok, install}

      {:error, %Ecto.Changeset{} = changeset} ->
        if unique_conflict?(changeset, :tenant_id) or unique_conflict?(changeset, :pack_id) do
          {:error, :duplicate_pack_install}
        else
          {:error, changeset}
        end
    end
  end

  defp unique_conflict?(%Ecto.Changeset{errors: errors}, field) do
    Enum.any?(errors, fn
      {^field, {_message, meta}} -> Keyword.get(meta, :constraint) == :unique
      _other -> false
    end)
  end

  # Every definition lands in the caller's own schema via `opts[:prefix]` and
  # nowhere else. All-or-nothing: the first failure aborts (see moduledoc).
  defp create_packed_definitions(packed_definitions, actor_id, opts) do
    Enum.reduce_while(packed_definitions, {:ok, []}, fn packed, {:ok, acc} ->
      attrs = %{
        name: packed.process_key,
        version: packed.version,
        graph: packed.graph,
        created_by: actor_id
      }

      case Definitions.create(attrs, opts) do
        {:ok, %ProcessDefinition{} = created} ->
          {:cont, {:ok, [{packed, created} | acc]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  # Maps `create_packed_definitions/3`'s `{packed_definition, %ProcessDefinition{}}`
  # accumulator to the artefact-snapshot shape `capture_artefact_bases/4` takes.
  # Pure, no I/O. Scope decision (REQ-379 design §1): process definitions only --
  # `variable_schemas`/`entity_definitions` are not captured by this requirement.
  # `artefact_id` is deliberately `created.id` (the newly-created, tenant-local
  # `ProcessDefinition.id`), never `packed.definition_id` (the source tenant's id) --
  # see design §2 for why only the former is ever resolvable by a future `theirs`
  # lookup against this tenant's own schema.
  @spec artefact_snapshots_from([{packed_definition(), ProcessDefinition.t()}]) ::
          [artefact_snapshot()]
  defp artefact_snapshots_from(installed) do
    Enum.map(installed, fn {packed, %ProcessDefinition{} = created} ->
      %{artefact_type: "process_definition", artefact_id: created.id, content: packed.graph}
    end)
  end

  @doc """
  Captures one `solution_pack_artefact_bases` row per `artefact_snapshots` entry
  (REQ-379 design §5.1), insert-if-absent.

  Must run inside the caller's already-open `Repo.transaction/1` (called from
  `run_install/5`) -- this function opens no transaction of its own.

  For each snapshot, in order: canonicalizes `content` (identical algorithm to
  `Letflow.Definitions.PromotionDigest.canonicalize/1` -- recursively sort map
  keys, rebuild via `Jason.OrderedObject.new/1`, map over lists without
  reordering, convert atoms via `Atom.to_string/1`, pass everything else
  through unchanged, then `Jason.encode!/1`), builds a
  `SolutionPackArtefactBase.upsert_changeset/2` with the given `tenant_id`,
  `pack_id`, `base_version`, the snapshot's `artefact_type`/`artefact_id`, the
  canonicalized `base_content`, and the single shared `captured_at` instant
  (passed in, not read per row, so every row from one install shares one
  timestamp), then `Repo.insert/2` with `on_conflict: :nothing,
  conflict_target: [:tenant_id, :pack_id, :artefact_type, :artefact_id]`.

  This is deliberately NOT `upsert_changeset/2`'s anticipated wholesale-replace
  write -- this call site (install-time capture) must never overwrite an
  existing base snapshot for an artefact the tenant has since locally adapted
  (AC3). A conflicting insert is a silent, successful no-op: the pre-existing
  row is left untouched, and the returned struct for that entry reflects the
  attempted (not necessarily persisted) snapshot -- callers must not rely on
  the return value to distinguish a fresh insert from a no-op skip (design
  §5.1).

  A genuine changeset error (e.g. a future value exceeding `artefact_type`'s
  or `artefact_id`'s 255-byte column limits) returns `{:error, changeset}`,
  which `run_install/5`'s existing `with`/`else` -> `Repo.rollback/1` clause
  turns into a full install rollback, consistent with every other step.
  """
  @spec capture_artefact_bases(
          tenant_id :: Ecto.UUID.t(),
          pack_id :: String.t(),
          base_version :: String.t(),
          artefact_snapshots :: [artefact_snapshot()],
          captured_at :: DateTime.t()
        ) :: {:ok, [SolutionPackArtefactBase.t()]} | {:error, Ecto.Changeset.t()}
  def capture_artefact_bases(tenant_id, pack_id, base_version, artefact_snapshots, captured_at) do
    Enum.reduce_while(artefact_snapshots, {:ok, []}, fn snapshot, {:ok, acc} ->
      attrs = %{
        tenant_id: tenant_id,
        pack_id: pack_id,
        artefact_type: snapshot.artefact_type,
        artefact_id: snapshot.artefact_id,
        base_version: base_version,
        base_content: canonicalize_artefact_content(snapshot.content),
        captured_at: captured_at
      }

      %SolutionPackArtefactBase{}
      |> SolutionPackArtefactBase.upsert_changeset(attrs)
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:tenant_id, :pack_id, :artefact_type, :artefact_id]
      )
      |> case do
        {:ok, base} -> {:cont, {:ok, [base | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  # Identical algorithm to Letflow.Definitions.PromotionDigest.canonicalize/1
  # (design §3, OQ-2) -- that function is `defp`, so this is a second,
  # independent implementation of the same four steps, not a shared call.
  # Recursively sort map keys, rebuild via Jason.OrderedObject.new/1 so sorted
  # order survives encoding, map over lists without reordering them, convert
  # atoms via Atom.to_string/1, pass everything else through unchanged, then
  # Jason.encode!/1 (default output has no insignificant whitespace).
  @spec canonicalize_artefact_content(map()) :: String.t()
  defp canonicalize_artefact_content(content) do
    content
    |> canonicalize_json()
    |> Jason.encode!()
  end

  defp canonicalize_json(value) when is_map(value) do
    value
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn key -> {key, canonicalize_json(Map.get(value, key))} end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize_json(value) when is_list(value) do
    Enum.map(value, &canonicalize_json/1)
  end

  defp canonicalize_json(value)
       when is_atom(value) and not is_boolean(value) and not is_nil(value) do
    Atom.to_string(value)
  end

  defp canonicalize_json(value), do: value

  # Every entity definition lands in the caller's own schema via
  # `opts[:prefix]` and nowhere else -- no `tenant_id`, `schema_name`, or
  # `slug` parameter appears anywhere in this helper (INV-1). `:inactive`-only
  # (0026 §2): no `Letflow.Entities.Definitions.activate_definition/4` call
  # anywhere -- `create_definition/2` already defaults every inserted row to
  # `status: :inactive`. All-or-nothing: the first failure aborts, halting
  # this reduce and flowing into `run_install/5`'s single shared
  # `with`/`else` -> `Repo.rollback/1` path (no new rollback path).
  defp create_packed_entity_definitions(packed_entity_definitions, actor_id, opts) do
    Enum.reduce_while(packed_entity_definitions, {:ok, []}, fn packed, {:ok, acc} ->
      create_attrs = %{definition: packed.definition_json, created_by: actor_id}

      case Letflow.Entities.Definitions.create_definition(create_attrs, prefix(opts)) do
        {:ok, %EntityDefinition{} = created} ->
          {:cont, {:ok, [{packed, created} | acc]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  # Step 7 -- the ONLY write into `variable_schemas`, and it goes through
  # Letflow.Definitions.register_variable_schemas/3, the single shared insert
  # path REQ-082's import also calls. This module adds no second one.
  defp register_packed_schemas(installed, decoded_schemas, opts) do
    by_source = Map.new(installed, fn {packed, created} -> {packed.definition_id, created.id} end)

    {resolved, warnings} =
      Enum.reduce(decoded_schemas, {%{}, []}, fn entry, {acc, warnings} ->
        case Map.fetch(by_source, entry.definition_id) do
          {:ok, new_definition_id} ->
            input = %{
              variable_key: entry.schema_name,
              json_schema: entry.schema_content,
              description: entry.description
            }

            {Map.update(acc, new_definition_id, [input], &(&1 ++ [input])), warnings}

          :error ->
            {acc,
             warnings ++
               [
                 "variable_schemas entry #{inspect(entry.schema_name)} names definition_id " <>
                   "#{inspect(entry.definition_id)}, which this pack does not carry; skipped"
               ]}
        end
      end)

    resolved
    |> Enum.reduce_while({:ok, 0}, fn {definition_id, inputs}, {:ok, total} ->
      case Definitions.register_variable_schemas(definition_id, inputs, opts) do
        {:ok, written} -> {:cont, {:ok, total + written}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, total} -> {:ok, total, warnings}
      {:error, _reason} = error -> error
    end
  end

  defp installed_definition_maps(installed) do
    Enum.map(installed, fn {packed, created} ->
      %{
        source_definition_id: packed.definition_id,
        new_definition_id: created.id,
        process_key: created.name,
        status: "installed"
      }
    end)
  end

  defp installed_entity_definition_maps(installed_entities) do
    Enum.map(installed_entities, fn {packed, created} ->
      %{
        source_entity_definition_id: packed.entity_definition_id,
        new_entity_definition_id: created.id,
        name: created.name,
        status: "installed"
      }
    end)
  end

  # PROVENANCE (historical, not current decision authority):
  # Read-only and advisory: no role is created, none is bound, and the
  # checklist never affects whether the install succeeds. This is a NARROWED
  # analogue of R-Co's `checkRoleGate` (`src/solution/store.zig:589`): that
  # gate can reject an install, but this implementation only reports and
  # proceeds. "Checklist" must not be read as an enforced precondition.
  defp role_mapping_checklist(required_roles) do
    known = MapSet.new(Authorization.roles(), &Atom.to_string/1)

    Enum.map(required_roles, fn role_name ->
      %{role_name: role_name, bound: MapSet.member?(known, role_name)}
    end)
  end
end
