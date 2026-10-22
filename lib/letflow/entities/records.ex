defmodule Letflow.Entities.Records do
  @moduledoc """
  Tenant-scoped command context module for entity records (REQ-228):
  `create_record/2`, `update_record/2`, `delete_record/2`. See
  `lib/letflow/design/req228-entity-event-registration-commands.md` §5 for
  the full design this module implements.

  Tenant scoping follows the same convention `Letflow.Entities.Definitions`
  already uses (design §5 preamble) -- every public function takes an
  explicit `prefix :: String.t()` argument; no function here accepts a
  separately-trusted `tenant_id`.

  ## Scope (REQ-518 PR 2c-ii)

  `create_record/3`, `update_record/3` and `delete_record/3` accept the optional attribute
  `:scope`, the caller's allowed node set (`Letflow.Entities.Query.Types.scope_set/0`): `:all`
  (the default, for system callers and tenant-wide callers), `:none`, or `{:nodes, [id]}`. An
  empty node list means `:none`; a malformed value raises `ArgumentError`. See
  `Letflow.Entities.ScopedWrites` for the rules; refusal is `{:error, :scope_refused}`.

  A scoped write also resolves every reference (`foreign_keys` field) of the NEW document through
  the scope of the referenced type (before the transaction and again inside it), with no
  exemption for an unchanged stored reference on an update (fail closed). A foreign-key violation
  of a scoped write is `{:error, :scope_refused}`, never a 500; a tenant-wide write is a 422
  naming the field (GH #2832). Residual: the referenced row's scope can change between the check
  and the commit (no lock is taken on it).

  ## The inner/outer validation split (AC7)

  Each command function runs REQ-227's **inner** check
  (`Letflow.Entities.Record.Validator.validate_record_payload/2`, against
  the resolved `entity_definitions` row's own field constraints) before ever
  building an `Ecto.Multi`. The **outer** envelope check
  (`Letflow.EventStore.Registry.validate_payload/3`, registered by
  `Letflow.Entities.EventTypes.seed!/1`) runs independently, inside
  `Letflow.EventStore.append_multi/3`'s own pipeline, entirely separate from
  the inner check. See `Letflow.Entities.EventTypes`'s moduledoc for the
  explicit statement of which module validates which (AC7's own requirement).

  ## `entity_type_instance_guard` runs eagerly, before the command's `Multi`
  is even built (flagged deviation from the design's literal §3.2/§5.1
  framing)

  See `Letflow.Entities.EntityTypeInstance`'s own moduledoc for the full
  reasoning: `Letflow.EventStore.append_multi/3`'s `attrs[:instance_id]`
  must be a concrete value at `Ecto.Multi`-composition time, which is
  structurally incompatible with `entity_type_instance_guard` being a lazy
  `Multi.run/3` step within the very `Multi` `append_multi/3`'s steps are
  folded into. `EntityTypeInstance.get_or_create/2` is called first, as a
  plain eager function, its own race-safe insert-if-absent-then-re-select
  protocol standing in for the "Multi step" framing. This does not weaken
  AC2's atomicity guarantee -- AC2 is about the event append and
  `entity_record_latest` write being atomic with each other, not about
  `entity_type_instances`'s own row.

  ONE `Ecto.Multi` is still composed and committed via exactly one
  `Repo.transaction/1` call per command: `Letflow.EventStore.append_multi/3`'s
  own M1-M6 steps, then -- only when the caller passed
  `expected_last_event_global_seq` (GH #2528) -- `:check_record_version`,
  then this module's own `:upsert_record_latest` step (design §5.1 steps
  4-5), then `:dual_write_promoted_columns` (REQ-297).

  ## Managed types (GH #2583)

  Each command has a `/3` arity taking `authority :: ManagedTypes.owner()`; the
  `/2` arity is that call with `:tenant`. Right after the active definition is
  resolved, `ManagedTypes.check_record_write/3` refuses a `managed_by` type with
  `{:error, :entity_type_managed}` unless the authority is that module's `Owner`
  naming the type. See `lib/letflow/design/gh2583-records-managed-type-guard.md`.

  ## Append-only entity types (GH #2529)

  `update_record/2` and `delete_record/2` refuse with
  `{:error, {:entity_append_only, entity_type}}` when the entity type's
  **current** active definition has `"append_only" => true` (literal `true`
  only). The check runs right after the active definition is resolved and
  before any record lookup, so it is existence-independent and appends no
  event. `create_record/2` is unaffected.

  ## Idempotency key binding (GH #2543)

  See `lib/letflow/design/gh2543-idempotency-key-binding.md`. An
  `idempotency_key` is bound to the request that first used it. On a
  duplicate key the new request is compared against the **original event**
  (its `event_type` and `actor_id` columns and its stored payload; no hash
  column, no `Letflow.EventStore` change):

    * bound: the command (`event_type`), the `actor_id`, `entity_type`, the
      target `record_id` (update, delete) and `field_values` (create,
      update), compared as JSON values (`1` matches `1.0`; key order is
      irrelevant);
    * not bound: `expected_last_event_global_seq`, `entity_def_version`,
      metadata, and the `record_id` a create mints per call.

  The same request returns the original as `is_duplicate: true`; anything
  else returns `{:error, :idempotency_key_reuse}` with no event appended. An
  oversized original (`%{"$ref" => event_id}`) is read back from
  `event_payload_store` first. `create_record/2` accepts the internal-only
  option `idempotency_match: :target` (default `:request`), which drops the
  `field_values` compare for a fetch-or-create by natural key
  (`Letflow.Modules.Exam.Certificate`); no request field can set it. The
  step order is unchanged: the GH #2529 append-only check runs before the
  claim and the GH #2528 version check after it.

  ## `entity_def_version`'s atom/string key round-trip (a real gap the design
  doc does not address -- flagged here, not silently patched)

  `Letflow.Entities.Definitions.get_definition_by_name/2` always returns a
  freshly-queried `%Letflow.Entities.EntityDefinition{}` row, whose
  `definition_json` column decodes from `jsonb` as a **string-keyed** map
  with string-valued `"type"` entries (e.g. `"type" => "string"`), confirmed
  directly against `Letflow.Entities.DefinitionsTest`'s own
  `reloaded.definition_json["name"]` assertion. `Letflow.Entities.Record.Validator.build_record_schema/1`
  (REQ-227), by contrast, expects the REQ-225 `Definition.t()` shape
  verbatim -- **atom**-keyed, with `type:` holding an **atom** (`:string`,
  `:enum`, ...) -- confirmed directly against its own test suite's fixtures.
  Passing a freshly-queried `EntityDefinition.definition_json` straight into
  `validate_record_payload/2` would silently produce `[]` (`Map.get(json,
  :fields, [])` finds no `:fields` atom key in a string-keyed map) rather
  than crashing, the worst possible failure mode for a validation gate. This
  module's own private `definition_document/1` converts the persisted,
  string-keyed `definition_json` back into REQ-225's atom-keyed
  `Definition.t()` shape before ever calling `validate_record_payload/2`
  (`String.to_existing_atom/1` on `"type"`'s value is safe: the full closed
  set of field-type atoms is already compiled into
  `Letflow.Entities.Definition.Validator`/`Letflow.Entities.Record.Validator`
  themselves). Flagged for REVIEWER as a real design-doc gap, not a silent
  workaround.

  ## REQ-297 dual-write: a NEW, separate `Multi.run/3` step, not an amendment
  ## to `upsert_record_latest/3`'s existing two clauses

  `docs/migration/decisions/0024-entity-promotion-ddl-execution.md`'s
  Consequences section literally describes the promoted-column dual-write as
  "an amendment to `upsert_record_latest/3`'s existing two clauses." This
  module instead adds one new `:dual_write_promoted_columns` `Multi.run/3`
  step, appended immediately after `:upsert_record_latest` in `run_command/2`'s
  pipeline below — per
  `lib/letflow/design/req297-entity-promotion-executor.md` §8 and
  CODE-DESIGN-VALIDATOR's confirmed reading of that design. This is a
  deliberately more conservative shape than 0024's literal wording (leaves
  `upsert_record_latest/3`'s own two existing clauses completely untouched,
  additive-only at the `Ecto.Multi` level too) and the functionally sounder
  choice, flagged here for a future reader rather than left as an unexplained
  divergence from the decision record's exact prose. Covers all three
  callers (`create_record/2`, `update_record/2`, `delete_record/2`) since all
  three funnel through this one shared pipeline — per
  `docs/anti-patterns.md`'s "established template-substitution mechanism
  applied to two of three sibling paths, not all three," a deleted record's
  promoted-column row must still carry `deleted: true` in the per-entity-type
  table too, not be skipped.

  ## Process-step writes (decision 0054, GH #2587)

  See `lib/letflow/design/gh2587-req499-pr-a-prerequisites.md` section 3.3.

    * `command_multi/3` builds, without writing, the `Ecto.Multi` of ONE
      process-step create line for the caller to compose into its own
      transaction. Its steps are named `{:line, i, step}` (`i` = the line's
      `line_key`): the namespaced `Letflow.EventStore.append_multi/3` steps,
      then `{:line, i, :recheck_definition}` (re-resolves the active
      definition under the type's sequence lock, refuses a changed row and
      repeats the authority check), `{:line, i, :upsert_record_latest}` and
      `{:line, i, :dual_write_promoted_columns}`. The authority is the third,
      positional argument and is checked per line with the same private
      `check_write_authority/3` the single-command path uses (GH #2583
      section 8.2). It accepts only a `"sys:step:"` idempotency key and
      carries the step's `source` as flat `source.*` event-metadata keys.
      Its one allow-listed caller is `Letflow.Entities.StepWrites` (added in PR B; static
      test `test/letflow/entities/command_multi_callers_test.exs`).
    * `interpret_in_multi/1` maps a failed `{:line, i, step}` to a refusal
      code or an internal fault. It has NO success clause: a duplicate key is
      `:idempotency_conflict`, never the original record.
    * The single-command entry points refuse, before any query, a
      `"sys:step:"` key (`{:error, :reserved_idempotency_key}`) and a
      top-level `source` / `metadata` attribute (`{:error,
      :reserved_attribute}`). Their Multi, step names and result
      interpretation are unchanged.
  """

  import Ecto.Query, only: [where: 3, select: 3]
  import Letflow.Entities.ManagedTypes, only: [is_authority: 1]

  alias Ecto.Multi
  alias Letflow.Entities.Definition.DDL
  alias Letflow.Entities.Definition.Validator.Violation
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.ExternalRef
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Query.Types, as: QueryTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Record.Validator
  alias Letflow.Entities.ScopeDeclaration
  alias Letflow.Entities.ScopedWrites
  alias Letflow.Entities.StepSource
  alias Letflow.EventStore
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.Registry
  alias Letflow.EventStore.StoredPayload
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion

  @typedoc """
  GH #2543: how strictly a duplicate `idempotency_key` must match the
  original request. `:request` (default) binds every element; `:target`
  (internal-only, create only) skips the `field_values` compare.
  """
  @type idempotency_match :: :request | :target

  @type create_attrs :: %{
          required(:entity_type) => String.t(),
          required(:field_values) => Validator.field_values(),
          required(:actor_id) => Ecto.UUID.t(),
          required(:idempotency_key) => String.t(),
          optional(:idempotency_match) => idempotency_match(),
          optional(:scope) => QueryTypes.scope_set(),
          optional(:legacy_original) => Event.t()
        }

  @typep request_fingerprint :: %{
           event_type: String.t(),
           actor_id: Ecto.UUID.t(),
           entity_type: String.t(),
           record_id: Ecto.UUID.t() | :not_compared,
           field_values: map() | :not_compared
         }

  @typedoc """
  GH #2528 optimistic-concurrency token: the `last_event_global_seq` the
  caller last saw for the record. `nil` (or the key absent) keeps today's
  last-writer-wins behaviour byte-for-byte.
  """
  @type expected_seq :: non_neg_integer() | nil

  @type update_attrs :: %{
          required(:entity_type) => String.t(),
          required(:record_id) => Ecto.UUID.t(),
          required(:field_values) => Validator.field_values(),
          required(:actor_id) => Ecto.UUID.t(),
          required(:idempotency_key) => String.t(),
          optional(:expected_last_event_global_seq) => expected_seq(),
          optional(:preserve_keys) => MapSet.t(String.t()),
          optional(:scope) => QueryTypes.scope_set(),
          optional(:legacy_original) => Event.t()
        }

  @type delete_attrs :: %{
          required(:entity_type) => String.t(),
          required(:record_id) => Ecto.UUID.t(),
          required(:actor_id) => Ecto.UUID.t(),
          required(:idempotency_key) => String.t(),
          optional(:expected_last_event_global_seq) => expected_seq(),
          optional(:scope) => QueryTypes.scope_set()
        }

  @type command_result :: %{record: Latest.t(), is_duplicate: boolean()}

  @typedoc """
  GH #2659: `external_ref` is the RAW `%{"system" => _, "id" => _}` map (the parser's input); the
  other keys are as `create_attrs()`.
  """
  @type upsert_attrs :: %{
          required(:entity_type) => String.t(),
          required(:external_ref) => map(),
          required(:field_values) => Validator.field_values(),
          required(:actor_id) => Ecto.UUID.t(),
          required(:idempotency_key) => String.t()
        }

  @type upsert_result :: %{
          record: Latest.t(),
          outcome: :created | :updated | :unchanged,
          is_duplicate: boolean()
        }

  @type upsert_error ::
          command_error()
          | {:error, :external_ref_invalid}
          | {:error, {:external_ref_record_deleted, ExternalRef.t()}}
          | {:error, :external_ref_contention}
          | {:error, :event_schema_outdated}

  @type command_error ::
          {:error, {:definition_not_found, entity_type :: String.t()}}
          | {:error, {:record_payload_invalid, Validator.violations() | [Violation.t()]}}
          | {:error, {:record_not_found, record_id :: Ecto.UUID.t()}}
          | {:error, {:record_already_deleted, record_id :: Ecto.UUID.t()}}
          | {:error, :record_version_conflict}
          | {:error, {:entity_append_only, entity_type :: String.t()}}
          | {:error, {:definition_changed, entity_type :: String.t()}}
          | {:error, :idempotency_key_reuse}
          | {:error, :entity_type_managed}
          | {:error, :scope_refused}
          | {:error, :tenant_not_provisioned}
          | {:error, :invalid_schema_name}
          | {:error, {:payload_validation_failed, [term()]}}
          | {:error, :reserved_idempotency_key}
          | {:error, :reserved_attribute}
          | {:error, :preserved_value_invalid}
          | {:error, term()}

  @typedoc "GH #2587: one process-step line (only `kind: :create` is accepted, D-A2.10)."
  @type step_command :: %{
          required(:kind) => :create | :update | :delete,
          required(:entity_type) => String.t(),
          required(:field_values) => Validator.field_values(),
          required(:actor_id) => Ecto.UUID.t(),
          required(:source) => StepSource.t()
        }

  @type step_refusal_code ::
          :record_version_conflict
          | :entity_append_only
          | :write_not_permitted
          | :validation_failed
          | :idempotency_conflict
          | :entity_type_inactive

  @type command_multi_error ::
          {:error, {:command_kind_not_supported, atom()}}
          | {:error, :invalid_step_key}
          | {:error, :invalid_step_source}
          | {:error, {:definition_not_found, String.t()}}
          | {:error, :entity_type_managed}
          | {:error, {:record_payload_invalid, Validator.violations() | [Violation.t()]}}
          | {:error, {:entity_type_instance_missing, String.t()}}
          | {:error, :invalid_schema_name}
          | EventStore.append_error()

  @upsert_max_attempts 3
  @created_event_type "ENTITY_RECORD_CREATED"
  @min_ref_schema_version 2
  @step_key_prefix "sys:step:"
  @step_key_max_bytes 255
  @step_key_format ~r/\Asys:step:[A-Za-z0-9:_.-]+\z/
  @reserved_attribute_keys [:source, "source", :metadata, "metadata"]

  @doc """
  Creates a new entity record (design §5.1). Step order:

    1. Resolve `attrs.entity_type`'s current **active** `EntityDefinition` --
       `{:error, {:definition_not_found, entity_type}}` otherwise.
    2. REQ-227's **inner** `field_values` check -- non-empty violations
       return `{:error, {:record_payload_invalid, violations}}` with **zero**
       events appended (AC4), before any `Ecto.Multi`/transaction exists.
    3. Mint a fresh `record_id`.
    4. Resolve-or-create the synthetic per-type instance.
    5. Append exactly one `ENTITY_RECORD_CREATED` event and insert the
       `entity_record_latest` row, in one transaction (AC2).
    6. Replaying **the same request** with the same `idempotency_key` returns
       the **original** record (AC3, `is_duplicate: true`), decoded from the
       original event's own stored payload. The same key with a different
       request (another command, entity type, actor or `field_values`)
       returns `{:error, :idempotency_key_reuse}` with no event appended
       (GH #2543). The internal-only `idempotency_match: :target` skips the
       `field_values` compare; any value other than `:request`/`:target`
       raises `ArgumentError`.

  GH #2550 (one release, removed by GH #2578): an optional
  `legacy_original` (also on `update_record/2`) is a pre-namespacing
  original event the router resolved for the caller's key
  (`Letflow.Idempotency.legacy_original/3`). It skips the append and is
  matched like a store duplicate: the original as `is_duplicate: true`, or
  `{:error, :idempotency_key_reuse}`.

  Step 1a (GH #2583): `authority` must hold the type. A `managed_by` type is
  written only with that module's `Owner` naming the type; `:tenant` (the `/2`
  default) and any other `Owner` get `{:error, :entity_type_managed}` with
  nothing read beyond the definition.

  Optional `attrs.scope` (REQ-518, default `:all`): the caller's allowed node set,
  `:all | :none | {:nodes, [String.t()]}`. `:all` (system and tenant-wide callers) adds no read
  and no check; an empty `{:nodes, []}` means `:none`; any other value raises `ArgumentError`.
  For a scoped set the type must be declared by a column (else `{:error, :scope_refused}`), the
  declared column of the new (create, update) and the stored (update, delete) document must be a
  string in the set, checked before the transaction and again inside it. Nothing is appended on
  refusal.
  """
  @spec create_record(create_attrs(), prefix :: String.t()) ::
          {:ok, command_result()} | command_error()
  def create_record(attrs, prefix) when is_binary(prefix),
    do: create_record(attrs, prefix, :tenant)

  @spec create_record(create_attrs(), prefix :: String.t(), ManagedTypes.owner()) ::
          {:ok, command_result()} | command_error()
  def create_record(%{entity_type: _, field_values: _} = attrs, prefix, authority)
      when is_binary(prefix) and is_authority(authority),
      do: do_create_record(attrs, prefix, authority, nil)

  # The shared create pipeline. `external_ref` is nil for `create_record/3` and the PARSED
  # `ExternalRef.t()` for the upsert primitive (GH #2659): it never comes from `attrs`, so no
  # caller-supplied map reaches the payload or the columns without `ExternalRef.parse/1`.
  defp do_create_record(
         %{entity_type: entity_type, field_values: field_values} = attrs,
         prefix,
         authority,
         external_ref
       ) do
    match = idempotency_match(attrs)

    with :ok <- reject_reserved_attributes(attrs),
         :ok <- reject_step_key(attrs),
         {:ok, definition} <- fetch_active_definition(entity_type, prefix),
         :ok <- check_write_authority(definition, entity_type, authority),
         {:ok, scope_ctx} <- resolve_scope(attrs, entity_type, prefix),
         {:ok, field_values} <- validate_field_values(definition, field_values),
         :ok <- scope_new_value(scope_ctx, field_values),
         :ok <- scope_new_references(scope_ctx, definition, field_values, prefix) do
      record_id = Ecto.UUID.generate()

      ctx =
        Map.merge(scope_ctx, %{
          kind: :create,
          entity_type: entity_type,
          record_id: record_id,
          field_values: field_values,
          definition: definition,
          existing_record: nil,
          expected_last_event_global_seq: nil,
          idempotency_match: match,
          prefix: prefix,
          authority: authority,
          # GH #2659: set only by `upsert_record_by_external_ref/3` (parsed); nil otherwise.
          external_ref: external_ref
        })

      run_command(ctx, attrs)
    end
  end

  @doc """
  Idempotent create-or-update of one record by its master `external_ref` (GH #2659 / REQ-505,
  design `lib/letflow/design/gh2659-external-ref-idempotent-import.md` sections 3-4). The `/2`
  arity is `/3` with `:tenant`.

  `attrs.external_ref` is the raw `%{"system" => _, "id" => _}` map; it enters only through
  `Letflow.Entities.ExternalRef.parse/1` (`{:error, :external_ref_invalid}` otherwise, nothing
  queried). Steps: parse, the reserved-attribute and `sys:step:` refusals, the active definition
  and write authority, the NORMALISED `field_values` (so strict decimals compare as in
  `create_record/3`), then a lookup by `(entity_type, system, id)` and, in this order:

    * absent: create with the ref in the `ENTITY_RECORD_CREATED` v2 payload and on the row
      (`outcome: :created`);
    * present and soft-deleted: `{:error, {:external_ref_record_deleted, ref}}`, nothing appended
      (no silent revival);
    * present, live, normalised values JSON-equal to the stored ones: `outcome: :unchanged`,
      no event and no write. Evaluated BEFORE the append-only check, so re-running a file against
      an `append_only` type is safe;
    * present, live, different: `update_record/3` (full replacement) with the read
      `last_event_global_seq` as the expected version (`outcome: :updated`; an `append_only` type
      answers `{:error, {:entity_append_only, type}}`).

  Races are arbitrated by the existing locks, never by a new one (decision 0061 rule 1, class 5):
  the partial unique index on the create path, `check_record_version` on the update path, both
  after the type's sequence-row lock. A lost race (the ref index's unique violation, a
  `:record_version_conflict`, or a delete that landed between lookup and write) re-runs from the
  lookup; each failed attempt rolled back whole. After 3 attempts the answer is the constant
  `{:error, :external_ref_contention}`; the unique-violation changeset, which carries the ref, is
  never returned.

  The function is convergent, not replay-keyed: its result follows the current state first and the
  `idempotency_key` only protects an append (design section 5.3.1). `is_duplicate: true` is
  returned only when the underlying command returns it. The router (PR 3) applies the per-request
  `TypeAccess` and field-restriction checks; the primitive does not.

  GH #2807: only the create branch needs `ENTITY_RECORD_CREATED` at schema v2 (the version that
  carries the ref); update and unchanged do not. The create branch therefore reads
  `Registry.max_schema_version/2` and answers `{:error, :event_schema_outdated}` (also for an
  absent registry row) before any write. The `/4` option `schema_checked: true` skips that read
  for a caller that has already done it once for a whole batch (`ImportUpsert.precheck/2`); a
  module handler calls without it. Any other option key or a non-boolean value raises
  `ArgumentError`.
  """
  @spec upsert_record_by_external_ref(upsert_attrs(), prefix :: String.t()) ::
          {:ok, upsert_result()} | upsert_error()
  def upsert_record_by_external_ref(attrs, prefix) when is_binary(prefix),
    do: upsert_record_by_external_ref(attrs, prefix, :tenant, [])

  @spec upsert_record_by_external_ref(upsert_attrs(), prefix :: String.t(), ManagedTypes.owner()) ::
          {:ok, upsert_result()} | upsert_error()
  def upsert_record_by_external_ref(attrs, prefix, authority),
    do: upsert_record_by_external_ref(attrs, prefix, authority, [])

  @doc "The lowest `ENTITY_RECORD_CREATED` schema version that carries an `external_ref`."
  @spec min_ref_schema_version() :: pos_integer()
  def min_ref_schema_version, do: @min_ref_schema_version

  @spec upsert_record_by_external_ref(
          upsert_attrs(),
          prefix :: String.t(),
          ManagedTypes.owner(),
          schema_checked: boolean()
        ) :: {:ok, upsert_result()} | upsert_error()
  def upsert_record_by_external_ref(
        %{entity_type: entity_type, field_values: field_values} = attrs,
        prefix,
        authority,
        opts
      )
      when is_binary(prefix) and is_authority(authority) and is_list(opts) do
    schema_checked = upsert_opts!(opts)

    # The definition is resolved and the values validated here (to compare before writing) and
    # again inside create_record/update_record: two cheap reads kept so the write path stays the
    # one existing command pipeline (no second copy of its checks).
    with {:ok, ref} <- ExternalRef.from_payload(Map.get(attrs, :external_ref)),
         :ok <- reject_reserved_attributes(attrs),
         :ok <- reject_step_key(attrs),
         {:ok, definition} <- fetch_active_definition(entity_type, prefix),
         :ok <- check_write_authority(definition, entity_type, authority),
         {:ok, normalised} <- validate_field_values(definition, field_values) do
      # `external_ref` is parsed above and travels separately; `idempotency_match` and
      # `legacy_original` are create-only internals that the upsert never forwards.
      command_attrs = Map.drop(attrs, [:external_ref, :idempotency_match, :legacy_original])

      upsert_attempt(
        %{
          attrs: command_attrs,
          ref: ref,
          normalised: canonical_json(normalised),
          prefix: prefix,
          authority: authority,
          schema_checked: schema_checked
        },
        @upsert_max_attempts
      )
    end
  end

  defp upsert_opts!(opts) do
    case Keyword.pop(opts, :schema_checked, false) do
      {checked, []} when is_boolean(checked) ->
        checked

      _invalid ->
        raise ArgumentError,
              "upsert_record_by_external_ref/4 accepts only schema_checked: boolean, got: " <>
                inspect(opts)
    end
  end

  defp upsert_attempt(_run, 0), do: {:error, :external_ref_contention}

  defp upsert_attempt(%{ref: ref, prefix: prefix} = run, attempts_left) do
    outcome =
      case Latest.get_by_external_ref(run.attrs.entity_type, ref.system, ref.id, prefix) do
        {:error, :not_found} -> upsert_create(run)
        {:ok, %Latest{deleted: true}} -> {:error, {:external_ref_record_deleted, ref}}
        {:ok, %Latest{} = existing} -> upsert_existing(run, existing)
        {:error, :invalid_schema_name} = error -> error
      end

    if lost_race?(outcome),
      do: upsert_attempt(run, attempts_left - 1),
      else: outcome
  end

  defp upsert_create(%{prefix: prefix, schema_checked: schema_checked} = run) do
    if schema_checked or ref_schema_ready?(prefix),
      do: upsert_create_checked(run),
      else: {:error, :event_schema_outdated}
  end

  defp ref_schema_ready?(prefix) do
    version = Registry.max_schema_version(@created_event_type, prefix)
    is_integer(version) and version >= @min_ref_schema_version
  end

  defp upsert_create_checked(%{attrs: attrs, ref: ref, prefix: prefix, authority: authority}) do
    case do_create_record(attrs, prefix, authority, ref) do
      {:ok, %{record: record, is_duplicate: false}} ->
        {:ok, %{record: record, outcome: :created, is_duplicate: false}}

      # The create fingerprint binds neither the ref nor the record id, so a caller key that
      # created ref A and is replayed for an absent ref B with equal values would otherwise be
      # answered with A's record as a "created" duplicate (REVIEWER F1): that is key reuse.
      {:ok, %{record: record, is_duplicate: true}} ->
        if Latest.external_ref(record) == ref,
          do: {:ok, %{record: record, outcome: :created, is_duplicate: true}},
          else: {:error, :idempotency_key_reuse}

      {:error, _reason} = error ->
        error
    end
  end

  defp upsert_existing(run, %Latest{} = existing) do
    if json_equal?(existing.field_values, run.normalised) do
      {:ok, %{record: existing, outcome: :unchanged, is_duplicate: false}}
    else
      update_attrs =
        run.attrs
        |> Map.put(:record_id, existing.record_id)
        |> Map.put(:expected_last_event_global_seq, existing.last_event_global_seq)

      case update_record(update_attrs, run.prefix, run.authority) do
        {:ok, %{record: record, is_duplicate: duplicate?}} ->
          {:ok, %{record: record, outcome: :updated, is_duplicate: duplicate?}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp lost_race?({:error, :record_version_conflict}), do: true
  defp lost_race?({:error, {:record_already_deleted, _record_id}}), do: true
  defp lost_race?({:error, %Ecto.Changeset{} = changeset}), do: external_ref_conflict?(changeset)
  defp lost_race?(_outcome), do: false

  @doc """
  Updates an existing entity record with a **full replacement** `field_values`
  (whole-document semantics, design §5.2) -- same step order as
  `create_record/2`, plus: the target record must already exist
  (`{:error, {:record_not_found, record_id}}` otherwise) and must not already
  be deleted (`{:error, {:record_already_deleted, record_id}}` otherwise).
  Validates against `entity_type`'s **current** active definition, which may
  differ from the definition version the record was originally created
  under (design §5.2, an explicit non-goal to reconcile).

  GH #2543: the `idempotency_key` is bound to the request, as in
  `create_record/2` step 6 -- replaying the same request (same command,
  `entity_type`, `record_id`, `field_values` and actor) returns the original
  as `is_duplicate: true`; the same key with a different request returns
  `{:error, :idempotency_key_reuse}`. The expected sequence below is not part
  of the binding.

  GH #2528: an optional `:expected_last_event_global_seq` makes the write
  conditional. Inside the transaction, after the per-type sequence lock and
  the idempotency check (so a replay of the same request still returns the
  original as `is_duplicate: true`), the row is re-read `FOR UPDATE`; a mismatch (or a row
  that vanished) returns `{:error, :record_version_conflict}` and rolls back
  the whole command, idempotency claim included. Absent/`nil` adds no step at
  all. A non-nil value that is not a non-negative integer raises
  `ArgumentError` (programmer error from an internal caller).

  GH #2529: if the current active definition carries `"append_only" => true`,
  returns `{:error, {:entity_append_only, entity_type}}` right after the
  definition is resolved -- before the record lookup, payload validation and
  idempotency -- so the answer is the same for any `record_id` and no event is
  appended.

  GH #2543: the duplicate-key binding is always the full `:request` match;
  `idempotency_match` is create-only and is ignored here.

  Step 1a (GH #2583): `authority` must hold the type. A `managed_by` type is
  written only with that module's `Owner` naming the type; `:tenant` (the `/2`
  default) and any other `Owner` get `{:error, :entity_type_managed}` with
  nothing read beyond the definition.

  Optional `attrs.scope` (REQ-518, default `:all`): the caller's allowed node set,
  `:all | :none | {:nodes, [String.t()]}`. `:all` (system and tenant-wide callers) adds no read
  and no check; an empty `{:nodes, []}` means `:none`; any other value raises `ArgumentError`.
  For a scoped set the type must be declared by a column (else `{:error, :scope_refused}`), the
  declared column of the new (create, update) and the stored (update, delete) document must be a
  string in the set, checked before the transaction and again inside it. Nothing is appended on
  refusal.

  GH #2812: the internal `attrs.preserve_keys` (a `MapSet` of field names, default empty) carries
  the STORED value of each named key into the written document, whatever the body holds for it,
  before validation and before the event is built (the event stays a whole-document event). The
  write is then always conditional: `expected_last_event_global_seq` if given, else the version
  merged from, checked FOR UPDATE by the existing version step. A stored value that no longer
  validates gives `{:error, :preserved_value_invalid}` (no field name reaches the caller).
  """
  @spec update_record(update_attrs(), prefix :: String.t()) ::
          {:ok, command_result()} | command_error()
  def update_record(attrs, prefix) when is_binary(prefix),
    do: update_record(attrs, prefix, :tenant)

  @spec update_record(update_attrs(), prefix :: String.t(), ManagedTypes.owner()) ::
          {:ok, command_result()} | command_error()
  def update_record(
        %{entity_type: entity_type, record_id: record_id, field_values: field_values} = attrs,
        prefix,
        authority
      )
      when is_binary(prefix) and is_authority(authority) do
    expected = expected_seq(attrs)

    with :ok <- reject_reserved_attributes(attrs),
         :ok <- reject_step_key(attrs),
         {:ok, definition} <- fetch_active_definition(entity_type, prefix),
         :ok <- check_write_authority(definition, entity_type, authority),
         :ok <- ensure_mutable(definition, entity_type),
         {:ok, scope_ctx} <- resolve_scope(attrs, entity_type, prefix),
         {:ok, existing_record} <- fetch_existing_record(record_id, entity_type, prefix),
         :ok <- scope_old_value(scope_ctx, existing_record),
         :ok <- ensure_not_deleted(existing_record, record_id),
         preserve = preserve_keys(attrs),
         merged = merge_preserved(field_values, existing_record, preserve),
         {:ok, field_values} <- validate_merged(definition, merged, preserve),
         :ok <- scope_new_value(scope_ctx, field_values),
         :ok <- scope_new_references(scope_ctx, definition, field_values, prefix) do
      expected = pin_expected(expected, existing_record, preserve)

      ctx =
        Map.merge(scope_ctx, %{
          kind: :update,
          entity_type: entity_type,
          record_id: record_id,
          field_values: field_values,
          definition: definition,
          existing_record: existing_record,
          expected_last_event_global_seq: expected,
          idempotency_match: :request,
          prefix: prefix,
          authority: authority
        })

      run_command(ctx, attrs)
    end
  end

  @doc """
  Deletes an entity record (design §5.2): appends one `ENTITY_RECORD_DELETED`
  event and marks the `entity_record_latest` row `deleted: true`,
  `field_values` retained unchanged at its last pre-delete value. Deleting an
  already-deleted record is a **no-op success** (except on an append-only
  type, below) returning the existing
  (already-deleted) row with `is_duplicate: false` -- deletion is naturally
  idempotent at the domain level, independent of the idempotency-key
  mechanism.

  GH #2528: the optional `:expected_last_event_global_seq` works as in
  `update_record/2` for a live record. An already-deleted record keeps the
  no-op success above regardless of the expected value (no check, no event).

  GH #2529: an append-only type (current active definition carries
  `"append_only" => true`) returns `{:error, {:entity_append_only, entity_type}}`
  right after the definition is resolved, before the record lookup and the
  already-deleted no-op, for any `record_id`, with no event appended.

  Step 1a (GH #2583): `authority` must hold the type. A `managed_by` type is
  written only with that module's `Owner` naming the type; `:tenant` (the `/2`
  default) and any other `Owner` get `{:error, :entity_type_managed}` with
  nothing read beyond the definition.

  Optional `attrs.scope` (REQ-518, default `:all`): the caller's allowed node set,
  `:all | :none | {:nodes, [String.t()]}`. `:all` (system and tenant-wide callers) adds no read
  and no check; an empty `{:nodes, []}` means `:none`; any other value raises `ArgumentError`.
  For a scoped set the type must be declared by a column (else `{:error, :scope_refused}`), the
  declared column of the new (create, update) and the stored (update, delete) document must be a
  string in the set, checked before the transaction and again inside it. Nothing is appended on
  refusal.
  """
  @spec delete_record(delete_attrs(), prefix :: String.t()) ::
          {:ok, command_result()} | command_error()
  def delete_record(attrs, prefix) when is_binary(prefix),
    do: delete_record(attrs, prefix, :tenant)

  @spec delete_record(delete_attrs(), prefix :: String.t(), ManagedTypes.owner()) ::
          {:ok, command_result()} | command_error()
  def delete_record(%{entity_type: entity_type, record_id: record_id} = attrs, prefix, authority)
      when is_binary(prefix) and is_authority(authority) do
    expected = expected_seq(attrs)

    with :ok <- reject_reserved_attributes(attrs),
         :ok <- reject_step_key(attrs),
         {:ok, definition} <- fetch_active_definition(entity_type, prefix),
         :ok <- check_write_authority(definition, entity_type, authority),
         :ok <- ensure_mutable(definition, entity_type),
         {:ok, scope_ctx} <- resolve_scope(attrs, entity_type, prefix),
         {:ok, existing_record} <- fetch_existing_record(record_id, entity_type, prefix),
         :ok <- scope_old_value(scope_ctx, existing_record) do
      if existing_record.deleted do
        {:ok, %{record: existing_record, is_duplicate: false}}
      else
        ctx =
          Map.merge(scope_ctx, %{
            kind: :delete,
            entity_type: entity_type,
            record_id: record_id,
            field_values: existing_record.field_values,
            definition: definition,
            existing_record: existing_record,
            expected_last_event_global_seq: expected,
            idempotency_match: :request,
            prefix: prefix,
            authority: authority
          })

        run_command(ctx, attrs)
      end
    end
  end

  # ---------------------------------------------------------------------
  # GH #2587 / REQ-499 -- process-step writes (design
  # lib/letflow/design/gh2587-req499-pr-a-prerequisites.md section 3.3)
  # ---------------------------------------------------------------------

  @doc """
  The server step-key prefix (`"sys:step:"`, decision 0054 D9.2). Only
  `command_multi/3` accepts a key with it; the single-command entry points and
  every un-namespaced `Letflow.EventStore` append refuse it.
  """
  @spec step_key_prefix() :: String.t()
  def step_key_prefix, do: @step_key_prefix

  @doc """
  Builds, WITHOUT writing, the `Ecto.Multi` of one process-step line (design
  3.3; decision 0054 D2). The caller composes it into its own transaction.
  Only `kind: :create` is supported (`{:error, {:command_kind_not_supported,
  kind}}` otherwise, no query).

  Build order:

    1. Shape, no query: `kind`; the command carries NO `line_key` or
       `idempotency_key` (else `:invalid_step_source`): the line key is
       `StepSource.line_key/1` (the `line_index` for a declarative line) and the step key is `StepSource.idempotency_key/1`
       (#2627), which matches `\\Asys:step:[A-Za-z0-9:_.-]+\\z` and is at most 255 bytes (else
       `:invalid_step_key`); `source` is a `Letflow.Entities.StepSource` struct (a
       bare map is refused; the shape is `StepSource.new/1`'s single validation, else
       `:invalid_step_source`). `entity_type` must be a binary, `field_values`
       a map and `actor_id` a UUID (else `:invalid_step_source`).
    2. The active definition (query), then `authority` through the same
       `check_write_authority/3` as `create_record/3` (managed type ->
       `{:error, :entity_type_managed}`, nothing else read), then the inner
       payload check.
    3. The synthetic instance, read-only (`{:error,
       {:entity_type_instance_missing, type}}` when the caller's preparation did
       not create it; never inserted here).
    4. `Letflow.EventStore.append_multi/3` with `step_namespace: {:line, line_key}`;
       the event carries the flat `source.*` metadata keys.
    5. `{:line, i, :recheck_definition}`: under the type's sequence lock,
       re-resolves the active definition, refuses `{:definition_changed, type}`
       when its row differs from the build-time row, repeats the authority check
       and returns the row.
    6. `{:line, i, :upsert_record_latest}`, `{:line, i, :dual_write_promoted_columns}`.

  `authority` is the third, positional argument (GH #2583 section 8.2); a value
  that is neither `:tenant` nor an `Owner` raises `FunctionClauseError`.
  """
  @spec command_multi(step_command(), prefix :: String.t(), ManagedTypes.owner()) ::
          {:ok, Ecto.Multi.t()} | command_multi_error()
  def command_multi(command, prefix, authority)
      when is_binary(prefix) and is_authority(authority) do
    with {:ok, line} <- check_step_command(command),
         {:ok, definition} <- fetch_active_definition(line.entity_type, prefix),
         :ok <- check_write_authority(definition, line.entity_type, authority),
         {:ok, field_values} <- validate_field_values(definition, line.field_values),
         {:ok, instance_id} <- fetch_step_instance_id(line.entity_type, prefix) do
      ctx = %{
        kind: :create,
        entity_type: line.entity_type,
        record_id: Ecto.UUID.generate(),
        field_values: field_values,
        definition: definition,
        existing_record: nil,
        expected_last_event_global_seq: nil,
        idempotency_match: :request,
        prefix: prefix,
        # GH #2659: engine step writes never carry an external ref (NULL/NULL columns).
        external_ref: nil
      }

      event_attrs =
        ctx
        |> build_event_attrs(
          Map.put(command, :idempotency_key, line.idempotency_key),
          instance_id
        )
        |> Map.put(:metadata, line.metadata)

      namespace = {:line, line.line_key}

      with {:ok, multi} <-
             EventStore.append_multi(Multi.new(), event_attrs,
               prefix: prefix,
               step_namespace: namespace
             ) do
        {:ok,
         multi
         |> run_line_step(namespace, :recheck_definition, fn _repo, _changes ->
           recheck_definition(definition, line.entity_type, prefix, authority)
         end)
         |> run_line_step(namespace, :upsert_record_latest, fn repo, changes ->
           upsert_record_latest(repo, changes, ctx)
         end)
         |> run_line_step(namespace, :dual_write_promoted_columns, fn repo, changes ->
           dual_write_promoted_columns(repo, changes, ctx)
         end)}
      end
    end
  end

  @doc """
  Maps a failed transaction of a Multi built from `command_multi/3` lines to the
  line's outcome (design 3.3). `{:entity_write_refused, i, code}` for a refusal,
  `{:entity_write_failed, i, step}` for an internal fault, `:not_a_line_failure`
  for a step that is not `{:line, i, _}`. There is no success clause: a duplicate
  `idempotency_key` is `:idempotency_conflict`, never the original record. The
  result never carries a field value or field name.
  """
  @spec interpret_in_multi({:error, Ecto.Multi.name(), term(), map()}) ::
          {:entity_write_refused, non_neg_integer(), step_refusal_code()}
          | {:entity_write_failed, non_neg_integer(), atom()}
          | :not_a_line_failure
  def interpret_in_multi({:error, {:line, i, step}, reason, _changes})
      when is_integer(i) and i >= 0 and is_atom(step),
      do: line_failure(i, step, reason)

  def interpret_in_multi({:error, _name, _reason, _changes}), do: :not_a_line_failure

  @doc """
  Classifies a `command_multi/3` build error or a `{:line, i, :build}` /
  `{:line, i, :recheck_definition}` step reason (design 3.3 table). Managed,
  not-found and already-deleted all answer `:write_not_permitted` (INV-5).
  """
  @spec classify_step_error(term()) :: {:refused, step_refusal_code()} | :internal
  def classify_step_error({:definition_not_found, _type}), do: {:refused, :entity_type_inactive}
  def classify_step_error({:definition_changed, _type}), do: {:refused, :entity_type_inactive}
  def classify_step_error(:entity_type_managed), do: {:refused, :write_not_permitted}
  def classify_step_error({:record_payload_invalid, _}), do: {:refused, :validation_failed}
  def classify_step_error({:entity_append_only, _type}), do: {:refused, :entity_append_only}
  def classify_step_error(:record_version_conflict), do: {:refused, :record_version_conflict}
  def classify_step_error({:record_not_found, _id}), do: {:refused, :write_not_permitted}
  def classify_step_error({:record_already_deleted, _id}), do: {:refused, :write_not_permitted}
  def classify_step_error(:idempotency_key_reuse), do: {:refused, :idempotency_conflict}
  def classify_step_error({:duplicate_idempotency_key, _}), do: {:refused, :idempotency_conflict}
  def classify_step_error(_other), do: :internal

  defp line_failure(i, step, reason) when step in [:build, :recheck_definition] do
    case classify_step_error(reason) do
      {:refused, code} -> {:entity_write_refused, i, code}
      :internal -> {:entity_write_failed, i, step}
    end
  end

  defp line_failure(i, :idempotency, {:duplicate_idempotency_key, %Event{}}),
    do: {:entity_write_refused, i, :idempotency_conflict}

  defp line_failure(i, :check_record_version, :record_version_conflict),
    do: {:entity_write_refused, i, :record_version_conflict}

  defp line_failure(i, :dual_write_promoted_columns, {:record_payload_invalid, _}),
    do: {:entity_write_refused, i, :validation_failed}

  defp line_failure(i, step, _reason), do: {:entity_write_failed, i, step}

  # D-A2.15 (CDV-4): runs after the namespaced append steps, so the type's
  # instance_sequences row is locked from {:line, i, :assign_sequence} to commit.
  @spec recheck_definition(EntityDefinition.t(), String.t(), String.t(), ManagedTypes.owner()) ::
          {:ok, EntityDefinition.t()}
          | {:error, {:definition_changed, String.t()}}
          | {:error, {:definition_not_found, String.t()}}
          | {:error, :entity_type_managed}
          | {:error, :invalid_schema_name}
  # The repeated authority check is defensive: managed_by is immutable (DB trigger), so it
  # cannot differ from the build-time row (GH #2583 section 8.2).
  defp recheck_definition(%EntityDefinition{id: built_id}, entity_type, prefix, authority) do
    case fetch_active_definition(entity_type, prefix) do
      {:ok, %EntityDefinition{id: ^built_id} = current} ->
        with :ok <- check_write_authority(current, entity_type, authority), do: {:ok, current}

      {:ok, %EntityDefinition{}} ->
        {:error, {:definition_changed, entity_type}}

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_step_instance_id(entity_type, prefix) do
    case EntityTypeInstance.fetch_instance_id(entity_type, prefix) do
      {:ok, instance_id} -> {:ok, instance_id}
      {:error, :not_found} -> {:error, {:entity_type_instance_missing, entity_type}}
    end
  end

  # Names the step {:line, i, step} and hands it only this line's changes, keyed
  # by the bare step atom (the same view Letflow.EventStore gives its own
  # namespaced steps), so upsert_record_latest/3 and dual_write_promoted_columns/3
  # keep their fixed-key reads.
  defp run_line_step(multi, {:line, i}, step, fun) do
    Multi.run(multi, {:line, i, step}, fn repo, changes ->
      local = for {{:line, ^i, name}, value} <- changes, into: %{}, do: {name, value}
      fun.(repo, local)
    end)
  end

  # Design 3.3 build step 1: pure shape checks. The line key and the step
  # idempotency key are DERIVED from the source (#2627, OQ-C7): a command that
  # carries its own `line_key` / `idempotency_key` is refused, so they cannot
  # disagree with `source`.
  @spec check_step_command(term()) ::
          {:ok,
           %{
             line_key: non_neg_integer(),
             idempotency_key: String.t(),
             entity_type: String.t(),
             field_values: map(),
             metadata: %{String.t() => String.t()}
           }}
          | {:error, {:command_kind_not_supported, atom()}}
          | {:error, :invalid_step_key}
          | {:error, :invalid_step_source}
  defp check_step_command(%{kind: :create} = command) when not is_struct(command) do
    with :ok <- reject_caller_keys(command),
         {:ok, source} <- check_source(command),
         key = StepSource.idempotency_key(source),
         :ok <- check_step_key(key),
         {:ok, entity_type, field_values} <- check_step_target(command) do
      {:ok,
       %{
         line_key: StepSource.line_key(source),
         idempotency_key: key,
         entity_type: entity_type,
         field_values: field_values,
         metadata: StepSource.to_metadata(source)
       }}
    end
  end

  defp check_step_command(%{kind: kind} = command)
       when is_atom(kind) and not is_struct(command),
       do: {:error, {:command_kind_not_supported, kind}}

  defp check_step_command(_command), do: {:error, :invalid_step_source}

  defp reject_caller_keys(command) do
    if Map.has_key?(command, :line_key) or Map.has_key?(command, :idempotency_key),
      do: {:error, :invalid_step_source},
      else: :ok
  end

  # A literal %StepSource{} could skip new/1: re-run the constructor, the only
  # validation of the shape (no second hand-written check here).
  defp check_source(%{source: %StepSource{} = source}),
    do: StepSource.new(Map.from_struct(source))

  defp check_source(_command), do: {:error, :invalid_step_source}

  # Defence in depth on the DERIVED key (D-A2.3): anchored, closed charset, at
  # most 255 bytes. Only an absurdly large line_index can fail it.
  defp check_step_key(key) when byte_size(key) <= @step_key_max_bytes do
    if Regex.match?(@step_key_format, key), do: :ok, else: {:error, :invalid_step_key}
  end

  defp check_step_key(_key), do: {:error, :invalid_step_key}

  defp check_step_target(%{entity_type: entity_type, field_values: field_values} = command)
       when is_binary(entity_type) and byte_size(entity_type) > 0 and is_map(field_values) and
              not is_struct(field_values) do
    with actor_id when is_binary(actor_id) <- Map.get(command, :actor_id),
         {:ok, _actor_id} <- Ecto.UUID.cast(actor_id) do
      {:ok, entity_type, field_values}
    else
      _invalid -> {:error, :invalid_step_source}
    end
  end

  defp check_step_target(_command), do: {:error, :invalid_step_source}

  # D-A2.4: the single-command entry points never take a caller-supplied
  # source/metadata (decision 0054 D10). A record FIELD named "source" lives
  # inside field_values and is unaffected.
  defp reject_reserved_attributes(attrs) do
    if Enum.any?(@reserved_attribute_keys, &Map.has_key?(attrs, &1)),
      do: {:error, :reserved_attribute},
      else: :ok
  end

  # GH #2812: `attrs.preserve_keys` (internal, set by the router only) names the restricted keys the
  # actor cannot see. Absent or empty = today's whole-document replace.
  defp preserve_keys(%{preserve_keys: %MapSet{} = keys}), do: keys
  defp preserve_keys(_attrs), do: MapSet.new()

  # The stored value of a preserved key wins over anything in the body and is carried verbatim; a
  # preserved key that is not stored stays absent.
  defp merge_preserved(field_values, existing_record, preserve) do
    if MapSet.size(preserve) == 0 do
      field_values
    else
      stored = existing_record.field_values |> Map.take(MapSet.to_list(preserve))
      field_values |> Map.drop(MapSet.to_list(preserve)) |> Map.merge(stored)
    end
  end

  # With preserved keys the write is always conditional: the client's token, else the version the
  # merge read. There is deliberately no pre-transaction comparison (it would run before the
  # :idempotency step and break the replay rule, GH #2528/#2543); the FOR UPDATE step in
  # `check_record_version` is the single check.
  defp pin_expected(nil, existing_record, preserve) do
    if MapSet.size(preserve) > 0, do: existing_record.last_event_global_seq, else: nil
  end

  defp pin_expected(expected, _existing_record, _preserve), do: expected

  # A violation that names a preserved key (or no key at all, e.g. a document-level `required`)
  # could leak a restricted name: it becomes `:preserved_value_invalid` (the router's constant 403).
  defp validate_merged(definition, merged, preserve) do
    case validate_field_values(definition, merged) do
      {:error, {:record_payload_invalid, violations}} = error ->
        if MapSet.size(preserve) > 0 and Enum.any?(violations, &touches_preserved?(&1, preserve)),
          do: {:error, :preserved_value_invalid},
          else: error

      other ->
        other
    end
  end

  defp touches_preserved?(%{field_path: path}, preserve) when is_binary(path) do
    case path |> String.split("/", trim: true) |> List.first() do
      nil -> true
      key -> MapSet.member?(preserve, key)
    end
  end

  defp touches_preserved?(_violation, _preserve), do: true

  # D-A2.1: exact bytes; only command_multi/3 accepts the step-key family.
  defp reject_step_key(%{idempotency_key: @step_key_prefix <> _rest}),
    do: {:error, :reserved_idempotency_key}

  defp reject_step_key(_attrs), do: :ok

  # ---------------------------------------------------------------------
  # Shared pipeline (design §5.1 steps 4-7)
  # ---------------------------------------------------------------------

  defp run_command(%{entity_type: entity_type, prefix: prefix} = ctx, attrs) do
    with {:ok, synthetic_instance_id} <- EntityTypeInstance.get_or_create(entity_type, prefix) do
      event_attrs = build_event_attrs(ctx, attrs, synthetic_instance_id)
      fingerprint = request_fingerprint(ctx, attrs)

      case Map.get(attrs, :legacy_original) do
        %Event{} = original -> original_result(original, fingerprint, prefix)
        nil -> append_command(ctx, event_attrs, fingerprint, prefix)
      end
    end
  end

  # A duplicate's original, matched against this request (GH #2543). Also
  # GH #2550's legacy hit (design D3, removed by GH #2578): a pre-namespacing
  # caller key the router already resolved to its original event takes this
  # path with no append.
  defp original_result(original, fingerprint, prefix) do
    case match_original(original, fingerprint, prefix) do
      {:ok, resolved} -> {:ok, duplicate_result(resolved)}
      {:error, _reason} = error -> error
    end
  end

  defp append_command(ctx, event_attrs, fingerprint, prefix) do
    case EventStore.append_multi(Multi.new(), event_attrs, prefix: prefix) do
      {:ok, multi} ->
        multi
        |> maybe_check_record_version(ctx)
        # REQ-518: the scope recheck (old and new value), under the same locks; scoped callers only.
        |> maybe_scope_check(ctx)
        # GH #2654: under the type's sequence lock (taken by the append steps above).
        # On a race the step's raw `{:error, reason}` (`{:definition_changed, type}`, or the
        # defensive `{:definition_not_found, type}` / `:entity_type_managed` /
        # `:invalid_schema_name` the recheck can also return) reaches the caller through
        # interpret_result/3's generic clause; the router maps each of them (409 / 404 / 403 /
        # 500 for the unreachable schema error), anything else to the logged 500 catch-all.
        |> Multi.run(:recheck_definition, fn _repo, _changes ->
          recheck_definition(ctx.definition, ctx.entity_type, prefix, ctx.authority)
        end)
        |> Multi.run(:upsert_record_latest, fn repo, changes ->
          upsert_record_latest(repo, changes, ctx)
        end)
        |> Multi.run(:dual_write_promoted_columns, fn repo, changes ->
          dual_write_promoted_columns(repo, changes, ctx)
        end)
        |> Repo.transaction()
        |> interpret_result(fingerprint, prefix)

      {:error, _reason} = error ->
        error
    end
  end

  defp build_event_attrs(%{kind: :create} = ctx, attrs, instance_id) do
    payload =
      base_payload(ctx)
      |> Map.put("field_values", ctx.field_values)
      |> put_external_ref(ctx.external_ref)

    to_append_attrs("ENTITY_RECORD_CREATED", payload, attrs, instance_id)
  end

  defp build_event_attrs(%{kind: :update} = ctx, attrs, instance_id) do
    payload = base_payload(ctx) |> Map.put("field_values", ctx.field_values)
    to_append_attrs("ENTITY_RECORD_UPDATED", payload, attrs, instance_id)
  end

  defp build_event_attrs(%{kind: :delete} = ctx, attrs, instance_id) do
    payload = base_payload(ctx)
    to_append_attrs("ENTITY_RECORD_DELETED", payload, attrs, instance_id)
  end

  # GH #2659: the payload gains "external_ref" only when a ref is supplied, so every other
  # payload stays byte-identical to today.
  defp put_external_ref(payload, nil), do: payload

  defp put_external_ref(payload, %ExternalRef{} = ref),
    do: Map.put(payload, "external_ref", ExternalRef.to_payload(ref))

  defp base_payload(%{entity_type: entity_type, record_id: record_id, definition: definition}) do
    %{
      "entity_type" => entity_type,
      "entity_def_version" => hex_version(definition),
      "record_id" => record_id
    }
  end

  defp to_append_attrs(event_type, payload_map, attrs, instance_id) do
    %{
      instance_id: instance_id,
      event_type: event_type,
      payload: Jason.encode!(payload_map),
      actor_id: attrs.actor_id,
      idempotency_key: attrs.idempotency_key
    }
  end

  defp upsert_record_latest(repo, changes, %{kind: :create} = ctx) do
    %Latest{}
    |> Latest.insert_changeset(
      Map.merge(
        %{
          entity_type: ctx.entity_type,
          record_id: ctx.record_id,
          field_values: ctx.field_values,
          entity_def_version: ctx.definition.logical_shape_version,
          last_event_global_seq: fetch_global_seq(changes)
        },
        %{external_ref: ctx.external_ref}
      )
    )
    |> repo.insert(prefix: ctx.prefix)
  end

  # GH #2528 design D5: when :check_record_version ran, the changeset is based
  # on the row it locked (so Ecto's UPDATE diff is computed against the
  # current row by construction); otherwise on the pre-transaction read, as
  # before (D2: the nil path is unchanged).
  defp upsert_record_latest(repo, changes, %{kind: kind} = ctx) when kind in [:update, :delete] do
    changes
    |> Map.get(:check_record_version, ctx.existing_record)
    |> Latest.update_changeset(%{
      field_values: ctx.field_values,
      deleted: kind == :delete,
      entity_def_version: ctx.definition.logical_shape_version,
      last_event_global_seq: fetch_global_seq(changes)
    })
    |> repo.update(prefix: ctx.prefix)
  end

  defp fetch_global_seq(changes) do
    %Event{global_seq: global_seq} = Map.fetch!(changes, :insert_event)
    global_seq
  end

  # ---------------------------------------------------------------------
  # REQ-518 PR 2c-ii -- the scope of a scoped caller's write (design
  # lib/letflow/design/req518-compiler-scope-filter.md 5.3, SEC C-3)
  # ---------------------------------------------------------------------

  # The optional attr `:scope` is the caller's allowed node set. Absent or `:all` (every system
  # caller and every tenant-wide caller) adds nothing: no read, no Multi step. A scoped set gates
  # the TYPE (a type not declared by a column is refused, R-6), then the old and the new value
  # of the declared column must be in the set. Refusal is `{:error, :scope_refused}`; the new
  # value is also checked BEFORE the transaction, so a replayed idempotency key never returns
  # a stored record to a caller whose value is out of scope (C-3).
  @typep scope_ctx :: %{
           scope: QueryTypes.scope_set(),
           scope_declaration: ScopeDeclaration.declaration() | :unscoped
         }

  @spec resolve_scope(map(), String.t(), String.t()) ::
          {:ok, scope_ctx()} | {:error, :scope_refused}
  defp resolve_scope(attrs, entity_type, prefix) do
    scope = attrs |> Map.get(:scope, :all) |> validate_scope!()

    case ScopedWrites.type_gate(entity_type, scope, prefix) do
      {:ok, declaration} -> {:ok, %{scope: scope, scope_declaration: declaration}}
      :refused -> {:error, :scope_refused}
    end
  end

  defp validate_scope!(:all), do: :all
  defp validate_scope!(:none), do: :none
  defp validate_scope!({:nodes, []}), do: :none

  defp validate_scope!({:nodes, ids} = scope) when is_list(ids) do
    if Enum.all?(ids, &is_binary/1), do: scope, else: raise_bad_scope()
  end

  defp validate_scope!(_other), do: raise_bad_scope()

  defp raise_bad_scope,
    do: raise(ArgumentError, "scope must be :all, :none or {:nodes, [binary]}")

  # The same pure membership rule applies to the stored (old) and the written (new) document:
  # the declared column's value must be a string in the caller's set.
  defp scope_value_in_set(%{scope: scope, scope_declaration: declaration}, field_values),
    do: scope_verdict(ScopedWrites.check_new_value(field_values, declaration, scope))

  defp scope_new_value(scope_ctx, field_values), do: scope_value_in_set(scope_ctx, field_values)

  # BUG-1: the references of the new document resolve through the REFERENCED type's scope.
  defp scope_new_references(%{scope: scope}, definition, field_values, prefix),
    do: scope_verdict(ScopedWrites.check_references(definition, field_values, scope, prefix))

  defp scope_old_value(scope_ctx, %Latest{field_values: stored}),
    do: scope_value_in_set(scope_ctx, stored)

  defp scope_verdict(:ok), do: :ok
  defp scope_verdict(:refused), do: {:error, :scope_refused}

  defp maybe_scope_check(multi, %{scope: :all}), do: multi

  defp maybe_scope_check(multi, %{scope: _scoped} = ctx) do
    Multi.run(multi, :scope_check, fn repo, changes -> scope_check(repo, changes, ctx) end)
  end

  # Under the type's sequence lock and after the idempotency step. The OLD value is the row
  # locked FOR UPDATE (the row `check_record_version` already locked, when it ran); the NEW value
  # is the validated document. A create has no old value, a delete no new one. An absent row is
  # refused.
  defp scope_check(repo, changes, ctx) do
    with :ok <- scope_check_old(repo, changes, ctx),
         :ok <- scope_check_new(ctx) do
      {:ok, :in_scope}
    end
  end

  defp scope_check_old(_repo, _changes, %{kind: :create}), do: :ok

  defp scope_check_old(repo, changes, ctx) do
    locked =
      Map.get(changes, :check_record_version) ||
        Latest.get_for_update(repo, ctx.record_id, ctx.entity_type, ctx.prefix)

    case locked do
      %Latest{} = row -> scope_old_value(ctx, row)
      nil -> {:error, :scope_refused}
    end
  end

  defp scope_check_new(%{kind: :delete}), do: :ok

  defp scope_check_new(ctx) do
    with :ok <- scope_new_value(ctx, ctx.field_values) do
      scope_new_references(ctx, ctx.definition, ctx.field_values, ctx.prefix)
    end
  end

  # ---------------------------------------------------------------------
  # GH #2528 -- optimistic concurrency (design
  # lib/letflow/design/gh2528-record-version-conflict.md §3)
  # ---------------------------------------------------------------------

  # Called at the entry of update_record/2 and delete_record/2, before any
  # lookup (in particular before delete_record/2's already-deleted early
  # return), so a bad internal value raises on a live and a deleted record
  # alike. The router validates before calling; the HTTP path never raises.
  defp expected_seq(attrs) do
    case Map.get(attrs, :expected_last_event_global_seq) do
      nil ->
        nil

      seq when is_integer(seq) and seq >= 0 ->
        seq

      other ->
        raise ArgumentError,
              "expected_last_event_global_seq must be nil or a non-negative integer, " <>
                "got: #{inspect(other)}"
    end
  end

  # D2: nil adds no step at all (same idiom as
  # EventStore.maybe_store_oversized_payload/2), so every existing caller gets
  # an identical Multi. D3: otherwise the step is appended after every
  # append_multi/3 step (under the sequence lock, after :idempotency) and
  # before :upsert_record_latest.
  @spec maybe_check_record_version(Ecto.Multi.t(), ctx :: map()) :: Ecto.Multi.t()
  defp maybe_check_record_version(multi, %{expected_last_event_global_seq: nil}), do: multi

  defp maybe_check_record_version(multi, ctx) do
    Multi.run(multi, :check_record_version, fn repo, changes ->
      check_record_version(repo, changes, ctx)
    end)
  end

  # D4: re-reads the row FOR UPDATE; never compares against
  # ctx.existing_record, which was read before the transaction and may be
  # stale under a race (READ COMMITTED: only a statement run after the lock
  # sees the winner's commit). D6: an absent row here can only be a
  # concurrent projection rebuild -- the pre-read already proved the record
  # exists in this tenant -- so it is a conflict too.
  @spec check_record_version(Ecto.Repo.t(), changes :: map(), ctx :: map()) ::
          {:ok, Latest.t()} | {:error, :record_version_conflict}
  defp check_record_version(repo, _changes, ctx) do
    expected = ctx.expected_last_event_global_seq

    case Latest.get_for_update(repo, ctx.record_id, ctx.entity_type, ctx.prefix) do
      %Latest{last_event_global_seq: ^expected} = locked -> {:ok, locked}
      _stale_or_absent -> {:error, :record_version_conflict}
    end
  end

  # ---------------------------------------------------------------------
  # REQ-297 §8 -- the NEW, separate :dual_write_promoted_columns Multi step
  # (see this module's moduledoc for why it is separate, not an amendment
  # to upsert_record_latest/3's own two clauses).
  # ---------------------------------------------------------------------

  @spec dual_write_promoted_columns(repo :: Ecto.Repo.t(), changes :: map(), ctx :: map()) ::
          {:ok, :skipped | :written} | {:error, term()}
  defp dual_write_promoted_columns(_repo, changes, ctx) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(ctx.prefix) do
      case TenantProvisioning.column_promotions_for_table_write(tenant_id, ctx.entity_type) do
        [] -> {:ok, :skipped}
        promotions -> write_entity_table_row(promotions, changes, ctx)
      end
    end
  end

  # The per-entity-type table is guaranteed to exist already (a
  # ColumnPromotion row past "pending" implies ensure_entity_table/2 already
  # ran for it) -- issues one INSERT ... ON CONFLICT (record_id) DO UPDATE,
  # populating every column named by a `promotions` ColumnPromotion row
  # (status in ["ddl_applied", "backfilling", "backfilled", "active"] --
  # ISS-0649: "active" is included deliberately, see
  # `column_promotions_for_table_write/2`'s moduledoc) from ctx.field_values
  # plus the same structural columns upsert_record_latest/3 itself already
  # writes to entity_record_latest. `field_values` is written into the
  # per-entity-type table's own jsonb column unconditionally (0024 §3 step
  # 1) -- independent of any single attribute's own dual-write flag, and
  # regardless of whether the promotion has reached "active".
  defp write_entity_table_row(promotions, changes, ctx) do
    with {:ok, table_name} <- TenantProvisioning.table_name_for_entity_type(ctx.entity_type) do
      unless DDL.valid_identifier?(table_name) do
        raise ArgumentError, "invalid per-entity-type table_name: #{inspect(table_name)}"
      end

      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      global_seq = fetch_global_seq(changes)
      deleted = ctx.kind == :delete

      promoted_pairs = Enum.map(promotions, &promoted_column_pair(&1, ctx.field_values))

      structural_columns = [
        "id",
        "record_id",
        "field_values",
        "deleted",
        "entity_def_version",
        "last_event_global_seq",
        "inserted_at",
        "updated_at"
      ]

      structural_values = [
        Ecto.UUID.generate(),
        ctx.record_id,
        Jason.encode!(ctx.field_values),
        deleted,
        ctx.definition.logical_shape_version,
        global_seq,
        now,
        now
      ]

      all_columns = structural_columns ++ Enum.map(promoted_pairs, &elem(&1, 0))
      all_values = structural_values ++ Enum.map(promoted_pairs, &elem(&1, 1))

      uuid_columns =
        promotions
        |> Enum.filter(&(&1.pg_type == "uuid"))
        |> Enum.map(& &1.column_name)
        |> MapSet.new()

      sql = build_upsert_sql(ctx.prefix, table_name, all_columns, uuid_columns)

      case Repo.query(sql, all_values, prefix: ctx.prefix) do
        {:ok, _result} ->
          {:ok, :written}

        {:error,
         %Postgrex.Error{postgres: %{code: :unique_violation, constraint: constraint_name}}} ->
          {:error,
           {:record_payload_invalid, unique_violation_from_constraint(ctx, constraint_name)}}

        # BUG-1 backstop: a scoped caller never sees a 500 (nor a constraint name) from a
        # foreign-key violation; the pre-checks refuse an unresolvable reference first, this
        # covers the race. A tenant-wide caller (scope `:all`, GH #2832) gets a 422 naming the
        # field with a constant message; a scoped caller keeps the generic refusal (404), because
        # a 422 for them would tell whether an id exists outside their scope.
        {:error,
         %Postgrex.Error{postgres: %{code: :foreign_key_violation, constraint: constraint_name}}} ->
          if Map.get(ctx, :scope, :all) == :all,
            do:
              {:error,
               {:record_payload_invalid,
                fk_violation_from_constraint(promotions, table_name, constraint_name)}},
            else: {:error, :scope_refused}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # GH #2832: the violation of a tenant-wide write whose promoted reference column points at a
  # record that does not exist. The column-level REFERENCES carries no explicit name, so Postgres
  # names it `<table>_<column>_fkey` (long names are shortened part by part, so the match can
  # miss); a miss with exactly one reference promotion still names that field, otherwise the
  # path is empty. The message is constant: no value, constraint or table name is echoed.
  defp fk_violation_from_constraint(promotions, table_name, constraint_name) do
    fk_promotions = Enum.filter(promotions, &(&1.references_entity != nil))

    attribute =
      case Enum.find(fk_promotions, &(constraint_name == "#{table_name}_#{&1.column_name}_fkey")) do
        %{attribute: attribute} -> attribute
        nil -> single_fk_attribute(fk_promotions)
      end

    [
      %Violation{
        rule: :reference,
        path: List.wrap(attribute),
        message: "referenced record does not exist"
      }
    ]
  end

  defp single_fk_attribute([%{attribute: attribute}]), do: attribute
  defp single_fk_attribute(_), do: nil

  # REVIEWER finding (re-verifying REQ-336 AC4 after ISS-0648): a genuine
  # duplicate-value write to a promoted-column entity table (e.g. two "tag"
  # records with the same name, now that ISS-0648 makes uq_tag_name real)
  # raised/returned a raw %Postgrex.Error{} through the bare `Repo.query/3`
  # above, which `interpret_result/1`'s catch-all clause and
  # `render_record_command/3`'s own final catch-all (entities.ex, "INV-8
  # catch-all, no detail") then turned into a bare 500 -- no field-level
  # detail the frontend could use. Translated here into the SAME
  # `{:record_payload_invalid, violations}` shape
  # `validate_field_values/2`'s inner schema check already produces, so it
  # is caught by `render_record_command/3`'s ALREADY-EXISTING 422 branch
  # (entities.ex:1214-1222) -- no router change needed.
  #
  # Reuses `Letflow.Entities.Definition.Validator.Violation` (list `path`)
  # rather than `Letflow.Entities.Record.Validator`'s own `ValidationFailure`
  # (single JSON-Pointer-string `field_path`) specifically because
  # `violation_map/1` (entities.ex:2450-2465) already renders a
  # `Violation.path` as a JSON array of field names -- the wire shape
  # `web/src/components/entities/__tests__/EntityRecordForm.errors.test.tsx`
  # expects (`path: ['name']`), not a JSON-Pointer string. `violation_map/1`'s
  # own `@spec` already declares this union
  # (`DefinitionViolation.t() | ValidationFailure.t()`), so this is not a new
  # shape the router has to learn.
  defp unique_violation_from_constraint(ctx, constraint_name) do
    case constraint_fields(ctx.definition, constraint_name) do
      [] ->
        [%Violation{rule: :unique, path: [], message: "this value has already been taken"}]

      fields ->
        [%Violation{rule: :unique, path: fields, message: unique_violation_message(fields)}]
    end
  end

  # `ctx.definition.definition_json`'s own `"constraints"` list is the single
  # source of truth for constraint_name -> fields: it is the EXACT list
  # `Letflow.Entities.Definition.DDL.unique_constraint_clauses/1` compiled
  # into the literal `CONSTRAINT "<name>" UNIQUE (<fields>)` clause that
  # created this constraint in the first place (both the fresh-CREATE-TABLE
  # path and `Letflow.TenantProvisioning.execute_add_constraint/3`'s retrofit
  # path build that clause from this same function) -- so the constraint
  # Postgres just reported by this exact name is guaranteed to have been
  # declared with exactly these fields. No string-parsing of
  # `constraint_name` itself, and generalizes to a composite constraint
  # (REQ-336/REQ-340's `question_tag`-shaped `[question_id, tag_id]` case)
  # for free -- `fields` is just whatever list this constraint_def declared.
  defp constraint_fields(%EntityDefinition{definition_json: json}, constraint_name) do
    json
    |> Map.get("constraints", [])
    |> Enum.find_value([], fn
      %{"name" => ^constraint_name, "fields" => fields} -> fields
      _ -> nil
    end)
  end

  defp unique_violation_message(fields) do
    "#{Enum.join(fields, ", ")} has already been taken"
  end

  defp promoted_column_pair(
         %ColumnPromotion{column_name: column_name, attribute: attribute, pg_type: pg_type},
         field_values
       ) do
    unless DDL.valid_identifier?(column_name) do
      raise ArgumentError, "invalid promoted column_name: #{inspect(column_name)}"
    end

    raw_value = Map.get(field_values, attribute)
    {column_name, TenantProvisioning.cast_promoted_value(raw_value, pg_type)}
  end

  defp build_upsert_sql(prefix, table_name, all_columns, uuid_columns) do
    placeholders = placeholder_list(all_columns, uuid_columns)
    column_list = Enum.map_join(all_columns, ", ", &~s("#{&1}"))
    update_columns = all_columns -- ["id", "record_id", "inserted_at"]
    update_clause = Enum.map_join(update_columns, ", ", fn c -> ~s("#{c}" = EXCLUDED."#{c}") end)

    """
    INSERT INTO "#{prefix}"."#{table_name}" (#{column_list})
    VALUES (#{Enum.join(placeholders, ", ")})
    ON CONFLICT (record_id) DO UPDATE SET #{update_clause}
    """
  end

  # `($n::text)::uuid`/`($n::text)::jsonb`, not a bare `$n::uuid`/`$n::jsonb`
  # -- the same double-cast idiom already established in
  # lib/letflow/sandbox_pool/fixture_loader.ex's apply_fixtures/3 (verified
  # there empirically): an immediately-annotated `::jsonb` cast makes
  # Postgrex infer the parameter is a native Elixir term to be JSON-encoded
  # client-side, double-encoding an already-encoded string; casting from
  # `::text` first keeps the parameter bound as plain text, with the real
  # cast happening server-side in Postgres.
  #
  # `uuid_columns` (REQ-298) is the set of promoted column names whose
  # `ColumnPromotion.pg_type` is `"uuid"` -- an FK-promoted column.
  # `TenantProvisioning.cast_promoted_value/2`'s own `"uuid"` clause keeps
  # the value in plain text form (see that function's own moduledoc for why
  # it deliberately does NOT dump to Postgrex's raw 16-byte binary form), so
  # -- exactly like `"id"`/`"record_id"` -- it needs this same
  # `($n::text)::uuid` server-side cast, not a bare `$n` placeholder (which
  # would leave the parameter's wire type inferred as `uuid` straight from
  # the target column, and Postgrex's `uuid` encoder rejects a plain
  # text-form string, demanding the raw binary instead).
  defp placeholder_list(all_columns, uuid_columns) do
    all_columns
    |> Enum.with_index(1)
    |> Enum.map(fn
      {"id", i} -> "($#{i}::text)::uuid"
      {"record_id", i} -> "($#{i}::text)::uuid"
      {"field_values", i} -> "($#{i}::text)::jsonb"
      {col, i} -> if MapSet.member?(uuid_columns, col), do: "($#{i}::text)::uuid", else: "$#{i}"
    end)
  end

  @spec interpret_result(tx_result :: term(), request_fingerprint(), prefix :: String.t()) ::
          {:ok, command_result()} | command_error()
  defp interpret_result({:ok, %{upsert_record_latest: %Latest{} = record}}, _fp, _prefix) do
    {:ok, %{record: record, is_duplicate: false}}
  end

  defp interpret_result(
         {:error, :idempotency, {:duplicate_idempotency_key, %Event{} = original_event},
          _changes},
         fingerprint,
         prefix
       ),
       do: original_result(original_event, fingerprint, prefix)

  defp interpret_result(
         {:error, :insert_event, %Ecto.Changeset{} = changeset, _changes},
         _fp,
         _prefix
       ) do
    if sequence_conflict?(changeset) do
      {:error, {:sequence_conflict, changeset}}
    else
      {:error, changeset}
    end
  end

  defp interpret_result({:error, _failed_operation, reason, _changes}, _fp, _prefix) do
    {:error, reason}
  end

  # ---------------------------------------------------------------------
  # GH #2543 -- idempotency key binding (design
  # lib/letflow/design/gh2543-idempotency-key-binding.md §2-§4)
  # ---------------------------------------------------------------------

  @command_event_types %{
    create: "ENTITY_RECORD_CREATED",
    update: "ENTITY_RECORD_UPDATED",
    delete: "ENTITY_RECORD_DELETED"
  }

  @doc """
  GH #2550 (design D3 guard (iii)), removed by GH #2578: the event types a
  record create/update route can have written under a pre-namespacing caller
  key -- the only ones `Letflow.Idempotency.legacy_original/3` may match.
  """
  @spec legacy_lookup_event_types() :: [String.t()]
  def legacy_lookup_event_types,
    do: [@command_event_types.create, @command_event_types.update]

  # Read at create_record/2's entry, before any lookup, so a bad internal
  # value raises on every path (same posture as expected_seq/1).
  @spec idempotency_match(map()) :: idempotency_match()
  defp idempotency_match(attrs) do
    case Map.get(attrs, :idempotency_match, :request) do
      match when match in [:request, :target] ->
        match

      other ->
        raise ArgumentError,
              "idempotency_match must be :request or :target, got: #{inspect(other)}"
    end
  end

  # Built once, before the transaction. canonical_json/1 cannot raise here:
  # build_event_attrs/3 has already Jason-encoded the same field_values.
  @spec request_fingerprint(ctx :: map(), attrs :: map()) :: request_fingerprint()
  defp request_fingerprint(%{kind: kind} = ctx, attrs) do
    %{
      event_type: Map.fetch!(@command_event_types, kind),
      actor_id: attrs.actor_id,
      entity_type: ctx.entity_type,
      record_id: if(kind == :create, do: :not_compared, else: ctx.record_id),
      field_values: fingerprint_field_values(ctx)
    }
  end

  defp fingerprint_field_values(%{kind: :delete}), do: :not_compared
  defp fingerprint_field_values(%{idempotency_match: :target}), do: :not_compared
  defp fingerprint_field_values(%{field_values: field_values}), do: canonical_json(field_values)

  # §2 check order: event_type, then actor (no reads), then $ref resolution,
  # then the payload fields.
  @spec match_original(Event.t(), request_fingerprint(), prefix :: String.t()) ::
          {:ok, Event.t()}
          | {:error, :idempotency_key_reuse}
          | {:error, {:payload_resolution_failed, Ecto.UUID.t()}}
  defp match_original(%Event{} = original, fingerprint, prefix) do
    if original.event_type == fingerprint.event_type and
         same_uuid?(original.actor_id, fingerprint.actor_id) do
      with {:ok, resolved} <- resolve_original_payload(original, prefix) do
        if same_request?(resolved, fingerprint),
          do: {:ok, resolved},
          else: {:error, :idempotency_key_reuse}
      end
    else
      {:error, :idempotency_key_reuse}
    end
  end

  # D3: an oversized original carries exactly the single-key `$ref` map
  # EventStore writes (event_store.ex insert_event/3); its full payload lives
  # in event_payload_store. Mirrors Reconstruction.resolve_live_payloads/2
  # (EventStore.resolve_payloads/2 is private). Runs after the rolled-back
  # transaction; the original event is already committed.
  @spec resolve_original_payload(Event.t(), prefix :: String.t()) ::
          {:ok, Event.t()} | {:error, {:payload_resolution_failed, Ecto.UUID.t()}}
  defp resolve_original_payload(%Event{payload: %{"$ref" => ref} = payload} = event, prefix)
       when map_size(payload) == 1 and is_binary(ref) do
    StoredPayload
    |> where([sp], sp.event_id == ^ref)
    |> select([sp], sp.payload)
    |> Repo.one(prefix: prefix)
    |> case do
      %{} = full_payload -> {:ok, %Event{event | payload: full_payload}}
      nil -> {:error, {:payload_resolution_failed, ref}}
    end
  end

  defp resolve_original_payload(%Event{} = event, _prefix), do: {:ok, event}

  # §2: Map.fetch/2 on the payload, so a missing key means "not the same".
  @spec same_request?(resolved :: Event.t(), request_fingerprint()) :: boolean()
  defp same_request?(%Event{payload: payload}, fingerprint) when is_map(payload) do
    with {:ok, entity_type} <- Map.fetch(payload, "entity_type"),
         true <- entity_type == fingerprint.entity_type,
         true <- same_record_id?(payload, fingerprint.record_id),
         true <- same_field_values?(payload, fingerprint.field_values) do
      true
    else
      _ -> false
    end
  end

  defp same_request?(%Event{}, _fingerprint), do: false

  defp same_record_id?(_payload, :not_compared), do: true

  defp same_record_id?(payload, record_id) do
    case Map.fetch(payload, "record_id") do
      {:ok, stored} -> same_uuid?(stored, record_id)
      :error -> false
    end
  end

  defp same_field_values?(_payload, :not_compared), do: true

  defp same_field_values?(payload, field_values) do
    case Map.fetch(payload, "field_values") do
      {:ok, stored} -> json_equal?(stored, field_values)
      :error -> false
    end
  end

  # §3: the same transform the original write went through
  # (to_append_attrs/4's Jason.encode!, EventStore's Jason.decode!).
  @spec canonical_json(term()) :: term()
  defp canonical_json(value), do: value |> Jason.encode!() |> Jason.decode!()

  # §3: recursive JSON-value equality, never bare ==. jsonb prints an
  # exponent float as a plain decimal that Jason then decodes as an integer,
  # so an integer and a float are compared as JSON numbers. Never raises: the
  # abs/<= guard compares a bignum with a float without converting it, and
  # the conversion is only reached inside the finite double range.
  # :erlang.binary_to_float/1 rounds correctly; :erlang.float/1 truncates
  # large integers and must not be used here.
  @max_finite_double 1.7976931348623157e308

  @spec json_equal?(stored :: term(), request :: term()) :: boolean()
  defp json_equal?(stored, request) when is_map(stored) and is_map(request) do
    map_size(stored) == map_size(request) and
      Enum.all?(stored, fn {key, stored_value} ->
        case Map.fetch(request, key) do
          {:ok, request_value} -> json_equal?(stored_value, request_value)
          :error -> false
        end
      end)
  end

  defp json_equal?(stored, request) when is_list(stored) and is_list(request) do
    length(stored) == length(request) and
      stored |> Enum.zip(request) |> Enum.all?(fn {s, r} -> json_equal?(s, r) end)
  end

  defp json_equal?(stored, request) when is_integer(stored) and is_float(request),
    do: int_float_equal?(stored, request)

  defp json_equal?(stored, request) when is_float(stored) and is_integer(request),
    do: int_float_equal?(request, stored)

  # Integer/integer, float/float, and everything else (strings, booleans,
  # nil, mismatched types -- "1" never matches 1): plain ==.
  defp json_equal?(stored, request), do: stored == request

  defp int_float_equal?(int, float) do
    int == float or
      (abs(int) <= @max_finite_double and
         :erlang.binary_to_float(Integer.to_string(int) <> ".0") == float)
  end

  # Both sides through Ecto.UUID.cast/1 (lowercase canonical); a cast error
  # on either side means "not the same".
  @spec same_uuid?(term(), term()) :: boolean()
  defp same_uuid?(a, b) do
    case {Ecto.UUID.cast(a), Ecto.UUID.cast(b)} do
      {{:ok, same}, {:ok, same}} -> true
      _ -> false
    end
  end

  # Design §5.4/§5.1 step 6 -- the original-record lookup happens by
  # decoding the ORIGINAL EVENT's own stored `payload`, not by a fresh
  # `entity_record_latest` SELECT. Mirrors `Letflow.EventStore.Event.payload`
  # already being a decoded `:map` (no re-parse of a JSON string). GH #2543:
  # it only ever receives an original that match_original/3 resolved and
  # matched, so a `$ref` or non-entity payload never reaches it.
  defp duplicate_result(%Event{payload: payload, event_type: event_type, global_seq: global_seq}) do
    entity_def_version_hex = Map.fetch!(payload, "entity_def_version")
    # GH #2794: the original's ref as ONE value (`ref_from_event/1`), spelled into the two
    # columns only by `ExternalRef.to_columns/1`, so the rebuilt `%Latest{}` can never carry a
    # half-set pair. The duplicate path (`upsert_create/1`) then compares it with
    # `Latest.external_ref/1`.
    columns = payload |> ref_from_event() |> ExternalRef.to_columns()

    %{
      record: %Latest{
        entity_type: Map.fetch!(payload, "entity_type"),
        record_id: Map.fetch!(payload, "record_id"),
        field_values: Map.get(payload, "field_values", %{}),
        deleted: event_type == "ENTITY_RECORD_DELETED",
        entity_def_version: Base.decode16!(entity_def_version_hex, case: :lower),
        last_event_global_seq: global_seq,
        # GH #2659: the ref the ORIGINAL create carried (nil for an update, delete or ref-less
        # original), so `upsert_create/1` can tell whose record a replayed key belongs to.
        external_system: columns.external_system,
        external_id: columns.external_id
      },
      is_duplicate: true
    }
  end

  # GH #2659: true when the changeset carries the unique violation of the partial external-ref
  # index. The changeset holds the offending ref value, so it is only ever mapped to a constant
  # outcome (retry, then `:external_ref_contention`), never returned or logged.
  defp external_ref_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :unique and
        Keyword.get(opts, :constraint_name) == "entity_record_latest_external_ref_idx"
    end)
  end

  defp sequence_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :unique and
        Keyword.get(opts, :constraint_name) == "uq_event_sequence"
    end)
  end

  # ---------------------------------------------------------------------
  # Definition/record resolution (design §5.1 step 1-2, §5.2)
  # ---------------------------------------------------------------------

  # ISS-0519 fix (B), lib/letflow/design/iss0519-entity-definition-versioning-fix.md
  # §4.2: routed through Definitions.get_active_definition_by_name/2 (which
  # itself resolves via REQ-203's authoritative Activation.resolve/3 pointer)
  # instead of the previous unfiltered get_definition_by_name/2 + post-hoc
  # %EntityDefinition{status: :active} pattern match -- that unfiltered query
  # could raise Ecto.MultipleResultsError before the pattern match was ever
  # reached once 2+ rows shared entity_type (the ISS-0519 crash). The "found
  # but not active" arm is unreachable in the new contract and is removed,
  # not kept dead.
  defp fetch_active_definition(entity_type, prefix) do
    case Definitions.get_active_definition_by_name(entity_type, prefix) do
      {:ok, %EntityDefinition{} = definition} ->
        {:ok, definition}

      {:error, :not_found} ->
        {:error, {:definition_not_found, entity_type}}

      {:error, :invalid_schema_name} = error ->
        error
    end
  end

  # GH #2583 design §4.3: the single ownership check every write runs right after
  # the definition is resolved and before anything else; zero extra queries (it
  # reads the stamp of the row `fetch_active_definition/2` already loaded).
  # REQ-499's `command_multi/3` must reuse it per line (design §8.2).
  @spec check_write_authority(
          EntityDefinition.t(),
          entity_type :: String.t(),
          ManagedTypes.owner()
        ) ::
          :ok | {:error, :entity_type_managed}
  defp check_write_authority(%EntityDefinition{managed_by: managed_by}, entity_type, authority),
    do: ManagedTypes.check_record_write(managed_by, entity_type, authority)

  defp fetch_existing_record(record_id, entity_type, prefix) do
    case Latest.get(record_id, entity_type, prefix) do
      {:ok, record} -> {:ok, record}
      {:error, :not_found} -> {:error, {:record_not_found, record_id}}
      {:error, :invalid_schema_name} = error -> error
    end
  end

  # GH #2529: reads the CURRENT active definition's string-keyed JSONB; only a
  # literal `true` locks the type (the definition validator guarantees a stored
  # value is a boolean).
  @spec ensure_mutable(EntityDefinition.t(), String.t()) ::
          :ok | {:error, {:entity_append_only, String.t()}}
  defp ensure_mutable(%EntityDefinition{definition_json: json}, entity_type) do
    if Map.get(json, "append_only") == true do
      {:error, {:entity_append_only, entity_type}}
    else
      :ok
    end
  end

  defp ensure_not_deleted(%Latest{deleted: true}, record_id),
    do: {:error, {:record_already_deleted, record_id}}

  defp ensure_not_deleted(%Latest{}, _record_id), do: :ok

  # GH #2654: returns the NORMALISED field_values (strict decimals as canonical
  # scale-padded strings); every caller must store/append/fingerprint that map,
  # not its input. A definition with no strict decimal field returns the input
  # unchanged.
  defp validate_field_values(%EntityDefinition{} = definition, field_values) do
    case Validator.normalize_record_payload(definition_document(definition), field_values) do
      {:ok, normalised} -> {:ok, normalised}
      {:error, violations} -> {:error, {:record_payload_invalid, violations}}
    end
  end

  defp hex_version(%EntityDefinition{logical_shape_version: version}) do
    Base.encode16(version, case: :lower)
  end

  # See this module's moduledoc ("entity_def_version's atom/string key
  # round-trip") for why this conversion exists.
  defp definition_document(%EntityDefinition{definition_json: json}) do
    %{
      name: Map.fetch!(json, "name"),
      display_name: Map.get(json, "display_name"),
      fields: json |> Map.get("fields", []) |> Enum.map(&field_document/1)
    }
  end

  # ISS-0624 / GH#1311 fix: this conversion only carried `name`/`type`/
  # `required`/`enum_values`, silently dropping every other optional
  # `Letflow.Entities.Definition.field_def()` key (`queried`,
  # `decimal_precision`, `decimal_scale`, `locales`, `search_strategy`) when
  # rebuilding the field map from the persisted, string-keyed
  # `definition_json`. `locales` is the one that crashed: a `:localized_text`
  # field reaches `Record.Validator.field_subschema/1`'s
  # `%{type: :localized_text, locales: locales}` clause (added by ISS-0617)
  # with no `locales` key at all, so the clause set has no match and
  # `create_record/2` raises `FunctionClauseError` on every write -- the same
  # INV-8 crash-on-realistic-input defect ISS-0617 fixed in
  # `field_subschema/1` itself, just reached via this converter never
  # supplying what that clause needs. `search_strategy` is added alongside it
  # per the same audit, even though no `field_subschema/1` clause currently
  # reads it, to keep this document a faithful `field_def()` reconstruction
  # rather than leaving another silent gap for the next clause that needs it
  # (`decimal_precision`/`decimal_scale` similarly: `field_subschema/1`'s
  # `:decimal` clause matches on `type` alone today and does not need them,
  # but they are real `field_def()` keys this converter was dropping).
  # `default` is the one `field_def()` key deliberately left out: no consumer
  # in this codebase reads it yet, matching the same omission in this
  # function's own siblings below. This mirrors
  # `Letflow.Entities.Query.Allowlist`'s and `Letflow.TenantProvisioning`'s
  # own `field_document/1`/`field_from_persisted/1` conversions, which
  # already carry `locales`/`search_strategy` correctly -- this was the one
  # sibling left behind.
  #
  # GH #2532: `min`, `max` and `non_negative` are carried too -- dropping
  # any of them here would silently disable that bound on every record
  # write (the same ISS-0624 key-drop shape). They are put only when present
  # in the stored JSON (so a key-less definition rebuilds exactly as before)
  # and copied verbatim: no atom conversion, no arithmetic.
  # `Record.Validator` ignores a non-number bound, so a corrupt stored value
  # can never crash a write (INV-8). `Query.Allowlist` and
  # `TenantProvisioning` deliberately do not carry them: neither reads a
  # bound (see lib/letflow/design/gh2532-field-min-max-non-negative.md §2.5).
  defp field_document(field) do
    %{
      name: Map.fetch!(field, "name"),
      type: String.to_existing_atom(Map.fetch!(field, "type")),
      required: Map.get(field, "required", false),
      queried: Map.get(field, "queried", false),
      enum_values: Map.get(field, "enum_values"),
      decimal_precision: Map.get(field, "decimal_precision"),
      decimal_scale: Map.get(field, "decimal_scale"),
      # GH #2654: nil and false are the same downstream (only `true` is strict).
      decimal_strict: Map.get(field, "decimal_strict"),
      locales: Map.get(field, "locales"),
      search_strategy: field |> Map.get("search_strategy") |> search_strategy_atom()
    }
    |> put_present(:min, field, "min")
    |> put_present(:max, field, "max")
    |> put_present(:non_negative, field, "non_negative")
  end

  @spec put_present(map(), atom(), map(), String.t()) :: map()
  defp put_present(document, atom_key, field, string_key) do
    if Map.has_key?(field, string_key),
      do: Map.put(document, atom_key, Map.fetch!(field, string_key)),
      else: document
  end

  # Same decode posture as `type`'s `String.to_existing_atom/1` above: both
  # `:plain` and `:fulltext` are already compiled into this codebase
  # (`Definition.Validator` Rule 11, `Definition.Ddl`'s own dispatch), so
  # this is safe.
  defp search_strategy_atom(nil), do: nil
  defp search_strategy_atom(value) when is_binary(value), do: String.to_existing_atom(value)

  # Absent or invalid original ref gives nil: the writer validated it at write time and the
  # projector owns corrupt-stream detection, so a duplicate lookup never fails on it.
  defp ref_from_event(payload) do
    case ExternalRef.from_payload(Map.get(payload, "external_ref")) do
      {:ok, ref} -> ref
      {:error, _} -> nil
    end
  end
end
