Code.require_file("codes_fixture.exs", __DIR__)

defmodule Letflow.Modules.Codes.ReadApiTest do
  @moduledoc """
  GH #3588 / REQ-648 criteria 5 to 10 (RS-*, RU-01, SV-*, AT-01, RA-*, TI-01): the read API of
  `Letflow.Modules.Codes` over records written through the owner path.
  """

  use Letflow.DataCase, async: false

  import Letflow.CodesFixture

  alias Letflow.Modules.Codes

  @ok_keys ~w(assignment_id code_id kind status target_id target_type value)

  setup do
    {:ok, installed_tenant!("gh3588-rd")}
  end

  defp assigned!(schema, value, type, id, extra \\ %{}) do
    tag = tag!(schema, value, Map.merge(%{"status" => "assigned"}, extra))
    {tag, assign!(schema, tag, type, id)}
  end

  describe "criterion 5: resolve/2" do
    test "RS-01: unknown, case-differing, nil, 7 and a non-binary prefix are :not_found", %{
      schema: schema
    } do
      tag!(schema, "AbC")
      assert Codes.resolve(schema, "nope") == {:error, :not_found}
      assert Codes.resolve(schema, "abc") == {:error, :not_found}
      assert Codes.resolve(schema, nil) == {:error, :not_found}
      assert Codes.resolve(schema, 7) == {:error, :not_found}
      assert Codes.resolve(7, "AbC") == {:error, :not_found}
      assert Codes.resolve(schema, <<0>>) == {:error, :not_found}
      assert Codes.resolve(schema, <<255>>) == {:error, :not_found}
    end

    test "RS-02: a retired code is :code_retired", %{schema: schema} do
      tag!(schema, "R", %{"status" => "retired"})
      assert Codes.resolve(schema, "R") == {:error, :code_retired}
    end

    test "RS-03a, RS-03b: not_assigned with no rows, or only a closed row, has nil target keys",
         %{schema: schema} do
      tag = tag!(schema, "N1")

      assert {:ok, map} = Codes.resolve(schema, "N1")
      assert map["status"] == "not_assigned"
      assert {map["target_type"], map["target_id"], map["assignment_id"]} == {nil, nil, nil}
      assert map["code_id"] == tag.record_id

      closed = tag!(schema, "N2")
      closed_row = assign!(schema, closed, "location_node", Ecto.UUID.generate())
      release!(schema, closed_row)

      assert {:ok, %{"status" => "not_assigned", "target_type" => nil, "assignment_id" => nil}} =
               Codes.resolve(schema, "N2")
    end

    test "RS-04, RS-06: assigned with one open assignment gives the target; exact key set", %{
      schema: schema
    } do
      target = Ecto.UUID.generate()
      {tag, a} = assigned!(schema, "A1", "location_node", target)

      assert {:ok, map} = Codes.resolve(schema, "A1")
      assert map["target_type"] == "location_node"
      assert map["target_id"] == target
      assert map["assignment_id"] == a.record_id
      assert map["code_id"] == tag.record_id
      assert map["kind"] == "barcode"
      assert map |> Map.keys() |> Enum.sort() == @ok_keys

      assert {:ok, nmap} = Codes.resolve(schema, tag!(schema, "N9").field_values["value"])
      assert nmap |> Map.keys() |> Enum.sort() == @ok_keys
    end

    test "RS-05a..c: every other combination is :assignment_conflict", %{schema: schema} do
      tag!(schema, "C1", %{"status" => "assigned"})
      assert Codes.resolve(schema, "C1") == {:error, :assignment_conflict}

      {tag, _} = assigned!(schema, "C2", "location_node", Ecto.UUID.generate())
      assign!(schema, tag, "location_node", Ecto.UUID.generate())
      assert Codes.resolve(schema, "C2") == {:error, :assignment_conflict}

      c3 = tag!(schema, "C3")
      assign!(schema, c3, "location_node", Ecto.UUID.generate())
      assert Codes.resolve(schema, "C3") == {:error, :assignment_conflict}
    end
  end

  describe "criterion 6: reuse of one tag" do
    test "RU-01: A, release, B: resolve gives B, codes_for and both histories follow", %{
      schema: schema
    } do
      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()
      tag = tag!(schema, "RFID-1", %{"kind" => "epc", "status" => "assigned"})
      first = assign!(schema, tag, "catalog_item", a)

      assert {:ok, %{"target_id" => ^a}} = Codes.resolve(schema, "RFID-1")

      release!(schema, first)
      tag = set_status!(schema, tag, "not_assigned")

      second =
        assign!(schema, tag, "catalog_item", b, %{"assigned_at" => "2026-11-02T12:00:00Z"})

      set_status!(schema, tag, "assigned")

      assert {:ok, %{"target_id" => ^b, "code_id" => code_id}} = Codes.resolve(schema, "RFID-1")
      assert code_id == tag.record_id
      assert Codes.codes_for(schema, "catalog_item", a) == []
      assert [%{"code_id" => ^code_id}] = Codes.codes_for(schema, "catalog_item", b)

      assert [h1, h2] = Codes.assignment_history(schema, tag.record_id)
      assert h1["assignment_id"] == first.record_id
      assert h1["released_at"] && h1["released_by"] == "u-1"
      assert h2["assignment_id"] == second.record_id
      assert h2["released_at"] == nil
    end
  end

  describe "criterion 7: several codes and value history" do
    test "SV-01: three kinds on one target, ordered by value", %{schema: schema} do
      t = Ecto.UUID.generate()

      for {v, k} <- [{"zz", "qr"}, {"aa", "epc"}, {"mm", "barcode"}] do
        assigned!(schema, v, "catalog_item", t, %{"kind" => k})
      end

      assigned!(schema, "other", "catalog_item", Ecto.UUID.generate())

      assert Codes.codes_for(schema, "catalog_item", t) |> Enum.map(& &1["value"]) ==
               ["aa", "mm", "zz"]

      assert Codes.codes_for(schema, "catalog_item", 7) == []
      assert Codes.codes_for(schema, nil, t) == []
    end

    test "SV-02: a changed value keeps the id, is found by the new value, history has one row",
         %{schema: schema} do
      {tag, _} =
        assigned!(schema, "old-epc", "catalog_item", Ecto.UUID.generate(), %{"kind" => "epc"})

      update!(schema, tag, Map.put(tag.field_values, "value", "new-epc"))

      create!(
        schema,
        "code_value_change",
        values("code_value_change", tag.record_id, %{
          "old_value" => "old-epc",
          "new_value" => "new-epc"
        })
      )

      assert {:ok, %{"code_id" => id}} = Codes.resolve(schema, "new-epc")
      assert id == tag.record_id
      assert Codes.resolve(schema, "old-epc") == {:error, :not_found}

      assert [%{"old_value" => "old-epc", "new_value" => "new-epc", "changed_by" => "u-1"}] =
               Codes.value_history(schema, tag.record_id)

      assert {:ok, _} = create(schema, "code_tag", values("code_tag", "old-epc", %{}))
    end
  end

  describe "criterion 8: any target" do
    test "AT-01: KNOWN LIMIT of 0050 D3.6, targets are not validated: a location_node and an unknown type both resolve",
         %{schema: schema} do
      node_id = Ecto.UUID.generate()
      assigned!(schema, "L1", "location_node", node_id)
      assigned!(schema, "U1", "no_such_type", node_id)

      assert {:ok, %{"target_type" => "location_node", "target_id" => ^node_id}} =
               Codes.resolve(schema, "L1")

      assert {:ok, %{"target_type" => "no_such_type", "target_id" => ^node_id}} =
               Codes.resolve(schema, "U1")
    end
  end

  describe "criterion 9: by id and edges" do
    test "RA-01: lookup/2 of each type", %{schema: schema} do
      {tag, a} = assigned!(schema, "K1", "location_node", Ecto.UUID.generate())

      change =
        create!(schema, "code_value_change", values("code_value_change", tag.record_id, %{}))

      for {rec, type} <- [
            {tag, "code_tag"},
            {a, "code_assignment"},
            {change, "code_value_change"}
          ] do
        assert {:ok, map} = Codes.lookup(schema, rec.record_id)
        assert map["entity_type"] == type
        assert map["record_id"] == rec.record_id
      end

      assert {:ok, %{"value" => "K1"}} = Codes.lookup(schema, tag.record_id)
    end

    test "RA-02: a non-uuid or unknown id is :not_found / []", %{schema: schema} do
      for id <- ["nope", 7, nil, Ecto.UUID.generate()] do
        assert Codes.lookup(schema, id) == {:error, :not_found}
        assert Codes.assignment_history(schema, id) == []
        assert Codes.value_history(schema, id) == []
      end
    end

    test "RA-03: the module defines no active?/2" do
      refute function_exported?(Codes, :active?, 2)
    end
  end

  describe "criterion 10: isolation" do
    test "TI-01: tenant B's prefix answers as for an absent value", %{schema: schema} do
      other = installed_tenant!("gh3588-rd2")
      t = Ecto.UUID.generate()
      {tag, a} = assigned!(schema, "ISO", "catalog_item", t)

      change =
        create!(schema, "code_value_change", values("code_value_change", tag.record_id, %{}))

      assert {:ok, _} = Codes.resolve(schema, "ISO")
      assert [_] = Codes.codes_for(schema, "catalog_item", t)
      assert [_] = Codes.assignment_history(schema, tag.record_id)
      assert [_] = Codes.value_history(schema, tag.record_id)

      assert Codes.resolve(other.schema, "ISO") == {:error, :not_found}
      assert Codes.codes_for(other.schema, "catalog_item", t) == []
      assert Codes.lookup(other.schema, tag.record_id) == {:error, :not_found}
      assert Codes.lookup(other.schema, a.record_id) == {:error, :not_found}
      assert Codes.lookup(other.schema, change.record_id) == {:error, :not_found}
      assert Codes.assignment_history(other.schema, tag.record_id) == []
      assert Codes.value_history(other.schema, tag.record_id) == []
    end
  end
end
