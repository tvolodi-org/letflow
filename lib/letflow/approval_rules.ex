defmodule Letflow.ApprovalRules do
  @moduledoc """
  T-1986 (four-eyes switch, slice 1; docs/design/four-eyes-switch.md, owner decision D-144): the
  admin context behind `GET /approval-rules` and `PUT /approval-rules/:definition_name/:node_id`.

  The four-eyes rule is the HUMAN_TASK attribute `distinct_from`
  (`Letflow.Engine.SeparationOfDuties`). A tenant administrator can switch it per process
  (definition name) and step (node id). The stored setting is
  `Letflow.Engine.ApprovalRuleSetting`; no row means ON.

  `list/1` answers every step of an ACTIVE definition that names `distinct_from`, plus every stored
  row whose step is no longer in an active definition (`in_active_definition: false`), so an OFF row
  that still applies to running instances of an older version is never hidden.

  `put/5` validates in this order and writes nothing before the last step: body, reason, step
  existence, then (only when the value changes) the row and an `approval_rule.changed` audit entry in
  ONE transaction. A PUT equal to the current value writes nothing. The tenant comes only from
  `prefix` (INV-1); names are bound parameters (INV-7).
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Audit
  alias Letflow.Audit.Reason
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Engine.ApprovalRuleSetting
  alias Letflow.Repo

  @type item :: %{
          definition_name: String.t(),
          node_id: String.t(),
          node_label: String.t() | nil,
          four_eyes: boolean(),
          in_active_definition: boolean(),
          changed_by: Ecto.UUID.t() | nil,
          changed_at: DateTime.t() | nil,
          reason: String.t() | nil
        }

  @type actor :: %{user_id: Ecto.UUID.t(), trace_id: String.t() | nil}

  @doc """
  T-1987: would the engine let this caller approve their own task? True only for an interactive
  (`:oidc`) credential and a stored OFF row for the task's step in the instance's definition: the
  condition `Letflow.Engine.SeparationOfDuties.check/6` uses. Any read failure answers false (the
  web keeps showing its hint; the server still decides at completion). Used by `GET /tasks/:id`.
  """
  @spec self_approval_allowed?(String.t(), Letflow.Engine.Task.t(), term()) :: boolean()
  def self_approval_allowed?(prefix, %Letflow.Engine.Task{} = task, :oidc) do
    case ApprovalRuleSetting.off_for_instance_step(Repo, prefix, task.instance_id, task.node_id) do
      {:ok, value} -> value
      {:error, :unreadable} -> false
    end
  end

  def self_approval_allowed?(_prefix, _task, _credential), do: false

  @doc "Every four-eyes step of the tenant with its current value, sorted by definition name and node id."
  @spec list(prefix :: String.t()) :: [item()]
  def list(prefix) do
    steps = active_steps(prefix)

    settings =
      Map.new(
        Repo.all(ApprovalRuleSetting, prefix: prefix),
        &{{&1.definition_name, &1.node_id}, &1}
      )

    active_items =
      Enum.map(steps, fn {{name, node_id} = key, label} ->
        item(name, node_id, label, Map.get(settings, key), true)
      end)

    orphan_items =
      for {key, setting} <- settings, not Map.has_key?(steps, key) do
        item(setting.definition_name, setting.node_id, nil, setting, false)
      end

    Enum.sort_by(active_items ++ orphan_items, &{&1.definition_name, &1.node_id})
  end

  @doc """
  Switches one step. `body` is `%{"four_eyes" => boolean, "reason" => string}`.
  """
  @spec put(
          prefix :: String.t(),
          definition_name :: String.t(),
          node_id :: String.t(),
          body :: term(),
          actor()
        ) ::
          {:ok, item()}
          | {:error,
             :invalid_body | :invalid_reason | :not_a_four_eyes_step | :conflict | :audit_failed}
  def put(prefix, definition_name, node_id, body, %{user_id: _} = actor)
      when is_binary(definition_name) and is_binary(node_id) do
    with {:ok, four_eyes} <- fetch_four_eyes(body),
         {:ok, reason} <- fetch_reason(body) do
      do_put(prefix, definition_name, node_id, four_eyes, reason, actor)
    end
  end

  def put(_prefix, _name, _node_id, _body, _actor), do: {:error, :invalid_body}

  defp fetch_four_eyes(%{"four_eyes" => value}) when is_boolean(value), do: {:ok, value}
  defp fetch_four_eyes(_body), do: {:error, :invalid_body}

  defp fetch_reason(%{"reason" => reason}) do
    case Reason.validate(reason) do
      {:ok, trimmed} -> {:ok, trimmed}
      :error -> {:error, :invalid_reason}
    end
  end

  defp fetch_reason(_body), do: {:error, :invalid_reason}

  defp do_put(prefix, name, node_id, four_eyes, reason, actor) do
    result =
      Repo.transaction(fn ->
        existing =
          Repo.one(
            from(s in ApprovalRuleSetting,
              where: s.definition_name == ^name and s.node_id == ^node_id,
              lock: "FOR UPDATE"
            ),
            prefix: prefix
          )

        steps = active_steps(prefix)
        key = {name, node_id}

        step_ok? =
          Map.has_key?(steps, key) or (four_eyes and existing != nil)

        unless step_ok?, do: Repo.rollback(:not_a_four_eyes_step)

        label = Map.get(steps, key)
        old = if existing, do: existing.four_eyes, else: true

        if old == four_eyes do
          item(name, node_id, label, existing, Map.has_key?(steps, key))
        else
          row = write_row!(prefix, existing, name, node_id, four_eyes, reason, actor)
          audit!(prefix, row, old, four_eyes, reason, actor)
          item(name, node_id, label, row, Map.has_key?(steps, key))
        end
      end)

    case result do
      {:ok, item} -> {:ok, item}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in [Ecto.ConstraintError, Postgrex.Error] ->
      if match?(%Postgrex.Error{postgres: %{code: :unique_violation}}, e) or
           is_struct(e, Ecto.ConstraintError),
         do: {:error, :conflict},
         else: {:error, :audit_failed}

    _other ->
      {:error, :audit_failed}
  end

  defp write_row!(prefix, nil, name, node_id, four_eyes, reason, actor) do
    now = DateTime.utc_now()

    Repo.insert!(
      %ApprovalRuleSetting{
        definition_name: name,
        node_id: node_id,
        four_eyes: four_eyes,
        changed_by: actor.user_id,
        changed_at: now,
        reason: reason
      },
      prefix: prefix
    )
  end

  defp write_row!(prefix, %ApprovalRuleSetting{} = existing, _n, _id, four_eyes, reason, actor) do
    existing
    |> Ecto.Changeset.change(%{
      four_eyes: four_eyes,
      changed_by: actor.user_id,
      changed_at: DateTime.utc_now(),
      reason: reason
    })
    |> Repo.update!(prefix: prefix)
  end

  defp audit!(prefix, row, old, new, reason, actor) do
    {:ok, _} =
      Multi.new()
      |> Audit.append_multi(
        :audit,
        %{
          actor_id: actor.user_id,
          action: "approval_rule.changed",
          resource_type: "approval_rule",
          resource_id: row.id,
          before_state: %{
            "definition_name" => row.definition_name,
            "node_id" => row.node_id,
            "four_eyes" => old
          },
          after_state: %{
            "definition_name" => row.definition_name,
            "node_id" => row.node_id,
            "four_eyes" => new,
            "reason" => reason
          },
          trace_id: Map.get(actor, :trace_id)
        },
        prefix
      )
      |> Repo.transaction()

    :ok
  end

  defp item(name, node_id, label, setting, in_active) do
    %{
      definition_name: name,
      node_id: node_id,
      node_label: label,
      four_eyes: if(setting, do: setting.four_eyes, else: true),
      in_active_definition: in_active,
      changed_by: setting && setting.changed_by,
      changed_at: setting && setting.changed_at,
      reason: setting && setting.reason
    }
  end

  # `%{{definition_name, node_id} => label | nil}` of every HUMAN_TASK of an ACTIVE definition that
  # names a non-empty `distinct_from` (the filter of `SeparationOfDuties.distinct_from/1`). Reads
  # the raw graph map so one malformed graph cannot fail the list.
  defp active_steps(prefix) do
    from(d in ProcessDefinition, where: d.status == :active, select: {d.name, d.graph})
    |> Repo.all(prefix: prefix)
    |> Enum.reduce(%{}, fn {name, graph}, acc ->
      graph
      |> raw_nodes()
      |> Enum.reduce(acc, fn node, acc2 ->
        case node do
          %{"node_type" => "HUMAN_TASK", "id" => id} when is_binary(id) ->
            if four_eyes_node?(node),
              do: Map.put_new(acc2, {name, id}, label(node)),
              else: acc2

          _other ->
            acc2
        end
      end)
    end)
  end

  defp raw_nodes(%{"nodes" => nodes}) when is_list(nodes), do: nodes
  defp raw_nodes(_graph), do: []

  defp four_eyes_node?(%{"attributes" => %{"distinct_from" => list}}) when is_list(list),
    do: Enum.any?(list, &(is_binary(&1) and &1 != ""))

  defp four_eyes_node?(_node), do: false

  defp label(%{"label" => label}) when is_binary(label), do: label
  defp label(_node), do: nil
end
