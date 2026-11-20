Code.require_file("../modules/stock/stock_fixture.exs", __DIR__)
Code.require_file("../modules/stock/documents_fixture.exs", __DIR__)
Code.require_file("../modules/codes/codes_fixture.exs", __DIR__)
Code.require_file("../modules/catalog_items/catalog_items_fixture.exs", __DIR__)
Code.require_file("../modules/org/org_fixture.exs", __DIR__)

defmodule Letflow.Routers.SharedStockAccessAddressTest do
  @moduledoc """
  REQ-859 / GH #4572 (decision 0091 sections 6 to 9; Qoimeks parity G13 part 3): the old-app address
  `/qoimeks/:tenant_slug` through the full `Letflow.Router` over committed tenants with real ledger
  postings. IDs follow the acceptance criteria: C1 the three reads in the Qoimeks shape, C2 one 401
  for every unproven request (INV-5, INV-10), C3 wrong values counted per address, C4 accepted
  requests limited per credential, C5 never an API token and no writes, C6 scope enforcement,
  C7 static pins; R1..R3 (REQ-907) the same calls under the `/api` path segment. `async: false`: committed tenants, VM-global config and buckets.
  """

  # impl_order: REQ-859
  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.CodesFixture, as: K
  alias Letflow.Identity.Tenant
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Stock.OldAppReads
  alias Letflow.OrgFixture
  alias Letflow.Plugs.AuthAttemptLimit
  alias Letflow.Plugs.AuthAttemptLimit.Bucket
  alias Letflow.Repo
  alias Letflow.SharedStockAccess
  alias Letflow.SharedStockAccess.IntIds
  alias Letflow.StockDocsFixture, as: SD
  alias Letflow.StockFixture, as: S

  # The problem document `Letflow.Plugs.AuthPipeline` sends for every 401 (decision 0091 section 8.1).
  @unauthorized %{
    "status" => 401,
    "title" => "Unauthorized",
    "detail" => "invalid or expired bearer token"
  }

  setup do
    ctx = S.setup_oidc!([:a, :b, :c, :d, :e, :f, :g])
    a = S.tenant!("q859-a", ctx.names.a)
    b = S.tenant!("q859-b", ctx.names.b)

    originals = %{
      tenants: Application.fetch_env(:letflow, :shared_stock_access_tenants),
      limits: Application.fetch_env(:letflow, AuthAttemptLimit)
    }

    on_exit(fn ->
      restore(:shared_stock_access_tenants, originals.tenants)
      restore(AuthAttemptLimit, originals.limits)
      Bucket.reset()
    end)

    Application.put_env(:letflow, :shared_stock_access_tenants, [a.tenant.slug, b.tenant.slug])

    Application.put_env(:letflow, AuthAttemptLimit,
      failure_capacity: 1000,
      request_capacity: 1000
    )

    Bucket.reset()

    ua = SD.unit!(a.schema_name)
    seeded = seed!(a, ua)
    value_a = access!(a)
    value_b = access!(b)

    {:ok,
     ctx: ctx,
     a: a,
     b: b,
     ua: ua,
     seeded: seeded,
     va: value_a,
     vb: value_b,
     tok_a: S.token(ctx, :a, ["TENANT_ADMIN"])}
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:letflow, key, value)
  defp restore(key, :error), do: Application.delete_env(:letflow, key)

  defp access!(fx) do
    {:ok, _kind, value} =
      SharedStockAccess.put(fx.schema_name, fx.tenant.slug, %{}, %{
        user_id: Ecto.UUID.generate(),
        trace_id: nil
      })

    value
  end

  # Two items, two places, three receipts (10 and 5 of Z-1, 4.5 of Z-2), one barcode on Z-1.
  defp seed!(fx, unit) do
    s = fx.schema_name
    opts = fn -> %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()} end
    uom = Cat.uom!(s, "pcs")

    {:ok, a1} =
      Locations.create_node(
        s,
        %{"code" => "A1", "name" => "Rack A1", "node_kind" => "zone"},
        opts.()
      )

    {:ok, b1} =
      Locations.create_node(
        s,
        %{"code" => "B1", "name" => "Rack B1", "node_kind" => "zone"},
        opts.()
      )

    for node <- [a1, b1],
        do: {:ok, _} = Locations.link_unit_location(s, unit, node["record_id"], opts.())

    z1 = Cat.item!(s, "Z-1", uom.record_id, %{"kind" => "material", "name" => "Lock"})
    z2 = Cat.item!(s, "Z-2", uom.record_id, %{"kind" => "material", "name" => "Button"})
    tag = K.tag!(s, "4600000000017", %{"status" => "assigned"})
    K.assign!(s, tag, "catalog_item", z1.record_id)

    for {item, qty, node} <- [{z1, "10", a1}, {z1, "5", b1}, {z2, "4.5", a1}] do
      S.post!(s, "receipt", %{
        lines: [
          S.line(item.record_id, qty, %{to: S.side(unit, node["record_id"])}, %{
            unit: uom.record_id
          })
        ]
      })
    end

    %{z1: z1, z2: z2, a1: a1, b1: b1, uom: uom}
  end

  defp request(method, slug, path, value, opts \\ []) do
    conn = Plug.Test.conn(method, "/qoimeks/#{slug}#{path}")
    conn = if value, do: put_req_header(conn, "authorization", "Bearer " <> value), else: conn
    conn = if ip = opts[:ip], do: %{conn | remote_ip: ip}, else: conn
    Letflow.Router.call(conn, Letflow.Router.init([]))
  end

  defp get(fx, path, value, opts \\ []), do: request(:get, fx.tenant.slug, path, value, opts)
  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp ok!(conn) do
    assert conn.status == 200, "expected 200, got #{conn.status}: #{conn.resp_body}"
    body(conn)
  end

  defp header(conn, name), do: conn |> get_resp_header(name) |> List.first()

  # -- C1 -----------------------------------------------------------------------------------------

  describe "C1 the three reads in the Qoimeks shape" do
    test "C1 catalog: exactly id, name, article, unit, barcode", %{a: a, va: v} do
      rows = ok!(get(a, "/catalog", v))
      assert length(rows) == 2
      assert Enum.all?(rows, &(Map.keys(&1) |> Enum.sort() == ~w(article barcode id name unit)))
      z1 = Enum.find(rows, &(&1["article"] == "Z-1"))
      assert %{"name" => "Lock", "unit" => "pcs", "barcode" => "4600000000017"} = z1
      assert is_integer(z1["id"]) and z1["id"] > 0
      assert Enum.find(rows, &(&1["article"] == "Z-2"))["barcode"] == nil
    end

    test "C1 balances equal the TENANT_ADMIN read of GET /modules/stock/balances",
         %{a: a, va: v, tok_a: tok} do
      old = ok!(get(a, "/balances", v))

      assert Enum.all?(
               old,
               &(Map.keys(&1) |> Enum.sort() ==
                   ~w(location_id location_name quantity sku_id sku_name))
             )

      admin = S.get("/balances", tok) |> S.json()
      catalog = ok!(get(a, "/catalog", v)) |> Map.new(&{&1["article"], &1["id"]})

      assert length(old) == length(admin["rows"]) and length(old) == 3

      for row <- old do
        assert row["sku_id"] ==
                 Map.fetch!(catalog, if(row["sku_name"] == "Lock", do: "Z-1", else: "Z-2"))
      end

      old_set = for r <- old, do: {r["sku_name"], r["location_name"], r["quantity"]}

      assert Enum.sort(old_set) ==
               Enum.sort([
                 {"Lock", "Rack A1", 10},
                 {"Lock", "Rack B1", 5},
                 {"Button", "Rack A1", 4.5}
               ])

      admin_total =
        admin["rows"] |> Enum.map(&Decimal.new(&1["quantity"])) |> Enum.reduce(&Decimal.add/2)

      old_total =
        old |> Enum.map(&Decimal.from_float(&1["quantity"] / 1)) |> Enum.reduce(&Decimal.add/2)

      assert Decimal.eq?(admin_total, old_total)
    end

    test "C1 balances filter by sku_id and an unknown integer answers an empty list",
         %{a: a, va: v} do
      catalog = ok!(get(a, "/catalog", v))
      z1 = Enum.find(catalog, &(&1["article"] == "Z-1"))
      assert [_, _] = ok!(get(a, "/balances?sku_id=#{z1["id"]}", v))
      assert [] = ok!(get(a, "/balances?sku_id=999999", v))
      assert get(a, "/balances?sku_id=abc", v).status == 400
      assert %{"error" => _} = body(get(a, "/balances?location_id=0", v))
    end

    test "C1 movements: exactly the section 7 fields, newest first, numbers equal the admin read",
         %{a: a, va: v, tok_a: tok} do
      rows = ok!(get(a, "/movements", v))
      assert length(rows) == 3

      assert Enum.all?(
               rows,
               &(Map.keys(&1) |> Enum.sort() ==
                   ~w(created_at id kind location_id operator quantity sku_id))
             )

      assert Enum.map(rows, & &1["quantity"]) == [4.5, 5, 10]
      assert rows |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == 3
      assert Enum.all?(rows, &(&1["kind"] == "receipt" or is_binary(&1["kind"])))
      assert Enum.all?(rows, &is_nil(&1["operator"]))

      admin = S.get("/movements", tok) |> S.json()
      assert length(admin["rows"]) == 3

      admin_qty =
        admin["rows"]
        |> Enum.map(
          &(&1["legs"]
            |> List.first()
            |> Map.fetch!("quantity")
            |> Decimal.new()
            |> Decimal.abs()
            |> Decimal.to_float())
        )
        |> Enum.sort()

      assert admin_qty == rows |> Enum.map(&(&1["quantity"] / 1)) |> Enum.sort()
    end

    test "C1 movements limit: 50 when missing or out of 1..500, otherwise as asked", %{
      a: a,
      va: v
    } do
      assert OldAppReads.movement_limit(nil) == 50
      assert OldAppReads.movement_limit("0") == 50
      assert OldAppReads.movement_limit("501") == 50
      assert OldAppReads.movement_limit("abc") == 50
      assert OldAppReads.movement_limit("2") == 2
      assert OldAppReads.movement_limit("500") == 500
      assert [first, _second] = ok!(get(a, "/movements?limit=2", v))
      all = ok!(get(a, "/movements", v))
      assert first["id"] == hd(all)["id"]
    end

    test "C1 the integers are stable: a second read answers the same ids", %{a: a, va: v} do
      first = ok!(get(a, "/catalog", v))
      assert ok!(get(a, "/catalog", v)) == first
      assert Enum.map(first, & &1["id"]) |> Enum.sort() == [1, 2]
    end

    test "C1 INV-1 the mapping rows live in the tenant's own schema only", %{a: a, b: b, va: v} do
      ok!(get(a, "/catalog", v))

      count = fn fx ->
        Repo.aggregate({"catalog_item_int_ids", IntIds.Row}, :count, prefix: fx.schema_name)
      end

      assert count.(a) == 2
      assert count.(b) == 0
    end
  end

  # -- C2 -----------------------------------------------------------------------------------------

  describe "C2 the same 401 for every unproven request" do
    test "C2 every refusal is byte-identical with no tenant-dependent header",
         %{a: a, b: b, va: va, vb: vb, ctx: ctx} do
      slug_a = a.tenant.slug

      # a listed tenant without a shared access
      c = S.tenant!("q859-c", ctx.names.c)
      # a tenant that has a value but is not listed
      d = S.tenant!("q859-d", ctx.names.d)

      value_d =
        Application.put_env(:letflow, :shared_stock_access_tenants, [d.tenant.slug]) && access!(d)

      # a tenant without the stock module
      e = S.tenant!("q859-e", ctx.names.e, install: false)
      Application.put_env(:letflow, :shared_stock_access_tenants, [e.tenant.slug])
      value_e = access!(e)

      # an inactive tenant
      f = S.tenant!("q859-f", ctx.names.f)
      Application.put_env(:letflow, :shared_stock_access_tenants, [f.tenant.slug])
      value_f = access!(f)
      from(t in Tenant, where: t.id == ^f.tenant_id) |> Repo.update_all(set: [status: :inactive])

      # a revoked value and a rotated-away value
      g = S.tenant!("q859-g", ctx.names.g)
      Application.put_env(:letflow, :shared_stock_access_tenants, [g.tenant.slug])
      value_g = access!(g)
      assert :ok = SharedStockAccess.revoke(g.schema_name, %{user_id: Ecto.UUID.generate()})
      value_g2 = access!(g)

      {:ok, :rotated, value_g3} =
        SharedStockAccess.put(g.schema_name, g.tenant.slug, %{}, %{user_id: Ecto.UUID.generate()})

      Application.put_env(
        :letflow,
        :shared_stock_access_tenants,
        Enum.map([a, b, c, f, e, g], & &1.tenant.slug)
      )

      refused = [
        {"unknown slug", request(:get, "no-such-tenant-q859", "/catalog", va)},
        {"listed, no access", get(c, "/catalog", va)},
        {"not listed", get(d, "/catalog", value_d)},
        {"wrong value", get(a, "/catalog", String.duplicate("z", 64))},
        {"no header", get(a, "/catalog", nil)},
        {"revoked value", get(g, "/catalog", value_g)},
        {"rotated-away value", get(g, "/catalog", value_g2)},
        {"inactive tenant", get(f, "/catalog", value_f)},
        {"no stock module", get(e, "/catalog", value_e)},
        {"A's value at B's address (INV-10)", get(b, "/catalog", va)},
        {"B's value at A's address (INV-10)", request(:get, slug_a, "/catalog", vb)}
      ]

      assert value_g3 != value_g2

      for {label, conn} <- refused do
        assert conn.status == 401, "#{label}: got #{conn.status}"
        assert Map.take(body(conn), Map.keys(@unauthorized)) == @unauthorized, label
      end

      bodies = refused |> Enum.map(fn {_, c} -> c.resp_body end) |> Enum.uniq()
      assert length(bodies) == 1

      headers = refused |> Enum.map(fn {_, c} -> Enum.sort(c.resp_headers) end) |> Enum.uniq()
      assert length(headers) == 1

      # and the live value of the rotated tenant still works
      assert 200 == get(g, "/catalog", value_g3).status
    end
  end

  # -- C3 / C4 ------------------------------------------------------------------------------------

  describe "C3 wrong values are counted" do
    test "C3 after failure_capacity wrong values the next is 429; another address gets 200",
         %{a: a, va: v} do
      Application.put_env(:letflow, AuthAttemptLimit,
        failure_capacity: 3,
        failure_refill_per_sec: 0.0001
      )

      Bucket.reset()
      ip = {10, 9, 9, 1}

      for _ <- 1..3,
          do:
            assert(
              get(a, "/catalog", "wrong-value-wrong-value-wrong-value-xx", ip: ip).status == 401
            )

      limited = get(a, "/catalog", "wrong-value-wrong-value-wrong-value-xx", ip: ip)
      assert limited.status == 429
      assert String.to_integer(header(limited, "retry-after")) >= 1

      assert 200 == get(a, "/catalog", v, ip: {10, 9, 9, 2}).status
      # a valid value is never throttled by the address's failures
      assert 200 == get(a, "/catalog", v, ip: ip).status
    end

    test "C3 a made-up slug is counted like a real one (no timing of 429 tells them apart)", %{
      va: v
    } do
      Application.put_env(:letflow, AuthAttemptLimit,
        failure_capacity: 2,
        failure_refill_per_sec: 0.0001
      )

      Bucket.reset()
      ip = {10, 9, 9, 3}
      for _ <- 1..2, do: assert(request(:get, "nope-q859", "/catalog", v, ip: ip).status == 401)
      assert request(:get, "nope-q859", "/catalog", v, ip: ip).status == 429
    end
  end

  describe "C4 accepted requests are limited per credential" do
    test "C4 the third accepted request is 429 with retry-after; another tenant is not affected",
         %{a: a, b: b, va: va, vb: vb} do
      Application.put_env(:letflow, AuthAttemptLimit,
        request_capacity: 2,
        request_refill_per_sec: 0.0001
      )

      Bucket.reset()

      assert 200 == get(a, "/catalog", va).status
      assert 200 == get(a, "/catalog", va).status
      third = get(a, "/catalog", va)
      assert third.status == 429
      assert String.to_integer(header(third, "retry-after")) >= 1

      assert 200 == get(b, "/catalog", vb).status
    end

    test "C4 the defaults and the runbook" do
      defaults = AuthAttemptLimit.defaults()
      assert defaults[:request_capacity] == 60
      assert defaults[:request_refill_per_sec] == 1

      runbook = File.read!("docs/runbooks/auth-rate-limits.md")
      assert runbook =~ "request_capacity"
      assert runbook =~ "request_refill_per_sec"
      assert runbook =~ "/qoimeks/"
    end
  end

  # -- C5 / C6 ------------------------------------------------------------------------------------

  describe "C5 never an API token, no writes" do
    test "C5 the value on /api/v1 with the tenant slug answers 401", %{a: a, va: v} do
      conn =
        Plug.Test.conn(:get, S.base() <> "/balances")
        |> put_req_header("authorization", "Bearer " <> v)
        |> put_req_header("x-tenant-slug", a.tenant.slug)
        |> Letflow.Router.call(Letflow.Router.init([]))

      assert conn.status == 401
    end

    # REQ-860 serves POST /movements and POST /movements/:id/reverse (shared_stock_access_writes_test.exs).
    test "C5 PUT, DELETE and the other writes at the address answer 404 and change no stock row",
         %{a: a, va: v} do
      count = fn ->
        Repo.aggregate("ledger_entry", :count, prefix: a.schema_name)
      end

      before = count.()

      for {method, path} <- [
            {:put, "/movements"},
            {:put, "/movements/1/reverse"},
            {:get, "/movements/1/reverse"},
            {:delete, "/catalog"},
            {:post, "/catalog"}
          ] do
        assert 404 == request(method, a.tenant.slug, path, v).status
      end

      assert count.() == before
      assert 404 == get(a, "/codes", v).status
    end

    test "C5 without the value the same requests are the one 401", %{a: a} do
      assert 401 == request(:post, a.tenant.slug, "/movements", nil).status
    end
  end

  describe "C6 scope enforcement" do
    test "C6 reads answer 403 while enforcement is shadow or on, and 200 again when it is off",
         %{a: a, va: v} do
      for mode <- [:shadow, :on] do
        from(t in Tenant, where: t.id == ^a.tenant_id)
        |> Repo.update_all(set: [scope_enforcement: mode])

        conn = get(a, "/catalog", v)
        assert conn.status == 403
        assert body(conn) == %{"error" => "scope_enforcement_active"}
      end

      from(t in Tenant, where: t.id == ^a.tenant_id)
      |> Repo.update_all(set: [scope_enforcement: :off])

      assert 200 == get(a, "/catalog", v).status
    end
  end

  # -- REQ-907: the same five calls under the /api path segment ------------------------------------

  @api_pairs [
    {"/catalog", "/api/catalog"},
    {"/balances", "/api/balances"},
    {"/movements", "/api/movements"}
  ]

  defp post(fx, path, value, body) do
    conn = Plug.Test.conn(:post, "/qoimeks/#{fx.tenant.slug}#{path}", Jason.encode!(body))
    conn = if value, do: put_req_header(conn, "authorization", "Bearer " <> value), else: conn
    Letflow.Router.call(conn, Letflow.Router.init([]))
  end

  defp receipt_body(sku, loc, id) do
    %{
      "id" => id,
      "kind" => "receipt",
      "sku_id" => sku,
      "location_id" => loc,
      "qty" => 2,
      "operator" => "Aigul"
    }
  end

  describe "R1 (REQ-907) the /api form gives the same answer" do
    test "R1 the three reads: same status and same body with and without /api", %{a: a, va: v} do
      for {plain, api} <- @api_pairs do
        plain_conn = get(a, plain, v)
        api_conn = get(a, api, v)
        assert plain_conn.status == 200 and api_conn.status == 200, api
        assert plain_conn.resp_body == api_conn.resp_body, api
        assert byte_size(api_conn.resp_body) > 2
      end

      # the query string rides along on the /api form too
      assert get(a, "/movements?limit=1", v).resp_body ==
               get(a, "/api/movements?limit=1", v).resp_body

      assert get(a, "/balances?sku_id=999999", v).resp_body ==
               get(a, "/api/balances?sku_id=999999", v).resp_body

      assert 400 == get(a, "/api/balances?sku_id=x", v).status
    end

    test "R1 the two writes: 201 with the same keys, a repeat of an /api post is 200 with the stored row",
         %{a: a, va: v, seeded: seeded, ua: ua} do
      # the old app names no responsible employee: the write takes the first active one
      OrgFixture.create!(
        a.schema_name,
        "org_employee",
        OrgFixture.values("org_employee", "E907", %{"org_unit_id" => ua})
      )

      sku = IntIds.assign(a.schema_name, :sku, [seeded.z1.record_id]) |> Map.values() |> hd()

      loc =
        IntIds.assign(a.schema_name, :location, [seeded.a1["record_id"]]) |> Map.values() |> hd()

      plain = post(a, "/movements", v, receipt_body(sku, loc, Ecto.UUID.generate()))
      id = Ecto.UUID.generate()
      body = receipt_body(sku, loc, id)
      api = post(a, "/api/movements", v, body)
      assert plain.status == 201 and api.status == 201, api.resp_body
      assert Map.keys(body(plain)) |> Enum.sort() == Map.keys(body(api)) |> Enum.sort()

      repeat = post(a, "/api/movements", v, body)
      assert repeat.status == 200
      assert body(repeat) == body(api)

      # the reverse, on each form, of the movement the other form made
      rev_api =
        post(a, "/api/movements/#{body(plain)["id"]}/reverse", v, %{
          "id" => Ecto.UUID.generate(),
          "operator" => "Aigul"
        })

      rev_id = Ecto.UUID.generate()
      rev_body = %{"id" => rev_id, "operator" => "Aigul"}
      rev_plain = post(a, "/movements/#{body(api)["id"]}/reverse", v, rev_body)

      assert rev_api.status == 201 and rev_plain.status == 201,
             rev_api.resp_body <> rev_plain.resp_body

      assert Map.keys(body(rev_api)) |> Enum.sort() == Map.keys(body(rev_plain)) |> Enum.sort()

      # a repeat of the reversal with its own id on the /api form is the stored row
      repeat_rev = post(a, "/api/movements/#{body(api)["id"]}/reverse", v, rev_body)
      assert repeat_rev.status == 200
      assert body(repeat_rev) == body(rev_plain)
    end
  end

  describe "R2 (REQ-907) one authentication per request" do
    test "R2 no header, a wrong value and an unlisted slug: the 401 of /api is byte-identical",
         %{a: a, va: v} do
      wrong = String.duplicate("z", 64)

      cases = [
        {"no header", fn path -> get(a, path, nil) end},
        {"wrong value", fn path -> get(a, path, wrong) end},
        {"unlisted slug", fn path -> request(:get, "nope-q907", path, v) end}
      ]

      for {label, call} <- cases, {plain, api} <- @api_pairs do
        p = call.(plain)
        q = call.(api)
        assert p.status == 401 and q.status == 401, "#{label} #{api}"
        assert p.resp_body == q.resp_body, "#{label} #{api}"
        assert Enum.sort(p.resp_headers) == Enum.sort(q.resp_headers), "#{label} #{api}"
      end

      for path <- [
            "/movements",
            "/api/movements",
            "/movements/1/reverse",
            "/api/movements/1/reverse"
          ] do
        assert 401 == request(:post, a.tenant.slug, path, nil).status
      end
    end

    test "R2 wrong values count the same on both forms and reach the 429 of AuthAttemptLimit",
         %{a: a} do
      Application.put_env(:letflow, AuthAttemptLimit,
        failure_capacity: 3,
        failure_refill_per_sec: 0.0001
      )

      Bucket.reset()
      wrong = String.duplicate("z", 64)

      # plain-only and /api-only runs each hit the 429 after exactly three failures
      for {path, ip} <- [{"/catalog", {10, 9, 7, 1}}, {"/api/catalog", {10, 9, 7, 2}}] do
        for _ <- 1..3, do: assert(get(a, path, wrong, ip: ip).status == 401)
        limited = get(a, path, wrong, ip: ip)
        assert limited.status == 429
        assert String.to_integer(header(limited, "retry-after")) >= 1
      end

      # mixed across the forms: the same single bucket of the address
      ip = {10, 9, 7, 3}
      assert 401 == get(a, "/catalog", wrong, ip: ip).status
      assert 401 == get(a, "/api/catalog", wrong, ip: ip).status
      assert 401 == get(a, "/api/movements", wrong, ip: ip).status
      mixed = get(a, "/catalog", wrong, ip: ip)
      assert mixed.status == 429
      assert get(a, "/api/catalog", wrong, ip: ip).resp_body == mixed.resp_body
    end

    test "R2 an accepted request spends exactly one request token, mixed across the forms",
         %{a: a, va: v} do
      Application.put_env(:letflow, AuthAttemptLimit,
        request_capacity: 4,
        request_refill_per_sec: 0.0001
      )

      Bucket.reset()

      for path <- ["/catalog", "/api/catalog", "/api/balances", "/movements"],
          do: assert(200 == get(a, path, v).status, path)

      limited = get(a, "/api/catalog", v)
      assert limited.status == 429
      assert String.to_integer(header(limited, "retry-after")) >= 1
      assert 429 == get(a, "/catalog", v).status
    end
  end

  describe "R3 (REQ-907) the calls not served stay 404" do
    test "R3 codes, voice, parse and feedback under /api are 404 and write nothing", %{
      a: a,
      va: v
    } do
      count = fn ->
        {SD.counts(a.schema_name),
         Repo.aggregate("movement_int_ids", :count, prefix: a.schema_name)}
      end

      before = count.()

      for {method, path} <- [
            {:get, "/api/codes/lookup?code=x"},
            {:get, "/api/codes"},
            {:post, "/api/codes"},
            {:post, "/api/voice"},
            {:post, "/api/parse"},
            {:post, "/api/feedback"},
            {:get, "/api"},
            {:get, "/api/api/catalog"},
            {:post, "/api/catalog"},
            {:put, "/api/movements"}
          ] do
        conn = request(method, a.tenant.slug, path, v)
        assert conn.status == 404, "#{method} #{path}: #{conn.status}"
        assert body(conn) == %{"error" => "not found"}
      end

      assert count.() == before
    end
  end

  # -- unit: the integer mapping ------------------------------------------------------------------

  describe "IntIds" do
    test "assign is stable, starts at 1, skips non-uuids; uuid_for inverts it", %{a: a} do
      s = a.schema_name
      [u1, u2] = [Ecto.UUID.generate(), Ecto.UUID.generate()]

      first = IntIds.assign(s, :movement, [u1, u2, "not-a-uuid", nil])
      assert Enum.sort(Map.values(first)) == [1, 2]
      assert IntIds.assign(s, :movement, [u2, u1]) == first
      assert IntIds.lookup(s, :movement, [u1, Ecto.UUID.generate()]) == %{u1 => first[u1]}
      assert IntIds.uuid_for(s, :movement, first[u1]) == u1
      assert IntIds.uuid_for(s, :movement, 999) == nil
      assert IntIds.uuid_for(s, :movement, 0) == nil
      assert IntIds.uuid_for(s, :movement, "1") == nil
    end
  end
end
