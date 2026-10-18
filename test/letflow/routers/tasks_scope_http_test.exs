defmodule Letflow.Routers.TasksScopeHttpTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2d, AC 13, AC 14 (visibility half), AC 20 and the unit/ledger half of
  AC 23 over the task routes (design `lib/letflow/design/req518-compiler-scope-filter.md` C.2,
  C.3, 7.1, 10.3; spec `test/specs/REQ-518-2d.md`; SEC code-gate step-24 MERGE CONDITIONS): the
  seven routes of `Letflow.Routers.Tasks` under the stored mode `on`, requests dispatched into the
  router with the per-request mode in the context (`Letflow.Support.TaskScopeFixture`).

    * T-F3 .. T-F7 (AC 13 cases a to e) on get, list, inbox, claim and complete;
    * T-F15: a scoped PROCESS_OPERATOR and a scoped TENANT_ADMIN holding grants on the node but NO
      TASK_WORKER grant are refused (404 / absent); with a covering TASK_WORKER grant allowed; a
      tenant-wide PROCESS_OPERATOR unchanged; the MIXED case (d3) scoped TASK_WORKER not covering
      the task plus a tenant-wide PROCESS_OPERATOR is EXEMPT; case (d2) a tenant-wide holder
      outside the routing role gets the EXISTING routing-role error; assign and reassign follow the
      route permission (no TASK_WORKER requirement);
    * T-L19 .. T-L25: one scoped-caller test per ledger row: each of the seven routes succeeds in
      scope (which also proves `ScopeGate` was called: the backstop would answer 500) and is refused
      out of scope;
    * no response map carries `scope_node_id` (INV-2, A-8);
    * the `on` + no-principal path never starts a transaction (SEC F-2, REVIEWER F-2).

  `async: false`: a committed provisioned tenant per test.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.Support.TaskScopeFixture, as: T

  @tw "TASK_WORKER"
  @po "PROCESS_OPERATOR"
  @ta "TENANT_ADMIN"
  @role_detail "caller does not hold the assigned role"

  setup do
    {:ok, fx: T.provision!("r518-2d-http")}
  end

  # ---- helpers -------------------------------------------------------------------------------

  defp get(fx, caller, task), do: T.call(fx, caller, :get, "/#{task.id}")
  defp list(fx, caller), do: T.call(fx, caller, :get, "/")
  defp inbox(fx, caller), do: T.call(fx, caller, :get, "/inbox")
  defp claim(fx, caller, task), do: T.call(fx, caller, :post, "/#{task.id}/claim")
  defp complete(fx, caller, task), do: T.call(fx, caller, :post, "/#{task.id}/complete", %{})

  defp assign(fx, caller, task, user_id),
    do: T.call(fx, caller, :post, "/#{task.id}/assign", %{"user_id" => user_id})

  defp reassign(fx, caller, task, user_id),
    do: T.call(fx, caller, :post, "/#{task.id}/reassign", %{"user_id" => user_id})

  defp detail(conn), do: T.json(conn)["detail"]

  # ===========================================================================================
  describe "T-F3 (a): routing role + a TASK_WORKER grant on an ancestor" do
    test "get, list, inbox, claim and complete are allowed for tasks on the grant node, a descendant, and a live node under a retired intermediate node",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      nodes = [:a, :a1, :a2x]

      tasks = for key <- nodes, do: {key, T.start_task!(fx, key)}

      for {key, task} <- tasks do
        assert get(fx, caller, task).status == 200, "get #{key}"
        assert T.json(get(fx, caller, task))["id"] == task.id
      end

      ids = Enum.map(tasks, fn {_k, task} -> task.id end)
      listed = list(fx, caller)
      assert listed.status == 200
      assert Enum.all?(ids, &(&1 in T.ids(listed)))
      assert Enum.all?(ids, &(&1 in T.ids(inbox(fx, caller))))

      [{_, first}, {_, second}, {_, third}] = tasks

      claimed = claim(fx, caller, first)
      assert claimed.status == 200, claimed.resp_body
      assert T.assigned_to?(T.task(fx, first.id), caller.id)

      for task <- [second, third] do
        done = complete(fx, caller, task)
        assert done.status == 200, done.resp_body
        assert T.task(fx, task.id).status == :completed
      end
    end
  end

  # ===========================================================================================
  describe "T-F4 (b): a TASK_WORKER grant on a sibling subtree" do
    test "get, claim and complete are the 404 of a nonexistent task; list and inbox exclude the task; nothing is written",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :b}])
      task = T.start_task!(fx, :a1)
      mine = T.insert_task!(fx, :b1)

      for conn <- [get(fx, caller, task), claim(fx, caller, task), complete(fx, caller, task)] do
        assert conn.status == 404
      end

      for conn <- [list(fx, caller), inbox(fx, caller)] do
        assert conn.status == 200
        refute task.id in T.ids(conn)
        assert mine.id in T.ids(conn)
      end

      assert T.task(fx, task.id).assignee_type == "ROLE"
      assert T.task(fx, task.id).status == :pending
    end
  end

  # ===========================================================================================
  describe "T-F5 (c): outside the routing role with a covering grant" do
    test "the EXISTING routing errors apply (claim 409, complete 403), never a 404; get is allowed; the task is not in the worker's own list",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}], routing: false)
      task = T.start_task!(fx, :a1)

      assert get(fx, caller, task).status == 200

      claimed = claim(fx, caller, task)
      assert claimed.status == 409
      assert detail(claimed) == @role_detail

      done = complete(fx, caller, task)
      assert done.status == 403
      assert detail(done) == @role_detail

      assert T.task(fx, task.id).status == :pending
      refute task.id in T.ids(list(fx, caller))
    end

    test "outside the routing role AND outside the grant is the 404, not the routing error", %{
      fx: fx
    } do
      caller = T.caller!(fx, grants: [{@tw, :a}], routing: false)
      task = T.start_task!(fx, :b)

      assert claim(fx, caller, task).status == 404
      assert complete(fx, caller, task).status == 404
      assert get(fx, caller, task).status == 404
    end
  end

  # ===========================================================================================
  describe "T-F6 (d): a tenant-wide TASK_WORKER in the routing role" do
    test "gets and acts on tasks of every node, including a task without a node", %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :tenant_wide}])

      for key <- [:a1, :b, :root, :a3, nil] do
        task = T.insert_task!(fx, key)
        assert get(fx, caller, task).status == 200, "get #{inspect(key)}"
        assert task.id in T.ids(list(fx, caller)), "list #{inspect(key)}"
        assert task.id in T.ids(inbox(fx, caller)), "inbox #{inspect(key)}"
        assert claim(fx, caller, task).status == 200, "claim #{inspect(key)}"
      end

      done = T.start_task!(fx, :b)
      assert complete(fx, caller, done).status == 200
    end
  end

  # ===========================================================================================
  describe "T-F7 (e): a task without a scope node" do
    test "is invisible to a scoped caller on every route and visible to a tenant-wide one", %{
      fx: fx
    } do
      scoped = T.caller!(fx, grants: [{@tw, :a}])
      wide = T.caller!(fx, grants: [{@tw, :tenant_wide}])
      task = T.start_task!(fx, nil)
      assert T.stored_scope_node(task.id, fx.schema_name) == nil

      assert get(fx, scoped, task).status == 404
      assert claim(fx, scoped, task).status == 404
      assert complete(fx, scoped, task).status == 404
      refute task.id in T.ids(list(fx, scoped))
      refute task.id in T.ids(inbox(fx, scoped))
      assert T.task(fx, task.id).status == :pending

      assert get(fx, wide, task).status == 200
      assert task.id in T.ids(list(fx, wide))
      assert complete(fx, wide, task).status == 200
    end
  end

  # ===========================================================================================
  describe "T-F15 (G1): the grant must be a TASK_WORKER grant" do
    test "a scoped PROCESS_OPERATOR and a scoped TENANT_ADMIN with grants on the node but NO TASK_WORKER grant are refused on get, list, inbox, claim and complete",
         %{fx: fx} do
      for role <- [@po, @ta] do
        caller = T.caller!(fx, roles: [role], grants: [{role, :a}])
        task = T.start_task!(fx, :a1)

        assert get(fx, caller, task).status == 404, "#{role} get"
        assert claim(fx, caller, task).status == 404, "#{role} claim"
        assert complete(fx, caller, task).status == 404, "#{role} complete"

        for conn <- [list(fx, caller), inbox(fx, caller)] do
          assert conn.status == 200
          assert T.ids(conn) == [], "#{role}: the task is absent"
        end

        assert T.task(fx, task.id).status == :pending
        assert T.task(fx, task.id).assignee_type == "ROLE"
      end
    end

    test "the same callers WITH a covering TASK_WORKER grant are allowed", %{fx: fx} do
      for role <- [@po, @ta] do
        caller = T.caller!(fx, roles: [role, @tw], grants: [{role, :a}, {@tw, :a}])
        task = T.start_task!(fx, :a1)

        assert get(fx, caller, task).status == 200, "#{role} get"
        assert task.id in T.ids(list(fx, caller))
        assert claim(fx, caller, task).status == 200, "#{role} claim"
        assert complete(fx, caller, T.start_task!(fx, :a1)).status == 200, "#{role} complete"
      end
    end

    test "a TASK_WORKER grant on a different node does not help (the grants of one role never widen another)",
         %{fx: fx} do
      caller = T.caller!(fx, roles: [@po, @tw], grants: [{@po, :a}, {@tw, :b}])
      task = T.insert_task!(fx, :a1)

      assert get(fx, caller, task).status == 404
      assert claim(fx, caller, task).status == 404
    end

    test "a TENANT-WIDE PROCESS_OPERATOR is unchanged: every node, a NULL node, every route",
         %{fx: fx} do
      caller = T.caller!(fx, roles: [@po], grants: [{@po, :tenant_wide}])

      for key <- [:a1, :b, nil] do
        task = T.insert_task!(fx, key)
        assert get(fx, caller, task).status == 200
        assert task.id in T.ids(list(fx, caller))
        assert task.id in T.ids(inbox(fx, caller))
        assert claim(fx, caller, task).status == 200
      end

      assert complete(fx, caller, T.start_task!(fx, :b)).status == 200
    end

    test "case (d2): a tenant-wide holder OUTSIDE the routing role gets the EXISTING routing-role error (claim 409, complete 403), not a 404",
         %{fx: fx} do
      caller = T.caller!(fx, roles: [@po], grants: [{@po, :tenant_wide}], routing: false)
      task = T.start_task!(fx, :a1)

      assert get(fx, caller, task).status == 200

      claimed = claim(fx, caller, task)
      assert claimed.status == 409
      assert detail(claimed) == @role_detail

      done = complete(fx, caller, task)
      assert done.status == 403
      assert detail(done) == @role_detail

      assert T.task(fx, task.id).status == :pending
    end

    test "case (d3) MIXED: a scoped TASK_WORKER NOT covering the task plus a tenant-wide PROCESS_OPERATOR is EXEMPT on get, list, inbox, claim and complete (subject to the routing role)",
         %{fx: fx} do
      mixed = T.caller!(fx, roles: [@tw, @po], grants: [{@tw, :b}, {@po, :tenant_wide}])
      task = T.start_task!(fx, :a1)
      null_task = T.insert_task!(fx, nil)

      assert get(fx, mixed, task).status == 200
      assert get(fx, mixed, null_task).status == 200
      assert task.id in T.ids(list(fx, mixed))
      assert task.id in T.ids(inbox(fx, mixed))
      assert claim(fx, mixed, null_task).status == 200
      assert complete(fx, mixed, task).status == 200

      # the routing-role checks stay in force for the exempt principal
      outside =
        T.caller!(fx, roles: [@tw, @po], grants: [{@tw, :b}, {@po, :tenant_wide}], routing: false)

      other = T.start_task!(fx, :a1)
      assert claim(fx, outside, other).status == 409
      assert complete(fx, outside, other).status == 403
    end
  end

  # ===========================================================================================
  describe "assign and reassign follow the ROUTE permission (design C.3), no TASK_WORKER requirement" do
    test "a scoped PROCESS_OPERATOR and TENANT_ADMIN assign and reassign tasks in scope and get the 404 outside it; a NULL-node task is out of scope",
         %{fx: fx} do
      target = T.caller!(fx, roles: [@tw], routing: false)

      for role <- [@po, @ta] do
        caller = T.caller!(fx, roles: [role], grants: [{role, :a}], routing: false)

        free_in = T.insert_task!(fx, :a1, %{assignee_type: nil, assignee_ref: nil})
        free_out = T.insert_task!(fx, :b, %{assignee_type: nil, assignee_ref: nil})
        free_null = T.insert_task!(fx, nil, %{assignee_type: nil, assignee_ref: nil})

        done = assign(fx, caller, free_in, target.id)
        assert done.status == 200, "#{role}: #{done.resp_body}"
        assert T.assigned_to?(T.task(fx, free_in.id), target.id)

        for refused <- [free_out, free_null] do
          conn = assign(fx, caller, refused, target.id)
          assert conn.status == 404, "#{role} assign out of scope"
          assert T.task(fx, refused.id).assignee_ref == nil
        end

        assert reassign(fx, caller, free_in, caller.id).status == 200, "#{role} reassign in scope"
        assert T.assigned_to?(T.task(fx, free_in.id), caller.id)

        owned_out = T.insert_task!(fx, :b)
        assert reassign(fx, caller, owned_out, target.id).status == 404
        assert T.task(fx, owned_out.id).assignee_type == "ROLE"
      end
    end

    test "a tenant-wide PROCESS_OPERATOR assigns every task including a NULL-node task; a scoped one with a grant on another subtree does not",
         %{fx: fx} do
      target = T.caller!(fx, roles: [@tw], routing: false)
      wide = T.caller!(fx, roles: [@po], grants: [{@po, :tenant_wide}], routing: false)
      elsewhere = T.caller!(fx, roles: [@po], grants: [{@po, :b}], routing: false)

      for key <- [:a1, nil] do
        task = T.insert_task!(fx, key, %{assignee_type: nil, assignee_ref: nil})
        assert assign(fx, elsewhere, task, target.id).status == 404
        assert assign(fx, wide, task, target.id).status == 200
      end
    end

    test "a scoped TASK_WORKER does not hold the assign permission at all (403 from the coarse check, before any scope read)",
         %{fx: fx} do
      worker = T.caller!(fx, grants: [{@tw, :a}])
      task = T.insert_task!(fx, :a1, %{assignee_type: nil, assignee_ref: nil})

      assert assign(fx, worker, task, worker.id).status == 403
      assert reassign(fx, worker, task, worker.id).status == 403
    end
  end

  # ===========================================================================================
  describe "T-L19 to T-L25: one scoped-caller test per ledger row (the handler applied the scope)" do
    test "all seven routes: success in scope (the marker is set, else the backstop answers 500) and refusal out of scope",
         %{fx: fx} do
      worker = T.caller!(fx, grants: [{@tw, :a}])
      operator = T.caller!(fx, roles: [@po], grants: [{@po, :a}], routing: false)

      in_task = T.insert_task!(fx, :a1)
      out_task = T.insert_task!(fx, :b)
      free_in = T.insert_task!(fx, :a1, %{assignee_type: nil, assignee_ref: nil})
      free_out = T.insert_task!(fx, :b, %{assignee_type: nil, assignee_ref: nil})

      # T2 GET /tasks, T1 GET /tasks/inbox (the :filter routes)
      for conn <- [list(fx, worker), inbox(fx, worker)] do
        assert conn.status == 200
        assert in_task.id in T.ids(conn)
        refute out_task.id in T.ids(conn)
      end

      # T3 GET /tasks/:id
      assert get(fx, worker, in_task).status == 200
      assert get(fx, worker, out_task).status == 404

      # T5 claim, T4 complete
      assert claim(fx, worker, in_task).status == 200
      assert claim(fx, worker, out_task).status == 404
      assert complete(fx, worker, T.start_task!(fx, :a1)).status == 200
      assert complete(fx, worker, T.start_task!(fx, :b)).status == 404

      # T6 assign, T7 reassign
      assert assign(fx, operator, free_in, worker.id).status == 200
      assert assign(fx, operator, free_out, worker.id).status == 404
      assert reassign(fx, operator, free_in, operator.id).status == 200
      assert reassign(fx, operator, out_task, operator.id).status == 404
    end
  end

  # ===========================================================================================
  describe "no response carries scope_node_id (INV-2, A-8)" do
    test "get, list, inbox, claim and complete bodies hold exactly the documented keys and never the column or the node id",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      node = F.nodes().a1
      task = T.start_task!(fx, :a1)
      second = T.start_task!(fx, :a1)
      third = T.insert_task!(fx, :a1)

      list_keys =
        ~w(assignee_ref assignee_type created_at form_id form_version id instance_id node_id node_name status token_id)

      detail_conn = get(fx, caller, task)
      assert T.json(detail_conn) |> Map.keys() |> length() == 14

      assert (T.json(detail_conn) |> Map.keys() |> Enum.sort()) -- list_keys == [
               "correlation_key",
               "form_schema",
               "updated_at"
             ]

      for conn <- [list(fx, caller), inbox(fx, caller)] do
        for item <- T.json(conn)["items"], do: assert(Enum.sort(Map.keys(item)) == list_keys)
      end

      responses = [
        detail_conn,
        list(fx, caller),
        inbox(fx, caller),
        claim(fx, caller, third),
        complete(fx, caller, second)
      ]

      for conn <- responses do
        assert conn.status == 200
        refute conn.resp_body =~ "scope_node_id"
        refute conn.resp_body =~ node
        refute conn.resp_body =~ "sf-"
      end
    end
  end

  # ===========================================================================================
  describe "SEC F-2 / REVIEWER F-2: the `on` path without a principal never starts a transaction" do
    test "claim and complete with no user in the context are never 2xx, run no task row lock and change nothing",
         %{fx: fx} do
      task = T.start_task!(fx, :a1)

      no_user = fn method, path ->
        ctx = %{tenant_id: fx.tenant_id, roles: [@tw], credential: :oidc, scope_enforcement: :on}

        Plug.Test.conn(method, path)
        |> Plug.Conn.assign(:auth_context, ctx)
        |> Plug.Conn.assign(:trace_id, "no-principal-trace")
        |> Letflow.Routers.Tasks.call(Letflow.Routers.Tasks.init([]))
      end

      for {method, path} <- [{:post, "/#{task.id}/claim"}, {:post, "/#{task.id}/complete"}] do
        {outcome, sql} =
          T.statements(fn ->
            try do
              no_user.(method, path)
            rescue
              e -> {:raised, e.__struct__}
            catch
              kind, _ -> {:thrown, kind}
            end
          end)

        case outcome do
          %Plug.Conn{status: status} -> assert status not in 200..299, path
          other -> assert match?({_, _}, other)
        end

        refute Enum.any?(sql, &(&1 =~ ~r/"tasks".*FOR UPDATE/s)), "#{path} locked the task row"
        assert T.task(fx, task.id).status == :pending
        assert T.task(fx, task.id).assignee_type == "ROLE"
      end
    end
  end
end
