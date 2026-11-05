Code.require_file("stock_fixture.exs", __DIR__)
Code.require_file("counts_fixture.exs", __DIR__)
Code.require_file("documents_fixture.exs", __DIR__)
Code.require_file("../codes/codes_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.CountScanTest do
  @moduledoc """
  REQ-716 / GH #3765 criteria 2 to 6 (C2a..C6): `Counts.scan/4` on a committed fresh tenant with org,
  locations, catalog_items, stock and codes installed. `async: false`, Sandbox `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.CodesFixture, as: K
  alias Letflow.CountsFixture, as: F
  alias Letflow.Entities.Record.Latest
  alias Letflow.Ledger
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.Modules.Stock.Counts
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S

  setup do
    ctx = S.setup_oidc!([:a])
    t = S.tenant!("scan", ctx.names.a)
    s = t.schema_name
    w = F.world!(s)
    fx = %{tenant_id: t.tenant_id, schema_name: s}

    chair_user = Fx.user!(fx, ["TENANT_ADMIN"])
    member_user = Fx.user!(fx, ["TENANT_ADMIN"])
    outsider_user = Fx.user!(fx, ["TENANT_ADMIN"])
    chair = F.employee!(s, w.unit, user: chair_user.id)
    member = F.employee!(s, w.unit, user: member_user.id)
    _ = F.employee!(s, w.unit, user: outsider_user.id)
    w = %{w | chair: chair, members: [member], chair_user: chair_user.id}

    m = D.masters!(s)
    S.post!(s, "receipt", %{lines: [S.line(m.item, "3", %{to: S.side(w.unit, w.a)})]})

    {:ok, order} = Counts.create(s, F.input(w, window()), opts(chair_user))
    {:ok, _} = Counts.issue(s, order["id"], opts(chair_user))
    {:ok, auth} = Ledger.authorize(Fx.conn_for(fx, chair_user, ["TENANT_ADMIN"]), "stock", :read)
    {:ok, _} = Counts.open(s, order["id"], opts(chair_user, %{authorized: auth}))

    # one lot line at a1 (surplus) so a lot code has a line
    {:ok, _} =
      Counts.add_surplus_line(
        s,
        order["id"],
        %{
          "location_id" => w.a1,
          "catalog_item_id" => m.lot_item,
          "catalog_lot_id" => m.lot,
          "responsible_employee_id" => chair,
          "unit_ref" => m.uom,
          "counted_quantity" => "1"
        },
        opts(member_user)
      )

    {:ok,
     %{
       fx: fx,
       s: s,
       w: w,
       m: m,
       id: order["id"],
       chair_user: chair_user,
       member_user: member_user,
       outsider_user: outsider_user,
       t: t
     }}
  end

  # --- helpers ----------------------------------------------------------------------------------

  defp window do
    now = DateTime.utc_now()

    %{
      "planned_start" => DateTime.to_iso8601(DateTime.add(now, -3600)),
      "planned_end" => DateTime.to_iso8601(DateTime.add(now, 20 * 3600))
    }
  end

  defp opts(user, extra \\ %{}), do: Map.merge(%{actor_id: user.id, scope: :all}, extra)

  defp code!(c, type, target) do
    value = "C-#{System.unique_integer([:positive])}"
    tag = K.tag!(c.s, value, %{"status" => "assigned"})
    K.assign!(c.s, tag, type, target)
    value
  end

  defp input(text, c, extra \\ %{}),
    do:
      Map.merge(
        %{"scanned_text" => text, "location_id" => c.w.a, "scan_id" => Ecto.UUID.generate()},
        extra
      )

  defp scan(c, input, user \\ nil), do: Counts.scan(c.s, c.id, input, opts(user || c.member_user))

  defp lines(c) do
    {:ok, page} = Counts.lines(c.s, c.id, %{"limit" => 200}, opts(c.chair_user))
    page.rows
  end

  defp entries(c) do
    {:ok, page} = Counts.entries(c.s, c.id, %{"limit" => 200}, opts(c.chair_user))
    page.rows
  end

  defp audits(s),
    do: Repo.all(from(e in Entry, where: e.action == "stock.count.line_scanned"), prefix: s)

  defp snapshot(c), do: {lines(c), length(entries(c)), length(audits(c.s))}

  defp item_line(c), do: Enum.find(lines(c), &(&1["catalog_item_id"] == c.m.item))

  # --- criterion 2: refusals record nothing -----------------------------------------------------

  describe "refusals" do
    test "C2a unknown text", c do
      before = snapshot(c)
      assert {:error, :code_unknown} = scan(c, input("no-such-code", c))
      assert snapshot(c) == before
    end

    test "C2b retired", c do
      value = "C-#{System.unique_integer([:positive])}"
      K.tag!(c.s, value, %{"status" => "retired"})
      before = snapshot(c)
      assert {:error, :code_retired} = scan(c, input(value, c))
      assert snapshot(c) == before
    end

    test "C2c assignment conflict", c do
      value = "C-#{System.unique_integer([:positive])}"
      K.tag!(c.s, value, %{"status" => "assigned"})
      before = snapshot(c)
      assert {:error, :code_assignment_conflict} = scan(c, input(value, c))
      assert snapshot(c) == before
    end

    test "C2d not assigned", c do
      value = "C-#{System.unique_integer([:positive])}"
      K.tag!(c.s, value)
      before = snapshot(c)
      assert {:error, :code_not_assigned} = scan(c, input(value, c))
      assert snapshot(c) == before
    end

    test "C2e not countable", c do
      value = code!(c, "no_such_type", Ecto.UUID.generate())
      before = snapshot(c)
      assert {:error, :code_not_countable} = scan(c, input(value, c))
      assert snapshot(c) == before
    end

    test "C2f a location outside the count or not linked is unknown", c do
      outside = code!(c, "location_node", c.w.b)
      before = snapshot(c)
      assert {:error, :code_unknown} = scan(c, input(outside, c))

      stray =
        Letflow.LocationsFixture.node!(c.s, "S#{System.unique_integer([:positive])}", "zone")

      stray_code = code!(c, "location_node", stray.record_id)
      assert {:error, :code_unknown} = scan(c, input(stray_code, c))
      assert snapshot(c) == before
    end
  end

  # --- criterion 3: a location scan -------------------------------------------------------------

  test "C3 a location in the count answers the location and records nothing", c do
    value = code!(c, "location_node", c.w.a11)
    before = snapshot(c)
    assert {:ok, %{"kind" => "location", "location_id" => loc}} = scan(c, input(value, c))
    assert loc == c.w.a11
    assert snapshot(c) == before
  end

  # --- criterion 4: item and lot scans ----------------------------------------------------------

  describe "counting" do
    test "C4a item scans add one unit each, one entry each", c do
      value = code!(c, "catalog_item", c.m.item)
      ids = for _ <- 1..3, do: Ecto.UUID.generate()

      for {sid, n} <- Enum.with_index(ids, 1) do
        assert {:ok, %{"duplicate" => false, "counted_quantity" => q}} =
                 scan(c, input(value, c, %{"scan_id" => sid}))

        assert Decimal.equal?(Decimal.new(q), n)
      end

      scans = Enum.filter(entries(c), &(&1["method"] == "scan"))
      assert length(scans) == 3

      assert Enum.map(scans, & &1["quantity_after"])
             |> Enum.map(&Decimal.to_integer(Decimal.new(&1))) == [1, 2, 3]

      assert hd(scans)["quantity_before"] == nil
      assert length(audits(c.s)) == 3
    end

    test "C4b lot scan counts the lot line", c do
      value = code!(c, "catalog_lot", c.m.lot)

      assert {:ok, %{"catalog_lot_id" => lot, "counted_quantity" => q}} =
               scan(c, input(value, c, %{"location_id" => c.w.a1}))

      assert lot == c.m.lot and Decimal.equal?(Decimal.new(q), 2)
    end

    test "C4c no line", c do
      value = code!(c, "catalog_item", Ecto.UUID.generate())
      before = snapshot(c)
      assert {:error, :scan_no_line} = scan(c, input(value, c))
      assert snapshot(c) == before
    end

    test "C4d ambiguous: two lines for the item at the place", c do
      {:ok, _} =
        Counts.add_surplus_line(
          c.s,
          c.id,
          %{
            "location_id" => c.w.a,
            "catalog_item_id" => c.m.item,
            "responsible_employee_id" => c.w.chair,
            "unit_ref" => c.m.uom,
            "counted_quantity" => "1"
          },
          opts(c.member_user)
        )

      value = code!(c, "catalog_item", c.m.item)
      before = snapshot(c)
      assert {:error, :scan_ambiguous} = scan(c, input(value, c))
      assert snapshot(c) == before
    end

    test "C4e the place is not in the count", c do
      value = code!(c, "catalog_item", c.m.item)

      for loc <- [c.w.b, Ecto.UUID.generate()] do
        assert {:error, :location_not_in_count} =
                 scan(c, input(value, c, %{"location_id" => loc}))
      end
    end

    test "C4f only the commission, only while counting", c do
      value = code!(c, "catalog_item", c.m.item)
      assert {:error, :not_commission_member} = scan(c, input(value, c), c.outsider_user)

      assert {:error, :not_found} =
               Counts.scan(c.s, Ecto.UUID.generate(), input(value, c), opts(c.member_user))

      assert {:error, :not_found} =
               Counts.scan(c.s, c.id, input(value, c), %{actor_id: c.member_user.id, scope: :none})

      {:ok, _} = Counts.cancel(c.s, c.id, opts(c.chair_user))
      assert {:error, :count_state_invalid} = scan(c, input(value, c))
    end

    test "C4g input shape", c do
      ok = input("x", c)

      assert {:error, {:field_invalid, "body"}} = scan(c, [1])
      assert {:error, {:field_not_allowed, "extra"}} = scan(c, Map.put(ok, "extra", 1))

      for bad <- [nil, "", 5] do
        assert {:error, {:field_invalid, "scanned_text"}} =
                 scan(c, Map.put(ok, "scanned_text", bad))
      end

      assert {:error, {:field_invalid, "scanned_text"}} = scan(c, Map.delete(ok, "scanned_text"))

      assert {:error, {:field_invalid, "location_id"}} =
               scan(c, Map.put(ok, "location_id", "nope"))

      assert {:error, {:field_invalid, "location_id"}} = scan(c, Map.delete(ok, "location_id"))
      assert {:error, {:field_invalid, "scan_id"}} = scan(c, Map.put(ok, "scan_id", "nope"))
    end

    test "C4h entry fields, and a typed number after scans replaces", c do
      value = code!(c, "catalog_item", c.m.item)
      sid = Ecto.UUID.generate()
      {:ok, _} = scan(c, input(value, c, %{"scan_id" => sid}))
      {:ok, _} = scan(c, input(value, c))
      {:ok, _} = scan(c, input(value, c))

      [e | _] = Enum.filter(entries(c), &(&1["method"] == "scan"))

      stored =
        Repo.one!(
          from(l in Latest,
            where:
              l.entity_type == "count_entry" and
                fragment("?->>'scan_id' = ?", l.field_values, ^sid)
          ),
          prefix: c.s
        )

      fv = stored.field_values

      assert fv["scanned_text"] == value and fv["location_id"] == c.w.a and
               is_binary(fv["code_id"])

      assert fv["entered_by"] == c.member_user.id and
               fv["entered_by_employee_id"] == hd(c.w.members)

      assert is_binary(fv["entered_at"]) and e["method"] == "scan"

      line = item_line(c)
      {:ok, v} = Counts.record_count(c.s, c.id, line["line_no"], "10", opts(c.member_user))
      assert Decimal.equal?(Decimal.new(v["counted_quantity"]), 10)
      assert List.last(entries(c))["method"] == "typed"
    end
  end

  # --- criterion 5: no double counting ----------------------------------------------------------

  describe "duplicates" do
    test "C5a a retry answers the first result and writes nothing", c do
      value = code!(c, "catalog_item", c.m.item)
      sid = Ecto.UUID.generate()
      doc = input(value, c, %{"scan_id" => sid})
      assert {:ok, first} = scan(c, doc)
      {:ok, _} = scan(c, input(value, c))
      before = snapshot(c)

      assert {:ok, again} = scan(c, doc)
      assert again == Map.put(first, "duplicate", true)
      assert snapshot(c) == before
    end

    test "C5b the same scan_id with another text or place is a conflict", c do
      value = code!(c, "catalog_item", c.m.item)
      other = code!(c, "catalog_item", c.m.item)
      sid = Ecto.UUID.generate()
      {:ok, _} = scan(c, input(value, c, %{"scan_id" => sid}))
      before = snapshot(c)

      assert {:error, :scan_id_conflict} = scan(c, input(other, c, %{"scan_id" => sid}))

      assert {:error, :scan_id_conflict} =
               scan(c, input(value, c, %{"scan_id" => sid, "location_id" => c.w.a1}))

      assert snapshot(c) == before
    end

    test "C5c two concurrent scans with one scan_id count once", c do
      value = code!(c, "catalog_item", c.m.item)
      doc = input(value, c)

      results =
        [1, 2]
        |> Enum.map(fn _ -> Task.async(fn -> scan(c, doc) end) end)
        |> Task.await_many(30_000)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert Enum.sort(Enum.map(results, fn {:ok, v} -> v["duplicate"] end)) == [false, true]
      assert length(Enum.filter(entries(c), &(&1["method"] == "scan"))) == 1
      assert Decimal.equal?(Decimal.new(item_line(c)["counted_quantity"]), 1)
    end

    test "C5d two concurrent scans with different scan_ids count twice", c do
      value = code!(c, "catalog_item", c.m.item)

      results =
        [1, 2]
        |> Enum.map(fn _ -> Task.async(fn -> scan(c, input(value, c)) end) end)
        |> Task.await_many(30_000)

      assert Enum.all?(results, &match?({:ok, %{"duplicate" => false}}, &1))
      assert length(Enum.filter(entries(c), &(&1["method"] == "scan"))) == 2
      assert Decimal.equal?(Decimal.new(item_line(c)["counted_quantity"]), 2)
    end
  end

  # --- criterion 6: audit -----------------------------------------------------------------------

  test "C6 one audit row per accepted scan, with ids and status only", c do
    value = code!(c, "catalog_item", c.m.item)
    doc = input(value, c)
    {:ok, _} = scan(c, doc)
    {:ok, _} = scan(c, doc)
    {:error, _} = scan(c, input("nope", c))
    {:ok, _} = scan(c, input(code!(c, "location_node", c.w.a), c))

    assert [entry] = audits(c.s)
    assert entry.resource_id == c.id
    assert Map.keys(entry.after_state) |> Enum.sort() == ["line_no", "status"]
    refute inspect(entry.after_state) =~ value
  end
end
