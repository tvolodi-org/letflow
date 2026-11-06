Code.require_file("register_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.RegisterRouterTest do
  @moduledoc """
  REQ-749 / GH #3893 criteria 4 and 5 (A8-RB-*, A8-RM-1, A8-RC-1, A8-R-422, A8-R-SC, A8-R-404,
  A8-R-403, A8-R-XT): the three read routes of module assets through the full `Letflow.Router` with
  real OIDC bearer tokens (`Letflow.Support.MockOidcProvider`, verifier `Oidcc`), on committed
  tenants in Sandbox `:auto` mode (`reconcile/2` refuses to run inside a transaction).
  `async: false`: DDL, advisory locks, VM-global config.

  C8 adds no write path (D-098): postings are made through `Letflow.LedgerFixture`, and every read
  goes through the real router, database types and token verifier.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.ScopeNodePaths
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TokenMintFixture

  @a1 "11111111-1111-4111-8111-111111111111"
  @a2 "12121212-1212-4212-8212-121212121212"
  @u1 "44444444-4444-4444-8444-444444444444"
  @u2 "46464646-4646-4646-8646-464646464646"
  @p "47474747-4747-4747-8747-474747474747"
  @l1 "33333333-3333-4333-8333-333333333333"
  @r1 "55555555-5555-4555-8555-555555555555"
  @r2 "56565656-5656-4656-8656-565656565656"

  setup do
    ctx = S.setup_oidc!([:a, :b, :c, :s, :p])
    a = S.tenant!("ast-a", ctx.names.a)
    b = S.tenant!("ast-b", ctx.names.b)
    Map.merge(ctx, %{a: a, b: b, tok_a: S.token(ctx, :a, ["TENANT_ADMIN"])})
  end

  defp strip(body), do: Map.delete(body, "trace_id")
  defp ok!(conn), do: assert_status(conn, 200) |> S.json()

  defp assert_status(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    conn
  end

  defp reason!(conn, status) do
    body = conn |> assert_status(status) |> S.json()
    body["reason"]
  end

  # a1 commissioned (3) at (u1, l1, r1), changed to r2 (1), handed over to u2 (1); a2 commissioned at u2.
  defp seed!(schema) do
    here = S.side(@u1, @r1, %{location: @l1})

    S.post!(schema, "commission", %{
      document_type: "commission_doc",
      document_id: "doc-1",
      lines: [S.line(@a1, "3", %{to: here})]
    })

    S.post!(schema, "change", %{
      document_id: "doc-2",
      lines: [S.line(@a1, "1", %{from: here, to: S.side(@u1, @r2, %{location: @l1})})]
    })

    S.post!(schema, "handover", %{
      document_id: "doc-3",
      lines: [S.line(@a1, "1", %{from: here, to: S.side(@u2, @r1)})]
    })

    S.post!(schema, "commission", %{
      document_id: "doc-4",
      lines: [S.line(@a2, "2", %{to: S.side(@u2, @r1)})]
    })
  end

  defp login!(ctx, sub) do
    tok = S.token(ctx, :s, ["TENANT_ADMIN"], sub: sub)
    ok!(S.get("/balances", tok))
    tok
  end

  defp scope_users!(schema, grants) do
    _ = RSG.raw_delete_rows!(schema, RSG.group_of!(schema, "TENANT_ADMIN"), "TENANT_ADMIN")

    for {sub, node} <- grants do
      user = Letflow.Repo.one!(from(u in User, where: u.username == ^sub), prefix: schema)
      :ok = RSG.raw_user_row!(schema, user.id, "TENANT_ADMIN", node)
    end
  end

  defp ledger_statements(fun) do
    {result, statements} = Fx.record(fun)
    {result, Enum.filter(statements, fn {sql, _} -> sql =~ "ledger_" end)}
  end

  describe "balances" do
    test "A8-RB-1 rows, filters, cutoff, paging and the exact key sets", ctx do
      seed!(ctx.a.schema_name)
      body = ok!(S.get("/balances", ctx.tok_a))

      assert body |> Map.keys() |> Enum.sort() ==
               ~w(as_of basis coverage cutoff_seq filters ledger_id ledger_seq next_cursor rows timezone)

      assert %{"basis" => "posting_seq", "ledger_id" => "assets", "cutoff_seq" => 4} = body
      assert body["ledger_seq"] == 4 and body["filters"] == %{}

      # (a1,u1,l1,r1) 1, (a1,u1,l1,r2) 1, (a1,u2,"",r1) 1, (a2,u2,"",r1) 2
      assert length(body["rows"]) == 4

      for row <- body["rows"] do
        assert row |> Map.keys() |> Enum.sort() ==
                 ~w(actual_user asset last_posting_seq location material_responsible org_unit quantity unit_ref)

        assert row["actual_user"] == nil and row["unit_ref"] == "pcs"
      end

      total = fn rows, asset ->
        rows
        |> Enum.filter(&(&1["asset"] == asset))
        |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, Decimal.new(&1["quantity"])))
      end

      assert Decimal.equal?(total.(body["rows"], @a1), 3)
      assert Decimal.equal?(total.(body["rows"], @a2), 2)
      assert Enum.any?(body["rows"], &(&1["location"] == nil and &1["org_unit"] == @u2))

      only = ok!(S.get("/balances?asset=#{@a2}", ctx.tok_a))
      assert [%{"asset" => @a2}] = only["rows"]
      assert only["filters"] == %{"asset" => @a2}

      by_unit = ok!(S.get("/balances?org_unit=#{@u2}&location=", ctx.tok_a))
      assert length(by_unit["rows"]) == 2

      by_user = ok!(S.get("/balances?actual_user=", ctx.tok_a))
      assert length(by_user["rows"]) == 4

      early = ok!(S.get("/balances?cutoff_seq=1", ctx.tok_a))
      assert [%{"quantity" => q}] = early["rows"]
      assert Decimal.equal?(Decimal.new(q), 3) and early["cutoff_seq"] == 1

      pages =
        Stream.unfold(:first, fn
          :done ->
            nil

          state ->
            query =
              if state == :first,
                do: "?limit=1",
                else: "?limit=1&cursor=" <> URI.encode_www_form(state)

            page = ok!(S.get("/balances" <> query, ctx.tok_a))
            {page["rows"], page["next_cursor"] || :done}
        end)
        |> Enum.to_list()

      keys =
        pages
        |> List.flatten()
        |> Enum.map(&{&1["asset"], &1["org_unit"], &1["location"], &1["material_responsible"]})

      assert length(keys) == 4 and length(Enum.uniq(keys)) == 4
    end

    test "A8-RB-2 the balance as of a date; a future date and a cutoff in the future are 422",
         ctx do
      seed!(ctx.a.schema_name)

      # the tenant zone is Asia/Almaty (UTC+5, no tz database in tests): its "today" is the date compared
      today = DateTime.utc_now() |> DateTime.add(5 * 3600) |> DateTime.to_date()

      body = ok!(S.get("/balances?as_of_date=#{Date.to_iso8601(today)}", ctx.tok_a))
      assert body["as_of_date"] == Date.to_iso8601(today) and length(body["rows"]) == 4

      yesterday = Date.add(today, -1) |> Date.to_iso8601()
      assert ok!(S.get("/balances?as_of_date=#{yesterday}", ctx.tok_a))["rows"] == []

      future = Date.add(today, 3) |> Date.to_iso8601()

      assert reason!(S.get("/balances?as_of_date=#{future}", ctx.tok_a), 422) ==
               "as_of_date_in_future"

      assert reason!(S.get("/balances?cutoff_seq=99999", ctx.tok_a), 422) == "cutoff_in_future"
    end
  end

  describe "movements and reconcile" do
    test "A8-RM-1 order, filter, paging, key sets and no internal columns", ctx do
      seed!(ctx.a.schema_name)
      body = ok!(S.get("/movements", ctx.tok_a))
      assert body |> Map.keys() |> Enum.sort() == ~w(next_cursor rows)
      assert Enum.map(body["rows"], & &1["posting_seq"]) == [1, 2, 3, 4]

      row = hd(body["rows"])

      assert row |> Map.keys() |> Enum.sort() ==
               ~w(cause correlation_id document_id document_type entry_id event_time legs posting_seq posting_time reason_code related_document_id reverses_entry_id)

      assert hd(row["legs"]) |> Map.keys() |> Enum.sort() ==
               ~w(actual_user asset document_line_id leg_no location material_responsible org_unit quantity unit_ref)

      text = Jason.encode!(body)

      for word <-
            ~w(actor_id subject_id client_op_id origin_key payload_hash device scope_ref entry_digest chain_hash) do
        refute text =~ word, "#{word} leaked"
      end

      assert length(Enum.at(body["rows"], 1)["legs"]) == 2

      one = ok!(S.get("/movements?document_id=doc-3", ctx.tok_a))
      assert [%{"posting_seq" => 3, "cause" => "handover"}] = one["rows"]
      assert [%{"cause" => "change"}] = ok!(S.get("/movements?cause=change", ctx.tok_a))["rows"]

      page1 = ok!(S.get("/movements?limit=3", ctx.tok_a))
      assert page1["next_cursor"] == "3"
      page2 = ok!(S.get("/movements?limit=3&cursor=3", ctx.tok_a))
      assert Enum.map(page2["rows"], & &1["posting_seq"]) == [4]

      assert reason!(S.get("/movements?from_seq=3&to_seq=2", ctx.tok_a), 422) == "invalid_filter"
    end

    test "A8-RC-1 a clean ledger, and an empty ledger of an installed module", ctx do
      assert %{"checked_through_seq" => 0, "mismatches" => []} =
               ok!(S.get("/reconcile", ctx.tok_a))

      seed!(ctx.a.schema_name)
      body = ok!(S.get("/reconcile", ctx.tok_a))

      assert body |> Map.keys() |> Enum.sort() ==
               ~w(audit_check chain_check checked_through_seq gap_check ledger_id mismatches next_cursor)

      assert %{
               "ledger_id" => "assets",
               "checked_through_seq" => 4,
               "mismatches" => [],
               "gap_check" => "ok",
               "chain_check" => "ok",
               "audit_check" => "ok",
               "next_cursor" => nil
             } = body

      assert reason!(S.get("/reconcile?cursor=nope", ctx.tok_a), 422) == "invalid_filter"
    end
  end

  describe "refusals" do
    test "A8-R-422 bad queries are refused before any ledger query", ctx do
      seed!(ctx.a.schema_name)
      slug = Letflow.Repo.get!(Letflow.Identity.Tenant, ctx.a.tenant_id).slug

      bad = [
        "/balances?format=xlsx",
        "/balances?format=json",
        "/balances?tenant_id=#{@u1}",
        "/balances?prefix=x",
        "/balances?ledger_id=assets",
        "/balances?x=1",
        "/balances?#{slug}=1",
        "/balances?asset=not-a-uuid",
        "/balances?asset=",
        "/balances?org_unit=",
        "/balances?material_responsible=",
        "/balances?sku=#{@a1}",
        "/balances?cutoff_seq=-1",
        "/balances?as_of=2026-01-01T00:00:00Z",
        "/balances?basis=event_time",
        "/balances?basis=other",
        "/balances?limit=0",
        "/balances?asset[]=a",
        "/balances?asset[a]=b",
        "/balances?cursor=" <> String.duplicate("a", 5000),
        "/balances?scope_subtree=",
        "/movements?format=xlsx",
        "/movements?tenant_id=x",
        "/movements?from_seq=x",
        "/movements?cause=",
        "/movements?cause[]=a",
        "/movements?cursor=abc",
        "/reconcile?format=xlsx",
        "/reconcile?tenant_id=x"
      ]

      for path <- bad do
        {conn, statements} = ledger_statements(fn -> S.get(path, ctx.tok_a) end)
        assert reason!(conn, 422) == "invalid_filter", path
        assert statements == [], path
      end
    end

    test "A8-R-404 an API token is refused like an unknown path, as is a tenant without the module",
         ctx do
      seed!(ctx.a.schema_name)
      reference = c_reference(ctx)
      user = TokenMintFixture.role_holder!(ctx.a.schema_name, ["TENANT_ADMIN"])

      {:ok, %{plaintext: plaintext}} =
        Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: ctx.a.schema_name
        )

      slug = Letflow.Repo.get!(Letflow.Identity.Tenant, ctx.a.tenant_id).slug

      for path <- ["/balances", "/movements", "/reconcile"] do
        conn = S.get(path, plaintext, [{"x-tenant-slug", slug}])
        assert conn.status == 404, path
        assert strip(S.json(conn)) == reference, path
      end
    end

    test "A8-R-403 a TASK_WORKER is forbidden on every route and no ledger query runs", ctx do
      tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-1")

      for path <- ["/balances", "/movements", "/reconcile"] do
        {conn, statements} = ledger_statements(fn -> S.get(path, tok) end)
        body = assert_status(conn, 403) |> S.json()
        assert body["title"] == "Forbidden" and body["detail"] == "insufficient permissions"
        assert String.ends_with?(body["type"], "forbidden")
        assert statements == [], path
      end
    end
  end

  describe "scoped reader" do
    test "A8-R-SC a reader granted on U1 sees U1 only; hidden legs masked; coverage; reconcile 404",
         ctx do
      s = S.tenant!("ast-s", ctx.names.s)
      schema = s.schema_name
      seed!(schema)

      {:ok, _} = ScopeNodePaths.write({:insert, @p, nil}, schema)
      {:ok, _} = ScopeNodePaths.write({:insert, @u1, @p}, schema)
      {:ok, _} = ScopeNodePaths.write({:insert, @u2, @p}, schema)

      tok1 = login!(ctx, "reader-u1")
      tok_p = login!(ctx, "reader-p")
      reference = c_reference(ctx)
      scope_users!(schema, [{"reader-u1", @u1}, {"reader-p", @p}])

      body = ok!(S.get("/balances", tok1))
      assert body["coverage"] == nil
      assert Enum.map(body["rows"], & &1["org_unit"]) |> Enum.uniq() == [@u1]
      assert length(body["rows"]) == 2

      sub = ok!(S.get("/balances?scope_subtree=#{@p}", tok1))
      assert sub["coverage"] == "visible_only"
      assert Enum.map(sub["rows"], & &1["org_unit"]) |> Enum.uniq() == [@u1]

      moves = ok!(S.get("/movements", tok1))["rows"]
      handover = Enum.find(moves, &(&1["document_id"] == "doc-3"))
      [full] = Enum.filter(handover["legs"], &(!Map.has_key?(&1, "masked")))
      [masked] = Enum.filter(handover["legs"], & &1["masked"])
      assert full["org_unit"] == @u1
      assert masked |> Map.keys() |> Enum.sort() == ~w(leg_no masked quantity unit_ref)
      # a movement wholly in the hidden unit is absent
      refute Enum.any?(moves, &(&1["document_id"] == "doc-4"))

      all = ok!(S.get("/balances?scope_subtree=#{@p}", tok_p))
      assert all["coverage"] == "complete"
      assert Enum.map(all["rows"], & &1["org_unit"]) |> Enum.uniq() |> Enum.sort() == [@u1, @u2]

      full_moves = ok!(S.get("/movements?scope_subtree=#{@p}", tok_p))["rows"]
      refute Enum.any?(full_moves, fn m -> Enum.any?(m["legs"], &Map.has_key?(&1, "masked")) end)

      conn = S.get("/reconcile", tok1)
      assert conn.status == 404
      assert strip(S.json(conn)) == reference
    end
  end

  describe "tenancy" do
    test "A8-R-XT B's admin sees none of A's rows, also with A's asset and unit ids", ctx do
      seed!(ctx.a.schema_name)
      seed!(ctx.b.schema_name)
      tok_b = S.token(ctx, :b, ["TENANT_ADMIN"])
      slug_a = Letflow.Repo.get!(Letflow.Identity.Tenant, ctx.a.tenant_id).slug

      # B has its own seed (same ids by design): only B's four postings, no row twice
      assert %{"rows" => rows, "ledger_seq" => 4} = ok!(S.get("/balances", tok_b))
      assert length(rows) == 4

      # a third tenant with a module but no postings sees nothing of A or B
      c = S.tenant!("ast-c", ctx.names.c)
      tok_c = S.token(ctx, :c, ["TENANT_ADMIN"], sub: "c-admin")
      assert c.schema_name != ctx.a.schema_name

      assert %{"rows" => [], "ledger_seq" => 0} = ok!(S.get("/balances", tok_c))
      query = "asset=#{@a1}&org_unit=#{@u1}"
      assert %{"rows" => []} = ok!(S.get("/balances?" <> query, tok_c))
      assert %{"rows" => []} = ok!(S.get("/movements?document_id=doc-1", tok_c))
      assert %{"checked_through_seq" => 0, "mismatches" => []} = ok!(S.get("/reconcile", tok_c))

      for text <- [Jason.encode!(ok!(S.get("/balances", tok_c))), Jason.encode!(rows)] do
        refute text =~ ctx.a.schema_name
      end

      assert reason!(S.get("/balances?tenant_id=#{ctx.a.tenant_id}", tok_c), 422) ==
               "invalid_filter"

      assert reason!(S.get("/movements?prefix=#{ctx.a.schema_name}", tok_c), 422) ==
               "invalid_filter"

      assert reason!(S.get("/balances?#{slug_a}=1", tok_c), 422) == "invalid_filter"

      # a slug header naming A does not redirect C's token
      assert %{"rows" => []} = ok!(S.get("/balances", tok_c, [{"x-tenant-slug", slug_a}]))
    end

    test "A8-R-XT a PLATFORM_ADMIN token reads only its own tenant's ledger", ctx do
      seed!(ctx.a.schema_name)
      S.tenant!("ast-p", ctx.names.p, platform: true)
      tok = S.token(ctx, :p, ["PLATFORM_ADMIN"], sub: "platform-1")

      assert %{"rows" => [], "ledger_seq" => 0} = ok!(S.get("/balances", tok))
      assert %{"rows" => []} = ok!(S.get("/movements", tok))
      assert %{"checked_through_seq" => 0} = ok!(S.get("/reconcile", tok))
    end
  end

  # The dispatcher's answer for a tenant without the module: the body the refusals must equal.
  defp c_reference(ctx) do
    S.tenant!("ast-ref", ctx.names.c, install: false)
    tok = S.token(ctx, :c, ["TENANT_ADMIN"], sub: "ref-admin")
    conn = S.get("/balances", tok)
    assert conn.status == 404
    strip(S.json(conn))
  end
end
