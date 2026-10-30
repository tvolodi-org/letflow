defmodule Letflow.Engine.ModuleStartLockOrderTest do
  @moduledoc """
  REQ-627 / GH #3505 (decision 0066 D4, D8 slice 2; decision 0061): a start of a definition stamped
  with a module share-locks the module's `tenant_modules` row inside the start transaction, and
  `Installs.uninstall/3` holds it FOR UPDATE, so the two serialize.

    * W5a  race-only: the start holds FOR SHARE, the uninstall must wait for it and then refuses;
    * W5b  race-only: the uninstall holds FOR UPDATE with its status update uncommitted, the start
           must wait for it and then answers `:definition_not_found`;
    * L1   the statement log of a start: `tenant_modules FOR SHARE` before the projection insert
           and before any audit chain statement; an unstamped definition issues none.

  Race-only: the interleavings cannot be forced without a hook. A barrier connection holds the audit
  chain row; both REAL transactions take their `tenant_modules` lock first and park on the audit
  chain after it (`Installs.transition/7` -> `Audit.insert_entry`; the start ->
  `record_instance_create_audit`). `backend_query/1` names the statement each parked worker waits in.

  `async: false`: Sandbox `:auto` (real commits, parallel connections).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Engine
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule
  alias Letflow.ModuleWritesFixture, as: Mw
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Test.SandboxAutoMode

  @why "REQ-627 lock order"

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    H.attach_error_handler(__MODULE__)

    base = Mw.committed_tenant!("req627-lo")
    definition = Mw.activate_installed!(base.schema, base.user, "fxl_task_plain")
    Map.put(base, :definition, definition)
  end

  defp start_fn(base) do
    fn ->
      Engine.create(
        %{
          definition_id: base.definition.id,
          initial_variables: %{},
          actor_id: base.user.id,
          idempotency_key: Fx.unique("req627-start")
        },
        prefix: base.schema
      )
    end
  end

  defp uninstall_fn(base) do
    fn ->
      Installs.uninstall("fixture_ledger", base.user.id, prefix: base.schema, rationale: @why)
    end
  end

  defp projections(base), do: Repo.aggregate(InstanceProjection, :count, prefix: base.schema)

  defp module_status(base),
    do: Repo.get_by!(TenantModule, [module_id: "fixture_ledger"], prefix: base.schema).status

  test "W5a race-only: the start holds FOR SHARE, the uninstall waits for it and refuses", ctx do
    {holder, barrier} = H.hold_row(ctx.schema, :audit_chain)

    {s_task, s} = H.start_worker(start_fn(ctx))
    H.wait_for_blocked([s], 1)
    H.await_blocked_by(s, [barrier])
    assert H.backend_query(s) =~ "audit_chain_locks"

    {u_task, u} = H.start_worker(uninstall_fn(ctx))
    H.wait_for_blocked([s, u], 2)
    H.await_blocked_by(u, [s])
    assert H.backend_query(u) =~ "tenant_modules"

    send(holder.pid, :release)
    assert {:ok, _} = Task.await(holder, H.await_ms())

    {s_result, _} = Task.await(s_task, H.await_ms())
    {u_result, _} = Task.await(u_task, H.await_ms())

    assert {:ok, %{status: :active}} = s_result
    assert {:error, {:open_work_exists, %{open_instances: 1}}} = u_result
    assert module_status(ctx) == :active
  end

  test "W5b race-only: the uninstall holds FOR UPDATE, the start waits and then answers 404",
       ctx do
    {holder, barrier} = H.hold_row(ctx.schema, :audit_chain)

    {u_task, u} = H.start_worker(uninstall_fn(ctx))
    H.wait_for_blocked([u], 1)
    H.await_blocked_by(u, [barrier])
    assert H.backend_query(u) =~ "audit_chain_locks"

    {s_task, s} = H.start_worker(start_fn(ctx))
    H.wait_for_blocked([u, s], 2)
    H.await_blocked_by(s, [u])
    query = H.backend_query(s)
    assert query =~ "tenant_modules"
    assert query =~ "FOR SHARE"

    send(holder.pid, :release)
    assert {:ok, _} = Task.await(holder, H.await_ms())

    {u_result, _} = Task.await(u_task, H.await_ms())
    {s_result, _} = Task.await(s_task, H.await_ms())

    assert {:ok, %{status: :uninstalled}} = u_result
    assert {:error, :definition_not_found} = s_result
    assert projections(ctx) == 0
  end

  describe "L1 statement log of a start" do
    defp statements(base, definition) do
      {result, events} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          Engine.create(
            %{
              definition_id: definition.id,
              initial_variables: %{},
              actor_id: base.user.id,
              idempotency_key: Fx.unique("req627-l1")
            },
            prefix: base.schema
          )
        end)

      assert {:ok, _} = result
      Enum.map(events, &to_string(&1.query))
    end

    defp index_of(sqls, fun), do: Enum.find_index(sqls, fun)

    test "L1b a stamped start reads tenant_modules FOR SHARE before the projection and the audit chain",
         ctx do
      sqls = statements(ctx, ctx.definition)

      share =
        index_of(sqls, &(&1 =~ "tenant_modules" and &1 =~ "FOR SHARE"))

      insert = index_of(sqls, &(&1 =~ "INSERT INTO" and &1 =~ "instance_projections"))
      audit = index_of(sqls, &(&1 =~ "audit_chain_locks"))

      assert share, "no tenant_modules FOR SHARE statement in #{inspect(sqls)}"
      assert insert && share < insert
      assert audit && share < audit
    end

    test "L1c an unstamped definition issues no tenant_modules statement", ctx do
      {:ok, row} =
        Letflow.Definitions.create(
          %{
            name: Fx.unique("req627-plain"),
            version: "1.0",
            graph: plain_graph(),
            created_by: ctx.user.id
          },
          prefix: ctx.schema
        )

      {:ok, %{definition: unstamped}} = Letflow.Definitions.activate(row.id, prefix: ctx.schema)
      sqls = statements(ctx, unstamped)
      refute Enum.any?(sqls, &(&1 =~ "tenant_modules"))
    end

    test "L1d the moduledoc of create/2 states the lock order", _ctx do
      {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(Engine)

      doc =
        for {{:function, :create, 2}, _, _, %{"en" => text}, _} <- docs, into: "", do: text

      assert doc =~ "tenant_modules"
      assert doc =~ "0061"
    end
  end

  defp plain_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "ht", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "ht"},
        %{"id" => "e2", "source" => "ht", "target" => "end"}
      ]
    }
  end
end
