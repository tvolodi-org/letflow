defmodule Letflow.Engine.ApprovalRuleSetting do
  @moduledoc """
  T-1986 (four-eyes switch, slice 1): one stored setting per (process definition name, HUMAN_TASK
  node id) in the tenant schema table `approval_rule_settings`. No row means the four-eyes rule
  (`distinct_from`, `Letflow.Engine.SeparationOfDuties`) is ON; a row with `four_eyes: false`
  switches it OFF for that step only. T-2391 (D-165): a NEW tenant carries a default marker row in
  `approval_rule_defaults` (see its migration); there a step with no setting row is OFF, and a stored
  row (true or false) always wins. Rows are written by `Letflow.ApprovalRules` (the admin
  routes); the engine only reads.

  Both read functions are TOTAL: a database error (for example a lagging tenant without the table)
  returns `{:error, :unreadable}`, never raises, so callers can fail closed (the check) or toward
  "shown" (the REQ-464 warning). Every query carries the tenant `prefix` (INV-1) and bound
  parameters (INV-7).
  """

  use Ecto.Schema

  import Ecto.Query

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "approval_rule_settings" do
    field(:definition_name, :string)
    field(:node_id, :string)
    field(:four_eyes, :boolean)
    field(:changed_by, :binary_id)
    field(:changed_at, :utc_datetime_usec)
    field(:reason, :string)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc """
  The stored setting of one step, or `nil` when none exists (ON). `query_opts` is merged after the
  prefix (the check passes `mode: :savepoint` inside a transaction).
  """
  @spec read(
          repo :: module(),
          prefix :: String.t(),
          definition_name :: String.t(),
          node_id :: String.t(),
          query_opts :: keyword()
        ) :: {:ok, t() | nil} | {:error, :unreadable}
  def read(repo, prefix, definition_name, node_id, query_opts \\ []) do
    query =
      from(s in __MODULE__,
        where: s.definition_name == ^definition_name and s.node_id == ^node_id
      )

    {:ok, repo.one(query, [prefix: prefix] ++ query_opts)}
  rescue
    _exception -> {:error, :unreadable}
  catch
    _kind, _value -> {:error, :unreadable}
  end

  @doc """
  T-2391: does this tenant carry the new-tenant default marker (steps with no stored setting are OFF)?
  Total: an unreadable table (a lagging tenant) answers `{:error, :unreadable}`, which callers treat as
  ON (fails closed).
  """
  @spec default_off(repo :: module(), prefix :: String.t(), query_opts :: keyword()) ::
          {:ok, boolean()} | {:error, :unreadable}
  def default_off(repo, prefix, query_opts \\ []) do
    query =
      from(d in "approval_rule_defaults",
        where: d.four_eyes_default == false,
        select: true,
        limit: 1
      )

    {:ok, repo.one(query, [prefix: prefix] ++ query_opts) == true}
  rescue
    _exception -> {:error, :unreadable}
  catch
    _kind, _value -> {:error, :unreadable}
  end

  @doc """
  The EFFECTIVE setting of one step: the stored row when there is one, else a synthetic OFF setting
  (`id: nil`, `changed_at: nil`, `reason: nil`) when the tenant default is OFF, else `nil` (ON).
  """
  @spec effective(
          repo :: module(),
          prefix :: String.t(),
          definition_name :: String.t(),
          node_id :: String.t(),
          query_opts :: keyword()
        ) :: {:ok, t() | nil} | {:error, :unreadable}
  def effective(repo, prefix, definition_name, node_id, query_opts \\ []) do
    case read(repo, prefix, definition_name, node_id, query_opts) do
      {:ok, nil} ->
        case default_off(repo, prefix, query_opts) do
          {:ok, true} ->
            {:ok,
             %__MODULE__{
               definition_name: definition_name,
               node_id: node_id,
               four_eyes: false
             }}

          {:ok, false} ->
            {:ok, nil}

          {:error, :unreadable} = error ->
            error
        end

      other ->
        other
    end
  end

  @doc """
  The set of `{definition_name, node_id}` steps that are switched OFF, among the given definition
  names: ONE read in total. An empty name list answers without a query.
  """
  @spec off_steps(
          repo :: module(),
          prefix :: String.t(),
          definition_names :: [String.t()],
          query_opts :: keyword()
        ) :: {:ok, MapSet.t({String.t(), String.t()})} | {:error, :unreadable}
  def off_steps(repo, prefix, definition_names, query_opts \\ [])

  def off_steps(_repo, _prefix, [], _query_opts), do: {:ok, MapSet.new()}

  def off_steps(repo, prefix, definition_names, query_opts) do
    query =
      from(s in __MODULE__,
        where: s.definition_name in ^definition_names and s.four_eyes == false,
        select: {s.definition_name, s.node_id}
      )

    {:ok, query |> repo.all([prefix: prefix] ++ query_opts) |> MapSet.new()}
  rescue
    _exception -> {:error, :unreadable}
  catch
    _kind, _value -> {:error, :unreadable}
  end

  @doc """
  T-1987: is the step `node_id` of the definition pinned by instance `instance_id` switched OFF (a
  stored `false` row, or no row on a tenant whose default is OFF, T-2391)? One query for the row (a
  second one for the default only when there is no row) joining the instance's definition snapshot and the setting row, both in the tenant
  `prefix` (INV-1), all values bound (INV-7). Total: a database error returns `{:error, :unreadable}`.
  """
  @spec off_for_instance_step(
          repo :: module(),
          prefix :: String.t(),
          instance_id :: Ecto.UUID.t(),
          node_id :: String.t(),
          query_opts :: keyword()
        ) :: {:ok, boolean()} | {:error, :unreadable}
  def off_for_instance_step(repo, prefix, instance_id, node_id, query_opts \\ []) do
    query =
      from(s in __MODULE__,
        join: snap in Letflow.Definitions.InstanceDefinitionSnapshot,
        on: snap.definition_name == s.definition_name,
        where: snap.instance_id == ^instance_id and s.node_id == ^node_id,
        select: s.four_eyes,
        limit: 1
      )

    case repo.one(query, [prefix: prefix] ++ query_opts) do
      nil -> default_off(repo, prefix, query_opts)
      four_eyes -> {:ok, four_eyes == false}
    end
  rescue
    _exception -> {:error, :unreadable}
  catch
    _kind, _value -> {:error, :unreadable}
  end
end
