defmodule Letflow.Entities.QuerySelfJoinTest do
  @moduledoc """
  REQ-324 (S10 gap 14) -- empirical check of `Letflow.Entities.Query.Compiler`'s
  REQ-300 join path for a self-referential `fk_def` (same entity type on both
  sides of the join, needing distinct binding names). See
  `docs/requirements.yaml`'s REQ-324 entry, open question 4.

  Mirrors `test/letflow/entities/query_joins_test.exs`'s own fixture pattern
  (DIRECTIVE T-1/T-4: real Postgres, self-contained tenant provisioning) --
  generic entity/field names only, per 0022 rule 1.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.Query.Compiler
  alias Letflow.Entities.Records
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion
  alias Letflow.TenantProvisioning.Registration

  import Ecto.Query

  # ---------------------------------------------------------------------------------
  # Fixtures -- provisions via Letflow.TenantFixture (ISS-0112 / GH#366),
  # teardown: false because this file's own on_exit also deletes its
  # domain-specific ColumnPromotion rows before the Tenant row (needed:
  # entity_column_promotions.tenant_id has on_delete: :nothing, so it must
  # be cleared before Tenant is deleted or the standard fixture teardown's
  # own Tenant delete would violate the FK).
  # ---------------------------------------------------------------------------------

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp provisioned_tenant do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "req324-self-join",
        display_name: "REQ-324 Self-Join Test Tenant",
        teardown: false
      )

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant_id) do
        {:ok, schema_name} -> drop_schema!(schema_name)
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant_id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
    end)

    assert {:ok, _seed_result} = Letflow.Entities.EventTypes.seed!(schema_name)

    %{tenant_id: tenant_id, schema_name: schema_name}
  end

  defp create_active_definition!(schema, definition) do
    assert {:ok, entity_definition} =
             Definitions.create_definition(
               %{definition: definition, created_by: Ecto.UUID.generate()},
               schema
             )

    assert {:ok, activated} =
             Definitions.activate_definition(
               entity_definition.name,
               Ecto.UUID.generate(),
               "go-live",
               schema
             )

    activated
  end

  defp create_record!(schema, entity_type, field_values) do
    attrs = %{
      entity_type: entity_type,
      field_values: field_values,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate()
    }

    assert {:ok, %{record: record}} = Records.create_record(attrs, schema)
    record
  end

  defp promote_and_create_table!(schema, tenant_id, entity_type, attribute, pg_type, opts \\ []) do
    references_entity = Keyword.get(opts, :references_entity)

    column_spec =
      if references_entity do
        %{pg_type: pg_type, nullable: true, references_entity: references_entity}
      else
        %{pg_type: pg_type, nullable: true}
      end

    assert {:ok, [row]} =
             TenantProvisioning.register_column_promotion(
               entity_type,
               attribute,
               column_spec,
               [tenant_id]
             )

    assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
             TenantProvisioning.run_column_promotion(row.id)

    assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type(entity_type)
    table_name
  end

  # Seeds a "node" entity type carrying a self-referential fk_def
  # ("parent_fk") whose references_entity is its own name -- the generic
  # parent/child-tree shape REQ-324 lifts Rule 9 for.
  defp seed_self_referential_node!(schema, tenant_id) do
    create_active_definition!(schema, %{
      name: "node",
      display_name: "Node",
      fields: [
        %{name: "label", type: :string, queried: true},
        %{name: "parent_id", type: :string}
      ],
      foreign_keys: [
        %{name: "parent_fk", field: "parent_id", references_entity: "node"}
      ]
    })

    promote_and_create_table!(schema, tenant_id, "node", "label", "text")

    promote_and_create_table!(schema, tenant_id, "node", "parent_id", "uuid",
      references_entity: "node"
    )

    :ok
  end

  describe "REQ-324 open question 4 -- self-join over a self-referential fk_def" do
    test "compile/2 produces a real self-join (distinct primary/join bindings against the same physical table)" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()
      seed_self_referential_node!(schema, tenant_id)

      request = %{
        entity_type: "node",
        join: [%{entity_type: "node", fk: "parent_fk"}]
      }

      assert {:ok, %Ecto.Query{joins: joins} = query} = Compiler.compile(request, schema, :all)
      assert [%Ecto.Query.JoinExpr{qual: :inner}] = joins
      assert %Ecto.Query{} = query
    end

    test "a self-join's ON condition is correct against real fixture data -- each child row pairs with its own parent, never a sibling's" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()
      seed_self_referential_node!(schema, tenant_id)

      root = create_record!(schema, "node", %{"label" => "root"})
      unrelated_root = create_record!(schema, "node", %{"label" => "unrelated-root"})

      child =
        create_record!(schema, "node", %{"label" => "child", "parent_id" => root.record_id})

      unrelated_child =
        create_record!(schema, "node", %{
          "label" => "unrelated-child",
          "parent_id" => unrelated_root.record_id
        })

      # No `filters` here -- see the next test/this file's moduledoc-adjacent
      # comment for why a primary-side filter is a SEPARATE, pre-existing
      # gap this requirement does not fix. This test isolates and proves
      # the ON-condition fix alone, against real data, with no filter in
      # the way.
      request = %{
        entity_type: "node",
        join: [%{entity_type: "node", fk: "parent_fk"}]
      }

      assert {:ok, query} = Compiler.compile(request, schema, :all)

      rows = Repo.all(query, prefix: schema)
      by_primary_label = Map.new(rows, &{&1.primary.field_values["label"], &1})

      assert by_primary_label["child"]["node"].field_values["label"] == "root"
      assert by_primary_label["unrelated-child"]["node"].field_values["label"] == "unrelated-root"
    end

    test "REQ-324 follow-on (not fixed here) -- a primary-side filter on a self-join hits Postgres ambiguous_column: see this test's body comment" do
      # promoted_column_dynamic/typed_column_dynamic emit an unqualified
      # column fragment that assumes the primary is the query's only
      # binding -- true for compile_plain and for every REQ-300 join test
      # to date (no filtered field name ever collided with a joined-in
      # column name), but never true for a self-join, where every column
      # name is shared by construction. See this file's moduledoc-adjacent
      # note and REQ-324's completion report for the named follow-on.
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()
      seed_self_referential_node!(schema, tenant_id)

      _root = create_record!(schema, "node", %{"label" => "root"})

      request = %{
        entity_type: "node",
        filters: [%{field: "label", op: :eq, value: "root"}],
        join: [%{entity_type: "node", fk: "parent_fk"}]
      }

      assert {:ok, query} = Compiler.compile(request, schema, :all)

      assert_raise Postgrex.Error, ~r/ambiguous_column/, fn ->
        Repo.all(query, prefix: schema)
      end
    end
  end
end
