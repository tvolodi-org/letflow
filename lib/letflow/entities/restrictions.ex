defmodule Letflow.Entities.Restrictions do
  @moduledoc """
  ISS-0935 (design `lib/letflow/design/iss0935-vortex-entity-seed.md` §1.3)
  -- the write path for the four restriction/grant tenant tables
  `Letflow.Entities.Query.FieldGrants` (REQ-231) and
  `Letflow.Entities.TypeAccess` (REQ-394) read from but never write to.
  Those two modules stay read-only and unmodified by this change -- this
  module is their own "future write-path requirement" (each module's own
  moduledoc), landed narrowly as a bulk-import write for seed/fixture use,
  not a full admin CRUD/listing API (design §1.3's explicit "no `GET`/
  `DELETE`" scope cut).

  GH #2808: the HTTP route gates the whole request with `TypeAccess` before calling this
  module (any named type the caller is denied is a constant 403 and nothing is written); this
  module itself stays ungated for system callers. `entity_types/1` names the types a body carries.

  Public functions: `import_restrictions/2`: a per-table upsert
  (`on_conflict: :nothing` against each table's existing unique index) for
  up to four caller-supplied row lists -- `field_restrictions`,
  `field_grants`, `type_restrictions`, `type_grants`. An absent (or empty)
  list for a given table is "insert nothing for that table," never an
  error.

  ## Precedent this follows, not re-invents

  `Letflow.Modules.Exam.on_install/2` already writes `entity_field_restrictions`
  rows via a schemaless `Repo.insert_all("entity_field_restrictions", rows,
  on_conflict: :nothing, conflict_target: [...])` call, inside its own
  install transaction -- the one write path into these tables that existed
  anywhere in the repo before this module (design §1.3's own grep note).
  This module uses the exact same schemaless-table-name,
  `Ecto.UUID.bingenerate/0`-for-`id`, `NaiveDateTime.utc_now/0`-for-
  timestamps shape that call already established, just reachable from an
  external HTTP route instead of an in-process module-install transaction,
  and across all four tables instead of one.

  ## Validation -- 422 contract (design §1.3)

  Every row's `entity_type`/`field_name` must be a non-empty string. Every
  row's `user_id` must resolve to a REAL user row in the CALLING TENANT's
  own schema (`Repo.get(Letflow.Identity.User, user_id, prefix: prefix)`)
  -- this is the cross-tenant-injection guard SECURITY-REVIEWER's checklist
  (design §7) calls for: a `user_id` that is a well-formed UUID belonging
  to a DIFFERENT tenant's schema does not exist in THIS prefix's `users`
  table, so it is rejected the same way a malformed or wholly nonexistent
  id is -- there is no way to plant a `user_entity_grants`/
  `user_entity_type_grants` row for a user outside the caller's own
  tenant. No existence check is performed against `entity_definitions`
  (same "not an existence oracle" posture `TypeAccess`'s own moduledoc
  states for its read side, design §1.3).

  All validation runs BEFORE any `insert_all` -- a 422 on any row means
  ZERO rows are inserted for this call, across all four tables (fail the
  whole request, not a partial-success batch -- a materially different
  posture from REQ-320's own per-record import, deliberately: these rows
  change WHO can see WHAT tenant-wide, so a half-applied access-control
  change is a worse failure mode than a half-applied content import).
  """

  alias Letflow.Identity.User
  alias Letflow.Repo

  @typedoc "One validation failure: which table, which row (0-based), why."
  @type row_error :: %{table: String.t(), index: non_neg_integer(), reason: String.t()}

  @typedoc "Per-table inserted-row counts (an on_conflict:-matched row is not counted)."
  @type counts :: %{
          field_restrictions: non_neg_integer(),
          field_grants: non_neg_integer(),
          type_restrictions: non_neg_integer(),
          type_grants: non_neg_integer()
        }

  @doc """
  The distinct binary `"entity_type"` values named by the entries of the four row lists of
  `attrs` (GH #2808: the route gates the request on these via `TypeAccess.denied_types/3`). A
  non-list list value, a non-map entry or a non-binary `entity_type` contributes nothing; the row
  validation of `import_restrictions/2` answers those with 422.
  """
  @spec entity_types(attrs :: map()) :: [String.t()]
  def entity_types(attrs) when is_map(attrs) do
    ["field_restrictions", "field_grants", "type_restrictions", "type_grants"]
    |> Enum.flat_map(fn key ->
      case Map.get(attrs, key) do
        rows when is_list(rows) -> rows
        _not_a_list -> []
      end
    end)
    |> Enum.flat_map(fn
      %{"entity_type" => entity_type} when is_binary(entity_type) -> [entity_type]
      _other -> []
    end)
    |> Enum.uniq()
  end

  @doc """
  Upserts up to four row lists from `attrs` (string keys
  `"field_restrictions"`, `"field_grants"`, `"type_restrictions"`,
  `"type_grants"`, each optional) into their respective tenant tables
  scoped by `prefix`. Returns `{:ok, counts()}` with per-table
  inserted-row counts, or `{:error, {:invalid_rows, [row_error()]}}` when
  any row fails validation -- no table is written to in that case.
  """
  @spec import_restrictions(attrs :: map(), prefix :: String.t()) ::
          {:ok, counts()} | {:error, {:invalid_rows, [row_error()]}}
  def import_restrictions(attrs, prefix) when is_map(attrs) and is_binary(prefix) do
    field_restrictions = Map.get(attrs, "field_restrictions", [])
    field_grants = Map.get(attrs, "field_grants", [])
    type_restrictions = Map.get(attrs, "type_restrictions", [])
    type_grants = Map.get(attrs, "type_grants", [])

    errors =
      validate_rows("field_restrictions", field_restrictions, [:entity_type, :field_name], prefix) ++
        validate_rows(
          "field_grants",
          field_grants,
          [:user_id, :entity_type, :field_name],
          prefix
        ) ++
        validate_rows("type_restrictions", type_restrictions, [:entity_type], prefix) ++
        validate_rows("type_grants", type_grants, [:user_id, :entity_type], prefix)

    if errors == [] do
      now = NaiveDateTime.utc_now()

      counts = %{
        field_restrictions:
          insert_rows(
            "entity_field_restrictions",
            field_restrictions,
            [:entity_type, :field_name],
            [:entity_type, :field_name],
            now,
            prefix
          ),
        field_grants:
          insert_rows(
            "user_entity_grants",
            field_grants,
            [:user_id, :entity_type, :field_name],
            [:user_id, :entity_type, :field_name],
            now,
            prefix
          ),
        type_restrictions:
          insert_rows(
            "entity_type_restrictions",
            type_restrictions,
            [:entity_type],
            [:entity_type],
            now,
            prefix
          ),
        type_grants:
          insert_rows(
            "user_entity_type_grants",
            type_grants,
            [:user_id, :entity_type],
            [:user_id, :entity_type],
            now,
            prefix
          )
      }

      {:ok, counts}
    else
      {:error, {:invalid_rows, errors}}
    end
  end

  # ── Validation ──────────────────────────────────────────────────────────

  defp validate_rows(table, rows, _keys, _prefix) when not is_list(rows) do
    [%{table: table, index: 0, reason: "must be an array"}]
  end

  defp validate_rows(table, rows, keys, prefix) do
    rows
    |> Enum.with_index()
    |> Enum.flat_map(fn {row, index} -> validate_row(table, row, keys, index, prefix) end)
  end

  defp validate_row(table, row, keys, index, prefix) when is_map(row) do
    Enum.flat_map(keys, fn
      :user_id ->
        case validate_user_id(Map.get(row, "user_id"), prefix) do
          :ok -> []
          {:error, reason} -> [%{table: table, index: index, reason: reason}]
        end

      key ->
        case validate_nonempty_string(Map.get(row, Atom.to_string(key))) do
          :ok -> []
          {:error, reason} -> [%{table: table, index: index, reason: "#{key} #{reason}"}]
        end
    end)
  end

  defp validate_row(table, _row, _keys, index, _prefix) do
    [%{table: table, index: index, reason: "must be an object"}]
  end

  defp validate_nonempty_string(value) when is_binary(value) and value != "", do: :ok
  defp validate_nonempty_string(_value), do: {:error, "must be a non-empty string"}

  defp validate_user_id(user_id, prefix) when is_binary(user_id) and user_id != "" do
    with {:ok, uuid} <- Ecto.UUID.cast(user_id),
         %User{} <- Repo.get(User, uuid, prefix: prefix) do
      :ok
    else
      _ -> {:error, "user_id does not resolve to a user in this tenant"}
    end
  end

  defp validate_user_id(_user_id, _prefix),
    do: {:error, "user_id must be a non-empty string"}

  # ── Insert ────────────────────────────────────────────────────────────
  #
  # Schemaless Repo.insert_all/3 against a raw table name -- same shape
  # Letflow.Modules.Exam.on_install/2 already established for
  # "entity_field_restrictions" (design §1.3's own precedent note).
  # `Ecto.UUID.bingenerate/0` for `id` and `Ecto.UUID.dump!/1` for any
  # `user_id` value -- both binary_id/uuid columns need the raw 16-byte
  # binary form for a schemaless insert, not the dashed string form
  # `Ecto.UUID.cast/1`/`validate_user_id/2` above work with.

  defp insert_rows(_table, [], _keys, _conflict_target, _now, _prefix), do: 0

  defp insert_rows(table, rows, keys, conflict_target, now, prefix) do
    entries = Enum.map(rows, &row_to_entry(&1, keys, now))

    {count, _} =
      Repo.insert_all(table, entries,
        on_conflict: :nothing,
        conflict_target: conflict_target,
        prefix: prefix
      )

    count
  end

  defp row_to_entry(row, keys, now) do
    keys
    |> Map.new(fn key -> {key, entry_value(key, Map.fetch!(row, Atom.to_string(key)))} end)
    |> Map.put(:id, Ecto.UUID.bingenerate())
    |> Map.put(:inserted_at, now)
    |> maybe_put_updated_at(keys, now)
  end

  defp entry_value(:user_id, value), do: Ecto.UUID.dump!(value)
  defp entry_value(_key, value), do: value

  # entity_field_restrictions/entity_type_restrictions use
  # `timestamps(type: :utc_datetime_usec)` (both inserted_at and
  # updated_at); user_entity_grants/user_entity_type_grants use
  # `timestamps(updated_at: false, ...)` (inserted_at only) -- distinguished
  # here by whether the row shape carries `:field_name` without `:user_id`
  # (the two restriction tables) vs. carries `:user_id` (the two grant
  # tables), matching each table's own migration exactly.
  defp maybe_put_updated_at(entry, keys, now) do
    if :user_id in keys do
      entry
    else
      Map.put(entry, :updated_at, now)
    end
  end
end
