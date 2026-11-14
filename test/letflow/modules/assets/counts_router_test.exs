Code.require_file("counts_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.CountsRouterTest do
  @moduledoc """
  REQ-816 / GH #4375 (asset count K1) through the full `Letflow.Router` with real OIDC bearer tokens.
  Criterion 2: K1-S1..S4 (the three settings through the real settings route and the readers).
  Criterion 6: K1-P1, K1-P2 (permission), K1-T1, K1-T2 (INV-10 cross-tenant negatives), K1-RT (the
  life of an order through the routes). Committed tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsCountsFixture, as: F
  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Identity.User
  alias Letflow.Modules.Assets.Settings

  setup do
    ctx = S.setup_oidc!([:a, :b])
    a = S.tenant!("ast-ck1ra", ctx.names.a)
    b = S.tenant!("ast-ck1rb", ctx.names.b)
    F.enable!(a.schema_name)
    F.enable!(b.schema_name)

    {:ok,
     Map.merge(ctx, %{
       a: a,
       b: b,
       sa: a.schema_name,
       sb: b.schema_name,
       tok_a: S.token(ctx, :a, ["TENANT_ADMIN"]),
       tok_b: S.token(ctx, :b, ["TENANT_ADMIN"])
     })}
  end

  defp put_settings(token, body) do
    Plug.Test.conn(:put, "/api/v1/tenant/modules/assets/settings", Jason.encode!(body))
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp strip(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, %{} = map} -> Map.delete(map, "trace_id")
      _ -> conn.resp_body
    end
  end

  describe "criterion 2: settings" do
    test "K1-S1: signer role 1 and 128 codepoints are accepted", ctx do
      base = %{"count_enabled" => true}

      for role <- ["accountant", String.duplicate("р", 128)] do
        conn = put_settings(ctx.tok_a, Map.put(base, "count_signer_role", role))
        assert conn.status == 200, conn.resp_body
        assert Settings.count_signer_role(ctx.sa) == role
      end
    end

    test "K1-S2: an empty and a 129 codepoint role are refused, stored settings unchanged", ctx do
      assert put_settings(ctx.tok_a, %{"count_signer_role" => "chief"}).status == 200

      for role <- ["", String.duplicate("р", 129)] do
        assert put_settings(ctx.tok_a, %{"count_signer_role" => role}).status == 422
      end

      assert Settings.count_signer_role(ctx.sa) == "chief"
    end

    test "K1-S3: freeze limit 1 and 5760 accepted, 0 and 5761 refused", ctx do
      for m <- [1, 5760] do
        assert put_settings(ctx.tok_a, %{"count_freeze_limit_minutes" => m}).status == 200
        assert Settings.count_freeze_limit_minutes(ctx.sa) == m
      end

      for m <- [0, 5761, "60"] do
        assert put_settings(ctx.tok_a, %{"count_freeze_limit_minutes" => m}).status == 422
      end

      assert Settings.count_freeze_limit_minutes(ctx.sa) == 5760
    end

    test "K1-S4: defaults without the keys, the stored values with them", ctx do
      F.disable!(ctx.sa)
      assert Settings.count_enabled?(ctx.sa) == false
      assert Settings.count_signer_role(ctx.sa) == "accountant"
      assert Settings.count_freeze_limit_minutes(ctx.sa) == 120

      body = %{
        "count_enabled" => true,
        "count_signer_role" => "chief",
        "count_freeze_limit_minutes" => 30
      }

      assert put_settings(ctx.tok_a, body).status == 200
      assert Settings.count_enabled?(ctx.sa) == true
      assert Settings.count_signer_role(ctx.sa) == "chief"
      assert Settings.count_freeze_limit_minutes(ctx.sa) == 30

      assert put_settings(ctx.tok_a, %{"count_enabled" => "yes"}).status == 422
    end
  end

  describe "criterion 6: permission" do
    test "K1-P1: a TASK_WORKER may not create an order", ctx do
      w = F.world!(ctx.sa)
      worker = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-k1")
      assert D.request(:post, "/counts", worker, F.input(w)).status == 403
      assert D.request(:get, "/counts", worker).status == 403
    end

    test "K1-P2: a TENANT_ADMIN may", ctx do
      w = F.world!(ctx.sa)
      assert D.request(:post, "/counts", ctx.tok_a, F.input(w)) |> D.status!(201)
    end
  end

  describe "criterion 6: INV-10 cross-tenant negatives" do
    test "K1-T1: tenant A cannot read or write an order of tenant B", ctx do
      wb = F.world!(ctx.sb)

      b_id =
        D.request(:post, "/counts", ctx.tok_b, F.input(wb)) |> D.status!(201) |> Map.get("id")

      unknown = D.request(:get, "/counts/#{Ecto.UUID.generate()}", ctx.tok_a)
      malformed = D.request(:get, "/counts/not-a-uuid", ctx.tok_a)
      assert unknown.status == 404 and malformed.status == 404

      foreign = D.request(:get, "/counts/#{b_id}", ctx.tok_a)
      assert foreign.status == 404
      assert strip(foreign) == strip(unknown)
      assert strip(foreign) == strip(malformed)

      assert D.request(:get, "/counts/#{b_id}", ctx.tok_b) |> D.status!(200) |> Map.get("status") ==
               "draft"
    end

    test "K1-T2: A's list holds none of B's orders, A's writes on B's id are 404 and change nothing",
         ctx do
      wb = F.world!(ctx.sb)

      b_id =
        D.request(:post, "/counts", ctx.tok_b, F.input(wb)) |> D.status!(201) |> Map.get("id")

      wa = F.world!(ctx.sa)
      D.request(:post, "/counts", ctx.tok_a, F.input(wa)) |> D.status!(201)

      rows = D.request(:get, "/counts", ctx.tok_a) |> D.status!(200) |> Map.get("rows")
      assert length(rows) == 1
      refute b_id in Enum.map(rows, & &1["id"])

      for {m, path, body} <- [
            {:put, "/counts/#{b_id}", F.input(wb)},
            {:post, "/counts/#{b_id}/issue", %{}},
            {:post, "/counts/#{b_id}/cancel", %{}}
          ] do
        assert D.request(m, path, ctx.tok_a, body).status == 404, path
      end

      assert D.request(:get, "/counts/#{b_id}", ctx.tok_b) |> D.status!(200) |> Map.get("status") ==
               "draft"
    end

    test "K1-T3: a tenant key in the body is not an allowed field", ctx do
      w = F.world!(ctx.sa)
      body = F.input(w, %{"tenant_id" => ctx.b.tenant_id})
      conn = D.request(:post, "/counts", ctx.tok_a, body)
      assert D.status!(conn, 422)["field"] == "tenant_id"
    end
  end

  describe "the routes" do
    test "K1-RT: create, update, issue, overlap, cancel by the chair", ctx do
      s = ctx.sa
      chair_tok = S.token(ctx, :a, ["TENANT_ADMIN"], sub: "chair-k1")
      assert D.request(:get, "/counts", chair_tok).status == 200
      cu = Repo.one!(from(u in User, where: u.username == "chair-k1"), prefix: s)
      w = F.world!(s, cu.id)

      id = D.request(:post, "/counts", chair_tok, F.input(w)) |> D.status!(201) |> Map.get("id")

      updated =
        D.request(:put, "/counts/#{id}", chair_tok, F.input(w, %{"note" => "second"}))
        |> D.status!(200)

      assert updated["note"] == "second"

      issued = D.request(:post, "/counts/#{id}/issue", chair_tok, %{}) |> D.status!(200)
      assert issued["status"] == "ordered"
      assert String.starts_with?(issued["number"], "ACO")

      refused = D.request(:post, "/counts/#{id}/issue", chair_tok, %{"x" => 1}) |> D.status!(422)
      assert %{"reason" => "field_not_allowed", "field" => "x"} = refused

      clash = D.request(:post, "/counts", chair_tok, F.input(w)) |> D.status!(201)

      assert D.request(:post, "/counts/#{clash["id"]}/issue", chair_tok, %{})
             |> D.status!(422)
             |> Map.get("reason") == "count_scope_overlaps"

      assert D.request(:put, "/counts/#{id}", chair_tok, F.input(w))
             |> D.status!(422)
             |> Map.get("reason") ==
               "count_state_invalid"

      listed = D.request(:get, "/counts?status=ordered", chair_tok) |> D.status!(200)
      assert [%{"id" => ^id}] = listed["rows"]

      assert D.request(:get, "/counts?bogus=1", chair_tok) |> D.status!(422) |> Map.get("field") ==
               "bogus"

      other = D.request(:post, "/counts/#{id}/cancel", ctx.tok_a, %{}) |> D.status!(422)
      assert other["reason"] == "not_chair"

      cancelled = D.request(:post, "/counts/#{id}/cancel", chair_tok, %{}) |> D.status!(200)
      assert cancelled["status"] == "cancelled"
    end
  end
end
