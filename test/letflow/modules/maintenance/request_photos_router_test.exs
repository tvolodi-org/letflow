Code.require_file("../stock/stock_fixture.exs", __DIR__)
Code.require_file("../assets/assets_fixture.exs", __DIR__)

defmodule Letflow.Modules.Maintenance.RequestPhotosRouterTest do
  @moduledoc """
  REQ-895 / GH #4805 criteria 1 to 5 through the full `Letflow.Router` with real OIDC bearer tokens on
  committed tenants: P-01 add and read, P-02 cap, P-03 state, P-04 isolation (INV-5, INV-10),
  P-05 access and flag off. `async: false`, Sandbox `:auto`; the flag is on in `config/test.exs` and
  turned off only inside P-05.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsFixture, as: A
  alias Letflow.Attachments.Link
  alias Letflow.AttachmentsImageFixture, as: Fx
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.Modules.Installs
  alias Letflow.StockFixture, as: S

  @moduletag :tmp_dir

  @base "/api/v1/modules/maintenance"
  @modules ["org", "catalog_items", "locations", "codes", "stock", "assets", "maintenance"]

  setup do
    ctx = S.setup_oidc!([:a, :b])
    a = tenant!("mnt-pa", ctx.names.a)
    b = tenant!("mnt-pb", ctx.names.b)

    ctx =
      Map.merge(ctx, %{
        a: a,
        b: b,
        tok_a: S.token(ctx, :a, ["TENANT_ADMIN"]),
        tok_b: S.token(ctx, :b, ["TENANT_ADMIN"])
      })

    {:ok, Map.merge(ctx, %{unit_a: unit!(ctx.tok_a), unit_b: unit!(ctx.tok_b)})}
  end

  defp tenant!(prefix, realm) do
    t = S.tenant!(prefix, realm, install: false)
    {:ok, _} = Letflow.Entities.EventTypes.seed!(t.schema_name)
    on_exit(fn -> S.drop_pack_rows!(t.tenant_id) end)

    for m <- @modules do
      {:ok, _} =
        Installs.install(m, Ecto.UUID.generate(),
          prefix: t.schema_name,
          rationale: "test: REQ-895"
        )
    end

    t
  end

  defp call(method, path, token, body \\ nil, json? \\ true) do
    conn =
      case {body, json?} do
        {nil, _} -> Plug.Test.conn(method, @base <> path)
        {body, true} -> Plug.Test.conn(method, @base <> path, Jason.encode!(body))
        {body, false} -> Plug.Test.conn(method, @base <> path, body)
      end

    conn =
      if json?, do: Plug.Conn.put_req_header(conn, "content-type", "application/json"), else: conn

    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp key, do: Ecto.UUID.generate()

  defp json!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    Jason.decode!(conn.resp_body)
  end

  defp unit!(tok) do
    n = System.unique_integer([:positive])
    org = fn path, body -> org_post!(tok, path, Map.put(body, "idempotency_key", key())) end

    le =
      org.("/legal-entities", %{
        "code" => "L#{n}",
        "name" => "L#{n}",
        "bin" => String.pad_leading("#{n}", 12, "1")
      })["record_id"]

    site =
      org.("/sites", %{"code" => "S#{n}", "name" => "S#{n}", "legal_entity_id" => le})[
        "record_id"
      ]

    org.("/units", %{
      "code" => "U#{n}",
      "name" => "U#{n}",
      "legal_entity_id" => le,
      "site_id" => site
    })["record_id"]
  end

  defp org_post!(tok, path, body) do
    conn =
      Plug.Test.conn(:post, "/api/v1/modules/org" <> path, Jason.encode!(body))
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> tok)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))

    json!(conn, 201)
  end

  defp card!(schema, unit) do
    n = "M-#{System.unique_integer([:positive])}"
    A.card!(schema, n, %{"org_unit_id" => unit, "name" => "Pump #{n}"}).record_id
  end

  defp request!(ctx) do
    body = %{
      "asset_card_id" => card!(ctx.a.schema_name, ctx.unit_a),
      "description" => "Leaking pump",
      "urgency" => "normal",
      "idempotency_key" => key()
    }

    json!(call(:post, "/requests", ctx.tok_a, body), 201)
  end

  defp file!(tmp, bytes) do
    path = Path.join(tmp, "p#{System.unique_integer([:positive])}.jpg")
    File.write!(path, bytes)
    %Plug.Upload{path: path, filename: "declared.jpg", content_type: "application/octet-stream"}
  end

  defp upload(tmp, id, n, extra \\ %{}, token) do
    body = Map.merge(%{"original" => file!(tmp, Fx.jpeg(pad: n))}, extra)
    call(:post, "/requests/#{id}/photos", token, body, false)
  end

  defp list(id, token), do: call(:get, "/requests/#{id}/photos", token)

  defp links(ctx, id) do
    Repo.aggregate(from(l in Link, where: l.owner_id == ^id), :count, prefix: ctx.a.schema_name)
  end

  test "P-01: add, list, read the bytes; the request view shows photo_count", ctx do
    r = request!(ctx)
    assert r["photo_count"] == 0

    photo = json!(upload(ctx.tmp_dir, r["id"], 1, %{"caption" => "Leak"}, ctx.tok_a), 201)
    assert photo["caption"] == "Leak"
    assert {:ok, _} = Ecto.UUID.cast(photo["id"])
    refute Map.has_key?(photo, "uploaded_by")
    refute Map.has_key?(photo, "uploader_id")
    refute inspect(photo) =~ "uploaded"

    assert [%{"id" => id}] = json!(list(r["id"], ctx.tok_a), 200)["photos"]
    assert id == photo["id"]

    original = call(:get, "/requests/#{r["id"]}/photos/#{photo["id"]}/original", ctx.tok_a)
    assert original.status == 200
    assert Plug.Conn.get_resp_header(original, "content-type") == ["image/jpeg"]
    assert Plug.Conn.get_resp_header(original, "x-content-type-options") == ["nosniff"]
    assert Plug.Conn.get_resp_header(original, "content-disposition") == ["inline"]

    assert Plug.Conn.get_resp_header(original, "cache-control") ==
             ["private, max-age=86400"]

    assert is_binary(original.resp_body) and byte_size(original.resp_body) > 0

    assert json!(call(:get, "/requests/#{r["id"]}", ctx.tok_a), 200)["photo_count"] == 1
  end

  test "P-02: the sixth photo is refused 422 owner_cap_reached and the list keeps five", ctx do
    r = request!(ctx)
    for n <- 1..5, do: json!(upload(ctx.tmp_dir, r["id"], n, ctx.tok_a), 201)

    refused = json!(upload(ctx.tmp_dir, r["id"], 6, ctx.tok_a), 422)
    assert refused["reason"] == "owner_cap_reached"

    assert length(json!(list(r["id"], ctx.tok_a), 200)["photos"]) == 5
    assert links(ctx, r["id"]) == 5
  end

  test "P-03: after the reject an upload is 409 request_not_new and adds nothing; reads work",
       ctx do
    r = request!(ctx)
    photo = json!(upload(ctx.tmp_dir, r["id"], 1, ctx.tok_a), 201)
    json!(call(:post, "/requests/#{r["id"]}/reject", ctx.tok_a, %{"reason" => "dup"}), 200)

    refused = json!(upload(ctx.tmp_dir, r["id"], 2, ctx.tok_a), 409)
    assert refused["reason"] == "request_not_new"
    assert links(ctx, r["id"]) == 1

    assert [%{"id" => id}] = json!(list(r["id"], ctx.tok_a), 200)["photos"]
    assert id == photo["id"]

    assert call(:get, "/requests/#{r["id"]}/photos/#{photo["id"]}/original", ctx.tok_a).status ==
             200

    assert json!(call(:get, "/requests/#{r["id"]}", ctx.tok_a), 200)["photo_count"] == 1
  end

  test "P-04: another request's photo and another tenant's request are the 404 of an unknown photo",
       ctx do
    r1 = request!(ctx)
    r2 = request!(ctx)
    photo = json!(upload(ctx.tmp_dir, r1["id"], 1, ctx.tok_a), 201)

    unknown =
      call(:get, "/requests/#{r2["id"]}/photos/#{Ecto.UUID.generate()}/original", ctx.tok_a)

    assert unknown.status == 404

    for which <- ["original", "thumbnail"] do
      cross = call(:get, "/requests/#{r2["id"]}/photos/#{photo["id"]}/#{which}", ctx.tok_a)
      assert cross.status == 404
    end

    other_request =
      call(:get, "/requests/#{r2["id"]}/photos/#{photo["id"]}/original", ctx.tok_a)

    assert M.strip(Jason.decode!(other_request.resp_body)) ==
             M.strip(Jason.decode!(unknown.resp_body))

    # Tenant B's administrator reads and writes against tenant A's request and photo.
    foreign = [
      call(:get, "/requests/#{r1["id"]}/photos", ctx.tok_b),
      call(:get, "/requests/#{r1["id"]}/photos/#{photo["id"]}/original", ctx.tok_b),
      call(:get, "/requests/#{r1["id"]}/photos/#{photo["id"]}/thumbnail", ctx.tok_b),
      upload(ctx.tmp_dir, r1["id"], 9, ctx.tok_b)
    ]

    for conn <- foreign, do: assert(conn.status == 404)

    bodies =
      for conn <- [unknown | foreign], do: M.strip(Jason.decode!(conn.resp_body))

    assert bodies |> Enum.uniq() |> length() == 1

    for id <- ["not-a-uuid", Ecto.UUID.generate()] do
      assert list(id, ctx.tok_a).status == 404
      assert upload(ctx.tmp_dir, id, 10, ctx.tok_a).status == 404
    end

    assert links(ctx, r1["id"]) == 1
  end

  describe "P-05: access" do
    test "TASK_WORKER and TENANT_AUDITOR get 403 on the upload and on the list", ctx do
      r = request!(ctx)
      photo = json!(upload(ctx.tmp_dir, r["id"], 1, ctx.tok_a), 201)

      for role <- ["TASK_WORKER", "TENANT_AUDITOR"] do
        tok = S.token(ctx, :a, [role], sub: "mnt-photo-#{role}")
        assert json!(upload(ctx.tmp_dir, r["id"], 2, tok), 403)["title"] == "Forbidden", role
        assert json!(list(r["id"], tok), 403)["title"] == "Forbidden", role

        original = call(:get, "/requests/#{r["id"]}/photos/#{photo["id"]}/original", tok)
        assert original.status == 403, role
      end

      assert links(ctx, r["id"]) == 1
    end

    test "flag off: every photo route answers 404 with one body and nothing is added", ctx do
      r = request!(ctx)
      photo = json!(upload(ctx.tmp_dir, r["id"], 1, ctx.tok_a), 201)

      old = Application.get_env(:letflow, :maintenance_enabled)
      Application.put_env(:letflow, :maintenance_enabled, false)
      on_exit(fn -> Application.put_env(:letflow, :maintenance_enabled, old) end)

      conns = [
        upload(ctx.tmp_dir, r["id"], 2, ctx.tok_a),
        list(r["id"], ctx.tok_a),
        call(:get, "/requests/#{r["id"]}/photos/#{photo["id"]}/original", ctx.tok_a),
        call(:get, "/requests/#{r["id"]}/photos/#{photo["id"]}/thumbnail", ctx.tok_a)
      ]

      for conn <- conns, do: assert(conn.status == 404)
      bodies = for conn <- conns, do: M.strip(Jason.decode!(conn.resp_body))
      assert bodies |> Enum.uniq() |> length() == 1
      assert links(ctx, r["id"]) == 1
      refute Letflow.Modules.Maintenance.enabled?()
    end
  end

  test "P-06: no new atom, no baseline role widened; photo policies reuse the existing atoms" do
    manifest = Letflow.Modules.Maintenance.manifest()

    assert manifest.permissions == [
             :MaintenanceRequestCreate,
             :MaintenanceRead,
             :MaintenanceOrderManage
           ]

    assert manifest.role_grants == %{}

    photo_policies =
      Enum.filter(manifest.route_policies, &String.contains?(elem(&1, 1), "/photos"))

    assert length(photo_policies) == 4
    assert {"POST", "/requests/:id/photos", :MaintenanceRequestCreate} in photo_policies

    assert Enum.sort(Enum.map(photo_policies, &elem(&1, 2))) ==
             [:MaintenanceRead, :MaintenanceRead, :MaintenanceRead, :MaintenanceRequestCreate]
  end
end
