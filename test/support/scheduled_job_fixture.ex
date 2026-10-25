defmodule Letflow.TestSupport.ScheduledJobFixture do
  @moduledoc """
  Shared fixtures for the REQ-561 / GH #3194 scheduled-job tests: a published definition, a user
  holding a role, a valid job attrs map and an instance counter. Test-only.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Engine
  alias Letflow.Identity.GroupMember
  alias Letflow.Repo
  alias Letflow.ScheduledJobs
  alias Letflow.Support.RoleScopeGrantsFixture, as: Rsg

  @anchor ~U[2026-01-01 00:00:00.000000Z]

  @doc "The fixed anchor of `attrs/1`."
  def anchor, do: @anchor

  @doc "A one-task definition (a HUMAN_TASK keeps the instance active); returns its name."
  def definition!(schema, name \\ nil, activate? \\ true) do
    name = name || "sj-def-" <> to_string(System.unique_integer([:positive]))

    {:ok, definition} =
      Definitions.create(
        %{name: name, version: "1.0.0", graph: graph(), created_by: Ecto.UUID.generate()},
        prefix: schema
      )

    if activate?, do: {:ok, _} = Definitions.activate(definition.id, prefix: schema)
    name
  end

  @doc "Sets `status` (and optionally nothing else) on every row of the definition name."
  def set_status!(schema, name, status) do
    Repo.update_all(
      from(d in ProcessDefinition, where: d.name == ^name),
      [set: [status: status]],
      prefix: schema
    )
  end

  @doc "Marks the active row of the name as needing reactivation."
  def needs_reactivation!(schema, name) do
    Repo.update_all(
      from(d in ProcessDefinition, where: d.name == ^name),
      [set: [needs_reactivation_at: DateTime.utc_now(), needs_reactivation_reason: "test"]],
      prefix: schema
    )
  end

  @doc "An active user holding the platform role `role` through a group of its own."
  def actor!(schema, role \\ "TENANT_ADMIN") do
    user = Rsg.user!(schema)
    group_id = role_group!(schema, role)
    Rsg.member!(schema, group_id, user)
    user
  end

  @doc "Group id bound to `role` in the schema (bound on first use)."
  def role_group!(schema, role) do
    case Rsg.binding(schema, role) do
      nil ->
        group = Rsg.fresh_group!(schema)
        Rsg.raw_binding!(schema, role, :platform_role, group.id)
        group.id

      binding ->
        binding.group_id
    end
  end

  @doc "Removes every group membership of the user."
  def drop_roles!(schema, user_id) do
    Repo.delete_all(from(m in GroupMember, where: m.user_id == ^user_id), prefix: schema)
  end

  @doc "Valid create attrs; `overrides` replace keys."
  def attrs(definition_name, overrides \\ %{}) do
    Map.merge(
      %{
        key: "job-" <> to_string(System.unique_integer([:positive])),
        title: "A job",
        definition_name: definition_name,
        variables: %{"batch" => "nightly"},
        interval_minutes: 60,
        anchor_at: @anchor
      },
      overrides
    )
  end

  @doc "Creates a job whose `next_run_at` is `next_run_at` (set directly); returns the job."
  def job!(schema, actor_id, definition_name, overrides \\ %{}, next_run_at \\ nil) do
    {:ok, job} = ScheduledJobs.create(schema, attrs(definition_name, overrides), actor_id)

    if next_run_at do
      {1, _} =
        Repo.update_all(
          from(j in ScheduledJobs.Job, where: j.id == ^job.id),
          [set: [next_run_at: next_run_at]],
          prefix: schema
        )
    end

    {:ok, job} = ScheduledJobs.get(schema, job.id)
    job
  end

  @doc "Instances in the tenant schema, all statuses."
  def instance_count(schema) do
    {:ok, counts} = Engine.count_instances_by_status(prefix: schema)
    counts |> Map.values() |> Enum.sum()
  end

  defp graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end
end
