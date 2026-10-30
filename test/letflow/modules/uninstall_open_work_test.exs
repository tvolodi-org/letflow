defmodule Letflow.Modules.UninstallOpenWorkTest do
  @moduledoc """
  REQ-627 / GH #3505 (decision 0066 D8 slice 2): the `open_work_exists` refusal of
  `Installs.uninstall/3`, the new-instance block and their route answers.

    W1  an active instance gives open_work_exists (function and route)
    W2  an open task counts, a terminal instance counts nothing
    S1  the stamp decides, not the name
    W3  a start after uninstall answers the 404 of an unknown definition (id and name)
    W3b a DRAFT stamped definition of an uninstalled module answers 404, not 409
    W4a an open instance with a module-write step blocks uninstall (the stamp checks of
        `module_write_runtime_stamp_test.exs` stay as they are)
    X1  INV-10: two tenants
    F1  the flag defaults to false; flag off, open work: the unknown-path answer
    D1  no delete in installs.ex / start_gate.ex; D2 a refusal changes no row count

  The concurrent interleavings are in `Letflow.Engine.ModuleStartLockOrderTest`.

  `async: false`: tenant provisioning needs `Sandbox.mode(:auto)`; the flag is VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Audit.Entry
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule
  alias Letflow.ModuleWritesFixture, as: Mw

  @why "test: REQ-627"
  @trace "req627-trace-id"
  @module "fixture_ledger"

  setup do
    previous = Application.fetch_env(:letflow, :modules_uninstall_enabled)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:letflow, :modules_uninstall_enabled, value)
        :error -> Application.delete_env(:letflow, :modules_uninstall_enabled)
      end
    end)

    :ok
  end

  defp opts(ctx), do: [prefix: ctx.schema, rationale: @why]
  defp uninstall(ctx), do: Installs.uninstall(@module, ctx.user.id, opts(ctx))
  defp row!(ctx), do: Repo.get_by!(TenantModule, [module_id: @module], prefix: ctx.schema)
  defp audit_count(ctx), do: Repo.aggregate(Entry, :count, prefix: ctx.schema)

  defp cancel!(ctx, instance_id) do
    {:ok, _} =
      Engine.cancel_instance(
        instance_id,
        %{actor_id: ctx.user.id, idempotency_key: Fx.unique("req627-cancel")},
        prefix: ctx.schema
      )
  end

  defp start(ctx, ref) do
    Engine.create(
      Map.merge(ref, %{
        initial_variables: %{},
        actor_id: ctx.user.id,
        idempotency_key: Fx.unique("req627-start")
      }),
      prefix: ctx.schema
    )
  end

  defp counts(ctx) do
    for {name, schema} <- [
          tenant_modules: TenantModule,
          instance_projections: InstanceProjection,
          tasks: EngineTask,
          events: Event,
          audit: Entry,
          process_definitions: Definitions.ProcessDefinition
        ],
        into: %{},
        do: {name, Repo.aggregate(schema, :count, prefix: ctx.schema)}
  end

  # ── routes ──

  defp admin_call(ctx, action) do
    conn(:post, "/#{@module}/#{action}")
    |> Map.put(:body_params, %{"rationale" => @why})
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: ctx.user.id,
      tenant_id: ctx.tenant.tenant_id,
      roles: ["TENANT_ADMIN"]
    })
    |> assign(:trace_id, @trace)
    |> Letflow.Routers.TenantModules.call(Letflow.Routers.TenantModules.init([]))
  end

  defp start_call(ctx, body) do
    conn(:post, "/")
    |> Map.put(:body_params, Map.put_new(body, "initial_variables", %{}))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("idempotency-key", Fx.unique("req627-http"))
    |> assign(:auth_context, %{
      user_id: ctx.user.id,
      tenant_id: ctx.tenant.tenant_id,
      roles: ["PROCESS_OPERATOR"]
    })
    |> assign(:trace_id, @trace)
    |> Letflow.Routers.Instances.call(Letflow.Routers.Instances.init([]))
  end

  describe "W1 / W2 / W4a open work" do
    test "W1 an active instance refuses uninstall; cancelling it lets it pass" do
      ctx = Mw.case!("req627-w1", :plain)
      before = counts(ctx)

      assert {:error, {:open_work_exists, %{open_instances: 1, open_tasks: 1}}} = uninstall(ctx)
      assert row!(ctx).status == :active
      assert counts(ctx) == before

      cancel!(ctx, ctx.instance_id)
      assert {:ok, %TenantModule{status: :uninstalled}} = uninstall(ctx)
    end

    test "W1 route: 409 with the code and the counts, no ids" do
      Application.put_env(:letflow, :modules_uninstall_enabled, true)
      ctx = Mw.case!("req627-w1r", :plain)
      before = audit_count(ctx)

      conn = admin_call(ctx, "uninstall")
      assert conn.status == 409
      body = Jason.decode!(conn.resp_body)
      assert body["code"] == "open_work_exists"
      assert body["open_instances"] == 1
      assert body["open_tasks"] == 1
      refute conn.resp_body =~ ctx.instance_id
      refute conn.resp_body =~ ctx.task.id
      assert row!(ctx).status == :active
      assert audit_count(ctx) == before
    end

    test "W2 a pending task counts; a completed instance and its tasks count nothing" do
      ctx = Mw.case!("req627-w2", :plain)

      pending =
        Repo.aggregate(
          from(t in EngineTask, where: t.status == :pending),
          :count,
          prefix: ctx.schema
        )

      assert {:error, {:open_work_exists, %{open_tasks: ^pending}}} = uninstall(ctx)

      {:ok, _} = Fx.complete(ctx, %{})
      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :completed
      assert Fx.task!(ctx.schema, ctx.task.id).status == :completed
      assert {:ok, %TenantModule{status: :uninstalled}} = uninstall(ctx)
    end

    test "W2 a cancelled instance counts nothing" do
      ctx = Mw.case!("req627-w2c", :plain)
      cancel!(ctx, ctx.instance_id)
      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :cancelled
      assert {:ok, _} = uninstall(ctx)
    end

    test "W4a an open instance of a module-write definition blocks uninstall" do
      ctx = Mw.case!("req627-w4a", :module)
      assert {:error, {:open_work_exists, %{open_instances: 1}}} = uninstall(ctx)
    end

    test "S1 the stamp decides: an active instance of a tenant-made definition is not counted" do
      ctx = Mw.case!("req627-s1", :plain)
      {:ok, _} = Fx.complete(ctx, %{})

      {:ok, row} =
        Definitions.create(
          %{
            name: Fx.unique("req627-own"),
            version: "1.0",
            graph: plain_graph(),
            created_by: ctx.user.id
          },
          prefix: ctx.schema
        )

      {:ok, %{definition: own}} = Definitions.activate(row.id, prefix: ctx.schema)
      {:ok, %{instance_id: own_instance}} = start(ctx, %{definition_id: own.id})
      assert Fx.projection!(ctx.schema, own_instance).status == :active

      assert {:ok, _} = uninstall(ctx)

      # the tenant-made version still starts while the module is uninstalled
      assert {:ok, _} = start(ctx, %{definition_id: own.id})
    end
  end

  describe "W3 / W3b new-instance block" do
    setup do
      ctx = Mw.case!("req627-w3", :plain)
      cancel!(ctx, ctx.instance_id)
      {:ok, _} = uninstall(ctx)
      %{ctx: ctx}
    end

    test "W3 the engine answers :definition_not_found by id and by name, writes nothing", %{
      ctx: ctx
    } do
      before = counts(ctx)

      assert {:error, :definition_not_found} = start(ctx, %{definition_id: ctx.definition.id})
      assert {:error, :definition_not_found} = start(ctx, %{definition_name: ctx.definition.name})
      assert counts(ctx) == before
    end

    test "W3 the route answer is byte-identical to the one for an unknown definition", %{ctx: ctx} do
      unknown_id = start_call(ctx, %{"definition_id" => Ecto.UUID.generate()})
      stamped_id = start_call(ctx, %{"definition_id" => ctx.definition.id})
      unknown_name = start_call(ctx, %{"definition_name" => "no-such-definition-xyz"})
      stamped_name = start_call(ctx, %{"definition_name" => ctx.definition.name})

      assert unknown_id.status == 404
      assert stamped_id.status == 404
      assert stamped_id.resp_body == unknown_id.resp_body
      assert stamped_id.resp_headers == unknown_id.resp_headers
      assert stamped_name.status == 404
      assert stamped_name.resp_body == unknown_name.resp_body
      assert stamped_name.resp_headers == unknown_name.resp_headers
      refute stamped_id.resp_body =~ "uninstall"
      refute stamped_id.resp_body =~ @module
    end

    test "W3 after reactivation the start succeeds", %{ctx: ctx} do
      {:ok, _} = Installs.reactivate(@module, ctx.user.id, opts(ctx))
      assert {:ok, _} = start(ctx, %{definition_id: ctx.definition.id})
    end

    test "W3b a DRAFT stamped definition answers 404, not 409", %{ctx: ctx} do
      draft =
        Repo.one!(
          from(d in Definitions.ProcessDefinition, where: d.name == "fxl_post_module"),
          prefix: ctx.schema
        )

      assert draft.status == :draft
      assert {:error, :definition_not_found} = start(ctx, %{definition_id: draft.id})

      {:ok, _} = Installs.reactivate(@module, ctx.user.id, opts(ctx))
      assert {:error, :definition_not_active} = start(ctx, %{definition_id: draft.id})
    end
  end

  describe "X1 INV-10 two tenants" do
    test "an uninstall in tenant A affects only tenant A" do
      Application.put_env(:letflow, :modules_uninstall_enabled, true)
      a = Mw.case!("req627-xa", :plain)
      b = Mw.case!("req627-xb", :plain)

      conn = admin_call(a, "uninstall")
      assert conn.status == 409
      assert Jason.decode!(conn.resp_body)["open_instances"] == 1

      cancel!(a, a.instance_id)
      assert admin_call(a, "uninstall").status == 200

      assert row!(b).status == :active
      assert Fx.projection!(b.schema, b.instance_id).status == :active
      assert {:ok, _} = start(b, %{definition_id: b.definition.id})
      assert {:error, :definition_not_found} = start(a, %{definition_id: a.definition.id})
      assert start_call(a, %{"definition_id" => a.definition.id}).status == 404
      assert start_call(b, %{"definition_id" => b.definition.id}).status == 201
    end
  end

  describe "F1 flag" do
    test "F1 the flag defaults to false in config" do
      assert File.read!("config/config.exs") =~ ~r/modules_uninstall_enabled,\s*false/
      Application.delete_env(:letflow, :modules_uninstall_enabled)
      refute Installs.uninstall_enabled?()
    end

    test "F1b flag off, open work present: not the 409 and nothing changes" do
      ctx = Mw.case!("req627-f1b", :plain)
      Application.put_env(:letflow, :modules_uninstall_enabled, false)
      before = counts(ctx)

      conn = admin_call(ctx, "uninstall")
      refute conn.status == 409
      refute conn.resp_body =~ "open_work_exists"
      assert counts(ctx) == before
    end
  end

  describe "D1 / D2 no delete, no write on refusal" do
    test "D1 installs.ex and start_gate.ex contain no delete call" do
      for file <- ["lib/letflow/modules/installs.ex", "lib/letflow/modules/start_gate.ex"] do
        refute File.read!(file) =~ ~r/Repo\.delete|delete_all/, file
      end
    end

    test "D2 a refused start writes no row (tenant_modules unchanged)" do
      ctx = Mw.case!("req627-d2", :plain)
      cancel!(ctx, ctx.instance_id)
      {:ok, _} = uninstall(ctx)
      before = counts(ctx)
      {:error, :definition_not_found} = start(ctx, %{definition_id: ctx.definition.id})
      assert counts(ctx) == before
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
