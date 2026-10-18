defmodule Letflow.Engine.EntityParentLockOrderTest do
  @moduledoc """
  GH #2704 / #2705 PR-1 (design `lib/letflow/design/gh2704-lock-order-family.md`, section 4.1;
  decision 0061): the entity-type rows (`E`) versus the ancestor group of a sub-process child
  (parent projection, then waiting token) and versus the tenant-wide audit chain row (`A`).

  One global order for both child kinds: `P_c`, ancestor group, `E`, `A`, `S_c`, ...

    * E0s: statement order of a service apply (parent group, then the type rows, then `A`);
    * E1: a completing HUMAN child and a completing service sibling, both with lines on one type;
    * E2a / E2b / E2c: a CONTINUING HUMAN child (key-share group) against the parent's own
      completion, a completing sibling, and a continuing sibling (the control: key-share is
      compatible, so C-P does not serialise continuing siblings);
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

  defp report_margin(label, overlap) do
    IO.puts(
      "MARGIN #{label} timing=#{inspect(overlap.timing)} margin_ms=#{H.margin_ms(overlap.timing)}"
    )
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

      IO.puts("E0s type_row=#{first_type_row} audit_chain=#{first_audit_row}")
      assert is_integer(first_type_row) and is_integer(first_audit_row)
      assert first_type_row < first_audit_row
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
      report_margin("E1", overlap)

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
      report_margin("E2a", overlap)

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
      report_margin("E2b", overlap)

      assert Fx.projection!(base.schema, c_id).status == :active
      assert Fx.projection!(base.schema, s_id).status == :completed
    end

    test "E2c (control): two continuing siblings are not serialised on the group", %{
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
      report_margin("E2c", overlap)

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
      report_margin("E3", overlap)

      assert Fx.projection!(base.schema, parent_id).status == :completed
      assert length(Fx.instance_events(base.schema, parent_id, "SUB_PROCESS_COMPLETED")) == 1
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
      report_margin("E5", overlap)
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
      report_margin("E6", overlap)
    end
  end
end
