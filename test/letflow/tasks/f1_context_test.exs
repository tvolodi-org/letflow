defmodule Letflow.Tasks.F1ContextTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2d at the CONTEXT layer (design
  `lib/letflow/design/req518-compiler-scope-filter.md` C.2 to C.4, 10.3; spec
  `test/specs/REQ-518-2d.md`; SEC code-gate step-24 and REVIEWER step-25 notes): the approver rule
  F1 as `Letflow.Tasks` and `Letflow.Engine` apply it, with the principal handed in directly.

    * `Tasks.in_scope/3`: `:all` -> `:ok` with ZERO statements, `:none` -> refused with zero
      statements, `{:nodes, ids}` -> ONE statement; out-of-set, NULL-node, retired-node and
      nonexistent tasks are one answer; a malformed id is the invalid-id answer BEFORE any
      statement; `{:nodes, []}` fails closed;
    * `get_task/2` and `list_tasks/2` take the same set (`:scope`): one statement, NULL-node tasks
      excluded, `count` and the cursor pages exclude out-of-scope tasks, the cursor holds no node
      or set, `:none` and `{:nodes, []}` are empty, composition with the assignee scope is the
      INTERSECTION (MU25);
    * `Tasks.claim_task/3` and `Engine.complete_task/3` with `f1: :off | {:enforce, principal}`:
      the `:f1_scope` step exists only for `{:enforce, _}`, runs right AFTER the task row lock and
      BEFORE every transition step, reloads the grants INSIDE the transaction (a stale principal
      is irrelevant in BOTH directions: MU23), refuses with `{:error, :task_not_found}` and leaves
      the task, the instance, the events and the audit untouched; an invalid `f1` value is a
      `FunctionClauseError`, never a silent skip (REVIEWER F-2);
    * AC 15 / T-F9 / T-F11: a REAL revocation between the task row lock (held by another
      connection) and the recheck refuses the claim and the completion; with no revocation the
      same interleaving succeeds;
    * T-F17 (C-4): the recheck adds NO lock: the multiset of lock-bearing statements of
      `complete_task` and `claim_task` is identical with and without `f1`, and the extra
      statements are plain `SELECT`s;
    * audit: no task audit entry (create, assign, claim, complete, cancel) carries
      `scope_node_id` in `before_state` or `after_state`, and the key set equals the pre-change
      key set; `Task.audit_state/1` is the single owner of the exclusion.

  `async: false`: committed tenant writes, cross-connection locks.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.Support.TaskScopeFixture, as: T
  alias Letflow.Tasks

  @tw "TASK_WORKER"
  @lock_re ~r/\bFOR (NO KEY )?(UPDATE|SHARE|KEY SHARE)\b|pg_advisory|LOCK TABLE/i

  setup do
    fx = T.provision!("r518-2d-ctx")
    {:ok, fx: fx, opts: [prefix: fx.schema_name]}
  end

  # ---- helpers -------------------------------------------------------------------------------

  defp ids(keys), do: keys |> Enum.map(&Map.fetch!(F.nodes(), &1)) |> Enum.sort()

  defp stmts(fun) do
    {result, queries} = Letflow.Support.PlatformTenantFixture.capture_repo_queries(fun)
    {result, Enum.map(queries, & &1.query)}
  end

  defp lock_statements(statements),
    do: statements |> Enum.filter(&(&1 =~ @lock_re)) |> Enum.sort()

  defp claim(fx, task, caller, f1) do
    Tasks.claim_task(task.id, %{actor_id: caller.id}, prefix: fx.schema_name, f1: f1)
  end

  defp complete(fx, task, caller, f1) do
    Engine.complete_task(
      task.id,
      %{
        output_variables: %{"decision" => "approved"},
        actor_id: caller.id,
        idempotency_key: Ecto.UUID.generate()
      },
      prefix: fx.schema_name,
      f1: f1
    )
  end

  defp enforce(fx, caller), do: {:enforce, T.principal(fx, caller)}

  defp unchanged?(fx, task) do
    now = T.task(fx, task.id)

    now.status == :pending and now.assignee_type == task.assignee_type and
      now.assignee_ref == task.assignee_ref and now.completed_at == nil
  end

  defp instance_status(fx, task) do
    Repo.get!(InstanceProjection, task.instance_id, prefix: fx.schema_name).status
  end

  defp event_count(fx, task) do
    {:ok, id} = Ecto.UUID.dump(task.instance_id)

    %{rows: [[n]]} =
      Repo.query!(~s|SELECT count(*) FROM "#{fx.schema_name}".events WHERE instance_id = $1|, [id])

    n
  end

  defp audit_count(fx, action) do
    Repo.aggregate(
      from(e in Letflow.Audit.Entry, where: e.action == ^action),
      :count,
      prefix: fx.schema_name
    )
  end

  # ===========================================================================================
  describe "Tasks.in_scope/3" do
    test ":all is :ok with ZERO statements (even for a nonexistent id); :none is refused with zero statements",
         %{fx: fx, opts: opts} do
      real = T.insert_task!(fx, :b)

      {results, queries} =
        stmts(fn ->
          [
            Tasks.in_scope(real.id, :all, opts),
            Tasks.in_scope(Ecto.UUID.generate(), :all, opts),
            Tasks.in_scope(real.id, :none, opts),
            Tasks.in_scope(Ecto.UUID.generate(), :none, opts)
          ]
        end)

      assert results == [:ok, :ok, {:error, :task_not_found}, {:error, :task_not_found}]
      assert queries == []
    end

    test "{:nodes, ids}: ONE statement; in the set -> :ok; out of the set, NULL node, retired node and nonexistent id are ONE answer",
         %{fx: fx, opts: opts} do
      in_a1 = T.insert_task!(fx, :a1)
      in_a2x = T.insert_task!(fx, :a2x)
      in_b = T.insert_task!(fx, :b)
      in_root = T.insert_task!(fx, :root)
      retired = T.insert_task!(fx, :a2)
      null_node = T.insert_task!(fx, nil)
      set = {:nodes, ids([:a, :a1, :a2x])}

      for ok <- [in_a1, in_a2x] do
        {result, queries} = stmts(fn -> Tasks.in_scope(ok.id, set, opts) end)
        assert result == :ok
        assert length(queries) == 1
      end

      refused = [in_b, in_root, retired, null_node, %{id: Ecto.UUID.generate()}]

      for task <- refused do
        {result, queries} = stmts(fn -> Tasks.in_scope(task.id, set, opts) end)
        assert result == {:error, :task_not_found}
        assert length(queries) == 1, "one statement however it is refused"
      end

      # the same statement TEXT for every outcome
      texts =
        for task <- [in_a1 | refused], uniq: true do
          {_, [sql]} = stmts(fn -> Tasks.in_scope(task.id, set, opts) end)
          sql
        end

      assert length(texts) == 1
    end

    test "a malformed id is the invalid-id answer BEFORE any statement, for every set", %{
      opts: opts
    } do
      {results, queries} =
        stmts(fn ->
          for set <- [:all, :none, {:nodes, ["sf-a"]}],
              do: Tasks.in_scope("not-a-uuid", set, opts)
        end)

      assert results == List.duplicate({:error, :invalid_task_id}, 3)
      assert queries == []
    end

    test "{:nodes, []} fails closed: nothing is in an empty set (REVIEWER note)", %{
      fx: fx,
      opts: opts
    } do
      task = T.insert_task!(fx, :a)
      assert Tasks.in_scope(task.id, {:nodes, []}, opts) == {:error, :task_not_found}
      assert Tasks.in_scope(Ecto.UUID.generate(), {:nodes, []}, opts) == {:error, :task_not_found}
    end

    test "another tenant's prefix sees nothing", %{fx: fx} do
      task = T.insert_task!(fx, :a)
      other = T.provision!("r518-2d-ctx2")

      assert Tasks.in_scope(task.id, {:nodes, [F.nodes().a]}, prefix: other.schema_name) ==
               {:error, :task_not_found}
    end
  end

  # ===========================================================================================
  describe "get_task/2 and list_tasks/2 with :scope (AC 14)" do
    test "get_task: one statement; in set -> {:ok, _}; out of set / NULL / :none / {:nodes, []} -> :not_found; no :scope is today's read",
         %{fx: fx, opts: opts} do
      in_a = T.insert_task!(fx, :a1)
      in_b = T.insert_task!(fx, :b)
      null_node = T.insert_task!(fx, nil)
      set = {:nodes, ids([:a, :a1, :a2x])}

      {result, queries} = stmts(fn -> Tasks.get_task(in_a.id, opts ++ [scope: set]) end)
      assert {:ok, {%EngineTask{id: id}, _corr, _fv}} = result
      assert id == in_a.id
      assert length(queries) == 1

      for task <- [in_b, null_node, %{id: Ecto.UUID.generate()}] do
        {result, queries} = stmts(fn -> Tasks.get_task(task.id, opts ++ [scope: set]) end)
        assert result == {:error, :not_found}
        assert length(queries) == 1
      end

      for scope <- [:none, {:nodes, []}] do
        assert Tasks.get_task(in_a.id, opts ++ [scope: scope]) == {:error, :not_found}
      end

      # no :scope key (today), and :all, read everything incl. the NULL-node task
      for extra <- [[], [scope: :all]] do
        assert {:ok, {%EngineTask{}, _, _}} = Tasks.get_task(null_node.id, opts ++ extra)
        assert {:ok, {%EngineTask{}, _, _}} = Tasks.get_task(in_b.id, opts ++ extra)
      end

      # a malformed id is still the invalid-id answer
      assert Tasks.get_task("nope", opts ++ [scope: set]) == {:error, :invalid_id}
    end

    defp list(opts, params) do
      {:ok, page} =
        Tasks.list_tasks(
          Map.merge(%{assignee_scope: :unfiltered, cursor: nil, page_size: 50}, params),
          opts
        )

      page
    end

    defp page_ids(page), do: page.items |> Enum.map(fn {task, _fv} -> task.id end) |> Enum.sort()

    test "list_tasks: a node set keeps only tasks in the set (NULL and out-of-set excluded); :none and an empty set are empty; :all is everything",
         %{fx: fx, opts: opts} do
      a1 = T.insert_task!(fx, :a1)
      a2x = T.insert_task!(fx, :a2x)
      b = T.insert_task!(fx, :b)
      retired = T.insert_task!(fx, :a3)
      null_node = T.insert_task!(fx, nil)

      set = {:nodes, ids([:a, :a1, :a2x])}
      assert page_ids(list(opts, %{scope: set})) == Enum.sort([a1.id, a2x.id])

      assert page_ids(list(opts, %{scope: :none})) == []
      assert page_ids(list(opts, %{scope: {:nodes, []}})) == []

      everything = Enum.sort([a1.id, a2x.id, b.id, retired.id, null_node.id])
      assert page_ids(list(opts, %{scope: :all})) == everything
      assert page_ids(list(opts, %{})) == everything
    end

    test "composition with the assignee scope is the INTERSECTION (MU25)",
         %{fx: fx, opts: opts} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      other = T.caller!(fx, grants: [{@tw, :a}], routing: false)

      mine_in = T.insert_task!(fx, :a1, %{assignee_type: "USER", assignee_ref: caller.id})
      theirs_in = T.insert_task!(fx, :a1, %{assignee_type: "USER", assignee_ref: other.id})
      mine_out = T.insert_task!(fx, :b, %{assignee_type: "USER", assignee_ref: caller.id})
      role_in = T.insert_task!(fx, :a2x)
      role_out = T.insert_task!(fx, :b1)
      mine_null = T.insert_task!(fx, nil, %{assignee_type: "USER", assignee_ref: caller.id})

      principal_scope = Tasks.resolve_principal_scope(caller.id, prefix: fx.schema_name)
      set = {:nodes, ids([:a, :a1, :a2x])}

      page = list(opts, %{assignee_scope: {:principal, principal_scope}, scope: set})
      assert page_ids(page) == Enum.sort([mine_in.id, role_in.id])
      refute theirs_in.id in page_ids(page)

      # the assignee scope alone sees more; the scope alone sees more: only the AND is the answer
      only_assignee = list(opts, %{assignee_scope: {:principal, principal_scope}, scope: :all})

      assert page_ids(only_assignee) ==
               Enum.sort([mine_in.id, mine_out.id, mine_null.id, role_in.id, role_out.id])

      only_scope = list(opts, %{scope: set})
      assert page_ids(only_scope) == Enum.sort([mine_in.id, theirs_in.id, role_in.id])

      explicit = list(opts, %{assignee_scope: {:explicit_user, caller.id}, scope: set})
      assert page_ids(explicit) == [mine_in.id]
    end

    test "pages and cursor: out-of-scope tasks are never paged; the cursor holds no node id; page 2 applies the scope given now",
         %{fx: fx, opts: opts} do
      in_scope = for _ <- 1..5, do: T.insert_task!(fx, :a1)
      for _ <- 1..3, do: T.insert_task!(fx, :b)
      for _ <- 1..2, do: T.insert_task!(fx, nil)
      set_a = {:nodes, ids([:a, :a1, :a2x])}

      page1 = list(opts, %{scope: set_a, page_size: 2})
      assert length(page1.items) == 2
      assert is_binary(page1.next_cursor)

      decoded = Base.url_decode64!(page1.next_cursor, padding: false)
      refute decoded =~ "sf-"
      refute page1.next_cursor =~ "sf-"

      page2 = list(opts, %{scope: set_a, page_size: 2, cursor: page1.next_cursor})
      page3 = list(opts, %{scope: set_a, page_size: 2, cursor: page2.next_cursor})

      all_ids = Enum.flat_map([page1, page2, page3], &page_ids/1)
      assert Enum.sort(all_ids) == Enum.sort(Enum.map(in_scope, & &1.id))
      assert page3.next_cursor == nil

      # the SAME cursor under a different (narrower) set: the scope given NOW is applied
      narrower = list(opts, %{scope: :none, page_size: 2, cursor: page1.next_cursor})
      assert narrower.items == []
    end
  end

  # ===========================================================================================
  describe "claim_task/3 with f1" do
    test "f1 absent or :off: today's behaviour, scope-free (an out-of-scope or NULL task is claimed)",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      out = T.insert_task!(fx, :b)
      null_node = T.insert_task!(fx, nil)

      assert {:ok, claimed} =
               Tasks.claim_task(out.id, %{actor_id: caller.id}, prefix: fx.schema_name)

      assert T.assigned_to?(claimed, caller.id)

      assert {:ok, _} = claim(fx, null_node, caller, :off)
    end

    test "{:enforce, principal}: a task under the grant (also via an ancestor grant and under a retired intermediate node's live child) is claimed",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])

      for key <- [:a, :a1, :a2x] do
        task = T.insert_task!(fx, key)
        assert {:ok, claimed} = claim(fx, task, caller, enforce(fx, caller)), "#{key}"
        assert T.assigned_to?(claimed, caller.id)
      end
    end

    test "{:enforce, principal}: sibling subtree, root, retired node, unknown node and NULL node are {:error, :task_not_found} and the row is untouched",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])

      for key <- [:b, :b1, :root, :a2, :a3, nil] do
        task = T.insert_task!(fx, key)
        assert claim(fx, task, caller, enforce(fx, caller)) == {:error, :task_not_found}, "#{key}"
        assert unchanged?(fx, task)
      end

      audits_before = audit_count(fx, "task.assign")
      task = T.insert_task!(fx, :b)
      assert claim(fx, task, caller, enforce(fx, caller)) == {:error, :task_not_found}
      assert audit_count(fx, "task.assign") == audits_before
    end

    test "the recheck precedes the routing-role errors; outside the role but covered keeps the existing role error (case c)",
         %{fx: fx} do
      not_routed = T.caller!(fx, grants: [{@tw, :a}], routing: false)
      in_task = T.insert_task!(fx, :a1)
      out_task = T.insert_task!(fx, :b)

      assert claim(fx, out_task, not_routed, enforce(fx, not_routed)) == {:error, :task_not_found}

      assert claim(fx, in_task, not_routed, enforce(fx, not_routed)) ==
               {:error, :assignee_role_not_held}

      assert unchanged?(fx, in_task)
    end

    test "tenant-wide TASK_WORKER in the routing role claims anything incl. a NULL-node task (case d, e); a scoped caller does not claim a NULL-node task",
         %{fx: fx} do
      wide = T.caller!(fx, grants: [{@tw, :tenant_wide}])
      scoped = T.caller!(fx, grants: [{@tw, :a}])

      assert {:ok, _} = claim(fx, T.insert_task!(fx, nil), wide, enforce(fx, wide))
      assert {:ok, _} = claim(fx, T.insert_task!(fx, :b), wide, enforce(fx, wide))

      null_task = T.insert_task!(fx, nil)
      assert claim(fx, null_task, scoped, enforce(fx, scoped)) == {:error, :task_not_found}
    end

    test "a token principal passes the gate as tenant-wide (design C.4)", %{fx: fx} do
      caller = T.caller!(fx, grants: [])
      token = %{F.token_principal(fx) | user_id: caller.id}
      task = T.insert_task!(fx, nil)

      assert {:ok, claimed} = claim(fx, task, caller, {:enforce, token})
      assert T.assigned_to?(claimed, caller.id)
    end

    test "MU23: the recheck reloads grants INSIDE the transaction: a principal loaded BEFORE the revocation is refused, one loaded BEFORE a grant was added is allowed",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      task = T.insert_task!(fx, :a1)

      stale_with_grant = enforce(fx, caller)
      :ok = T.set_grant!(fx, caller, @tw, :none)

      assert claim(fx, task, caller, stale_with_grant) == {:error, :task_not_found}
      assert unchanged?(fx, task)

      stale_without_grant = enforce(fx, caller)
      :ok = T.set_grant!(fx, caller, @tw, :a)

      assert {:ok, claimed} = claim(fx, task, caller, stale_without_grant)
      assert T.assigned_to?(claimed, caller.id)
    end

    test "the recheck sees group membership freshly too: a group-level grant is gone after the member leaves the group",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [])
      # the grant is held through the TASK_WORKER binding group (a stray group row never applies)
      group = RSG.group_of!(fx.schema_name, @tw)
      _removed = RSG.raw_delete_rows!(fx.schema_name, group, @tw)
      RSG.member!(fx.schema_name, group, caller.user)
      :ok = RSG.raw_scoped_row!(fx.schema_name, group, @tw, F.nodes().a)

      task = T.insert_task!(fx, :a1)
      stale = enforce(fx, caller)
      assert %{rows_by_role: %{@tw => [_]}} = elem(stale, 1).grants

      Repo.delete_all(
        from(m in Letflow.Identity.GroupMember,
          where: m.group_id == ^group and m.user_id == ^caller.id
        ),
        prefix: fx.schema_name
      )

      assert claim(fx, task, caller, stale) == {:error, :task_not_found}
    end

    test "an invalid f1 value is a FunctionClauseError, never a silent skip (nil, :on, a bare principal, {:enforce, nil})",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      task = T.insert_task!(fx, :b)
      principal = T.principal(fx, caller)

      for bad <- [nil, :on, principal, {:enforce, nil}, {:enforce, :principal}] do
        assert_raise FunctionClauseError, fn -> claim(fx, task, caller, bad) end
      end

      assert unchanged?(fx, task)
    end

    test "as-built (pinned): a NON-pending task is {:task_not_pending, _} from the task-lock step, before the recheck; the router closes the oracle with Tasks.in_scope/3 first",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      done = T.insert_task!(fx, :b) |> then(&T.force_status!(fx, &1, :completed))

      assert claim(fx, done, caller, enforce(fx, caller)) ==
               {:error, {:task_not_pending, :completed}}
    end
  end

  # ===========================================================================================
  describe "Engine.complete_task/3 with f1" do
    test "f1 absent or :off: today's behaviour (an out-of-scope task completes)", %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      out = T.start_task!(fx, :b)

      assert {:ok, result} = complete(fx, out, caller, :off)
      assert result.instance_status == :completed or result.instance_status == "COMPLETED"
    end

    test "{:enforce, principal}: in scope completes; out of scope / NULL / retired is {:error, :task_not_found} and NOTHING changes (task, instance, events, audit)",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])

      in_task = T.start_task!(fx, :a1)
      assert {:ok, _} = complete(fx, in_task, caller, enforce(fx, caller))
      assert T.task(fx, in_task.id).status == :completed

      for key <- [:b, :root, :a3, nil] do
        task = T.start_task!(fx, key)
        events = event_count(fx, task)
        audits = audit_count(fx, "task.complete")

        assert complete(fx, task, caller, enforce(fx, caller)) == {:error, :task_not_found},
               "#{key}"

        assert unchanged?(fx, task)
        assert instance_status(fx, task) == :active
        assert event_count(fx, task) == events
        assert audit_count(fx, "task.complete") == audits
      end
    end

    test "MU23 again for complete: a stale principal (loaded before the revocation) is refused; a tenant-wide principal completes a NULL-node task",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      task = T.start_task!(fx, :a1)
      stale = enforce(fx, caller)
      :ok = T.set_grant!(fx, caller, @tw, :none)

      assert complete(fx, task, caller, stale) == {:error, :task_not_found}
      assert unchanged?(fx, task)

      wide = T.caller!(fx, grants: [{@tw, :tenant_wide}])
      null_task = T.start_task!(fx, nil)
      assert {:ok, _} = complete(fx, null_task, wide, enforce(fx, wide))
    end

    test "an invalid f1 value never completes the task silently", %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      task = T.start_task!(fx, :b)

      for bad <- [nil, :on, T.principal(fx, caller), {:enforce, nil}] do
        outcome =
          try do
            complete(fx, task, caller, bad)
          rescue
            e -> {:raised, e.__struct__}
          end

        refute match?({:ok, _}, outcome), inspect(bad)
        assert unchanged?(fx, task)
        assert instance_status(fx, task) == :active
      end
    end
  end

  # ===========================================================================================
  describe "AC 15 / T-F9 / T-F11: a real revocation between the task row lock and the recheck" do
    defp interleave(fx, task, work, between), do: T.interleave(fx, task, work, between)

    test "complete: a grant revoked while the completion waits for the task lock is task_not_found (MU23)",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      task = T.start_task!(fx, :a1)
      principal = enforce(fx, caller)

      result =
        interleave(
          fx,
          task,
          fn -> complete(fx, task, caller, principal) end,
          fn -> :ok = T.set_grant!(fx, caller, @tw, :none) end
        )

      assert result == {:error, :task_not_found}
      assert unchanged?(fx, task)
      assert instance_status(fx, task) == :active
    end

    test "complete, control: the same interleaving with NO revocation completes", %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      task = T.start_task!(fx, :a1)
      principal = enforce(fx, caller)

      assert {:ok, _} =
               interleave(fx, task, fn -> complete(fx, task, caller, principal) end, fn -> :ok end)

      assert T.task(fx, task.id).status == :completed
    end

    test "claim, revoke, complete: the claim holds, the completion is the 404-equivalent (T-F9)",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      task = T.start_task!(fx, :a1)

      assert {:ok, claimed} = claim(fx, task, caller, enforce(fx, caller))
      assert T.assigned_to?(claimed, caller.id)

      :ok = T.set_grant!(fx, caller, @tw, :none)
      assert complete(fx, task, caller, enforce(fx, caller)) == {:error, :task_not_found}

      # the claimed assignment stays; only the completion was refused
      assert T.assigned_to?(T.task(fx, task.id), caller.id)
      assert T.task(fx, task.id).status == :pending
    end

    test "claim: grant revoked while the claim waits for the task row lock -> task_not_found, not assigned",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      task = T.insert_task!(fx, :a1)
      principal = enforce(fx, caller)

      result =
        interleave(
          fx,
          task,
          fn -> claim(fx, task, caller, principal) end,
          fn -> :ok = T.set_grant!(fx, caller, @tw, :none) end
        )

      assert result == {:error, :task_not_found}
      assert unchanged?(fx, task)
    end
  end

  # ===========================================================================================
  describe "T-F17 / C-4: the recheck adds no lock and sits right after the task row lock" do
    test "complete_task: same lock statements with and without f1; extras are plain SELECTs between the task and instance locks",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      off_task = T.start_task!(fx, :a1)
      on_task = T.start_task!(fx, :a1)

      {{:ok, _}, off} = stmts(fn -> complete(fx, off_task, caller, :off) end)
      f1 = enforce(fx, caller)
      {{:ok, _}, on} = stmts(fn -> complete(fx, on_task, caller, f1) end)

      assert lock_statements(on) == lock_statements(off)
      assert lock_statements(on) != [], "the capture is live (locks are taken)"

      assert off -- on == [], "the f1 path only ADDS statements"
      extra = on -- off
      assert extra != [], "the :f1_scope step is live when f1 is {:enforce, _}"

      for sql <- extra do
        assert sql =~ ~r/^SELECT/i, sql
        refute sql =~ @lock_re, sql
      end

      # order: task row lock < first grants read < instance projection lock
      pos = fn re -> Enum.find_index(on, &(&1 =~ re)) end
      task_lock = pos.(~r/FROM "[^"]+"\."tasks" .*FOR UPDATE/s)
      grants = pos.(~r/role_scope_grants/)
      projection_lock = pos.(~r/FROM "[^"]+"\."instance_projections" .*FOR UPDATE/s)

      assert is_integer(task_lock) and is_integer(grants) and is_integer(projection_lock)
      assert task_lock < grants and grants < projection_lock
    end

    test "claim_task: identical lock statements with and without f1; extras are plain SELECTs in the right place",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      off_task = T.insert_task!(fx, :a1)
      on_task = T.insert_task!(fx, :a1)

      {{:ok, _}, off} = stmts(fn -> claim(fx, off_task, caller, :off) end)
      f1 = enforce(fx, caller)
      {{:ok, _}, on} = stmts(fn -> claim(fx, on_task, caller, f1) end)

      assert lock_statements(on) == lock_statements(off)
      assert off -- on == []
      extra = on -- off
      assert extra != []

      for sql <- extra do
        assert sql =~ ~r/^SELECT/i, sql
        refute sql =~ @lock_re, sql
      end

      pos = fn re -> Enum.find_index(on, &(&1 =~ re)) end
      assert pos.(~r/"tasks" .*FOR UPDATE/s) < pos.(~r/role_scope_grants/)

      routing_reads =
        Enum.find_index(on, &(&1 =~ "group_members" and not (&1 =~ "role_scope_grants")))

      assert pos.(~r/role_scope_grants/) < routing_reads
    end

    test "f1 :off adds nothing: no statement mentions the grants or the node tree (AC 16 at the context layer)",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      claim_task = T.insert_task!(fx, :b)
      complete_task = T.start_task!(fx, :b)

      {_, claim_sql} = stmts(fn -> claim(fx, claim_task, caller, :off) end)
      {_, complete_sql} = stmts(fn -> complete(fx, complete_task, caller, :off) end)

      for sql <- claim_sql ++ complete_sql do
        refute sql =~ "role_scope_grants", sql
        refute sql =~ "scope_node_paths", sql
      end
    end
  end

  # ===========================================================================================
  describe "Tasks.resolve_principal_scope/2 stays the single reader of groups and roles (AC 13)" do
    test "its result is exactly today's map (user, groups, roles): the F1 rule adds no key and no extra read",
         %{fx: fx, opts: opts} do
      caller = T.caller!(fx, grants: [{@tw, :a}])

      {scope, queries} = stmts(fn -> Tasks.resolve_principal_scope(caller.id, opts) end)

      assert scope |> Map.keys() |> Enum.sort() == [:group_ids, :role_names, :user_id]
      assert scope.user_id == caller.id
      assert scope.group_ids == [fx.routing_group_id]
      assert scope.role_names == [T.routing_role()]
      # two statements as before: memberships, then the bindings of those groups
      assert length(queries) == 2
      assert Enum.all?(queries, &(not (&1 =~ "role_scope_grants" or &1 =~ "scope_node_paths")))
    end
  end

  # ===========================================================================================
  describe "audit: no task audit entry carries scope_node_id (five writers, seven sites)" do
    defp state_keys(entry) do
      [entry.before_state, entry.after_state]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Map.keys/1)
    end

    test "create, claim, assign, complete and cancel entries never name scope_node_id and keep the pre-change key set",
         %{fx: fx} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      expected_keys = EngineTask.__schema__(:fields) -- [:scope_node_id]
      expected_keys = expected_keys |> Enum.map(&Atom.to_string/1) |> Enum.sort()

      # create (task_activation) -- the task is created by the engine, then given a node
      completed = T.start_task!(fx, :a1)
      claimed = T.start_task!(fx, :a1)
      assigned = T.insert_task!(fx, :a1, %{assignee_type: nil, assignee_ref: nil})
      cancelled = T.start_task!(fx, :a2x, escalation: true)

      # claim and complete (engine)
      assert {:ok, _} = claim(fx, claimed, caller, enforce(fx, caller))
      assert {:ok, _} = complete(fx, completed, caller, enforce(fx, caller))

      # assign (the write path of Tasks.assign_task/3)
      assert {:ok, _} =
               Tasks.assign_task(assigned.id, %{user_id: caller.id}, prefix: fx.schema_name)

      # reassign and claim (they write no audit entry today; if one is added it is checked below)
      assert {:ok, _} =
               Tasks.reassign_task(assigned.id, %{user_id: Ecto.UUID.generate()},
                 prefix: fx.schema_name
               )

      # cancel (the escalation timer cancels the original task)
      :ok = T.fire_escalation!(fx, cancelled)

      entries = T.task_audit_entries(fx)

      actions = entries |> Enum.map(& &1.action) |> Enum.uniq() |> Enum.sort()

      # (as built only assign writes a `task.assign` entry; claim and reassign write none. Whatever
      # a future writer adds is covered: the loop below checks EVERY task entry)
      assert Enum.count(entries, &(&1.action == "task.assign")) >= 1

      for needed <- ["task.assign", "task.cancel", "task.complete", "task.create"] do
        assert needed in actions, "the capture is live for #{needed} (got #{inspect(actions)})"
      end

      for entry <- entries, keys <- state_keys(entry) do
        refute "scope_node_id" in keys, "#{entry.action} carries scope_node_id"
        assert Enum.sort(keys) == expected_keys, entry.action
      end
    end

    test "Task.audit_state/1 is the one owner: struct_state minus scope_node_id, nothing else dropped",
         %{fx: fx} do
      task = T.insert_task!(fx, :a1)
      assert task.scope_node_id == F.nodes().a1

      state = EngineTask.audit_state(task)
      refute Map.has_key?(state, :scope_node_id)
      assert state == Letflow.Audit.struct_state(task, [:scope_node_id])

      assert Map.keys(state) |> Enum.sort() ==
               Enum.sort(EngineTask.__schema__(:fields) -- [:scope_node_id])

      assert state.id == task.id and state.status == :pending
    end
  end
end
