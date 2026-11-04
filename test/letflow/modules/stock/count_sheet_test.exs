Code.require_file("stock_fixture.exs", __DIR__)
Code.require_file("counts_fixture.exs", __DIR__)
Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.CountSheetTest do
  @moduledoc """
  REQ-701 / GH #3736 criteria 2 to 7 (O1..O7, B1..B3, T1..T5, S1..S8, E1..E4, C1..C7):
  `Letflow.Modules.Stock.CountSheet` (through the `Counts` delegates) on a committed fresh tenant with
  org, locations, catalog_items and stock installed and real ledger postings (`Letflow.StockFixture`).
  `async: false`, Sandbox `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.CountsFixture, as: F
  alias Letflow.Entities.Record.Latest
  alias Letflow.Ledger
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.Modules.Stock.Counts
  alias Letflow.StockFixture, as: S

  setup do
    ctx = S.setup_oidc!([:a])
    t = S.tenant!("cnt", ctx.names.a)
    s = t.schema_name
    w = F.world!(s)
    fx = %{tenant_id: t.tenant_id, schema_name: s}

    chair_user = Fx.user!(fx, ["TENANT_ADMIN"])
    member_user = Fx.user!(fx, ["TENANT_ADMIN"])
    chair = F.employee!(s, w.unit, user: chair_user.id)
    member = F.employee!(s, w.unit, user: member_user.id)
    outsider_user = Fx.user!(fx, ["TENANT_ADMIN"])
    _outsider = F.employee!(s, w.unit, user: outsider_user.id)

    w = %{w | chair: chair, members: [member], chair_user: chair_user.id}

    {:ok,
     %{
       fx: fx,
       s: s,
       w: w,
       chair_user: chair_user,
       member_user: member_user,
       outsider_user: outsider_user
     }}
  end

  # --- helpers ----------------------------------------------------------------------------------

  defp authorized!(fx, user) do
    {:ok, auth} = Ledger.authorize(Fx.conn_for(fx, user, ["TENANT_ADMIN"]), "stock", :read)
    auth
  end

  defp opts(user, extra \\ %{}), do: Map.merge(%{actor_id: user.id, scope: :all}, extra)

  defp window(extra \\ %{}) do
    now = DateTime.utc_now()

    Map.merge(
      %{
        "planned_start" => DateTime.to_iso8601(DateTime.add(now, -3600)),
        "planned_end" => DateTime.to_iso8601(DateTime.add(now, 20 * 3600))
      },
      extra
    )
  end

  # An `ordered` count of the world's unit with the roots `[w.a]` and a window around now.
  defp ordered!(c, extra \\ %{}) do
    {:ok, v} = Counts.create(c.s, F.input(c.w, window(extra)), opts(c.chair_user))
    {:ok, i} = Counts.issue(c.s, v["id"], opts(c.chair_user))
    assert i["status"] == "ordered"
    i["id"]
  end

  defp open!(c, id) do
    auth = authorized!(c.fx, c.chair_user)
    {:ok, v} = Counts.open(c.s, id, opts(c.chair_user, %{authorized: auth}))
    v
  end

  defp lines!(c, id, params \\ %{}) do
    {:ok, page} = Counts.lines(c.s, id, params, opts(c.chair_user))
    page
  end

  defp all_lines(c, id), do: lines!(c, id, %{"limit" => 200}).rows

  defp receipt!(c, sku, qty, loc),
    do:
      S.post!(c.s, "receipt", %{
        lines: [S.line(sku, qty, %{to: S.side(c.w.unit, loc)})]
      })

  defp live(s, type),
    do:
      Repo.aggregate(from(l in Latest, where: l.entity_type == ^type and not l.deleted), :count,
        prefix: s
      )

  defp audits(s, action), do: Repo.all(from(e in Entry, where: e.action == ^action), prefix: s)

  defp status(c, id) do
    {:ok, v} = Counts.get(c.s, id, opts(c.chair_user))
    v["status"]
  end

  # sku1 10 at a, sku2 4 at a1, sku1 7 at a11 (a lot-less key each); sku3 3 at b (outside), a key
  # in another unit, and a key that went back to zero.
  defp seed!(c) do
    {sku1, sku2, sku3, sku4} = {S.uuid(), S.uuid(), S.uuid(), S.uuid()}
    receipt!(c, sku1, "10", c.w.a)
    receipt!(c, sku2, "4", c.w.a1)
    receipt!(c, sku1, "7", c.w.a11)
    receipt!(c, sku3, "3", c.w.b)

    S.post!(c.s, "receipt", %{
      lines: [S.line(sku4, "5", %{to: S.side(Ecto.UUID.generate(), c.w.a)})]
    })

    receipt!(c, sku4, "3", c.w.a)

    S.post!(c.s, "transfer", %{
      lines: [S.line(sku4, "3", %{from: S.side(c.w.unit, c.w.a), to: S.side(c.w.unit, c.w.b)})]
    })

    %{sku1: sku1, sku2: sku2, sku3: sku3, sku4: sku4}
  end

  defp counted_sheet!(c, id) do
    for l <- all_lines(c, id) do
      {:ok, _} = Counts.record_count(c.s, id, l["line_no"], "1", opts(c.chair_user))
    end

    :ok
  end

  # --- open (criteria 2, 3) ---------------------------------------------------------------------

  describe "open" do
    test "O1 B1 the happy path: cut-off, book quantities of the unit inside the subtree", c do
      k = seed!(c)
      id = ordered!(c)
      v = open!(c, id)

      assert v["status"] == "counting" and is_binary(v["cut_off_at"])
      assert is_integer(v["cutoff_seq"]) and v["cutoff_seq"] >= 6

      rows = all_lines(c, id)
      assert Enum.map(rows, & &1["line_no"]) == Enum.to_list(1..length(rows)//1)
      assert Enum.all?(rows, &(&1["kind"] == "stock" and &1["counted_quantity"] == nil))

      keys =
        for r <- rows,
            do: {r["catalog_item_id"], r["location_id"], Decimal.new(r["book_quantity"])}

      assert Enum.sort(keys) ==
               Enum.sort([
                 {k.sku1, c.w.a, Decimal.new("10.000000000")},
                 {k.sku2, c.w.a1, Decimal.new("4.000000000")},
                 {k.sku1, c.w.a11, Decimal.new("7.000000000")}
               ])

      assert Enum.all?(rows, &(&1["unit_ref"] == "pcs"))
      sorted = Enum.sort_by(rows, &{&1["location_id"], &1["catalog_item_id"]})
      assert Enum.map(sorted, & &1["line_no"]) == Enum.to_list(1..3)
      assert [_] = audits(c.s, "stock.count.opened")
    end

    test "O2 O3 O4 refusals: not chair, not due, wrong state, no ledger for a scoped caller", c do
      id = ordered!(c)
      auth = authorized!(c.fx, c.member_user)
      assert {:error, :not_chair} = Counts.open(c.s, id, opts(c.member_user, %{authorized: auth}))

      auth = authorized!(c.fx, c.chair_user)
      ok = opts(c.chair_user, %{authorized: auth})
      assert {:error, :not_found} = Counts.open(c.s, id, opts(c.chair_user))

      assert {:error, :not_found} =
               Counts.open(c.s, id, %{ok | authorized: %{auth | scope: {:nodes, [c.w.unit]}}})

      assert {:error, :not_found} =
               Counts.open(c.s, id, %{ok | authorized: %{auth | prefix: "other"}})

      assert {:error, :not_found} = Counts.open(c.s, Ecto.UUID.generate(), ok)

      {:ok, d} = Counts.create(c.s, F.input(c.w, window()), opts(c.chair_user))
      assert {:error, :count_state_invalid} = Counts.open(c.s, d["id"], ok)

      past = %{"planned_start" => "2026-01-01T09:00:00Z", "planned_end" => "2026-01-02T09:00:00Z"}

      future = %{
        "planned_start" => "2099-01-01T09:00:00Z",
        "planned_end" => "2099-01-02T09:00:00Z"
      }

      for extra <- [past, future] do
        {:ok, v} =
          Counts.create(
            c.s,
            F.input(c.w, Map.put(extra, "location_ids", [c.w.b])),
            opts(c.chair_user)
          )

        {:ok, _} = Counts.issue(c.s, v["id"], opts(c.chair_user))
        assert {:error, :count_not_due} = Counts.open(c.s, v["id"], ok)
        assert status(c, v["id"]) == "ordered"
        {:ok, _} = Counts.cancel(c.s, v["id"], opts(c.chair_user))
      end

      assert {:ok, _} = Counts.open(c.s, id, ok)
      assert {:error, :count_state_invalid} = Counts.open(c.s, id, ok)
      assert live(c.s, "count_sheet_line") == 0
    end

    test "O5 two concurrent opens: exactly one set of lines and one winner", c do
      seed!(c)
      id = ordered!(c)
      auth = authorized!(c.fx, c.chair_user)

      results =
        for _ <- 1..2 do
          Task.async(fn -> Counts.open(c.s, id, opts(c.chair_user, %{authorized: auth})) end)
        end
        |> Task.await_many(60_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :count_state_invalid})) == 1
      assert live(c.s, "count_sheet_line") == 3
    end

    test "O6 count_too_large with the cap lowered, nothing stored", c do
      seed!(c)
      id = ordered!(c)
      Application.put_env(:letflow, :stock_count_max_lines, 2)
      on_exit(fn -> Application.delete_env(:letflow, :stock_count_max_lines) end)
      auth = authorized!(c.fx, c.chair_user)

      assert {:error, :count_too_large} =
               Counts.open(c.s, id, opts(c.chair_user, %{authorized: auth}))

      assert status(c, id) == "ordered" and live(c.s, "count_sheet_line") == 0
    end

    test "O7 a ledger refusal is ledger_read_failed and stores nothing", c do
      id = ordered!(c)
      auth = authorized!(c.fx, c.chair_user)
      bad = %{auth | slot_names: ["sku"]}

      assert {:error, :ledger_read_failed} =
               Counts.open(c.s, id, opts(c.chair_user, %{authorized: bad}))

      assert status(c, id) == "ordered" and live(c.s, "count_sheet_line") == 0
      assert audits(c.s, "stock.count.opened") == []
    end

    test "B2 a later posting does not change the sheet and the stored basis reproduces it", c do
      k = seed!(c)
      id = ordered!(c)
      v = open!(c, id)
      before = all_lines(c, id)
      receipt!(c, k.sku2, "100", c.w.a1)
      assert all_lines(c, id) == before

      {:ok, at, _} = DateTime.from_iso8601(v["cut_off_at"])
      auth = authorized!(c.fx, c.chair_user)

      {:ok, report} =
        Ledger.balances(auth, {:event_time, at, v["cutoff_seq"]}, %{"org_unit" => c.w.unit}, %{
          limit: 200
        })

      from_ledger =
        for r <- report.rows,
            Decimal.compare(Decimal.new(r.quantity), 0) != :eq,
            [_sku, loc | _] = r.k,
            loc in [c.w.a, c.w.a1, c.w.a11],
            do: {hd(r.k), loc, Decimal.new(r.quantity)}

      lines =
        for l <- before,
            do: {l["catalog_item_id"], l["location_id"], Decimal.new(l["book_quantity"])}

      assert Enum.sort(from_ledger) == Enum.sort(lines)
    end

    test "B3 more keys than one ledger page (200) in one location: one line each", c do
      id = ordered!(c)
      skus = for _ <- 1..205, do: S.uuid()

      for chunk <- Enum.chunk_every(skus, 50) do
        S.post!(c.s, "receipt", %{
          lines: Enum.map(chunk, &S.line(&1, "1", %{to: S.side(c.w.unit, c.w.a)}))
        })
      end

      open!(c, id)
      {:ok, p1} = Counts.lines(c.s, id, %{"limit" => 200}, opts(c.chair_user))
      cursor = p1.next_cursor
      {:ok, p2} = Counts.lines(c.s, id, %{"limit" => 200, "cursor" => cursor}, opts(c.chair_user))
      assert length(p1.rows) == 200 and length(p2.rows) == 5 and p2.next_cursor == nil
      rows = p1.rows ++ p2.rows
      assert length(Enum.uniq_by(rows, & &1["catalog_item_id"])) == 205
    end
  end

  test "the module's balance page size is the ledger page cap" do
    assert Ledger.page_cap() == 200
    assert File.read!("lib/letflow/modules/stock/count_sheet.ex") =~ "@balance_page 200"
  end

  # --- typed input (criterion 4) ----------------------------------------------------------------

  describe "record_count" do
    setup c do
      k = seed!(c)
      id = ordered!(c)
      open!(c, id)
      {:ok, %{id: id, k: k}}
    end

    test "T1 replace semantics: 5 then 3 gives one line value and two entries", c do
      assert {:ok, l} = Counts.record_count(c.s, c.id, 1, "5", opts(c.chair_user))
      assert l["counted_quantity"] == "5.000000000" and l["line_no"] == 1
      assert {:ok, l} = Counts.record_count(c.s, c.id, "1", "3.5", opts(c.chair_user))
      assert l["counted_quantity"] == "3.500000000"
      assert hd(all_lines(c, c.id))["counted_quantity"] == "3.500000000"

      {:ok, %{rows: [e1, e2]}} = Counts.entries(c.s, c.id, %{}, opts(c.chair_user))

      assert {e1["entry_no"], e1["quantity_before"], e1["quantity_after"]} ==
               {1, nil, "5.000000000"}

      assert {e2["entry_no"], e2["quantity_before"], e2["quantity_after"]} ==
               {2, "5.000000000", "3.500000000"}
    end

    test "T2 only the commission counts", c do
      assert {:ok, _} = Counts.record_count(c.s, c.id, 1, "1", opts(c.member_user))
      assert {:ok, _} = Counts.record_count(c.s, c.id, 2, "1", opts(c.chair_user))

      assert {:error, :not_commission_member} =
               Counts.record_count(c.s, c.id, 1, "9", opts(c.outsider_user))

      nobody = %{actor_id: Ecto.UUID.generate(), scope: :all}
      assert {:error, :not_commission_member} = Counts.record_count(c.s, c.id, 1, "9", nobody)
    end

    test "T3 a count that is not counting refuses", c do
      {:ok, d} = Counts.create(c.s, F.input(c.w, window()), opts(c.chair_user))

      assert {:error, :count_state_invalid} =
               Counts.record_count(c.s, d["id"], 1, "1", opts(c.chair_user))

      ordered = ordered!(c, %{"location_ids" => [c.w.b]})

      assert {:error, :count_state_invalid} =
               Counts.record_count(c.s, ordered, 1, "1", opts(c.chair_user))
    end

    test "T4 the quantity must be a decimal string, zero is fine", c do
      for bad <- ["-1", "1e3", "1.0000000001", "abc", 5, "", nil, "01", "1,5"] do
        assert {:error, {:field_invalid, "counted_quantity"}} =
                 Counts.record_count(c.s, c.id, 1, bad, opts(c.chair_user)),
               inspect(bad)
      end

      assert {:ok, %{"counted_quantity" => "0.000000000"}} =
               Counts.record_count(c.s, c.id, 1, "0", opts(c.chair_user))

      assert {:ok, %{"counted_quantity" => "0.000000001"}} =
               Counts.record_count(c.s, c.id, 1, "0.000000001", opts(c.chair_user))

      assert live(c.s, "count_entry") == 2
    end

    test "T5 a line that is not on the sheet", c do
      for bad <- [99, 0, -1, "x", "01", "1.5", nil] do
        assert {:error, :line_not_found} =
                 Counts.record_count(c.s, c.id, bad, "1", opts(c.chair_user)),
               inspect(bad)
      end
    end
  end

  # --- surplus lines (criterion 5) --------------------------------------------------------------

  describe "add_surplus_line" do
    setup c do
      seed!(c)
      m = Letflow.StockDocsFixture.masters!(c.s)
      receipt!(c, m.item, "3", c.w.a)
      id = ordered!(c)
      open!(c, id)

      input = %{
        "location_id" => c.w.a1,
        "catalog_item_id" => m.item,
        "unit_ref" => m.uom,
        "counted_quantity" => "2"
      }

      {:ok, %{id: id, m: m, input: input}}
    end

    defp add(c, input, user \\ nil),
      do: Counts.add_surplus_line(c.s, c.id, input, opts(user || c.member_user))

    test "S1 a surplus line: kind surplus, book 0, one entry", c do
      before = length(all_lines(c, c.id))
      assert {:ok, l} = add(c, c.input)
      assert l["kind"] == "surplus" and l["book_quantity"] == "0.000000000"
      assert l["counted_quantity"] == "2.000000000"
      assert l["line_no"] == before + 1
      assert List.last(all_lines(c, c.id)) == l
      {:ok, %{rows: [e]}} = Counts.entries(c.s, c.id, %{}, opts(c.chair_user))

      assert e["line_no"] == l["line_no"] and e["quantity_before"] == nil and
               e["quantity_after"] == "2.000000000"

      assert [_] = audits(c.s, "stock.count.surplus_added")

      lot =
        Map.merge(c.input, %{
          "catalog_item_id" => c.input["catalog_item_id"],
          "catalog_lot_id" => c.m.lot,
          "responsible_employee_id" => c.w.chair
        })

      assert {:ok, %{"catalog_lot_id" => lot_id}} = add(c, lot)
      assert lot_id == c.m.lot
    end

    test "S2 S3 S4 S5 S6 S7 one refusal each, nothing stored", c do
      n = live(c.s, "count_sheet_line")
      bad = fn changes -> add(c, Map.merge(c.input, changes)) end

      other_loc =
        Letflow.LocationsFixture.node!(c.s, "X#{System.unique_integer([:positive])}").record_id

      assert {:error, :location_not_in_count} = bad.(%{"location_id" => c.w.b})
      assert {:error, :location_not_in_count} = bad.(%{"location_id" => other_loc})
      assert {:error, :location_not_in_count} = bad.(%{"location_id" => Ecto.UUID.generate()})
      assert {:error, :item_inactive} = bad.(%{"catalog_item_id" => Ecto.UUID.generate()})
      assert {:error, :unit_invalid} = bad.(%{"unit_ref" => Ecto.UUID.generate()})
      assert {:error, :lot_invalid} = bad.(%{"catalog_lot_id" => Ecto.UUID.generate()})

      assert {:error, :employee_inactive} =
               bad.(%{"responsible_employee_id" => Ecto.UUID.generate()})

      assert live(c.s, "count_sheet_line") == n and live(c.s, "count_entry") == 0
    end

    test "S7 count_line_exists against a stock line and a surplus line", c do
      first = Enum.find(all_lines(c, c.id), &(&1["catalog_item_id"] == c.m.item))

      stock_dup = %{
        "location_id" => first["location_id"],
        "catalog_item_id" => first["catalog_item_id"],
        "unit_ref" => c.m.uom,
        "counted_quantity" => "1"
      }

      assert {:error, :count_line_exists} = add(c, stock_dup)
      assert {:ok, _} = add(c, c.input)
      assert {:error, :count_line_exists} = add(c, c.input)
    end

    test "S8 caller, state, quantity and keys", c do
      assert {:error, :not_commission_member} = add(c, c.input, c.outsider_user)

      assert {:error, {:field_invalid, "counted_quantity"}} =
               add(c, %{c.input | "counted_quantity" => "0"})

      assert {:error, {:field_invalid, "location_id"}} = add(c, %{c.input | "location_id" => "x"})

      assert {:error, {:field_invalid, "catalog_item_id"}} =
               add(c, Map.delete(c.input, "catalog_item_id"))

      assert {:error, {:field_not_allowed, "bogus"}} = add(c, Map.put(c.input, "bogus", 1))
      assert {:error, {:field_invalid, "body"}} = add(c, "x")
      ordered = ordered!(c, %{"location_ids" => [c.w.b]})

      assert {:error, :count_state_invalid} =
               Counts.add_surplus_line(c.s, ordered, c.input, opts(c.member_user))
    end
  end

  # --- log and audit (criterion 6) --------------------------------------------------------------

  describe "entry log and audit" do
    test "E1 E3 E4 entries in order with who and when; audit has ids and status only", c do
      seed!(c)
      m = Letflow.StockDocsFixture.masters!(c.s)
      receipt!(c, m.item, "3", c.w.a)
      id = ordered!(c)
      open!(c, id)

      {:ok, _} = Counts.record_count(c.s, id, 1, "4", opts(c.member_user))
      {:ok, _} = Counts.record_count(c.s, id, 2, "5", opts(c.chair_user))
      {:ok, _} = Counts.record_count(c.s, id, 1, "6", opts(c.member_user))

      {:ok, _} =
        Counts.add_surplus_line(
          c.s,
          id,
          %{
            "location_id" => c.w.a1,
            "catalog_item_id" => m.item,
            "unit_ref" => m.uom,
            "counted_quantity" => "1"
          },
          opts(c.member_user)
        )

      {:ok, %{rows: rows, next_cursor: nil}} = Counts.entries(c.s, id, %{}, opts(c.chair_user))
      assert Enum.map(rows, & &1["entry_no"]) == [1, 2, 3, 4]

      assert Enum.map(rows, & &1["entered_by"]) ==
               Enum.map([c.member_user, c.chair_user, c.member_user, c.member_user], & &1.id)

      assert Enum.all?(
               rows,
               &(is_binary(&1["entered_at"]) and is_binary(&1["entered_by_employee_id"]) and
                   &1["method"] == "typed")
             )

      assert Enum.map(rows, & &1["entered_at"]) == Enum.sort(Enum.map(rows, & &1["entered_at"]))

      {:ok, %{rows: [_, _], next_cursor: cur}} =
        Counts.entries(c.s, id, %{"limit" => "2"}, opts(c.chair_user))

      assert cur == "2"

      assert {:error, {:field_invalid, "limit"}} =
               Counts.entries(c.s, id, %{"limit" => "0"}, opts(c.chair_user))

      assert {:error, {:field_invalid, "cursor"}} =
               Counts.lines(c.s, id, %{"cursor" => "-1"}, opts(c.chair_user))

      assert {:error, {:field_not_allowed, "x"}} =
               Counts.lines(c.s, id, %{"x" => "1"}, opts(c.chair_user))

      assert [_, _, _] = audits(c.s, "stock.count.line_counted")
      assert [e] = audits(c.s, "stock.count.opened")
      assert e.resource_id == id and e.after_state == %{"status" => "counting"}

      for a <- audits(c.s, "stock.count.line_counted") do
        assert Map.keys(a.after_state) |> Enum.sort() == ["line_no", "status"]
      end

      n = Repo.aggregate(Entry, :count, prefix: c.s)
      assert {:error, :line_not_found} = Counts.record_count(c.s, id, 99, "1", opts(c.chair_user))

      assert {:error, :not_commission_member} =
               Counts.record_count(c.s, id, 1, "1", opts(c.outsider_user))

      assert Repo.aggregate(Entry, :count, prefix: c.s) == n
    end

    test "E2 no function updates or deletes a count entry" do
      for file <- Path.wildcard("lib/letflow/modules/stock/*.ex") do
        src = File.read!(file)

        refute src =~ ~r/update_record\([^)]*"count_entry"/,
               "#{file} updates a count_entry"

        refute src =~ ~r/delete_record[^\n]*count_entry/, "#{file} deletes a count_entry"
      end

      src = File.read!("lib/letflow/modules/stock/count_sheet.ex")
      uses = Regex.scan(~r/update_record\(\s*prefix,[^\n]*\n?[^\n]*"(\w+)"/, src)
      refute Enum.any?(uses, fn [_, t] -> t == "count_entry" end)
      refute src =~ "delete_record"
    end

    test "E5 a failing audit store rolls a count back", c do
      seed!(c)
      id = ordered!(c)
      open!(c, id)
      Repo.query!(~s|DROP TABLE "#{c.s}".audit_entries CASCADE|)
      assert {:error, :audit_failed} = Counts.record_count(c.s, id, 1, "1", opts(c.chair_user))
      assert live(c.s, "count_entry") == 0
      assert hd(all_lines(c, id))["counted_quantity"] == nil
    end
  end

  # --- close (criterion 7) ----------------------------------------------------------------------

  describe "close_counting" do
    setup c do
      seed!(c)
      id = ordered!(c)
      open!(c, id)
      {:ok, %{id: id}}
    end

    defp numbers(c), do: Repo.query!(~s|SELECT count(*) FROM "#{c.s}".document_sequences|).rows

    test "C1 C4 close issues the count.sheet and freezes the sheet", c do
      counted_sheet!(c, c.id)
      assert {:ok, v} = Counts.close_counting(c.s, c.id, opts(c.chair_user))
      assert v["status"] == "counted" and is_binary(v["sheet_document_id"])

      assert {:ok, d} = Counts.sheet_document(c.s, c.id, opts(c.chair_user))
      assert d.number_label =~ ~r/\ACS-\d{4}-0001\z/ and d.version_no == 1

      assert Map.keys(d) |> Enum.sort() == [
               :content_hash,
               :document_id,
               :issued_at,
               :number_label,
               :version_no
             ]

      content =
        Repo.one(
          from(dv in Letflow.Documents.DocumentVersion,
            where: dv.document_id == ^d.document_id,
            select: dv.content
          ),
          prefix: c.s
        )

      parsed = content
      assert parsed["cutoff_seq"] == v["cutoff_seq"] and parsed["cut_off_at"] == v["cut_off_at"]
      assert length(parsed["lines"]) == 3

      assert Enum.all?(
               parsed["lines"],
               &(&1["counted_quantity"] == "1.000000000" and is_binary(&1["book_quantity"]))
             )

      assert [_] = audits(c.s, "stock.count.closed")

      assert {:error, :count_state_invalid} =
               Counts.record_count(c.s, c.id, 1, "2", opts(c.chair_user))

      assert {:error, :count_state_invalid} = Counts.close_counting(c.s, c.id, opts(c.chair_user))

      assert {:error, :count_state_invalid} =
               Counts.add_surplus_line(
                 c.s,
                 c.id,
                 %{
                   "location_id" => c.w.a1,
                   "catalog_item_id" => S.uuid(),
                   "unit_ref" => S.uuid(),
                   "counted_quantity" => "1"
                 },
                 opts(c.chair_user)
               )
    end

    test "C2 lines_uncounted issues nothing and takes no number", c do
      {:ok, _} = Counts.record_count(c.s, c.id, 1, "1", opts(c.chair_user))
      before = numbers(c)
      assert {:error, :lines_uncounted} = Counts.close_counting(c.s, c.id, opts(c.chair_user))
      assert status(c, c.id) == "counting" and numbers(c) == before

      assert Repo.query!(
               ~s|SELECT count(*) FROM "#{c.s}".documents WHERE type_key = 'count.sheet'|
             ).rows == [[0]]

      assert {:error, :not_found} = Counts.sheet_document(c.s, c.id, opts(c.chair_user))
    end

    test "C3 only the chair closes", c do
      counted_sheet!(c, c.id)
      assert {:error, :not_chair} = Counts.close_counting(c.s, c.id, opts(c.member_user))
      assert status(c, c.id) == "counting"
    end

    test "C5 a counted order can still be cancelled and the sheet stays", c do
      counted_sheet!(c, c.id)
      {:ok, v} = Counts.close_counting(c.s, c.id, opts(c.chair_user))
      {:ok, d} = Counts.sheet_document(c.s, c.id, opts(c.chair_user))
      assert {:ok, %{"status" => "cancelled"}} = Counts.cancel(c.s, c.id, opts(c.chair_user))
      assert {:ok, d2} = Counts.sheet_document(c.s, c.id, opts(c.chair_user))
      assert d2.content_hash == d.content_hash and v["sheet_document_id"] == d.document_id
    end

    test "C6 a failed document issue leaves the order counting", c do
      counted_sheet!(c, c.id)
      Repo.query!(~s|ALTER TABLE "#{c.s}".document_types DISABLE TRIGGER ALL|)
      Repo.query!(~s|DELETE FROM "#{c.s}".document_types WHERE key = 'count.sheet'|)
      assert {:error, {:document, _}} = Counts.close_counting(c.s, c.id, opts(c.chair_user))
      assert status(c, c.id) == "counting"
    end

    test "C7 a cancel racing a typed entry never loses the cancel", c do
      tasks = [
        Task.async(fn -> Counts.cancel(c.s, c.id, opts(c.chair_user)) end),
        Task.async(fn -> Counts.record_count(c.s, c.id, 1, "3", opts(c.chair_user)) end)
      ]

      [cancel, count] = Task.await_many(tasks, 60_000)
      assert {:ok, %{"status" => "cancelled"}} = cancel
      assert match?({:ok, _}, count) or count == {:error, :count_state_invalid}
      assert status(c, c.id) == "cancelled"
    end
  end
end
