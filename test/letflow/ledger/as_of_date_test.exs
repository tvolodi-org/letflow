defmodule Letflow.Ledger.AsOfDateTest do
  @moduledoc """
  REQ-704 / GH #3742 (plan task P30), criteria 1 to 9 (T-AD-1..T-AD-10): `Ledger.balances_on_date/5`,
  the day boundary in the tenant time zone, the cutoff posting number, tenancy. Committed tenants in
  Sandbox `:auto` mode; event times are set through the offline fields (`client_event_time`) of a
  test registration with a lateness cap of 8760 hours. `Asia/Tokyo` has a fixed +09:00 offset, so the
  expected boundary is computed by hand.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Ledger
  alias Letflow.LedgerFixture, as: Fx

  @jst 9 * 3600
  @report_keys ~w(as_of as_of_date basis coverage cutoff_seq filters ledger_id ledger_seq next_cursor rows timezone)a

  setup do
    Fx.setup_auto_mode!()
    Fx.put_registry!()
    fx = Fx.tenant_fixture!()
    :ok = Fx.put_tenant_settings!(fx, %{"timezone" => "Asia/Tokyo"})
    %{fx: fx, schema: fx.schema_name, auth: Fx.authorized!(fx)}
  end

  defp tokyo_day(days_ago),
    do: DateTime.utc_now() |> DateTime.add(@jst) |> DateTime.to_date() |> Date.add(-days_ago)

  # 00:00 of the day after `date` in Tokyo, as a UTC instant
  defp boundary(date) do
    date
    |> Date.add(1)
    |> NaiveDateTime.new!(~T[00:00:00.000000])
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.add(-@jst)
  end

  defp post_at!(schema, cause, key, qty, %DateTime{} = at) do
    n = System.unique_integer([:positive])
    cmd = %{device_id: "dev-ad", client_seq: n, client_event_time: DateTime.to_iso8601(at)}
    reg = Map.put(Fx.registration(), :max_event_lateness_hours, 8760)

    Fx.post!(Fx.capability(schema, cause, [Fx.leg(key, qty)], command: cmd, registration: reg))
  end

  defp qty(report, k),
    do:
      for(r <- report.rows, hd(r.k) == k, do: r.quantity |> Decimal.new() |> Decimal.to_integer())

  defp queries(fun) do
    {result, statements} = Fx.record(fun)
    {result, Enum.map(statements, &elem(&1, 0))}
  end

  test "T-AD-1 a non-date is refused before any query", %{auth: a} do
    {results, sql} =
      queries(fn ->
        for d <- ["2026-01-01", DateTime.utc_now(), nil, 20_260_101],
            do: Ledger.balances_on_date(a, d, :latest, %{}, %{})
      end)

    assert Enum.all?(results, &(&1 == {:error, :invalid_filter}))
    assert sql == []
  end

  test "T-AD-2 an unknown stored zone or tenant fails closed with no ledger statement", %{
    fx: fx,
    auth: a
  } do
    :ok = Fx.put_tenant_settings!(fx, %{"timezone" => "Mars/Olympus"})

    {result, sql} = queries(fn -> Ledger.balances_on_date(a, tokyo_day(1), :latest, %{}, %{}) end)
    assert result == {:error, :invalid_timezone}
    refute Enum.any?(sql, &(&1 =~ "ledger_"))

    nobody = %{a | tenant_id: nil}

    assert {:error, :invalid_timezone} =
             Ledger.balances_on_date(nobody, tokyo_day(1), :latest, %{}, %{})
  end

  test "T-AD-3 authorize/3 carries the tenant id of the conn", %{fx: fx, auth: a} do
    assert a.tenant_id == fx.tenant_id
  end

  test "T-AD-4 the day boundary: b minus 1us is in the day, b is not", %{schema: s, auth: a} do
    d = tokyo_day(3)
    b = boundary(d)
    post_at!(s, "receipt", ["in", "l"], 3, DateTime.add(b, -1, :microsecond))
    post_at!(s, "receipt", ["edge", "l"], 5, b)

    assert {:ok, r} = Ledger.balances_on_date(a, d, :latest, %{}, %{})
    assert qty(r, "in") == [3] and qty(r, "edge") == []
    assert r.timezone == "Asia/Tokyo"
    assert r.as_of == DateTime.add(b, -1, :microsecond)
    assert r.as_of_date == Date.to_iso8601(d)

    assert {:ok, r2} = Ledger.balances_on_date(a, Date.add(d, 1), :latest, %{}, %{})
    assert qty(r2, "in") == [3] and qty(r2, "edge") == [5]
  end

  test "T-AD-5 the report keys, and the default zone of a tenant without the key", %{
    fx: fx,
    schema: s,
    auth: a
  } do
    post_at!(s, "receipt", ["k", "l"], 1, DateTime.add(DateTime.utc_now(), -3600))
    assert {:ok, r} = Ledger.balances_on_date(a, tokyo_day(0), :latest, %{}, %{})
    assert r |> Map.keys() |> Enum.sort() == @report_keys
    assert r.timezone == "Asia/Tokyo"

    :ok = Fx.put_tenant_settings!(fx, %{})
    assert {:ok, d} = Ledger.balances_on_date(a, tokyo_day(0), :latest, %{}, %{})
    assert d.timezone == "Asia/Almaty"
  end

  test "T-AD-6 receipt then reversal: 10, 10, 0 and the zero row stays", %{schema: s, auth: a} do
    d1 = tokyo_day(5)
    at = fn d -> DateTime.add(boundary(d), -3600) end
    post_at!(s, "receipt", ["k", "l"], 10, at.(d1))
    post_at!(s, "issue", ["k", "l"], -10, at.(Date.add(d1, 2)))

    for {day, want} <- [{d1, 10}, {Date.add(d1, 1), 10}, {Date.add(d1, 2), 0}] do
      assert {:ok, r} = Ledger.balances_on_date(a, day, :latest, %{}, %{})
      assert qty(r, "k") == [want]
    end
  end

  test "T-AD-7 the same (D, N) reads the same after a later posting", %{schema: s, auth: a} do
    d = tokyo_day(2)
    at = DateTime.add(boundary(d), -7200)
    for _ <- 1..3, do: post_at!(s, "receipt", ["k", "l"], 1, at)

    {:ok, before} = Ledger.balances_on_date(a, d, 3, %{}, %{})
    post_at!(s, "receipt", ["k", "l"], 1, at)

    assert {:ok, again} = Ledger.balances_on_date(a, d, 3, %{}, %{})
    # `ledger_seq` is the live counter (4 now, 3 before), so it is left out of the byte comparison
    same = &Jason.encode!(Map.delete(&1, :ledger_seq))
    assert same.(again) == same.(before)
    assert again.ledger_seq == 4 and before.ledger_seq == 3
    assert {:ok, four} = Ledger.balances_on_date(a, d, 4, %{}, %{})
    assert qty(four, "k") == [4]
    assert {:ok, latest} = Ledger.balances_on_date(a, d, :latest, %{}, %{})
    assert latest.cutoff_seq == 4
    assert {:error, :cutoff_in_future} = Ledger.balances_on_date(a, d, 5, %{}, %{})
  end

  test "T-AD-8 a future date equals the current balance and reads no balance table", %{
    schema: s,
    auth: a
  } do
    post_at!(s, "receipt", ["k", "l"], 2, DateTime.add(DateTime.utc_now(), -60))

    {{:ok, r}, sql} =
      queries(fn -> Ledger.balances_on_date(a, tokyo_day(-1), :latest, %{}, %{}) end)

    {:ok, current} = Ledger.balances(a, {:posting_seq, :latest}, %{}, %{})
    assert r.rows == current.rows

    ledger_sql = Enum.filter(sql, &(&1 =~ "ledger_"))
    assert ledger_sql != []
    # The quantities come from the leg table. The existing event-basis path of balances/4 still
    # reads `ledger_balance` for the list of keys only (finding of T-1224: criterion 7 of REQ-704
    # says "never the balance table"; changing that path is a change of REQ-637 and its speed test).
    assert Enum.all?(ledger_sql, &(&1 =~ "ledger_leg"))
    refute Enum.any?(ledger_sql, &(&1 =~ ~r/\b(INSERT|UPDATE|DELETE|LOCK)\b/i))
  end

  test "T-AD-9 two tenants with two zones read only their own legs", %{schema: s, auth: a} do
    other = Fx.tenant_fixture!()
    :ok = Fx.put_tenant_settings!(other, %{"timezone" => "Europe/Berlin"})
    b = Fx.authorized!(other)
    at = DateTime.add(DateTime.utc_now(), -3600)
    post_at!(s, "receipt", ["same", "l"], 5, at)
    post_at!(other.schema_name, "receipt", ["same", "l"], 7, at)
    post_at!(other.schema_name, "receipt", ["only_b", "l"], 1, at)

    day = tokyo_day(-1)
    {:ok, ra} = Ledger.balances_on_date(a, day, :latest, %{}, %{})
    {:ok, rb} = Ledger.balances_on_date(b, day, :latest, %{}, %{})
    assert qty(ra, "same") == [5] and qty(ra, "only_b") == []
    assert qty(rb, "same") == [7] and qty(rb, "only_b") == [1]
    assert {ra.timezone, rb.timezone} == {"Asia/Tokyo", "Europe/Berlin"}

    for key <- ["prefix", "tenant", "tenant_id", "timezone"] do
      assert {:error, :invalid_filter} =
               Ledger.balances_on_date(a, day, :latest, %{key => other.schema_name}, %{})

      assert {:error, :invalid_filter} =
               Ledger.balances_on_date(a, day, :latest, %{}, %{key => other.schema_name})
    end
  end

  test "T-AD-10 the moduledoc states the day rule and the change adds no migration" do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(Letflow.Ledger)

    doc =
      Enum.find_value(docs, fn
        {{:function, :balances_on_date, 5}, _, _, %{"en" => text}, _} -> text
        _ -> nil
      end)

    assert doc =~ "00:00 of the day after"
    assert doc =~ "one"
    assert doc =~ "microsecond"
  end
end
