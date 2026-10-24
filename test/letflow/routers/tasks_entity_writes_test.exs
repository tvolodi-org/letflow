defmodule Letflow.Routers.TasksEntityWritesTest do
  @moduledoc """
  GH #2587 / REQ-499 PR B2 (design `gh2587-req499-pr-b-human-task-writes.md` sections 8 and
  10; tests B-7 (HTTP half), B-11 (AuditRead holder sees the full trail), B-18): the HTTP
  surface of a HUMAN_TASK completion that carries `entity_writes`.

  Dispatches into the real `Letflow.Routers.Tasks`, `Letflow.Routers.Instances` and
  `Letflow.Routers.Audit` with a hand-assigned auth context. `async: false` (the entity
  port double is application env).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias Ecto.Multi
  alias Letflow.Definitions.ActivatedBy
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Entities.EntityPortImpl
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Identity.User
  alias Letflow.Repo

  defmodule ProbePort do
    @moduledoc false
    @behaviour Letflow.Engine.EntityPort

    defp report(call) do
      case :persistent_term.get({__MODULE__, :pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:port_call, call})
        _ -> :ok
      end
    end

    @impl true
    def authorize_module_writes(lines, ctx),
      do: EntityPortImpl.authorize_module_writes(lines, ctx)

    @impl true
    def prefetch(prefix, reads, vars), do: EntityPortImpl.prefetch(prefix, reads, vars)

    @impl true
    def prepare(lines, ctx) do
      report(:prepare)
      EntityPortImpl.prepare(lines, ctx)
    end

    @impl true
    def validate_lines(lines, ctx), do: EntityPortImpl.validate_lines(lines, ctx)

    @impl true
    def multi(multi, lines, ctx) do
      report(:multi)
      base = EntityPortImpl.multi(multi, lines, ctx)

      if :persistent_term.get({__MODULE__, :deadlock}, false) do
        Multi.run(base, :chaos, fn _repo, _changes ->
          raise %Postgrex.Error{postgres: %{code: :deadlock_detected, message: "x"}}
        end)
      else
        base
      end
    end

    @impl true
    def interpret_failure(step, reason), do: EntityPortImpl.interpret_failure(step, reason)
  end

  setup do
    previous = Application.fetch_env(:letflow, :entity_port)
    :persistent_term.put({ProbePort, :pid}, self())

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:letflow, :entity_port, value)
        :error -> Application.delete_env(:letflow, :entity_port)
      end

      :persistent_term.erase({ProbePort, :pid})
      :persistent_term.erase({ProbePort, :deadlock})
    end)

    :ok
  end

  defp lines do
    [
      Map.put(
        Fx.line("stock_move", %{"label" => %{"var" => "label"}}),
        "output_record_id_var",
        "_sys.move"
      )
    ]
  end

  defp case!(the_lines \\ lines()) do
    ctx = Fx.case!("gh2587-b2r", the_lines)
    :ok = Letflow.SodSupport.grant_role!(ctx.schema, "REVIEWER", [ctx.user.id])
    ctx
  end

  defp complete(ctx, body, user_id, roles) do
    conn(:post, "/#{ctx.task.id}/complete")
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{user_id: user_id, tenant_id: ctx.tenant.tenant_id, roles: roles})
    |> assign(:trace_id, "gh2587-b2-trace")
    |> then(&Letflow.Routers.Tasks.call(&1, Letflow.Routers.Tasks.init([])))
  end

  defp complete_ok(ctx, body), do: complete(ctx, body, ctx.user.id, ["TENANT_ADMIN", "REVIEWER"])

  defp get(router, path, ctx, roles) do
    conn(:get, path)
    |> assign(:auth_context, %{
      user_id: ctx.user.id,
      tenant_id: ctx.tenant.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "gh2587-b2-trace")
    |> then(&router.call(&1, router.init([])))
  end

  # T-0250: a valid-looking document is signed through the product path (non-maps pass as they are).

  defp signed_for(ctx, doc) when is_map(doc) do
    row = Repo.get!(ProcessDefinition, ctx.definition.id, prefix: ctx.schema)

    {:ok, signed} = ActivatedBy.sign(doc, row, ctx.schema)

    signed
  end

  defp signed_for(_ctx, doc), do: doc

  defp set_activated_by!(ctx, activated_by) do
    {1, _} =
      from(d in ProcessDefinition, where: d.id == ^ctx.definition.id)
      |> Repo.update_all([set: [activated_by: signed_for(ctx, activated_by)]], prefix: ctx.schema)
  end

  test "success: 200, and the response carries no _sys key (CO-1) while the projection does" do
    ctx = case!()
    conn = complete_ok(ctx, %{"label" => "L1"})

    assert conn.status == 200, conn.resp_body
    body = Jason.decode!(conn.resp_body)
    assert body["variables"] == %{"label" => "L1"}

    assert Enum.any?(
             Map.keys(Fx.projection!(ctx.schema, ctx.instance_id).variables),
             &String.starts_with?(&1, "_sys.")
           )
  end

  describe "B-7: one write_not_permitted body for every cause" do
    test "not-authorized pair and restricted field are byte-identical" do
      a = case!()

      set_activated_by!(a, %{
        "user_id" => a.user.id,
        "roles" => ["TENANT_ADMIN"],
        "permissions" => ["EntitiesRecordsWrite"],
        "authorized" => [],
        "activated_at" => DateTime.to_iso8601(DateTime.utc_now())
      })

      conn_a = complete_ok(a, %{"label" => "L1"})

      b = case!()

      Repo.insert_all(
        "entity_field_restrictions",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            entity_type: "stock_move",
            field_name: "label",
            inserted_at: NaiveDateTime.utc_now(),
            updated_at: NaiveDateTime.utc_now()
          }
        ],
        prefix: b.schema
      )

      conn_b = complete_ok(b, %{"label" => "L1"})

      assert conn_a.status == 403
      assert conn_b.status == 403
      assert conn_a.resp_body == conn_b.resp_body

      assert Jason.decode!(conn_a.resp_body) == %{
               "error" => "write_not_permitted",
               "line_index" => 0
             }

      refute conn_a.resp_body =~ "stock_move"
      refute conn_a.resp_body =~ "label"
    end
  end

  test "B-7 extended: managed, not-writable, not-append-only and not-authorised are one body" do
    bodies =
      for cause <- [:not_authorized, :not_writable, :not_append_only, :managed] do
        ctx = case!()

        case cause do
          :not_authorized ->
            set_activated_by!(ctx, %{
              "user_id" => ctx.user.id,
              "roles" => ["TENANT_ADMIN"],
              "permissions" => ["EntitiesRecordsWrite"],
              "authorized" => [],
              "activated_at" => DateTime.to_iso8601(DateTime.utc_now())
            })

          :not_writable ->
            Fx.define_type!(ctx.schema, "stock_move", %{writable_by_process: false})

          :not_append_only ->
            Fx.define_type!(ctx.schema, "stock_move", %{append_only: false})

          :managed ->
            Fx.install_managed_fixture!(ctx.schema)

            {:ok, _} =
              Letflow.Entities.EntityTypeInstance.get_or_create("fxm_ledger", ctx.schema)

            snapshot =
              Repo.get!(Letflow.Definitions.InstanceDefinitionSnapshot, ctx.instance_id,
                prefix: ctx.schema
              )

            nodes =
              Enum.map(snapshot.graph["nodes"], fn
                %{"id" => "ht", "attributes" => attrs} = node ->
                  lines = [Fx.line("fxm_ledger", %{"label" => %{"var" => "label"}})]
                  %{node | "attributes" => Map.put(attrs, "entity_writes", lines)}

                node ->
                  node
              end)

            {1, _} =
              from(s in Letflow.Definitions.InstanceDefinitionSnapshot,
                where: s.instance_id == ^ctx.instance_id
              )
              |> Repo.update_all([set: [graph: %{snapshot.graph | "nodes" => nodes}]],
                prefix: ctx.schema
              )

            set_activated_by!(ctx, %{
              "user_id" => ctx.user.id,
              "roles" => ["TENANT_ADMIN"],
              "permissions" => ["EntitiesRecordsWrite"],
              "authorized" => [%{"entity_type" => "fxm_ledger", "op" => "create"}],
              "activated_at" => DateTime.to_iso8601(DateTime.utc_now())
            })
        end

        conn = complete_ok(ctx, %{"label" => "L1"})
        assert conn.status == 403, "#{cause}: #{conn.resp_body}"
        conn.resp_body
      end

    assert [body] = Enum.uniq(bodies)
    assert Jason.decode!(body) == %{"error" => "write_not_permitted", "line_index" => 0}
  end

  test "validation failure is 422 with a code and the declared index only" do
    ctx = case!([Fx.line("stock_move", %{"label" => %{"var" => "absent"}})])
    conn = complete_ok(ctx, %{"other" => 1})

    assert conn.status == 422
    assert Jason.decode!(conn.resp_body) == %{"error" => "validation_failed", "line_index" => 0}
  end

  test "a deactivated activator is 409 entity_write_needs_reactivation, task stays pending" do
    ctx = case!()

    {1, _} =
      from(u in User, where: u.id == ^ctx.user.id)
      |> Repo.update_all([set: [status: :inactive]], prefix: ctx.schema)

    conn = complete_ok(ctx, %{"label" => "L1"})

    assert conn.status == 409
    assert Jason.decode!(conn.resp_body) == %{"error" => "entity_write_needs_reactivation"}
    assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
  end

  test "contention is 503 with a null line index" do
    ctx = case!()
    Application.put_env(:letflow, :entity_port, ProbePort)
    :persistent_term.put({ProbePort, :deadlock}, true)

    conn = complete_ok(ctx, %{"label" => "L1"})

    assert conn.status == 503

    assert Jason.decode!(conn.resp_body) == %{
             "error" => "entity_write_contention",
             "line_index" => nil
           }

    assert Fx.all_records(ctx.schema) == []
  end

  test "the fail-closed 'lines but no plan' refusal is an explicit 500, not the catch-all" do
    ctx = case!()
    Repo.query!("SET session_replication_role = replica")

    try do
      Repo.delete_all(from(d in ProcessDefinition, where: d.id == ^ctx.definition.id),
        prefix: ctx.schema
      )
    after
      Repo.query!("SET session_replication_role = DEFAULT")
    end

    conn = complete_ok(ctx, %{"label" => "L1"})
    assert conn.status == 500
    refute conn.resp_body =~ "not_planned"
    assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
  end

  describe "B-18: the completer scope check runs before any line is built" do
    test "a caller who does not hold the assigned role is 403 and the port is never called" do
      ctx = case!()
      Application.put_env(:letflow, :entity_port, ProbePort)
      stranger = Fx.user!(ctx.schema, "stranger")

      conn = complete(ctx, %{"label" => "L1"}, stranger.id, ["TENANT_ADMIN"])

      assert conn.status == 403
      refute_received {:port_call, _}

      assert Repo.aggregate("entity_type_instances", :count, prefix: ctx.schema) == 0
      assert Fx.all_records(ctx.schema) == []
    end
  end

  describe "B-11 / OQ-B4: history drops the ids, the audit trail keeps them" do
    test "an AuditRead holder sees record id, completer and definition version" do
      ctx = case!()
      assert complete_ok(ctx, %{"label" => "L1"}).status == 200
      [record] = Fx.records(ctx.schema, "stock_move")

      history =
        get(Letflow.Routers.Instances, "/#{ctx.instance_id}/history", ctx, ["TENANT_ADMIN"])

      assert history.status == 200
      refute history.resp_body =~ record.record_id
      refute history.resp_body =~ "INSTANCE_SYS_VARIABLES_SET"
      assert history.resp_body =~ "TASK_ENTITY_WRITES_APPLIED"

      audit = get(Letflow.Routers.Audit, "/?resource_type=entity_record", ctx, ["TENANT_ADMIN"])
      assert audit.status == 200
      assert [item] = Jason.decode!(audit.resp_body)["items"]
      assert item["action"] == "entity_write.process_step"
      assert item["actor_id"] == ctx.user.id
      assert item["after_state"]["record_id"] == record.record_id
      assert item["after_state"]["definition_version"] == "1.0.0"
    end
  end
end
