defmodule Letflow.Routers.DefinitionsReactivateTest do
  @moduledoc """
  GH #2692 / REQ-515: `POST /definitions/:id/reactivate` (RA-R1..R7) and the `activation_state`
  view. Dispatches into the real `Letflow.Routers.Definitions` with a hand-assigned auth context.
  `async: false` (tenant fixtures commit).
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Identity
  alias Letflow.Repo

  @opts Letflow.Routers.Definitions.init([])

  defp case! do
    ctx = Fx.case!("gh2692-r", [Fx.line("stock_move", %{"label" => %{"var" => "label"}})])
    deactivate!(ctx)
    ctx
  end

  defp deactivate!(ctx) do
    assert {:ok, _} =
             Identity.update_user_status(ctx.user.id, :inactive,
               prefix: ctx.schema,
               tenant_id: ctx.tenant.tenant_id,
               login_directory: :skip
             )
  end

  defp call(method, path, ctx, user_id, roles, body \\ nil) do
    conn = conn(method, path)

    conn =
      if body,
        do: put_req_header(%{conn | body_params: body}, "content-type", "application/json"),
        else: conn

    conn
    |> assign(:auth_context, %{user_id: user_id, tenant_id: ctx.tenant.tenant_id, roles: roles})
    |> assign(:trace_id, "gh2692-r")
    |> Letflow.Routers.Definitions.call(@opts)
  end

  defp reactivate(ctx, id, user_id, roles),
    do: call(:post, "/#{id}/reactivate", ctx, user_id, roles)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp row(ctx), do: Repo.get!(ProcessDefinition, ctx.definition.id, prefix: ctx.schema)

  test "RA-R1: a current admin reactivates in place and becomes the activator" do
    ctx = case!()
    admin = Fx.user!(ctx.schema, "admin")

    conn = reactivate(ctx, ctx.definition.id, admin.id, ["TENANT_ADMIN"])

    assert conn.status == 200, conn.resp_body
    body = json(conn)
    assert body["status"] == "ACTIVE"
    assert body["activation_state"] == "ok"
    assert body["needs_reactivation_reason"] == nil
    assert row(ctx).activated_by["user_id"] == admin.id
    assert row(ctx).id == ctx.definition.id
  end

  test "RA-R2: an unflagged active row is 409 not_needs_reactivation" do
    ctx = Fx.case!("gh2692-r2", [Fx.line("stock_move", %{"label" => %{"var" => "label"}})])
    admin = Fx.user!(ctx.schema, "admin")

    conn = reactivate(ctx, ctx.definition.id, admin.id, ["TENANT_ADMIN"])

    assert conn.status == 409
    assert json(conn) == %{"error" => "not_needs_reactivation"}
  end

  test "RA-R3: a caller without EntitiesRecordsWrite is 422 entity_writes_invalid, nothing changes" do
    ctx = case!()
    designer = Fx.user!(ctx.schema, "designer")

    conn = reactivate(ctx, ctx.definition.id, designer.id, ["PROCESS_DESIGNER"])

    assert conn.status == 422, conn.resp_body

    assert %{"error" => "entity_writes_invalid", "violations" => [%{"code" => code}]} =
             json(conn)

    assert code == "entity_write_activator_required"
    assert row(ctx).needs_reactivation_at != nil
  end

  test "RA-R4: a role without the definitions write permission is 403, no change" do
    ctx = case!()
    worker = Fx.user!(ctx.schema, "worker")

    conn = reactivate(ctx, ctx.definition.id, worker.id, ["TASK_WORKER"])

    assert conn.status == 403
    assert row(ctx).needs_reactivation_at != nil
  end

  test "RA-R5: an unknown id and another tenant's id are both 404" do
    ctx = case!()
    other = Fx.case!("gh2692-r5", [Fx.line("stock_move", %{"label" => %{"var" => "label"}})])
    admin = Fx.user!(ctx.schema, "admin")

    unknown = reactivate(ctx, Ecto.UUID.generate(), admin.id, ["TENANT_ADMIN"])
    foreign = reactivate(ctx, other.definition.id, admin.id, ["TENANT_ADMIN"])
    malformed = reactivate(ctx, "not-a-uuid", admin.id, ["TENANT_ADMIN"])

    assert unknown.status == 404
    assert foreign.status == 404
    assert malformed.status == 404
    assert unknown.resp_body == foreign.resp_body
    assert row(ctx).needs_reactivation_at != nil
  end

  test "RA-R6: PUT and PATCH naming the server-owned fields are refused" do
    ctx = case!()
    admin = Fx.user!(ctx.schema, "admin")

    for method <- [:put, :patch],
        field <- ["needs_reactivation_at", "needs_reactivation_reason"] do
      conn =
        call(method, "/#{ctx.definition.id}", ctx, admin.id, ["TENANT_ADMIN"], %{field => nil})

      assert conn.status == 422, "#{method} #{field}: #{conn.resp_body}"
    end

    assert row(ctx).needs_reactivation_at != nil
  end

  test "RA-R7: GET shows the flag; status stays ACTIVE" do
    ctx = case!()
    admin = Fx.user!(ctx.schema, "admin")

    conn = call(:get, "/#{ctx.definition.id}", ctx, admin.id, ["TENANT_ADMIN"])

    assert conn.status == 200
    body = json(conn)
    assert body["status"] == "ACTIVE"
    assert body["activation_state"] == "needs_reactivation"
    assert body["needs_reactivation_reason"] == "activator_deactivated"
    assert is_binary(body["needs_reactivation_at"])
    refute Map.has_key?(body, "activated_by")
  end

  test "RA-R8: a new instance start on the flagged definition is 409 definition_needs_reactivation" do
    ctx = case!()

    conn =
      conn(:post, "/")
      |> put_req_header("content-type", "application/json")
      |> Map.put(:body_params, %{"definition_id" => ctx.definition.id, "initial_variables" => %{}})
      |> assign(:auth_context, %{
        user_id: ctx.user.id,
        tenant_id: ctx.tenant.tenant_id,
        roles: ["TENANT_ADMIN"]
      })
      |> assign(:trace_id, "gh2692-r")
      |> put_req_header("idempotency-key", Fx.unique("ra-r8"))
      |> Letflow.Routers.Instances.call(Letflow.Routers.Instances.init([]))

    assert conn.status == 409, conn.resp_body
    assert json(conn) == %{"error" => "definition_needs_reactivation"}
  end
end
