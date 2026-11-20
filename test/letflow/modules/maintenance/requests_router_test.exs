Code.require_file("../stock/stock_fixture.exs", __DIR__)
Code.require_file("../assets/assets_fixture.exs", __DIR__)

defmodule Letflow.Modules.Maintenance.RequestsRouterTest do
  @moduledoc """
  REQ-894 / GH #4806 criteria 1 to 7 through the full `Letflow.Router` with real OIDC bearer tokens on
  committed tenants: R-01 create, R-02 refusals, R-03 idempotency, R-04 reads and isolation (INV-5,
  INV-10), R-05 reject, R-06 access (roles, API token, org-scoped grant, flag off), R-07 matrix.
  `async: false`, Sandbox `:auto`; the flag is on in `config/test.exs` and turned off only inside R-06.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsFixture, as: A
  alias Letflow.Documents.Document
  alias Letflow.Entities.Record.Latest
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.Modules.Installs
  alias Letflow.Modules.Maintenance
  alias Letflow.StockFixture, as: S
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TokenMintFixture

  @base "/api/v1/modules/maintenance"
  @modules ["org", "catalog_items", "locations", "codes", "stock", "assets", "maintenance"]

  setup do
    ctx = S.setup_oidc!([:a, :b, :s, :n])
    a = tenant!("mnt-ra", ctx.names.a)
    b = tenant!("mnt-rb", ctx.names.b)

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
          rationale: "test: REQ-894"
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
  defp mnt(tok, method, path, body \\ nil), do: req(method, @base <> path, tok, body)

  defp ok!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    Jason.decode!(conn.resp_body)
  end

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

  defp card!(schema, unit, extra \\ %{}) do
    n = "M-#{System.unique_integer([:positive])}"

    A.card!(
      schema,
      n,
      Map.merge(
        %{
          "org_unit_id" => unit,
          "acquisition_cost" => "987654321.000000000",
          "name" => "Pump #{n}"
        },
        extra
      )
    ).record_id
  end

  defp body(card, extra \\ %{}) do
    Map.merge(
      %{
        "asset_card_id" => card,
        "description" => "Leaking pump",
        "urgency" => "normal",
        "idempotency_key" => key()
      },
      extra
    )
  end

  defp created!(ctx, card, extra \\ %{}),
    do: ok!(mnt(ctx.tok_a, :post, "/requests", body(card, extra)), 201)

  defp counts(schema) do
    {Repo.aggregate(from(l in Latest, where: l.entity_type == "maintenance_work_request"), :count,
       prefix: schema
     ), Repo.aggregate(Document, :count, prefix: schema)}
  end

  defp strip(body), do: M.strip(body)

  test "R-01: create answers 201 with WR number, the two card keys and the caller; numbers advance",
       ctx do
    card = card!(ctx.a.schema_name, ctx.unit_a)
    first = created!(ctx, card)

    assert first["status"] == "new"
    assert first["number"] =~ ~r/\AWR-\d{4}-\d{6}\z/
    assert first["urgency"] == "normal" and first["description"] == "Leaking pump"
    assert first["order"] == nil and first["reject_reason"] == nil
    assert Map.keys(first["asset"]) |> Enum.sort() == ["id", "inventory_number", "name"]
    assert first["asset"]["id"] == card
    refute inspect(first) =~ "987654321"

    assert {:ok, _} = Ecto.UUID.cast(first["reported_by"])
    assert Repo.get!(User, first["reported_by"], prefix: ctx.a.schema_name)

    [_, year, seq] = Regex.run(~r/\AWR-(\d{4})-(\d{6})\z/, first["number"])
    second = created!(ctx, card)

    assert second["number"] ==
             "WR-#{year}-#{seq |> String.to_integer() |> Kernel.+(1) |> Integer.to_string() |> String.pad_leading(6, "0")}"

    stored =
      Repo.one!(from(l in Latest, where: l.record_id == ^first["id"]), prefix: ctx.a.schema_name)

    assert stored.field_values["org_unit_id"] == ctx.unit_a
    assert stored.field_values["document_id"] != "pending"
  end

  test "R-02: card and input refusals answer 422 and write nothing", ctx do
    schema = ctx.a.schema_name
    card = card!(schema, ctx.unit_a)
    retired = card!(schema, ctx.unit_a, %{"active" => false})
    foreign = card!(ctx.b.schema_name, ctx.unit_b)
    before = counts(schema)

    cases = [
      {body(Ecto.UUID.generate()), "asset_card_not_found"},
      {body(foreign), "asset_card_not_found"},
      {body("not-a-uuid"), "asset_card_not_found"},
      {body(retired), "asset_card_inactive"},
      {body(card, %{"description" => "   "}), "description_required"},
      {body(card, %{"description" => String.duplicate("x", 2001)}), "description_too_long"},
      {body(card, %{"urgency" => "high"}), "invalid_urgency"},
      {body(card, %{"extra" => 1}), "field_not_allowed"}
    ]

    for {b, reason} <- cases do
      r = ok!(mnt(ctx.tok_a, :post, "/requests", b), 422)
      assert r["reason"] == reason, inspect({reason, r})
    end

    assert counts(schema) == before

    # the limit is inclusive
    assert created!(ctx, card, %{"description" => String.duplicate("x", 2000)})["status"] == "new"
  end

  test "R-03: same key and body is one request; same key and another body is 409", ctx do
    schema = ctx.a.schema_name
    card = card!(schema, ctx.unit_a)
    b = body(card)
    first = ok!(mnt(ctx.tok_a, :post, "/requests", b), 201)
    {requests, documents} = counts(schema)

    again = ok!(mnt(ctx.tok_a, :post, "/requests", b), 201)
    assert again["id"] == first["id"] and again["number"] == first["number"]
    assert counts(schema) == {requests, documents}

    r = ok!(mnt(ctx.tok_a, :post, "/requests", Map.put(b, "description", "Other")), 409)
    assert r["reason"] == "idempotency_key_reuse"
    assert counts(schema) == {requests, documents}

    assert ok!(mnt(ctx.tok_a, :post, "/requests", Map.delete(b, "idempotency_key")), 422)[
             "reason"
           ] == "field_invalid"
  end

  test "R-04: list newest first with filters and paging; cross-tenant and unknown ids are one 404",
       ctx do
    card = card!(ctx.a.schema_name, ctx.unit_a)
    one = created!(ctx, card)
    two = created!(ctx, card)
    three = created!(ctx, card)
    ok!(mnt(ctx.tok_a, :post, "/requests/#{two["id"]}/reject", %{"reason" => "no"}), 200)

    listed = ok!(mnt(ctx.tok_a, :get, "/requests"), 200)
    assert Enum.map(listed["rows"], & &1["id"]) == [three["id"], two["id"], one["id"]]

    rejected = ok!(mnt(ctx.tok_a, :get, "/requests?status=rejected"), 200)
    assert Enum.map(rejected["rows"], & &1["id"]) == [two["id"]]
    assert ok!(mnt(ctx.tok_a, :get, "/requests?status=new"), 200)["rows"] |> length() == 2

    assert ok!(mnt(ctx.tok_a, :get, "/requests?status=closed"), 422)["reason"] == "invalid_filter"
    assert ok!(mnt(ctx.tok_a, :get, "/requests?limit=0"), 422)["reason"] == "invalid_filter"
    assert ok!(mnt(ctx.tok_a, :get, "/requests?cursor=zz"), 422)["reason"] == "invalid_filter"
    assert ok!(mnt(ctx.tok_a, :get, "/requests?x=1"), 422)["reason"] == "invalid_filter"

    page = ok!(mnt(ctx.tok_a, :get, "/requests?limit=2"), 200)
    assert Enum.map(page["rows"], & &1["id"]) == [three["id"], two["id"]]
    rest = ok!(mnt(ctx.tok_a, :get, "/requests?limit=2&cursor=#{page["next_cursor"]}"), 200)
    assert Enum.map(rest["rows"], & &1["id"]) == [one["id"]]
    assert rest["next_cursor"] == nil

    assert ok!(mnt(ctx.tok_a, :get, "/requests/#{one["id"]}"), 200)["id"] == one["id"]

    # tenant B sees none of A's requests, and A's id answers B the same 404 as an unknown id
    assert ok!(mnt(ctx.tok_b, :get, "/requests"), 200)["rows"] == []

    bodies =
      for id <- [Ecto.UUID.generate(), "not-a-uuid", one["id"]],
          {m, p} <- [{:get, "/requests/#{id}"}, {:post, "/requests/#{id}/reject"}] do
        tok = if id == one["id"], do: ctx.tok_b, else: ctx.tok_a
        strip(ok!(mnt(tok, m, p, if(m == :post, do: %{"reason" => "x"}, else: nil)), 404))
      end

    assert bodies |> Enum.uniq() |> length() == 1
    assert ok!(mnt(ctx.tok_a, :get, "/requests/#{one["id"]}"), 200)["status"] == "new"
  end

  test "R-05: reject sets the status and reason; a second reject is 409; a blank reason is 422",
       ctx do
    card = card!(ctx.a.schema_name, ctx.unit_a)
    r = created!(ctx, card)
    path = "/requests/#{r["id"]}/reject"

    blank = ok!(mnt(ctx.tok_a, :post, path, %{"reason" => "  "}), 422)
    assert blank["reason"] == "reason_required"

    assert ok!(mnt(ctx.tok_a, :post, path, %{"reason" => String.duplicate("r", 501)}), 422)[
             "reason"
           ] == "reason_required"

    assert ok!(mnt(ctx.tok_a, :post, path, %{"reason" => "a", "x" => 1}), 422)["reason"] ==
             "field_not_allowed"

    assert ok!(mnt(ctx.tok_a, :get, "/requests/#{r["id"]}"), 200)["status"] == "new"

    done = ok!(mnt(ctx.tok_a, :post, path, %{"reason" => "Not a job"}), 200)
    assert done["status"] == "rejected" and done["reject_reason"] == "Not a job"
    assert done["number"] == r["number"]

    again = ok!(mnt(ctx.tok_a, :post, path, %{"reason" => "Again"}), 409)
    assert again["reason"] == "request_not_new"
    assert ok!(mnt(ctx.tok_a, :get, "/requests/#{r["id"]}"), 200)["reject_reason"] == "Not a job"
  end

  describe "R-06: access" do
    test "TASK_WORKER, PROCESS_OPERATOR, STOREKEEPER and TENANT_AUDITOR get 403 on all four routes",
         ctx do
      card = card!(ctx.a.schema_name, ctx.unit_a)
      r = created!(ctx, card)
      before = counts(ctx.a.schema_name)

      for role <- ["TASK_WORKER", "PROCESS_OPERATOR", "STOREKEEPER", "TENANT_AUDITOR"] do
        tok = S.token(ctx, :a, [role], sub: "mnt-#{role}")

        for {m, p, b} <- [
              {:post, "/requests", body(card)},
              {:get, "/requests", nil},
              {:get, "/requests/#{r["id"]}", nil},
              {:post, "/requests/#{r["id"]}/reject", %{"reason" => "x"}}
            ] do
          assert ok!(mnt(tok, m, p, b), 403)["title"] == "Forbidden", "#{role} #{p}"
        end
      end

      assert counts(ctx.a.schema_name) == before
      assert ok!(mnt(ctx.tok_a, :get, "/requests/#{r["id"]}"), 200)["status"] == "new"
    end

    test "an API token gets the 404 of an unknown request and an empty list", ctx do
      card = card!(ctx.a.schema_name, ctx.unit_a)
      r = created!(ctx, card)
      before = counts(ctx.a.schema_name)
      user = TokenMintFixture.role_holder!(ctx.a.schema_name, ["TENANT_ADMIN"])

      {:ok, %{plaintext: plaintext}} =
        Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: ctx.a.schema_name
        )

      slug = Repo.get!(Letflow.Identity.Tenant, ctx.a.tenant_id).slug

      call = fn m, p, b ->
        Plug.Test.conn(m, @base <> p, if(b, do: Jason.encode!(b), else: nil))
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> plaintext)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-tenant-slug", slug)
        |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
      end

      for {m, p, b} <- [
            {:post, "/requests", body(card)},
            {:get, "/requests/#{r["id"]}", nil},
            {:post, "/requests/#{r["id"]}/reject", %{"reason" => "x"}}
          ] do
        ok!(call.(m, p, b), 404)
      end

      assert ok!(call.(:get, "/requests", nil), 200)["rows"] == []
      assert counts(ctx.a.schema_name) == before
    end

    test "a TENANT_ADMIN with an org-scoped grant gets 404 on writes and reads by id, [] on the list",
         ctx do
      s = tenant!("mnt-rs", ctx.names.s)
      scoped = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "scoped-mnt")
      req(:get, @base <> "/requests", scoped)

      user =
        Repo.one!(from(u in User, where: u.username == "scoped-mnt"), prefix: s.schema_name)

      _ =
        RSG.raw_delete_rows!(
          s.schema_name,
          RSG.group_of!(s.schema_name, "TENANT_ADMIN"),
          "TENANT_ADMIN"
        )

      :ok = RSG.raw_user_row!(s.schema_name, user.id, "TENANT_ADMIN", RSG.node!(s.schema_name))
      before = counts(s.schema_name)

      ok!(mnt(scoped, :post, "/requests", body(Ecto.UUID.generate())), 404)
      ok!(mnt(scoped, :get, "/requests/#{Ecto.UUID.generate()}"), 404)
      ok!(mnt(scoped, :post, "/requests/#{Ecto.UUID.generate()}/reject", %{"reason" => "x"}), 404)
      assert ok!(mnt(scoped, :get, "/requests"), 200)["rows"] == []
      assert counts(s.schema_name) == before
    end

    test "flag off: every route answers 404 for an installed tenant and writes nothing", ctx do
      card = card!(ctx.a.schema_name, ctx.unit_a)
      r = created!(ctx, card)
      before = counts(ctx.a.schema_name)

      old = Application.get_env(:letflow, :maintenance_enabled)
      Application.put_env(:letflow, :maintenance_enabled, false)
      on_exit(fn -> Application.put_env(:letflow, :maintenance_enabled, old) end)

      bodies =
        for {m, p, b} <- [
              {:post, "/requests", body(card)},
              {:get, "/requests", nil},
              {:get, "/requests/#{r["id"]}", nil},
              {:post, "/requests/#{r["id"]}/reject", %{"reason" => "x"}}
            ] do
          strip(ok!(mnt(ctx.tok_a, m, p, b), 404))
        end

      assert bodies |> Enum.uniq() |> length() == 1

      assert counts(ctx.a.schema_name) == before
      refute Maintenance.enabled?()
    end
  end

  test "R-07: three atoms, no role grant, only the two administrator catch-alls hold them" do
    atoms = [:MaintenanceRequestCreate, :MaintenanceRead, :MaintenanceOrderManage]
    manifest = Maintenance.manifest()
    assert manifest.permissions == atoms
    assert manifest.role_grants == %{}

    assert Enum.map(manifest.route_policies, &elem(&1, 2)) |> Enum.sort() ==
             Enum.sort(atoms ++ [:MaintenanceRead])

    golden = File.read!("priv/permission_matrix/effective.golden") |> String.split("\n")

    for atom <- atoms do
      rows = Enum.filter(golden, &String.contains?(&1, " #{atom} "))
      assert length(rows) == length(Letflow.Api.Authorization.roles())

      holders =
        for row <- rows, [role, _atom, "true" | _] <- [String.split(row)], do: role

      assert Enum.sort(holders) == ["PLATFORM_ADMIN", "TENANT_ADMIN"], "#{atom}"
    end
  end
end
