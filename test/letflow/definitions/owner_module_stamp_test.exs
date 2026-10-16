defmodule Letflow.Definitions.OwnerModuleStampTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R2 (design `lib/letflow/design/gh2590-req501-module-write-handlers.md`
  4.2, 4.8, 4.10, D-R.8, D-R.15, INV-R1, INV-R2; section 11 R2 rows): the ownership stamp of
  a module-shipped process definition version is STORAGE only.

    * it exists only by install (`Installs.install/3` -> `SolutionPack.install/4` ->
      `Definitions.create_owned/3`), four columns in the one INSERT;
    * it cannot be forged (no cast list, no tenant create path, the CHECK) or edited (the
      application refusal and the immutability trigger, both directions);
    * `OwnerStamp.graph_hash/1` of the graph before the insert equals the hash of the JSONB
      row read back and of the snapshot copy (F-9);
    * `tenant_modules.manifest_hash` records the install-time manifest hash.

  Nothing consumes the stamp yet: no activation check, no execution.

  `async: false`: tenant provisioning switches the sandbox to `:auto` and the install runs DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions
  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Definitions.OwnerStamp
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.SnapshotStore
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.FixtureLedger
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @graph %{
    "nodes" => [
      %{"id" => "start", "node_type" => "START"},
      %{"id" => "end", "node_type" => "END"}
    ],
    "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
  }

  @forged %{
    owner_module: "fixture_ledger",
    owner_module_version: "9.9.9",
    owner_manifest_hash: String.duplicate("a", 64),
    owner_body_hash: String.duplicate("b", 64)
  }

  @weird %{
    "floats" => [1.0, 0.1, 100.0, 1.0e-7, 1.5e20, 1.0e16, 1.2345678901234567e16, -0.0, 3.14159],
    "ints" => [1, 0, -7, 9_007_199_254_740_993, 12_345_678_901_234_567_890],
    "nested" => %{"b" => [%{"z" => 1.0, "a" => nil}, "s", true], "a" => %{"k" => 2.5e-3}},
    "atom_value" => :an_atom,
    "text" => "ünïcode \" \\ ok"
  }

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2590-r2-stamp")

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.tenant_id))
    end)

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    {:ok, schema: tenant.schema_name, tenant_id: tenant.tenant_id}
  end

  defp install_ledger(schema) do
    assert {:ok, %TenantModule{} = tm} =
             Installs.install("fixture_ledger", Ecto.UUID.generate(),
               prefix: schema,
               rationale: "GH 2590 R2 stamp test"
             )

    tm
  end

  defp fetch_by_name(schema, name) do
    Repo.one!(from(d in ProcessDefinition, where: d.name == ^name), prefix: schema)
  end

  defp raw(schema, sql, params) do
    Repo.query(String.replace(sql, "$S", ~s("#{schema}")), params)
  end

  defp stamp_columns(schema, id) do
    %{rows: [row]} =
      Repo.query!(
        "SELECT owner_module, owner_module_version, owner_manifest_hash, owner_body_hash " <>
          ~s(FROM "#{schema}"."process_definitions" WHERE id = $1),
        [Ecto.UUID.dump!(id)]
      )

    row
  end

  defp owner, do: ManagedTypes.module_owner(FixtureLedger)

  defp create_owned!(schema, attrs, owner \\ owner()) do
    base = %{
      name: "gh2590-r2-#{System.unique_integer([:positive])}",
      version: "1.0.0",
      graph: @graph,
      created_by: Ecto.UUID.generate()
    }

    assert {:ok, %ProcessDefinition{} = row} =
             Definitions.create_owned(Map.merge(base, attrs), [prefix: schema], owner)

    row
  end

  defp plain!(schema, name) do
    assert {:ok, %ProcessDefinition{} = row} =
             Definitions.create(
               %{name: name, version: "1", graph: @graph, created_by: Ecto.UUID.generate()},
               prefix: schema
             )

    row
  end

  describe "install stamps the pack's process definition" do
    test "all four columns are written in the INSERT, from the compiled manifest and the graph",
         %{schema: schema} do
      install_ledger(schema)
      row = fetch_by_name(schema, "fxl_post")
      {:ok, manifest_hash} = Catalog.manifest_hash(FixtureLedger)

      assert row.owner_module == "fixture_ledger"
      assert row.owner_module_version == FixtureLedger.manifest().version
      assert row.owner_manifest_hash == manifest_hash
      assert row.owner_body_hash == OwnerStamp.graph_hash(row.graph)
      assert row.status == :draft

      assert stamp_columns(schema, row.id) ==
               [
                 "fixture_ledger",
                 FixtureLedger.manifest().version,
                 manifest_hash,
                 row.owner_body_hash
               ]

      assert {:ok, stamp} = OwnerStamp.from_row(row)
      assert stamp.module_id == "fixture_ledger"
    end

    test "tenant_modules.manifest_hash records the same manifest hash", %{schema: schema} do
      tm = install_ledger(schema)
      {:ok, manifest_hash} = Catalog.manifest_hash("fixture_ledger")

      assert tm.manifest_hash == manifest_hash
      assert Repo.get!(TenantModule, tm.id, prefix: schema).manifest_hash == manifest_hash

      assert Installs.installed_manifest_hash("fixture_ledger", prefix: schema) ==
               {:ok, manifest_hash}

      assert fetch_by_name(schema, "fxl_post").owner_manifest_hash == manifest_hash
    end

    test "OQ-R7: a module installed before the column has no installed hash (no backfill)",
         %{schema: schema} do
      assert Installs.installed_manifest_hash("fixture_ledger", prefix: schema) ==
               {:error, :not_installed}

      tm = install_ledger(schema)

      {1, _} =
        Repo.update_all(
          from(m in TenantModule, where: m.id == ^tm.id),
          [set: [manifest_hash: nil]],
          prefix: schema
        )

      assert Installs.installed_manifest_hash("fixture_ledger", prefix: schema) ==
               {:error, :no_installed_hash}
    end

    test "a tenant-created version of the same name is unstamped and cannot inherit the stamp",
         %{schema: schema} do
      install_ledger(schema)

      assert {:ok, %ProcessDefinition{} = copy} =
               Definitions.create(
                 %{
                   name: "fxl_post",
                   version: "1.1.0",
                   graph: @graph,
                   created_by: Ecto.UUID.generate()
                 },
                 prefix: schema
               )

      assert stamp_columns(schema, copy.id) == [nil, nil, nil, nil]
      assert OwnerStamp.from_row(copy) == :none
    end
  end

  describe "the stamp cannot be forged" do
    test "no changeset casts a stamp field (both changesets, atom and string keys)" do
      base = %{name: "n", version: "1", graph: @graph, created_by: Ecto.UUID.generate()}
      string_forged = Map.new(@forged, fn {k, v} -> {Atom.to_string(k), v} end)

      string_base = Map.new(base, fn {k, v} -> {Atom.to_string(k), v} end)

      for attrs <- [Map.merge(base, @forged), Map.merge(string_base, string_forged)],
          changeset_fun <- [
            &ProcessDefinition.create_changeset/2,
            &ProcessDefinition.update_changeset/2
          ] do
        cs = changeset_fun.(%ProcessDefinition{}, attrs)

        for field <- Map.keys(@forged) do
          refute Map.has_key?(cs.changes, field)
        end
      end
    end

    test "Definitions.create/2 with stamp keys in attrs writes an unstamped row",
         %{schema: schema} do
      attrs =
        Map.merge(
          %{name: "forge-1", version: "1", graph: @graph, created_by: Ecto.UUID.generate()},
          @forged
        )

      assert {:ok, %ProcessDefinition{id: id}} = Definitions.create(attrs, prefix: schema)
      assert stamp_columns(schema, id) == [nil, nil, nil, nil]
    end

    test "create_owned(:tenant) and an owner without stamp inputs create unstamped rows",
         %{schema: schema} do
      tenant_row = create_owned!(schema, %{}, :tenant)
      bare = %{owner() | version: nil, manifest_hash: nil}
      bare_row = create_owned!(schema, %{}, bare)

      assert stamp_columns(schema, tenant_row.id) == [nil, nil, nil, nil]
      assert stamp_columns(schema, bare_row.id) == [nil, nil, nil, nil]
    end

    test "the CHECK refuses a partial stamp (raw INSERT with one column set)", %{schema: schema} do
      sql =
        "INSERT INTO $S.process_definitions " <>
          "(id, name, version, status, graph, created_by, sequence_number, created_at, " <>
          "updated_at, owner_module) " <>
          "VALUES ($1, 'partial', '1', 'draft', '{\"nodes\":[],\"edges\":[]}', $2, 0, now(), now(), 'm')"

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation} = pg}} =
               raw(schema, sql, [Ecto.UUID.bingenerate(), Ecto.UUID.bingenerate()])

      assert pg.constraint == "process_definitions_owner_stamp_all_or_none"
    end

    test "the trigger refuses stamping an existing unstamped row (NULL -> value)",
         %{schema: schema} do
      plain = plain!(schema, "forge-2")

      sql =
        "UPDATE $S.process_definitions SET owner_module = 'fixture_ledger', " <>
          "owner_module_version = '1', owner_manifest_hash = $1, owner_body_hash = $1 " <>
          "WHERE id = $2"

      assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
               raw(schema, sql, [String.duplicate("c", 64), Ecto.UUID.dump!(plain.id)])

      assert message =~ "immutable"
      assert stamp_columns(schema, plain.id) == [nil, nil, nil, nil]
    end

    test "update_all of a stamped row's owner_* is refused for every column and for NULL",
         %{schema: schema} do
      row = create_owned!(schema, %{})
      before = stamp_columns(schema, row.id)

      for {column, value} <- [
            {"owner_module", "other"},
            {"owner_module_version", "9"},
            {"owner_manifest_hash", String.duplicate("d", 64)},
            {"owner_body_hash", String.duplicate("e", 64)}
          ] do
        sql = "UPDATE $S.process_definitions SET #{column} = $1 WHERE id = $2"

        assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
                 raw(schema, sql, [value, Ecto.UUID.dump!(row.id)])

        assert message =~ "immutable"
      end

      # value -> NULL for all four: the one change the CHECK allows, which the trigger refuses.
      sql =
        "UPDATE $S.process_definitions SET owner_module = NULL, owner_module_version = NULL, " <>
          "owner_manifest_hash = NULL, owner_body_hash = NULL WHERE id = $1"

      assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
               raw(schema, sql, [Ecto.UUID.dump!(row.id)])

      assert message =~ "immutable"
      assert stamp_columns(schema, row.id) == before
    end

    test "update_all of a stamped row's graph is refused; status and activated_by pass",
         %{schema: schema} do
      row = create_owned!(schema, %{})

      assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
               raw(
                 schema,
                 "UPDATE $S.process_definitions SET graph = '{\"nodes\":[],\"edges\":[]}' WHERE id = $1",
                 [Ecto.UUID.dump!(row.id)]
               )

      assert message =~ "immutable"

      assert {:ok, %{num_rows: 1}} =
               raw(
                 schema,
                 "UPDATE $S.process_definitions SET status = 'active', activated_by = '{}' WHERE id = $1",
                 [Ecto.UUID.dump!(row.id)]
               )

      assert Repo.get!(ProcessDefinition, row.id, prefix: schema).graph == row.graph
    end

    test "an unstamped row is not affected by the trigger", %{schema: schema} do
      plain = plain!(schema, "forge-3")

      assert {:ok, %{num_rows: 1}} =
               raw(
                 schema,
                 "UPDATE $S.process_definitions SET description = 'x' WHERE id = $1",
                 [Ecto.UUID.dump!(plain.id)]
               )
    end
  end

  describe "a stamped version is immutable to Definitions.update/3" do
    test "update (PUT and PATCH shapes) answers :module_owned_definition and writes nothing",
         %{schema: schema} do
      row = create_owned!(schema, %{})

      for attrs <- [
            %{name: row.name, version: row.version, graph: @graph, description: "x", stage: nil},
            %{description: "patched"},
            %{variable_schemas: []}
          ] do
        assert {:error, :module_owned_definition} =
                 Definitions.update(row.id, attrs, prefix: schema)
      end

      assert Repo.get!(ProcessDefinition, row.id, prefix: schema).description == row.description
    end

    test "an unstamped draft still updates; an activated stamped row stays :not_draft",
         %{schema: schema} do
      plain = plain!(schema, "upd-1")

      assert {:ok, %ProcessDefinition{description: "ok"}} =
               Definitions.update(plain.id, %{description: "ok"}, prefix: schema)

      stamped = create_owned!(schema, %{})
      assert {:ok, %{definition: active}} = Definitions.activate(stamped.id, prefix: schema)
      assert active.owner_module == "fixture_ledger"
      assert active.owner_body_hash == stamped.owner_body_hash

      assert {:error, :not_draft} =
               Definitions.update(stamped.id, %{description: "late"}, prefix: schema)
    end

    test "the definition.create audit state carries the module but never the hashes",
         %{schema: schema} do
      row = create_owned!(schema, %{})

      %{rows: [[after_state]]} =
        Repo.query!(
          ~s(SELECT after_state FROM "#{schema}"."audit_entries" ) <>
            "WHERE action = 'definition.create' AND resource_id = $1",
          [row.id]
        )

      assert after_state["owner_module"] == "fixture_ledger"
      assert after_state["owner_module_version"] == FixtureLedger.manifest().version
      refute Map.has_key?(after_state, "owner_manifest_hash")
      refute Map.has_key?(after_state, "owner_body_hash")
    end
  end

  describe "graph_hash/1 is one function over the JSONB-normalised form (F-9)" do
    test "pre-insert hash == stored body hash == JSONB row read-back == snapshot copy",
         %{schema: schema} do
      graph = Map.put(@graph, "annotations", @weird)
      pre_insert = OwnerStamp.graph_hash(graph)

      row = create_owned!(schema, %{graph: graph})
      assert row.owner_body_hash == pre_insert
      assert OwnerStamp.graph_hash(row.graph) == pre_insert

      reread = Repo.get!(ProcessDefinition, row.id, prefix: schema)
      assert OwnerStamp.graph_hash(reread.graph) == pre_insert

      instance_id = Ecto.UUID.generate()

      assert {:ok, %InstanceDefinitionSnapshot{} = snap} =
               SnapshotStore.create(instance_id, row.id, prefix: schema)

      assert OwnerStamp.graph_hash(snap.graph) == pre_insert

      %{rows: [[raw_graph]]} =
        Repo.query!(
          ~s(SELECT graph FROM "#{schema}"."instance_definition_snapshots" WHERE instance_id = $1),
          [Ecto.UUID.dump!(instance_id)]
        )

      assert OwnerStamp.graph_hash(raw_graph) == pre_insert
    end

    test "key order, atom keys and map insertion do not change the hash" do
      a = %{"x" => 1, "y" => %{"p" => 1.5, "q" => [1, 2]}}
      b = Jason.decode!(~s({"y":{"q":[1,2],"p":1.5},"x":1}))
      c = %{x: 1, y: %{p: 1.5, q: [1, 2]}}

      assert OwnerStamp.graph_hash(a) == OwnerStamp.graph_hash(b)
      assert OwnerStamp.graph_hash(a) == OwnerStamp.graph_hash(c)
    end

    test "a changed value changes the hash; 1 and 1.0 stay distinct (as stored)" do
      refute OwnerStamp.graph_hash(%{"v" => 1}) == OwnerStamp.graph_hash(%{"v" => 1.0})
      refute OwnerStamp.graph_hash(%{"v" => 1}) == OwnerStamp.graph_hash(%{"v" => 2})
      assert OwnerStamp.graph_hash(%{"v" => -0.0}) == OwnerStamp.graph_hash(%{"v" => 0.0})
    end

    test "a large float is the integer Postgres numeric reads back" do
      assert OwnerStamp.graph_hash(%{"v" => 1.0e20}) ==
               OwnerStamp.graph_hash(%{"v" => 100_000_000_000_000_000_000})
    end
  end
end
