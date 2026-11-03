Code.require_file("locations_fixture.exs", __DIR__)

defmodule Letflow.Modules.Locations.DescendantIdsTest do
  @moduledoc """
  GH #3588 / REQ-646 criterion 7 (tests D-01..D-10): `descendant_ids/2`, the subtree read by one
  recursive query.
  """

  use Letflow.DataCase, async: false

  import Letflow.LocationsFixture

  alias Letflow.Modules.Locations

  @tree_path Path.join([File.cwd!(), "lib", "letflow", "modules", "locations", "tree.ex"])

  setup do
    {:ok, installed_tenant!("gh3588-di")}
  end

  defp opts, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

  defp mk!(schema, code, parent \\ nil) do
    attrs = %{"code" => code, "name" => "N #{code}", "node_kind" => "zone"}
    attrs = if parent, do: Map.put(attrs, "parent_id", parent["record_id"]), else: attrs
    {:ok, node} = Locations.create_node(schema, attrs, opts())
    node
  end

  defp del!(schema, n),
    do: delete!(schema, %{entity_type: "location_node", record_id: n["record_id"]})

  test "D-01/D-02/D-05: five levels, sorted text, without the node; leaf is []", %{schema: schema} do
    root = mk!(schema, "L0")

    nodes = build(schema, root, 5)

    ids = nodes |> Enum.map(& &1["record_id"]) |> Enum.sort()
    assert Locations.descendant_ids(schema, root["record_id"]) == ids
    refute root["record_id"] in ids
    assert Locations.descendant_ids(schema, List.last(nodes)["record_id"]) == []
  end

  defp build(schema, root, n) do
    {list, _} =
      Enum.map_reduce(1..n, root, fn i, prev ->
        node = mk!(schema, "L#{i}", prev)
        {node, node}
      end)

    list
  end

  test "D-03/D-04: retired is listed; soft-deleted and below are left out", %{schema: schema} do
    r = mk!(schema, "R")
    a = mk!(schema, "A", r)
    b = mk!(schema, "B", r)
    c = mk!(schema, "C", b)
    {:ok, _} = Locations.retire_node(schema, c["record_id"], opts())

    assert Locations.descendant_ids(schema, r["record_id"]) |> Enum.sort() ==
             Enum.sort([a["record_id"], b["record_id"], c["record_id"]])

    # the owner path soft-deletes c's parent chain end; c then drops out alone
    del!(schema, c)

    assert Locations.descendant_ids(schema, r["record_id"]) ==
             Enum.sort([a["record_id"], b["record_id"]])
  end

  test "D-06/D-07/D-08: bad ids and prefixes give [] without a raise", %{schema: schema} do
    r = mk!(schema, "R")
    _ = mk!(schema, "A", r)
    other = create!(schema, "location_node", values("location_node", "Z", %{}))
    assert other.record_id
    assert Locations.descendant_ids(schema, "nope") == []
    assert Locations.descendant_ids(schema, Ecto.UUID.generate()) == []
    assert Locations.descendant_ids(schema, nil) == []
    assert Locations.descendant_ids(nil, r["record_id"]) == []
    assert Locations.descendant_ids(123, r["record_id"]) == []
    assert Locations.descendant_ids("bad prefix;", r["record_id"]) == []

    assert Locations.descendant_ids("tenant_00000000000000000000000000000000", r["record_id"]) ==
             []
  end

  test "D-09: a damaged chain ends", %{schema: schema} do
    x = mk!(schema, "X")
    y = mk!(schema, "Y", x)

    update!(
      schema,
      %{entity_type: "location_node", record_id: x["record_id"]},
      Map.put(values("location_node", "X", %{}), "parent_id", y["record_id"])
    )

    assert Locations.descendant_ids(schema, x["record_id"]) == [y["record_id"]]
  end

  test "D-10: a soft-deleted node with live children gives []", %{schema: schema} do
    r = mk!(schema, "R")
    _child = mk!(schema, "C", r)
    del!(schema, r)
    assert Locations.descendant_ids(schema, r["record_id"]) == []
  end

  test "D-11: one recursive query, node id bound" do
    src = File.read!(@tree_path)
    assert length(Regex.scan(~r/WITH RECURSIVE/, src)) == 1
    assert src =~ "$1::uuid"
    refute src =~ ~S|#{node_id}|
  end
end
