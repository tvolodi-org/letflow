Code.require_file("procurement_fixture.exs", __DIR__)

defmodule Letflow.Modules.Procurement.AttachmentRoutesTest do
  @moduledoc """
  GH #3503 / REQ-626 parts A and B (H1..H5 for the submitted branch), the HTTP half of criteria 1, 2, 4, 9 and 10 (spec: state/tasks/T-0962/design.md,
  tests A3, R2, D1..D3, S2, S3, S6, T1, P3): the four attachment routes through the full pipeline
  (`Letflow.Router`) with real tokens.

  The over-limit case is the real 413 of the JSON body parser (2 MiB, about 1.5 MiB of file): the
  25 MiB rule itself is tested in `AttachmentsTest`.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Modules.Procurement.Attachment
  alias Letflow.Modules.Procurement, as: Manifest
  alias Letflow.Modules.Procurement.Router
  alias Letflow.ProcurementFixture, as: Fixture
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.Repo

  @base "/api/v1/modules/procurement/purchase-requests"

  setup do
    a = Fixture.tenant!("gh3503ra")
    b = Fixture.tenant!("gh3503rb")

    users = %{
      admin: Fixture.user!(a, ["TENANT_ADMIN"]),
      decider: Fixture.user!(a, ["TENANT_ADMIN"]),
      worker: Fixture.user!(a, ["TASK_WORKER"]),
      other: Fixture.user!(b, ["TENANT_ADMIN"])
    }

    conn = call(:post, @base, users.admin, Fixture.params(a))
    %{"document_id" => id} = Jason.decode!(conn.resp_body)
    Map.merge(users, %{a: a, b: b, id: id})
  end

  defp call(method, path, user, body \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body when is_binary(body) ->
          conn(method, path, body) |> put_req_header("content-type", "application/json")

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer " <> user.plaintext)
    |> put_req_header("x-tenant-slug", user.slug)
    |> put_req_header("x-trace-id", "t-3503")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp json(conn), do: M.json(conn)

  defp upload(name \\ "a.pdf", bytes \\ "hello", type \\ "application/pdf"),
    do: %{"file_name" => name, "content_type" => type, "content_base64" => Base.encode64(bytes)}

  defp attach(ctx, user \\ nil, id \\ nil, body \\ nil) do
    call(:post, "#{@base}/#{id || ctx.id}/attachments", user || ctx.admin, body || upload())
  end

  defp rows(ctx), do: Repo.aggregate(Attachment, :count, prefix: ctx.a.schema)

  test "A3 and D1: attach, list, download with the safe headers", ctx do
    hostile = "\"; x=1\r\n.pdf"
    conn = attach(ctx, nil, nil, upload(hostile, "BYTES"))
    assert conn.status == 201
    view = json(conn)
    assert Map.has_key?(view, "attachment_id") and Map.has_key?(view, "slot_id")
    refute Map.has_key?(view, "content_hash")
    refute conn.resp_body =~ Base.encode16(:crypto.hash(:sha256, "BYTES"), case: :lower)

    conn = call(:get, "#{@base}/#{ctx.id}/attachments", ctx.admin)
    assert conn.status == 200
    assert %{"version_no" => 1, "attachments" => [%{"attachment_id" => id}]} = json(conn)
    assert id == view["attachment_id"]

    conn = call(:get, "#{@base}/#{ctx.id}/attachments/#{id}/content", ctx.admin)
    assert conn.status == 200
    assert conn.resp_body == "BYTES"
    assert [type] = get_resp_header(conn, "content-type")
    assert type =~ "application/pdf"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~r/\Aattachment; filename="/
    refute disposition =~ ~r/[\r\n]/
  end

  defp submit!(ctx) do
    {:ok, _} =
      Letflow.Modules.Procurement.PurchaseRequests.submit_for_bpm(
        ctx.a.schema,
        ctx.admin.user_id,
        %{document_id: ctx.id, version_no: 1, content_hash: nil, idempotency_key: "s-1"}
      )
  end

  test "replace by slot id on the open draft", ctx do
    view = attach(ctx) |> json()
    path = "#{@base}/#{ctx.id}/attachments/#{view["slot_id"]}/replace"
    conn = call(:post, path, ctx.admin, upload("b.pdf", "new"))
    assert conn.status == 201
    assert %{"replaces_id" => replaced, "slot_id" => slot} = json(conn)
    assert replaced == view["attachment_id"] and slot == view["slot_id"]
  end

  test "H1: replace on a submitted request makes version 2 and keeps version 1", ctx do
    view = attach(ctx, nil, nil, upload("a.pdf", "original")) |> json()
    submit!(ctx)
    path = "#{@base}/#{ctx.id}/attachments/#{view["slot_id"]}/replace"

    conn = call(:post, path, ctx.admin, upload("b.pdf", "newer"))
    assert conn.status == 201
    assert %{"version_no" => 2, "replaces_id" => replaced} = json(conn)
    assert replaced == view["attachment_id"]

    conn = call(:get, "#{@base}/#{ctx.id}/attachments?version_no=1", ctx.admin)
    assert %{"version_no" => 1, "attachments" => [%{"attachment_id" => id}]} = json(conn)
    assert id == view["attachment_id"]
    conn = call(:get, "#{@base}/#{ctx.id}/attachments/#{id}/content", ctx.admin)
    assert conn.status == 200 and conn.resp_body == "original"

    conn = call(:get, "#{@base}/#{ctx.id}/attachments", ctx.admin)
    assert %{"version_no" => 2, "attachments" => [%{"file_name" => "b.pdf"}]} = json(conn)
  end

  test "H2: attach on a submitted request makes version 2", ctx do
    attach(ctx)
    submit!(ctx)
    conn = attach(ctx, nil, nil, upload("n.pdf", "n"))
    assert conn.status == 201 and json(conn)["version_no"] == 2
    assert rows(ctx) == 3
  end

  test "H3: the decider reads version 1 after the replace", ctx do
    view = attach(ctx, nil, nil, upload("a.pdf", "original")) |> json()
    submit!(ctx)
    path = "#{@base}/#{ctx.id}/attachments/#{view["slot_id"]}/replace"
    assert call(:post, path, ctx.admin, upload("b.pdf", "newer")).status == 201

    conn = call(:get, "#{@base}/#{ctx.id}/attachments?version_no=1", ctx.decider)
    assert %{"attachments" => [%{"attachment_id" => id}]} = json(conn)
    assert id == view["attachment_id"]
    conn = call(:get, "#{@base}/#{ctx.id}/attachments/#{id}/content", ctx.decider)
    assert conn.status == 200 and conn.resp_body == "original"
  end

  test "H4: on a submitted request a worker gets 403 and a non-requester 404", ctx do
    view = attach(ctx) |> json()
    submit!(ctx)
    path = "#{@base}/#{ctx.id}/attachments/#{view["slot_id"]}/replace"
    before = rows(ctx)

    assert attach(ctx, ctx.worker).status == 403
    assert call(:post, path, ctx.worker, upload()).status == 403
    assert call(:post, path, ctx.decider, upload()).status == 404
    assert attach(ctx, ctx.decider).status == 404
    assert rows(ctx) == before
    assert Repo.aggregate(Letflow.Documents.DocumentVersion, :count, prefix: ctx.a.schema) == 1
  end

  test "H5: tenant B cannot attach or replace on tenant A's submitted request", ctx do
    view = attach(ctx) |> json()
    submit!(ctx)
    before = rows(ctx)
    absent = Ecto.UUID.generate()

    norm = fn conn ->
      {conn.status, conn.resp_body |> Jason.decode!() |> Map.drop(["trace_id", "instance"])}
    end

    foreign_attach = call(:post, "#{@base}/#{ctx.id}/attachments", ctx.other, upload()) |> norm.()
    absent_attach = call(:post, "#{@base}/#{absent}/attachments", ctx.other, upload()) |> norm.()
    assert {404, _} = foreign_attach
    assert foreign_attach == absent_attach

    path = "#{@base}/#{ctx.id}/attachments/#{view["slot_id"]}/replace"
    foreign_replace = call(:post, path, ctx.other, upload()) |> norm.()

    absent_replace =
      call(
        :post,
        "#{@base}/#{absent}/attachments/#{view["slot_id"]}/replace",
        ctx.other,
        upload()
      )
      |> norm.()

    assert {404, _} = foreign_replace
    assert foreign_replace == absent_replace

    assert rows(ctx) == before
    assert Repo.aggregate(Letflow.Documents.DocumentVersion, :count, prefix: ctx.a.schema) == 1
  end

  test "R2: refusals over HTTP: type, body, base64, over the parser limit", ctx do
    conn = attach(ctx, nil, nil, upload("a.html", "x", "text/html"))
    assert conn.status == 422 and json(conn)["reason"] == "content_type_not_allowed"

    conn = attach(ctx, nil, nil, %{upload() | "content_base64" => "***"})
    assert conn.status == 422 and json(conn)["reason"] == "validation"

    conn = attach(ctx, nil, nil, Map.delete(upload(), "file_name"))
    assert conn.status == 422

    big = upload("big.pdf", :binary.copy("a", 2_200_000))
    # Plug.Test has no endpoint error handler: the parser's RequestTooLargeError (a 413) is raised
    assert_raise Plug.Conn.WrapperError, ~r/RequestTooLargeError/, fn ->
      attach(ctx, nil, nil, big)
    end

    assert rows(ctx) == 0
  end

  test "D2 and S3: absent, malformed and foreign ids look the same", ctx do
    view = attach(ctx) |> json()
    id = view["attachment_id"]

    responses =
      for path <- [
            "#{@base}/#{ctx.id}/attachments/#{Ecto.UUID.generate()}/content",
            "#{@base}/#{ctx.id}/attachments/nope/content",
            "#{@base}/#{Ecto.UUID.generate()}/attachments/#{id}/content"
          ] do
        conn = call(:get, path, ctx.admin)
        {conn.status, conn.resp_body |> Jason.decode!() |> Map.drop(["trace_id", "instance"])}
      end

    assert [{404, body}, {404, body}, {404, body}] = responses

    # tenant B's token with tenant A's ids
    for {method, path, payload} <- [
          {:get, "#{@base}/#{ctx.id}/attachments", nil},
          {:get, "#{@base}/#{ctx.id}/attachments/#{id}/content", nil},
          {:post, "#{@base}/#{ctx.id}/attachments", upload()},
          {:post, "#{@base}/#{ctx.id}/attachments/#{view["slot_id"]}/replace", upload()}
        ] do
      assert call(method, path, ctx.other, payload).status == 404
    end

    assert rows(ctx) == 1
  end

  test "S3: tenant, prefix and uploader in the body are ignored", ctx do
    body =
      Map.merge(upload(), %{
        "uploaded_by" => Ecto.UUID.generate(),
        "prefix" => "public",
        "tenant" => "x"
      })

    assert %{"uploaded_by" => by} = attach(ctx, nil, nil, body) |> json()
    assert by == ctx.admin.user_id
  end

  test "S2: the permission gate answers 403 first, even for an absent id", ctx do
    absent = Ecto.UUID.generate()
    assert attach(ctx, ctx.worker, absent).status == 403

    assert call(:post, "#{@base}/#{absent}/attachments/#{absent}/replace", ctx.worker, upload()).status ==
             403

    assert call(:get, "#{@base}/#{absent}/attachments", ctx.worker).status == 403

    assert call(:get, "#{@base}/#{absent}/attachments/#{absent}/content", ctx.worker).status ==
             403

    assert rows(ctx) == 0
  end

  test "S6: a decider reads but cannot attach or replace", ctx do
    view = attach(ctx) |> json()
    assert attach(ctx, ctx.decider).status == 404

    assert call(
             :post,
             "#{@base}/#{ctx.id}/attachments/#{view["slot_id"]}/replace",
             ctx.decider,
             upload()
           ).status == 404

    assert call(:get, "#{@base}/#{ctx.id}/attachments", ctx.decider).status == 200

    assert call(
             :get,
             "#{@base}/#{ctx.id}/attachments/#{view["attachment_id"]}/content",
             ctx.decider
           ).status == 200

    assert rows(ctx) == 1
  end

  test "T1 and D3: exactly four routes, with the existing permissions, none by hash", _ctx do
    expected = [
      {"POST", "/purchase-requests/:id/attachments", :ProcurementRequestWrite},
      {"GET", "/purchase-requests/:id/attachments", :ProcurementRequestRead},
      {"GET", "/purchase-requests/:id/attachments/:attachment_id/content",
       :ProcurementRequestRead},
      {"POST", "/purchase-requests/:id/attachments/:attachment_id/replace",
       :ProcurementRequestWrite}
    ]

    policies = Manifest.manifest().route_policies

    assert Enum.filter(policies, &String.contains?(elem(&1, 1), "attachments")) |> Enum.sort() ==
             Enum.sort(expected)

    assert length(policies) == 14

    routes = Router.__authz_routes__() |> inspect()
    refute routes =~ "hash"
    assert length(Regex.scan(~r/attachments/, routes)) >= 4
  end
end
