defmodule Letflow.Modules.Stock.RegistrationTest do
  @moduledoc """
  REQ-687 / GH #3707 criteria 1 and 2 (T-RG-1..3, T-APP-1, T-R-RULE8): the stock manifest and its ledger
  registration, the config order, the hash coverage, the boot registry and the Rule 8 scan. Pure: no database.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  alias Letflow.Modules.Catalog
  alias Letflow.Modules.ManifestHash
  alias Letflow.Modules.Stock

  @registration %{
    ledger_ids: ["stock"],
    slots: [
      %{name: "sku", format: :uuid, required: true},
      %{name: "location", format: :uuid, required: true},
      %{name: "org_unit", format: :uuid, required: true},
      %{name: "responsible", format: :uuid, required: false},
      %{name: "lot", format: :uuid, required: false}
    ],
    causes: %{
      "receipt" => %{sign_rule: :positive, reason_required: false},
      "opening" => %{sign_rule: :positive, reason_required: false},
      "issue" => %{sign_rule: :negative, reason_required: false},
      "write_off" => %{sign_rule: :negative, reason_required: true},
      "transfer" => %{sign_rule: :zero_sum_by_slot_1, reason_required: false},
      "hand_over" => %{sign_rule: :zero_sum_by_slot_1, reason_required: false},
      "return" => %{sign_rule: :zero_sum_by_slot_1, reason_required: false},
      "count_difference" => %{sign_rule: :any, reason_required: true},
      "kind_change_out" => %{sign_rule: :negative, reason_required: false}
    },
    key_bounds: [],
    permissions: %{
      post: :StockPost,
      reverse: :StockReverse,
      read: :StockRead,
      reconcile: :StockReconcile
    },
    scope_slot: "org_unit",
    max_event_lateness_hours: 96,
    error_aliases: %{
      "insufficient_balance" => "insufficient_stock",
      "posting_held" => "location_frozen"
    },
    posting_guard: %{module: Letflow.Modules.Stock.FreezeGuard, function: :check},
    policy: %{module: Letflow.Modules.Stock.LedgerPolicy, function: :declare}
  }

  test "T-RG-1: the manifest, the catalog and the config order" do
    m = Stock.manifest()
    assert Catalog.validate(m) == :ok
    assert m.id == "stock"
    assert m.version == "0.17.0"
    assert m.depends_on == ["catalog_items", "codes", "locations", "org"]
    assert m.pack == "modules/stock/pack.json"

    assert m.manages_entity_types == [
             "stock_receipt",
             "stock_receipt_line",
             "stock_issue",
             "stock_issue_line",
             "stock_writeoff",
             "stock_writeoff_line",
             "stock_transfer",
             "stock_transfer_line",
             "stock_handover",
             "stock_handover_line",
             "stock_return",
             "stock_return_line",
             "count_order",
             "count_order_scope",
             "count_commission_member",
             "count_sheet_line",
             "count_entry",
             "count_signature",
             "count_freeze_location",
             "stock_posting_mark",
             "stock_opening",
             "stock_opening_line"
           ]

    assert Enum.map(m.write_handlers, & &1.name) == [
             "post_document",
             "reverse_document",
             "post_count",
             "post_kind_change_out"
           ]

    assert m.permissions == [
             :StockPost,
             :StockReverse,
             :StockRead,
             :StockReconcile,
             :StockCountOrder,
             :StockCountRecord
           ]

    assert m.role_grants == %{
             STOREKEEPER: [
               :StockRead,
               :StockPost,
               :StockReverse,
               :StockCountOrder,
               :StockCountRecord
             ]
           }

    assert m.scope_declarations == %{
             "stock_receipt" => {:column, "org_unit_id"},
             "stock_receipt_line" => {:column, "org_unit_id"},
             "stock_issue" => {:column, "org_unit_id"},
             "stock_issue_line" => {:column, "org_unit_id"},
             "stock_writeoff" => {:column, "org_unit_id"},
             "stock_writeoff_line" => {:column, "org_unit_id"},
             "stock_transfer" => {:column, "org_unit_id"},
             "stock_transfer_line" => {:column, "org_unit_id"},
             "stock_handover" => {:column, "org_unit_id"},
             "stock_handover_line" => {:column, "org_unit_id"},
             "stock_return" => {:column, "org_unit_id"},
             "stock_return_line" => {:column, "org_unit_id"},
             "count_order" => {:column, "org_unit_id"},
             "count_order_scope" => {:column, "org_unit_id"},
             "count_commission_member" => {:column, "org_unit_id"},
             "count_sheet_line" => {:column, "org_unit_id"},
             "count_entry" => {:column, "org_unit_id"},
             "count_signature" => {:column, "org_unit_id"},
             "count_freeze_location" => {:column, "org_unit_id"},
             "stock_posting_mark" => {:column, "org_unit_id"},
             "stock_opening" => {:column, "org_unit_id"},
             "stock_opening_line" => {:column, "org_unit_id"}
           }

    assert m.route_policies == [
             {"GET", "/balances", :StockRead},
             {"GET", "/movements", :StockRead},
             {"GET", "/reconcile", :StockReconcile},
             {"POST", "/documents", :StockPost},
             {"PUT", "/documents/:id", :StockPost},
             {"DELETE", "/documents/:id", :StockPost},
             {"POST", "/documents/:id/issue", :StockPost},
             {"POST", "/documents/:id/check", :StockPost},
             {"GET", "/documents", :StockRead},
             {"GET", "/documents/:id", :StockRead},
             {"GET", "/documents/:id/print", :StockRead},
             {"GET", "/stock-card/print", :StockRead},
             {"GET", "/stock-sheet/print", :StockRead},
             {"POST", "/documents/:id/post", :StockPost},
             {"POST", "/documents/:id/reverse", :StockReverse},
             {"POST", "/documents/:id/cancel", :StockReverse},
             {"POST", "/counts", :StockCountOrder},
             {"PUT", "/counts/:id", :StockCountOrder},
             {"POST", "/counts/:id/issue", :StockCountOrder},
             {"POST", "/counts/:id/cancel", :StockCountOrder},
             {"GET", "/counts", :StockRead},
             {"GET", "/counts/:id", :StockRead},
             {"GET", "/frozen-locations", :StockRead},
             {"GET", "/counts/:id/document", :StockRead},
             {"GET", "/counts/:id/paperwork/:kind", :StockRead},
             {"GET", "/counts/:id/print/:kind", :StockRead},
             {"POST", "/counts/:id/open", :StockCountRecord},
             {"POST", "/counts/:id/scan", :StockCountRecord},
             {"GET", "/counts/:id/lines", :StockRead},
             {"PUT", "/counts/:id/lines/:line_no/count", :StockCountRecord},
             {"POST", "/counts/:id/surplus-lines", :StockCountRecord},
             {"GET", "/counts/:id/entries", :StockRead},
             {"POST", "/counts/:id/close", :StockCountRecord},
             {"GET", "/counts/:id/sheet-document", :StockRead},
             {"POST", "/counts/:id/sheet-signatures", :StockCountRecord},
             {"POST", "/counts/:id/differences", :StockCountRecord},
             {"POST", "/counts/:id/differences-signatures", :StockCountRecord},
             {"GET", "/counts/:id/differences", :StockRead},
             {"GET", "/counts/:id/signatures", :StockRead},
             {"POST", "/counts/:id/post", :StockPost},
             {"POST", "/counts/:id/reverse", :StockReverse},
             {"POST", "/counts/:id/posting-record", :StockCountRecord},
             {"GET", "/counts/:id/posting-document", :StockRead},
             {"POST", "/voice/draft", :StockPost},
             {"POST", "/voice/draft-text", :StockPost}
           ]

    assert Stock.router() == Letflow.Modules.Stock.Router
    assert Catalog.fetch("stock") == {:ok, Stock}
    assert Catalog.fetch_ledger("stock", "stock") == {:ok, @registration}

    for file <- ["config/config.exs", "config/test.exs"] do
      source = File.read!(file)
      assert source =~ ~r/Letflow\.Modules\.Codes,\s*Letflow\.Modules\.Stock/
    end

    modules = Catalog.entry_modules()
    codes = Enum.find_index(modules, &(&1 == Letflow.Modules.Codes))
    assert Enum.at(modules, codes + 1) == Stock
  end

  test "T-RG-2: every registration value, one by one" do
    {:ok, r} = Catalog.fetch_ledger("stock", "stock")
    assert r.ledger_ids == ["stock"]
    assert Enum.map(r.slots, & &1.name) == ~w(sku location org_unit responsible lot)
    assert Enum.map(r.slots, & &1.required) == [true, true, true, false, false]
    assert Enum.all?(r.slots, &(&1.format == :uuid))

    assert Map.keys(r.causes) |> Enum.sort() ==
             ~w(count_difference hand_over issue kind_change_out opening receipt return transfer write_off)

    # REQ-718: one cause, sign rule any, a reason required
    assert r.causes["count_difference"] == %{sign_rule: :any, reason_required: true}

    assert r.causes["write_off"] == %{sign_rule: :negative, reason_required: true}
    assert r.causes["receipt"].sign_rule == :positive
    assert r.key_bounds == []
    refute Map.has_key?(r, :units)
    assert r.permissions == @registration.permissions
    assert r.scope_slot == "org_unit"
    assert r.max_event_lateness_hours == 96

    assert r.error_aliases == %{
             "insufficient_balance" => "insufficient_stock",
             "posting_held" => "location_frozen"
           }

    assert r.posting_guard == %{module: Letflow.Modules.Stock.FreezeGuard, function: :check}
    assert r.policy == %{module: Letflow.Modules.Stock.LedgerPolicy, function: :declare}
  end

  test "T-RG-3: the manifest hash changes with each registration part" do
    base = Stock.manifest()
    hash = &ManifestHash.compute/1
    change = fn fun -> update_in(base.ledger["stock"], fun) end

    variants = [
      change.(
        &Map.update!(&1, :slots, fn [first | rest] -> [%{first | required: false} | rest] end)
      ),
      change.(&Map.update!(&1, :causes, fn c -> Map.delete(c, "return") end)),
      change.(&Map.update!(&1, :permissions, fn p -> %{p | read: :StockPost} end)),
      change.(&Map.put(&1, :scope_slot, "location")),
      change.(&Map.put(&1, :error_aliases, %{})),
      change.(&Map.put(&1, :policy, {Letflow.Modules.Stock.Views, :declare}))
    ]

    hashes = Enum.map(variants, hash)
    assert length(Enum.uniq([hash.(base) | hashes])) == 7
  end

  test "T-APP-1: the boot registry carries stock with its permissions" do
    registry = Catalog.ledger_registry()

    assert %{name: "stock", read_permission: :StockRead, reconcile_permission: :StockReconcile} =
             registry["stock"]

    assert registry["stock"].registration.scope_slot == "org_unit"
  end

  test "T-R-RULE8: no Rule 8 violation and no SQL names in the module files" do
    files = Path.wildcard("lib/letflow/modules/stock/**/*.ex")
    # T-1416: form_z2.ex (pure Z-2 data map, no Repo) makes 31.
    # T-1418: form_count.ex, form_count_inv18.ex and form_count_inv10.ex (pure data maps, no Repo) make 34.
    # T-1417: form_z3.ex, form_z5.ex (pure) and stock_card_source.ex (reads through Ledger) make 37; REQ-765 freeze_guard.ex and freeze_state.ex make 39.
    # T-1905: count_worksheet.ex (pure, no Repo) makes 40.
    # T-1912: form_z1.ex (pure Z-1 data map, no Repo) makes 41.
    # T-1914: form_z6.ex (pure Z-6 data map, no Repo) makes 42.
    # T-1955: data_export.ex (reads through Ledger, no Repo) makes 43.
    # T-1925: form_z7.ex (pure Z-7 data map, no Repo) and stock_sheet_source.ex (reads through Ledger) make 45.
    assert length(files) == 45

    sources = Enum.map(files, &{&1, File.read!(&1)})
    assert Mix.Tasks.Letflow.CheckBoundaries.rule_8_violations(sources) == []

    # REQ-712: the document context (documents.ex, documents/) reads and writes its own record and
    # document tables, so Repo and Ecto.Query are allowed there; the ledger names stay banned everywhere.
    # REQ-701: count_sheet.ex does the same for the sheet lines and the entry log.
    # REQ-717: count_differences.ex reads the order children and writes the signature rows.
    # REQ-719: count_paperwork_source.ex reads issued versions and one offset statement (own tables only).
    # REQ-736: count_print.ex is pure (no Repo, no query); it is only counted here.
    # REQ-700: counts.ex reads and writes the count record types (Repo, Ecto.Query), never a ledger table.
    # REQ-765: freeze_state.ex reads the count order and freeze rows and writes the freeze audit entries (own tables only);
    # freeze_guard.ex is pure over it (no Repo), both are counted here (36).
    # GH 3735 R7: document_numbers.ex reads the core document and type rows (own tables) for the movement number.
    own_tables = fn path ->
      path =~
        ~r{stock/(documents(\.ex|/)|counts\.ex|count_sheet\.ex|count_differences\.ex|count_paperwork_source\.ex|document_numbers\.ex|freeze_state\.ex)}
    end

    for {path, source} <- sources,
        word <-
          [
            "Repo",
            "Ecto.Query",
            "Ecto.Adapters.SQL",
            "ledger_entry",
            "ledger_leg",
            "ledger_balance",
            "ledger_counter",
            "binary_to_term"
          ] do
      unless own_tables.(path) and word in ["Repo", "Ecto.Query"],
        do: refute(source =~ word, "#{path} names #{word}")
    end
  end
end
