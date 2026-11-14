Code.require_file("assets/documents_fixture.exs", __DIR__)
Code.require_file("assets/counts_fixture.exs", __DIR__)
Code.require_file("stock/documents_fixture.exs", __DIR__)
Code.require_file("stock/counts_fixture.exs", __DIR__)
Code.require_file("stock/posting_fixture.exs", __DIR__)

defmodule Letflow.Modules.AssetStockIsolationTest do
  @moduledoc """
  T-1534 (tenant-isolation hardening review of the asset and stock routes). One table, `@id_routes`, lists
  every route of `Letflow.Modules.Assets.Router` and `Letflow.Modules.Stock.Router` that takes a record id.
  I1 compares the table with `__authz_routes__/0` of both routers, so a route added later without a row
  fails. I2 calls every row through the full `Letflow.Router` with tenant B's TENANT_ADMIN token and tenant
  A's real id and requires the uniform 404 of an unknown id (INV-5), A's row unchanged, and a control call
  with A's token that is not a 404 (so the id was real). I3 shows no register or print route honours a
  tenant key from the caller (INV-10). I4 shows B's lists hold none of A's rows. Committed tenants, Sandbox
  `:auto`, `async: false`. The scoped-reader and hidden-leg cases are in `asset_stock_scope_exports_test.exs`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsCountsFixture, as: ACF
  alias Letflow.AssetsDocsFixture, as: AD
  alias Letflow.AssetsRegisterFixture, as: RS
  alias Letflow.Identity.User
  alias Letflow.CountsFixture, as: CF
  alias Letflow.StockDocsFixture, as: SD
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.StockFixture, as: S
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG

  @assets "/api/v1/modules/assets"
  @stock "/api/v1/modules/stock"

  # {family, method, path, body key, control}. `control: :none` marks a route whose A-side answer is a
  # legitimate 404 for the generic fixture (issued order: no counting, no posting yet), so the generic I2 loop
  # applies only the B == unknown rule; I2b gives each of them a real A-side success first.
  @id_routes [
    {:card, "PATCH", "/cards/:id", :card_patch, :call},
    {:card, "POST", "/cards/:id/retire", :idem, :call},
    {:card, "GET", "/cards/:id/lock", nil, :call},
    {:adoc, "PUT", "/documents/:id", :adoc_put, :call},
    {:adoc, "DELETE", "/documents/:id", nil, :call},
    {:adoc, "GET", "/documents/:id", nil, :call},
    {:adoc, "GET", "/documents/:id/print", nil, :call},
    {:adoc, "POST", "/documents/:id/issue", nil, :call},
    {:adoc, "POST", "/documents/:id/check", nil, :call},
    {:adoc, "POST", "/documents/:id/reverse", :reverse, :call},
    {:sdoc, "PUT", "/documents/:id", :sdoc_put, :call},
    {:sdoc, "DELETE", "/documents/:id", nil, :call},
    {:sdoc, "GET", "/documents/:id", nil, :call},
    {:sdoc, "GET", "/documents/:id/print", nil, :call},
    {:sdoc, "POST", "/documents/:id/issue", nil, :call},
    {:sdoc, "POST", "/documents/:id/check", nil, :call},
    {:sdoc, "POST", "/documents/:id/post", nil, :call},
    {:sdoc, "POST", "/documents/:id/reverse", :reverse, :call},
    {:sdoc, "POST", "/documents/:id/cancel", :cancel, :call},
    # REQ-816 (asset count K1): flag `count_enabled` is on in both tenants, so B's 404 is the cross-tenant one.
    {:acount, "PUT", "/counts/:id", :acount_put, :call},
    {:acount, "GET", "/counts/:id", nil, :call},
    {:acount, "POST", "/counts/:id/issue", :empty, :call},
    {:acount, "POST", "/counts/:id/cancel", :empty, :call},
    {:count, "PUT", "/counts/:id", :count_put, :call},
    {:count, "GET", "/counts/:id", nil, :call},
    {:count, "POST", "/counts/:id/issue", :empty, :call},
    {:count, "POST", "/counts/:id/cancel", :empty, :call},
    {:count, "GET", "/counts/:id/document", nil, :call},
    {:count, "POST", "/counts/:id/open", :empty, :call},
    {:count, "GET", "/counts/:id/lines", nil, :call},
    {:count, "PUT", "/counts/:id/lines/:line_no/count", :counted, :none},
    {:count, "POST", "/counts/:id/scan", :scan, :call},
    {:count, "POST", "/counts/:id/surplus-lines", :surplus, :call},
    {:count, "GET", "/counts/:id/entries", nil, :call},
    {:count, "POST", "/counts/:id/close", :empty, :call},
    {:count, "GET", "/counts/:id/sheet-document", nil, :none},
    {:count, "POST", "/counts/:id/sheet-signatures", :signers, :call},
    {:count, "POST", "/counts/:id/differences", :empty, :call},
    {:count, "POST", "/counts/:id/differences-signatures", :signers, :call},
    {:count, "GET", "/counts/:id/differences", nil, :none},
    {:count, "POST", "/counts/:id/post", :empty, :call},
    {:count, "POST", "/counts/:id/reverse", :reverse, :call},
    {:count, "POST", "/counts/:id/posting-record", :empty, :call},
    {:count, "GET", "/counts/:id/posting-document", nil, :none},
    {:count, "GET", "/counts/:id/signatures", nil, :none},
    {:count, "GET", "/counts/:id/paperwork/:kind", nil, :call},
    {:count, "GET", "/counts/:id/print/:kind", nil, :call}
  ]

  setup do
    ctx = RS.setup_oidc!([:aa, :ab, :sa, :sb, :s])
    aa = RS.tenant!("ast-isa", ctx.names.aa)
    ab = RS.tenant!("ast-isb", ctx.names.ab)
    ACF.enable!(aa.schema_name)
    ACF.enable!(ab.schema_name)
    sa = S.tenant!("stk-isa", ctx.names.sa)
    sb = S.tenant!("stk-isb", ctx.names.sb)

    {:ok,
     Map.merge(ctx, %{
       aa: aa,
       ab: ab,
       sa: sa,
       sb: sb,
       maa: AD.masters!(aa.schema_name),
       mab: AD.masters!(ab.schema_name),
       msa: SD.masters!(sa.schema_name),
       msb: SD.masters!(sb.schema_name),
       wa: CF.world!(sa.schema_name),
       wb: CF.world!(sb.schema_name),
       wcb: ACF.world!(ab.schema_name),
       tok_aa: S.token(ctx, :aa, ["TENANT_ADMIN"]),
       tok_ab: S.token(ctx, :ab, ["TENANT_ADMIN"]),
       tok_sa: S.token(ctx, :sa, ["TENANT_ADMIN"]),
       tok_sb: S.token(ctx, :sb, ["TENANT_ADMIN"])
     })}
  end

  defp call(base, method, path, token, body \\ nil) do
    method = method |> String.downcase() |> String.to_atom()

    conn =
      case body do
        nil -> Plug.Test.conn(method, base <> path)
        b -> Plug.Test.conn(method, base <> path, Jason.encode!(b))
      end

    conn
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

  defp templates(family) do
    for {^family, m, p, b, c} <- @id_routes, do: {m, p, b, c}
  end

  defp fill(path, id, kind \\ "order"),
    do:
      path
      |> String.replace(":id", id)
      |> String.replace(":line_no", "1")
      |> String.replace(":kind", kind)

  defp body(key, ctx) do
    case key do
      nil ->
        nil

      :empty ->
        %{}

      :signers ->
        %{"signer_employee_ids" => [ctx.wb.chair]}

      :idem ->
        %{"idempotency_key" => Ecto.UUID.generate()}

      :card_patch ->
        %{"idempotency_key" => Ecto.UUID.generate(), "name" => "Hijack"}

      :adoc_put ->
        AD.body(ctx.mab)

      :sdoc_put ->
        SD.body(ctx.msb)

      :reverse ->
        %{"reason_code" => "wrong_document"}

      :cancel ->
        %{"reason" => "x"}

      :count_put ->
        CF.input(ctx.wb)

      :acount_put ->
        ACF.input(ctx.wcb)

      :counted ->
        %{"counted_quantity" => "1"}

      :scan ->
        %{"scanned_text" => "x", "location_id" => ctx.wb.a, "scan_id" => Ecto.UUID.generate()}

      :surplus ->
        %{
          "location_id" => ctx.wb.a,
          "catalog_item_id" => Ecto.UUID.generate(),
          "unit_ref" => Ecto.UUID.generate(),
          "counted_quantity" => "1"
        }
    end
  end

  # Fresh entity in tenant A for one route; returns {id, base, tok_a, tok_b, the path that reads it back}.
  defp fresh(:card, ctx) do
    id = AD.card!(ctx.aa.schema_name, "fixed", ctx.maa.unit)
    {id, @assets, ctx.tok_aa, ctx.tok_ab, "/cards/#{id}/lock"}
  end

  defp fresh(:adoc, ctx) do
    doc = AD.request(:post, "/documents", ctx.tok_aa, AD.body(ctx.maa)) |> AD.status!(201)
    {doc["id"], @assets, ctx.tok_aa, ctx.tok_ab, "/documents/#{doc["id"]}"}
  end

  defp fresh(:sdoc, ctx) do
    doc = SD.request(:post, "/documents", ctx.tok_sa, SD.body(ctx.msa))
    assert doc.status == 201, doc.resp_body
    id = S.json(doc)["id"]
    {id, @stock, ctx.tok_sa, ctx.tok_sb, "/documents/#{id}"}
  end

  defp fresh(:acount, ctx) do
    # An open order blocks overlapping scope, so every order gets its own unit and locations.
    w = ACF.world!(ctx.aa.schema_name)
    created = call(@assets, "POST", "/counts", ctx.tok_aa, ACF.input(w))
    assert created.status == 201, created.resp_body
    id = RS.json(created)["id"]
    issued = call(@assets, "POST", "/counts/#{id}/issue", ctx.tok_aa, %{})
    assert issued.status == 200, issued.resp_body
    {id, @assets, ctx.tok_aa, ctx.tok_ab, "/counts/#{id}"}
  end

  defp fresh(:count, ctx) do
    # An active order blocks overlapping scope, so every order gets its own unit and locations.
    created = call(@stock, "POST", "/counts", ctx.tok_sa, CF.input(CF.world!(ctx.sa.schema_name)))
    assert created.status == 201, created.resp_body
    id = S.json(created)["id"]
    issued = call(@stock, "POST", "/counts/#{id}/issue", ctx.tok_sa, %{})
    assert issued.status == 200, issued.resp_body
    {id, @stock, ctx.tok_sa, ctx.tok_sb, "/counts/#{id}"}
  end

  describe "I1 inventory" do
    test "the table lists exactly the id routes of both routers" do
      declared = fn router, family_of ->
        for {m, p, _} <- router.__authz_routes__(),
            String.contains?(p, ":id"),
            do: {family_of, m, p}
      end

      from_routers =
        (declared.(Letflow.Modules.Assets.Router, :assets) ++
           declared.(Letflow.Modules.Stock.Router, :stock))
        |> Enum.sort()

      from_table =
        for {family, m, p, _, _} <- @id_routes do
          {if(family in [:card, :adoc, :acount], do: :assets, else: :stock), m, p}
        end
        |> Enum.sort()

      assert from_table -- from_routers == [], "table rows without a route"
      assert from_routers -- from_table == [], "id routes without a row in @id_routes"
      assert length(from_routers) == length(@id_routes)
    end
  end

  describe "I2 cross-tenant, every id route" do
    @describetag timeout: 600_000

    for family <- [:card, :adoc, :acount, :sdoc, :count] do
      test "#{family}: tenant B gets the uniform 404 and A's row is unchanged", ctx do
        family = unquote(family)

        for {m, p, bkey, control} <- templates(family) do
          {id, base, tok_a, tok_b, get_path} = fresh(family, ctx)
          label = "#{m} #{p}"
          reqbody = body(bkey, ctx)
          before = strip(call(base, "GET", get_path, tok_a))

          # An unknown id and a malformed id are the baseline answers of tenant B.
          unknown = call(base, m, fill(p, Ecto.UUID.generate()), tok_b, reqbody)

          assert unknown.status == 404,
                 "baseline #{label}: #{unknown.status} #{unknown.resp_body}"

          foreign = call(base, m, fill(p, id), tok_b, reqbody)
          assert foreign.status == 404, "#{label}: #{foreign.status} #{foreign.resp_body}"
          assert strip(foreign) == strip(unknown), label

          assert strip(call(base, "GET", get_path, tok_a)) == before, label

          if control == :call do
            real = call(base, m, fill(p, id), tok_a, reqbody)

            refute real.status == 404,
                   "control #{label}: A's own id answered 404 #{real.resp_body}"
          end
        end
      end
    end
  end

  describe "I2b the five state-dependent count routes, with a real A-side answer" do
    @describetag timeout: 600_000

    # A count of tenant A driven to `counting` and another to `posted`, so that every `:none` route has a
    # real answer for A. Then B must get the uniform 404 and A's state must not move.
    test "line count, sheet-document, differences, posting-document, signatures", ctx do
      s = ctx.sa.schema_name
      w = CF.world!(s)
      chair_tok = S.token(ctx, :sa, ["TENANT_ADMIN"], sub: "chair-isl")
      member_tok = S.token(ctx, :sa, ["TENANT_ADMIN"], sub: "member-isl")
      assert call(@stock, "GET", "/counts", chair_tok).status == 200
      assert call(@stock, "GET", "/counts", member_tok).status == 200
      cu = Repo.one!(from(u in User, where: u.username == "chair-isl"), prefix: s)
      mu = Repo.one!(from(u in User, where: u.username == "member-isl"), prefix: s)

      w = %{
        w
        | chair: CF.employee!(s, w.unit, user: cu.id),
          members: [CF.employee!(s, w.unit, user: mu.id)]
      }

      holder = Letflow.Support.TokenMintFixture.role_holder!(s, ["TENANT_ADMIN"])
      x = %{s: s, schema: s, holder: holder}

      ok = fn conn, status ->
        assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
        S.json(conn)
      end

      now = DateTime.utc_now()

      window = %{
        "planned_start" => DateTime.to_iso8601(DateTime.add(now, -3600)),
        "planned_end" => DateTime.to_iso8601(DateTime.add(now, 20 * 3600))
      }

      # book and open an order; returns its id in state `counting`
      counting = fn w ->
        S.post!(s, "receipt", %{lines: [S.line(S.uuid(), "10", %{to: S.side(w.unit, w.a)})]})
        id = ok.(call(@stock, "POST", "/counts", chair_tok, CF.input(w, window)), 201)["id"]
        ok.(call(@stock, "POST", "/counts/#{id}/issue", chair_tok, %{}), 200)
        ok.(call(@stock, "POST", "/counts/#{id}/open", chair_tok, %{}), 200)
        id
      end

      # B == unknown id, and A's own read-back is unchanged by B's call
      probe = fn m, path, id, bkey, readback ->
        reqbody = body(bkey, ctx)
        unknown = call(@stock, m, fill(path, Ecto.UUID.generate()), ctx.tok_sb, reqbody)
        assert unknown.status == 404, "baseline #{m} #{path}: #{unknown.status}"
        before = strip(call(@stock, "GET", readback, chair_tok))
        foreign = call(@stock, m, fill(path, id), ctx.tok_sb, reqbody)
        assert foreign.status == 404, "#{m} #{path}: #{foreign.status} #{foreign.resp_body}"
        assert strip(foreign) == strip(unknown), "#{m} #{path}"
        assert strip(call(@stock, "GET", readback, chair_tok)) == before, "#{m} #{path}"
      end

      id2 = counting.(w)

      # 1. PUT /counts/:id/lines/:line_no/count, while the order is counting
      lines = "/counts/#{id2}/lines"
      [line | _] = ok.(call(@stock, "GET", lines, chair_tok), 200)["rows"]
      assert line["counted_quantity"] == nil
      path = "/counts/:id/lines/#{line["line_no"]}/count"
      probe.("PUT", path, id2, :counted, lines)
      mine = call(@stock, "PUT", fill(path, id2), chair_tok, %{"counted_quantity" => "7"})
      assert ok.(mine, 200)["counted_quantity"] == "7.000000000"

      # 2. the same order taken to `posted`: sheet-document, differences, signatures, posting-document
      for l <- ok.(call(@stock, "GET", "/counts/#{id2}/lines", chair_tok), 200)["rows"] do
        put =
          call(@stock, "PUT", "/counts/#{id2}/lines/#{l["line_no"]}/count", member_tok, %{
            "counted_quantity" => "3"
          })

        ok.(put, 200)
      end

      ok.(call(@stock, "POST", "/counts/#{id2}/close", chair_tok, %{}), 200)
      signers = %{"signer_employee_ids" => [w.chair | w.members]}
      ok.(call(@stock, "POST", "/counts/#{id2}/sheet-signatures", chair_tok, signers), 200)
      ok.(call(@stock, "POST", "/counts/#{id2}/differences", chair_tok, %{}), 200)
      ok.(call(@stock, "POST", "/counts/#{id2}/differences-signatures", chair_tok, signers), 200)

      diff_id =
        ok.(call(@stock, "GET", "/counts/#{id2}", chair_tok), 200)["differences_document_id"]

      ok.(call(@stock, "POST", "/counts/#{id2}/post", chair_tok, %{}), 200)
      task = P.pending_task(x, diff_id, "post") || flunk("no pending post task")
      assert {:ok, _} = P.complete(x, task)
      ok.(call(@stock, "POST", "/counts/#{id2}/posting-record", chair_tok, %{}), 200)

      read = "/counts/#{id2}"

      for path <- ["sheet-document", "differences", "signatures", "posting-document"] do
        route = "/counts/:id/" <> path
        # the A-side control: the real answer is a 200 for the owner's own order
        ok.(call(@stock, "GET", fill(route, id2), chair_tok), 200)
        probe.("GET", route, id2, nil, read)
      end
    end
  end

  describe "I3 no tenant key from the caller" do
    test "register and print routes refuse a tenant_id and never switch tenant", ctx do
      for {base, tok, path} <- [
            {@assets, ctx.tok_ab, "/balances"},
            {@assets, ctx.tok_ab, "/movements"},
            {@assets, ctx.tok_ab, "/reconcile"},
            {@stock, ctx.tok_sb, "/balances"},
            {@stock, ctx.tok_sb, "/movements"},
            {@stock, ctx.tok_sb, "/reconcile"},
            {@stock, ctx.tok_sb, "/stock-card/print"}
          ],
          key <- ["tenant_id", "tenant", "prefix", "schema"] do
        value = if key == "tenant_id", do: ctx.aa.tenant_id, else: ctx.aa.schema_name
        conn = call(base, "GET", "#{path}?#{key}=#{value}", tok)
        assert conn.status == 422, "#{base}#{path} #{key}: #{conn.status} #{conn.resp_body}"
        refute conn.resp_body =~ ctx.aa.schema_name
      end
    end
  end

  describe "I4 lists" do
    test "tenant B's lists hold none of A's rows", ctx do
      {adoc, _, _, _, _} = fresh(:adoc, ctx)
      {sdoc, _, _, _, _} = fresh(:sdoc, ctx)
      {count, _, _, _, _} = fresh(:count, ctx)

      for {base, tok, path, id} <- [
            {@assets, ctx.tok_ab, "/documents", adoc},
            {@stock, ctx.tok_sb, "/documents", sdoc},
            {@stock, ctx.tok_sb, "/counts", count}
          ] do
        conn = call(base, "GET", path, tok)
        assert conn.status == 200, conn.resp_body
        assert S.json(conn)["rows"] == [], "#{base}#{path}"
        refute conn.resp_body =~ id
      end

      for {base, tok, path, id} <- [
            {@assets, ctx.tok_aa, "/documents", adoc},
            {@stock, ctx.tok_sa, "/documents", sdoc},
            {@stock, ctx.tok_sa, "/counts", count}
          ] do
        assert call(base, "GET", path, tok).resp_body =~ id, "control #{base}#{path}"
      end
    end
  end

  describe "S6b scoped counts" do
    @describetag timeout: 600_000

    test "a reader scoped to one unit gets its own count and 404 on every id route of another unit's",
         ctx do
      s = S.tenant!("stk-iss", ctx.names.s).schema_name
      wx = CF.world!(s)
      wy = CF.world!(s)
      admin = S.token(ctx, :s, ["TENANT_ADMIN"])

      ids =
        for w <- [wx, wy] do
          created = call(@stock, "POST", "/counts", admin, CF.input(w))
          assert created.status == 201, created.resp_body
          id = S.json(created)["id"]
          assert call(@stock, "POST", "/counts/#{id}/issue", admin, %{}).status == 200
          id
        end

      [own, other] = ids
      tok = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "scoped-counter")
      assert call(@stock, "GET", "/counts", tok).status == 200
      user = Repo.one!(from(u in User, where: u.username == "scoped-counter"), prefix: s)
      _ = RSG.raw_delete_rows!(s, RSG.group_of!(s, "TENANT_ADMIN"), "TENANT_ADMIN")
      :ok = RSG.raw_user_row!(s, user.id, "TENANT_ADMIN", wx.unit)

      assert call(@stock, "GET", "/counts/#{own}", tok).status == 200
      listed = S.json(call(@stock, "GET", "/counts", tok))["rows"]
      assert Enum.map(listed, & &1["id"]) == [own]
      assert call(@stock, "GET", "/counts/#{own}/lines", tok).status == 200

      # `cancel` last: it ends the own order's life for the routes after it.
      routes =
        Enum.sort_by(templates(:count), fn {m, p, _, _} -> m == "POST" and p =~ "/cancel" end)

      for {m, p, bkey, control} <- routes do
        reqbody = body(bkey, %{ctx | wb: wx})
        unknown = call(@stock, m, fill(p, Ecto.UUID.generate()), tok, reqbody)
        assert unknown.status == 404, "baseline #{m} #{p}: #{unknown.status} #{unknown.resp_body}"

        hidden = call(@stock, m, fill(p, other), tok, reqbody)
        assert hidden.status == 404, "#{m} #{p}: #{hidden.status} #{hidden.resp_body}"
        assert strip(hidden) == strip(unknown), "#{m} #{p}"

        # `open` needs a full ledger reader: a scoped caller is refused with 404 even on its own count
        # (pinned by count_sheet_router_test RT4/RT5), so it has no control call here.
        if control == :call and not (p =~ "/open") do
          real = call(@stock, m, fill(p, own), tok, reqbody)
          refute real.status == 404, "control #{m} #{p}: own-unit count answered 404"
        end
      end
    end
  end
end
