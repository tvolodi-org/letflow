defmodule Letflow.Entities.ManagedTypesTest do
  @moduledoc """
  REQ-496 / GH #2530 (decision 0050 D7; design
  `lib/letflow/design/req496-managed-by-and-scope-node-paths.md` §2.1-§2.5, §9 T-12, T-33, T-35;
  spec `test/specs/REQ-496.md`): the `managed_by` stamp and its guards below the HTTP layer.

    * T-12: the DB trigger refuses changing `managed_by` in either direction and deleting a
      stamped row; `EntityDefinition.changeset/2` never casts `:managed_by`;
      `EntityDefinition.put_managed_by/2` only stamps a NEW row.
    * T-33 (Revision 1 A1/A4/A6/A9): `create_definition/3` takes the per-(tenant, name) advisory
      lock (class 496001, two-int4 key) held to the end of the caller's transaction; names failing
      the managed-name format are `:unmanaged` with no query at all; `check_create/3` raises on an
      owner that is not `:tenant` or an `%Owner{}`; the trigger refuses renaming or re-tenanting a
      stamped row while a status flip passes.
    * T-35 (Revision 2): `lock_names/2` dedups, skips bad names and takes one lock per name; a pack
      install takes the locks of every packed name.
    * The `check_create/3` decision table (design §2.4), row by row.

  `async: false`: tenant provisioning switches the sandbox to `:auto`, and the lock assertions need
  real transactions on one connection.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.SolutionPack
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Modules.FixtureManaged
  alias Letflow.Modules.Installs
  alias Letflow.Repository.ArtifactVersion
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @lock_class 496_001

  defp tenant!(slug_prefix) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.tenant_id))
    end)

    tenant
  end

  defp installed_tenant!(slug_prefix) do
    tenant = tenant!(slug_prefix)
    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)

    {:ok, _tenant_module} =
      Installs.install("fixture_managed", Ecto.UUID.generate(),
        prefix: tenant.schema_name,
        rationale: "REQ-496 managed types test"
      )

    tenant
  end

  defp definition_attrs(name) do
    %{
      definition: %{
        name: name,
        display_name: "REQ-496 #{name}",
        fields: [%{name: "name", type: :string, required: true}]
      },
      created_by: Ecto.UUID.generate()
    }
  end

  # Advisory locks of the REQ-496 class held by THIS backend (the caller's transaction).
  defp held_create_locks do
    %{rows: [[n]]} =
      Repo.query!(
        """
        SELECT count(*) FROM pg_locks
        WHERE locktype = 'advisory' AND classid::bigint = $1 AND objsubid = 2
          AND granted AND pid = pg_backend_pid()
        """,
        [@lock_class]
      )

    n
  end

  defp stamped_row(schema, name) do
    Repo.one!(
      from(d in EntityDefinition,
        where: d.name == ^name and not is_nil(d.managed_by),
        limit: 1
      ),
      prefix: schema
    )
  end

  defp by_id(id), do: from(d in EntityDefinition, where: d.id == ^id)

  # ── T-12: immutability ──────────────────────────────────────────────────────────────────────

  describe "T-12 (AC2/AC3): managed_by is immutable once stamped" do
    test "the trigger refuses clearing, changing or setting managed_by and deleting a stamped row" do
      %{schema_name: schema} = installed_tenant!("req496-trigger")
      row = stamped_row(schema, "org_unit")
      assert row.managed_by == "fixture_managed"

      assert_raise Postgrex.Error, ~r/managed_by is immutable/, fn ->
        Repo.update_all(by_id(row.id), [set: [managed_by: nil]], prefix: schema)
      end

      assert_raise Postgrex.Error, ~r/managed_by is immutable/, fn ->
        Repo.update_all(by_id(row.id), [set: [managed_by: "another_module"]], prefix: schema)
      end

      assert_raise Postgrex.Error, ~r/managed_by is immutable/, fn ->
        Repo.delete_all(by_id(row.id), prefix: schema)
      end

      # "Any direction": an unmanaged row cannot be stamped after insert either.
      free = Repo.one!(from(d in EntityDefinition, where: d.name == "fxm_free"), prefix: schema)
      assert free.managed_by == nil

      assert_raise Postgrex.Error, ~r/managed_by is immutable/, fn ->
        Repo.update_all(by_id(free.id), [set: [managed_by: "fixture_managed"]], prefix: schema)
      end

      assert Repo.get!(EntityDefinition, row.id, prefix: schema).managed_by == "fixture_managed"
      assert Repo.get!(EntityDefinition, free.id, prefix: schema).managed_by == nil
    end

    test "changeset/2 never casts managed_by; put_managed_by/2 stamps only a new row" do
      attrs = %{
        tenant_id: Ecto.UUID.generate(),
        name: "x_type",
        display_name: "X",
        definition_json: %{},
        managed_by: "fixture_managed"
      }

      changeset = EntityDefinition.changeset(%EntityDefinition{}, attrs)
      assert Ecto.Changeset.get_change(changeset, :managed_by) == nil

      built =
        %EntityDefinition{} |> Ecto.Changeset.change() |> EntityDefinition.put_managed_by("m")

      assert Ecto.Changeset.get_change(built, :managed_by) == "m"
      assert built.valid?

      %{schema_name: schema} = installed_tenant!("req496-put-stamp")
      loaded = stamped_row(schema, "org_site")

      refused =
        loaded |> Ecto.Changeset.change() |> EntityDefinition.put_managed_by("another_module")

      refute refused.valid?
      assert {"is immutable", _} = refused.errors[:managed_by]
      assert Ecto.Changeset.get_change(refused, :managed_by) == nil
    end
  end

  # ── T-33 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-33 (AC2/AC3): create lock, format short-circuit, owner shape, rename guard" do
    test "create_definition/3 holds the 496001 two-int4 advisory lock until the caller's transaction ends" do
      %{schema_name: schema} = tenant!("req496-lock")

      assert {:error, :probe_done} =
               Repo.transaction(fn ->
                 assert held_create_locks() == 0

                 assert {:ok, %EntityDefinition{name: "org_unit"}} =
                          Definitions.create_definition(
                            definition_attrs("org_unit"),
                            schema,
                            :tenant
                          )

                 assert held_create_locks() == 1
                 Repo.rollback(:probe_done)
               end)

      # Released with the transaction.
      assert held_create_locks() == 0
    end

    test "a name failing the managed-name format is :unmanaged / :ok without any query" do
      %{schema_name: schema} = tenant!("req496-noquery")
      long = String.duplicate("a", 65)

      for name <- ["Org Unit", "a%", "a_%", long, "1abc", ""] do
        {results, queries} =
          PlatformTenantFixture.capture_repo_queries(fn ->
            {ManagedTypes.owner_of(name, schema), ManagedTypes.check_tenant_write(name, schema)}
          end)

        assert results == {:unmanaged, :ok}, inspect(name)
        assert queries == [], "#{inspect(name)} issued #{length(queries)} queries"
      end

      # Control: a format-valid name IS looked up, so the capture above can see a query.
      {_result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          ManagedTypes.owner_of("org_unit", schema)
        end)

      assert queries != []
    end

    test "check_create/3 raises FunctionClauseError for an owner that is not :tenant or %Owner{}" do
      %{schema_name: schema} = tenant!("req496-owner-shape")

      assert_raise FunctionClauseError, fn ->
        ManagedTypes.check_create(
          "org_unit",
          %{module_id: "fixture_managed", manages: MapSet.new(["org_unit"])},
          schema
        )
      end

      assert_raise FunctionClauseError, fn ->
        ManagedTypes.check_create("org_unit", "fixture_managed", schema)
      end
    end

    test "the trigger refuses renaming or re-tenanting a stamped row; a status flip passes" do
      %{schema_name: schema} = installed_tenant!("req496-rename")
      row = stamped_row(schema, "catalog_item")

      assert_raise Postgrex.Error, ~r/managed_by is immutable/, fn ->
        Repo.update_all(by_id(row.id), [set: [name: "catalog_item_renamed"]], prefix: schema)
      end

      assert_raise Postgrex.Error, ~r/managed_by is immutable/, fn ->
        Repo.update_all(by_id(row.id), [set: [tenant_id: Ecto.UUID.generate()]], prefix: schema)
      end

      assert {1, _} =
               Repo.update_all(by_id(row.id), [set: [status: :inactive]], prefix: schema)

      reloaded = Repo.get!(EntityDefinition, row.id, prefix: schema)
      assert reloaded.status == :inactive
      assert reloaded.managed_by == "fixture_managed"
      assert reloaded.name == "catalog_item"
    end
  end

  # ── T-35 (managed_types part) ───────────────────────────────────────────────────────────────

  describe "T-35 (AC3): sorted, deduplicated lock set" do
    test "lock_names/2 takes one lock per distinct format-valid name" do
      %{schema_name: schema} = tenant!("req496-lock-names")

      assert {:error, :probe_done} =
               Repo.transaction(fn ->
                 assert :ok =
                          ManagedTypes.lock_names(
                            ["b_type", "a_type", "b_type", "Bad Name"],
                            schema
                          )

                 assert held_create_locks() == 2
                 Repo.rollback(:probe_done)
               end)
    end

    test "a pack install holds the create lock of every packed entity name" do
      %{schema_name: schema} = tenant!("req496-pack-locks")

      document = %{
        "pack_id" => "req496-lock-pack-#{System.unique_integer([:positive])}",
        "version" => "1.0.0",
        "bpm_export_schema_version" => "bpm/definition/v1",
        "exported_at" => "2026-10-14T00:00:00Z",
        "manifest" => %{"required_roles" => []},
        "definitions" => [],
        "variable_schemas" => [],
        "service_catalog_entries" => [],
        "entity_definitions" => Enum.map(["b_type", "a_type"], &packed_entity/1)
      }

      assert {:error, :probe_done} =
               Repo.transaction(fn ->
                 assert {:ok, _result} =
                          SolutionPack.install(document, Ecto.UUID.generate(), prefix: schema)

                 assert held_create_locks() == 2
                 Repo.rollback(:probe_done)
               end)
    end
  end

  defp packed_entity(name) do
    %{
      "entity_definition_id" => Ecto.UUID.generate(),
      "name" => name,
      "display_name" => name,
      "logical_shape_version" => Base.encode16(:crypto.hash(:sha256, name), case: :lower),
      "definition_json" => %{
        "name" => name,
        "display_name" => name,
        "fields" => [%{"name" => "name", "type" => "string", "required" => true}]
      }
    }
  end

  # ── check_create/3 decision table (design §2.4) ─────────────────────────────────────────────

  describe "check_create/3 decision table" do
    test "rows with a managed name: only the owning module, for a name it declares, may create" do
      %{schema_name: schema} = installed_tenant!("req496-table-managed")
      owner = ManagedTypes.module_owner(FixtureManaged)
      other = ManagedTypes.module_owner(Letflow.Modules.Fixture)

      assert ManagedTypes.owner_of("org_unit", schema) == {:ok, "fixture_managed"}
      assert ManagedTypes.check_tenant_write("org_unit", schema) == {:error, :entity_type_managed}

      # {:ok, m} + :tenant
      assert ManagedTypes.check_create("org_unit", :tenant, schema) ==
               {:error, :entity_type_managed}

      # {:ok, m} + %Owner{module_id: m} declaring the name
      assert ManagedTypes.check_create("org_unit", owner, schema) == {:ok, "fixture_managed"}

      # {:ok, m} + any other %Owner{}
      assert ManagedTypes.check_create("org_unit", other, schema) ==
               {:error, :entity_type_managed}

      # :unmanaged + :tenant (fxm_free exists, unstamped)
      assert ManagedTypes.owner_of("fxm_free", schema) == :unmanaged
      assert ManagedTypes.check_create("fxm_free", :tenant, schema) == {:ok, nil}

      # :unmanaged + %Owner{} for a name it does NOT declare
      assert ManagedTypes.check_create("fxm_free", owner, schema) == {:ok, nil}

      # A non-binary name is left to the Validator.
      assert ManagedTypes.check_create(123, :tenant, schema) == {:ok, nil}
      assert ManagedTypes.check_create(nil, owner, schema) == {:ok, nil}
    end

    test "rows with an unmanaged name: a module claims it only when no row of the name exists" do
      %{schema_name: schema} = tenant!("req496-table-claim")
      owner = ManagedTypes.module_owner(FixtureManaged)

      assert MapSet.member?(owner.manages, "org_site")
      assert owner.module_id == "fixture_managed"

      # :unmanaged + declaring %Owner{} + no row -> stamped
      assert ManagedTypes.check_create("org_site", owner, schema) == {:ok, "fixture_managed"}

      # :unmanaged + declaring %Owner{} + a tenant's own unmanaged row -> taken
      assert {:ok, _own} = Definitions.create_definition(definition_attrs("org_site"), schema)

      assert ManagedTypes.check_create("org_site", owner, schema) ==
               {:error, {:managed_name_taken, "org_site"}}

      # The tenant's own type is never locked by that attempt.
      assert ManagedTypes.owner_of("org_site", schema) == :unmanaged
    end

    test "module_owner/1 reads the compiled manifest; absent manages_entity_types is empty" do
      assert %ManagedTypes.Owner{module_id: "fixture_managed", manages: manages} =
               ManagedTypes.module_owner(FixtureManaged)

      assert MapSet.equal?(
               manages,
               MapSet.new([
                 "org_legal_entity",
                 "org_site",
                 "org_unit",
                 "org_unit_membership",
                 "catalog_item",
                 "catalog_uom",
                 "fxm_ledger"
               ])
             )

      assert %ManagedTypes.Owner{module_id: "fixture", manages: none} =
               ManagedTypes.module_owner(Letflow.Modules.Fixture)

      assert MapSet.size(none) == 0
    end
  end

  # ── GH #2583 T-10 / T-29 ────────────────────────────────────────────────────────────────────
  #
  # Design `lib/letflow/design/gh2583-records-managed-type-guard.md` sections 1 (D8, premise P),
  # 3.1-3.3 and 10 (T-10, T-29); spec `test/specs/GH-2583.md`.

  @seven [
    "org_legal_entity",
    "org_site",
    "org_unit",
    "org_unit_membership",
    "catalog_item",
    "catalog_uom",
    "fxm_ledger"
  ]

  describe "GH #2583 T-10 (AC2): check_record_write/3 and owner_for!/1" do
    test "check_record_write/3 follows the design section 3.2 table row by row" do
      owner = ManagedTypes.owner_for!(FixtureManaged)
      other = %ManagedTypes.Owner{module_id: "other_module", manages: MapSet.new(["org_unit"])}

      # nil + :tenant / nil + any Owner
      assert ManagedTypes.check_record_write(nil, "fxm_free", :tenant) == :ok
      assert ManagedTypes.check_record_write(nil, "fxm_free", owner) == :ok
      assert ManagedTypes.check_record_write(nil, "fxm_free", other) == :ok

      # m + :tenant
      assert ManagedTypes.check_record_write("fixture_managed", "org_unit", :tenant) ==
               {:error, :entity_type_managed}

      # m + %Owner{module_id: m} naming the type
      assert ManagedTypes.check_record_write("fixture_managed", "org_unit", owner) == :ok

      # m + %Owner{module_id: m} NOT naming the type
      assert ManagedTypes.check_record_write("fixture_managed", "fxm_free", owner) ==
               {:error, :entity_type_managed}

      # m + %Owner{module_id: other} (even though it names the type)
      assert ManagedTypes.check_record_write("fixture_managed", "org_unit", other) ==
               {:error, :entity_type_managed}
    end

    test "check_record_write/3 raises FunctionClauseError for a non-authority third argument" do
      bad = [
        "fixture_managed",
        %{module_id: "fixture_managed", manages: MapSet.new(["org_unit"])},
        nil,
        :owner
      ]

      for authority <- bad, managed_by <- [nil, "fixture_managed"] do
        assert_raise FunctionClauseError, fn ->
          ManagedTypes.check_record_write(managed_by, "org_unit", authority)
        end
      end
    end

    test "owner_for!/1 returns module_owner/1's struct for a registered module declaring managed types" do
      assert ManagedTypes.owner_for!(FixtureManaged) == ManagedTypes.module_owner(FixtureManaged)
      assert ManagedTypes.owner_for!(FixtureManaged).module_id == "fixture_managed"
    end

    test "owner_for!/1 raises for an unregistered module, a module without managed types and a non-atom" do
      # Registered, but its manifest declares no managed types.
      assert_raise ArgumentError, ~r/declares no managed entity types/, fn ->
        ManagedTypes.owner_for!(Letflow.Modules.Fixture)
      end

      # Not a Catalog entry module: refused BEFORE manifest/0 is called (Records has none, so
      # reversing the two checks would raise UndefinedFunctionError instead).
      assert_raise ArgumentError, ~r/not a registered Catalog entry module/, fn ->
        ManagedTypes.owner_for!(Letflow.Entities.Records)
      end

      assert_raise FunctionClauseError, fn -> ManagedTypes.owner_for!("fixture_managed") end
    end
  end

  describe "GH #2583 T-29 (AC2): premise P, the row Records resolves for a managed name carries its stamp" do
    test "every version under a managed artifact name is a stamped row of that name; tenant creates cannot add one" do
      %{schema_name: schema} = installed_tenant!("gh2583-premise")

      for name <- @seven do
        version_ids =
          Repo.all(
            from(v in ArtifactVersion,
              where: v.artifact_kind == :entity and v.artifact_name == ^name,
              select: v.version_id
            ),
            prefix: schema
          )

        assert version_ids != [], "#{name}: no artifact version"

        rows =
          Repo.all(
            from(d in EntityDefinition, where: d.artifact_version_id in ^version_ids),
            prefix: schema
          )

        assert length(rows) == length(version_ids), "#{name}: a version without its row"

        for row <- rows do
          assert row.managed_by == "fixture_managed", "#{name}: unstamped version row"
          assert row.name == name
        end

        # P1 in the other direction: every row named `name` sits under the artifact `name`.
        named_versions =
          Repo.all(
            from(d in EntityDefinition,
              join: v in ArtifactVersion,
              on: v.version_id == d.artifact_version_id,
              where: d.name == ^name,
              select: {v.artifact_kind, v.artifact_name}
            ),
            prefix: schema
          )

        assert Enum.uniq(named_versions) == [{:entity, name}]

        {:ok, active} = Definitions.get_active_definition_by_name(name, schema)
        assert active.managed_by == "fixture_managed", "#{name}: active row unstamped"
      end

      # P2: a tenant create of a NEW shape under a managed name adds neither a version nor a row.
      versions_before = artifact_version_count(schema, "org_unit")

      rows_before =
        Repo.aggregate(from(d in EntityDefinition, where: d.name == "org_unit"), :count,
          prefix: schema
        )

      new_shape = %{
        definition: %{
          name: "org_unit",
          display_name: "Tenant org unit",
          fields: [
            %{name: "name", type: :string, required: true},
            %{name: "tenant_extra", type: :string}
          ]
        },
        created_by: Ecto.UUID.generate()
      }

      assert Definitions.create_definition(new_shape, schema) == {:error, :entity_type_managed}
      assert artifact_version_count(schema, "org_unit") == versions_before

      assert Repo.aggregate(from(d in EntityDefinition, where: d.name == "org_unit"), :count,
               prefix: schema
             ) == rows_before

      # Re-activating the name can only (re)activate a stamped row.
      case Definitions.activate_definition(
             "org_unit",
             Ecto.UUID.generate(),
             "gh2583 t-29",
             schema
           ) do
        {:ok, %EntityDefinition{} = promoted} -> assert promoted.managed_by == "fixture_managed"
        {:error, _reason} -> :ok
      end

      {:ok, active} = Definitions.get_active_definition_by_name("org_unit", schema)
      assert active.managed_by == "fixture_managed"
    end
  end

  defp artifact_version_count(schema, name) do
    Repo.aggregate(
      from(v in ArtifactVersion, where: v.artifact_kind == :entity and v.artifact_name == ^name),
      :count,
      prefix: schema
    )
  end
end
