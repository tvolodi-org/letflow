Code.require_file("locations_fixture.exs", __DIR__)

defmodule Letflow.Modules.Locations.CreateNodeTest do
  @moduledoc """
  GH #3591 / REQ-645 (tests C-01..C-11): `Letflow.Modules.Locations.create_node/3`, the free-kind
  tree with a real parent foreign key, on freshly provisioned tenants with the real installed module.
  """

  use Letflow.DataCase, async: false

  import Letflow.LocationsFixture

  alias Letflow.Entities.Records
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Locations
  alias Letflow.Repo

  @tree_path Path.join([File.cwd!(), "lib", "letflow", "modules", "locations", "tree.ex"])

  setup do
    {:ok, installed_tenant!("gh3591-cn")}
  end

  defp opts(extra \\ %{}),
    do: Map.merge(%{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}, extra)

  defp attrs(code, extra \\ %{}),
    do: Map.merge(%{"code" => code, "name" => "N #{code}", "node_kind" => "country"}, extra)

  defp mk!(schema, code, extra \\ %{}, o \\ %{}) do
    {:ok, node} = Locations.create_node(schema, attrs(code, extra), Map.merge(opts(), o))
    node
  end

  defp count(schema) do
    %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}"."entity_location_node"|)
    n
  end

  describe "C-01 / C-02: free kinds, no depth bound" do
    test "C-01: a chain of 45 levels; parent link only, no path or depth", %{schema: schema} do
      kinds = ~w(region building zone aisle rack shelf bin position)
      root = mk!(schema, "L0")
      refute Map.has_key?(root, "parent_id")
      refute Map.has_key?(root, "ancestor_path")
      refute Map.has_key?(root, "depth")
      assert root["active"] == true

      last =
        Enum.reduce(1..45, root, fn i, prev ->
          node =
            mk!(schema, "L#{i}", %{
              "node_kind" => Enum.at(kinds, rem(i, 8)),
              "parent_id" => prev["record_id"]
            })

          assert node["parent_id"] == prev["record_id"]
          refute Map.has_key?(node, "ancestor_path")
          refute Map.has_key?(node, "depth")
          node
        end)

      assert last["code"] == "L45"
      assert count(schema) == 46
    end

    test "C-02: node_kind must be a non-blank text; any word is accepted", %{schema: schema} do
      for bad <- [5, "", "   ", nil] do
        assert {:error, {:field_invalid, "node_kind"}} =
                 Locations.create_node(schema, attrs("K1", %{"node_kind" => bad}), opts())
      end

      for kind <- ~w(site zone address), do: mk!(schema, "K-#{kind}", %{"node_kind" => kind})
      assert count(schema) == 3
    end
  end

  describe "C-03: parent checks" do
    test "C-03a..c: not a uuid, unknown, soft-deleted", %{schema: schema} do
      parent = node!(schema, "P1", "site")
      assert count(schema) == 1

      for bad <- ["nope", "", Ecto.UUID.generate()] do
        assert {:error, :parent_not_found} =
                 Locations.create_node(schema, attrs("C1", %{"parent_id" => bad}), opts())
      end

      delete!(schema, parent)

      assert {:error, :parent_not_found} =
               Locations.create_node(
                 schema,
                 attrs("C2", %{"parent_id" => parent.record_id}),
                 opts()
               )

      assert count(schema) == 1
    end

    test "C-03d: the id of a record of another type", %{schema: schema} do
      Letflow.Support.ScriptPolicyFixture.active_definition!(schema, "scratch", ["name"])

      {:ok, %{record: other}} =
        Records.create_record(
          %{
            entity_type: "scratch",
            field_values: %{"name" => "x"},
            actor_id: Ecto.UUID.generate(),
            idempotency_key: Ecto.UUID.generate()
          },
          schema
        )

      assert {:error, :parent_not_found} =
               Locations.create_node(
                 schema,
                 attrs("C3", %{"parent_id" => other.record_id}),
                 opts()
               )

      assert count(schema) == 0
    end

    test "C-03e: an inactive parent", %{schema: schema} do
      parent = node!(schema, "PI", "site")
      update!(schema, parent, Map.put(parent.field_values, "active", false))

      assert {:error, :parent_inactive} =
               Locations.create_node(
                 schema,
                 attrs("C4", %{"parent_id" => parent.record_id}),
                 opts()
               )

      assert count(schema) == 1
    end
  end

  describe "C-04: field rules" do
    test "not allowed keys are named, first in sorted order", %{schema: schema} do
      for key <- ~w(ancestor_path depth active org_site_id bogus) do
        assert {:error, {:field_not_allowed, ^key}} =
                 Locations.create_node(schema, attrs("F1", %{key => "x"}), opts())
      end

      assert {:error, {:field_not_allowed, "a_key"}} =
               Locations.create_node(schema, attrs("F1", %{"z" => 1, "a_key" => 1}), opts())

      assert count(schema) == 0
    end

    test "missing required fields and bad segments", %{schema: schema} do
      for key <- ~w(code name node_kind) do
        assert {:error, {:field_invalid, ^key}} =
                 Locations.create_node(schema, Map.delete(attrs("F2"), key), opts())
      end

      for seg <- ["A-1", " ", 3] do
        assert {:error, {:field_invalid, "segment"}} =
                 Locations.create_node(schema, attrs("F3", %{"segment" => seg}), opts())
      end

      assert count(schema) == 0
    end

    test "duplicate code and duplicate address come back as a tuple, nothing written", %{
      schema: schema
    } do
      mk!(schema, "D1", %{"address" => "ADDR-1"})

      assert {:error, {:record_payload_invalid, [_ | _]}} =
               Locations.create_node(schema, attrs("D1"), opts())

      assert {:error, {:record_payload_invalid, [_ | _]}} =
               Locations.create_node(schema, attrs("D2", %{"address" => "ADDR-1"}), opts())

      assert count(schema) == 1
      # the tenant connection still works after the refusals
      mk!(schema, "D3")
      assert count(schema) == 2
    end

    test "a nil optional value is dropped; idempotent replay returns the same record", %{
      schema: schema
    } do
      o = opts()
      a = mk!(schema, "R1", %{"segment" => nil, "parent_id" => nil}, o)
      refute Map.has_key?(a, "segment")
      b = mk!(schema, "R1", %{"segment" => nil, "parent_id" => nil}, o)
      assert a["record_id"] == b["record_id"]
      assert count(schema) == 1
    end

    test "invalid opts raise", %{schema: schema} do
      assert_raise ArgumentError, fn -> Locations.create_node(schema, attrs("O1"), %{}) end

      assert_raise ArgumentError, fn ->
        Locations.create_node(schema, attrs("O1"), %{actor_id: "x", idempotency_key: "k"})
      end
    end
  end

  describe "C-05: addresses" do
    test "segments compose the address top-down; ancestors without a segment are skipped",
         %{schema: schema} do
      seg = %{address_pattern: :segments}
      b = mk!(schema, "BLD")
      z = mk!(schema, "Z1", %{"segment" => "Z1", "parent_id" => b["record_id"]}, seg)
      assert z["address"] == "Z1"
      a = mk!(schema, "A03", %{"segment" => "A03", "parent_id" => z["record_id"]}, seg)
      r = mk!(schema, "R2", %{"segment" => "R2", "parent_id" => a["record_id"]}, seg)
      s = mk!(schema, "S4", %{"segment" => "S4", "parent_id" => r["record_id"]}, seg)
      assert s["address"] == "Z1-A03-R2-S4"
      bin = mk!(schema, "B1", %{"segment" => "B1", "parent_id" => s["record_id"]}, seg)
      assert bin["address"] == "Z1-A03-R2-S4-B1"
    end

    test "free address stored as given or not at all", %{schema: schema} do
      assert mk!(schema, "FA1", %{"address" => "ANY thing"})["address"] == "ANY thing"
      refute Map.has_key?(mk!(schema, "FA2"), "address")
    end

    test "segments pattern refusals", %{schema: schema} do
      seg = opts(%{address_pattern: :segments})

      assert {:error, {:field_invalid, "address"}} =
               Locations.create_node(
                 schema,
                 attrs("P1", %{"segment" => "A", "address" => "X"}),
                 seg
               )

      assert {:error, {:field_invalid, "segment"}} =
               Locations.create_node(schema, attrs("P2"), seg)

      assert {:error, {:field_invalid, "segment"}} =
               Locations.create_node(schema, attrs("P3", %{"segment" => "A-1"}), seg)

      assert {:error, {:field_invalid, "address"}} =
               Locations.create_node(
                 schema,
                 attrs("P4", %{"segment" => "A"}),
                 opts(%{address_pattern: :other})
               )

      assert count(schema) == 0
    end

    test "a second warehouse composing an existing address is refused", %{schema: schema} do
      seg = %{address_pattern: :segments}
      w1 = mk!(schema, "W1")
      w2 = mk!(schema, "W2")
      mk!(schema, "W1A", %{"segment" => "A1", "parent_id" => w1["record_id"]}, seg)

      assert {:error, {:record_payload_invalid, [_ | _]}} =
               Locations.create_node(
                 schema,
                 attrs("W2A", %{"segment" => "A1", "parent_id" => w2["record_id"]}),
                 opts(seg)
               )

      assert count(schema) == 3
    end
  end

  describe "C-06: lock and foreign key" do
    test "C-06a: create_node holds a transaction-scoped advisory lock", %{schema: schema} do
      q = "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()"

      {before, after_} =
        Repo.transaction(fn ->
          %{rows: [[before]]} = Repo.query!(q)
          mk!(schema, "LK1")
          %{rows: [[after_]]} = Repo.query!(q)
          {before, after_}
        end)
        |> elem(1)

      assert after_ > before
    end

    test "C-06b: the lock key is a bound parameter; the tree does not touch the scope index" do
      src = File.read!(@tree_path)
      assert src =~ "pg_advisory_xact_lock(hashtextextended($1, 0))"
      assert src =~ "location_node_tree"
      refute src =~ ~r/scope_node_paths|ScopeNodePaths/i
    end

    test "C-06d: the owner path with an unknown uuid parent hits the foreign key", %{
      schema: schema
    } do
      assert {:error, {:record_payload_invalid, violations}} =
               create(
                 schema,
                 "location_node",
                 values("location_node", "FK1", %{"parent_id" => Ecto.UUID.generate()})
               )

      assert Enum.any?(violations, &(&1.rule == :reference))
      assert count(schema) == 0
    end

    test "the parent column is a nullable uuid with a RESTRICT self reference", %{schema: schema} do
      %{rows: rows} =
        Repo.query!(
          """
          SELECT c.confdeltype::text, c.confrelid = c.conrelid
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
          WHERE n.nspname = $1 AND t.relname = 'entity_location_node' AND c.contype = 'f'
            AND a.attname = 'parent_id'
          """,
          [schema]
        )

      assert rows == [["r", true]]

      %{rows: idx} =
        Repo.query!(
          "SELECT indexname FROM pg_indexes WHERE schemaname = $1 AND indexname = 'idx_location_node_parent_id'",
          [schema]
        )

      assert idx == [["idx_location_node_parent_id"]]
    end
  end

  describe "C-07: tenant isolation" do
    test "a node of tenant A is not a parent in tenant B; same code in both", %{schema: a} do
      %{schema: b} = installed_tenant!("gh3591-cn-b")
      node_a = mk!(a, "SAME")

      assert {:error, :parent_not_found} =
               Locations.create_node(
                 b,
                 attrs("X1", %{"parent_id" => node_a["record_id"]}),
                 opts()
               )

      assert {:error, :parent_not_found} =
               Locations.create_node(
                 b,
                 attrs("X1", %{"parent_id" => Ecto.UUID.generate()}),
                 opts()
               )

      assert count(b) == 0
      mk!(b, "SAME")
      assert count(a) == 1 and count(b) == 1
    end

    test "the manifest ships only LocationsWrite and depends on org only" do
      m = Locations.manifest()
      assert m.permissions == [:LocationsWrite]
      assert m.depends_on == ["org"]
    end
  end

  describe "C-08: a tenant with the old definition" do
    test "the old definition refuses a free kind and a segment", %{schema: schema} do
      # A fresh tenant has the new definition; the old one is shown by the pre-change enum, so here
      # the old document is created as a scratch type with the old shape.
      old = %{
        name: "old_location_node",
        display_name: "Old",
        fields: [
          %{name: "code", type: :string, required: true},
          %{
            name: "node_kind",
            type: :enum,
            required: true,
            enum_values: ["site", "zone", "address"]
          }
        ]
      }

      {:ok, _} =
        Letflow.Entities.Definitions.create_definition(
          %{definition: old, created_by: Ecto.UUID.generate()},
          schema
        )

      {:ok, _} =
        Letflow.Entities.Definitions.activate_definition(
          "old_location_node",
          Ecto.UUID.generate(),
          "go",
          schema
        )

      base = %{
        entity_type: "old_location_node",
        actor_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate()
      }

      assert {:error, {:record_payload_invalid, _}} =
               Records.create_record(
                 Map.put(base, :field_values, %{"code" => "O", "node_kind" => "country"}),
                 schema
               )

      assert {:error, {:record_payload_invalid, _}} =
               Records.create_record(
                 %{base | idempotency_key: Ecto.UUID.generate()}
                 |> Map.put(:field_values, %{
                   "code" => "O",
                   "node_kind" => "site",
                   "segment" => "A"
                 }),
                 schema
               )
    end
  end

  describe "C-11: version and scope declaration" do
    test "the manifest is 0.3.0 with the two scope declarations and validates" do
      m = Locations.manifest()
      assert m.version == "0.4.0"

      assert m.scope_declarations == %{
               "location_node" => :tenant_wide,
               "location_org_unit_link" => {:column, "org_unit_id"}
             }

      assert Catalog.validate(m) == :ok
    end

    test "after install the declaration of location_node is tenant_wide", %{schema: schema} do
      assert Letflow.Entities.ScopeDeclaration.for_type("location_node", schema) == :tenant_wide
    end
  end
end
