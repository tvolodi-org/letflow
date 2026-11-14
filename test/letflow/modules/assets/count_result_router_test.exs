Code.require_file("counts_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.CountResultRouterTest do
  @moduledoc """
  REQ-819 / GH #4372 (asset count K4) through the full `Letflow.Router` with real OIDC bearer tokens:
  RT1 (the life of a result through the three routes), RT2 (an administrator outside the signer role: 403),
  RT3 (a role that is not set up: 422), RT4 (a refused draft names the line), RT5 (tenant B on tenant A's
  count), RT6 (the flag and the permission), RT7 (a body on sign). Committed tenants, Sandbox `:auto`,
  `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsCountsFixture, as: F
  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Identity.User

  @moduletag timeout: 300_000

  setup do
    ctx = D.setup!([:a, :b, :n])
    n = S.tenant!("ast-ck4n", ctx.names.n, install: false)
    F.enable!(ctx.schema)
    b = D.tenant_b!(ctx)
    F.enable!(b.b.schema_name)
    ctx = Map.merge(ctx, Map.merge(b, %{n: n, tok_n: S.token(ctx, :n, ["TENANT_ADMIN"])}))
    {:ok, Map.put(ctx, :sw, F.sheet_world!(ctx.schema, ctx.ma))}
  end

  defp strip(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, %{} = map} -> Map.delete(map, "trace_id")
      _ -> conn.resp_body
    end
  end

  # A token whose user exists in tenant `key` (the first request provisions it); returns {token, user_id}.
  defp user_token(ctx, key, schema, sub) do
    tok = S.token(ctx, key, ["TENANT_ADMIN"], sub: sub)
    assert D.request(:get, "/counts", tok).status == 200
    {tok, Repo.one!(from(u in User, where: u.username == ^sub), prefix: schema).id}
  end

  # A token whose user holds the routing role `accountant` of tenant A.
  defp signer_token(ctx, sub \\ "signer-k4") do
    {tok, uid} = user_token(ctx, :a, ctx.schema, sub)
    F.signer!(ctx.schema, uid, "accountant")
    tok
  end

  defp forged(ctx), do: F.forged_sheet!(ctx, [forged_line()])

  defp forged_line do
    %{
      "line_no" => 1,
      "kind" => "book",
      "asset_id" => Ecto.UUID.generate(),
      "asset_kind" => "fixed",
      "book_material_responsible_id" => Ecto.UUID.generate(),
      "book_quantity" => "1",
      "counted_quantity" => "0"
    }
  end

  describe "the life of a result" do
    test "RT1: read, decide and sign with the token of a signer", ctx do
      w = F.world7!(ctx)
      tok = signer_token(ctx)
      id = w.id

      view = D.request(:get, "/counts/#{id}/result", tok) |> D.status!(200)
      assert view["status"] == "sheet_signed" and view["line_count"] == 7

      assert view["signer_role"] == %{
               "name" => "accountant",
               "configured" => true,
               "held" => true
             }

      decided =
        D.request(:put, "/counts/#{id}/result/lines/#{w.no.f6}", tok, %{"decision" => "writeoff"})
        |> D.status!(200)

      assert decided["decision"] == "writeoff" and decided["difference"] == "condition"

      signed = D.request(:post, "/counts/#{id}/result/sign", tok, %{}) |> D.status!(200)
      assert signed["status"] == "signed" and String.starts_with?(signed["result_number"], "ACR")
      assert Enum.count(signed["lines"], & &1["document_id"]) == 6

      order = D.request(:get, "/counts/#{id}", tok) |> D.status!(200)
      assert order["status"] == "signed" and order["result_number"] == signed["result_number"]
      assert is_binary(order["signed_at"]) and is_binary(order["signed_by"])

      assert D.request(:post, "/counts/#{id}/result/sign", tok, %{})
             |> D.status!(422)
             |> Map.get("reason") ==
               "count_state_invalid"
    end

    test "RT2: an administrator outside the group reads, but cannot decide or sign", ctx do
      id = forged(ctx)
      _signer = signer_token(ctx)
      {admin, _} = user_token(ctx, :a, ctx.schema, "admin-k4")

      assert %{"signer_role" => %{"held" => false, "configured" => true}} =
               D.request(:get, "/counts/#{id}/result", admin) |> D.status!(200)

      put = D.request(:put, "/counts/#{id}/result/lines/1", admin, %{"decision" => "writeoff"})
      assert put.status == 403 and strip(put)["reason"] == "signer_role_not_held"
      post = D.request(:post, "/counts/#{id}/result/sign", admin, %{})
      assert post.status == 403 and strip(post)["reason"] == "signer_role_not_held"

      assert D.request(:get, "/counts/#{id}", admin) |> D.status!(200) |> Map.get("status") ==
               "sheet_signed"
    end

    test "RT3: a role that is not set up is 422, the read says so", ctx do
      id = forged(ctx)
      tok = signer_token(ctx)
      F.put_setting!(ctx.schema, "count_signer_role", "nobody")

      assert %{"configured" => false} =
               D.request(:get, "/counts/#{id}/result", tok)
               |> D.status!(200)
               |> Map.get("signer_role")

      for {method, path, body} <- [
            {:put, "/counts/#{id}/result/lines/1", %{"decision" => "writeoff"}},
            {:post, "/counts/#{id}/result/sign", %{}}
          ] do
        conn = D.request(method, path, tok, body)
        assert conn.status == 422 and strip(conn)["reason"] == "signer_role_not_configured", path
      end
    end

    test "RT4: a refused draft is 422 with its reason and the result line", ctx do
      s = ctx.schema
      m = ctx.ma
      a = D.card!(s, "fixed", m.unit)
      b = D.card!(s, "fixed", m.unit)
      D.commission!(ctx, D.body(m, %{"lines" => [%{"asset_id" => a, "quantity" => "1"}]}))
      id = F.ordered!(ctx)
      F.open!(ctx, id)
      F.record!(ctx, id, a, %{"found" => false})
      no = F.surplus!(ctx, id, %{"asset_id" => b, "observed_location_id" => m.location})
      F.finish!(ctx, id)
      tok = signer_token(ctx)

      conn = D.request(:post, "/counts/#{id}/result/sign", tok, %{})
      assert conn.status == 422
      body = strip(conn)
      assert body["reason"] == "field_required" and body["field"] == "material_responsible_id"
      assert body["line_no"] == no

      assert D.request(:get, "/counts/#{id}", tok) |> D.status!(200) |> Map.get("status") ==
               "sheet_signed"
    end

    test "RT7: a body on sign is refused before anything happens", ctx do
      id = forged(ctx)
      tok = signer_token(ctx)
      conn = D.request(:post, "/counts/#{id}/result/sign", tok, %{"x" => 1})
      assert conn.status == 422
      assert %{"reason" => "field_not_allowed", "field" => "x"} = strip(conn)

      assert D.request(:get, "/counts/#{id}", tok) |> D.status!(200) |> Map.get("status") ==
               "sheet_signed"
    end
  end

  describe "isolation, permission, flag" do
    test "RT5: the signer of tenant B gets the uniform 404 on tenant A's count", ctx do
      id = forged(ctx)
      sb = ctx.b.schema_name
      {tok_b, uid_b} = user_token(ctx, :b, sb, "signer-b-k4")
      F.signer!(sb, uid_b, "accountant")
      tok_a = signer_token(ctx)

      before = D.request(:get, "/counts/#{id}/result", tok_a) |> strip()

      for {method, path, body} <- [
            {:get, "/counts/:id/result", nil},
            {:put, "/counts/:id/result/lines/1", %{"decision" => "writeoff"}},
            {:post, "/counts/:id/result/sign", %{}}
          ] do
        unknown =
          D.request(method, String.replace(path, ":id", Ecto.UUID.generate()), tok_b, body)

        foreign = D.request(method, String.replace(path, ":id", id), tok_b, body)
        assert unknown.status == 404 and foreign.status == 404, path
        assert strip(foreign) == strip(unknown), path
      end

      assert D.request(:get, "/counts/#{id}/result", tok_a) |> strip() == before

      assert D.request(:get, "/counts/#{id}", tok_a) |> D.status!(200) |> Map.get("status") ==
               "sheet_signed"
    end

    test "RT6: with the flag off the three routes are the 404 of a tenant without the module; a worker is 403",
         ctx do
      id = forged(ctx)
      tok = signer_token(ctx)
      worker = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-k4")
      F.disable!(ctx.schema)

      requests = [
        {:get, "/counts/#{id}/result", nil},
        {:put, "/counts/#{id}/result/lines/1", %{"decision" => "writeoff"}},
        {:post, "/counts/#{id}/result/sign", %{}}
      ]

      for {method, path, body} <- requests do
        mine = D.request(method, path, tok, body)
        theirs = D.request(method, path, ctx.tok_n, body)
        assert mine.status == 404 and theirs.status == 404, path
        assert strip(mine) == strip(theirs), path
        assert D.request(method, path, worker, body).status == 403, path
      end
    end
  end
end
