defmodule Letflow.SodSupport do
  @moduledoc """
  Shared fixtures for the REQ-463 separation-of-duties tests (`distinct_from`):
  `test/letflow/engine_distinct_from_test.exs`,
  `test/letflow/engine_distinct_from_concurrency_test.exs` and
  `test/letflow/routers/tasks_distinct_from_test.exs`.

  Real Postgres, no mocks. Every case provisions its own tenant (unique slug) and its own
  users, so nothing is shared between tests. No helper here takes an optional argument
  (anti-patterns ISS-0069). Plain pattern matches are used instead of ExUnit `assert`
  so the module needs no ExUnit import: a failed match raises `MatchError`, failing the
  calling test just as loudly.

  The node ids are deliberately distinctive (`first-review`, `second-review`, ...) so a
  grep of a response body or a log line for a node id cannot match by accident.

  See `test/specs/REQ-463.md`.
  """

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Identity fixtures
  # ---------------------------------------------------------------------------------

  @spec unique(String.t()) :: String.t()
  def unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  @doc "A provisioned tenant: `%{tenant_id, schema_name, slug}`."
  @spec tenant!() :: %{tenant_id: String.t(), schema_name: String.t(), slug: String.t()}
  def tenant! do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "req463",
        display_name: "REQ-463 Separation Of Duties Test Tenant"
      )

    %Tenant{slug: slug} = Repo.get!(Tenant, tenant_id)
    %{tenant_id: tenant_id, schema_name: schema_name, slug: slug}
  end

  @doc "A user with a unique, greppable email, display name and username."
  @spec insert_user!(String.t(), String.t()) :: struct()
  def insert_user!(schema_name, label) do
    n = System.unique_integer([:positive])

    %User{}
    |> Ecto.Changeset.change(%{
      username: "sod-username-#{label}-#{n}",
      display_name: "Sod Display #{label} #{n}",
      email: "sod-email-#{label}-#{n}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema_name)
  end

  @doc """
  Makes every user in `user_ids` hold the process-routing role `role_name`: one group,
  one `TenantRole` row bound to it (role names are unique per tenant schema), one
  `GroupMember` row per user.
  """
  @spec grant_role!(String.t(), String.t(), [String.t()]) :: :ok
  def grant_role!(schema_name, role_name, user_ids) do
    group =
      %Group{}
      |> Ecto.Changeset.change(%{name: unique("sod-group"), display_name: "Sod Group"})
      |> Repo.insert!(prefix: schema_name)

    %TenantRole{}
    |> Ecto.Changeset.change(%{
      name: role_name,
      kind: :process_routing_role,
      group_id: group.id
    })
    |> Repo.insert!(prefix: schema_name)

    for user_id <- user_ids do
      %GroupMember{}
      |> Ecto.Changeset.change(%{group_id: group.id, user_id: user_id})
      |> Repo.insert!(prefix: schema_name)
    end

    :ok
  end

  # ---------------------------------------------------------------------------------
  # Graph builders
  # ---------------------------------------------------------------------------------

  @n1 "first-review"
  @n2 "second-review"

  @spec n1() :: String.t()
  def n1, do: @n1

  @spec n2() :: String.t()
  def n2, do: @n2

  @spec human(String.t(), String.t(), map()) :: map()
  def human(id, role, extra_attrs) do
    %{
      "id" => id,
      "node_type" => "HUMAN_TASK",
      "attributes" => Map.merge(%{"role" => role}, extra_attrs)
    }
  end

  @doc """
  START -> `first-review` (role-a) -> `second-review` (role-b, `n2_attrs` merged in) -> END.
  """
  @spec seq_graph(map()) :: map()
  def seq_graph(n2_attrs) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        human(@n1, "role-a", %{}),
        human(@n2, "role-b", n2_attrs),
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => @n1},
        %{"id" => "e2", "source" => @n1, "target" => @n2},
        %{"id" => "e3", "source" => @n2, "target" => "end"}
      ]
    }
  end

  @doc """
  START -> split (PARALLEL) -> `branch-one` / `branch-two` / `branch-three` -> join -> END,
  all three on role `role-p`; each names the OTHER two in `distinct_from`.
  """
  @spec parallel_graph() :: map()
  def parallel_graph do
    ids = ["branch-one", "branch-two", "branch-three"]

    %{
      "nodes" =>
        [
          %{"id" => "start", "node_type" => "START"},
          %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"}
        ] ++
          Enum.map(ids, fn id -> human(id, "role-p", %{"distinct_from" => ids -- [id]}) end) ++
          [
            %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
            %{"id" => "end", "node_type" => "END"}
          ],
      "edges" =>
        [%{"id" => "e0", "source" => "start", "target" => "split"}] ++
          Enum.map(ids, fn id -> %{"id" => "s-#{id}", "source" => "split", "target" => id} end) ++
          Enum.map(ids, fn id -> %{"id" => "j-#{id}", "source" => id, "target" => "join"} end) ++
          [%{"id" => "e9", "source" => "join", "target" => "end"}]
    }
  end

  @doc """
  START -> `first-review` (role-a) -> `triage-review` (role-t) -> gw1 -> (`variables.again == "yes"`
  back to `first-review`, else) `second-review` (role-b, `distinct_from [first-review]`) -> gw2 ->
  (`variables.redo == "yes"` back to `first-review`, else) END. Rework loops, so every pass
  through a node creates a NEW task row. The loop deliberately passes through a DIFFERENT
  node (`triage-review`, or `second-review` for the redo loop): a token looping straight back to the
  node it just completed is not re-activated as a new task by the engine (observed while writing
  these tests; out of REQ-463's scope). Fixed by GH #2359 -- the direct loop is now covered by
  `test/letflow/engine/gh2359_gateway_reentry_task_row_test.exs`; this graph keeps its detour
  because it predates the fix.
  """
  @spec rework_graph() :: map()
  def rework_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        human(@n1, "role-a", %{}),
        human("triage-review", "role-t", %{}),
        %{"id" => "gw1", "node_type" => "EXCLUSIVE_GATEWAY"},
        human(@n2, "role-b", %{"distinct_from" => [@n1]}),
        %{"id" => "gw2", "node_type" => "EXCLUSIVE_GATEWAY"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => @n1},
        %{"id" => "e1b", "source" => @n1, "target" => "triage-review"},
        %{"id" => "e2", "source" => "triage-review", "target" => "gw1"},
        %{
          "id" => "e3",
          "source" => "gw1",
          "target" => @n1,
          "condition" => "variables.again == \"yes\""
        },
        %{"id" => "e4", "source" => "gw1", "target" => @n2, "is_default" => true},
        %{"id" => "e5", "source" => @n2, "target" => "gw2"},
        %{
          "id" => "e6",
          "source" => "gw2",
          "target" => @n1,
          "condition" => "variables.redo == \"yes\""
        },
        %{"id" => "e7", "source" => "gw2", "target" => "end", "is_default" => true}
      ]
    }
  end

  @doc """
  START -> `first-review` (role-a) -> `second-review` (role-b) -> `third-review` (role-c,
  `distinct_from` = `n3_names`) -> END.
  """
  @spec chain_graph([String.t()]) :: map()
  def chain_graph(n3_names) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        human(@n1, "role-a", %{}),
        human(@n2, "role-b", %{}),
        human("third-review", "role-c", %{"distinct_from" => n3_names}),
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => @n1},
        %{"id" => "e2", "source" => @n1, "target" => @n2},
        %{"id" => "e3", "source" => @n2, "target" => "third-review"},
        %{"id" => "e4", "source" => "third-review", "target" => "end"}
      ]
    }
  end

  # ---------------------------------------------------------------------------------
  # Definition / instance / task helpers
  # ---------------------------------------------------------------------------------

  @doc """
  Creates, registers the `variable_schemas` (`%{key => json_schema}`, may be empty) and
  activates a definition. REQ-461 check 2: a `required_outputs` key needs its schema
  registered BEFORE activation.
  """
  @spec activate!(String.t(), map(), map()) :: struct()
  def activate!(schema_name, graph, schemas) do
    {:ok, definition} =
      Definitions.create(
        %{
          name: unique("req463-def"),
          version: "1.0.0",
          graph: graph,
          created_by: Ecto.UUID.generate()
        },
        prefix: schema_name
      )

    if schemas != %{} do
      entries =
        for {key, json_schema} <- schemas, do: %{variable_key: key, json_schema: json_schema}

      {:ok, _count} =
        Definitions.register_variable_schemas(definition.id, entries, prefix: schema_name)
    end

    {:ok, %{definition: activated}} = Definitions.activate(definition.id, prefix: schema_name)
    activated
  end

  @spec start_instance!(String.t(), struct(), map()) :: String.t()
  def start_instance!(schema_name, definition, initial_variables) do
    {:ok, created} =
      Engine.create(
        %{
          definition_id: definition.id,
          initial_variables: initial_variables,
          actor_id: Ecto.UUID.generate(),
          idempotency_key: unique("req463-start")
        },
        prefix: schema_name
      )

    created.instance_id
  end

  @doc "A fresh tenant, an activated definition and one started instance: the case context."
  @spec new_case!(map(), map(), map()) :: map()
  def new_case!(graph, schemas, initial_variables) do
    tenant = tenant!()
    definition = activate!(tenant.schema_name, graph, schemas)
    instance_id = start_instance!(tenant.schema_name, definition, initial_variables)
    Map.merge(tenant, %{definition: definition, instance_id: instance_id})
  end

  @doc "The single PENDING task row of `node_id` in the case's instance."
  @spec pending_task!(map(), String.t()) :: EngineTask.t()
  def pending_task!(ctx, node_id) do
    [task] =
      EngineTask
      |> where(
        [t],
        t.instance_id == ^ctx.instance_id and t.node_id == ^node_id and t.status == :pending
      )
      |> Repo.all(prefix: ctx.schema_name)

    task
  end

  @spec reload_task!(map(), EngineTask.t()) :: EngineTask.t()
  def reload_task!(ctx, task), do: Repo.get!(EngineTask, task.id, prefix: ctx.schema_name)

  @doc "`Engine.complete_task/3` as `actor_id` (the raw result, no match)."
  @spec complete(map(), EngineTask.t(), String.t(), map()) :: term()
  def complete(ctx, task, actor_id, output) do
    Engine.complete_task(
      task.id,
      %{output_variables: output, actor_id: actor_id, idempotency_key: unique("req463-complete")},
      prefix: ctx.schema_name
    )
  end

  @doc "Completes the pending task of `node_id` as `actor_id`; it must be accepted."
  @spec complete_node!(map(), String.t(), String.t(), map()) :: map()
  def complete_node!(ctx, node_id, actor_id, output) do
    {:ok, result} = complete(ctx, pending_task!(ctx, node_id), actor_id, output)
    result
  end

  # ---------------------------------------------------------------------------------
  # Row snapshots and audit
  # ---------------------------------------------------------------------------------

  @doc """
  Every row a refused completion must leave byte-for-byte alone, INCLUDING `updated_at`:
  the instance projection (variables, join counters), every token, every task row of the
  instance, the event count and every timer row of the instance (an armed escalation timer
  keeps its `fire_at`).
  """
  @spec rows(map()) :: map()
  def rows(ctx) do
    %{
      projection: Repo.get!(InstanceProjection, ctx.instance_id, prefix: ctx.schema_name),
      tokens:
        TokenRecord
        |> where([t], t.instance_id == ^ctx.instance_id)
        |> order_by([t], t.id)
        |> Repo.all(prefix: ctx.schema_name),
      tasks:
        EngineTask
        |> where([t], t.instance_id == ^ctx.instance_id)
        |> order_by([t], t.id)
        |> Repo.all(prefix: ctx.schema_name),
      event_count:
        Repo.aggregate(from(e in Event, where: e.instance_id == ^ctx.instance_id), :count,
          prefix: ctx.schema_name
        ),
      timers:
        Timer
        |> where([t], t.instance_id == ^ctx.instance_id)
        |> order_by([t], t.id)
        |> Repo.all(prefix: ctx.schema_name)
    }
  end

  @spec refusal_rows(String.t()) :: [struct()]
  def refusal_rows(schema_name) do
    Letflow.Audit.Entry
    |> where([a], a.action == "task.completion_refused")
    |> Repo.all(prefix: schema_name)
  end

  @spec audit_count(String.t()) :: non_neg_integer()
  def audit_count(schema_name),
    do: Repo.aggregate(Letflow.Audit.Entry, :count, prefix: schema_name)
end
