defmodule Letflow.Modules.InstallActivationTest do
  @moduledoc """
  GH 2531, decision 0052: a module's `on_install/3` activates and promotes its
  packed entity definitions inside the install transaction.

    * D7 (go/no-go): a two-entity FK pack installed through `Installs.install/3`
      leaves both tables and the `REFERENCES` constraint after commit; after a
      forced failure in `on_install/3` (AFTER activation and promotion ran) no
      table, constraint, definition, promotion row or `tenant_modules` row remains.
    * D3: a module exporting both arities runs ONLY `on_install/3`; `ctx` carries
      the installer and the rationale; the activation trail records the installer
      as activator and the rationale verbatim. `opts[:rationale]` is required.
    * D5: a promotion left `pending` or `ddl_failed` fails the install and rolls back.
    * D6: a same-name definition the tenant already has fails the install with
      `{:entity_name_conflict, name}` and rolls back; an already-active definition
      is not activated again.

  `async: false`: tenant provisioning and DDL (same reasoning as `installs_test.exs`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Modules.EntityActivation
  alias Letflow.Modules.FixtureCtxRecorder
  alias Letflow.Modules.FixtureFkPack
  alias Letflow.Modules.FixtureFkPackFailing
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule
  alias Letflow.Repository.ActivationHistory
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion

  @names ["fkp_parent", "fkp_child"]
  @rationale "  GH 2531 test install: org pack go-live (installer's own words)  "

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2531")

    # solution_pack_installs, solution_pack_artefact_bases and entity_column_promotions
    # are GLOBAL tables with an FK to tenants; TenantFixture's teardown deletes the tenant
    # and knows nothing about them. Registered after the fixture's on_exit, so it runs
    # first (same arrangement as test/letflow/modules/exam/pack_install_test.exs).
    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.tenant_id))
    end)

    Process.delete({FixtureFkPack, :on_install_2_called})
    Process.delete({FixtureFkPack, :on_install_3_ctx})
    Process.delete({FixtureFkPackFailing, :promoted_before_failure})
    Process.delete({FixtureCtxRecorder, :ctx})
    {:ok, tenant: tenant, actor_id: Ecto.UUID.generate()}
  end

  # --- catalogue helpers -------------------------------------------------------------------------

  defp table_exists?(schema, table) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2",
        [schema, table]
      )

    n == 1
  end

  # Foreign keys of `table` in `schema`, as {constraint_name, referenced_table}.
  defp foreign_keys(schema, table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.conname, rt.relname
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_class rt ON rt.oid = c.confrelid
        WHERE c.contype = 'f' AND n.nspname = $1 AND t.relname = $2
        """,
        [schema, table]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  defp unique_constraint_count(schema, table) do
    %{rows: [[n]]} =
      Repo.query!(
        """
        SELECT count(*) FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.contype = 'u' AND n.nspname = $1 AND t.relname = $2
        """,
        [schema, table]
      )

    n
  end

  defp definitions(schema) do
    Repo.all(from(d in EntityDefinition, where: d.name in ^@names, select: {d.name, d.status}),
      prefix: schema
    )
  end

  defp promotions(tenant_id) do
    Repo.all(
      from(p in ColumnPromotion,
        where: p.tenant_id == ^tenant_id and p.entity_type in ^@names,
        select: {p.entity_type, p.attribute, p.status}
      )
    )
  end

  defp tenant_modules(schema), do: Repo.all(TenantModule, prefix: schema)

  # --- D7 -----------------------------------------------------------------------------------------

  describe "D7 go/no-go: activation and promotion inside the install transaction" do
    test "(a) after commit both tables and the REFERENCES constraint exist; both definitions are active",
         %{tenant: %{schema_name: schema, tenant_id: tenant_id}, actor_id: actor_id} do
      assert {:ok, %TenantModule{module_id: "fixture_fk_pack"}} =
               Installs.install("fixture_fk_pack", actor_id,
                 prefix: schema,
                 rationale: @rationale
               )

      assert table_exists?(schema, "entity_fkp_parent")
      assert table_exists?(schema, "entity_fkp_child")
      assert [{_name, "entity_fkp_parent"}] = foreign_keys(schema, "entity_fkp_child")
      assert unique_constraint_count(schema, "entity_fkp_parent") >= 1
      assert unique_constraint_count(schema, "entity_fkp_child") >= 1

      assert Enum.sort(definitions(schema)) == [{"fkp_child", :active}, {"fkp_parent", :active}]

      statuses = promotions(tenant_id) |> Enum.map(&elem(&1, 2)) |> Enum.uniq()
      assert statuses != []
      refute Enum.any?(statuses, &(&1 in ["pending", "ddl_failed"]))
    end

    test "(b) a failure in on_install/3 AFTER activation and promotion leaves no table, constraint, definition, promotion or tenant_modules row",
         %{tenant: %{schema_name: schema, tenant_id: tenant_id}, actor_id: actor_id} do
      assert {:error, {:on_install_failed, :forced_after_promotion}} =
               Installs.install("fixture_fk_pack_failing", actor_id,
                 prefix: schema,
                 rationale: @rationale
               )

      # activation and promotion really ran inside the transaction before the failure
      assert Process.get({FixtureFkPackFailing, :promoted_before_failure}) == true

      refute table_exists?(schema, "entity_fkp_parent")
      refute table_exists?(schema, "entity_fkp_child")
      assert foreign_keys(schema, "entity_fkp_child") == []
      assert definitions(schema) == []
      assert promotions(tenant_id) == []
      assert tenant_modules(schema) == []
    end
  end

  # --- D3 -----------------------------------------------------------------------------------------

  describe "D3: on_install/3, ctx and the rationale" do
    test "a module exporting both arities runs ONLY on_install/3, with the installer and the rationale in ctx",
         %{tenant: %{schema_name: schema}, actor_id: actor_id} do
      assert {:ok, _} =
               Installs.install("fixture_fk_pack", actor_id,
                 prefix: schema,
                 rationale: @rationale
               )

      assert Process.get({FixtureFkPack, :on_install_2_called}) == nil

      assert %{actor_id: ^actor_id, rationale: @rationale, pack_entity_definition_ids: ids} =
               Process.get({FixtureFkPack, :on_install_3_ctx})

      # D6 origin: exactly the definitions this install's pack inserted, by id.
      assert ids |> Map.keys() |> Enum.sort() == ["fkp_child", "fkp_parent"]

      for {name, id} <- ids do
        assert %EntityDefinition{name: ^name, status: :active} =
                 Repo.get!(EntityDefinition, id, prefix: schema)
      end
    end

    test "the activation trail records the installer as activator and the rationale verbatim",
         %{tenant: %{schema_name: schema}, actor_id: actor_id} do
      assert {:ok, _} =
               Installs.install("fixture_fk_pack", actor_id,
                 prefix: schema,
                 rationale: @rationale
               )

      history =
        Repo.all(
          from(h in ActivationHistory,
            where: h.artifact_name in ^@names,
            select: {h.artifact_name, h.activator_user_id, h.rationale}
          ),
          prefix: schema
        )

      assert Enum.sort(history) == [
               {"fkp_child", actor_id, @rationale},
               {"fkp_parent", actor_id, @rationale}
             ]
    end

    test "missing, nil, non-string and blank rationale give {:error, :rationale_required} and install nothing",
         %{tenant: %{schema_name: schema, tenant_id: tenant_id}, actor_id: actor_id} do
      for opts <- [
            [prefix: schema],
            [prefix: schema, rationale: nil],
            [prefix: schema, rationale: 42],
            [prefix: schema, rationale: ""],
            [prefix: schema, rationale: " \t\n "]
          ] do
        assert {:error, :rationale_required} = Installs.install("fixture_fk_pack", actor_id, opts),
               inspect(opts)
      end

      assert tenant_modules(schema) == []
      assert definitions(schema) == []
      assert promotions(tenant_id) == []
    end

    test "a solution install of two modules applies ONE rationale to both (ctx and activation trail)",
         %{tenant: %{schema_name: schema}, actor_id: actor_id} do
      assert {:ok, installed} =
               Letflow.Modules.Solutions.install("fixture-activation-bundle", actor_id,
                 prefix: schema,
                 rationale: @rationale
               )

      assert installed |> Enum.map(& &1.module_id) |> Enum.sort() ==
               ["fixture_ctx_recorder", "fixture_fk_pack"]

      assert %{actor_id: ^actor_id, rationale: @rationale} =
               Process.get({FixtureFkPack, :on_install_3_ctx})

      # the pack-less module gets the same installer and rationale, and no pack ids
      assert Process.get({FixtureCtxRecorder, :ctx}) == %{
               actor_id: actor_id,
               rationale: @rationale,
               pack_entity_definition_ids: %{}
             }

      rationales =
        Repo.all(
          from(h in ActivationHistory, where: h.artifact_name in ^@names, select: h.rationale),
          prefix: schema
        )

      assert rationales == [@rationale, @rationale]
    end

    test "the exam seed task's fixed, reviewed rationale is a valid install rationale" do
      rationale = Mix.Tasks.Letflow.Seed.ExamFixtures.install_rationale()
      assert {:ok, ^rationale} = Installs.fetch_rationale(rationale: rationale)
      assert rationale =~ "seed"
    end

    test "a solution install without a rationale is {:error, :rationale_required} and installs nothing",
         %{tenant: %{schema_name: schema}, actor_id: actor_id} do
      assert {:error, :rationale_required} =
               Letflow.Modules.Solutions.install("fixture-activation-bundle", actor_id,
                 prefix: schema
               )

      assert tenant_modules(schema) == []
      assert Process.get({FixtureCtxRecorder, :ctx}) == nil
    end
  end

  # --- D5 -----------------------------------------------------------------------------------------

  describe "D5: an incomplete promotion fails the install" do
    for status <- ["pending", "ddl_failed"] do
      test "a #{status} promotion row for one of the pack's columns rolls the install back",
           %{tenant: %{schema_name: schema, tenant_id: tenant_id}, actor_id: actor_id} do
        status = unquote(status)

        {:ok, [planted]} =
          TenantProvisioning.register_column_promotion(
            "fkp_child",
            "code",
            %{pg_type: "text", nullable: true},
            [tenant_id]
          )

        if status == "ddl_failed" do
          Repo.update_all(from(p in ColumnPromotion, where: p.id == ^planted.id),
            set: [status: "ddl_failed", last_error: "planted by GH 2531 test"]
          )
        end

        assert {:error, {:on_install_failed, {:promotion_incomplete, incomplete}}} =
                 Installs.install("fixture_fk_pack", actor_id,
                   prefix: schema,
                   rationale: @rationale
                 )

        assert {"fkp_child", "code", status} in incomplete
        assert tenant_modules(schema) == []
        assert definitions(schema) == []
        refute table_exists?(schema, "entity_fkp_child")
        # only the planted row (committed before the install) is left
        assert promotions(tenant_id) == [{"fkp_child", "code", status}]
      end
    end
  end

  # --- D6 -----------------------------------------------------------------------------------------

  describe "D6: preconditions and idempotency" do
    test "a tenant-created INACTIVE definition of the same name gives {:entity_name_conflict, name}, rolls back, and leaves it inactive and untouched",
         %{tenant: %{schema_name: schema, tenant_id: tenant_id}, actor_id: actor_id} do
      tenant_definition = %{
        name: "fkp_parent",
        display_name: "Tenant's own parent (draft)",
        fields: [%{name: "label", type: :string}]
      }

      assert {:ok, %EntityDefinition{id: own_id} = before} =
               Definitions.create_definition(
                 %{definition: tenant_definition, created_by: actor_id},
                 schema
               )

      assert before.status == :inactive
      stored_before = Repo.get!(EntityDefinition, own_id, prefix: schema)

      assert {:error, {:on_install_failed, {:entity_name_conflict, "fkp_parent"}}} =
               Installs.install("fixture_fk_pack", actor_id,
                 prefix: schema,
                 rationale: @rationale
               )

      assert tenant_modules(schema) == []
      assert [{"fkp_parent", :inactive}] = definitions(schema)
      after_row = Repo.get!(EntityDefinition, own_id, prefix: schema)
      assert after_row.status == :inactive
      assert after_row == stored_before
      assert promotions(tenant_id) == []
      refute table_exists?(schema, "entity_fkp_parent")
    end

    test "a tenant-created ACTIVE definition of the same name gives {:entity_name_conflict, name}, rolls back, and leaves the tenant's definition untouched",
         %{tenant: %{schema_name: schema, tenant_id: tenant_id}, actor_id: actor_id} do
      tenant_definition = %{
        name: "fkp_parent",
        display_name: "Tenant's own parent",
        fields: [%{name: "label", type: :string}]
      }

      assert {:ok, %EntityDefinition{id: own_id}} =
               Definitions.create_definition(
                 %{definition: tenant_definition, created_by: actor_id},
                 schema
               )

      assert {:ok, _} =
               Definitions.activate_definition("fkp_parent", actor_id, "tenant's own", schema)

      result =
        Installs.install("fixture_fk_pack", actor_id, prefix: schema, rationale: @rationale)

      assert result == {:error, {:on_install_failed, {:entity_name_conflict, "fkp_parent"}}}

      assert tenant_modules(schema) == []
      assert [{"fkp_parent", :active}] = definitions(schema)
      assert Repo.get!(EntityDefinition, own_id, prefix: schema).status == :active
      assert promotions(tenant_id) |> Enum.filter(&(elem(&1, 0) == "fkp_child")) == []
    end

    test "activate_and_promote/3 never adopts a definition the pack did not insert, even an active one with a matching id",
         %{tenant: %{schema_name: schema, tenant_id: tenant_id}, actor_id: actor_id} do
      definition = %{
        name: "fkp_parent",
        display_name: "Parent",
        fields: [%{name: "code", type: :string, queried: true, required: true}],
        constraints: [%{name: "uq_fkp_parent_code", type: :unique, fields: ["code"]}]
      }

      assert {:ok, %EntityDefinition{id: tenant_row_id}} =
               Definitions.create_definition(
                 %{definition: definition, created_by: actor_id},
                 schema
               )

      assert {:ok, _} = Definitions.activate_definition("fkp_parent", actor_id, "first", schema)

      history_count = fn ->
        Repo.aggregate(
          from(h in ActivationHistory, where: h.artifact_name == "fkp_parent"),
          :count,
          prefix: schema
        )
      end

      before = history_count.()
      table_before = table_exists?(schema, "entity_fkp_parent")
      promotions_before = promotions(tenant_id)

      # not in the pack's ids at all
      assert {:error, {:entity_definition_missing, "fkp_parent"}} =
               EntityActivation.activate_and_promote(
                 schema,
                 %{actor_id: actor_id, rationale: "r", pack_entity_definition_ids: %{}},
                 ["fkp_parent"]
               )

      # even if a caller passed that row's id, an active row is never the pack's own
      assert {:error, {:entity_name_conflict, "fkp_parent"}} =
               EntityActivation.activate_and_promote(
                 schema,
                 %{
                   actor_id: actor_id,
                   rationale: "r",
                   pack_entity_definition_ids: %{"fkp_parent" => tenant_row_id}
                 },
                 ["fkp_parent"]
               )

      # nothing activated again, no new table or promotion
      assert history_count.() == before
      assert table_exists?(schema, "entity_fkp_parent") == table_before
      assert promotions(tenant_id) == promotions_before
    end

    test "activate_and_promote/3 with no definition of the name gives {:entity_definition_missing, name}",
         %{tenant: %{schema_name: schema}, actor_id: actor_id} do
      assert {:error, {:entity_definition_missing, "fkp_parent"}} =
               EntityActivation.activate_and_promote(
                 schema,
                 %{actor_id: actor_id, rationale: "r"},
                 ["fkp_parent"]
               )
    end
  end
end
