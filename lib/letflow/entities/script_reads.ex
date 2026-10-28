defmodule Letflow.Entities.ScriptReads do
  @moduledoc """
  GH 2534 PR 7c-2 (decision 0053 D5; 7b-2a section 8, SEC F1/N1): the entity-record
  read half of `Letflow.Engine.EntityPort` (`prefetch/3`), reached through the delegating
  adapter `Letflow.Entities.EntityPortImpl` (`config :letflow, :entity_port`). Design
  `lib/letflow/design/gh2534-7c-script-handler.md` section 11.2.

  ## Phase 1 (every read, before ANY record query)

    0. The type is STILL flagged readable (`script_readable_masters`, read fresh): the port
       re-checks the flag itself, closing the window between the dispatcher's
       `check_reads` and this call (7b-2a P5 / residual R1) and protecting any caller that
       skips `check_reads`. The table is read schemalessly by name: this module does not call
       into the scripts context (no entities -> scripts code edge).
    1. The type has an ACTIVE definition and no `entity_type_restrictions` row; every `fields`
       name and the `match.field` is a field of that definition; `restricted_fields` (the
       opt-in, decision 0062 R6) is a list of names of the `fields`.
    2. `R` = the type's CURRENT restricted field names (`entity_field_restrictions`), with NO
       per-user grant anti-join: the script principal has no user and holds no grants (D5).
    3. SEC N1: a `match.field` in `R` is refused. The equality filter can never act as an
       oracle on a restricted field.
    4. The record query is built (not run). A field match goes through
       `Letflow.Entities.Query.Compiler.compile/2` (allowlist, bound parameters); a compile
       error is a type/field-level refusal.

  Any failure is `{:error, :reads_not_allowed}` and no record has been read.

  ## Phase 2 (exactly ONE record query per read, INV-5)

    * `id_from`: one `entity_record_latest` lookup by `(entity_type, record_id)` with
      `deleted = false`, at most one row. A nil or non-UUID value is replaced by the nil UUID
      (never generated as a record id), so a malformed or unknown id costs the same one query
      as a miss or a hit.
    * `field`/`value_from`: the compiled equality query plus `deleted = false`, ordered by
      `record_id`, `LIMIT min(limit, 50)`. A value of the wrong JSON type for the field (nil, a
      list, a map, a string for an integer field, an unparsable date) issues the SAME query with
      a constant-false predicate. A datetime value must be ISO-8601 WITH an offset; it is
      converted to UTC (stored values are compared as UTC timestamps).
    * A record query that the database refuses (a STORED value that does not fit the SQL cast
      of its field, e.g. a value written under an earlier definition version) is caught, nothing
      is logged, and the whole prefetch is refused `{:error, :reads_not_allowed}`: the run ends
      `script_rejected` / `reads_not_allowed` instead of leaving its row `running` until the
      lease sweep.

  Each row is `%{"id" => record_id}` plus every declared field that is present in the record
  AND not in `R`; a restricted field is OMITTED (absent, same as never set; no sentinel).
  Misses, deleted records, unknown and malformed ids all deliver `[]`.

  The tenant prefix comes only from the caller's run context; no table or schema name is built
  from manifest text (the per-type table name, if any, is resolved by the compiler from the
  validated type name). No ETS, persistent_term or process-dictionary state: nothing is cached
  across runs.

  ## Fingerprint read (decision 0065 D2)

  `prefetch_with_fingerprint/3` runs the same phase 1 and phase 2 inside one READ ONLY
  transaction and, between them, reads the `instance_sequence` counter of every read type in
  ascending byte order (phase 1 reads no record, so counters still precede all rows). Nothing is
  inserted; an absent counter is the schema default.
  """

  import Ecto.Query

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.Query.Allowlist
  alias Letflow.Entities.Query.Compiler
  alias Letflow.Entities.Record.Decimals
  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore.InstanceSequence
  alias Letflow.Repo

  @max_rows 50
  @nil_uuid "00000000-0000-0000-0000-000000000000"

  def prefetch(prefix, reads, input_vars)
      when is_binary(prefix) and is_list(reads) and is_map(input_vars) do
    # Phase 1 for EVERY read before the first record query.
    case plan_all(prefix, reads, input_vars) do
      {:ok, plans} -> fetch_all(plans, prefix)
      :refused -> {:error, :reads_not_allowed}
    end
  end

  def prefetch(_prefix, _reads, _input_vars), do: {:error, :reads_not_allowed}

  @doc """
  `prefetch/3` plus a per-type fingerprint (REQ-601, decision 0065 D2): `{:ok, rows, fingerprint}`
  where `fingerprint` maps each read entity type to the `next_seq` of its instance sequence row
  (the `%InstanceSequence{}` default when the type has no registry or sequence row; nothing is
  inserted). One READ ONLY, READ COMMITTED transaction runs phase 1, then the counters of all
  read types in ascending byte order of the type name, then the rows. A counter read before the
  rows can only be stale, never ahead of the rows. Refusals and rows equal `prefetch/3`.

  The caller must not already be inside a transaction: `SET TRANSACTION` is then refused by
  Postgres (SQLSTATE 25001, not a data exception) and the error is re-raised. After the call
  returns, the caller is not in a transaction.
  """
  @spec prefetch_with_fingerprint(String.t(), [map()], map()) ::
          {:ok, %{String.t() => [map()]}, %{String.t() => pos_integer()}}
          | {:error, :reads_not_allowed}
  def prefetch_with_fingerprint(prefix, reads, input_vars)
      when is_binary(prefix) and is_list(reads) and is_map(input_vars) do
    result =
      Repo.transaction(fn ->
        Repo.query!("SET TRANSACTION ISOLATION LEVEL READ COMMITTED, READ ONLY")

        plans =
          case plan_all(prefix, reads, input_vars) do
            {:ok, plans} -> plans
            :refused -> Repo.rollback(:reads_not_allowed)
          end

        fingerprint =
          plans
          |> Enum.map(& &1.entity_type)
          |> Enum.uniq()
          |> Enum.sort()
          |> Map.new(&{&1, counter(&1, prefix)})

        {Map.new(plans, &{&1.name, fetch(&1, prefix)}), fingerprint}
      end)

    case result do
      {:ok, {rows, fingerprint}} -> {:ok, rows, fingerprint}
      {:error, :reads_not_allowed} -> {:error, :reads_not_allowed}
    end
  rescue
    error in Postgrex.Error ->
      if data_exception?(error),
        do: {:error, :reads_not_allowed},
        else: reraise(error, __STACKTRACE__)
  end

  def prefetch_with_fingerprint(_prefix, _reads, _input_vars), do: {:error, :reads_not_allowed}

  # Reads only (`Repo.get`): an absent registry or sequence row is the struct default.
  defp counter(entity_type, prefix) do
    with {:ok, instance_id} <- EntityTypeInstance.fetch_instance_id(entity_type, prefix),
         %InstanceSequence{next_seq: next_seq} <-
           Repo.get(InstanceSequence, instance_id, prefix: prefix) do
      next_seq
    else
      _absent -> %InstanceSequence{}.next_seq
    end
  end

  defp plan_all(prefix, reads, input_vars) do
    planned =
      Enum.reduce_while(reads, {:ok, []}, fn read, {:ok, acc} ->
        case plan(prefix, read, input_vars) do
          {:ok, plan} -> {:cont, {:ok, [plan | acc]}}
          :refused -> {:halt, :refused}
        end
      end)

    case planned do
      {:ok, plans} -> {:ok, Enum.reverse(plans)}
      :refused -> :refused
    end
  end

  # ── phase 1 ─────────────────────────────────────────────────────────────────

  defp plan(
         prefix,
         %{"name" => name, "entity_type" => entity_type, "match" => match, "fields" => fields} =
           read,
         input_vars
       )
       when is_binary(name) and is_binary(entity_type) and is_map(match) and is_list(fields) do
    with true <- readable_master?(prefix, entity_type),
         {:ok, definition} <- active_definition(entity_type, prefix),
         false <- type_restricted?(prefix, entity_type),
         true <- known_fields?(definition, fields, match),
         current = restricted_fields(prefix, entity_type),
         false <- match_field_restricted?(match, current),
         restricted = omitted_fields(current, read),
         strict = Decimals.specs_from_definition_json(definition.definition_json),
         {:ok, query} <- build_query(prefix, entity_type, match, read, input_vars, strict) do
      {:ok,
       %{
         name: name,
         entity_type: entity_type,
         fields: fields,
         restricted: restricted,
         query: query,
         strict: strict
       }}
    else
      _refused -> :refused
    end
  end

  defp plan(_prefix, _read, _input_vars), do: :refused

  defp active_definition(entity_type, prefix) do
    case Definitions.get_active_definition_by_name(entity_type, prefix) do
      {:ok, definition} -> {:ok, definition}
      {:error, _not_found_or_invalid_schema} -> :refused
    end
  end

  # Step 0: the flag, read fresh on every call (schemaless: no entities -> scripts code edge).
  defp readable_master?(prefix, entity_type) do
    Repo.exists?(from(m in "script_readable_masters", where: m.entity_type == ^entity_type),
      prefix: prefix
    )
  end

  defp type_restricted?(prefix, entity_type) do
    Repo.exists?(from(r in "entity_type_restrictions", where: r.entity_type == ^entity_type),
      prefix: prefix
    )
  end

  defp known_fields?(definition, fields, match) do
    known = definition_field_names(definition)
    named = fields ++ List.wrap(Map.get(match, "field"))
    fields != [] and Enum.all?(named, &(is_binary(&1) and MapSet.member?(known, &1)))
  end

  # `definition_json` is read back from jsonb (string keys).
  defp definition_field_names(definition) do
    case definition.definition_json do
      %{"fields" => fields} when is_list(fields) ->
        for %{"name" => name} when is_binary(name) <- fields, into: MapSet.new(), do: name

      _no_fields ->
        MapSet.new()
    end
  end

  # The same table FieldGrants.load_restrictions/3 reads, WITHOUT its per-user grant
  # anti-join (the script principal has no user and no grants, D5).
  defp restricted_fields(prefix, entity_type) do
    from(r in "entity_field_restrictions",
      where: r.entity_type == ^entity_type,
      select: r.field_name
    )
    |> Repo.all(prefix: prefix)
    |> MapSet.new()
  end

  # Decision 0062 R6: a field the read declares in `restricted_fields` is delivered even while
  # restricted; every other restricted field stays omitted. SEC N1 still uses the full set.
  defp omitted_fields(current, read) do
    declared = read |> Map.get("restricted_fields", []) |> List.wrap()
    MapSet.difference(current, MapSet.new(declared))
  end

  # SEC N1: a match field restricted NOW is refused before any record query (a declared
  # restricted_fields entry does not lift it).
  defp match_field_restricted?(%{"field" => field}, restricted),
    do: MapSet.member?(restricted, field)

  defp match_field_restricted?(_id_match, _restricted), do: false

  defp build_query(_prefix, entity_type, %{"id_from" => var} = match, _read, input_vars, _strict)
       when map_size(match) == 1 do
    record_id =
      case Ecto.UUID.cast(Map.get(input_vars, var)) do
        {:ok, uuid} -> uuid
        :error -> @nil_uuid
      end

    {:ok,
     from(r in Latest,
       where: r.entity_type == ^entity_type and r.record_id == ^record_id and r.deleted == false,
       limit: 1,
       select: %{record_id: r.record_id, field_values: r.field_values}
     )}
  end

  defp build_query(
         prefix,
         entity_type,
         %{"field" => field, "value_from" => var} = match,
         read,
         vars,
         strict
       )
       when map_size(match) == 2 and is_binary(field) do
    limit = read |> Map.get("limit", @max_rows) |> row_cap()

    with {:ok, allowlist} <- Allowlist.load(entity_type, prefix),
         {:ok, %{type: type}} <- Allowlist.resolve_field(allowlist, field) do
      {value, usable?} = coerce(type, Map.has_key?(strict, field), Map.get(vars, var))
      request = %{entity_type: entity_type, filters: [%{field: field, op: :eq, value: value}]}

      # scope-all: script principal is tenant-wide, 0051 D1/F6
      case Compiler.compile(request, prefix, :all) do
        {:ok, query} ->
          query =
            query
            |> where([r], field(r, :deleted) == false)
            |> order_by([r], asc: field(r, :record_id))
            |> limit(^limit)

          {:ok, if(usable?, do: query, else: where(query, [r], false))}

        {:error, _compile_error} ->
          :refused
      end
    else
      _not_allowlisted -> :refused
    end
  end

  defp build_query(_prefix, _entity_type, _match, _read, _input_vars, _strict), do: :refused

  defp row_cap(limit) when is_integer(limit) and limit >= 1, do: min(limit, @max_rows)
  defp row_cap(_invalid), do: 1

  # GH #2654: a `decimal_strict` field matches a canonical decimal string or an integer, exactly;
  # a float (already lossy) or a malformed string is the type-mismatch constant-false query.
  # A non-strict decimal field is unchanged (integer or float only).
  defp coerce(:decimal, true, value) when is_binary(value) or is_integer(value) do
    case Decimals.filter_value(value) do
      {:ok, decimal} -> {decimal, true}
      :error -> placeholder(:decimal)
    end
  end

  defp coerce(:decimal, true, _value), do: placeholder(:decimal)
  defp coerce(type, _strict?, value), do: coerce(type, value)

  # The match value converted to what the compiled comparison binds for the field's type; a
  # value of the wrong type yields a type-correct placeholder plus `false` (constant-false
  # predicate, the same single query).
  defp coerce(type, value) when type in [:string, :enum] and is_binary(value), do: {value, true}
  defp coerce(:integer, value) when is_integer(value), do: {value, true}
  defp coerce(:decimal, value) when is_integer(value), do: {Decimal.new(value), true}
  defp coerce(:decimal, value) when is_float(value), do: {Decimal.from_float(value), true}
  defp coerce(:boolean, value) when is_boolean(value), do: {value, true}

  defp coerce(:date, value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {date, true}
      {:error, _} -> placeholder(:date)
    end
  end

  # REVIEWER F3: an offset is required and honoured (converted to UTC); a value without an
  # offset, or an unparsable one, is a type mismatch (constant-false, still one query).
  defp coerce(:datetime, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {datetime |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_naive(), true}

      {:error, _} ->
        placeholder(:datetime)
    end
  end

  defp coerce(type, _value), do: placeholder(type)

  defp placeholder(:integer), do: {0, false}
  defp placeholder(:decimal), do: {Decimal.new(0), false}
  defp placeholder(:boolean), do: {false, false}
  defp placeholder(:date), do: {~D[1970-01-01], false}
  defp placeholder(:datetime), do: {~N[1970-01-01 00:00:00], false}
  defp placeholder(_string_like), do: {"", false}

  # ── phase 2: exactly one record query per read ──────────────────────────────

  # SECURITY F2: a record query the database refuses (a stored value that does not fit the
  # field's SQL cast) refuses the whole prefetch. Nothing is bound or logged; there is no
  # open transaction here, so nothing is left aborted.
  defp fetch_all(plans, prefix) do
    {:ok, Map.new(plans, &{&1.name, fetch(&1, prefix)})}
  rescue
    # Only a data exception (SQLSTATE class 22, e.g. a stored value the cast cannot read) is a
    # refusal; any other database error (timeout, lock, missing table) is re-raised so the
    # dispatcher's handler treats it as transient (SECURITY D1).
    error in Postgrex.Error ->
      if data_exception?(error),
        do: {:error, :reads_not_allowed},
        else: reraise(error, __STACKTRACE__)
  end

  defp data_exception?(%Postgrex.Error{postgres: %{pg_code: "22" <> _}}), do: true
  defp data_exception?(_error), do: false

  defp fetch(%{query: query, fields: fields, restricted: restricted, strict: strict}, prefix) do
    query
    |> Repo.all(prefix: prefix)
    |> Enum.map(&project(&1, fields, restricted, strict))
  end

  # A strict decimal is delivered as its canonical string (Lua compares and forwards strings; `tonumber`
  # is lossy), exactly as the HTTP reads render it. Non-strict fields are delivered as stored.
  defp project(record, fields, restricted, strict) do
    values =
      case record.field_values do
        %{} = values -> Decimals.render_field_values(values, strict)
        _none -> %{}
      end

    for field <- fields,
        Map.has_key?(values, field),
        not MapSet.member?(restricted, field),
        into: %{"id" => record.record_id},
        do: {field, Map.fetch!(values, field)}
  end
end
