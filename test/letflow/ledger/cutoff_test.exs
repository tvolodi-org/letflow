defmodule Letflow.Ledger.CutoffTest do
  @moduledoc """
  REQ-637 / GH #3559 part B, criterion 4: `Letflow.Ledger.balances/4` on the two bases, filters,
  paging and the one-snapshot read (T-CO-1..7). Sandbox `:auto`, committed tenants, `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Ledger
  alias Letflow.Ledger.Digest
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.Repo

  setup do
    Fx.setup_auto_mode!()
    Fx.put_registry!()
    fx = Fx.tenant_fixture!()
    %{fx: fx, schema: fx.schema_name, auth: Fx.authorized!(fx)}
  end

  defp receipt!(schema, key, qty, command \\ %{}) do
    Fx.post!(Fx.capability(schema, "receipt", [Fx.leg(key, qty)], command: command))
  end

  defp late!(schema, key, qty, n, hours_ago) do
    time = DateTime.utc_now() |> DateTime.add(-hours_ago * 3600) |> DateTime.to_iso8601()

    receipt!(schema, key, qty, %{device_id: "dev-#{n}", client_seq: n, client_event_time: time})
  end

  defp qty(report), do: Map.new(report.rows, &{hd(&1.k), &1.quantity})

  test "T-CO-1 as-posted sums the legs up to n; :latest is the counter", %{
    schema: s,
    auth: a
  } do
    receipt!(s, ["a", "l"], 5)
    receipt!(s, ["b", "l"], 3)
    receipt!(s, ["a", "l"], 2)

    assert {:ok, r2} = Ledger.balances(a, {:posting_seq, 2}, %{}, %{})
    assert qty(r2) == %{"a" => "5.000000000", "b" => "3.000000000"}
    assert r2.cutoff_seq == 2 and r2.ledger_seq == 3

    assert {:ok, r3} = Ledger.balances(a, {:posting_seq, 3}, %{}, %{})
    assert qty(r3) == %{"a" => "7.000000000", "b" => "3.000000000"}

    assert {:ok, latest} = Ledger.balances(a, {:posting_seq, :latest}, %{}, %{})
    assert latest.cutoff_seq == 3 and latest.ledger_seq == 3
    assert qty(latest) == qty(r3)
    assert latest.basis == %{type: "posting_seq", n: 3}

    assert {:ok, r0} = Ledger.balances(a, {:posting_seq, 0}, %{}, %{})
    assert r0.rows == [] and r0.cutoff_seq == 0
  end

  test "T-CO-1b a ledger id with no counter row reports an empty ledger", %{auth: a} do
    assert {:ok, r} = Ledger.balances(a, {:posting_seq, :latest}, %{}, %{})
    assert r.rows == [] and r.ledger_seq == 0 and r.cutoff_seq == 0 and r.next_cursor == nil
    assert {:error, :cutoff_in_future} = Ledger.balances(a, {:posting_seq, 1}, %{}, %{})
  end

  test "T-CO-2 a cutoff above the counter is cutoff_in_future, also from a cursor", %{
    schema: s,
    auth: a
  } do
    receipt!(s, ["a", "l"], 1)
    now = DateTime.utc_now()
    assert {:error, :cutoff_in_future} = Ledger.balances(a, {:posting_seq, 2}, %{}, %{})
    assert {:error, :cutoff_in_future} = Ledger.balances(a, {:event_time, now, 2}, %{}, %{})

    cursor = Base.url_encode64(Jason.encode!(%{"n" => 99, "k" => List.duplicate("", 8)}))
    page = %{cursor: cursor}
    assert {:error, :cutoff_in_future} = Ledger.balances(a, {:posting_seq, :latest}, %{}, page)
  end

  test "T-CO-3 a basis of any other shape is invalid_filter before any query", %{auth: a} do
    now = DateTime.utc_now()

    bad = [
      {:event_time, now},
      {:event_time, "2026-01-01T00:00:00Z", 1},
      {:event_time, now, -1},
      {:event_time, now, "1"},
      {:posting_seq, -1},
      {:posting_seq, "3"},
      {:posting_seq, 1, 2},
      :latest,
      nil
    ]

    {results, statements} =
      Fx.record(fn -> for b <- bad, do: Ledger.balances(a, b, %{}, %{}) end)

    assert Enum.all?(results, &(&1 == {:error, :invalid_filter}))
    assert statements == []
  end

  test "T-CO-4 G2: a recorded report is reproduced after later and late postings", %{
    schema: s,
    auth: a
  } do
    receipt!(s, ["a", "l"], 5)
    receipt!(s, ["b", "l"], 3)
    receipt!(s, ["a", "l"], 2)
    t = DateTime.utc_now()

    stable = fn basis ->
      {:ok, r} = Ledger.balances(a, basis, %{}, %{})
      {Digest.canonical_json(Map.delete(r, :ledger_seq)), r}
    end

    {posted_before, _} = stable.({:posting_seq, 3})
    {event_before, r_event} = stable.({:event_time, t, 3})
    assert qty(r_event) == %{"a" => "7.000000000", "b" => "3.000000000"}

    receipt!(s, ["a", "l"], 1)
    receipt!(s, ["c", "l"], 4)
    receipt!(s, ["b", "l"], 1)
    late!(s, ["b", "l"], 10, 7, 2)

    {posted_after, _} = stable.({:posting_seq, 3})
    {event_after, _} = stable.({:event_time, t, 3})
    assert posted_after == posted_before
    assert event_after == event_before

    assert {:ok, r7} = Ledger.balances(a, {:event_time, t, 7}, %{}, %{})
    assert qty(r7) == %{"a" => "7.000000000", "b" => "13.000000000"}
    assert r7.as_of == t and r7.ledger_seq == 7
    assert r7.basis == %{type: "event_time", t: t, n: 7}
  end

  test "T-CO-5 filters: one value per slot name, a closed key set, zero queries when refused", %{
    schema: s,
    auth: a
  } do
    receipt!(s, ["a", "l1"], 5)
    receipt!(s, ["b", "l1"], 3)
    receipt!(s, ["a", "l2"], 2)

    assert {:ok, r} = Ledger.balances(a, {:posting_seq, :latest}, %{"k_primary" => "a"}, %{})
    assert Enum.map(r.rows, & &1.k) |> Enum.map(&Enum.take(&1, 2)) == [["a", "l1"], ["a", "l2"]]
    assert r.filters == %{"k_primary" => "a"}

    assert {:ok, r2} =
             Ledger.balances(a, {:posting_seq, :latest}, %{k_primary: "a", k_second: "l2"}, %{})

    assert qty(r2) == %{"a" => "2.000000000"}

    assert {:ok, none} = Ledger.balances(a, {:posting_seq, :latest}, %{"k_primary" => "zz"}, %{})
    assert none.rows == []

    bad = [
      %{"nope" => "x"},
      %{"k_other_registration" => "x"},
      %{"k_primary" => 1},
      %{"k_primary" => nil},
      %{"k_primary" => String.duplicate("x", 201)},
      %{"prefix" => "tenant_x"},
      %{"tenant_id" => "x"},
      %{"ledger_id" => "other"},
      %{1 => "x"},
      "not a map"
    ]

    {results, statements} =
      Fx.record(fn -> for f <- bad, do: Ledger.balances(a, {:posting_seq, :latest}, f, %{}) end)

    assert Enum.all?(results, &(&1 == {:error, :invalid_filter}))
    assert statements == []
  end

  test "T-CO-6 paging: every key once, one cutoff, a posting lands between pages", %{
    schema: s,
    auth: a
  } do
    for k <- ~w(a b c d e), do: receipt!(s, [k, "l"], 1)

    assert Ledger.page_cap() == 200
    assert {:ok, big} = Ledger.balances(a, {:posting_seq, :latest}, %{}, %{limit: 1_000_000})
    assert length(big.rows) == 5

    for page <- [
          %{limit: 0},
          %{limit: -1},
          %{limit: "2"},
          %{limit: 2.0},
          %{cursor: "garbage"},
          %{x: 1},
          nil
        ] do
      assert {:error, :invalid_filter} = Ledger.balances(a, {:posting_seq, :latest}, %{}, page)
    end

    {:ok, first} = Ledger.balances(a, {:posting_seq, :latest}, %{}, %{limit: 2})
    assert length(first.rows) == 2 and first.next_cursor
    receipt!(s, ["bb", "l"], 1)
    receipt!(s, ["a", "l"], 1)

    {pages, _} =
      Stream.unfold(first, fn
        nil ->
          nil

        report ->
          next =
            case report.next_cursor do
              nil ->
                nil

              c ->
                elem(Ledger.balances(a, {:posting_seq, :latest}, %{}, %{limit: 2, cursor: c}), 1)
            end

          {report, next}
      end)
      |> Enum.to_list()
      |> then(&{&1, nil})

    assert length(pages) == 3
    assert pages |> Enum.map(& &1.cutoff_seq) |> Enum.uniq() == [5]
    keys = pages |> Enum.flat_map(& &1.rows) |> Enum.map(&hd(&1.k))
    assert keys == ~w(a b c d e)

    assert pages |> Enum.flat_map(& &1.rows) |> Enum.map(& &1.quantity) |> Enum.uniq() ==
             ["1.000000000"]
  end

  test "T-CO-7 one statement per page; a poster running alongside never tears a report", %{
    schema: s,
    auth: a
  } do
    receipt!(s, ["a", "l"], 1)

    {{:ok, _}, statements} =
      Fx.record(fn -> Ledger.balances(a, {:posting_seq, :latest}, %{}, %{}) end)

    assert Enum.count(statements, fn {sql, _} -> sql =~ "ledger_" end) == 1

    poster =
      Task.async(fn ->
        for i <- 1..30, do: receipt!(s, [Enum.at(["a", "b"], rem(i, 2)), "l"], 1)
      end)

    reports =
      for _ <- 1..20 do
        {:ok, r} = Ledger.balances(a, {:posting_seq, :latest}, %{}, %{})
        r
      end

    Task.await(poster, 120_000)

    for r <- reports do
      total =
        r.rows
        |> Enum.map(&Decimal.new(&1.quantity))
        |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

      assert Decimal.equal?(total, r.cutoff_seq)
      assert r.ledger_seq == r.cutoff_seq
    end

    assert Repo.aggregate(from_ledger_entries(), :count, prefix: s) == 31
  end

  defp from_ledger_entries, do: "ledger_entry"
end
