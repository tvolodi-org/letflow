Code.require_file("../stock/stock_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.CardsRouterTest do
  @moduledoc """
  GH #3892 / REQ-750 criteria 1, 2, 3 and 4 through the full `Letflow.Router` with real OIDC bearer
  tokens on committed tenants (D-098 real HTTP path): H-1 lifecycle, H-2 statuses and idempotency, H-3
  refusal reasons, T-1 API token, T-2 scoped grant, T-3 TASK_WORKER, T-4 unknown ids, T-5 cross-tenant
  (INV-10), T-6 module not installed. `async: false`, Sandbox `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.Entities.Record.Latest
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.Modules.Installs
  alias Letflow.StockFixture, as: S
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TokenMintFixture

  @base "/api/v1/modules/assets"

  setup do
    ctx = S.setup_oidc!([:a, :b, :s, :n])

    a =
      tenant!("ast-ra", ctx.names.a, [
        "org",
        "catalog_items",
        "locations",
        "codes",
        "stock",
        "assets"
      ])

    b =
      tenant!("ast-rb", ctx.names.b, [
        "org",
        "catalog_items",
        "locations",
        "codes",
        "stock",
        "assets"
      ])

    ctx
    |> Map.merge(%{
      a: a,
      b: b,
      tok_a: S.token(ctx, :a, ["TENANT_ADMIN"]),
      tok_b: S.token(ctx, :b, ["TENANT_ADMIN"])
    })
    |> then(&{:ok, Map.put(&1, :unit_a, unit!(&1.tok_a))})
  end

  defp tenant!(prefix, realm, modules) do
    t = S.tenant!(prefix, realm, install: false)
    {:ok, _} = Letflow.Entities.EventTypes.seed!(t.schema_name)
    on_exit(fn -> S.drop_pack_rows!(t.tenant_id) end)

    for m <- modules do
      {:ok, _} =
        Installs.install(m, Ecto.UUID.generate(),
          prefix: t.schema_name,
          rationale: "test: REQ-750"
        )
    end

    t
  end

  defp req(method, path, token, body \\ nil) do
    conn =
      case body do
        nil -> Plug.Test.conn(method, path)
        body -> Plug.Test.conn(method, path, Jason.encode!(body))
      end

    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp key, do: Ecto.UUID.generate()
  defp card(tok, method, path, body), do: req(method, @base <> path, tok, body)

  defp ok!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    Jason.decode!(conn.resp_body)
  end

  defp strip(body), do: M.strip(body)

  defp org!(tok, path, body) do
    ok!(
      req(:post, "/api/v1/modules/org" <> path, tok, Map.put(body, "idempotency_key", key())),
      201
    )
  end

  defp unit!(tok) do
    n = System.unique_integer([:positive])

    le =
      org!(tok, "/legal-entities", %{
        "code" => "L#{n}",
        "name" => "L#{n}",
        "bin" => String.pad_leading("#{n}", 12, "1")
      })["record_id"]

    site =
      org!(tok, "/sites", %{"code" => "S#{n}", "name" => "S#{n}", "legal_entity_id" => le})[
        "record_id"
      ]

    org!(tok, "/units", %{
      "code" => "U#{n}",
      "name" => "U#{n}",
      "legal_entity_id" => le,
      "site_id" => site
    })["record_id"]
  end

  defp body(_unit, number, extra \\ %{}) do
    Map.merge(
      %{
        "inventory_number" => number,
        "name" => "Card #{number}",
        "kind" => "fixed",
        "idempotency_key" => key()
      },
      extra
    )
  end

  defp counts(schema) do
    {Repo.aggregate(from(l in Latest, where: l.entity_type == "assets_card"), :count,
       prefix: schema
     ),
     Repo.aggregate(from(a in Entry, where: like(a.action, "assets_card.%")), :count,
       prefix: schema
     ), 0}
  end

  defp created!(ctx, number \\ "C-#{System.unique_integer([:positive])}"),
    do: ok!(card(ctx.tok_a, :post, "/cards", body(ctx.unit_a, number)), 201)

  test "H-1: create, update, retire and read back through the real routes", ctx do
    c =
      ok!(
        card(
          ctx.tok_a,
          :post,
          "/cards",
          body(ctx.unit_a, "H1", %{"acquisition_cost" => "1500.250000000"})
        ),
        201
      )

    assert c["active"] == true and c["acquisition_cost"] == "1500.250000000"
    id = c["record_id"]

    u =
      ok!(
        card(ctx.tok_a, :patch, "/cards/#{id}", %{
          "idempotency_key" => key(),
          "name" => "Renamed",
          "acquisition_cost" => "1600.000000000"
        }),
        200
      )

    assert u["name"] == "Renamed" and u["acquisition_cost"] == "1600.000000000"
    r = ok!(card(ctx.tok_a, :post, "/cards/#{id}/retire", %{"idempotency_key" => key()}), 200)
    assert r["active"] == false

    q =
      ok!(
        req(:post, "/api/v1/entities/query", ctx.tok_a, %{
          "entity_type" => "assets_card",
          "filters" => [%{"field" => "inventory_number", "op" => "eq", "value" => "H1"}]
        }),
        200
      )

    assert [%{"record_id" => ^id, "field_values" => fv}] = q["items"]
    assert fv["name"] == "Renamed" and fv["active"] == false

    actions =
      Repo.all(
        from(a in Entry,
          where: like(a.action, "assets_card.%"),
          select: a.action,
          order_by: a.timestamp
        ),
        prefix: ctx.a.schema_name
      )

    assert actions == ["assets_card.created", "assets_card.updated", "assets_card.retired"]

    assert req(:post, "/api/v1/entities", ctx.tok_a, %{"entity_type" => "assets_card"}).status ==
             403
  end

  test "H-1b: a created card has no org unit; the unit cannot be set later (T-1488)", ctx do
    c = created!(ctx, "H1B")
    refute Map.has_key?(c, "org_unit_id")
    id = c["record_id"]

    r =
      ok!(
        card(ctx.tok_a, :patch, "/cards/#{id}", %{
          "idempotency_key" => key(),
          "org_unit_id" => ctx.unit_a
        }),
        422
      )

    assert r["reason"] == "field_not_allowed" and r["field"] == "org_unit_id"

    # another tenant's admin cannot read or patch the holderless card (INV-5/INV-10)
    ok!(
      card(ctx.tok_b, :patch, "/cards/#{id}", %{"idempotency_key" => key(), "name" => "x"}),
      404
    )
  end

  test "H-2: idempotency key required, replay and reuse", ctx do
    b = body(ctx.unit_a, "H2")
    first = ok!(card(ctx.tok_a, :post, "/cards", b), 201)
    n = counts(ctx.a.schema_name)
    assert ok!(card(ctx.tok_a, :post, "/cards", b), 201) == first
    assert counts(ctx.a.schema_name) == n

    r = ok!(card(ctx.tok_a, :post, "/cards", Map.put(b, "name", "Other")), 409)
    assert r["reason"] == "idempotency_key_reuse"

    for bad <- [Map.delete(b, "idempotency_key"), Map.put(b, "idempotency_key", "  ")] do
      r = ok!(card(ctx.tok_a, :post, "/cards", bad), 422)
      assert r["reason"] == "field_invalid" and r["field"] == "idempotency_key"
    end

    r = ok!(card(ctx.tok_a, :post, "/cards", [1, 2]), 422)
    assert r["reason"] == "field_invalid"
  end

  test "H-3: each refusal reason answers 422 with a fixed reason", ctx do
    id = created!(ctx)["record_id"]
    other = Ecto.UUID.generate()

    cases = [
      {:post, "/cards", body(ctx.unit_a, "H3A", %{"active" => false}), "field_not_allowed"},
      {:post, "/cards", body(other, "H3B", %{"org_unit_id" => other}), "field_not_allowed"},
      {:patch, "/cards/#{id}", %{"idempotency_key" => key(), "org_unit_id" => other},
       "field_not_allowed"},
      {:post, "/cards", body(ctx.unit_a, "H3C", %{"valid_until" => "2030-01-01"}),
       "valid_until_not_allowed"},
      {:post, "/cards", body(ctx.unit_a, "H3D", %{"currency" => "USD"}), "currency_mismatch"},
      {:post, "/cards", body(ctx.unit_a, "H3E", %{"acquisition_cost" => "1e3"}),
       "record_payload_invalid"},
      {:post, "/cards/#{id}/retire", %{"idempotency_key" => key(), "name" => "x"},
       "field_not_allowed"}
    ]

    for {m, p, b, reason} <- cases do
      r = ok!(card(ctx.tok_a, m, p, b), 422)
      assert r["reason"] == reason, inspect({p, r})
    end

    r =
      ok!(
        card(ctx.tok_a, :post, "/cards", body(ctx.unit_a, "H3E", %{"acquisition_cost" => "1e3"})),
        422
      )

    assert r["fields"] == ["acquisition_cost"]

    ok!(card(ctx.tok_a, :post, "/cards/#{id}/retire", %{"idempotency_key" => key()}), 200)

    for {m, p, b} <- [
          {:patch, "/cards/#{id}", %{"idempotency_key" => key(), "name" => "z"}},
          {:post, "/cards/#{id}/retire", %{"idempotency_key" => key()}}
        ] do
      assert ok!(card(ctx.tok_a, m, p, b), 422)["reason"] == "card_inactive"
    end

    dup = ok!(card(ctx.tok_a, :post, "/cards", body(ctx.unit_a, "H3-DUP")), 201)
    r = ok!(card(ctx.tok_a, :post, "/cards", body(ctx.unit_a, dup["inventory_number"])), 422)
    assert r["reason"] == "record_payload_invalid"
    # T-1865: the duplicate names the field, so the web form can show it
    assert r["fields"] == ["inventory_number"]
  end

  test "H-4: a failing audit table answers 500 and writes nothing", ctx do
    Repo.query!(~s(DROP TABLE "#{ctx.a.schema_name}".audit_entries))
    conn = card(ctx.tok_a, :post, "/cards", body(ctx.unit_a, "H4"))
    assert conn.status == 500
    refute conn.resp_body =~ "H4"

    assert Repo.aggregate(from(l in Latest, where: l.entity_type == "assets_card"), :count,
             prefix: ctx.a.schema_name
           ) == 0
  end

  # The 404 of a tenant without the module, `trace_id` dropped.
  defp reference(ctx) do
    tenant!("ast-rr", ctx.names.n, ["org"])

    card(S.token(ctx, :n, ["TENANT_ADMIN"]), :post, "/cards", %{"idempotency_key" => key()})
    |> ok!(404)
    |> strip()
  end

  defp routes(id, b) do
    [
      {:post, "/cards", b},
      {:patch, "/cards/#{id}", Map.take(b, ["idempotency_key", "name"])},
      {:post, "/cards/#{id}/retire", Map.take(b, ["idempotency_key"])}
    ]
  end

  test "T-1: an API token gets the 404 of a tenant without the module", ctx do
    id = created!(ctx)["record_id"]
    before = counts(ctx.a.schema_name)
    user = TokenMintFixture.role_holder!(ctx.a.schema_name, ["TENANT_ADMIN"])

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: ctx.a.schema_name
      )

    slug = Repo.get!(Letflow.Identity.Tenant, ctx.a.tenant_id).slug
    reference = reference(ctx)

    for {m, p, b} <- routes(id, body(ctx.unit_a, "T1")) do
      conn =
        Plug.Test.conn(m, @base <> p, Jason.encode!(b))
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> plaintext)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-tenant-slug", slug)
        |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))

      assert strip(ok!(conn, 404)) == reference
    end

    assert counts(ctx.a.schema_name) == before
  end

  test "T-2: a TENANT_ADMIN with a scoped grant gets the same 404, nothing written", ctx do
    s =
      tenant!("ast-rs", ctx.names.s, [
        "org",
        "catalog_items",
        "locations",
        "codes",
        "stock",
        "assets"
      ])

    scoped = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "scoped-writer")
    req(:get, @base <> "/none", scoped)

    user = Repo.one!(from(u in User, where: u.username == "scoped-writer"), prefix: s.schema_name)

    _ =
      RSG.raw_delete_rows!(
        s.schema_name,
        RSG.group_of!(s.schema_name, "TENANT_ADMIN"),
        "TENANT_ADMIN"
      )

    :ok = RSG.raw_user_row!(s.schema_name, user.id, "TENANT_ADMIN", RSG.node!(s.schema_name))

    reference = reference(ctx)
    before = counts(s.schema_name)

    for {m, p, b} <- routes(Ecto.UUID.generate(), body(Ecto.UUID.generate(), "T2")) do
      assert strip(ok!(card(scoped, m, p, b), 404)) == reference
    end

    assert counts(s.schema_name) == before
  end

  test "T-3: a TASK_WORKER is forbidden on every route", ctx do
    id = created!(ctx)["record_id"]
    before = counts(ctx.a.schema_name)
    tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-1")

    for {m, p, b} <- routes(id, body(ctx.unit_a, "T3")) do
      r = ok!(card(tok, m, p, b), 403)
      assert r["title"] == "Forbidden"
    end

    assert counts(ctx.a.schema_name) == before
  end

  test "T-4: unknown, malformed and foreign ids give identical 404 bodies", ctx do
    foreign =
      ok!(card(ctx.tok_b, :post, "/cards", body(unit!(ctx.tok_b), "T4B")), 201)["record_id"]

    bodies =
      for id <- [Ecto.UUID.generate(), "not-a-uuid", foreign],
          {m, p} <- [{:patch, "/cards/#{id}"}, {:post, "/cards/#{id}/retire"}] do
        strip(ok!(card(ctx.tok_a, m, p, %{"idempotency_key" => key()}), 404))
      end

    assert bodies |> Enum.uniq() |> length() == 1
  end

  test "T-5: cross-tenant (INV-10): B cannot touch A's card or use A's org unit", ctx do
    c = created!(ctx, "T5")
    id = c["record_id"]
    before = counts(ctx.a.schema_name)
    assert {0, 0, _} = counts(ctx.b.schema_name)

    ok!(
      card(ctx.tok_b, :patch, "/cards/#{id}", %{"idempotency_key" => key(), "name" => "Hijack"}),
      404
    )

    ok!(card(ctx.tok_b, :post, "/cards/#{id}/retire", %{"idempotency_key" => key()}), 404)

    r =
      ok!(
        card(ctx.tok_b, :post, "/cards", body(ctx.unit_a, "T5B", %{"org_unit_id" => ctx.unit_a})),
        422
      )

    assert r["reason"] == "field_not_allowed" and r["field"] == "org_unit_id"

    r =
      ok!(
        card(
          ctx.tok_b,
          :post,
          "/cards",
          body(unit!(ctx.tok_b), "T5C", %{"tenant_id" => ctx.a.tenant_id})
        ),
        422
      )

    assert r["reason"] == "field_not_allowed" and r["field"] == "tenant_id"

    assert counts(ctx.a.schema_name) == before
    assert {0, 0, _} = counts(ctx.b.schema_name)

    # the same number in another tenant is accepted (D-097: unique per tenant)
    same = ok!(card(ctx.tok_b, :post, "/cards", body(unit!(ctx.tok_b), "T5")), 201)
    assert same["inventory_number"] == "T5"
  end

  test "T-6: a tenant without the module answers 404", ctx do
    n = tenant!("ast-rn", ctx.names.n, ["org"])
    tok = S.token(ctx, :n, ["TENANT_ADMIN"])

    for {m, p, b} <- routes(Ecto.UUID.generate(), body(Ecto.UUID.generate(), "T6")) do
      ok!(card(tok, m, p, b), 404)
    end

    assert n.schema_name
  end
end
