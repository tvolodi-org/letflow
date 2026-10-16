defmodule Letflow.Routers.TasksModuleWritesTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R4b (design section 8): the HTTP surface of a HUMAN_TASK completion that
  carries `module_writes`.

    * success is 200 and the history response keeps only `line_index` + `entity_type` of each
      applied line (no handler key, no record id);
    * a stamp / hash / handler refusal is the SAME 403 body as REQ-499's declarative refusals:
      `{"error":"write_not_permitted","line_index":N}`, byte for byte (INV-5);
    * handler "invalid arguments" is the 422 `validation_failed` body;
    * a handler fault (a raise) is the bare 500: no module id, handler name, exception text.

  Dispatches into the real `Letflow.Routers.Tasks` and `Letflow.Routers.Instances` with a
  hand-assigned auth context. `async: false` (module install, tenant provisioning).
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.ModuleWritesFixture, as: Mw

  defp complete(ctx, body) do
    :ok = Letflow.SodSupport.grant_role!(ctx.schema, "REVIEWER", [ctx.user.id])

    conn(:post, "/#{ctx.task.id}/complete")
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: ctx.user.id,
      tenant_id: ctx.tenant.tenant_id,
      roles: ["TENANT_ADMIN", "REVIEWER"]
    })
    |> assign(:trace_id, "gh2590-r4b-trace")
    |> then(&Letflow.Routers.Tasks.call(&1, Letflow.Routers.Tasks.init([])))
  end

  defp get(router, path, ctx) do
    conn(:get, path)
    |> assign(:auth_context, %{
      user_id: ctx.user.id,
      tenant_id: ctx.tenant.tenant_id,
      roles: ["TENANT_ADMIN"]
    })
    |> assign(:trace_id, "gh2590-r4b-trace")
    |> then(&router.call(&1, router.init([])))
  end

  test "success: 200, and the history keeps only line_index and entity_type per line" do
    ctx = Mw.case!("gh2590-r4b-http-ok", :module)
    conn = complete(ctx, %{"label" => "L1"})
    assert conn.status == 200, conn.resp_body

    [record | _] = Fx.records(ctx.schema, "fxl_ledger")
    history = get(Letflow.Routers.Instances, "/#{ctx.instance_id}/history", ctx)

    assert history.status == 200
    assert history.resp_body =~ "TASK_ENTITY_WRITES_APPLIED"
    refute history.resp_body =~ record.record_id
    refute history.resp_body =~ "fixture_ledger"
    refute history.resp_body =~ "post_entry"
    refute history.resp_body =~ "write_ordinal"
  end

  test "a handler refusal is byte-identical to a declarative write_not_permitted (INV-5)" do
    handler = Mw.case!("gh2590-r4b-http-403", :module)
    Mw.set_installed_hash!(handler.schema, "fixture_ledger", String.duplicate("c", 64))
    handler_conn = complete(handler, %{"label" => "L1"})

    declarative =
      Fx.case!("gh2590-r4b-http-403d", [Fx.line("stock_move", %{"label" => %{"var" => "label"}})])

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
      prefix: declarative.schema
    )

    declarative_conn = complete(declarative, %{"label" => "L1"})

    assert handler_conn.status == 403
    assert declarative_conn.status == 403
    assert handler_conn.resp_body == declarative_conn.resp_body

    assert Jason.decode!(handler_conn.resp_body) == %{
             "error" => "write_not_permitted",
             "line_index" => 0
           }

    refute handler_conn.resp_body =~ "fixture_ledger"
    refute handler_conn.resp_body =~ "hash"
  end

  test "a MIXED node reports the declared index of the handler call (1)" do
    ctx = Mw.case!("gh2590-r4b-http-idx", :mixed)
    Mw.set_installed_hash!(ctx.schema, "fixture_ledger", nil)
    conn = complete(ctx, %{"label" => "L1"})

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => "write_not_permitted", "line_index" => 1}
    assert Fx.records(ctx.schema, "stock_move") == []
  end

  test "handler invalid arguments is the 422 validation_failed body" do
    ctx = Mw.case!("gh2590-r4b-http-422", :module)
    conn = complete(ctx, %{})

    assert conn.status == 422
    assert Jason.decode!(conn.resp_body) == %{"error" => "validation_failed", "line_index" => 0}
  end

  test "a handler that raises is a bare 500: no module, handler or exception text" do
    ctx = Mw.rogue_case!("gh2590-r4b-http-500", "raises")
    conn = complete(ctx, %{})

    assert conn.status == 500
    refute conn.resp_body =~ "fixture_ledger_rogue"
    refute conn.resp_body =~ "raises"
    refute conn.resp_body =~ "secret detail"
    refute conn.resp_body =~ "boom"
    assert Fx.all_records(ctx.schema) == []
  end
end
