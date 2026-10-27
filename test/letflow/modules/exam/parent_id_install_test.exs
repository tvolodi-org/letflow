defmodule Letflow.Modules.Exam.ParentIdInstallTest do
  @moduledoc """
  REQ-586 part A (GH #3315), criterion 2 (I1) and the raw-SQL RESTRICT proofs (R1, R2): the exam
  module installed through `Letflow.Modules.Installs.install/3`, its ten authoring types activated
  in the unchanged dependency order, then `category` and `question` promoted so their tables are
  created. `parent_id` must be a nullable uuid with a self-referencing foreign key
  `ON DELETE RESTRICT` (`pg_constraint.confdeltype = 'r'`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EventTypes
  alias Letflow.Modules.Installs
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion

  @activation_order ~w(
    category tag exam
    question exam_section
    answer_option question_tag exam_question_rule
    exam_question_rule_tag exam_manual_question
  )

  defp installed_tenant do
    fixture =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "req586-install",
        display_name: "REQ-586 install test tenant"
      )

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^fixture.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^fixture.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^fixture.tenant_id))
    end)

    {:ok, _seeded} = EventTypes.seed!(fixture.schema_name)
    actor_id = Ecto.UUID.generate()

    assert {:ok, _tenant_module} =
             Installs.install("exam", actor_id,
               prefix: fixture.schema_name,
               rationale: "test: REQ-586 install"
             )

    for entity_type <- @activation_order do
      assert {:ok, %EntityDefinition{status: :active}} =
               Definitions.activate_definition(
                 entity_type,
                 actor_id,
                 "REQ-586",
                 fixture.schema_name
               )
    end

    promote!(fixture.tenant_id, "category", "sort_order", "bigint")
    promote!(fixture.tenant_id, "question", "category_id", "uuid", references_entity: "category")

    %{tenant_id: fixture.tenant_id, schema_name: fixture.schema_name}
  end

  defp promote!(tenant_id, entity_type, attribute, pg_type, opts \\ []) do
    spec =
      case Keyword.get(opts, :references_entity) do
        nil -> %{pg_type: pg_type, nullable: true}
        target -> %{pg_type: pg_type, nullable: true, references_entity: target}
      end

    assert {:ok, [row]} =
             TenantProvisioning.register_column_promotion(entity_type, attribute, spec, [
               tenant_id
             ])

    assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
             TenantProvisioning.run_column_promotion(row.id)
  end

  defp parent_id_column(schema_name, table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT format_type(a.atttypid, a.atttypmod), a.attnotnull
        FROM pg_attribute a
        JOIN pg_class t ON t.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = $1 AND t.relname = $2 AND a.attname = 'parent_id' AND NOT a.attisdropped
        """,
        [schema_name, table]
      )

    rows
  end

  defp parent_id_foreign_keys(schema_name, table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.confdeltype::text, c.confrelid = c.conrelid
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
        WHERE n.nspname = $1 AND t.relname = $2 AND c.contype = 'f' AND a.attname = 'parent_id'
        """,
        [schema_name, table]
      )

    rows
  end

  defp insert_row!(schema_name, table, record_id, parent_id) do
    Repo.query!(
      "INSERT INTO #{schema_name}.#{table} (id, record_id, last_event_global_seq, inserted_at, updated_at, parent_id) VALUES (gen_random_uuid(), $1, 1, now(), now(), $2)",
      [Ecto.UUID.dump!(record_id), parent_id && Ecto.UUID.dump!(parent_id)]
    )
  end

  defp delete_row(schema_name, table, record_id) do
    Repo.query("DELETE FROM #{schema_name}.#{table} WHERE record_id = $1", [
      Ecto.UUID.dump!(record_id)
    ])
  end

  describe "I1 install shape" do
    test "category and question get a nullable uuid parent_id with a self-FK ON DELETE RESTRICT" do
      ctx = installed_tenant()

      for table <- ["entity_category", "entity_question"] do
        assert [["uuid", false]] = parent_id_column(ctx.schema_name, table)
        assert [["r", true]] = parent_id_foreign_keys(ctx.schema_name, table)
      end
    end
  end

  describe "R1 / R2 raw SQL RESTRICT" do
    for {type, table} <- [{"category", "entity_category"}, {"question", "entity_question"}] do
      test "#{type}: deleting a referenced row is a foreign_key_violation; a leaf deletes" do
        ctx = installed_tenant()
        table = unquote(table)
        parent = Ecto.UUID.generate()
        child = Ecto.UUID.generate()
        insert_row!(ctx.schema_name, table, parent, nil)
        insert_row!(ctx.schema_name, table, child, parent)

        assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
                 delete_row(ctx.schema_name, table, parent)

        assert {:ok, %{num_rows: 1}} = delete_row(ctx.schema_name, table, child)
        assert {:ok, %{num_rows: 1}} = delete_row(ctx.schema_name, table, parent)
      end
    end
  end
end
