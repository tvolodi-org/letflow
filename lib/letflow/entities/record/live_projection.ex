defmodule Letflow.Entities.Record.LiveProjection do
  @moduledoc """
  The live record projection steps (`entity_record_latest` and the promoted-column per-type table),
  moved out of `Letflow.Entities.Records` (REQ-683, decision 0055 D3) so the record command pipeline
  and the module-upgrade writer (`Letflow.ModuleUpgrade.Writer`) run the same code.

  Both functions are `Ecto.Multi.run/3` steps: `(repo, changes, ctx)`. `changes.insert_event` is the
  appended event (its `global_seq` becomes `last_event_global_seq`); an optional
  `changes.check_record_version` is the row locked by the optimistic-concurrency step. `ctx` carries
  `kind`, `entity_type`, `record_id`, `field_values`, `prefix`, `existing_record`, `external_ref`
  and `entity_def_version` (the raw version binary: the definition's for a record command, the
  row's own for a migration). `ctx.definition` is optional and only used to name a unique
  constraint in an error.
  """

  alias Letflow.Entities.Definition.DDL
  alias Letflow.Entities.Definition.Validator.Violation
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore.Event
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion

  @doc false
  def upsert_record_latest(repo, changes, %{kind: :create} = ctx) do
    %Latest{}
    |> Latest.insert_changeset(
      Map.merge(
        %{
          entity_type: ctx.entity_type,
          record_id: ctx.record_id,
          field_values: ctx.field_values,
          entity_def_version: ctx.entity_def_version,
          last_event_global_seq: fetch_global_seq(changes)
        },
        %{external_ref: ctx.external_ref}
      )
    )
    |> repo.insert(prefix: ctx.prefix)
    |> put_record_number(changes)
  end

  # GH #2528 design D5: when :check_record_version ran, the changeset is based
  # on the row it locked (so Ecto's UPDATE diff is computed against the
  # current row by construction); otherwise on the pre-transaction read, as
  # before (D2: the nil path is unchanged).
  def upsert_record_latest(repo, changes, %{kind: kind} = ctx) when kind in [:update, :delete] do
    changes
    |> Map.get(:check_record_version, ctx.existing_record)
    |> Latest.update_changeset(%{
      field_values: ctx.field_values,
      deleted: kind == :delete,
      entity_def_version: ctx.entity_def_version,
      last_event_global_seq: fetch_global_seq(changes)
    })
    |> repo.update(prefix: ctx.prefix)
  end

  defp put_record_number({:ok, %Latest{} = row}, changes) do
    case changes do
      %{allocate_number: %{formatted: formatted}} -> {:ok, %{row | record_number: formatted}}
      _no_number -> {:ok, row}
    end
  end

  defp put_record_number(other, _changes), do: other

  defp fetch_global_seq(changes) do
    %Event{global_seq: global_seq} = Map.fetch!(changes, :insert_event)
    global_seq
  end

  # ---------------------------------------------------------------------
  # REQ-297 §8 -- the NEW, separate :dual_write_promoted_columns Multi step
  # (see this module's moduledoc for why it is separate, not an amendment
  # to upsert_record_latest/3's own two clauses).
  # ---------------------------------------------------------------------

  @doc false
  @spec dual_write_promoted_columns(repo :: Ecto.Repo.t(), changes :: map(), ctx :: map()) ::
          {:ok, :skipped | :written} | {:error, term()}
  def dual_write_promoted_columns(_repo, changes, ctx) do
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
        ctx.entity_def_version,
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
    case constraint_fields(Map.get(ctx, :definition), constraint_name) do
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
  defp constraint_fields(nil, _constraint_name), do: []

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
end
