Code.require_file("procurement_fixture.exs", __DIR__)

defmodule Letflow.Modules.Procurement.LineRoutesTest do
  @moduledoc """
  GH #3188 / REQ-558 part 1, the HTTP half of criteria 4, 5 and 9 (spec: state/tasks/T-0763/design.md,
  tests LE-9, LE-13, LE-15b, LE-16, LE-17, LE-21): the four line routes of
  `Letflow.Modules.Procurement.Router` through the full pipeline with real tokens.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Audit.Entry
  alias Letflow.Modules.Procurement.Decisions
  alias Letflow.Modules.Procurement.LineEvent
  alias Letflow.ProcurementFixture, as: Fixture
  alias Letflow.Repo

  @base "/api/v1/modules/procurement/purchase-requests"

  setup do
    a = Fixture.tenant!("gh3188ra")
    b = Fixture.tenant!("gh3188rb")
    admin = Fixture.user!(a, ["TENANT_ADMIN"])
    approver = Fixture.user!(a, ["TENANT_ADMIN"])
    worker = Fixture.user!(a, ["TASK_WORKER"])
    outsider = Fixture.user!(b, ["TENANT_ADMIN"])
    request = Fixture.issued!(a, admin.user_id)

    {:ok, _} =
      Decisions.record(a.schema, approver.user_id, %{
        document_id: request.id,
        version_no: request.version_no,
        content_hash: request.hash,
        decision: "approve",
        idempotency_key: "approve-1"
      })

    %{
      a: a,
      b: b,
      admin: admin,
      approver: approver,
      worker: worker,
      outsider: outsider,
      request: request
    }
  end

  defp call(method, path, user, body \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer " <> user.plaintext)
    |> put_req_header("x-tenant-slug", user.slug)
    |> put_req_header("x-trace-id", "t-3188")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp line_path(ctx, suffix \\ "", line_no \\ 1),
    do: "#{@base}/#{ctx.request.id}/lines/#{line_no}#{suffix}"

  defp supplier_body(id, overrides \\ %{}) do
    Map.merge(
      %{
        "source_system" => "erp",
        "identifier" => id,
        "display_name" => "Supplier " <> id,
        "idempotency_key" => "k-" <> Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp rows(ctx), do: Repo.aggregate(LineEvent, :count, prefix: ctx.schema)
  defp audits(ctx), do: Repo.aggregate(Entry, :count, prefix: ctx.schema)

  test "LE-9: a fresh line shows null, not empty strings, over the route", ctx do
    conn = call(:get, line_path(ctx), ctx.admin)
    assert conn.status == 200

    assert %{
             "officer" => nil,
             "supplier" => nil,
             "procurement_document" => nil,
             "fulfilled_quantity" => "0"
           } = json(conn)
  end

  test "LE-21: first call is 201, the replay 200, the same key with another body 409", ctx do
    body = supplier_body("S1", %{"idempotency_key" => "route-1"})
    path = line_path(ctx, "/supplier")

    conn = call(:post, path, ctx.admin, body)
    assert conn.status == 201
    assert %{"replayed" => false, "identifier" => "S1"} = json(conn)

    conn = call(:post, path, ctx.admin, body)
    assert conn.status == 200
    assert %{"replayed" => true} = json(conn)

    conn = call(:post, path, ctx.admin, %{body | "identifier" => "S2"})
    assert conn.status == 409
    assert %{"reason" => "idempotency_key_reused"} = json(conn)
    assert rows(ctx.a) == 1

    conn =
      call(:post, line_path(ctx, "/officer"), ctx.admin, %{
        "officer_id" => ctx.approver.user_id,
        "idempotency_key" => "o-1"
      })

    assert conn.status == 201

    conn =
      call(:post, line_path(ctx, "/reference"), ctx.admin, %{
        "source_system" => "erp",
        "identifier" => "PO-1",
        "kind" => "purchase_order",
        "idempotency_key" => "r-1"
      })

    assert conn.status == 201

    view = call(:get, line_path(ctx), ctx.admin) |> json()
    assert %{"identifier" => "S1"} = view["supplier"]
    assert %{"user_id" => _} = view["officer"]
    assert %{"kind" => "purchase_order"} = view["procurement_document"]
  end

  test "LE-21b: the validation error names each field; an unapproved request is 409", ctx do
    conn = call(:post, line_path(ctx, "/supplier"), ctx.admin, %{"idempotency_key" => "v-1"})
    assert conn.status == 422

    assert %{"errors" => errors} = json(conn)
    assert Enum.map(errors, & &1["field"]) == ["source_system", "identifier", "display_name"]
    assert rows(ctx.a) == 0

    other = Fixture.issued!(ctx.a, ctx.admin.user_id)
    path = "#{@base}/#{other.id}/lines/1/supplier"
    conn = call(:post, path, ctx.admin, supplier_body("S1"))
    assert conn.status == 409
    assert %{"reason" => "not_approved"} = json(conn)
    assert rows(ctx.a) == 0
  end

  test "LE-13: the requester holding the permission is accepted; a task worker gets 403", ctx do
    assert call(:post, line_path(ctx, "/supplier"), ctx.admin, supplier_body("S1")).status == 201

    before_audits = audits(ctx.a)
    assert call(:post, line_path(ctx, "/supplier"), ctx.worker, supplier_body("S2")).status == 403
    assert call(:get, line_path(ctx), ctx.worker).status == 403
    assert audits(ctx.a) == before_audits
    assert rows(ctx.a) == 1
  end

  test "LE-15b: the no-permission 403 is counted by the HTTP metric, with no audit or event",
       ctx do
    id = "gh3188-http-" <> Ecto.UUID.generate()
    test = self()

    :telemetry.attach(
      id,
      [:letflow, :http, :request],
      fn _event, _measurements, metadata, _config -> send(test, {:http, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    before_audits = audits(ctx.a)

    conn =
      call(:post, line_path(ctx, "/officer"), ctx.worker, %{
        "officer_id" => ctx.worker.user_id,
        "idempotency_key" => "p-1"
      })

    assert conn.status == 403

    assert_received {:http, %{status: 403, method: "POST", route_template: template}}
    assert template =~ "/purchase-requests/:id/lines/:line_no/officer"
    assert audits(ctx.a) == before_audits
    assert rows(ctx.a) == 0
  end

  test "LE-16: absent, malformed and wrong line answer with one identical 404", ctx do
    absent =
      call(
        :post,
        "#{@base}/#{Ecto.UUID.generate()}/lines/1/supplier",
        ctx.admin,
        supplier_body("S1")
      )

    assert absent.status == 404

    for path <- [
          "#{@base}/not-a-uuid/lines/1/supplier",
          line_path(ctx, "/supplier", 9),
          line_path(ctx, "/supplier", 0),
          line_path(ctx, "/supplier", "abc")
        ] do
      conn = call(:post, path, ctx.admin, supplier_body("S1"))
      assert conn.status == 404
      assert normalise(conn) == normalise(absent), path
    end

    assert call(:get, line_path(ctx, "", 9), ctx.admin).status == 404
    assert rows(ctx.a) == 0
  end

  defp normalise(conn), do: json(conn) |> Map.drop(["trace_id", "instance"])

  test "LE-17: another tenant's token cannot reach tenant A's line", ctx do
    absent =
      call(
        :post,
        "#{@base}/#{Ecto.UUID.generate()}/lines/1/supplier",
        ctx.outsider,
        supplier_body("S1")
      )

    foreign = call(:post, line_path(ctx, "/supplier"), ctx.outsider, supplier_body("S1"))
    assert foreign.status == 404
    assert normalise(foreign) == normalise(absent)

    assert call(:get, line_path(ctx), ctx.outsider).status == 404
    assert rows(ctx.a) == 0
    assert rows(ctx.b) == 0
  end
end
