defmodule Letflow.Entities.ImportRowTest do
  @moduledoc """
  Core extraction slice S3: canary for the shared import row checks. The expected values are the
  results of the four old private copies (assets, locations, org, catalog lots) on origin/main
  before the move, pasted as literals. Every case that goes through a module refuses before any
  read, so the prefix below is never queried.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.ExternalRef
  alias Letflow.Entities.ImportRow
  alias Letflow.Modules.Assets.Import, as: AssetsImport
  alias Letflow.Modules.CatalogItems.LotImport
  alias Letflow.Modules.Locations.Import, as: LocationsImport
  alias Letflow.Modules.Org.Import, as: OrgImport

  @ref %ExternalRef{system: "erp", id: "1"}
  @ctx %{actor_id: "a", idempotency_key: "k"}
  @prefix "no_such_schema"

  defp entry(type, cells), do: %{entity_type: type, external_ref: @ref, field_values: cells}

  describe "text?/1" do
    test "T1 non-blank binary only" do
      assert ImportRow.text?("a")
      assert ImportRow.text?(" a ")
      refute ImportRow.text?("")
      refute ImportRow.text?("  \t\n")
      refute ImportRow.text?(nil)
      refute ImportRow.text?(5)
      refute ImportRow.text?(:a)
    end
  end

  describe "check_cells/3" do
    test "T2 refusal order and shapes" do
      assert ImportRow.check_cells(%{"a" => "1"}, ["a"], ["i"]) == :ok
      assert ImportRow.check_cells(%{"a" => "1", "i" => "2"}, ["a"], ["i"]) == :ok

      assert ImportRow.check_cells(%{"active" => "true", "z" => "1"}, ["a"], []) ==
               {:error, {:field_not_allowed, "active"}}

      assert ImportRow.check_cells(%{"z" => "1"}, ["a"], ["i"]) == {:error, :field_not_allowed}
    end
  end

  describe "check_required/3" do
    test "T3 first missing header in list order, caller's term" do
      cells = %{"b" => "x", "c" => " "}
      assert ImportRow.check_required(cells, ["b"], &{:e, &1}) == :ok
      assert ImportRow.check_required(cells, ["a", "c"], &{:e, &1}) == {:error, {:e, "a"}}
      assert ImportRow.check_required(cells, ["c", "a"], &{:e, &1}) == {:error, {:e, "c"}}
    end
  end

  describe "transact/1" do
    test "T4 commits on ok, rolls back on error" do
      assert ImportRow.transact(fn -> {:ok, 7} end) == {:ok, 7}
      assert ImportRow.transact(fn -> {:error, :boom} end) == {:error, :boom}
    end
  end

  describe "through the four modules" do
    test "T5 assets" do
      ok = %{
        "inventory_number" => "I",
        "name" => "N",
        "kind" => "fixed",
        "org_unit_id" => "U"
      }

      row = fn cells -> AssetsImport.import_card(@prefix, entry("assets_card", cells), @ctx) end

      assert row.(Map.put(ok, "active", "false")) == {:error, {:field_not_allowed, "active"}}
      assert row.(Map.put(ok, "zzz", "1")) == {:error, :field_not_allowed}
      assert row.(Map.put(ok, "name", " ")) == {:error, {:asset_field_required, "name"}}

      assert row.(Map.delete(ok, "inventory_number")) ==
               {:error, {:asset_field_required, "inventory_number"}}

      assert row.(Map.put(ok, "kind", "bad")) == {:error, :asset_kind_invalid}
    end

    test "T6 locations" do
      ok = %{"code" => "C", "name" => "N", "node_kind" => "site"}
      row = fn cells -> LocationsImport.row(@prefix, entry("location_node", cells), @ctx) end

      assert row.(Map.put(ok, "active", "x")) == {:error, {:field_not_allowed, "active"}}
      assert row.(Map.put(ok, "zzz", "1")) == {:error, :field_not_allowed}
      assert row.(Map.put(ok, "node_kind", "")) == {:error, {:field_invalid, "node_kind"}}
      assert row.(Map.delete(ok, "code")) == {:error, {:field_invalid, "code"}}
    end

    test "T7 org, including the user_id case" do
      emp = %{"code" => "C", "full_name" => "F", "org_unit_id" => "U"}
      row = fn type, cells -> OrgImport.row(@prefix, entry(type, cells), @ctx) end

      assert row.("org_employee", Map.put(emp, "active", "x")) ==
               {:error, {:field_not_allowed, "active"}}

      assert row.("org_employee", Map.put(emp, "site_id", "1")) == {:error, :field_not_allowed}

      assert row.("org_employee", Map.delete(emp, "full_name")) ==
               {:error, {:field_invalid, "full_name"}}

      assert row.("org_position", %{"code" => "C", "name" => "N"}) ==
               {:error, {:field_invalid, "org_unit_id"}}

      assert row.("org_unit", %{"code" => "C", "name" => "N", "legal_entity_id" => "L"}) ==
               {:error, {:field_invalid, "site_id"}}

      assert row.("org_employee", Map.put(emp, "user_id", 5)) ==
               {:error, {:field_invalid, "user_id"}}
    end

    test "T8 catalog lots" do
      ok = %{"item_id" => "I", "code" => "C"}
      row = fn cells -> LotImport.row(@prefix, entry("catalog_lot", cells), @ctx) end

      assert row.(Map.put(ok, "active", "x")) == {:error, {:field_not_allowed, "active"}}
      assert row.(Map.put(ok, "zzz", "1")) == {:error, :field_not_allowed}
      assert row.(Map.put(ok, "code", " ")) == {:error, {:field_invalid, "code"}}
      assert row.(Map.delete(ok, "item_id")) == {:error, {:field_invalid, "item_id"}}
    end
  end
end
