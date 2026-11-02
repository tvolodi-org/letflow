Code.require_file("locations_fixture.exs", __DIR__)

defmodule Letflow.Modules.Locations.TreeWriteTest do
  @moduledoc """
  GH #3588 / REQ-646 (tests M-*, X-*, U-*, R-*, L-*, T-*, P-*): `move_node/4`, `update_node/4` and
  `retire_node/3` on freshly provisioned tenants with the real installed module.
  """

  use Letflow.DataCase, async: false

  import Letflow.LocationsFixture

  alias Letflow.Modules.Locations
  alias Letflow.Repo

  @tree_path Path.join([File.cwd!(), "lib", "letflow", "modules", "locations", "tree.ex"])
  @locations_path Path.join([
                    File.cwd!(),
                    "lib",
                    "letflow",
                    "modules",
                    "locations",
                    "locations.ex"
                  ])

  setup do
    {:ok, installed_tenant!("gh3588-tw")}
  end

  defp opts, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

  defp mk!(schema, code, parent \\ nil, extra \\ %{}) do
    attrs = %{"code" => code, "name" => "N #{code}", "node_kind" => "zone"}
    attrs = if parent, do: Map.put(attrs, "parent_id", parent["record_id"]), else: attrs
    {:ok, node} = Locations.create_node(schema, Map.merge(attrs, extra), opts())
    node
  end

  # The event position of every live node, to prove that nothing else was written.
  defp seqs(schema) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT record_id::text, last_event_global_seq FROM "#{schema}".entity_record_latest ORDER BY 1|
      )

    rows
  end

  defp seq(schema, node),
    do: seqs(schema) |> Enum.find(&(hd(&1) == node["record_id"])) |> List.last()

  describe "move_node/4" do
    test "M-01: moves a subtree root with one write; others untouched", %{schema: schema} do
      r = mk!(schema, "R")
      a = mk!(schema, "A", r)
      b = mk!(schema, "B", a)
      c = mk!(schema, "C", b)
      s = mk!(schema, "S")
      before = seqs(schema)

      assert {:ok, moved} = Locations.move_node(schema, a["record_id"], s["record_id"], opts())
      assert moved["parent_id"] == s["record_id"]
      assert {:ok, %{"parent_id" => pb}} = Locations.lookup(schema, b["record_id"])
      assert pb == a["record_id"]
      assert {:ok, %{"parent_id" => pc}} = Locations.lookup(schema, c["record_id"])
      assert pc == b["record_id"]

      assert Locations.descendant_ids(schema, s["record_id"]) ==
               Enum.sort([a["record_id"], b["record_id"], c["record_id"]])

      assert Locations.descendant_ids(schema, r["record_id"]) == []

      changed = for {x, y} <- Enum.zip(before, seqs(schema)), x != y, do: hd(x)
      assert changed == [a["record_id"]]
    end

    test "M-02: to the top removes parent_id; address and descendants stay", %{schema: schema} do
      r = mk!(schema, "R", nil, %{"segment" => "r", "address" => "r"})
      a = mk!(schema, "A", r, %{"address" => "r-a"})
      assert {:ok, moved} = Locations.move_node(schema, a["record_id"], nil, opts())
      refute Map.has_key?(moved, "parent_id")
      assert moved["address"] == "r-a"
    end

    test "M-03: a 50 chain moves under the end of another 50 chain", %{schema: schema} do
      chain = fn tag ->
        Enum.reduce(1..50, {nil, nil}, fn i, {first, prev} ->
          n = mk!(schema, "#{tag}#{i}", prev)
          {first || n, n}
        end)
      end

      {first_a, _} = chain.("a")
      {_, last_b} = chain.("b")

      assert {:ok, _} =
               Locations.move_node(schema, first_a["record_id"], last_b["record_id"], opts())

      assert length(Locations.descendant_ids(schema, last_b["record_id"])) == 50
    end

    test "M-04: under the current parent is a no-op with no event", %{schema: schema} do
      r = mk!(schema, "R")
      a = mk!(schema, "A", r)
      s = seq(schema, a)
      assert {:ok, _} = Locations.move_node(schema, a["record_id"], r["record_id"], opts())
      assert seq(schema, a) == s
    end

    test "X-01..X-08: refusals write nothing", %{schema: schema} do
      r = mk!(schema, "R")
      a = mk!(schema, "A", r)
      b = mk!(schema, "B", a)
      c = mk!(schema, "C", b)
      gone = mk!(schema, "G")
      delete!(schema, %{entity_type: "location_node", record_id: gone["record_id"]})
      retired = mk!(schema, "T")
      {:ok, _} = Locations.retire_node(schema, retired["record_id"], opts())
      before = seqs(schema)
      id = fn n -> n["record_id"] end

      assert {:error, :cycle} = Locations.move_node(schema, id.(a), id.(a), opts())
      assert {:error, :cycle} = Locations.move_node(schema, id.(a), id.(c), opts())

      for bad <- ["nope", Ecto.UUID.generate(), id.(gone)] do
        assert {:error, :parent_not_found} = Locations.move_node(schema, id.(a), bad, opts())
      end

      assert {:error, :parent_inactive} =
               Locations.move_node(schema, id.(a), id.(retired), opts())

      for bad <- ["nope", Ecto.UUID.generate(), id.(gone)] do
        assert {:error, :node_not_found} = Locations.move_node(schema, bad, id.(r), opts())
      end

      assert seqs(schema) == before
    end

    test "X-09: a damaged chain ends with :cycle", %{schema: schema} do
      x = mk!(schema, "X")
      y = mk!(schema, "Y", x)
      n = mk!(schema, "N")

      update!(
        schema,
        %{entity_type: "location_node", record_id: x["record_id"]},
        Map.put(values("location_node", "X", %{}), "parent_id", y["record_id"])
      )

      before = seqs(schema)

      assert {:error, :cycle} =
               Locations.move_node(schema, n["record_id"], x["record_id"], opts())

      assert seqs(schema) == before
    end
  end

  describe "update_node/4" do
    test "U-01: name, node_kind, segment, address are read back", %{schema: schema} do
      a = mk!(schema, "A")

      assert {:ok, u} =
               Locations.update_node(
                 schema,
                 a["record_id"],
                 %{"name" => "New", "node_kind" => "bin", "segment" => "s1", "address" => "x-1"},
                 opts()
               )

      assert %{"name" => "New", "node_kind" => "bin", "segment" => "s1", "address" => "x-1"} = u
      assert u["code"] == "A"
      assert u["active"] == true
    end

    test "U-02: other keys are refused", %{schema: schema} do
      a = mk!(schema, "A")
      before = seqs(schema)

      for key <- ~w(parent_id active code org_site_id ancestor_path depth bogus) do
        assert {:error, {:field_not_allowed, ^key}} =
                 Locations.update_node(schema, a["record_id"], %{key => "x"}, opts())
      end

      assert seqs(schema) == before
    end

    test "U-03/U-04: blank kind and dashed segment are invalid", %{schema: schema} do
      a = mk!(schema, "A")

      assert {:error, {:field_invalid, "node_kind"}} =
               Locations.update_node(schema, a["record_id"], %{"node_kind" => " "}, opts())

      assert {:error, {:field_invalid, "name"}} =
               Locations.update_node(schema, a["record_id"], %{"name" => nil}, opts())

      assert {:error, {:field_invalid, "segment"}} =
               Locations.update_node(schema, a["record_id"], %{"segment" => "a-b"}, opts())

      assert {:error, :node_not_found} =
               Locations.update_node(schema, Ecto.UUID.generate(), %{"name" => "x"}, opts())
    end

    test "U-05: a segment change leaves addresses alone; nil removes an optional", %{
      schema: schema
    } do
      r = mk!(schema, "R", nil, %{"segment" => "r", "address" => "r"})
      a = mk!(schema, "A", r, %{"address" => "r-a", "location_type" => "pick"})

      assert {:ok, u} =
               Locations.update_node(schema, r["record_id"], %{"segment" => "q"}, opts())

      assert u["address"] == "r"
      assert {:ok, %{"address" => "r-a"}} = Locations.lookup(schema, a["record_id"])

      assert {:ok, u2} =
               Locations.update_node(schema, a["record_id"], %{"location_type" => nil}, opts())

      refute Map.has_key?(u2, "location_type")
    end

    test "U-07: a duplicate address is a record error, nothing written", %{schema: schema} do
      _a = mk!(schema, "A", nil, %{"address" => "dup"})
      b = mk!(schema, "B")
      before = seqs(schema)

      assert {:error, {:record_payload_invalid, _}} =
               Locations.update_node(schema, b["record_id"], %{"address" => "dup"}, opts())

      assert seqs(schema) == before
    end
  end

  describe "retire_node/3" do
    test "R-01..R-05", %{schema: schema} do
      r = mk!(schema, "R")
      a = mk!(schema, "A", r)
      b = mk!(schema, "B", a)

      assert {:error, :has_active_descendants} =
               Locations.retire_node(schema, r["record_id"], opts())

      assert {:error, :has_active_descendants} =
               Locations.retire_node(schema, r["record_id"], opts())

      assert {:ok, %{"active" => false}} = Locations.retire_node(schema, b["record_id"], opts())

      assert {:error, :has_active_descendants} =
               Locations.retire_node(schema, r["record_id"], opts())

      assert {:ok, %{"active" => false}} = Locations.retire_node(schema, a["record_id"], opts())
      assert {:ok, %{"active" => false}} = Locations.retire_node(schema, r["record_id"], opts())

      s = seq(schema, r)
      assert {:ok, %{"active" => false}} = Locations.retire_node(schema, r["record_id"], opts())
      assert seq(schema, r) == s
      refute Locations.active?(schema, r["record_id"])
    end

    test "R-02b: an active grandchild below a retired child blocks", %{schema: schema} do
      r = mk!(schema, "R")
      a = mk!(schema, "A", r)
      _b = mk!(schema, "B", a)
      {:ok, _} = Locations.update_node(schema, a["record_id"], %{"name" => "n"}, opts())

      assert {:error, :has_active_descendants} =
               Locations.retire_node(schema, r["record_id"], opts())
    end

    test "R-06: no delete or un-retire function" do
      src = File.read!(@tree_path) <> File.read!(@locations_path)
      refute src =~ ~r/def\s+(delete_node|unretire|reactivate|restore)/
    end
  end

  describe "lock, replay, tenants, boundaries" do
    test "L-01/L-02: each write takes the lock first and holds an advisory lock", %{
      schema: schema
    } do
      src = File.read!(@tree_path)
      assert length(Regex.scan(~r/pg_advisory_xact_lock/, src)) == 1
      assert src =~ ~r/Repo\.transaction\(fn ->\s+lock!\(prefix\)/

      q = "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()"
      a = mk!(schema, "A")
      b = mk!(schema, "B")

      calls = [
        fn -> Locations.move_node(schema, a["record_id"], b["record_id"], opts()) end,
        fn -> Locations.update_node(schema, a["record_id"], %{"name" => "z"}, opts()) end,
        fn -> Locations.retire_node(schema, a["record_id"], opts()) end
      ]

      for call <- calls do
        {before, after_} =
          Repo.transaction(fn ->
            %{rows: [[before]]} = Repo.query!(q)
            {:ok, _} = call.()
            %{rows: [[after_]]} = Repo.query!(q)
            {before, after_}
          end)
          |> elem(1)

        assert after_ > before
      end
    end

    test "T-01..T-03: another tenant's node is unknown", %{schema: schema} do
      %{schema: other} = installed_tenant!("gh3588-tx")
      mine = mk!(schema, "A")
      theirs = mk!(other, "B")
      before = {seqs(schema), seqs(other)}
      unknown = Ecto.UUID.generate()

      assert {:error, :node_not_found} =
               Locations.move_node(other, mine["record_id"], nil, opts())

      assert {:error, :node_not_found} =
               Locations.move_node(other, unknown, nil, opts())

      assert {:error, :node_not_found} =
               Locations.update_node(other, mine["record_id"], %{"name" => "x"}, opts())

      assert {:error, :node_not_found} = Locations.retire_node(other, mine["record_id"], opts())

      assert {:error, :parent_not_found} =
               Locations.move_node(other, theirs["record_id"], mine["record_id"], opts())

      assert Locations.descendant_ids(other, mine["record_id"]) == []
      assert {seqs(schema), seqs(other)} == before
    end

    test "P-01..P-03: a repeated key returns the first result, no second event", %{schema: schema} do
      r = mk!(schema, "R")
      a = mk!(schema, "A")
      key = Ecto.UUID.generate()
      o = %{actor_id: Ecto.UUID.generate(), idempotency_key: key}

      assert {:ok, first} = Locations.move_node(schema, a["record_id"], r["record_id"], o)
      s = seq(schema, a)
      assert {:ok, again} = Locations.move_node(schema, a["record_id"], r["record_id"], o)
      assert again["parent_id"] == first["parent_id"]
      assert seq(schema, a) == s

      o2 = %{o | idempotency_key: Ecto.UUID.generate()}
      assert {:ok, _} = Locations.update_node(schema, a["record_id"], %{"name" => "Q"}, o2)
      s2 = seq(schema, a)

      assert {:ok, %{"name" => "Q"}} =
               Locations.update_node(schema, a["record_id"], %{"name" => "Q"}, o2)

      assert seq(schema, a) == s2

      o3 = %{o | idempotency_key: Ecto.UUID.generate()}
      assert {:ok, %{"active" => false}} = Locations.retire_node(schema, a["record_id"], o3)
      s3 = seq(schema, a)
      assert {:ok, %{"active" => false}} = Locations.retire_node(schema, a["record_id"], o3)
      assert seq(schema, a) == s3
    end

    test "G-02: the new functions take no principal or scope; manifest unchanged" do
      src = File.read!(@tree_path)

      refute src =~
               ~r/def\s+(move_node|update_node|retire_node|descendant_ids)\([^)]*(principal|scope)/

      assert Locations.manifest().version == "0.2.0"
    end
  end
end
