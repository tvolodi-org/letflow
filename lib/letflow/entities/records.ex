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
  own M1-M6 steps, followed by this module's own `:upsert_record_latest`
  step (design §5.1 steps 4-5).

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
  """

  alias Ecto.Multi
  alias Letflow.Entities.Definition.DDL
  alias Letflow.Entities.Definition.Validator.Violation
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Record.Validator
  alias Letflow.EventStore
  alias Letflow.EventStore.Event
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion

  @type create_attrs :: %{
          required(:entity_type) => String.t(),
          required(:field_values) => Validator.field_values(),
          required(:actor_id) => Ecto.UUID.t(),
          required(:idempotency_key) => String.t()
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
          optional(:expected_last_event_global_seq) => expected_seq()
        }

  @type delete_attrs :: %{
          required(:entity_type) => String.t(),
          required(:record_id) => Ecto.UUID.t(),
          required(:actor_id) => Ecto.UUID.t(),
          required(:idempotency_key) => String.t(),
          optional(:expected_last_event_global_seq) => expected_seq()
        }

  @type command_result :: %{record: Latest.t(), is_duplicate: boolean()}

  @type command_error ::
          {:error, {:definition_not_found, entity_type :: String.t()}}
          | {:error, {:record_payload_invalid, Validator.violations() | [Violation.t()]}}
          | {:error, {:record_not_found, record_id :: Ecto.UUID.t()}}
          | {:error, {:record_already_deleted, record_id :: Ecto.UUID.t()}}
          | {:error, :record_version_conflict}
          | {:error, :tenant_not_provisioned}
          | {:error, :invalid_schema_name}
          | {:error, {:payload_validation_failed, [term()]}}
          | {:error, term()}

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
    6. A duplicate `idempotency_key` returns the **original** record (AC3),
       decoded from the original event's own stored payload.
  """
  @spec create_record(create_attrs(), prefix :: String.t()) ::
          {:ok, command_result()} | command_error()
  def create_record(%{entity_type: entity_type, field_values: field_values} = attrs, prefix)
      when is_binary(prefix) do
    with {:ok, definition} <- fetch_active_definition(entity_type, prefix),
         :ok <- validate_field_values(definition, field_values) do
      record_id = Ecto.UUID.generate()

      ctx = %{
        kind: :create,
        entity_type: entity_type,
        record_id: record_id,
        field_values: field_values,
        definition: definition,
        existing_record: nil,
        expected_last_event_global_seq: nil,
        prefix: prefix
      }

      run_command(ctx, attrs)
    end
  end

  @doc """
  Updates an existing entity record with a **full replacement** `field_values`
  (whole-document semantics, design §5.2) -- same step order as
  `create_record/2`, plus: the target record must already exist
  (`{:error, {:record_not_found, record_id}}` otherwise) and must not already
  be deleted (`{:error, {:record_already_deleted, record_id}}` otherwise).
  Validates against `entity_type`'s **current** active definition, which may
  differ from the definition version the record was originally created
  under (design §5.2, an explicit non-goal to reconcile).

  GH #2528: an optional `:expected_last_event_global_seq` makes the write
  conditional. Inside the transaction, after the per-type sequence lock and
  the idempotency check (so an identical replay still returns the original as
  `is_duplicate: true`), the row is re-read `FOR UPDATE`; a mismatch (or a row
  that vanished) returns `{:error, :record_version_conflict}` and rolls back
  the whole command, idempotency claim included. Absent/`nil` adds no step at
  all. A non-nil value that is not a non-negative integer raises
  `ArgumentError` (programmer error from an internal caller).
  """
  @spec update_record(update_attrs(), prefix :: String.t()) ::
          {:ok, command_result()} | command_error()
  def update_record(
        %{entity_type: entity_type, record_id: record_id, field_values: field_values} = attrs,
        prefix
      )
      when is_binary(prefix) do
    expected = expected_seq(attrs)

    with {:ok, definition} <- fetch_active_definition(entity_type, prefix),
         {:ok, existing_record} <- fetch_existing_record(record_id, entity_type, prefix),
         :ok <- ensure_not_deleted(existing_record, record_id),
         :ok <- validate_field_values(definition, field_values) do
      ctx = %{
        kind: :update,
        entity_type: entity_type,
        record_id: record_id,
        field_values: field_values,
        definition: definition,
        existing_record: existing_record,
        expected_last_event_global_seq: expected,
        prefix: prefix
      }

      run_command(ctx, attrs)
    end
  end

  @doc """
  Deletes an entity record (design §5.2): appends one `ENTITY_RECORD_DELETED`
  event and marks the `entity_record_latest` row `deleted: true`,
  `field_values` retained unchanged at its last pre-delete value. Deleting an
  already-deleted record is a **no-op success** returning the existing
  (already-deleted) row with `is_duplicate: false` -- deletion is naturally
  idempotent at the domain level, independent of the idempotency-key
  mechanism.

  GH #2528: the optional `:expected_last_event_global_seq` works as in
  `update_record/2` for a live record. An already-deleted record keeps the
  no-op success above regardless of the expected value (no check, no event).
  """
  @spec delete_record(delete_attrs(), prefix :: String.t()) ::
          {:ok, command_result()} | command_error()
  def delete_record(%{entity_type: entity_type, record_id: record_id} = attrs, prefix)
      when is_binary(prefix) do
    expected = expected_seq(attrs)

    with {:ok, definition} <- fetch_active_definition(entity_type, prefix),
         {:ok, existing_record} <- fetch_existing_record(record_id, entity_type, prefix) do
      if existing_record.deleted do
        {:ok, %{record: existing_record, is_duplicate: false}}
      else
        ctx = %{
          kind: :delete,
          entity_type: entity_type,
          record_id: record_id,
          field_values: existing_record.field_values,
          definition: definition,
          existing_record: existing_record,
          expected_last_event_global_seq: expected,
          prefix: prefix
        }

        run_command(ctx, attrs)
      end
    end
  end

  # ---------------------------------------------------------------------
  # Shared pipeline (design §5.1 steps 4-7)
  # ---------------------------------------------------------------------

  defp run_command(%{entity_type: entity_type, prefix: prefix} = ctx, attrs) do
    with {:ok, synthetic_instance_id} <- EntityTypeInstance.get_or_create(entity_type, prefix) do
      event_attrs = build_event_attrs(ctx, attrs, synthetic_instance_id)

      case EventStore.append_multi(Multi.new(), event_attrs, prefix: prefix) do
        {:ok, multi} ->
          multi
          |> maybe_check_record_version(ctx)
          |> Multi.run(:upsert_record_latest, fn repo, changes ->
            upsert_record_latest(repo, changes, ctx)
          end)
          |> Multi.run(:dual_write_promoted_columns, fn repo, changes ->
            dual_write_promoted_columns(repo, changes, ctx)
          end)
          |> Repo.transaction()
          |> interpret_result()

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp build_event_attrs(%{kind: :create} = ctx, attrs, instance_id) do
    payload = base_payload(ctx) |> Map.put("field_values", ctx.field_values)
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
    |> Latest.insert_changeset(%{
      entity_type: ctx.entity_type,
      record_id: ctx.record_id,
      field_values: ctx.field_values,
      entity_def_version: ctx.definition.logical_shape_version,
      last_event_global_seq: fetch_global_seq(changes)
    })
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

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

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

  defp interpret_result({:ok, %{upsert_record_latest: %Latest{} = record}}) do
    {:ok, %{record: record, is_duplicate: false}}
  end

  defp interpret_result(
         {:error, :idempotency, {:duplicate_idempotency_key, %Event{} = original_event}, _changes}
       ) do
    {:ok, duplicate_result(original_event)}
  end

  defp interpret_result({:error, :insert_event, %Ecto.Changeset{} = changeset, _changes}) do
    if sequence_conflict?(changeset) do
      {:error, {:sequence_conflict, changeset}}
    else
      {:error, changeset}
    end
  end

  defp interpret_result({:error, _failed_operation, reason, _changes}) do
    {:error, reason}
  end

  # Design §5.4/§5.1 step 6 -- the original-record lookup happens by
  # decoding the ORIGINAL EVENT's own stored `payload`, not by a fresh
  # `entity_record_latest` SELECT. Mirrors `Letflow.EventStore.Event.payload`
  # already being a decoded `:map` (no re-parse of a JSON string).
  defp duplicate_result(%Event{payload: payload, event_type: event_type, global_seq: global_seq}) do
    entity_def_version_hex = Map.fetch!(payload, "entity_def_version")

    %{
      record: %Latest{
        entity_type: Map.fetch!(payload, "entity_type"),
        record_id: Map.fetch!(payload, "record_id"),
        field_values: Map.get(payload, "field_values", %{}),
        deleted: event_type == "ENTITY_RECORD_DELETED",
        entity_def_version: Base.decode16!(entity_def_version_hex, case: :lower),
        last_event_global_seq: global_seq
      },
      is_duplicate: true
    }
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

  defp fetch_existing_record(record_id, entity_type, prefix) do
    case Latest.get(record_id, entity_type, prefix) do
      {:ok, record} -> {:ok, record}
      {:error, :not_found} -> {:error, {:record_not_found, record_id}}
      {:error, :invalid_schema_name} = error -> error
    end
  end

  defp ensure_not_deleted(%Latest{deleted: true}, record_id),
    do: {:error, {:record_already_deleted, record_id}}

  defp ensure_not_deleted(%Latest{}, _record_id), do: :ok

  defp validate_field_values(%EntityDefinition{} = definition, field_values) do
    case Validator.validate_record_payload(definition_document(definition), field_values) do
      [] -> :ok
      violations -> {:error, {:record_payload_invalid, violations}}
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
  defp field_document(field) do
    %{
      name: Map.fetch!(field, "name"),
      type: String.to_existing_atom(Map.fetch!(field, "type")),
      required: Map.get(field, "required", false),
      queried: Map.get(field, "queried", false),
      enum_values: Map.get(field, "enum_values"),
      decimal_precision: Map.get(field, "decimal_precision"),
      decimal_scale: Map.get(field, "decimal_scale"),
      locales: Map.get(field, "locales"),
      search_strategy: field |> Map.get("search_strategy") |> search_strategy_atom()
    }
  end

  # Same decode posture as `type`'s `String.to_existing_atom/1` above: both
  # `:plain` and `:fulltext` are already compiled into this codebase
  # (`Definition.Validator` Rule 11, `Definition.Ddl`'s own dispatch), so
  # this is safe.
  defp search_strategy_atom(nil), do: nil
  defp search_strategy_atom(value) when is_binary(value), do: String.to_existing_atom(value)
end
