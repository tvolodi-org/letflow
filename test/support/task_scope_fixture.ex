defmodule Letflow.Support.TaskScopeFixture do
  @moduledoc """
  Test-support for REQ-518 PR 2d (approver rule F1; design
  `lib/letflow/design/req518-compiler-scope-filter.md` C.1 to C.4, 10.3; spec
  `test/specs/REQ-518-2d.md`).

  `set_scope_node!/3` is a test-only writer of `tasks.scope_node_id` for rows the engine did not
  create (the production writer is `TaskActivation.insert_task_row/4`, REQ-532). It uses direct,
  parameterised SQL so that no changeset or schema path can be mistaken for one.
  The only interpolation is the schema name, quoted (INV-7).

  Everything else builds ONE committed, provisioned tenant (`provision!/1`: the REQ-517 grants
  fixture tenant plus the `ScopeSetFixture` node tree `root > a (a1, a2 retired, a2x, a3
  retired), b (b1)`, the stored mode `on`, a routing role `approver` bound to a group), real
  callers with a claimed role list, USER-level grant rows and optional routing-role membership
  (`caller!/2`), real tasks (`insert_task!/3` raw rows, `start_task!/3` through the real engine),
  and requests dispatched into `Letflow.Routers.Tasks` with the per-request mode in the context
  (`call/6`). Callers are `async: false` (committed writes, cross-connection locks).
  """

  import ExUnit.Assertions
  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.GroupMember
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeEnforcementFixture
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.Support.ScopedGrantsFixture, as: S

  @routing_role "approver"

  @type fixture :: map()
  @type caller :: %{
          required(:id) => Ecto.UUID.t(),
          required(:roles) => [String.t()],
          required(:user) => Letflow.Identity.User.t()
        }

  # ---- the only writer of the column ---------------------------------------------------------

  @doc """
  Sets (or, with `nil`, clears) the scope node of one task in the tenant schema `prefix`.
  Raises when the task does not exist or the node is unknown (the foreign key).
  """
  @spec set_scope_node!(
          task_id :: Ecto.UUID.t(),
          node_id :: String.t() | nil,
          prefix :: String.t()
        ) ::
          :ok
  def set_scope_node!(task_id, node_id, prefix)
      when is_binary(prefix) and (is_binary(node_id) or is_nil(node_id)) do
    {:ok, uuid} = Ecto.UUID.dump(task_id)

    %Postgrex.Result{num_rows: 1} =
      Repo.query!(
        ~s|UPDATE "#{quote_ident(prefix)}".tasks SET scope_node_id = $1 WHERE id = $2|,
        [node_id, uuid]
      )

    :ok
  end

  @doc "The stored `scope_node_id` of a task, read RAW (the schema field is not trusted here)."
  @spec stored_scope_node(Ecto.UUID.t(), String.t()) :: String.t() | nil
  def stored_scope_node(task_id, prefix) do
    {:ok, uuid} = Ecto.UUID.dump(task_id)

    %{rows: [[node]]} =
      Repo.query!(
        ~s|SELECT scope_node_id FROM "#{quote_ident(prefix)}".tasks WHERE id = $1|,
        [uuid]
      )

    node
  end

  defp quote_ident(prefix) do
    true = Regex.match?(~r/\A[a-z0-9_]+\z/, prefix)
    prefix
  end

  # ---- the tenant ------------------------------------------------------------------------------

  @doc "The routing role every task of this fixture is assigned to (`assignee_type` `ROLE`)."
  @spec routing_role() :: String.t()
  def routing_role, do: @routing_role

  @doc """
  One committed provisioned tenant with the node tree, the stored mode `on` and the routing role
  `approver` (a group `approvers` bound through a `process_routing_role` binding). The map holds
  `S.tenant!/1`'s keys plus `:nodes` and `:routing_group_id`.
  """
  @spec provision!(String.t()) :: fixture()
  def provision!(slug_prefix) do
    fx = S.tenant!(slug_prefix)
    :ok = F.build_tree!(fx.schema_name)
    :ok = ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, :on)

    group = RSG.fresh_group!(fx.schema_name)
    _binding = RSG.raw_binding!(fx.schema_name, @routing_role, :process_routing_role, group.id)

    fx |> Map.put(:nodes, F.nodes()) |> Map.put(:routing_group_id, group.id)
  end

  @doc "Stores `mode` in the tenant row (the next request reads it)."
  @spec store_mode!(fixture(), :off | :shadow | :on) :: :ok
  def store_mode!(fx, mode), do: ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, mode)

  # ---- callers ----------------------------------------------------------------------------------

  @doc """
  A real user and the role list it CLAIMS in the request context. Options:

    * `:roles` (default `["TASK_WORKER"]`);
    * `:grants` a list of `{role, node_key | :tenant_wide}` USER-level rows (a node key is an atom
      of `ScopeSetFixture.nodes/0`);
    * `:routing` (default `true`) whether the user is a member of the `approver` routing group.

  No row is ever written for the group of a platform role, so no role is held tenant-wide by
  accident.
  """
  @spec caller!(fixture(), keyword()) :: caller()
  def caller!(fx, opts \\ []) do
    schema = fx.schema_name
    roles = Keyword.get(opts, :roles, ["TASK_WORKER"])
    user = RSG.user!(schema)

    for {role, where} <- Keyword.get(opts, :grants, []) do
      node = if where == :tenant_wide, do: nil, else: Map.fetch!(F.nodes(), where)
      :ok = RSG.raw_user_row!(schema, user.id, role, node)
    end

    if Keyword.get(opts, :routing, true), do: add_routing_member!(fx, user)

    %{id: user.id, roles: roles, user: user}
  end

  @doc "Makes `user` a member of the routing group."
  @spec add_routing_member!(fixture(), Letflow.Identity.User.t()) :: :ok
  def add_routing_member!(fx, user) do
    Repo.insert!(%GroupMember{group_id: fx.routing_group_id, user_id: user.id},
      prefix: fx.schema_name
    )

    :ok
  end

  @doc "Replaces every USER-level grant row of `caller` for `role` by `where` (`:none` removes all)."
  @spec set_grant!(fixture(), caller(), String.t(), atom() | :tenant_wide | :none) :: :ok
  def set_grant!(fx, caller, role, where) do
    {_n, _} =
      Repo.delete_all(
        from(g in Letflow.Identity.RoleScopeGrant,
          where: g.principal_type == :user and g.principal_id == ^caller.id and g.role == ^role
        ),
        prefix: fx.schema_name
      )

    case where do
      :none -> :ok
      :tenant_wide -> RSG.raw_user_row!(fx.schema_name, caller.id, role, nil)
      key -> RSG.raw_user_row!(fx.schema_name, caller.id, role, Map.fetch!(F.nodes(), key))
    end
  end

  @doc """
  The `Letflow.Api.Scope.Principal` of `caller` built exactly as the pipeline builds it from the
  claimed roles and the database (fresh grants).
  """
  @spec principal(fixture(), caller()) :: Letflow.Api.Scope.Principal.t()
  def principal(fx, caller) do
    %Letflow.Api.Scope.Principal{
      kind: :user,
      user_id: caller.id,
      prefix: fx.schema_name,
      platform_tenant?: false,
      roles: Enum.map(caller.roles, &String.to_atom/1),
      grants: Letflow.Api.Scope.load_grants(caller.id, fx.schema_name)
    }
  end

  # ---- tasks ---------------------------------------------------------------------------------------

  @doc """
  A raw `pending` task row (instance projection and token rows inserted first, as the FKs need)
  assigned to the routing role (`assignee_type: "ROLE"`), unless `attrs` says otherwise, with the
  scope node `node` (`nil` keeps it NULL; a node key sets it through `set_scope_node!/3`).
  """
  @spec insert_task!(fixture(), atom() | nil, map()) :: EngineTask.t()
  def insert_task!(fx, node, attrs \\ %{}) do
    schema = fx.schema_name
    instance_id = Ecto.UUID.generate()

    %InstanceProjection{}
    |> InstanceProjection.insert_changeset(%{
      instance_id: instance_id,
      status: :active,
      definition_id: Ecto.UUID.generate()
    })
    |> Repo.insert!(prefix: schema)

    token =
      %TokenRecord{}
      |> TokenRecord.insert_changeset(%{
        instance_id: instance_id,
        node_id: "review",
        branch_id: "b1"
      })
      |> Repo.insert!(prefix: schema)

    default = %{
      instance_id: instance_id,
      token_id: token.id,
      node_id: "review",
      node_name: "Review",
      assignee_type: "ROLE",
      assignee_ref: @routing_role
    }

    task =
      %EngineTask{}
      |> EngineTask.insert_changeset(Map.merge(default, Map.new(attrs)))
      |> Repo.insert!(prefix: schema)

    place!(fx, task, node)
  end

  @doc """
  A pending task created through the REAL engine (`Engine.create/2` on a START > HUMAN_TASK
  (role `approver`) > END definition), so `Engine.complete_task/3` can drive it. The scope node
  is then set with `set_scope_node!/3`. With `escalation: true` the node carries an immediately
  due escalation timer (`fire_escalation!/2`).
  """
  @spec start_task!(fixture(), atom() | nil, keyword()) :: EngineTask.t()
  def start_task!(fx, node, opts \\ []) do
    schema = fx.schema_name
    ref = Keyword.get(opts, :assignee_ref, @routing_role)
    n = System.unique_integer([:positive, :monotonic])

    graph =
      if Keyword.get(opts, :escalation, false),
        do: escalation_graph(ref),
        else: plain_graph(ref)

    {:ok, definition} =
      Definitions.create(
        %{name: "r518-2d-#{n}", version: "1.0.0", graph: graph, created_by: Ecto.UUID.generate()},
        prefix: schema
      )

    {:ok, %{definition: activated}} = Definitions.activate(definition.id, prefix: schema)

    {:ok, result} =
      Engine.create(
        %{
          definition_id: activated.id,
          initial_variables: %{"seed" => "value"},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: "r518-2d-start-#{n}"
        },
        prefix: schema
      )

    task =
      Repo.one!(from(t in EngineTask, where: t.instance_id == ^result.instance_id),
        prefix: schema
      )

    place!(fx, task, node)
  end

  defp plain_graph(ref) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => ref}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  # START > orig-task (escalation timer due at once) > escalated-task > END: firing the timer
  # cancels the original task (the `task.cancel` audit writer) and activates the next one.
  defp escalation_graph(ref) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "orig-task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{
            "role" => ref,
            "escalation_timer_duration" => "P0D",
            "escalation_role" => "role-escalation"
          }
        },
        %{
          "id" => "escalated-task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "role-escalation"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "orig-task"},
        %{"id" => "e2", "source" => "orig-task", "target" => "escalated-task"},
        %{"id" => "e3", "source" => "escalated-task", "target" => "end"}
      ]
    }
  end

  @doc """
  Fires the (immediately due) escalation timer of a task created by `start_task!/3` with
  `escalation: true`: the original task is cancelled (audit action `task.cancel`).
  """
  @spec fire_escalation!(fixture(), EngineTask.t()) :: :ok
  def fire_escalation!(fx, task) do
    timer =
      Repo.one!(
        from(t in Letflow.Scheduler.Timer,
          where: t.instance_id == ^task.instance_id and t.timer_type == "escalation"
        ),
        prefix: fx.schema_name
      )

    {:ok, :fired} = Letflow.Scheduler.fire_timer(timer.id, fx.schema_name)
    :ok
  end

  defp place!(fx, task, nil), do: Repo.get!(EngineTask, task.id, prefix: fx.schema_name)

  defp place!(fx, task, node) do
    :ok = set_scope_node!(task.id, Map.fetch!(F.nodes(), node), fx.schema_name)
    Repo.get!(EngineTask, task.id, prefix: fx.schema_name)
  end

  @doc "The current task row (fresh read)."
  @spec task(fixture(), Ecto.UUID.t()) :: EngineTask.t()
  def task(fx, id), do: Repo.get!(EngineTask, id, prefix: fx.schema_name)

  @doc "Forces the status of a task row (a fixture write, as the REQ-085 tests do)."
  @spec force_status!(fixture(), EngineTask.t(), atom()) :: EngineTask.t()
  def force_status!(fx, task, status) do
    task |> Ecto.Changeset.change(%{status: status}) |> Repo.update!(prefix: fx.schema_name)
  end

  # ---- requests ----------------------------------------------------------------------------------

  @doc """
  One request into `Letflow.Routers.Tasks` (paths relative to the router: `"/inbox"`, `"/"`,
  `"/<id>/claim"`) as `caller` with the per-request enforcement `mode` in the context. The
  conn is hand-assigned (no `AuthPipeline`), so no API token row is touched.
  """
  @spec call(fixture(), caller(), atom(), String.t(), map() | nil, :off | :shadow | :on) ::
          Plug.Conn.t()
  def call(fx, caller, method, path, body \\ nil, mode \\ :on) do
    On.call(Letflow.Routers.Tasks, method, path, fx, caller.id, caller.roles, mode, body)
  end

  @doc "The decoded JSON body."
  @spec json(Plug.Conn.t()) :: term()
  def json(conn), do: Jason.decode!(conn.resp_body)

  @doc "Status, sorted response headers and the RAW body: the unit INV-5 equality compares."
  @spec wire(Plug.Conn.t()) :: {non_neg_integer(), [{String.t(), String.t()}], binary()}
  def wire(conn), do: {conn.status, Enum.sort(conn.resp_headers), conn.resp_body}

  @doc "`{conn, sql_texts}`: the SQL text of every statement `fun` ran, in order."
  @spec statements((-> Plug.Conn.t())) :: {Plug.Conn.t(), [String.t()]}
  def statements(fun) do
    {result, queries} = Fixture.capture_repo_queries(fun)
    {result, Enum.map(queries, & &1.query)}
  end

  @doc "The ids of the `items` of a list response, sorted."
  @spec ids(Plug.Conn.t()) :: [String.t()]
  def ids(conn), do: conn |> json() |> Map.fetch!("items") |> Enum.map(& &1["id"]) |> Enum.sort()

  # ---- interleaving ------------------------------------------------------------------------------

  # Holds the task row FOR UPDATE on a third connection, starts `work` on its own connection
  # (it blocks on the task-row lock of its first step), waits until it is parked on a lock,
  # runs `between` (the revocation, committed), releases the holder and returns the result.
  @spec interleave(fixture(), EngineTask.t(), (-> term()), (-> term())) :: term()
  def interleave(fx, task, work, between) do
    parent = self()
    {:ok, id} = Ecto.UUID.dump(task.id)
    sql = ~s|SELECT 1 FROM "#{fx.schema_name}".tasks WHERE id = $1 FOR UPDATE|

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!(sql, [id])
          send(parent, :held)

          receive do
            :release -> :ok
          after
            20_000 -> :timeout
          end
        end)
      end)

    assert_receive :held, 10_000

    worker =
      Task.async(fn ->
        Repo.checkout(fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:backend, pid})
          work.()
        end)
      end)

    assert_receive {:backend, backend}, 10_000
    await_parked!(backend)
    between.()
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 20_000)
    Task.await(worker, 20_000)
  end

  # Bounded poll on a monotonic deadline (not a step count): the backend waits on a lock.
  defp await_parked!(backend) do
    deadline = System.monotonic_time(:millisecond) + 10_000
    do_await_parked(backend, deadline)
  end

  defp do_await_parked(backend, deadline) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock'",
        [backend]
      )

    cond do
      rows != [] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the worker never parked on the task row lock")

      true ->
        :erlang.yield()
        do_await_parked(backend, deadline)
    end
  end

  # ---- audit ---------------------------------------------------------------------------------------

  @doc "Every audit entry whose `resource_type` is `task` (all actions), oldest first."
  @spec task_audit_entries(fixture()) :: [Letflow.Audit.Entry.t()]
  def task_audit_entries(fx) do
    Repo.all(
      from(e in Letflow.Audit.Entry, where: e.resource_type == "task", order_by: e.timestamp),
      prefix: fx.schema_name
    )
  end

  @doc "Whether a task row is assigned to `user_id` as a USER."
  @spec assigned_to?(EngineTask.t(), Ecto.UUID.t()) :: boolean()
  def assigned_to?(task, user_id),
    do: task.assignee_type == "USER" and task.assignee_ref == user_id

  @doc "Counts rows of `tasks` (committed state)."
  @spec task_count(fixture()) :: non_neg_integer()
  def task_count(fx), do: Repo.aggregate(EngineTask, :count, prefix: fx.schema_name)
end
