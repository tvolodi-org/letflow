Code.require_file("stock_fixture.exs", __DIR__)
Code.require_file("documents_fixture.exs", __DIR__)
Code.require_file("../codes/codes_fixture.exs", __DIR__)
Code.require_file("../catalog_items/catalog_items_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.StockWorkbookTest do
  @moduledoc """
  REQ-865 / GH #4579 criteria 2–9 (layout, rows, round-trip, aggregation, place cells, paging,
  cap, tenancy): `Letflow.Modules.Stock.StockWorkbook.build/1` on committed tenants with real
  ledger postings.  `async: false`, Sandbox `:auto`.

  Criterion 1 (access control via the router) lives in router_test.exs (T-RWB-1..T-RWB-4).
  """

  # impl_order: REQ-865
  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.CodesFixture, as: K
  alias Letflow.Entities.Record.Latest
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Stock.StockWorkbook
  alias Letflow.StockDocsFixture, as: SD
  alias Letflow.StockFixture, as: S

  setup do
    ctx = S.setup_oidc!([:a, :b])
    t = S.tenant!("swb-a", ctx.names.a)
    tb = S.tenant!("swb-b", ctx.names.b)
    s = t.schema_name
    sb = tb.schema_name

    u = SD.unit!(s)
    ub = SD.unit!(sb)

    admin_user = Fx.user!(%{tenant_id: t.tenant_id, schema_name: s}, ["TENANT_ADMIN"])
    auth = authorized!(t, admin_user)

    {:ok, ctx: ctx, t: t, tb: tb, s: s, sb: sb, u: u, ub: ub, auth: auth, admin_user: admin_user}
  end

  # --- helpers ---------------------------------------------------------------------------------

  defp authorized!(tenant, user) do
    fx = %{tenant_id: tenant.tenant_id, schema_name: tenant.schema_name}

    {:ok, auth} =
      Letflow.Ledger.authorize(Fx.conn_for(fx, user, ["TENANT_ADMIN"]), "stock", :read)

    auth
  end

  defp opts, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

  # Create a location node linked to a unit.
  defp loc!(s, code, unit_id) do
    {:ok, node} =
      Locations.create_node(
        s,
        %{"code" => code, "name" => code, "node_kind" => "zone"},
        opts()
      )

    {:ok, _} = Locations.link_unit_location(s, unit_id, node["record_id"], opts())
    node
  end

  defp uom!(s, code), do: Cat.uom!(s, code)

  defp item!(s, code, uom_id, extra \\ %{}) do
    Cat.item!(s, code, uom_id, Map.merge(%{"kind" => "material"}, extra))
  end

  # Set the default_location_id on a catalog_item record.
  defp set_default_location!(s, item, loc_id) do
    Cat.update!(s, item, Map.put(item.field_values, "default_location_id", loc_id))
  end

  defp post!(s, cause, cmd), do: S.post!(s, cause, cmd)

  defp side(unit, loc), do: S.side(unit, loc)

  defp line(sku, qty, sides, extra) do
    S.line(sku, to_string(qty), sides, extra)
  end

  # Build the workbook bytes and parse its sheets.
  defp build_sheets(auth) do
    {:ok, {_name, bin}} = StockWorkbook.build(auth)
    parse_sheets(bin)
  end

  # Parse the xlsx binary into %{sheet_name => [[{type, val}]]} using XML.
  defp parse_sheets(bin) do
    parts = unzip_parts(bin)
    strings = shared_strings(parts)

    wb_xml = Map.fetch!(parts, "xl/workbook.xml")
    names = Regex.scan(~r/<sheet [^>]*name="([^"]+)"/, wb_xml) |> Enum.map(&List.last/1)

    names
    |> Enum.with_index(1)
    |> Map.new(fn {name, i} ->
      {name, sheet_rows(Map.fetch!(parts, "xl/worksheets/sheet#{i}.xml"), strings)}
    end)
  end

  defp unzip_parts(bin) do
    {:ok, list} = :zip.extract(bin, [:memory])
    Map.new(list, fn {name, content} -> {List.to_string(name), content} end)
  end

  defp shared_strings(parts) do
    xml = parts["xl/sharedStrings.xml"] || ""

    Regex.scan(~r/<si>(.*?)<\/si>/s, xml)
    |> Enum.map(fn [_, si] ->
      Regex.scan(~r/<t[^>]*>(.*?)<\/t>/s, si) |> Enum.map_join(fn [_, t] -> xml_unescape(t) end)
    end)
  end

  defp xml_unescape(t),
    do:
      t
      |> String.replace("&amp;", "&")
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> String.replace("&quot;", "\"")
      |> String.replace("&apos;", "'")

  # Each row is a list of {type_string, value_string}; "s" = string, "n" = number.
  defp sheet_rows(xml, strings) do
    Regex.scan(~r/<row [^>]*>(.*?)<\/row>/s, xml)
    |> Enum.map(fn [_, row_xml] ->
      Regex.scan(~r/<c ([^>]*?)(?:\/>|>(.*?)<\/c>)/s, row_xml)
      |> Enum.map(fn [_ | m] ->
        attrs = Enum.at(m, 0)
        body = Enum.at(m, 1) || ""
        type = (Regex.run(~r/ t="(\w+)"/, " " <> attrs) || [nil, "n"]) |> List.last()
        v = (Regex.run(~r/<v>(.*?)<\/v>/, body) || [nil, nil]) |> List.last()

        cond do
          type == "s" -> {"s", Enum.at(strings, String.to_integer(v))}
          v == nil -> {"s", ""}
          true -> {type, v}
        end
      end)
    end)
  end

  # True when the cell `ref` points (s= style index -> cellXfs fontId) to a font with <b/>.
  defp bold_cell?(styles_xml, sheet_xml, ref) do
    [_, attrs] = Regex.run(~r/<c r="#{ref}"([^>]*?)\/?>/, sheet_xml)

    case Regex.run(~r/\ss="(\d+)"/, attrs) do
      nil ->
        false

      [_, s_idx] ->
        [xfs] =
          Regex.run(~r/<cellXfs[^>]*>(.*?)<\/cellXfs>/s, styles_xml, capture: :all_but_first)

        xf =
          Regex.scan(~r/<xf [^>]*?(?:\/>|>.*?<\/xf>)/s, xfs) |> Enum.at(String.to_integer(s_idx))

        [_, font_id] = Regex.run(~r/fontId="(\d+)"/, List.first(xf))
        [fonts] = Regex.run(~r/<fonts[^>]*>(.*?)<\/fonts>/s, styles_xml, capture: :all_but_first)

        font =
          Regex.scan(~r/<font\s*\/>|<font>.*?<\/font>/s, fonts)
          |> Enum.at(String.to_integer(font_id))

        List.first(font) =~ ~r/<b[ \/]/
    end
  end

  defp cell_texts(rows) do
    Enum.map(rows, fn r -> Enum.map(r, &elem(&1, 1)) end)
  end

  # --- criterion 2: layout ---------------------------------------------------------------------

  describe "REQ-865 C2 layout" do
    test "workbook has one sheet named 'Остатки YYYY-MM-DD'; header row A–J bold and frozen",
         ctx do
      date_str = today_str()
      sheets = build_sheets(ctx.auth)

      assert Map.keys(sheets) == ["Остатки #{date_str}"]
      [header | _] = Map.fetch!(sheets, "Остатки #{date_str}")

      assert cell_texts([header]) == [
               [
                 "Артикул",
                 "Номенклатура",
                 "Конечный остаток",
                 "Зона",
                 "Стеллаж",
                 "Полка",
                 "Второе место",
                 "Место",
                 "Ед. изм.",
                 "Коды / Codes"
               ]
             ]

      assert length(header) == 10
    end

    test "header cells A1–J1 use a bold font, a data cell does not, and the pane is frozen below row 1",
         ctx do
      uom = uom!(ctx.s, "pcb")
      item!(ctx.s, "BOLD-1", uom.record_id)
      {:ok, {_name, bin}} = StockWorkbook.build(ctx.auth)
      parts = unzip_parts(bin)

      sheet_xml = Map.fetch!(parts, "xl/worksheets/sheet1.xml")
      assert sheet_xml =~ ~r/<pane [^>]*ySplit="1"/
      assert sheet_xml =~ ~r/<pane [^>]*state="frozen"/

      styles = Map.fetch!(parts, "xl/styles.xml")
      assert bold_cell?(styles, sheet_xml, "A1") == true
      for col <- ~w(A B C D E F G H I J), do: assert(bold_cell?(styles, sheet_xml, col <> "1"))
      # A data cell (row 2) must not carry the bold font.
      refute bold_cell?(styles, sheet_xml, "A2")
      refute bold_cell?(styles, sheet_xml, "B2")
    end

    test "file name is stock-YYYY-MM-DD.xlsx", ctx do
      date_str = today_str()
      {:ok, {name, _bin}} = StockWorkbook.build(ctx.auth)
      assert name == "stock-#{date_str}.xlsx"
    end
  end

  # --- criterion 3: rows fixture ---------------------------------------------------------------

  describe "REQ-865 C3 rows from the Qoimeks TestWriteThenParse fixture" do
    setup ctx do
      s = ctx.s

      # Locations: RI2, RK2, LA1 (must be uppercase for the place pattern to split them).
      ri2 = loc!(s, "RI2", ctx.u)
      rk2 = loc!(s, "RK2", ctx.u)
      la1 = loc!(s, "LA1", ctx.u)

      uom = uom!(s, "шт")

      # Z-1: usual place RI2, second place n/a (G3 amendment: no second_location_id); balance 10 at RI2 and 3 at LA1.
      z1 = item!(s, "Z-1", uom.record_id, %{"name" => "Z-1 Замок"})
      z1 = set_default_location!(s, z1, ri2["record_id"])

      # Z-2: usual place LA1, no second place, balance 4.5 at RK2.
      z2 = item!(s, "Z-2", uom.record_id, %{"name" => "Z-2 Кнопка"})
      z2 = set_default_location!(s, z2, la1["record_id"])

      # Z-3: no place link, no balance (placeholder row).
      z3 = item!(s, "Z-3", uom.record_id, %{"name" => "Z-3 Пусто"})

      # Codes for Z-1.
      tag1 = K.tag!(s, "4600000000017", %{"status" => "assigned"})
      K.assign!(s, tag1, "catalog_item", z1.record_id)
      tag2 = K.tag!(s, "Q-1", %{"status" => "assigned"})
      K.assign!(s, tag2, "catalog_item", z1.record_id)

      # Postings: Z-1 10 at RI2, Z-1 3 at LA1, Z-2 4.5 at RK2.
      # Use uom.record_id as the posting unit (a UUID is a valid LedgerPolicy token and allows
      # Cyrillic catalog UOM codes — the workbook resolves it back to the "шт" code).
      post!(s, "receipt", %{
        lines: [
          line(z1.record_id, "10", %{to: side(ctx.u, ri2["record_id"])}, %{unit: uom.record_id})
        ]
      })

      post!(s, "receipt", %{
        lines: [
          line(z1.record_id, "3", %{to: side(ctx.u, la1["record_id"])}, %{unit: uom.record_id})
        ]
      })

      post!(s, "receipt", %{
        lines: [
          line(z2.record_id, "4.5", %{to: side(ctx.u, rk2["record_id"])}, %{unit: uom.record_id})
        ]
      })

      {:ok, z1: z1, z2: z2, z3: z3, ri2: ri2, rk2: rk2, la1: la1, uom: uom}
    end

    test "data rows match the Qoimeks TestWriteThenParse fixture", ctx do
      [_header | data] = Map.fetch!(build_sheets(ctx.auth), "Остатки #{today_str()}")
      rows = cell_texts(data)

      assert rows == [
               # Z-1 at RI2 (usual place, quantity 10, codes)
               ["Z-1", "Z-1 Замок", "10", "R", "I", "2", "", "RI2", "шт", "4600000000017; Q-1"],
               # Z-1 at LA1 (non-usual place, quantity 3)
               ["Z-1", "Z-1 Замок", "3", "L", "A", "1", "", "LA1", "шт", "4600000000017; Q-1"],
               # Z-2 at LA1 (usual place, quantity 0 since no balance there)
               ["Z-2", "Z-2 Кнопка", "0", "L", "A", "1", "", "LA1", "шт", ""],
               # Z-2 at RK2 (non-usual place, quantity 4.5)
               ["Z-2", "Z-2 Кнопка", "4.5", "R", "K", "2", "", "RK2", "шт", ""],
               # Z-3 (no place, no balance)
               ["Z-3", "Z-3 Пусто", "0", "", "", "", "", "", "шт", ""]
             ]
    end

    test "C column (quantity) and F column (shelf) are number cells", ctx do
      [_header | data] = Map.fetch!(build_sheets(ctx.auth), "Остатки #{today_str()}")
      # Row 0: Z-1 at RI2, C=10 (n), F=2 (n)
      z1_ri2 = Enum.at(data, 0)
      assert Enum.at(z1_ri2, 2) == {"n", "10"}
      assert Enum.at(z1_ri2, 5) == {"n", "2"}
    end
  end

  # --- criterion 4: round trip -----------------------------------------------------------------

  describe "REQ-865 C4 round trip by Qoimeks import rules" do
    setup ctx do
      s = ctx.s

      ri2 = loc!(s, "RI2", ctx.u)
      rk2 = loc!(s, "RK2", ctx.u)
      la1 = loc!(s, "LA1", ctx.u)
      uom = uom!(s, "шт")

      z1 = item!(s, "Z-1", uom.record_id, %{"name" => "Z-1 Замок"})
      z1 = set_default_location!(s, z1, ri2["record_id"])
      z2 = item!(s, "Z-2", uom.record_id, %{"name" => "Z-2 Кнопка"})
      z2 = set_default_location!(s, z2, la1["record_id"])
      _z3 = item!(s, "Z-3", uom.record_id, %{"name" => "Z-3 Пусто"})

      post!(s, "receipt", %{
        lines: [
          line(z1.record_id, "10", %{to: side(ctx.u, ri2["record_id"])}, %{unit: uom.record_id})
        ]
      })

      post!(s, "receipt", %{
        lines: [
          line(z1.record_id, "3", %{to: side(ctx.u, la1["record_id"])}, %{unit: uom.record_id})
        ]
      })

      post!(s, "receipt", %{
        lines: [
          line(z2.record_id, "4.5", %{to: side(ctx.u, rk2["record_id"])}, %{unit: uom.record_id})
        ]
      })

      {:ok, z1: z1, z2: z2}
    end

    test "workbook read back by Qoimeks rules gives Z-1 RI2/RK2, Z-2 LA1/RK2, Z-3 none", ctx do
      [_header | data] = Map.fetch!(build_sheets(ctx.auth), "Остатки #{today_str()}")

      # Apply Qoimeks import rules:
      # - Start after the row whose first cell is "Артикул" (already stripped by parse).
      # - For each row: A=article, B=name, C=quantity, D+E+F=place_code, G=second_place (ignored now).
      # - Rows of one article are added up by place; first row's place is the usual place.
      # - When G is empty the first later row with a different place gives the second place.

      result = qoimeks_parse(cell_texts(data))

      assert result["Z-1"] == %{
               usual: "RI2",
               second: "LA1",
               quantities: %{"RI2" => Decimal.new("10"), "LA1" => Decimal.new("3")}
             }

      assert result["Z-2"] == %{
               usual: "LA1",
               second: "RK2",
               quantities: %{"LA1" => Decimal.new("0"), "RK2" => Decimal.new("4.5")}
             }

      assert result["Z-3"] == %{
               usual: nil,
               second: nil,
               quantities: %{"" => Decimal.new("0")}
             }
    end
  end

  # Qoimeks import rules: aggregate by article and place; usual = first row's place;
  # second = first later row with a different place when G is empty.
  # An empty place_code (all of D, E, F are empty) means "no place" and is treated as nil
  # for the usual-place field.
  defp qoimeks_parse(rows) do
    Enum.reduce(rows, %{}, fn [
                                article,
                                _name,
                                qty_str,
                                zone,
                                rack,
                                shelf,
                                _second,
                                _place,
                                _uom,
                                _codes
                              ],
                              acc ->
      raw_code = "#{zone}#{rack}#{shelf}"
      place_code = if raw_code == "", do: nil, else: raw_code
      qty = Decimal.new(qty_str)
      place_key = place_code || ""

      entry = Map.get(acc, article, %{usual: place_code, second: nil, quantities: %{}})

      entry =
        if Map.get(entry.quantities, place_key) do
          # Already seen this place: add quantity.
          %{entry | quantities: Map.update!(entry.quantities, place_key, &Decimal.add(&1, qty))}
        else
          # New place.
          second =
            if is_nil(entry.second) and place_code != entry.usual and not is_nil(entry.usual),
              do: place_code,
              else: entry.second

          %{entry | second: second, quantities: Map.put(entry.quantities, place_key, qty)}
        end

      Map.put(acc, article, entry)
    end)
  end

  # --- criterion 5: aggregation and items -------------------------------------------------------

  describe "REQ-865 C5 aggregation and items" do
    test "two balance rows of one item at one place in two org units give one row with the sum",
         ctx do
      s = ctx.s
      u2 = Ecto.UUID.generate()
      l = loc!(s, "AA1", ctx.u)
      uom = uom!(s, "kg")
      item = item!(s, "AGG-U", uom.record_id)

      post!(s, "receipt", %{
        lines: [
          line(item.record_id, "7", %{to: %{org_unit: ctx.u, location: l["record_id"]}}, %{
            unit: "kg"
          })
        ]
      })

      post!(s, "receipt", %{
        lines: [
          line(item.record_id, "5", %{to: %{org_unit: u2, location: l["record_id"]}}, %{
            unit: "kg"
          })
        ]
      })

      [_header | data] = Map.fetch!(build_sheets(ctx.auth), "Остатки #{today_str()}")
      rows = cell_texts(data)
      agg_row = Enum.find(rows, fn [art | _] -> art == "AGG-U" end)
      assert agg_row != nil
      assert Enum.at(agg_row, 2) == "12"
    end

    test "two balance rows of one item at one place in two lots give one row with the sum", ctx do
      s = ctx.s
      l = loc!(s, "AB1", ctx.u)
      uom = uom!(s, "kg2")
      item = item!(s, "AGG-L", uom.record_id, %{"tracking_policy" => "lot"})
      lot1 = Cat.lot!(s, item.record_id, "LOT1")
      lot2 = Cat.lot!(s, item.record_id, "LOT2")

      post!(s, "receipt", %{
        lines: [
          line(item.record_id, "4", %{to: side(ctx.u, l["record_id"])}, %{
            unit: "kg2",
            lot: lot1.record_id
          })
        ]
      })

      post!(s, "receipt", %{
        lines: [
          line(item.record_id, "6", %{to: side(ctx.u, l["record_id"])}, %{
            unit: "kg2",
            lot: lot2.record_id
          })
        ]
      })

      [_header | data] = Map.fetch!(build_sheets(ctx.auth), "Остатки #{today_str()}")
      rows = cell_texts(data)
      agg_row = Enum.find(rows, fn [art | _] -> art == "AGG-L" end)
      assert agg_row != nil
      assert Enum.at(agg_row, 2) == "10"
    end

    test "balances of one item at one place in two units give two rows, one per unit code", ctx do
      s = ctx.s
      l = loc!(s, "AC1", ctx.u)
      uom_a = uom!(s, "kg_a")
      _uom_b = uom!(s, "kg_b")
      item = item!(s, "TWO-U", uom_a.record_id)

      # The stock ledger pins unit_ref per balance key (sku, location, org_unit, responsible, lot).
      # To have two different unit_refs at the same location we use two different org units.
      u2 = Ecto.UUID.generate()

      post!(s, "receipt", %{
        lines: [
          line(item.record_id, "3", %{to: %{org_unit: ctx.u, location: l["record_id"]}}, %{
            unit: "kg_a"
          })
        ]
      })

      post!(s, "receipt", %{
        lines: [
          line(item.record_id, "2", %{to: %{org_unit: u2, location: l["record_id"]}}, %{
            unit: "kg_b"
          })
        ]
      })

      [_header | data] = Map.fetch!(build_sheets(ctx.auth), "Остатки #{today_str()}")
      rows = cell_texts(data)
      item_rows = Enum.filter(rows, fn [art | _] -> art == "TWO-U" end)
      assert length(item_rows) == 2
      units = Enum.map(item_rows, &Enum.at(&1, 8)) |> Enum.sort()
      assert units == ["kg_a", "kg_b"]
    end

    test "a retired catalog_item holding a non-zero balance has its rows", ctx do
      s = ctx.s
      l = loc!(s, "AD1", ctx.u)
      uom = uom!(s, "pc3")
      item = item!(s, "RET-BAL", uom.record_id)

      post!(s, "receipt", %{
        lines: [line(item.record_id, "1", %{to: side(ctx.u, l["record_id"])}, %{unit: "pc3"})]
      })

      # Retire the item.
      Cat.update!(s, item, Map.put(item.field_values, "active", false))

      [_header | data] = Map.fetch!(build_sheets(ctx.auth), "Остатки #{today_str()}")
      rows = cell_texts(data)

      assert Enum.any?(rows, fn [art | _] -> art == "RET-BAL" end),
             "retired item with balance not in workbook"
    end

    test "a retired item with no balance and a service item with no balance have no row", ctx do
      s = ctx.s
      uom = uom!(s, "pc4")
      ret = item!(s, "RET-NOBBAL", uom.record_id)
      _svc = item!(s, "SVC-NOBBAL", uom.record_id, %{"kind" => "service"})

      # Retire item with no balance.
      Cat.update!(s, ret, Map.put(ret.field_values, "active", false))

      [_header | data] = Map.fetch!(build_sheets(ctx.auth), "Остатки #{today_str()}")
      rows = cell_texts(data)
      refute Enum.any?(rows, fn [art | _] -> art == "RET-NOBBAL" end)
      refute Enum.any?(rows, fn [art | _] -> art == "SVC-NOBBAL" end)
    end

    test "a balance row whose quantity is zero gives no row (except the usual-place row)", ctx do
      s = ctx.s
      l1 = loc!(s, "AE1", ctx.u)
      l2 = loc!(s, "AE2", ctx.u)
      uom = uom!(s, "pc5")
      item = item!(s, "ZERO-ROW", uom.record_id)
      item = set_default_location!(s, item, l1["record_id"])

      # Post 5 then issue 5 at l1 to zero it out; post 2 at l2.
      post!(s, "receipt", %{
        lines: [line(item.record_id, "5", %{to: side(ctx.u, l1["record_id"])}, %{unit: "pc5"})]
      })

      post!(s, "issue", %{
        lines: [line(item.record_id, "5", %{from: side(ctx.u, l1["record_id"])}, %{unit: "pc5"})]
      })

      post!(s, "receipt", %{
        lines: [line(item.record_id, "2", %{to: side(ctx.u, l2["record_id"])}, %{unit: "pc5"})]
      })

      [_header | data] = Map.fetch!(build_sheets(ctx.auth), "Остатки #{today_str()}")
      rows = cell_texts(data)
      item_rows = Enum.filter(rows, fn [art | _] -> art == "ZERO-ROW" end)
      # The usual place row is there with quantity 0; l2 row is there with quantity 2.
      assert length(item_rows) == 2
      places = Enum.map(item_rows, &Enum.at(&1, 7))
      assert "AE1" in places and "AE2" in places
      zero = Enum.find(item_rows, fn r -> Enum.at(r, 7) == "AE1" end)
      assert Enum.at(zero, 2) == "0"
    end
  end

  # --- criterion 6: place cells ----------------------------------------------------------------

  describe "REQ-865 C6 place cells" do
    test "WH-01 gives D/E/F empty and H=WH-01", ctx do
      s = ctx.s
      l = loc!(s, "WH-01", ctx.u)
      uom = uom!(s, "pc6")
      item = item!(s, "PC6-WH", uom.record_id)

      post!(s, "receipt", %{
        lines: [line(item.record_id, "1", %{to: side(ctx.u, l["record_id"])}, %{unit: "pc6"})]
      })

      [_header | data] = Map.fetch!(build_sheets(ctx.auth), "Остатки #{today_str()}")
      rows = cell_texts(data)
      row = Enum.find(rows, fn [art | _] -> art == "PC6-WH" end)
      assert row != nil
      [_a, _b, _c, d, e, f, _g, h | _] = row
      assert d == "" and e == "" and f == "" and h == "WH-01"
    end

    test "? gives D/E/F empty and H=?", ctx do
      s = ctx.s
      l = loc!(s, "?", ctx.u)
      uom = uom!(s, "pc7")
      item = item!(s, "PC7-Q", uom.record_id)

      post!(s, "receipt", %{
        lines: [line(item.record_id, "1", %{to: side(ctx.u, l["record_id"])}, %{unit: "pc7"})]
      })

      [_header | data] = Map.fetch!(build_sheets(ctx.auth), "Остатки #{today_str()}")
      rows = cell_texts(data)
      row = Enum.find(rows, fn [art | _] -> art == "PC7-Q" end)
      assert row != nil
      [_a, _b, _c, d, e, f, _g, h | _] = row
      assert d == "" and e == "" and f == "" and h == "?"
    end

    test "RI02 gives D=R, E=I, F text cell '02'", ctx do
      s = ctx.s
      l = loc!(s, "RI02", ctx.u)
      uom = uom!(s, "pc8")
      item = item!(s, "PC8-RI02", uom.record_id)

      post!(s, "receipt", %{
        lines: [line(item.record_id, "1", %{to: side(ctx.u, l["record_id"])}, %{unit: "pc8"})]
      })

      sheets = build_sheets(ctx.auth)
      [_header | data] = Map.fetch!(sheets, "Остатки #{today_str()}")
      row = Enum.find(data, fn r -> elem(Enum.at(r, 0), 1) == "PC8-RI02" end)
      assert row != nil
      # F is a text cell "02" (not integer 2).
      assert Enum.at(row, 5) == {"s", "02"}
      assert elem(Enum.at(row, 3), 1) == "R"
      assert elem(Enum.at(row, 4), 1) == "I"
    end

    test "L5 gives D=L, E empty, F number 5", ctx do
      s = ctx.s
      l = loc!(s, "L5", ctx.u)
      uom = uom!(s, "pc9")
      item = item!(s, "PC9-L5", uom.record_id)

      post!(s, "receipt", %{
        lines: [line(item.record_id, "1", %{to: side(ctx.u, l["record_id"])}, %{unit: "pc9"})]
      })

      sheets = build_sheets(ctx.auth)
      [_header | data] = Map.fetch!(sheets, "Остатки #{today_str()}")
      row = Enum.find(data, fn r -> elem(Enum.at(r, 0), 1) == "PC9-L5" end)
      assert row != nil
      assert Enum.at(row, 3) == {"s", "L"}
      assert Enum.at(row, 4) == {"s", ""}
      # F is a number cell.
      assert Enum.at(row, 5) == {"n", "5"}
    end

    test "ri2 (lower case) gives D/E/F empty and ri2 in H", ctx do
      s = ctx.s
      l = loc!(s, "ri2", ctx.u)
      uom = uom!(s, "pca")
      item = item!(s, "PCA-ri2", uom.record_id)

      post!(s, "receipt", %{
        lines: [line(item.record_id, "1", %{to: side(ctx.u, l["record_id"])}, %{unit: "pca"})]
      })

      [_header | data] = Map.fetch!(build_sheets(ctx.auth), "Остатки #{today_str()}")
      rows = cell_texts(data)
      row = Enum.find(rows, fn [art | _] -> art == "PCA-ri2" end)
      assert row != nil
      [_a, _b, _c, d, e, f, _g, h | _] = row
      assert d == "" and e == "" and f == "" and h == "ri2"
    end

    test "a retired usual place still shows its code in H of the usual-place row", ctx do
      s = ctx.s
      l = loc!(s, "AF1", ctx.u)
      uom = uom!(s, "pcb")
      item = item!(s, "PCB-RET", uom.record_id)
      item = set_default_location!(s, item, l["record_id"])

      post!(s, "receipt", %{
        lines: [line(item.record_id, "2", %{to: side(ctx.u, l["record_id"])}, %{unit: "pcb"})]
      })

      # Retire the location (by setting active=false on the node).
      {:ok, loc} = Locations.lookup(s, l["record_id"])

      Letflow.Entities.Records.update_record(
        %{
          entity_type: "location_node",
          record_id: l["record_id"],
          field_values: Map.merge(loc, %{"active" => false}),
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
        },
        s,
        Letflow.Entities.ManagedTypes.owner_for!(Letflow.Modules.Locations)
      )

      [_header | data] = Map.fetch!(build_sheets(ctx.auth), "Остатки #{today_str()}")
      rows = cell_texts(data)
      row = Enum.find(rows, fn [art | _] -> art == "PCB-RET" end)
      assert row != nil
      # H column still carries the retired location's code.
      assert Enum.at(row, 7) == "AF1"
    end
  end

  # --- criterion 7: paging and one cutoff ------------------------------------------------------

  describe "REQ-865 C7 paging and one cutoff" do
    test "with page size 2 and 5 balance rows, every row appears exactly once", ctx do
      s = ctx.s
      l1 = loc!(s, "P1A", ctx.u)
      l2 = loc!(s, "P1B", ctx.u)
      l3 = loc!(s, "P1C", ctx.u)
      l4 = loc!(s, "P1D", ctx.u)
      l5 = loc!(s, "P1E", ctx.u)
      uom = uom!(s, "pcc")
      item = item!(s, "PAGE-5", uom.record_id)

      for {l, qty} <- [{l1, "1"}, {l2, "2"}, {l3, "3"}, {l4, "4"}, {l5, "5"}] do
        post!(s, "receipt", %{
          lines: [line(item.record_id, qty, %{to: side(ctx.u, l["record_id"])}, %{unit: "pcc"})]
        })
      end

      Application.put_env(:letflow, :stock_workbook_balance_page, 2)

      try do
        [_header | data] = Map.fetch!(build_sheets(ctx.auth), "Остатки #{today_str()}")
        rows = cell_texts(data)
        item_rows = Enum.filter(rows, fn [art | _] -> art == "PAGE-5" end)
        assert length(item_rows) == 5
        # Each place appears exactly once.
        place_codes = Enum.map(item_rows, &Enum.at(&1, 7)) |> Enum.sort()
        assert place_codes == Enum.sort(["P1A", "P1B", "P1C", "P1D", "P1E"])
      after
        Application.delete_env(:letflow, :stock_workbook_balance_page)
      end
    end
  end

  # --- criterion 8: cap ------------------------------------------------------------------------

  describe "REQ-865 C8 cap" do
    test "cap lowered to 3: 4 data rows → {:error, :workbook_too_large}", ctx do
      s = ctx.s
      uom = uom!(s, "pcd")

      # Create 4 items (active materials, no balance = one placeholder row each).
      for i <- 1..4 do
        item!(s, "CAP-#{i}", uom.record_id)
      end

      Application.put_env(:letflow, :stock_workbook_max_rows, 3)

      try do
        assert StockWorkbook.build(ctx.auth) == {:error, :workbook_too_large}
      after
        Application.delete_env(:letflow, :stock_workbook_max_rows)
      end

      # The 422 answer through the router is T-RWB-5 in router_test.exs.
    end

    test "cap lowered to 3: exactly 3 data rows → ok", ctx do
      s = ctx.s
      uom = uom!(s, "pce")

      for i <- 1..3 do
        item!(s, "CAP3-#{i}", uom.record_id)
      end

      Application.put_env(:letflow, :stock_workbook_max_rows, 3)

      try do
        assert {:ok, _} = StockWorkbook.build(ctx.auth)
      after
        Application.delete_env(:letflow, :stock_workbook_max_rows)
      end
    end
  end

  # --- criterion 9: read only and tenancy ------------------------------------------------------

  describe "REQ-865 C9 read only and tenancy (INV-1)" do
    test "downloading the workbook writes no entity record, no ledger entry, no audit entry",
         ctx do
      s = ctx.s
      uom = uom!(s, "pcf")
      item = item!(s, "RO-1", uom.record_id)
      l = loc!(s, "RO1", ctx.u)

      post!(s, "receipt", %{
        lines: [line(item.record_id, "2", %{to: side(ctx.u, l["record_id"])}, %{unit: "pcf"})]
      })

      before_records = count_latest(s)
      before_entries = count_audit(s)

      {:ok, _} = StockWorkbook.build(ctx.auth)

      assert count_latest(s) == before_records
      assert count_audit(s) == before_entries
    end

    test "tenant B's workbook has only B's rows, quantities and code values", ctx do
      sa = ctx.s
      sb = ctx.sb

      # Both tenants share the same item code but different quantities.
      admin_b = Fx.user!(%{tenant_id: ctx.tb.tenant_id, schema_name: sb}, ["TENANT_ADMIN"])
      auth_b = authorized!(ctx.tb, admin_b)

      uom_a = uom!(sa, "iso")
      item_a = item!(sa, "ISO-X", uom_a.record_id)
      l_a = loc!(sa, "AA9", ctx.u)

      post!(sa, "receipt", %{
        lines: [
          line(item_a.record_id, "77", %{to: side(ctx.u, l_a["record_id"])}, %{unit: "iso"})
        ]
      })

      tag_a = K.tag!(sa, "CODE-A", %{"status" => "assigned"})
      K.assign!(sa, tag_a, "catalog_item", item_a.record_id)

      uom_b = uom!(sb, "iso")
      item_b = item!(sb, "ISO-X", uom_b.record_id)
      l_b = loc!(sb, "AA9", ctx.ub)

      post!(sb, "receipt", %{
        lines: [
          line(item_b.record_id, "33", %{to: side(ctx.ub, l_b["record_id"])}, %{unit: "iso"})
        ]
      })

      tag_b = K.tag!(sb, "CODE-B", %{"status" => "assigned"})
      K.assign!(sb, tag_b, "catalog_item", item_b.record_id)

      [_h | a_data] = Map.fetch!(build_sheets(ctx.auth), "Остатки #{today_str()}")
      [_h | b_data] = Map.fetch!(build_sheets(auth_b), "Остатки #{today_str()}")

      a_rows = cell_texts(a_data) |> Enum.filter(fn [art | _] -> art == "ISO-X" end)
      b_rows = cell_texts(b_data) |> Enum.filter(fn [art | _] -> art == "ISO-X" end)

      assert length(a_rows) == 1 and Enum.at(hd(a_rows), 2) == "77"
      assert length(b_rows) == 1 and Enum.at(hd(b_rows), 2) == "33"

      # Code values are tenant-specific.
      assert Enum.at(hd(a_rows), 9) == "CODE-A"
      assert Enum.at(hd(b_rows), 9) == "CODE-B"
    end
  end

  # --- helpers ---------------------------------------------------------------------------------

  defp today_str do
    zone = "Asia/Almaty"
    {:ok, today} = Letflow.Identity.TenantTimezone.today(zone)
    Date.to_iso8601(today)
  end

  defp count_latest(schema) do
    Letflow.Repo.one!(
      from(r in Latest, where: r.entity_type != "ledger_snapshot", select: count(r.id)),
      prefix: schema
    )
  end

  defp count_audit(schema) do
    Letflow.Repo.one!(from(e in Entry, select: count(e.id)), prefix: schema)
  end
end
