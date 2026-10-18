defmodule Letflow.Engine.EntityParentLockOrderTest do
  @moduledoc """
  GH #2704 / #2705 PR-1 (design `lib/letflow/design/gh2704-lock-order-family.md`, section 4.1;
  decision 0061): the entity-type rows (`E`) versus the ancestor group of a sub-process child
  (parent projection, then waiting token) and versus the tenant-wide audit chain row (`A`).

  One global order for both child kinds: `P_c`, ancestor group, `E`, `A`, `S_c`, ...

    * E0s / E0c: statement order of a service apply (the type rows before the first token insert
      and the audit chain row) and of a service CHILD (parent group, waiting token, type rows,
      audit chain row);
    * E1: a completing HUMAN child and a completing service sibling, both with lines on one type;
    * E2a / E2b / E2c: a CONTINUING HUMAN child (key-share group) against the parent's own
      completion, a completing sibling, and a continuing service sibling. E2c is NOT a green
      control on main: it was measured RED on main (the continuing service sibling activates a
      HUMAN task, so it takes the audit chain row before the type rows: the "I4" inversion with
      the HUMAN sibling's type-rows-then-audit order) and is GREEN after PR-1. It cannot detect a
      continuing child wrongly taking the group FOR UPDATE (that would be the same order, no
      deadlock); E2d pins the lock MODE by statement trace;
    * E2d: a continuing child takes the group `FOR KEY SHARE` and never `FOR UPDATE`, HUMAN and
      service shaped;
    * E4x: a completion whose transition is an execution error does not raise (the
      `:lock_ancestors` step returns `{:ok, []}`); the only group lock is the ExecutionError
      landing's own `FOR KEY SHARE` (GH #2709);
    * E3: a HUMAN child completion against the parent's OWN completion with lines on the type;
    * E5 / E6 (the demonstrating tests of GH #2705, "I4"): a service apply that activates a HUMAN
      task (so it writes `task.create` and takes `A`) versus a HUMAN completion with lines on the
      same type, no parent involved; E6 with the type reached ONLY through a module write handler.

  Forced-overlap method: `Letflow.LockOrderHelpers` (a barrier row held by a third connection plus
  lock-queue FIFO; deadlocks and lock timeouts are reported through the Repo telemetry event, so a
  retried victim cannot hide). Sandbox `:auto` mode (real commits), hence `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Engine
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.ModuleWritesFixture, as: Mw
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Test.SandboxAutoMode

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    H.attach_error_handler(__MODULE__)
    :ok
  end

  defp plain_tenant(_context) do
    base = Fx.committed_tenant_case!("gh2704-ent")
    on_exit(fn -> Fx.drop_committed_tenant!(base.tenant.tenant_id) end)
    Fx.define_type!(base.schema, "stock_move", %{})
    # the type's synthetic instance is created before the race (its first creation is not part
    # of it; `prepare/2` does the same outside the transaction)
    {:ok, type_id} = EntityTypeInstance.get_or_create("stock_move", base.schema)

    # ... and so is its `instance_sequences` row, which the barrier holds (it is created lazily by
    # the first lock, without incrementing)
    {:ok, {:ok, :locked}} =
      Repo.transaction(fn ->
        Letflow.EventStore.lock_instance_sequence(Repo, type_id, base.schema)
      end)

    %{base: base, type_id: type_id}
  end

  # ---- graphs -----------------------------------------------------------------------------------

  defp x_line, do: Fx.line("stock_move", %{"label" => %{"const" => "x"}})

  defp human(id, attributes),
    do: %{
      "id" => id,
      "node_type" => "HUMAN_TASK",
      "attributes" => Map.merge(%{"role" => "REVIEWER"}, attributes)
    }

  defp linear(nodes) do
    ids = Enum.map(nodes, & &1["id"])

    edges =
      ids
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.with_index(1)
      |> Enum.map(fn {[from, to], i} -> %{"id" => "e#{i}", "source" => from, "target" => to} end)

    %{"nodes" => nodes, "edges" => edges}
  end

  defp start_node, do: %{"id" => "start", "node_type" => "START"}
  defp end_node, do: %{"id" => "end", "node_type" => "END"}

  # HUMAN child that COMPLETES with its lines: START -> ht(lines X) -> END
  defp completing_human_child, do: Fx.graph([x_line()])

  # HUMAN child that CONTINUES: START -> h1(lines X) -> h2 -> END
  defp continuing_human_child,
    do:
      linear([
        start_node(),
        human("h1", %{"entity_writes" => [x_line()]}),
        human("h2", %{}),
        end_node()
      ])

  # START -> ct (HUMAN gate) -> svc (HTTP, lines X) -> [h2] -> END. The HUMAN gate comes first
  # because a child created by a SUB_PROCESS node arms no dispatch row for a SERVICE_TASK
  # directly after START; completing "ct" arms it.
  defp service_child(:completing) do
    linear([start_node(), human("ct", %{}), service_node(), end_node()])
  end

  defp service_child(:continuing) do
    linear([start_node(), human("ct", %{}), service_node(), human("h2", %{}), end_node()])
  end

  defp service_node,
    do: Fx.service_graph([x_line()])["nodes"] |> Enum.find(&(&1["id"] == "svc"))

  defp sub_process(id, definition) do
    %{
      "id" => id,
      "node_type" => "SUB_PROCESS",
      "attributes" => %{"definition_name" => definition.name}
    }
  end

  # start -> split -> each branch -> join -> end
  defp parallel_parent(branches) do
    nodes =
      [start_node(), %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"}] ++
        branches ++ [%{"id" => "join", "node_type" => "PARALLEL_GATEWAY"}, end_node()]

    branch_ids = Enum.map(branches, & &1["id"])

    edges =
      [%{"id" => "p0", "source" => "start", "target" => "split"}] ++
        Enum.flat_map(Enum.with_index(branch_ids), fn {id, i} ->
          [
            %{"id" => "pa#{i}", "source" => "split", "target" => id},
            %{"id" => "pb#{i}", "source" => id, "target" => "join"}
          ]
        end) ++ [%{"id" => "pz", "source" => "join", "target" => "end"}]

    %{"nodes" => nodes, "edges" => edges}
  end

  defp activate!(base, graph),
    do: Fx.legacy_activate!(base.schema, base.user, graph, [{"stock_move", "create"}])

  defp start_instance!(base, definition) do
    {:ok, %{instance_id: instance_id}} =
      Engine.create(
        %{
          definition_id: definition.id,
          initial_variables: %{},
          actor_id: base.user.id,
          idempotency_key: Fx.unique("ep-start")
        },
        prefix: base.schema
      )

    instance_id
  end

  defp child_of(base, parent_id, definition) do
    Repo.one!(
      from(p in InstanceProjection,
        where: p.parent_instance_id == ^parent_id and p.definition_id == ^definition.id,
        select: p.instance_id
      ),
      prefix: base.schema
    )
  end

  defp pending_task(base, instance_id, node_id) do
    Repo.one!(
      from(t in Letflow.Engine.Task,
        where: t.instance_id == ^instance_id and t.node_id == ^node_id and t.status == :pending
      ),
      prefix: base.schema
    )
  end

  # ---- workers (closures run on a pinned connection by the harness) ------------------------------

  defp complete_task_fn(base, task) do
    fn ->
      Engine.complete_task(
        task.id,
        %{
          output_variables: %{},
          actor_id: base.user.id,
          idempotency_key: Fx.unique("ep-complete")
        },
        prefix: base.schema
      )
    end
  end

  # Completes the child's HUMAN gate `ct` (sequential, before any race), marks its dispatch row
  # "advanced" and returns the closure that applies the HTTP result.
  defp service_apply_fn(base, child_id) do
    ct = pending_task(base, child_id, "ct")
    assert {:ok, _} = complete_task_fn(base, ct).()

    dispatch =
      from(d in ServiceTaskDispatch, where: d.instance_id == ^child_id)
      |> Repo.one!(prefix: base.schema)
      |> Ecto.Changeset.change(%{status: "advanced"})
      |> Repo.update!(prefix: base.schema)

    fn ->
      Engine.advance_after_service_task_outcome(dispatch.id, {:advance, %{}}, Repo, base.schema)
    end
  end

  # ---- shared assertions ------------------------------------------------------------------------

  defp assert_ok_and_clean(base, overlap, records) do
    assert {:ok, _} = overlap.first
    assert {:ok, _} = overlap.second
    assert length(Fx.records(base.schema, "stock_move")) == records
    assert Fx.dlq_entries(base.schema) == []
    assert {:ok, :valid} = Audit.verify_chain(base.schema)
    overlap
  end

  # the 2 s lock_timeout of the entity-write transactions must leave real room (design 4, "Margin")
  defp assert_margin(overlap) do
    margin = H.margin_ms(overlap.timing)

    assert margin >= 500,
           "lock_timeout margin #{margin} ms is under 500 ms (#{inspect(overlap.timing)}): " <>
             "add the test-env timeout seam of the design"
  end

  defp first_index(queries, pred), do: Enum.find_index(queries, pred)

  # ---- E0s --------------------------------------------------------------------------------------

  describe "E0s: statement order of a service apply that activates a HUMAN task" do
    setup :plain_tenant

    test "the type row is locked before the audit chain row (GH #2704 C-E / GH #2705)", %{
      base: base,
      type_id: type_id
    } do
      ctx = Fx.attach_service!(base, Fx.service_then_human_graph([x_line()]))

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn -> Fx.apply_http(ctx, %{}) end)

      assert {:ok, :advanced} = result

      first_type_row =
        first_index(queries, fn q ->
          q.query =~ "instance_sequence" and q.query =~ "FOR UPDATE" and
            type_id in params(q)
        end)

      first_audit_row = first_index(queries, &(&1.query =~ "audit_chain_locks"))

      first_task_insert = first_index(queries, &(&1.query =~ ~r/INSERT INTO "[^"]+"\."tasks"/))

      assert is_integer(first_type_row) and is_integer(first_audit_row)
      assert is_integer(first_task_insert)
      assert first_type_row < first_audit_row
      # the pre-lock sits before the first merge after :lock_ancestors (hop-chain tokens, then the
      # task activation whose `tasks` INSERT is traced here)
      assert first_type_row < first_task_insert
    end
  end

  describe "E0c: statement order of a completing service CHILD" do
    setup :plain_tenant

    test "parent projection, waiting token, type row, audit chain row", %{
      base: base,
      type_id: type_id
    } do
      s_def = activate!(base, service_child(:completing))
      parent = activate!(base, linear([start_node(), sub_process("sp", s_def), end_node()]))
      parent_id = start_instance!(base, parent)
      s_id = child_of(base, parent_id, s_def)
      apply_fn = service_apply_fn(base, s_id)

      {result, queries} = PlatformTenantFixture.capture_repo_queries(apply_fn)
      assert {:ok, :advanced} = result

      parent_projection =
        first_index(queries, fn q ->
          q.query =~ "instance_projections" and q.query =~ "FOR UPDATE" and
            parent_id in params(q)
        end)

      waiting_token =
        first_index(queries, fn q ->
          q.query =~ "FOR UPDATE" and q.query =~ "waiting_child_instance_id"
        end)

      type_row =
        first_index(queries, fn q ->
          q.query =~ "instance_sequence" and q.query =~ "FOR UPDATE" and type_id in params(q)
        end)

      audit_row = first_index(queries, &(&1.query =~ "audit_chain_locks"))

      assert Enum.all?([parent_projection, waiting_token, type_row, audit_row], &is_integer/1)
      assert parent_projection < waiting_token
      assert waiting_token < type_row
      assert type_row < audit_row
    end
  end

  defp params(q), do: q |> Map.get(:params, []) |> Enum.map(&H.normalize/1)

  # ---- E1 .. E3: the ancestor group versus E -----------------------------------------------------

  describe "E1/E2/E3: entity-type rows versus the ancestor group" do
    setup :plain_tenant

    test "E1: a completing HUMAN child and a completing service sibling", %{
      base: base,
      type_id: type_id
    } do
      h_def = activate!(base, completing_human_child())
      s_def = activate!(base, service_child(:completing))

      parent =
        activate!(base, parallel_parent([sub_process("sp_h", h_def), sub_process("sp_s", s_def)]))

      parent_id = start_instance!(base, parent)
      h_id = child_of(base, parent_id, h_def)
      s_id = child_of(base, parent_id, s_def)

      h = complete_task_fn(base, pending_task(base, h_id, "ht"))
      s = service_apply_fn(base, s_id)

      overlap = H.forced_overlap(base.schema, {:sequence, type_id}, h, s)
      assert_ok_and_clean(base, overlap, 2)
      assert_margin(overlap)

      assert Fx.projection!(base.schema, parent_id).status == :completed
      assert length(Fx.instance_events(base.schema, parent_id, "SUB_PROCESS_COMPLETED")) == 2
    end

    test "E2a: a continuing HUMAN child against the parent's own completion", %{
      base: base,
      type_id: type_id
    } do
      c_def = activate!(base, continuing_human_child())

      parent =
        activate!(
          base,
          parallel_parent([
            sub_process("sp_c", c_def),
            human("ph", %{"entity_writes" => [x_line()]})
          ])
        )

      parent_id = start_instance!(base, parent)
      c_id = child_of(base, parent_id, c_def)

      child = complete_task_fn(base, pending_task(base, c_id, "h1"))
      own = complete_task_fn(base, pending_task(base, parent_id, "ph"))

      overlap = H.forced_overlap(base.schema, {:sequence, type_id}, child, own)
      assert_ok_and_clean(base, overlap, 2)
      assert_margin(overlap)

      assert Fx.projection!(base.schema, c_id).status == :active
    end

    test "E2b: a continuing HUMAN child against a completing service sibling", %{
      base: base,
      type_id: type_id
    } do
      c_def = activate!(base, continuing_human_child())
      s_def = activate!(base, service_child(:completing))

      parent =
        activate!(base, parallel_parent([sub_process("sp_c", c_def), sub_process("sp_s", s_def)]))

      parent_id = start_instance!(base, parent)
      c_id = child_of(base, parent_id, c_def)
      s_id = child_of(base, parent_id, s_def)

      child = complete_task_fn(base, pending_task(base, c_id, "h1"))
      sibling = service_apply_fn(base, s_id)

      overlap = H.forced_overlap(base.schema, {:sequence, type_id}, child, sibling)
      assert_ok_and_clean(base, overlap, 2)
      assert_margin(overlap)

      assert Fx.projection!(base.schema, c_id).status == :active
      assert Fx.projection!(base.schema, s_id).status == :completed
    end

    # E2c was measured RED on main: the continuing service sibling activates a HUMAN task (`h2`),
    # so on main it takes the audit chain row BEFORE the type rows while the HUMAN sibling takes
    # the type rows before the audit chain row (the I4 inversion), a 40P01 on `instance_sequence`.
    # After PR-1 it is GREEN. It does NOT discriminate the group's lock mode (a FOR UPDATE group
    # would give the same order and no deadlock): E2d does.
    test "E2c: two continuing siblings (red on main by I4, green after PR-1)", %{
      base: base,
      type_id: type_id
    } do
      c_def = activate!(base, continuing_human_child())
      s_def = activate!(base, service_child(:continuing))

      parent =
        activate!(base, parallel_parent([sub_process("sp_c", c_def), sub_process("sp_s", s_def)]))

      parent_id = start_instance!(base, parent)
      c_id = child_of(base, parent_id, c_def)
      s_id = child_of(base, parent_id, s_def)

      child = complete_task_fn(base, pending_task(base, c_id, "h1"))
      sibling = service_apply_fn(base, s_id)

      overlap = H.forced_overlap(base.schema, {:sequence, type_id}, child, sibling)
      assert_ok_and_clean(base, overlap, 2)
      assert_margin(overlap)

      assert Fx.projection!(base.schema, c_id).status == :active
      assert Fx.projection!(base.schema, s_id).status == :active
    end

    test "E3: a HUMAN child completion against the parent's OWN completion", %{
      base: base,
      type_id: type_id
    } do
      h_def = activate!(base, completing_human_child())

      parent =
        activate!(
          base,
          parallel_parent([
            sub_process("sp_h", h_def),
            human("ph", %{"entity_writes" => [x_line()]})
          ])
        )

      parent_id = start_instance!(base, parent)
      h_id = child_of(base, parent_id, h_def)

      # the CHILD starts first (it gets E first), the parent second: the start order is part of
      # the test, with the opposite order main happens to be green
      child = complete_task_fn(base, pending_task(base, h_id, "ht"))
      own = complete_task_fn(base, pending_task(base, parent_id, "ph"))

      overlap = H.forced_overlap(base.schema, {:sequence, type_id}, child, own)
      assert_ok_and_clean(base, overlap, 2)
      assert_margin(overlap)

      assert Fx.projection!(base.schema, parent_id).status == :completed
      assert length(Fx.instance_events(base.schema, parent_id, "SUB_PROCESS_COMPLETED")) == 1
    end
  end

  # ---- E2d / E4x: the group's lock MODE and the execution-error transition ------------------------

  # the statements that lock the parent projection or a waiting token, as {table, mode}
  defp group_lock_modes(queries, parent_id) do
    for q <- queries,
        q.query =~ ~r/FOR (UPDATE|KEY SHARE)/,
        kind = group_kind(q, parent_id),
        do: {kind, if(q.query =~ "FOR KEY SHARE", do: :key_share, else: :update)}
  end

  defp group_kind(q, parent_id) do
    cond do
      q.query =~ "instance_projections" and parent_id in params(q) -> :parent_projection
      q.query =~ "waiting_child_instance_id" -> :waiting_token
      true -> nil
    end
  end

  defp assert_key_share_group(modes) do
    assert {:parent_projection, :key_share} in modes
    assert {:waiting_token, :key_share} in modes
    refute Enum.any?(modes, fn {_kind, mode} -> mode == :update end), inspect(modes)
  end

  describe "E2d/E4x: group mode and execution error" do
    setup :plain_tenant

    test "E2d: a continuing HUMAN child takes the group FOR KEY SHARE, never FOR UPDATE", %{
      base: base
    } do
      c_def = activate!(base, continuing_human_child())
      parent = activate!(base, linear([start_node(), sub_process("sp", c_def), end_node()]))
      parent_id = start_instance!(base, parent)
      c_id = child_of(base, parent_id, c_def)
      complete = complete_task_fn(base, pending_task(base, c_id, "h1"))

      {result, queries} = PlatformTenantFixture.capture_repo_queries(complete)
      assert {:ok, _} = result

      assert_key_share_group(group_lock_modes(queries, parent_id))
    end

    test "E2d: a continuing service child takes the group FOR KEY SHARE, never FOR UPDATE", %{
      base: base
    } do
      s_def = activate!(base, service_child(:continuing))
      parent = activate!(base, linear([start_node(), sub_process("sp", s_def), end_node()]))
      parent_id = start_instance!(base, parent)
      s_id = child_of(base, parent_id, s_def)
      apply_fn = service_apply_fn(base, s_id)

      {result, queries} = PlatformTenantFixture.capture_repo_queries(apply_fn)
      assert {:ok, :advanced} = result

      assert_key_share_group(group_lock_modes(queries, parent_id))
    end

    test "E4x: an execution-error transition does not raise; the landing takes the KEY SHARE pair",
         %{
           base: base
         } do
      graph =
        linear([
          start_node(),
          human("ht", %{"entity_writes" => [x_line()]}),
          %{"id" => "xg", "node_type" => "EXCLUSIVE_GATEWAY"},
          end_node()
        ])

      # the only edge out of the gateway never matches: the :transition step ends in an execution
      # error, so the completion's own :lock_ancestors step returns {:ok, []}
      graph =
        update_in(graph, ["edges"], fn edges ->
          Enum.map(edges, fn
            %{"source" => "xg"} = edge ->
              Map.put(edge, "condition", "variables.approved == true")

            edge ->
              edge
          end)
        end)

      c_def = activate!(base, graph)
      parent = activate!(base, linear([start_node(), sub_process("sp", c_def), end_node()]))
      parent_id = start_instance!(base, parent)
      c_id = child_of(base, parent_id, c_def)
      task = pending_task(base, c_id, "ht")

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          Engine.complete_task(
            task.id,
            %{
              output_variables: %{"approved" => false},
              actor_id: base.user.id,
              idempotency_key: Fx.unique("ep-xerr")
            },
            prefix: base.schema
          )
        end)

      assert {:error, {:instance_execution_error, _type, _affected}} = result
      assert Fx.projection!(base.schema, c_id).status == :error
      assert Fx.records(base.schema, "stock_move") == []

      # the completion's own `:lock_ancestors` step took nothing (its result is `{:ok, []}`); since
      # GH #2709 the ExecutionError landing itself locks the group, `FOR KEY SHARE` and never
      # `FOR UPDATE` (the landing never completes the child), so that is the only group lock here
      assert_key_share_group(group_lock_modes(queries, parent_id))

      # ... and it is taken before the first UPDATE of the child's projection (the FK checks queue
      # on the second one)
      first_group =
        first_index(queries, fn q -> q.query =~ "FOR KEY SHARE" and group_kind(q, parent_id) end)

      first_update =
        first_index(queries, &(&1.query =~ ~r/UPDATE "[^"]+"\."instance_projections"/))

      assert is_integer(first_group) and is_integer(first_update)
      assert first_group < first_update
    end
  end

  # ---- E5 / E6: A versus E, no parent (GH #2705, "I4") -----------------------------------------

  describe "E5: a service apply that activates a HUMAN task versus a HUMAN completion" do
    setup :plain_tenant

    test "the service apply holds the type row before the audit chain row", %{base: base} do
      # the HUMAN case's instance creation already wrote task.create audits, so the tenant's one
      # `audit_chain_locks` row exists (`hold_row/2` asserts it)
      service = Fx.attach_service!(base, Fx.service_then_human_graph([x_line()]))
      human = Fx.attach!(base, [x_line()])

      overlap =
        H.forced_overlap(
          base.schema,
          :audit_chain,
          fn -> Fx.apply_http(service, %{}) end,
          fn -> Fx.complete(human, %{}) end
        )

      assert {:ok, :advanced} = overlap.first
      assert {:ok, _} = overlap.second
      assert length(Fx.records(base.schema, "stock_move")) == 2
      assert {:ok, :valid} = Audit.verify_chain(base.schema)
      assert_margin(overlap)
    end
  end

  describe "E6: the type is reached only through a module write handler" do
    setup do
      base = Mw.committed_tenant!("gh2704-e6")
      {:ok, balance_id} = EntityTypeInstance.get_or_create("fxl_balance", base.schema)
      {:ok, _ledger_id} = EntityTypeInstance.get_or_create("fxl_ledger", base.schema)
      %{base: base, balance_id: balance_id}
    end

    test "the union pre-lock covers a handler-only target (red with a lines-only pre-lock)", %{
      base: base
    } do
      schema = base.schema

      svc_def = Mw.activate_installed!(schema, base.user, "fxl_svc_then_human")
      pending = Fx.start_service_instance!(base, svc_def)

      dispatch =
        pending.dispatch
        |> Ecto.Changeset.change(%{status: "advanced"})
        |> Repo.update!(prefix: schema)

      service = %{pending | dispatch: dispatch}

      human_def = Mw.activate_installed!(schema, base.user, "fxl_post_module")
      {human_instance, human_task} = Fx.start!(schema, human_def)
      human = Map.merge(base, %{instance_id: human_instance, task: human_task})

      overlap =
        H.forced_overlap(
          schema,
          :audit_chain,
          fn -> Fx.apply_http(service, %{"label" => "svc-label"}) end,
          fn -> Fx.complete(human, %{"label" => "human-label"}) end
        )

      assert {:ok, :advanced} = overlap.first
      assert {:ok, _} = overlap.second
      # the handler writes: post_balance_only -> 1 fxl_balance record; post_entry -> 1 each
      assert length(Fx.records(schema, "fxl_balance")) == 2
      assert length(Fx.records(schema, "fxl_ledger")) == 1
      assert {:ok, :valid} = Audit.verify_chain(schema)
      assert_margin(overlap)
    end
  end
end
