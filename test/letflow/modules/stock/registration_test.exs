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
      "issue" => %{sign_rule: :negative, reason_required: false},
      "write_off" => %{sign_rule: :negative, reason_required: true},
      "transfer" => %{sign_rule: :zero_sum_by_slot_1, reason_required: false},
      "hand_over" => %{sign_rule: :zero_sum_by_slot_1, reason_required: false},
      "return" => %{sign_rule: :zero_sum_by_slot_1, reason_required: false}
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
    error_aliases: %{"insufficient_balance" => "insufficient_stock"},
    policy: %{module: Letflow.Modules.Stock.LedgerPolicy, function: :declare}
  }

  test "T-RG-1: the manifest, the catalog and the config order" do
    m = Stock.manifest()
    assert Catalog.validate(m) == :ok
    assert m.id == "stock"
    assert m.version == "0.2.0"
    assert m.depends_on == ["org", "locations"]
    assert m.pack == "modules/stock/pack.json"

    assert m.manages_entity_types == [
             "count_order",
             "count_order_scope",
             "count_commission_member"
           ]

    assert Map.get(m, :write_handlers, []) == []

    assert m.permissions == [
             :StockPost,
             :StockReverse,
             :StockRead,
             :StockReconcile,
             :StockCountOrder
           ]

    assert m.role_grants == %{}

    assert m.scope_declarations == %{
             "count_order" => {:column, "org_unit_id"},
             "count_order_scope" => {:column, "org_unit_id"},
             "count_commission_member" => {:column, "org_unit_id"}
           }

    assert m.route_policies == [
             {"GET", "/balances", :StockRead},
             {"GET", "/movements", :StockRead},
             {"GET", "/reconcile", :StockReconcile},
             {"POST", "/counts", :StockCountOrder},
             {"PUT", "/counts/:id", :StockCountOrder},
             {"POST", "/counts/:id/issue", :StockCountOrder},
             {"POST", "/counts/:id/cancel", :StockCountOrder},
             {"GET", "/counts", :StockRead},
             {"GET", "/counts/:id", :StockRead},
             {"GET", "/counts/:id/document", :StockRead}
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
             ~w(hand_over issue receipt return transfer write_off)

    assert r.causes["write_off"] == %{sign_rule: :negative, reason_required: true}
    assert r.causes["receipt"].sign_rule == :positive
    assert r.key_bounds == []
    refute Map.has_key?(r, :units)
    assert r.permissions == @registration.permissions
    assert r.scope_slot == "org_unit"
    assert r.max_event_lateness_hours == 96
    assert r.error_aliases == %{"insufficient_balance" => "insufficient_stock"}
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
    assert length(files) == 5

    sources = Enum.map(files, &{&1, File.read!(&1)})
    assert Mix.Tasks.Letflow.CheckBoundaries.rule_8_violations(sources) == []

    # REQ-700: counts.ex reads and writes the count record types (Repo, Ecto.Query), never a ledger table.
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
          ],
        not (Path.basename(path) == "counts.ex" and word in ["Repo", "Ecto.Query"]) do
      refute source =~ word, "#{path} names #{word}"
    end
  end
end
