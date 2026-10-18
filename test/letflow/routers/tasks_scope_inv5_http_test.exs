defmodule Letflow.Routers.TasksScopeInv5HttpTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2d, AC 14, AC 15, AC 16 and INV-5 over the task routes (design
  `lib/letflow/design/req518-compiler-scope-filter.md` C.2, C.4, 10.3; spec
  `test/specs/REQ-518-2d.md`; SEC code-gate step-24 MERGE CONDITIONS):

    * T-F8 / INV-5 on ALL SEVEN routes: for a scoped caller an out-of-scope task answers exactly
      like a nonexistent task id: the same status, the same header set, the same RAW body bytes and
      the same SQL statement sequence (hence count). get, claim and complete; assign and reassign
      for BOTH an invalid body (the validation answer, whatever the id) and a valid body (404);
      out-of-scope keys: a sibling subtree, the shared root, a retired leaf, a retired
      intermediate node, a NULL node and a NON-pending task (a 409 must not leak);
    * T-F9 / T-F11 / AC 15: claim in scope, revoke the grant, complete: the 404-equivalent, and
      end-to-end through the router with a REAL revocation between the task row lock and the
      recheck; the refused paths take no task row lock before the scope gate and no new lock mode;
    * T-F10 / AC 14: list and inbox exclude out-of-subtree and NULL-node tasks, `count` and cursor
      pages exclude them, the cursor holds no node id, a later page applies the CURRENT scope, and
      the composition with the assignee row scope (and the `status` / `instance_id` filters) is the
      intersection;
    * T-F14 / AC 16: `off` and `shadow` are byte-identical to each other, scope-free (an
      out-of-scope task is served), and issue NO F1 statement (no grants, no node-tree read, no
      `scope_node_id` predicate).

  `async: false`: a committed provisioned tenant per test, cross-connection locks. No statement
  count crosses a token-user request (hand-built context, no `last_used_at` write), so the
  second-boundary flake of #2729 cannot occur.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Support.TaskScopeFixture, as: T

  @tw "TASK_WORKER"
  @po "PROCESS_OPERATOR"

  setup do
    {:ok, fx: T.provision!("r518-2d-inv5")}
  end

  # ---- helpers -------------------------------------------------------------------------------

  defp request(fx, caller, method, path, body \\ nil, mode \\ :on) do
    {conn, sql} = T.statements(fn -> T.call(fx, caller, method, path, body, mode) end)
    {conn, sql}
  end

  # Out-of-scope keys for a caller whose grant is on subtree `a`. Each entry builds a task
  # (pending, assigned to the routing role, so only the SCOPE differs from a nonexistent id).
  defp out_of_scope_tasks(fx) do
    [
      {"sibling subtree", T.insert_task!(fx, :b)},
      {"descendant of a sibling", T.insert_task!(fx, :b1)},
      {"shared root", T.insert_task!(fx, :root)},
      {"retired leaf", T.insert_task!(fx, :a3)},
      {"retired intermediate", T.insert_task!(fx, :a2)},
      {"NULL node", T.insert_task!(fx, nil)},
      {"non-pending (completed) out of scope",
       fx |> T.insert_task!(:b) |> then(&T.force_status!(fx, &1, :completed))},
      {"non-pending (cancelled) with a NULL node",
       fx |> T.insert_task!(nil) |> then(&T.force_status!(fx, &1, :cancelled))}
    ]
  end

  defp assert_same_as_nonexistent(fx, caller, method, path_fun, body, expected_status) do
    ghost = Ecto.UUID.generate()

    # the first request pays one-off statements (warm-up); measure the second pair
    _warm = request(fx, caller, method, path_fun.(ghost), body)
    {ghost_conn, ghost_sql} = request(fx, caller, method, path_fun.(ghost), body)
    assert ghost_conn.status == expected_status, ghost_conn.resp_body
    assert ghost_sql != [], "the capture is live"

    tasks = out_of_scope_tasks(fx)
    before = Map.new(tasks, fn {_label, task} -> {task.id, T.task(fx, task.id)} end)

    for {label, task} <- tasks do
      {conn, sql} = request(fx, caller, method, path_fun.(task.id), body)

      assert T.wire(conn) == T.wire(ghost_conn),
             "#{label}: status/headers/body differ from a nonexistent id"

      assert sql == ghost_sql, "#{label}: the SQL statement sequence differs"
      refute conn.resp_body =~ task.id, "#{label}: the id is echoed"
    end

    # nothing was written by any refused request: every row is exactly as it was
    for {_label, task} <- tasks do
      assert T.task(fx, task.id) == Map.fetch!(before, task.id)
    end
  end

  # ===========================================================================================
  describe "T-F8 INV-5: out of scope is a nonexistent id on all seven routes" do
    test "get, claim and complete: identical status, headers, raw body and statements for a scoped TASK_WORKER",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])

      assert_same_as_nonexistent(fx, caller, :get, &"/#{&1}", nil, 404)
      assert_same_as_nonexistent(fx, caller, :post, &"/#{&1}/claim", nil, 404)
      assert_same_as_nonexistent(fx, caller, :post, &"/#{&1}/complete", %{}, 404)
    end

    test "the same holds for callers whose TASK_WORKER set is :none (no grant row; scoped PROCESS_OPERATOR or TENANT_ADMIN without a TASK_WORKER grant)",
         %{fx: fx} do
      rowless = T.caller!(fx, roles: [@tw])
      po = T.caller!(fx, roles: [@po], grants: [{@po, :a}])
      ta = T.caller!(fx, roles: ["TENANT_ADMIN"], grants: [{"TENANT_ADMIN", :a}])

      for caller <- [rowless, po, ta] do
        assert_same_as_nonexistent(fx, caller, :get, &"/#{&1}", nil, 404)
        assert_same_as_nonexistent(fx, caller, :post, &"/#{&1}/claim", nil, 404)
        assert_same_as_nonexistent(fx, caller, :post, &"/#{&1}/complete", %{}, 404)
      end

      # a task in the caller's own subtree is NOT the nonexistent answer for a covered caller
      covered = T.caller!(fx, grants: [{@tw, :a}])
      inside = T.insert_task!(fx, :a1)
      {conn, _sql} = request(fx, covered, :get, "/#{inside.id}")
      assert conn.status == 200
    end

    test "assign and reassign with an INVALID body: out of scope, nonexistent and in scope all answer the validation problem",
         %{fx: fx} do
      operator = T.caller!(fx, roles: [@po], grants: [{@po, :a}], routing: false)
      inside = T.insert_task!(fx, :a1, %{assignee_type: nil, assignee_ref: nil})

      for route <- ["assign", "reassign"] do
        path = fn id -> "/#{id}/#{route}" end
        ghost = Ecto.UUID.generate()
        _warm = request(fx, operator, :post, path.(ghost), %{})
        {ghost_conn, ghost_sql} = request(fx, operator, :post, path.(ghost), %{})

        assert ghost_conn.status in [400, 422], "#{route}: #{ghost_conn.resp_body}"

        for {label, task} <- [{"in scope", inside} | out_of_scope_tasks(fx)] do
          {conn, sql} = request(fx, operator, :post, path.(task.id), %{})
          assert T.wire(conn) == T.wire(ghost_conn), "#{route} #{label}"
          assert sql == ghost_sql, "#{route} #{label}: statements"
        end
      end
    end

    test "assign and reassign with a VALID body: out of scope equals nonexistent (404, same bytes, same statements)",
         %{fx: fx} do
      operator = T.caller!(fx, roles: [@po], grants: [{@po, :a}], routing: false)
      target = T.caller!(fx, roles: [@tw], routing: false)

      for route <- ["assign", "reassign"] do
        assert_same_as_nonexistent(
          fx,
          operator,
          :post,
          &"/#{&1}/#{route}",
          %{"user_id" => target.id},
          404
        )
      end

      # unassigned out-of-scope tasks stay unassigned (the nothing-written check, assign's shape)
      free = T.insert_task!(fx, :b, %{assignee_type: nil, assignee_ref: nil})
      {conn, _} = request(fx, operator, :post, "/#{free.id}/assign", %{"user_id" => target.id})
      assert conn.status == 404
      assert T.task(fx, free.id).assignee_ref == nil
    end

    test "an in-scope task outside the routing role is NOT the 404: the existing errors are unchanged (claim 409, complete 403)",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}], routing: false)
      inside = T.start_task!(fx, :a1)

      {claimed, _} = request(fx, caller, :post, "/#{inside.id}/claim")
      {done, _} = request(fx, caller, :post, "/#{inside.id}/complete", %{})
      assert claimed.status == 409
      assert done.status == 403
    end
  end

  # ===========================================================================================
  describe "T-F9 / T-F11 / AC 15: revocation" do
    test "claim in scope, REVOKE the grant, complete: the 404-equivalent; the claim stays; no task row lock is taken",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      task = T.start_task!(fx, :a1)

      {claimed, _} = request(fx, caller, :post, "/#{task.id}/claim")
      assert claimed.status == 200
      assert T.assigned_to?(T.task(fx, task.id), caller.id)

      :ok = T.set_grant!(fx, caller, @tw, :none)

      {ghost, _} = request(fx, caller, :post, "/#{Ecto.UUID.generate()}/complete", %{})
      {refused, sql} = request(fx, caller, :post, "/#{task.id}/complete", %{})

      assert refused.status == 404
      assert T.wire(refused) == T.wire(ghost)
      assert T.task(fx, task.id).status == :pending
      assert T.assigned_to?(T.task(fx, task.id), caller.id)

      # refused before the transaction: no row lock, no advisory lock at all
      refute Enum.any?(sql, &(&1 =~ ~r/FOR (NO KEY )?(UPDATE|SHARE)|pg_advisory/i))
    end

    test "a grant moved to another subtree flips the same request from 200 to 404 on the NEXT request (no cache)",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      task = T.insert_task!(fx, :a1)

      {before, _} = request(fx, caller, :get, "/#{task.id}")
      :ok = T.set_grant!(fx, caller, @tw, :b)
      {after_move, _} = request(fx, caller, :get, "/#{task.id}")
      :ok = T.set_grant!(fx, caller, @tw, :a)
      {restored, _} = request(fx, caller, :get, "/#{task.id}")

      assert {before.status, after_move.status, restored.status} == {200, 404, 200}
    end

    test "END TO END: grant revoked while the request waits for the task lock in Engine.complete_task: 404, same bytes as nonexistent",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      task = T.start_task!(fx, :a1)

      {ghost, _} = request(fx, caller, :post, "/#{Ecto.UUID.generate()}/complete", %{})

      conn =
        T.interleave(
          fx,
          task,
          fn -> T.call(fx, caller, :post, "/#{task.id}/complete", %{}) end,
          fn -> :ok = T.set_grant!(fx, caller, @tw, :none) end
        )

      assert conn.status == 404
      assert T.wire(conn) == T.wire(ghost)
      assert T.task(fx, task.id).status == :pending
    end

    test "END TO END control: the same interleaving without a revocation completes (the 404 above is the recheck, not the lock wait)",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      task = T.start_task!(fx, :a1)

      conn =
        T.interleave(
          fx,
          task,
          fn -> T.call(fx, caller, :post, "/#{task.id}/complete", %{}) end,
          fn ->
            :ok
          end
        )

      assert conn.status == 200
      assert T.task(fx, task.id).status == :completed
    end

    test "END TO END claim: the grant is revoked while the claim waits for the task row lock: 404, not assigned",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      task = T.insert_task!(fx, :a1)

      conn =
        T.interleave(
          fx,
          task,
          fn -> T.call(fx, caller, :post, "/#{task.id}/claim") end,
          fn -> :ok = T.set_grant!(fx, caller, @tw, :none) end
        )

      assert conn.status == 404
      assert T.task(fx, task.id).assignee_type == "ROLE"
    end
  end

  # ===========================================================================================
  describe "T-F10 / AC 14: list and inbox" do
    test "out-of-subtree and NULL-node tasks are excluded; count and cursor pages exclude them; the cursor holds no node id; a later page applies the CURRENT scope",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      inside = for key <- [:a, :a1, :a2x, :a1, :a1], do: T.insert_task!(fx, key)
      for key <- [:b, :b1, :root, :a3, nil], do: T.insert_task!(fx, key)

      for base <- ["/", "/inbox"] do
        first = T.call(fx, caller, :get, base <> "?page_size=2")
        assert first.status == 200
        body = T.json(first)
        assert body["count"] == 2 and length(body["items"]) == 2
        assert is_binary(body["next_cursor"])

        decoded = Base.url_decode64!(body["next_cursor"], padding: false)
        refute decoded =~ "sf-"
        refute body["next_cursor"] =~ "sf-"

        pages =
          Enum.reduce_while(1..10, {[first], body["next_cursor"]}, fn _i, {acc, cursor} ->
            conn = T.call(fx, caller, :get, base <> "?page_size=2&cursor=" <> cursor)
            assert conn.status == 200
            next = T.json(conn)["next_cursor"]
            if next == nil, do: {:halt, {[conn | acc], nil}}, else: {:cont, {[conn | acc], next}}
          end)
          |> elem(0)

        paged = pages |> Enum.flat_map(&T.ids/1) |> Enum.sort()
        assert paged == inside |> Enum.map(& &1.id) |> Enum.sort(), base

        for conn <- pages, do: assert(T.json(conn)["count"] == length(T.json(conn)["items"]))
      end

      # the cursor carries no set: the SAME cursor under a revoked grant yields an empty page
      first = T.call(fx, caller, :get, "/?page_size=2")
      cursor = T.json(first)["next_cursor"]
      :ok = T.set_grant!(fx, caller, @tw, :none)
      later = T.call(fx, caller, :get, "/?page_size=2&cursor=" <> cursor)
      assert later.status == 200
      assert T.ids(later) == []
    end

    test "composition is the intersection with the assignee row scope: in scope but assigned to another is absent",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      other = T.caller!(fx, grants: [{@tw, :a}], routing: false)

      mine_in = T.insert_task!(fx, :a1, %{assignee_type: "USER", assignee_ref: caller.id})
      theirs_in = T.insert_task!(fx, :a1, %{assignee_type: "USER", assignee_ref: other.id})
      mine_out = T.insert_task!(fx, :b, %{assignee_type: "USER", assignee_ref: caller.id})
      mine_null = T.insert_task!(fx, nil, %{assignee_type: "USER", assignee_ref: caller.id})
      role_in = T.insert_task!(fx, :a2x)
      role_out = T.insert_task!(fx, :b1)

      for conn <- [T.call(fx, caller, :get, "/"), T.call(fx, caller, :get, "/inbox")] do
        assert T.ids(conn) == Enum.sort([mine_in.id, role_in.id])
        refute theirs_in.id in T.ids(conn)
        refute mine_out.id in T.ids(conn)
        refute mine_null.id in T.ids(conn)
        refute role_out.id in T.ids(conn)
      end
    end

    test "a caller with NO row scope (also PROCESS_OPERATOR) still gets only the TASK_WORKER node set, intersected with the status / instance filters",
         %{fx: fx} do
      both = T.caller!(fx, roles: [@tw, @po], grants: [{@tw, :a}, {@po, :a}])
      pending_in = T.insert_task!(fx, :a1, %{assignee_type: nil, assignee_ref: nil})
      done_in = T.insert_task!(fx, :a1) |> then(&T.force_status!(fx, &1, :completed))
      pending_out = T.insert_task!(fx, :b, %{assignee_type: nil, assignee_ref: nil})
      done_out = T.insert_task!(fx, :b) |> then(&T.force_status!(fx, &1, :completed))

      all = T.call(fx, both, :get, "/")
      assert T.ids(all) == Enum.sort([pending_in.id, done_in.id])

      completed = T.call(fx, both, :get, "/?status=COMPLETED")
      assert T.ids(completed) == [done_in.id]
      refute done_out.id in T.ids(completed)

      pending = T.call(fx, both, :get, "/?status=PENDING")
      assert T.ids(pending) == [pending_in.id]
      refute pending_out.id in T.ids(pending)

      by_instance = T.call(fx, both, :get, "/?instance_id=#{pending_out.instance_id}")
      assert by_instance.status == 200
      assert T.ids(by_instance) == []
    end

    test "the RA-13 exemption lists everything (tenant-wide PROCESS_OPERATOR plus scoped TASK_WORKER); an explicit assignee_id still filters",
         %{fx: fx} do
      mixed = T.caller!(fx, roles: [@tw, @po], grants: [{@tw, :b}, {@po, :tenant_wide}])
      tasks = for key <- [:a1, :b, :root, nil], do: T.insert_task!(fx, key)
      assigned = T.insert_task!(fx, :a1, %{assignee_type: "USER", assignee_ref: mixed.id})

      listed = T.call(fx, mixed, :get, "/")
      assert T.ids(listed) == Enum.sort([assigned.id | Enum.map(tasks, & &1.id)])

      filtered = T.call(fx, mixed, :get, "/?assignee_id=#{mixed.id}")
      assert T.ids(filtered) == [assigned.id]
    end

    test "a scoped caller with no grant at all gets the empty page, not an error and not the full list",
         %{fx: fx} do
      rowless = T.caller!(fx, roles: [@tw])
      T.insert_task!(fx, :a1)
      T.insert_task!(fx, nil)

      for path <- ["/", "/inbox"] do
        conn = T.call(fx, rowless, :get, path)
        assert conn.status == 200
        assert T.json(conn)["items"] == []
        assert T.json(conn)["count"] == 0
      end
    end
  end

  # ===========================================================================================
  describe "T-F14 / AC 16: off and shadow are scope-free, byte-identical to each other, with no F1 statement" do
    defp no_f1_statement?(sql) do
      not (sql =~ "role_scope_grants" or sql =~ "scope_node_paths" or
             case String.split(sql, " WHERE ", parts: 2) do
               [_select, where] -> where =~ "scope_node_id"
               [_only] -> false
             end)
    end

    test "get, list and inbox: off and shadow byte-identical, scope-free, no F1 statement",
         %{fx: fx} do
      callers = [
        T.caller!(fx, grants: [{@tw, :a}]),
        T.caller!(fx, roles: [@tw]),
        T.caller!(fx, roles: [@po], grants: [{@po, :a}])
      ]

      in_task = T.insert_task!(fx, :a1)
      out_task = T.insert_task!(fx, :b)
      null_task = T.insert_task!(fx, nil)

      for caller <- callers do
        for {method, path} <- [
              {:get, "/#{in_task.id}"},
              {:get, "/#{out_task.id}"},
              {:get, "/#{null_task.id}"},
              {:get, "/"},
              {:get, "/inbox"}
            ] do
          {off, off_sql} = request(fx, caller, method, path, nil, :off)
          {shadow, shadow_sql} = request(fx, caller, method, path, nil, :shadow)

          assert off.status == 200, "#{path}: #{off.resp_body}"
          assert T.wire(off) == T.wire(shadow), "#{path}: off and shadow differ"
          assert Enum.all?(off_sql, &no_f1_statement?/1), "#{path}: off issued an F1 statement"

          assert Enum.all?(shadow_sql, &no_f1_statement?/1),
                 "#{path}: shadow issued an F1 statement"
        end
      end

      # scope-free: the worker with a grant on `a` is still served the out-of-scope and NULL tasks
      [scoped | _] = callers
      listed = T.ids(T.call(fx, scoped, :get, "/", nil, :off))
      assert out_task.id in listed and null_task.id in listed and in_task.id in listed
    end

    test "claim and complete: same response bytes in off and shadow, out-of-scope tasks served, no F1 statement",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])

      claim_modes =
        for mode <- [:off, :shadow] do
          task = T.insert_task!(fx, :b)
          {conn, sql} = request(fx, caller, :post, "/#{task.id}/claim", nil, mode)
          assert conn.status == 200, "#{mode}: #{conn.resp_body}"
          assert T.assigned_to?(T.task(fx, task.id), caller.id)
          assert Enum.all?(sql, &no_f1_statement?/1), "claim #{mode}"
          {T.wire(conn), task}
        end

      [
        {{200, off_headers, off_body}, off_task},
        {{200, shadow_headers, shadow_body}, shadow_task}
      ] =
        claim_modes

      assert off_headers == shadow_headers
      assert normalise(off_body, off_task) == normalise(shadow_body, shadow_task)

      complete_modes =
        for mode <- [:off, :shadow] do
          task = T.start_task!(fx, :b)
          {conn, sql} = request(fx, caller, :post, "/#{task.id}/complete", %{}, mode)
          assert conn.status == 200, "#{mode}: #{conn.resp_body}"
          assert T.task(fx, task.id).status == :completed
          assert Enum.all?(sql, &no_f1_statement?/1), "complete #{mode}"
          {T.wire(conn), task}
        end

      [
        {{200, c_off_headers, c_off_body}, c_off},
        {{200, c_shadow_headers, c_shadow_body}, c_shadow}
      ] =
        complete_modes

      assert c_off_headers == c_shadow_headers
      assert normalise(c_off_body, c_off) == normalise(c_shadow_body, c_shadow)
    end

    test "assign and reassign: served for an out-of-scope task in off and shadow, no F1 statement",
         %{fx: fx} do
      operator = T.caller!(fx, roles: [@po], grants: [{@po, :a}], routing: false)
      target = T.caller!(fx, roles: [@tw], routing: false)

      for mode <- [:off, :shadow] do
        task = T.insert_task!(fx, :b, %{assignee_type: nil, assignee_ref: nil})

        {conn, sql} =
          request(fx, operator, :post, "/#{task.id}/assign", %{"user_id" => target.id}, mode)

        assert conn.status == 200, "#{mode}: #{conn.resp_body}"
        assert Enum.all?(sql, &no_f1_statement?/1)

        {conn, sql} =
          request(fx, operator, :post, "/#{task.id}/reassign", %{"user_id" => operator.id}, mode)

        assert conn.status == 200
        assert Enum.all?(sql, &no_f1_statement?/1)
      end
    end

    test "the same requests under `on` DO read the grants (the absence above is meaningful)",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      task = T.insert_task!(fx, :a1)
      {_conn, sql} = request(fx, caller, :get, "/#{task.id}", nil, :on)

      refute Enum.all?(sql, &no_f1_statement?/1)
    end

    # the task's own ids and instance ids differ between two runs: replace them
    defp normalise(body, task) do
      body
      |> String.replace(task.id, "TASK")
      |> String.replace(task.instance_id, "INSTANCE")
      |> String.replace(task.token_id, "TOKEN")
      |> String.replace(~r/"(created_at|updated_at|completed_at)":"[^"]*"/, ~S("\1":"T"))
      |> String.replace(~r/"trace_id":"[^"]*"/, ~S("trace_id":"X"))
    end
  end
end
