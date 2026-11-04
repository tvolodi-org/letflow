Code.require_file("stock_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.RouterTest do
  @moduledoc """
  REQ-687 / GH #3707 criteria 5 to 8 (T-RB-1, T-RM-1, T-RC-1..3, T-R-404, T-R-SC, T-R-403, T-R-422, T-R-XT):
  the three read routes of module `stock` through the full `Letflow.Router` with real OIDC bearer tokens
  (`Letflow.Support.MockOidcProvider`, verifier `Oidcc`), on committed tenants in Sandbox `:auto` mode
  (`reconcile/2` refuses to run inside a transaction). `async: false`: DDL, advisory locks, VM-global config.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.StockFixture, as: S
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TokenMintFixture

  @sku1 "11111111-1111-4111-8111-111111111111"
  @sku2 "12121212-1212-4212-8212-121212121212"
  @u1 "44444444-4444-4444-8444-444444444444"
  @l1 "33333333-3333-4333-8333-333333333333"
  @l2 "35353535-3535-4535-8535-353535353535"

  setup do
    ctx = S.setup_oidc!([:a, :b, :c, :s, :p])
    a = S.tenant!("stk-a", ctx.names.a)
    b = S.tenant!("stk-b", ctx.names.b)
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

  # sku1 10 and sku2 4 received at (u1, l1); sku1 10 moved to l2 -> three keys, one at zero.
  defp seed!(schema) do
    here = S.side(@u1, @l1)

    S.post!(schema, "receipt", %{
      document_type: "receipt_doc",
      document_id: "doc-1",
      lines: [S.line(@sku1, "10", %{to: here})]
    })

    S.post!(schema, "receipt", %{lines: [S.line(@sku2, "4", %{to: here})]})

    S.post!(schema, "transfer", %{
      document_id: "doc-3",
      lines: [S.line(@sku1, "10", %{from: here, to: S.side(@u1, @l2)})]
    })
  end

  defp ledger_statements(fun) do
    {result, statements} = Fx.record(fun)
    {result, Enum.filter(statements, fn {sql, _} -> sql =~ "ledger_" end)}
  end

  describe "balances" do
    test "T-RB-1 rows, zero row, filters, cutoff, paging and the exact key sets", ctx do
      seed!(ctx.a.schema_name)
      body = ok!(S.get("/balances", ctx.tok_a))

      assert body |> Map.keys() |> Enum.sort() ==
               ~w(as_of basis cutoff_seq filters ledger_id ledger_seq next_cursor rows timezone)

      assert %{
               "basis" => "posting_seq",
               "ledger_id" => "stock",
               "cutoff_seq" => 3,
               "as_of" => nil
             } =
               body

      assert body["ledger_seq"] == 3 and body["next_cursor"] == nil and body["filters"] == %{}
      assert is_binary(body["timezone"])
      assert length(body["rows"]) == 3

      for row <- body["rows"] do
        assert row |> Map.keys() |> Enum.sort() ==
                 ~w(last_posting_seq location lot org_unit quantity responsible sku unit_ref)

        assert row["responsible"] == nil and row["lot"] == nil and row["unit_ref"] == "pcs"
      end

      qty = fn rows, sku, loc ->
        row = Enum.find(rows, &(&1["sku"] == sku and &1["location"] == loc))
        row && Decimal.new(row["quantity"])
      end

      assert Decimal.equal?(qty.(body["rows"], @sku1, @l1), 0)
      assert Decimal.equal?(qty.(body["rows"], @sku1, @l2), 10)
      assert Decimal.equal?(qty.(body["rows"], @sku2, @l1), 4)

      only = ok!(S.get("/balances?sku=#{@sku2}", ctx.tok_a))
      assert [%{"sku" => @sku2}] = only["rows"]
      assert only["filters"] == %{"sku" => @sku2}

      # a cutoff read stays byte-identical after a later posting
      before = ok!(S.get("/balances?cutoff_seq=3", ctx.tok_a))

      S.post!(ctx.a.schema_name, "receipt", %{
        lines: [S.line(@sku2, "1", %{to: S.side(@u1, @l1)})]
      })

      later = ok!(S.get("/balances?cutoff_seq=3", ctx.tok_a))
      assert Jason.encode!(later["rows"]) == Jason.encode!(before["rows"])
      assert later["cutoff_seq"] == 3 and before["cutoff_seq"] == 3

      # paging by one row returns every key once
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

      keys = pages |> List.flatten() |> Enum.map(&{&1["sku"], &1["location"]})
      assert length(keys) == 3 and length(Enum.uniq(keys)) == 3

      # the event-time basis
      as_of =
        DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601() |> URI.encode_www_form()

      event = ok!(S.get("/balances?basis=event_time&cutoff_seq=4&as_of=#{as_of}", ctx.tok_a))

      assert event["basis"] == "event_time" and is_binary(event["as_of"]) and
               event["cutoff_seq"] == 4

      assert length(event["rows"]) == 3
    end
  end

  describe "movements" do
    test "T-RM-1 order, filter, paging, key sets and no internal columns", ctx do
      seed!(ctx.a.schema_name)
      body = ok!(S.get("/movements", ctx.tok_a))
      assert body |> Map.keys() |> Enum.sort() == ~w(next_cursor rows)
      assert Enum.map(body["rows"], & &1["posting_seq"]) == [1, 2, 3]

      row = hd(body["rows"])

      assert row |> Map.keys() |> Enum.sort() ==
               ~w(cause correlation_id document_id document_type entry_id event_time legs posting_seq posting_time reason_code related_document_id reverses_entry_id)

      leg = hd(row["legs"])

      assert leg |> Map.keys() |> Enum.sort() ==
               ~w(document_line_id leg_no location lot org_unit quantity responsible sku unit_ref)

      text = body |> Jason.encode!()

      for word <-
            ~w(actor_id subject_id client_op_id origin_key payload_hash device scope_ref bpm_ entry_digest chain_hash) do
        refute text =~ word, "#{word} leaked"
      end

      assert length(Enum.at(body["rows"], 2)["legs"]) == 2

      one = ok!(S.get("/movements?document_id=doc-3", ctx.tok_a))
      assert [%{"posting_seq" => 3, "cause" => "transfer"}] = one["rows"]

      page1 = ok!(S.get("/movements?limit=2", ctx.tok_a))
      assert Enum.map(page1["rows"], & &1["posting_seq"]) == [1, 2]
      assert page1["next_cursor"] == "2"
      page2 = ok!(S.get("/movements?limit=2&cursor=2", ctx.tok_a))
      assert Enum.map(page2["rows"], & &1["posting_seq"]) == [3]
      assert page2["next_cursor"] == nil

      assert Enum.map(
               ok!(S.get("/movements?from_seq=2&to_seq=2", ctx.tok_a))["rows"],
               & &1["posting_seq"]
             ) ==
               [2]

      assert reason!(S.get("/movements?from_seq=3&to_seq=2", ctx.tok_a), 422) == "invalid_filter"
    end
  end

  describe "reconcile" do
    test "T-RC-1 a clean ledger", ctx do
      seed!(ctx.a.schema_name)
      body = ok!(S.get("/reconcile", ctx.tok_a))

      assert body |> Map.keys() |> Enum.sort() ==
               ~w(audit_check chain_check checked_through_seq gap_check ledger_id mismatches next_cursor)

      assert %{
               "ledger_id" => "stock",
               "checked_through_seq" => 3,
               "mismatches" => [],
               "gap_check" => "ok",
               "chain_check" => "ok",
               "audit_check" => "ok",
               "next_cursor" => nil
             } = body
    end

    test "T-RC-1 an empty ledger of an installed module", ctx do
      assert %{"checked_through_seq" => 0, "mismatches" => [], "gap_check" => "ok"} =
               ok!(S.get("/reconcile", ctx.tok_a))
    end

    test "T-RC-2 a balance mismatch, a gap, a broken chain and an audit mismatch", ctx do
      schema = ctx.a.schema_name
      seed!(schema)

      Fx.exec!(
        ~s|UPDATE "#{schema}".ledger_balance SET on_hand = 99, last_posting_seq = 3 WHERE ledger_id = 'stock' AND k1 = $1 AND k2 = $2|,
        [@sku2, @l1]
      )

      %{"mismatches" => [mismatch]} = ok!(S.get("/reconcile", ctx.tok_a))

      assert mismatch |> Map.keys() |> Enum.sort() ==
               ~w(balance ledger_sum location lot org_unit responsible sku)

      assert %{"sku" => @sku2, "location" => @l1, "responsible" => nil, "lot" => nil} = mismatch
      assert Decimal.equal?(Decimal.new(mismatch["balance"]), 99)
      assert Decimal.equal?(Decimal.new(mismatch["ledger_sum"]), 4)
    end

    test "T-RC-2 gap and chain, owner tamper", ctx do
      schema = ctx.a.schema_name

      if Fx.table_owner?(schema) do
        seed!(schema)
        Fx.disable_guards!(schema, "ledger_entry")
        Fx.disable_guards!(schema, "ledger_leg")
        Fx.exec!(~s|DELETE FROM "#{schema}".ledger_leg WHERE posting_seq = 2|)
        Fx.exec!(~s|DELETE FROM "#{schema}".ledger_entry WHERE posting_seq = 2|)

        body = ok!(S.get("/reconcile", ctx.tok_a))
        assert body["gap_check"] == %{"gap" => [2]}
        assert body["chain_check"] == %{"broken_at" => 3}
        refute Jason.encode!(body) =~ "{:"
      else
        IO.puts("T-RC-2 gap/chain skipped: the test role does not own the ledger tables")
      end
    end

    test "T-RC-2 an entry without its audit entry", ctx do
      schema = ctx.a.schema_name
      here = S.side(@u1, @l1)
      S.post!(schema, "receipt", %{lines: [S.line(@sku1, "1", %{to: here})]})
      S.post!(schema, "receipt", %{lines: [S.line(@sku1, "1", %{to: here})]}, audit: false)
      S.post!(schema, "receipt", %{lines: [S.line(@sku1, "1", %{to: here})]})

      body = ok!(S.get("/reconcile", ctx.tok_a))
      assert body["audit_check"] == %{"mismatch_at" => 2}
      assert body["chain_check"] == "ok"
    end

    test "T-RC-3 a held chunk lock is 409 reconcile_busy", ctx do
      schema = ctx.a.schema_name
      seed!(schema)

      holder =
        hold(fn ->
          Fx.exec!("SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))", [schema, "stock"])
        end)

      try do
        conn = S.get("/reconcile", ctx.tok_a)
        assert reason!(conn, 409) == "reconcile_busy"

        assert conn
               |> S.json()
               |> Map.keys()
               |> Enum.sort()
               |> Enum.reject(&(&1 in ~w(detail status title type trace_id instance))) == [
                 "reason"
               ]
      after
        release(holder)
      end

      assert ok!(S.get("/reconcile", ctx.tok_a))["gap_check"] == "ok"
    end

    test "T-RC-3 a statement timeout is 503 ledger_read_timeout without SQL text", ctx do
      schema = ctx.a.schema_name
      seed!(schema)

      previous = Application.fetch_env(:letflow, :stock_reconcile_statement_timeout_ms)
      Application.put_env(:letflow, :stock_reconcile_statement_timeout_ms, 200)

      on_exit(fn ->
        case previous do
          {:ok, v} -> Application.put_env(:letflow, :stock_reconcile_statement_timeout_ms, v)
          :error -> Application.delete_env(:letflow, :stock_reconcile_statement_timeout_ms)
        end
      end)

      holder =
        hold(fn ->
          Fx.exec!(~s|LOCK TABLE "#{schema}".ledger_balance IN ACCESS EXCLUSIVE MODE|)
        end)

      try do
        conn = S.get("/reconcile", ctx.tok_a)
        assert reason!(conn, 503) == "ledger_read_timeout"
        refute conn.resp_body =~ "SELECT"
        refute conn.resp_body =~ "ledger_balance"
        refute conn.resp_body =~ schema
      after
        release(holder)
      end
    end

    test "a foreign or malformed cursor is 422", ctx do
      seed!(ctx.a.schema_name)
      assert reason!(S.get("/reconcile?cursor=nope", ctx.tok_a), 422) == "invalid_filter"
      assert reason!(S.get("/reconcile?x=1", ctx.tok_a), 422) == "invalid_filter"
    end
  end

  defp hold(fun) do
    me = self()

    task =
      Task.async(fn ->
        Letflow.Repo.transaction(fn ->
          fun.()
          send(me, :locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :locked, 5_000
    task
  end

  defp release(task) do
    send(task.pid, :release)
    Task.await(task)
  end

  describe "refusals" do
    test "T-R-404 an API token is refused like an unknown path, as is a tenant without the module",
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

    test "T-R-SC a scoped reader gets 404 on every route (P25 lifts balances and movements)",
         ctx do
      s = S.tenant!("stk-s", ctx.names.s)
      seed!(s.schema_name)
      tok = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "scoped-reader")

      # first login creates the user and the group membership; then the grant becomes scoped
      ok!(S.get("/balances", tok))

      user =
        Letflow.Repo.one!(from(u in User, where: u.username == "scoped-reader"),
          prefix: s.schema_name
        )

      _ =
        RSG.raw_delete_rows!(
          s.schema_name,
          RSG.group_of!(s.schema_name, "TENANT_ADMIN"),
          "TENANT_ADMIN"
        )

      node = RSG.node!(s.schema_name)
      :ok = RSG.raw_user_row!(s.schema_name, user.id, "TENANT_ADMIN", node)

      reference = c_reference(ctx)

      for path <- ["/balances", "/movements", "/reconcile"] do
        conn = S.get(path, tok)
        assert conn.status == 404, path
        assert strip(S.json(conn)) == reference, path
      end
    end

    test "T-R-403 a TASK_WORKER is forbidden on every route and no ledger query runs", ctx do
      tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-1")

      for path <- ["/balances", "/movements", "/reconcile"] do
        {conn, statements} = ledger_statements(fn -> S.get(path, tok) end)
        body = assert_status(conn, 403) |> S.json()
        assert body["title"] == "Forbidden" and body["detail"] == "insufficient permissions"
        assert String.ends_with?(body["type"], "forbidden")
        assert statements == [], path
      end
    end

    test "T-R-422 bad queries are refused before any ledger query", ctx do
      seed!(ctx.a.schema_name)
      slug = Letflow.Repo.get!(Letflow.Identity.Tenant, ctx.a.tenant_id).slug
      other_cursor = Base.url_encode64(Jason.encode!(%{"n" => 1, "k" => []}))

      bad = [
        "/balances?tenant_id=#{@u1}",
        "/balances?prefix=x",
        "/balances?ledger_id=stock",
        "/balances?x=1",
        "/balances?#{slug}=1",
        "/balances?sku=not-a-uuid",
        "/balances?sku=AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
        "/balances?location=",
        "/balances?cutoff_seq=-1",
        "/balances?cutoff_seq=01",
        "/balances?cutoff_seq=abc",
        "/balances?as_of=2026-01-01T00:00:00Z",
        "/balances?basis=event_time",
        "/balances?basis=event_time&cutoff_seq=1",
        "/balances?basis=event_time&cutoff_seq=1&as_of=2026-01-01T00:00:00",
        "/balances?basis=other",
        "/balances?limit=0",
        "/balances?limit=abc",
        "/balances?sku[]=a",
        "/balances?sku[a]=b",
        "/balances?cursor=" <> String.duplicate("a", 5000),
        "/balances?cursor=%00",
        "/movements?tenant_id=x",
        "/movements?from_seq=x",
        "/movements?cause=",
        "/movements?cause[]=a",
        "/movements?cursor=" <> other_cursor,
        "/movements?cursor=abc",
        "/reconcile?tenant_id=x"
      ]

      for path <- bad do
        {conn, statements} = ledger_statements(fn -> S.get(path, ctx.tok_a) end)
        assert reason!(conn, 422) == "invalid_filter", path
        assert statements == [], path
      end

      assert reason!(S.get("/balances?cutoff_seq=99999", ctx.tok_a), 422) == "cutoff_in_future"
      refute File.read!("lib/letflow/modules/stock/router.ex") =~ "binary_to_term"
    end
  end

  describe "tenancy" do
    test "T-R-XT B's admin sees none of A's rows, also with A's values and slug", ctx do
      seed!(ctx.a.schema_name)
      tok_b = S.token(ctx, :b, ["TENANT_ADMIN"])
      slug_a = Letflow.Repo.get!(Letflow.Identity.Tenant, ctx.a.tenant_id).slug

      assert %{"rows" => [], "ledger_seq" => 0} = ok!(S.get("/balances", tok_b))

      assert %{"rows" => []} =
               ok!(S.get("/balances?sku=#{@sku1}&location=#{@l1}&org_unit=#{@u1}", tok_b))

      assert %{"rows" => []} = ok!(S.get("/movements", tok_b))
      assert %{"rows" => []} = ok!(S.get("/movements?document_id=doc-1", tok_b))
      assert %{"checked_through_seq" => 0, "mismatches" => []} = ok!(S.get("/reconcile", tok_b))

      assert reason!(S.get("/balances?#{slug_a}=1", tok_b), 422) == "invalid_filter"

      assert reason!(S.get("/balances?tenant_id=#{ctx.a.tenant_id}", tok_b), 422) ==
               "invalid_filter"

      assert reason!(S.get("/movements?prefix=#{ctx.a.schema_name}", tok_b), 422) ==
               "invalid_filter"

      # a slug header naming A does not redirect B's token
      assert %{"rows" => []} = ok!(S.get("/balances", tok_b, [{"x-tenant-slug", slug_a}]))
    end

    test "T-R-XT a PLATFORM_ADMIN token reads only its own tenant's ledger", ctx do
      seed!(ctx.a.schema_name)
      S.tenant!("stk-p", ctx.names.p, platform: true)
      tok = S.token(ctx, :p, ["PLATFORM_ADMIN"], sub: "platform-1")

      assert %{"rows" => [], "ledger_seq" => 0} = ok!(S.get("/balances", tok))
      assert %{"rows" => []} = ok!(S.get("/movements", tok))
      assert %{"checked_through_seq" => 0} = ok!(S.get("/reconcile", tok))
    end
  end

  # The dispatcher's answer for a tenant without the module: the body the refusals must equal.
  defp c_reference(ctx) do
    S.tenant!("stk-ref", ctx.names.c, install: false)
    tok = S.token(ctx, :c, ["TENANT_ADMIN"], sub: "ref-admin")
    conn = S.get("/balances", tok)
    assert conn.status == 404
    strip(S.json(conn))
  end
end
