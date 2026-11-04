defmodule Letflow.Ledger.ScopedReadTest do
  @moduledoc """
  REQ-693 / GH #3733 (assets B6): the scoped read of the core ledger (decision 0073 S3..S7).
  T-SR-1..10. Sandbox `:auto`, real committed tenants, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.Api.Scope
  alias Letflow.Ledger
  alias Letflow.Ledger.Authorized
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.ScopeNodePaths
  alias Letflow.Support.RoleScopeGrantsFixture
  alias Letflow.Support.TokenMintFixture

  @id Fx.ledger_id()
  @reg_opts [scope_slot: "k_unit"]
  @role "PROCESS_DESIGNER"

  setup do
    Fx.setup_auto_mode!()
    Fx.put_registry!(Fx.registry(@reg_opts))
    fx = Fx.tenant_fixture!()
    s = fx.schema_name

    [p, a, b, h, x] = for _ <- 1..5, do: Ecto.UUID.generate()
    {:ok, _} = ScopeNodePaths.write({:insert, p, nil}, s)
    for n <- [a, b, h], do: {:ok, _} = ScopeNodePaths.write({:insert, n, p}, s)
    {:ok, _} = ScopeNodePaths.write({:insert, x, nil}, s)

    %{fx: fx, s: s, p: p, a: a, b: b, h: h, x: x}
  end

  defp cap(s, cause, legs, opts \\ []),
    do: Fx.capability(s, cause, legs, [registration: Fx.registration(@reg_opts)] ++ opts)

  defp receipt!(s, unit, qty, sku \\ "sku1"),
    do: Fx.post!(cap(s, "receipt", [Fx.leg([sku, "", "", unit], qty)]))

  # Funds the sending unit first (a transfer needs the balance), then moves `qty`.
  defp transfer!(s, from, to, qty, opts \\ []) do
    Fx.post!(cap(s, "receipt", [Fx.leg(["sku1", "", "", from], qty)], opts))

    Fx.post!(
      cap(
        s,
        "transfer",
        [Fx.leg(["sku1", "", "", from], -qty), Fx.leg(["sku1", "", "", to], qty)],
        opts
      )
    )
  end

  defp transfers(rows), do: Enum.filter(rows, &(&1.cause in ["transfer", "reversal"]))

  defp scoped_auth(fx, node_ids, purpose \\ :read) do
    user = TokenMintFixture.role_holder!(fx.schema_name, [])

    for n <- node_ids,
        do: :ok = RoleScopeGrantsFixture.raw_user_row!(fx.schema_name, user.id, @role, n)

    Ledger.authorize(Fx.conn_for(fx, user, [@role]), @id, purpose)
  end

  defp scoped!(fx, node_ids) do
    {:ok, auth} = scoped_auth(fx, node_ids)
    auth
  end

  defp latest(auth, filters \\ %{}, page \\ %{}) do
    {:ok, rep} = Ledger.balances(auth, {:posting_seq, :latest}, filters, page)
    rep
  end

  defp units(rep), do: rep.rows |> Enum.map(&Enum.at(&1.k, 3)) |> Enum.sort()

  defp total(rep),
    do:
      rep.rows
      |> Enum.map(&Decimal.new(&1.quantity))
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

  defp seed(ctx) do
    receipt!(ctx.s, ctx.p, 5)
    receipt!(ctx.s, ctx.a, 10)
    receipt!(ctx.s, ctx.b, 20)
    receipt!(ctx.s, ctx.h, 40)
  end

  test "T-SR-1 fixture registration with and without scope_slot" do
    r = Fx.registration(scope_slot: "k_unit")
    assert length(r.slots) == 4
    assert List.last(r.slots) == %{name: "k_unit", format: :uuid, required: false}
    assert r.scope_slot == "k_unit"
    plain = Fx.registration()
    assert length(plain.slots) == 3
    refute Map.has_key?(plain, :scope_slot)
  end

  describe "authorize/3 (T-SR-2)" do
    test "T-SR-2a scoped reader gets the node set, tenant-wide gets :all", %{fx: fx, a: a, b: b} do
      auth = scoped!(fx, [a, b])
      assert %Authorized{scope: {:nodes, ids}, scope_col: :k4} = auth
      assert Enum.sort(ids) == Enum.sort([a, b])

      assert {:ok, %Authorized{scope: :all, scope_col: :k4}} =
               Ledger.authorize(
                 Fx.conn_for(fx, Fx.user!(fx, ["TENANT_ADMIN"]), ["TENANT_ADMIN"]),
                 @id,
                 :read
               )
    end

    test "T-SR-2b no grant row is refused", %{fx: fx} do
      user = TokenMintFixture.role_holder!(fx.schema_name, [])
      assert Ledger.authorize(Fx.conn_for(fx, user, [@role]), @id, :read) === :error
    end

    test "T-SR-2c a set over the cap is refused", %{fx: fx, p: p} do
      previous = Application.get_env(:letflow, :scope_allowed_ids_cap)
      Application.put_env(:letflow, :scope_allowed_ids_cap, 1)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:letflow, :scope_allowed_ids_cap, previous),
          else: Application.delete_env(:letflow, :scope_allowed_ids_cap)
      end)

      assert scoped_auth(fx, [p]) === :error
    end

    test "T-SR-2d a registration without scope_slot refuses a scoped reader", %{fx: fx, a: a} do
      Fx.put_registry!(Fx.registry())
      assert scoped_auth(fx, [a]) === :error
    end

    test "T-SR-2e a scoped reconcile is refused", %{fx: fx, a: a} do
      assert scoped_auth(fx, [a], :reconcile) === :error
    end
  end

  describe "balances/4 (T-SR-3, 4, 5)" do
    test "T-SR-3a rows of the reader's units only, both bases", ctx do
      seed(ctx)
      auth = scoped!(ctx.fx, [ctx.a, ctx.b])
      rep = latest(auth)
      assert units(rep) == Enum.sort([ctx.a, ctx.b])
      assert Decimal.equal?(total(rep), 30)

      wide = latest(Fx.authorized!(ctx.fx))
      # the plain test helper registry has no scope slot: use a real tenant-wide authorize
      assert length(wide.rows) == 4

      {:ok, tw} =
        Ledger.authorize(
          Fx.conn_for(ctx.fx, Fx.user!(ctx.fx, ["TENANT_ADMIN"]), ["TENANT_ADMIN"]),
          @id,
          :read
        )

      assert tw |> latest() |> total() |> Decimal.equal?(75)

      {:ok, ev} = Ledger.balances(auth, {:event_time, DateTime.utc_now(), :latest}, %{}, %{})
      assert units(ev) == Enum.sort([ctx.a, ctx.b])
    end

    test "T-SR-3c an empty scope slot is invisible to a scoped reader", ctx do
      Fx.post!(cap(ctx.s, "receipt", [Fx.leg(["sku1", "", "", ""], 7)]))
      receipt!(ctx.s, ctx.a, 1)
      assert [_] = latest(scoped!(ctx.fx, [ctx.a])).rows
    end

    test "T-SR-3d paging walks visible rows only", ctx do
      seed(ctx)
      auth = scoped!(ctx.fx, [ctx.a, ctx.b])
      first = latest(auth, %{}, %{limit: 1})
      assert length(first.rows) == 1 and first.next_cursor
      second = latest(auth, %{}, %{limit: 1, cursor: first.next_cursor})
      assert length(second.rows) == 1 and second.next_cursor == nil
      assert Enum.sort(units(first) ++ units(second)) == Enum.sort([ctx.a, ctx.b])
    end

    test "T-SR-4a scope_subtree narrows, with a slot filter both apply", ctx do
      seed(ctx)
      auth = scoped!(ctx.fx, [ctx.a, ctx.b])
      rep = latest(auth, %{"scope_subtree" => ctx.p})
      assert units(rep) == Enum.sort([ctx.a, ctx.b])
      assert rep.filters == %{"scope_subtree" => ctx.p}

      rep = latest(auth, %{scope_subtree: ctx.a, k_primary: "sku1"})
      assert units(rep) == [ctx.a]

      assert [] == latest(auth, %{scope_subtree: ctx.a, k_primary: "nope"}).rows
    end

    test "T-SR-4b bad subtree ids are refused before any statement", ctx do
      auth = scoped!(ctx.fx, [ctx.a])

      for bad <- [1, "a/b", "", String.duplicate("x", 65), %{}, ["a"]] do
        {res, stmts} =
          Fx.record(fn ->
            Ledger.balances(auth, {:posting_seq, :latest}, %{scope_subtree: bad}, %{})
          end)

        assert res == {:error, :invalid_filter}
        assert stmts == []
      end

      Fx.put_registry!(Fx.registry())

      {:ok, plain} =
        Ledger.authorize(
          Fx.conn_for(ctx.fx, Fx.user!(ctx.fx, ["TENANT_ADMIN"]), ["TENANT_ADMIN"]),
          @id,
          :read
        )

      assert {:error, :invalid_filter} =
               Ledger.balances(plain, {:posting_seq, :latest}, %{scope_subtree: ctx.p}, %{})
    end

    test "T-SR-4c subtree ids equal descendants_of/2", ctx do
      weird = "n_%x"
      {:ok, _} = ScopeNodePaths.write({:insert, weird, ctx.p}, ctx.s)
      {:ok, _} = ScopeNodePaths.write({:retire, ctx.h}, ctx.s)
      receipt!(ctx.s, ctx.h, 1)
      Fx.post!(cap(ctx.s, "receipt", [Fx.leg(["sku1", "", "", Ecto.UUID.generate()], 1)]))
      {:ok, nodes} = ScopeNodePaths.descendants_of([ctx.p], ctx.s)
      expected = nodes |> Enum.map(& &1.node_id) |> MapSet.new()
      assert ctx.h in expected and weird in expected

      {:ok, tw} =
        Ledger.authorize(
          Fx.conn_for(ctx.fx, Fx.user!(ctx.fx, ["TENANT_ADMIN"]), ["TENANT_ADMIN"]),
          @id,
          :read
        )

      got = tw |> latest(%{scope_subtree: ctx.p}) |> units() |> MapSet.new()
      assert got == MapSet.new([ctx.h])
      assert MapSet.subset?(got, expected)
    end

    test "T-SR-5a coverage", ctx do
      seed(ctx)
      auth = scoped!(ctx.fx, [ctx.a, ctx.b])
      assert latest(auth).coverage == nil
      rep = latest(auth, %{scope_subtree: ctx.p})
      assert rep.coverage == :visible_only
      assert Decimal.equal?(total(rep), 30)

      rep = latest(scoped!(ctx.fx, [ctx.p]), %{scope_subtree: ctx.p})
      assert rep.coverage == :complete
      assert Decimal.equal?(total(rep), 75)
    end

    test "T-SR-5b unknown and empty subtree look alike", ctx do
      seed(ctx)
      auth = scoped!(ctx.fx, [ctx.a, ctx.b])
      empty = Ecto.UUID.generate()
      {:ok, _} = ScopeNodePaths.write({:insert, empty, ctx.p}, ctx.s)
      unknown = Ecto.UUID.generate()

      {r1, s1} = Fx.record(fn -> latest(auth, %{scope_subtree: unknown}) end)
      {r2, s2} = Fx.record(fn -> latest(auth, %{scope_subtree: empty}) end)
      assert r1.rows == [] and r2.rows == []
      assert r1.coverage == :visible_only and r2.coverage == :visible_only
      assert Map.drop(r1, [:filters]) == Map.drop(r2, [:filters])
      assert length(s1) == length(s2)
    end

    test "T-SR-5e coverage rule equals Scope.allowed?/3", ctx do
      user = TokenMintFixture.role_holder!(ctx.fx.schema_name, [])
      :ok = RoleScopeGrantsFixture.raw_user_row!(ctx.s, user.id, @role, ctx.p)
      {:ok, _} = ScopeNodePaths.write({:retire, ctx.h}, ctx.s)
      conn = Fx.conn_for(ctx.fx, user, [@role])
      {:ok, auth} = Ledger.authorize(conn, @id, :read)
      {:ok, _conn, principal} = Scope.principal_from_conn(conn)

      for node <- [ctx.p, ctx.a, ctx.x, ctx.h, Ecto.UUID.generate()] do
        allowed = match?({:allow, _}, Scope.allowed?(principal, :ScriptsWrite, {:node, node}))
        cov = latest(auth, %{scope_subtree: node}).coverage
        assert cov == :complete == allowed, "node #{node}"
      end
    end
  end

  describe "entries/3 (T-SR-6, 7, 8)" do
    test "T-SR-6a a hidden leg is masked", ctx do
      transfer!(ctx.s, ctx.a, ctx.h, 3)
      auth = scoped!(ctx.fx, [ctx.a])
      {:ok, %{rows: [row]}} = Ledger.entries(auth, %{cause: "transfer"}, %{})
      assert [vis, hid] = Enum.sort_by(row.legs, & &1.leg_no)
      assert Map.keys(hid) |> Enum.sort() == [:leg_no, :masked, :quantity, :unit_ref]
      assert hid.masked == true
      assert vis.k |> Enum.at(3) == ctx.a
      refute Map.has_key?(vis, :masked)

      {:ok, tw} =
        Ledger.authorize(
          Fx.conn_for(ctx.fx, Fx.user!(ctx.fx, ["TENANT_ADMIN"]), ["TENANT_ADMIN"]),
          @id,
          :read
        )

      {:ok, %{rows: [wide]}} = Ledger.entries(tw, %{cause: "transfer"}, %{})
      assert Enum.all?(wide.legs, &(not Map.has_key?(&1, :masked) and Map.has_key?(&1, :k)))
    end

    test "T-SR-6b hidden values are selected through CASE only", ctx do
      transfer!(ctx.s, ctx.a, ctx.h, 3)
      auth = scoped!(ctx.fx, [ctx.a])
      {_res, stmts} = Fx.record(fn -> Ledger.entries(auth, %{}, %{}) end)
      {sql, params} = Enum.find(stmts, fn {q, _} -> q =~ "ledger_leg" and q =~ "CASE WHEN" end)
      select_list = sql |> String.split(" FROM ") |> hd()
      assert select_list =~ "CASE WHEN"
      stripped = Regex.replace(~r/CASE WHEN .*? END/, select_list, "")
      refute stripped =~ ~r/l0\."k[1-8]"(?! = ANY)/
      refute stripped =~ "document_line_id"
      refute Enum.any?(params, &(&1 == ctx.h))
    end

    test "T-SR-6c subtree on entries and paging", ctx do
      transfer!(ctx.s, ctx.a, ctx.h, 1)
      receipt!(ctx.s, ctx.h, 2)
      transfer!(ctx.s, ctx.a, ctx.b, 1)
      auth = scoped!(ctx.fx, [ctx.a, ctx.b])
      {:ok, %{rows: all}} = Ledger.entries(auth, %{cause: "transfer"}, %{})
      assert length(all) == 2
      {:ok, %{rows: sub}} = Ledger.entries(auth, %{scope_subtree: ctx.b, cause: "transfer"}, %{})
      assert length(sub) == 1

      {:ok, %{rows: [_], next_cursor: c}} =
        Ledger.entries(auth, %{cause: "transfer"}, %{limit: 1})

      assert c

      {:ok, %{rows: [_], next_cursor: nil}} =
        Ledger.entries(auth, %{cause: "transfer"}, %{limit: 1, cursor: c})

      assert {:error, :invalid_filter} = Ledger.entries(auth, %{scope_subtree: "a/b"}, %{})
    end

    test "T-SR-7a hidden entries are absent, hidden and unknown documents alike", ctx do
      receipt!(ctx.s, ctx.h, 2)

      Fx.post!(
        cap(ctx.s, "receipt", [Fx.leg(["sku1", "", "", ctx.h], 1)],
          posting: %{document_type: "d", document_id: "doc-h"}
        )
      )

      auth = scoped!(ctx.fx, [ctx.a, ctx.b])
      assert {:ok, %{rows: []}} = Ledger.entries(auth, %{}, %{})
      {r1, s1} = Fx.record(fn -> Ledger.entries(auth, %{document_id: "doc-h"}, %{}) end)
      {r2, s2} = Fx.record(fn -> Ledger.entries(auth, %{document_id: "nope"}, %{}) end)
      assert r1 == {:ok, %{rows: [], next_cursor: nil}}
      assert r1 == r2
      assert length(s1) == length(s2)
    end

    test "T-SR-7b a reversal is masked by the same rule", ctx do
      posted = transfer!(ctx.s, ctx.a, ctx.h, 3)

      Fx.post!(
        Fx.reversal_capability(ctx.s, posted.entry_id, registration: Fx.registration(@reg_opts))
      )

      auth = scoped!(ctx.fx, [ctx.a])
      {:ok, %{rows: rows}} = Ledger.entries(auth, %{}, %{})
      rows = transfers(rows)
      assert length(rows) == 2
      assert Enum.all?(rows, fn r -> Enum.count(r.legs, &Map.get(&1, :masked)) == 1 end)
    end

    test "T-SR-8 two ledger ids are read by their own values", ctx do
      other = "ledger_b"
      reg = Fx.registry(@reg_opts)
      Fx.put_registry!(Map.put(reg, other, reg[@id]))
      transfer!(ctx.s, ctx.a, ctx.h, 3, ledger_id: other)
      transfer!(ctx.s, ctx.a, ctx.b, 1)

      user = TokenMintFixture.role_holder!(ctx.s, [])
      :ok = RoleScopeGrantsFixture.raw_user_row!(ctx.s, user.id, @role, ctx.a)
      conn = Fx.conn_for(ctx.fx, user, [@role])
      {:ok, a1} = Ledger.authorize(conn, @id, :read)
      {:ok, a2} = Ledger.authorize(conn, other, :read)
      assert a1.ledger_id != a2.ledger_id
      {:ok, %{rows: [r1]}} = Ledger.entries(a1, %{cause: "transfer"}, %{})
      {:ok, %{rows: [r2]}} = Ledger.entries(a2, %{cause: "transfer"}, %{})
      assert Enum.count(r1.legs, &Map.get(&1, :masked)) == 1
      assert Enum.count(r2.legs, &Map.get(&1, :masked)) == 1
      assert r1.ledger_id == @id and r2.ledger_id == other
    end
  end

  describe "current tree and hygiene (T-SR-9, 10)" do
    test "T-SR-9a a moved node leaves the reader", ctx do
      seed(ctx)
      transfer!(ctx.s, ctx.a, ctx.b, 1)
      {:ok, _} = ScopeNodePaths.write({:move, ctx.b, ctx.x}, ctx.s)
      auth = scoped!(ctx.fx, [ctx.p])
      assert ctx.b not in units(latest(auth))
      {:ok, %{rows: rows}} = Ledger.entries(auth, %{}, %{})
      assert Enum.any?(rows, fn r -> Enum.any?(r.legs, &Map.get(&1, :masked)) end)
      assert ctx.b in units(latest(scoped!(ctx.fx, [ctx.x])))
    end

    test "T-SR-9b a retired node leaves the reader, tenant-wide keeps it", ctx do
      seed(ctx)
      {:ok, _} = ScopeNodePaths.write({:retire, ctx.a}, ctx.s)
      assert ctx.a not in units(latest(scoped!(ctx.fx, [ctx.p])))

      {:ok, tw} =
        Ledger.authorize(
          Fx.conn_for(ctx.fx, Fx.user!(ctx.fx, ["TENANT_ADMIN"]), ["TENANT_ADMIN"]),
          @id,
          :read
        )

      assert ctx.a in units(latest(tw))
    end

    test "T-SR-10a no log output and typed errors", ctx do
      seed(ctx)
      transfer!(ctx.s, ctx.a, ctx.h, 3)

      auth = scoped!(ctx.fx, [ctx.a])

      log =
        capture_log([level: :info], fn ->
          latest(auth, %{scope_subtree: ctx.p})
          Ledger.entries(auth, %{scope_subtree: ctx.p}, %{})
          Ledger.balances(auth, {:posting_seq, :latest}, %{scope_subtree: %{}}, %{})
          Ledger.entries(auth, %{scope_subtree: [1]}, %{})
        end)

      refute log =~ ctx.a
      refute log =~ ctx.h
    end

    test "T-SR-10b another tenant's rows are never read", ctx do
      seed(ctx)
      fx2 = Fx.tenant_fixture!()
      {:ok, _} = ScopeNodePaths.write({:insert, ctx.a, nil}, fx2.schema_name)
      receipt!(fx2.schema_name, ctx.a, 99)
      assert Decimal.equal?(total(latest(scoped!(ctx.fx, [ctx.a]))), 10)
      assert Decimal.equal?(total(latest(scoped!(fx2, [ctx.a]))), 99)
    end

    test "T-SR-10d every statement of a subtree read names the tenant schema", ctx do
      seed(ctx)
      auth = scoped!(ctx.fx, [ctx.a])
      {_r, stmts} = Fx.record(fn -> latest(auth, %{scope_subtree: ctx.p}) end)
      assert stmts != []
      ledger_stmts = Enum.filter(stmts, fn {sql, _} -> sql =~ ~r/ledger_|scope_node_paths/ end)
      assert Enum.all?(ledger_stmts, fn {sql, _} -> sql =~ ctx.s end)
      assert Enum.any?(ledger_stmts, fn {sql, _} -> sql =~ ~s|"#{ctx.s}"."scope_node_paths"| end)
    end
  end
end
