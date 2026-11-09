Code.require_file("assets_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.CardsTest do
  @moduledoc """
  GH #3892 / REQ-750 criteria 2 and 3 (tests R-1..R-9, A-1, A-2, I-1): the write functions of
  `Letflow.Modules.Assets.Cards` on committed tenants. `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.AssetsFixture, as: Fx
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Assets.Cards
  alias Letflow.OrgFixture, as: Org

  setup do
    fx = Fx.installed_tenant!("gh3892-cd")
    schema = fx.schema_name
    unit = Org.unit_id!(schema)
    {:ok, fx: fx, schema: schema, unit: unit}
  end

  @actor Ecto.UUID.generate()
  defp opts(key \\ Ecto.UUID.generate()), do: %{actor_id: @actor, idempotency_key: key}

  defp attrs(_unit, number, extra \\ %{}) do
    Map.merge(
      %{
        "inventory_number" => number,
        "name" => "Card #{number}",
        "kind" => "fixed"
      },
      extra
    )
  end

  # The import is the only caller that may still carry the unit (T-1488).
  defp import_opts, do: Map.put(opts(), :holder_source, :import)

  defp card!(schema, unit, number, extra \\ %{}) do
    {:ok, card} = Cards.create_card(schema, attrs(unit, number, extra), opts())
    card
  end

  defp entries(schema),
    do:
      Repo.all(from(a in Entry, where: like(a.action, "assets_card.%"), order_by: a.timestamp),
        prefix: schema
      )

  defp stored(schema, id) do
    {:ok, %Latest{field_values: fv}} = Latest.get(id, "assets_card", schema)
    fv
  end

  defp card_count(schema),
    do:
      Repo.aggregate(from(l in Latest, where: l.entity_type == "assets_card"), :count,
        prefix: schema
      )

  test "R-1: keys outside the allow-list are refused", %{schema: s, unit: u} do
    assert {:error, {:field_not_allowed, "active"}} =
             Cards.create_card(s, attrs(u, "R1", %{"active" => false}), opts())

    assert {:error, {:field_not_allowed, "tenant_id"}} =
             Cards.create_card(s, attrs(u, "R1", %{"tenant_id" => "x"}), opts())

    assert {:error, {:field_not_allowed, "zzz"}} =
             Cards.create_card(s, attrs(u, "R1", %{"zzz" => 1}), opts())

    card = card!(s, u, "R1B")

    for key <- ["active", "record_id"] do
      assert {:error, {:field_not_allowed, ^key}} =
               Cards.update_card(s, card["record_id"], %{key => true}, opts())
    end

    assert card_count(s) == 1
  end

  test "R-2: (import only) the org unit must be a live active org_unit of this tenant", %{
    fx: fx,
    schema: s,
    unit: u
  } do
    retired = Org.create!(s, "org_unit", Org.values("org_unit", "R2-OFF", %{"active" => false}))
    site = Org.create!(s, "org_site", Org.values("org_site", "R2-S"))
    other = Fx.installed_tenant!("gh3892-cx")
    foreign = Org.unit_id!(other.schema_name)

    for bad <- [
          Ecto.UUID.generate(),
          "not-a-uuid",
          retired.record_id,
          site.record_id,
          foreign,
          5
        ] do
      assert {:error, :org_unit_not_active} =
               Cards.create_card(s, attrs(bad, "R2", %{"org_unit_id" => bad}), import_opts())
    end

    assert {:ok, _} = Cards.create_card(s, attrs(u, "R2-Y", %{"org_unit_id" => u}), import_opts())
    card = card!(s, u, "R2-OK")

    assert {:error, :org_unit_not_active} =
             Cards.update_card(
               s,
               card["record_id"],
               %{"org_unit_id" => retired.record_id},
               import_opts()
             )

    assert card_count(s) == 2
    assert fx.schema_name == s
  end

  test "B1: a card is created without an org unit, nothing stored for it", %{schema: s, unit: u} do
    card = card!(s, u, "B1")
    refute Map.has_key?(card, "org_unit_id")
    refute Map.has_key?(stored(s, card["record_id"]), "org_unit_id")
    assert [%{action: "assets_card.created"}] = entries(s)
  end

  test "B2: the route write path refuses org_unit_id on create and update", %{
    schema: s,
    unit: u
  } do
    assert {:error, {:field_not_allowed, "org_unit_id"}} =
             Cards.create_card(s, attrs(u, "B2", %{"org_unit_id" => u}), opts())

    card = card!(s, u, "B2B")

    assert {:error, {:field_not_allowed, "org_unit_id"}} =
             Cards.update_card(s, card["record_id"], %{"org_unit_id" => u}, opts())

    assert card_count(s) == 1
    assert length(entries(s)) == 1
  end

  test "B3: an update keeps the unit of an old card and keeps a holderless card holderless", %{
    schema: s,
    unit: u
  } do
    {:ok, old} =
      Cards.create_card(s, attrs(u, "B3O", %{"org_unit_id" => u}), import_opts())

    {:ok, new} = Cards.create_card(s, attrs(u, "B3N"), opts())

    assert {:ok, _} = Cards.update_card(s, old["record_id"], %{"name" => "X"}, opts())
    assert {:ok, _} = Cards.update_card(s, new["record_id"], %{"name" => "Y"}, opts())
    assert stored(s, old["record_id"])["org_unit_id"] == u
    refute Map.has_key?(stored(s, new["record_id"]), "org_unit_id")
  end

  test "R-3: valid_until only for intangible, judged on the merged document", %{
    schema: s,
    unit: u
  } do
    assert {:error, :valid_until_not_allowed} =
             Cards.create_card(s, attrs(u, "R3", %{"valid_until" => "2030-01-01"}), opts())

    card = card!(s, u, "R3I", %{"kind" => "intangible", "valid_until" => "2030-01-01"})
    id = card["record_id"]

    assert {:error, :valid_until_not_allowed} =
             Cards.update_card(s, id, %{"kind" => "low_value"}, opts())

    assert stored(s, id)["kind"] == "intangible"

    assert {:ok, c} =
             Cards.update_card(s, id, %{"kind" => "low_value", "valid_until" => nil}, opts())

    assert c["kind"] == "low_value"
    refute Map.has_key?(c, "valid_until")
  end

  test "R-4: currency is the tenant currency or empty", %{schema: s, unit: u} do
    assert {:error, :currency_mismatch} =
             Cards.create_card(s, attrs(u, "R4", %{"currency" => "USD"}), opts())

    assert {:ok, c} = Cards.create_card(s, attrs(u, "R4A", %{"currency" => "KZT"}), opts())
    assert c["currency"] == "KZT"
    assert {:ok, c2} = Cards.create_card(s, attrs(u, "R4B", %{"currency" => ""}), opts())
    refute Map.has_key?(c2, "currency")

    assert {:error, :currency_mismatch} =
             Cards.update_card(s, c["record_id"], %{"currency" => "EUR"}, opts())
  end

  test "R-4b: a tenant currency setting changes the accepted value", %{schema: s, unit: u} do
    Repo.update_all(
      from(t in Letflow.Modules.TenantModule, where: t.module_id == "assets"),
      [set: [settings: %{"currency" => "EUR"}]],
      prefix: s
    )

    assert {:ok, _} = Cards.create_card(s, attrs(u, "R4E", %{"currency" => "EUR"}), opts())

    assert {:error, :currency_mismatch} =
             Cards.create_card(s, attrs(u, "R4K", %{"currency" => "KZT"}), opts())
  end

  test "R-5: record errors: duplicates, strict decimals, missing required", %{schema: s, unit: u} do
    card!(s, u, "R5")
    assert {:error, {:record_payload_invalid, _}} = Cards.create_card(s, attrs(u, "R5"), opts())

    other = Fx.installed_tenant!("gh3892-c5")
    ou = Org.unit_id!(other.schema_name)
    assert {:ok, _} = Cards.create_card(other.schema_name, attrs(ou, "R5"), opts())

    ref = %{"external_ref_system" => "erp", "external_ref_id" => "1"}
    card!(s, u, "R5X1", ref)

    assert {:error, {:record_payload_invalid, _}} =
             Cards.create_card(s, attrs(u, "R5X2", ref), opts())

    for bad <- ["1e3", "abc", "1,5"] do
      assert {:error, {:record_payload_invalid, _}} =
               Cards.create_card(s, attrs(u, "R5D", %{"acquisition_cost" => bad}), opts())
    end

    assert {:error, {:record_payload_invalid, _}} =
             Cards.create_card(s, Map.delete(attrs(u, "R5N"), "name"), opts())
  end

  test "R-6: a retired card cannot be updated or retired again", %{schema: s, unit: u} do
    id = card!(s, u, "R6")["record_id"]
    assert {:ok, %{"active" => false}} = Cards.retire_card(s, id, opts())
    before = stored(s, id)
    assert {:error, :card_inactive} = Cards.update_card(s, id, %{"name" => "x"}, opts())
    assert {:error, :card_inactive} = Cards.retire_card(s, id, opts())
    assert stored(s, id) == before
    assert {:error, :card_not_found} = Cards.retire_card(s, Ecto.UUID.generate(), opts())
    assert {:error, :card_not_found} = Cards.update_card(s, "nope", %{}, opts())
  end

  test "R-7: accepted shapes and decimals stored exactly as given", %{schema: s, unit: u} do
    card =
      card!(s, u, "R7", %{
        "kind" => "intangible",
        "valid_until" => "2031-02-03",
        "acquisition_cost" => "1234.500000000",
        "acquisition_date" => "2024-01-02"
      })

    refute Map.has_key?(card, "location_id")
    assert card["acquisition_cost"] == "1234.500000000"

    assert {:ok, c} =
             Cards.update_card(
               s,
               card["record_id"],
               %{
                 "accumulated_depreciation" => "100.250000000",
                 "book_value" => "1134.250000000",
                 "depreciation_as_of" => "2025-01-01",
                 "acquisition_cost" => "1234.500000000"
               },
               opts()
             )

    assert stored(s, c["record_id"])["book_value"] == "1134.250000000"
    assert stored(s, c["record_id"])["accumulated_depreciation"] == "100.250000000"

    fixed = card!(s, u, "R7F")

    assert {:ok, c2} =
             Cards.update_card(
               s,
               fixed["record_id"],
               %{"kind" => "intangible", "valid_until" => "2040-01-01"},
               opts()
             )

    assert c2["kind"] == "intangible"
  end

  test "R-8: inventory_number stays unique per tenant on update", %{schema: s, unit: u} do
    card!(s, u, "R8A")
    b = card!(s, u, "R8B")

    assert {:error, {:record_payload_invalid, _}} =
             Cards.update_card(s, b["record_id"], %{"inventory_number" => "R8A"}, opts())

    assert {:ok, %{"inventory_number" => "R8C"}} =
             Cards.update_card(s, b["record_id"], %{"inventory_number" => "R8C"}, opts())
  end

  test "R-9: an update that changes nothing writes no entry", %{schema: s, unit: u} do
    card = card!(s, u, "R9")
    id = card["record_id"]
    n = length(entries(s))
    assert {:ok, ^card} = Cards.update_card(s, id, %{"name" => card["name"]}, opts())
    assert {:ok, ^card} = Cards.update_card(s, id, %{}, opts())
    assert length(entries(s)) == n
  end

  test "A-1: one audit entry per accepted write, none for refusals", %{schema: s, unit: u} do
    actor = Ecto.UUID.generate()
    o = fn -> %{actor_id: actor, idempotency_key: Ecto.UUID.generate()} end
    {:ok, card} = Cards.create_card(s, attrs(u, "A1"), o.())
    id = card["record_id"]
    {:ok, _} = Cards.update_card(s, id, %{"name" => "New"}, o.())
    {:error, _} = Cards.update_card(s, id, %{"active" => false}, o.())
    {:error, _} = Cards.create_card(s, attrs(u, "A1"), o.())
    {:ok, _} = Cards.retire_card(s, id, o.())
    {:error, :card_inactive} = Cards.retire_card(s, id, o.())

    es = entries(s)

    assert Enum.map(es, & &1.action) == [
             "assets_card.created",
             "assets_card.updated",
             "assets_card.retired"
           ]

    for e <- es do
      assert e.resource_type == "assets_card" and e.resource_id == id and e.actor_id == actor
    end

    [c, up, re] = es
    assert c.before_state == nil and c.after_state["inventory_number"] == "A1"
    assert up.before_state["name"] == "Card A1" and up.after_state["name"] == "New"
    assert re.before_state["active"] == true and re.after_state["active"] == false
  end

  describe "A-2: a failing audit entry rolls the write back" do
    setup %{schema: s, unit: u} do
      card = card!(s, u, "A2")
      Repo.query!(~s(DROP TABLE "#{s}".audit_entries))
      {:ok, card: card}
    end

    test "create, update, retire", %{schema: s, unit: u, card: card} do
      id = card["record_id"]
      before = stored(s, id)
      assert {:error, :audit_failed} = Cards.create_card(s, attrs(u, "A2N"), opts())
      assert card_count(s) == 1
      assert {:error, :audit_failed} = Cards.update_card(s, id, %{"name" => "X"}, opts())
      assert stored(s, id) == before
      assert {:error, :audit_failed} = Cards.retire_card(s, id, opts())
      assert stored(s, id)["active"] == true
    end
  end

  test "I-1: idempotency: replay answers the first result, other body is reuse", %{
    schema: s,
    unit: u
  } do
    key = Ecto.UUID.generate()
    {:ok, a} = Cards.create_card(s, attrs(u, "I1"), opts(key))
    n = length(entries(s))
    assert {:ok, ^a} = Cards.create_card(s, attrs(u, "I1"), opts(key))
    assert length(entries(s)) == n
    assert card_count(s) == 1

    assert {:error, :idempotency_key_reuse} =
             Cards.create_card(s, attrs(u, "I1-other"), opts(key))

    ukey = Ecto.UUID.generate()
    {:ok, b} = Cards.update_card(s, a["record_id"], %{"name" => "Renamed"}, opts(ukey))
    assert {:ok, ^b} = Cards.update_card(s, a["record_id"], %{"name" => "Renamed"}, opts(ukey))

    assert {:error, :idempotency_key_reuse} =
             Cards.update_card(s, a["record_id"], %{"name" => "Other"}, opts(ukey))

    rkey = Ecto.UUID.generate()
    {:ok, r} = Cards.retire_card(s, a["record_id"], opts(rkey))
    assert {:ok, ^r} = Cards.retire_card(s, a["record_id"], opts(rkey))
    assert Enum.count(entries(s), &(&1.action == "assets_card.retired")) == 1
  end
end
