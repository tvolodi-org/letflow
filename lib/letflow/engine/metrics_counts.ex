defmodule Letflow.Engine.MetricsCounts do
  @moduledoc """
  REQ-078 metrics counters, split out of `Letflow.Engine` (B4#10, code health;
  code moved verbatim, no behaviour change). `Letflow.Engine` keeps
  `count_instances_by_status/1` and `count_tasks_by_status/1` as `defdelegate`s
  with the same names, arities and specs, so no caller changed.

  These back GET /api/v1/metrics: `COUNT(*)` aggregates over tables that already
  exist in the caller's tenant schema (design: `req078-supporting-routes.md`
  section 11.4), NOT a metrics subsystem. See `Letflow.Routers.Metrics`.
  """

  import Ecto.Query

  alias Letflow.Engine.Task
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @typedoc """
  status atom -> row count, within one tenant schema. Every status in the
  owning schema's closed enum is present, zero-valued if unseen.
  """
  @type status_counts :: %{atom() => non_neg_integer()}

  # Declared before their readers -- module attributes are read at expansion
  # time. Both mirror the closed `Ecto.Enum` value sets of the schemas below.
  @instance_status_zero_fill %{active: 0, completed: 0, cancelled: 0, error: 0}
  @task_status_zero_fill %{pending: 0, completed: 0, cancelled: 0}

  @doc """
  Counts `instance_projections` rows by `status`, scoped to `opts[:prefix]`.
  One query.

  **Grouped over the schema field, never the raw column.**
  `instance_projections.status` is a *keyword-mapped* `Ecto.Enum`
  (`[active: "ACTIVE", completed: "COMPLETED", ...]`), so the values stored in
  Postgres are the uppercase strings, not the atom names. A `group_by` written
  against the raw column would yield keys like `"ACTIVE"`, which would never
  match the `:active` atoms the zero-fill uses — silently producing an
  all-zero map plus unexpected extra keys. Composing over the schema field
  makes Ecto's enum loader map each value back to its atom first.

  `opts[:prefix]` is validated via
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` **before** the
  query is constructed. Composed with `Ecto.Query` and bound parameters only
  (INV-7).
  """
  @spec count_instances_by_status(opts :: [prefix: String.t()]) ::
          {:ok, status_counts()} | {:error, :invalid_schema_name}
  def count_instances_by_status(opts) when is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      counts =
        InstanceProjection
        |> group_by([p], p.status)
        |> select([p], {p.status, count(p.instance_id)})
        |> Repo.all(prefix: prefix)
        |> Map.new()

      {:ok, Map.merge(@instance_status_zero_fill, counts)}
    end
  end

  @doc """
  Counts `tasks` rows by `status`, scoped to `opts[:prefix]`. One query.

  Same keyword-mapped-enum caveat as `count_instances_by_status/1` — see its
  `@doc`. `tasks.status` stores `"PENDING"`/`"COMPLETED"`/`"CANCELLED"`, so
  the `group_by` is composed over the schema field, not the raw column.
  """
  @spec count_tasks_by_status(opts :: [prefix: String.t()]) ::
          {:ok, status_counts()} | {:error, :invalid_schema_name}
  def count_tasks_by_status(opts) when is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      counts =
        Task
        |> group_by([t], t.status)
        |> select([t], {t.status, count(t.id)})
        |> Repo.all(prefix: prefix)
        |> Map.new()

      {:ok, Map.merge(@task_status_zero_fill, counts)}
    end
  end
end
