defmodule Letflow.Modules.StepRecords do
  @moduledoc """
  REQ-773: the one "where unset" predicate of a declarative data step, shared by the plan's count
  and the executor's batches, so the two cannot disagree about which records a step touches.

  A record is a candidate of a step when it is live (`deleted == false`), of the step's type, and
  the target key is absent or JSON `null` in `field_values` (an existing value, `false`, `0` and
  `""` included, is kept). A `copy_field` step also needs the source key present and not `null`.

  Every query is Ecto with bound parameters (type, keys, cursor); no SQL string is built (INV-7).
  The schema is the `prefix` the caller passes (INV-1); nothing here reads a tenant id.

  ## Restricted fields (INV-2, decision 0055 D2, REQ-768 criterion 7)

  A number over `field_values` of a field listed in `entity_field_restrictions` would be an
  equality oracle for a caller who may not read the field. `restricted?/2` is true when the
  tenant restricts ANY field the step reads or writes. `reportable_count/3` then answers `nil`
  (also when `TypeAccess` denies the actor the type), and `bound/2`, the only number the one-
  transaction cap uses, falls back to `live_total/2`: the live record count of the type, which
  uses no `field_values` predicate and so reveals nothing about any field.
  """

  import Ecto.Query, only: [from: 2, dynamic: 1, dynamic: 2]

  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.TypeAccess
  alias Letflow.Repo

  @type spec :: map()

  @doc """
  The candidate query: ordered by `record_id`, after `cursor` (`nil` for the start), at most
  `limit` rows. With `lock: true` the rows are selected `FOR UPDATE`.
  """
  @spec candidates_query(spec(), String.t() | nil, pos_integer(), boolean()) :: Ecto.Query.t()
  def candidates_query(spec, cursor, limit, lock? \\ false) do
    query =
      from(l in base(spec),
        where: ^after_cursor(cursor),
        order_by: [asc: l.record_id],
        limit: ^limit
      )

    if lock?, do: Ecto.Query.lock(query, "FOR UPDATE"), else: query
  end

  @doc "The number of candidates of `spec` (exact; field-dependent: see `reportable_count/3`)."
  @spec count(spec(), String.t()) :: non_neg_integer()
  def count(spec, prefix) when is_binary(prefix) do
    Repo.aggregate(base(spec), :count, :id, prefix: prefix)
  end

  @doc "The number of live records of `type`. Uses no field predicate, so it is field-independent."
  @spec live_total(String.t(), String.t()) :: non_neg_integer()
  def live_total(type, prefix) when is_binary(type) and is_binary(prefix) do
    from(l in Latest, where: l.entity_type == ^type and l.deleted == false)
    |> Repo.aggregate(:count, :id, prefix: prefix)
  end

  @doc """
  Whether the tenant restricts any field `spec` reads or writes (the target; for `copy_field`
  also the source) on the step's type.
  """
  @spec restricted?(spec(), String.t()) :: boolean()
  def restricted?(%{type: type} = spec, prefix) when is_binary(prefix) do
    names = fields(spec)

    Repo.exists?(
      from(r in "entity_field_restrictions",
        where: r.entity_type == ^type and r.field_name in ^names
      ),
      prefix: prefix
    )
  end

  @doc """
  The count a plan may show `actor_id`, or `nil` when the step touches a restricted field or the
  actor is denied the type by `TypeAccess` (the existing per-type read gate; no new permission).
  A failing `TypeAccess` lookup shows nothing (fail closed).
  """
  @spec reportable_count(spec(), String.t(), String.t() | nil) :: non_neg_integer() | nil
  def reportable_count(%{type: type} = spec, prefix, actor_id) do
    cond do
      restricted?(spec, prefix) -> nil
      not is_binary(actor_id) -> nil
      denied?(actor_id, type, prefix) -> nil
      true -> count(spec, prefix)
    end
  end

  @doc """
  The number the one-transaction cap uses: the exact `count/2` for an unrestricted step, the
  type's `live_total/2` for a restricted one (an over-estimate, fail closed).
  """
  @spec bound(spec(), String.t()) :: non_neg_integer()
  def bound(%{type: type} = spec, prefix) do
    if restricted?(spec, prefix), do: live_total(type, prefix), else: count(spec, prefix)
  end

  @doc "The fields a spec reads or writes."
  @spec fields(spec()) :: [String.t()]
  def fields(%{op: :copy_field, from: from, to: to}), do: [from, to]
  def fields(%{field: field}), do: [field]
  def fields(_spec), do: []

  @doc "The key the step writes."
  @spec target(spec()) :: String.t()
  def target(%{op: :copy_field, to: to}), do: to
  def target(%{field: field}), do: field

  defp denied?(actor_id, type, prefix) do
    case TypeAccess.denied_types(actor_id, [type], prefix) do
      {:ok, denied} -> MapSet.member?(denied, type)
      _error -> true
    end
  end

  defp base(%{type: type} = spec) do
    from(l in Latest,
      where: l.entity_type == ^type and l.deleted == false,
      where: ^unset(target(spec)),
      where: ^source_present(spec)
    )
  end

  defp unset(key) do
    dynamic(
      [l],
      fragment("(? -> ?::text) IS NULL", l.field_values, type(^key, :string)) or
        fragment("jsonb_typeof(? -> ?::text) = 'null'", l.field_values, type(^key, :string))
    )
  end

  defp source_present(%{op: :copy_field, from: from}) do
    dynamic(
      [l],
      fragment("(? -> ?::text) IS NOT NULL", l.field_values, type(^from, :string)) and
        fragment("jsonb_typeof(? -> ?::text) <> 'null'", l.field_values, type(^from, :string))
    )
  end

  defp source_present(_spec), do: dynamic(true)

  defp after_cursor(nil), do: dynamic(true)
  defp after_cursor(cursor), do: dynamic([l], l.record_id > type(^cursor, Ecto.UUID))
end
