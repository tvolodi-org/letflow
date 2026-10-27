defmodule Letflow.Modules.Exam.ParentRolloutTest do
  @moduledoc """
  REQ-586 part C (GH #3315): the rollout that brings a tenant installed BEFORE part A to the
  `parent_id` shape of `category` and `question` (`Letflow.Modules.Exam.ParentRollout`,
  `Letflow.Release.ExamParentId`), against real provisioned tenants. Test ids follow the design
  (P1..P17).

  Every real run targets one schema through `run_tenant/2`: a real `run/1` sweep would upgrade the
  other tests' tenants, so only `run(dry_run: true)` is used for the sweep shape.

  An "old" tenant is built by installing the exam module (stamped `managed_by "exam"`), activating
  the authoring types, replacing the active `category` / `question` definitions by versions without
  `parent_id`, and creating their tables from those versions.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Exam
  alias Letflow.Modules.Exam.Authoring
  alias Letflow.Modules.Exam.DefinitionDocument
  alias Letflow.Modules.Exam.ParentRollout
  alias Letflow.Modules.Installs
  alias Letflow.Release.ExamParentId, as: Release
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
  @types ["category", "question"]
  @definitions_dir Path.expand("../../../../priv/modules/exam/entity_definitions", __DIR__)

  # ── fixtures ───────────────────────────────────────────────────────────────────────────────

  defp provisioned!(slug) do
    fixture = TenantFixture.provisioned_tenant!(slug_prefix: slug)

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^fixture.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^fixture.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^fixture.tenant_id))
    end)

    {:ok, _seeded} = EventTypes.seed!(fixture.schema_name)
    %{tenant_id: fixture.tenant_id, schema_name: fixture.schema_name}
  end

  # mode: :stamped (active versions managed_by "exam"), :unstamped (a legacy row, managed_by nil),
  # :other_module (managed_by "other_module"), :other_shape (stamped, with a parent_id of type integer).
  defp old_tenant!(slug, mode \\ :stamped) do
    tenant = provisioned!(slug)
    schema = tenant.schema_name
    actor = Ecto.UUID.generate()

    assert {:ok, _module_row} =
             Installs.install("exam", actor, prefix: schema, rationale: "test: REQ-586 part C")

    for type <- @activation_order do
      assert {:ok, %EntityDefinition{status: :active}} =
               Definitions.activate_definition(type, actor, "REQ-586 C", schema)
    end

    for type <- @types, do: downgrade!(schema, type, mode)

    promote!(tenant.tenant_id, "category", "sort_order", "bigint")
    promote!(tenant.tenant_id, "question", "category_id", "uuid", "category")
    tenant
  end

  defp downgrade!(schema, type, mode) do
    {:ok, active} = Definitions.get_active_definition_by_name(type, schema)
    {:ok, doc} = DefinitionDocument.from_stored(active.definition_json)

    doc =
      doc
      |> Map.update!(:fields, fn fields -> Enum.reject(fields, &(&1.name == "parent_id")) end)
      |> Map.update(:foreign_keys, [], fn fks -> Enum.reject(fks, &(&1.field == "parent_id")) end)
      |> Map.put(:indexes, [])

    doc =
      if mode == :other_shape and type == "category",
        do:
          Map.update!(
            doc,
            :fields,
            &(&1 ++ [%{name: "parent_id", type: :integer, required: false, queried: false}])
          ),
        else: doc

    case mode do
      m when m in [:stamped, :other_shape] ->
        assert {:ok, _row} =
                 Definitions.create_definition(
                   %{definition: doc, created_by: Ecto.UUID.generate()},
                   schema,
                   ManagedTypes.owner_for!(Exam)
                 )

      :unstamped ->
        Letflow.ManagedTypesSupport.plant_legacy_definition!(schema, doc)

      :other_module ->
        {:ok, current} = Definitions.get_active_definition_by_name(type, schema)

        assert {:ok, %Letflow.Repository.ArtifactVersion{version_id: version_id}} =
                 Letflow.Repository.create(
                   %{
                     artifact_kind: :entity,
                     artifact_name: type,
                     content_type: "application/json",
                     content: Jason.encode!(doc),
                     created_by: Ecto.UUID.generate()
                   },
                   schema
                 )

        stored = doc |> Jason.encode!() |> Jason.decode!()

        current
        |> Ecto.put_meta(state: :built)
        |> Map.merge(%{
          id: Ecto.UUID.generate(),
          artifact_version_id: version_id,
          inserted_at: DateTime.utc_now(),
          definition_json: stored,
          content_hash: :crypto.strong_rand_bytes(32),
          logical_shape_version: :crypto.strong_rand_bytes(32),
          status: :inactive,
          managed_by: "other_module"
        })
        |> Repo.insert!(prefix: schema)
    end

    assert {:ok, %EntityDefinition{}} =
             Definitions.activate_definition(type, Ecto.UUID.generate(), "REQ-586 C", schema)
  end

  defp promote!(tenant_id, type, attribute, pg_type, references \\ nil) do
    spec = %{pg_type: pg_type, nullable: true, references_entity: references}

    assert {:ok, [row]} =
             TenantProvisioning.register_column_promotion(type, attribute, spec, [tenant_id])

    assert {:ok, %ColumnPromotion{}} = TenantProvisioning.run_column_promotion(row.id)
  end

  defp create_category!(schema, parent_id \\ nil) do
    base = %{"name" => %{"en" => "C #{System.unique_integer([:positive])}"}, "sort_order" => 1}
    values = if parent_id, do: Map.put(base, "parent_id", parent_id), else: base

    Authoring.create(
      %{
        entity_type: "category",
        field_values: values,
        actor_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate()
      },
      schema
    )
  end

  # ── observers ──────────────────────────────────────────────────────────────────────────────

  defp active!(schema, type) do
    assert {:ok, row} = Definitions.get_active_definition_by_name(type, schema)
    row
  end

  defp versions(schema, type),
    do: Repo.all(from(d in EntityDefinition, where: d.name == ^type), prefix: schema)

  defp snapshot(tenant) do
    schema = tenant.schema_name

    %{
      definitions: for(t <- @types, do: versions(schema, t) |> Enum.map(&{&1.id, &1.status})),
      promotions: promotion_rows(tenant.tenant_id),
      columns: columns(schema),
      indexes: indexes(schema)
    }
  end

  defp promotion_rows(tenant_id) do
    Repo.all(
      from(p in ColumnPromotion,
        where: p.tenant_id == ^tenant_id,
        order_by: [p.entity_type, p.attribute],
        select: {p.entity_type, p.attribute, p.status}
      )
    )
  end

  defp columns(schema) do
    %{rows: rows} =
      Repo.query!(
        "SELECT table_name, column_name, data_type FROM information_schema.columns " <>
          "WHERE table_schema = $1 ORDER BY table_name, column_name",
        [schema]
      )

    rows
  end

  defp indexes(schema) do
    %{rows: rows} =
      Repo.query!("SELECT indexname FROM pg_indexes WHERE schemaname = $1 ORDER BY 1", [schema])

    rows
  end

  defp parent_column(schema, table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT format_type(a.atttypid, a.atttypmod), a.attnotnull
        FROM pg_attribute a
        JOIN pg_class t ON t.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = $1 AND t.relname = $2 AND a.attname = 'parent_id' AND NOT a.attisdropped
        """,
        [schema, table]
      )

    rows
  end

  defp parent_fks(schema, table) do
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
        [schema, table]
      )

    rows
  end

  defp row_count(schema, table),
    do: Repo.query!("SELECT count(*) FROM #{schema}.#{table}").rows |> hd() |> hd()

  defp non_null_parents(schema, table),
    do:
      Repo.query!("SELECT count(*) FROM #{schema}.#{table} WHERE parent_id IS NOT NULL").rows
      |> hd()
      |> hd()

  defp declares_parent?(row, type) do
    json = row.definition_json
    field = Enum.find(json["fields"], &(&1["name"] == "parent_id"))

    field != nil and field["type"] == "string" and
      Enum.any?(json["foreign_keys"], &(&1["field"] == "parent_id")) and
      Enum.any?(json["indexes"], &(&1["name"] == "idx_#{type}_parent_id"))
  end

  defp tenant_report(report, schema), do: Enum.find(report.tenants, &(&1.schema_name == schema))

  # ── P1 / P3 / P6 / P16 ─────────────────────────────────────────────────────────────────────

  describe "P1 real run on a stamped old tenant" do
    test "definitions, promotion, self-FK RESTRICT, index; rows unchanged; second run no-op" do
      tenant = old_tenant!("req586c-p1")
      schema = tenant.schema_name

      {:ok, %{record: a}} = create_category!(schema)
      {:ok, %{record: b}} = create_category!(schema)
      rows_before = row_count(schema, "entity_category")
      values_before = Enum.map([a, b], &Latest.get(&1.record_id, "category", schema))

      for t <- @types, do: refute(declares_parent?(active!(schema, t), t))
      versions_before = Map.new(@types, &{&1, length(versions(schema, &1))})

      report = ParentRollout.run_tenant(schema, [])

      assert %{
               status: :upgraded,
               error: nil,
               types: %{"category" => :added, "question" => :added}
             } =
               report

      for {t, table} <- [{"category", "entity_category"}, {"question", "entity_question"}] do
        row = active!(schema, t)
        assert declares_parent?(row, t)
        # P6: created through the new version under the exam owner, previous version inactive
        assert row.managed_by == "exam"
        assert length(versions(schema, t)) == versions_before[t] + 1
        assert [["uuid", false]] = parent_column(schema, table)
        assert [["r", true]] = parent_fks(schema, table)
        # P16
        assert TenantProvisioning.entity_index_exists?(schema, "idx_#{t}_parent_id")
      end

      assert {"category", "parent_id", status} =
               Enum.find(
                 promotion_rows(tenant.tenant_id),
                 &(elem(&1, 0) == "category" and elem(&1, 1) == "parent_id")
               )

      assert status in ["ddl_applied", "active", "backfilled", "backfilling"]

      assert row_count(schema, "entity_category") == rows_before
      assert non_null_parents(schema, "entity_category") == 0
      assert Enum.map([a, b], &Latest.get(&1.record_id, "category", schema)) == values_before

      # P3: second run writes nothing
      after_first = snapshot(tenant)
      second = ParentRollout.run_tenant(schema, [])
      assert %{status: :already_current, types: %{"category" => :already_current}} = second
      assert snapshot(tenant) == after_first
      assert %{ready: _, tenants: checks} = ParentRollout.verify()
      assert %{category: true, question: true} = Enum.find(checks, &(&1.schema_name == schema))
    end
  end

  describe "P2 a later authoring write sets a parent" do
    test "rejected before the rollout (undeclared field), accepted and stored after" do
      tenant = old_tenant!("req586c-p2")
      schema = tenant.schema_name
      {:ok, %{record: parent}} = create_category!(schema)

      assert {:error, before_error} = create_category!(schema, parent.record_id)
      refute match?({:ok, _}, before_error)

      assert %{status: :upgraded} = ParentRollout.run_tenant(schema, [])

      assert {:ok, %{record: child}} = create_category!(schema, parent.record_id)
      assert {:ok, latest} = Latest.get(child.record_id, "category", schema)
      assert latest.field_values["parent_id"] == parent.record_id
    end
  end

  # ── P4 / P5 ────────────────────────────────────────────────────────────────────────────────

  describe "P4 dry run" do
    test "reports the upgrade and writes nothing" do
      tenant = old_tenant!("req586c-p4")
      before = snapshot(tenant)

      report = ParentRollout.run_tenant(tenant.schema_name, dry_run: true)

      assert %{status: :upgraded, types: %{"category" => :added, "question" => :added}} = report
      assert snapshot(tenant) == before
      refute declares_parent?(active!(tenant.schema_name, "category"), "category")
    end

    test "run/1 sweep shape in dry run" do
      tenant = old_tenant!("req586c-p4s")

      assert {:ok, report} = ParentRollout.run(dry_run: true)
      assert report.dry_run

      assert Enum.sort(Map.keys(report)) == [
               :conflict_total,
               :dry_run,
               :failed_total,
               :tenants,
               :upgraded_total
             ]

      assert %{status: :upgraded} = tenant_report(report, tenant.schema_name)
    end
  end

  describe "P5 tenant without the exam module" do
    test "is skipped and untouched" do
      tenant = provisioned!("req586c-p5")
      before = snapshot(tenant)

      assert %{status: :exam_not_installed, error: nil} =
               ParentRollout.run_tenant(tenant.schema_name, [])

      assert snapshot(tenant) == before
    end

    test "an unknown schema is skipped" do
      assert %{status: :skipped_schema_missing} = ParentRollout.run_tenant("tenant_nope", [])
    end
  end

  # ── P7 / P8 ────────────────────────────────────────────────────────────────────────────────

  describe "P7 / P8 blocked tenants are untouched" do
    test "an unstamped name is managed_name_taken" do
      tenant = old_tenant!("req586c-p7", :unstamped)
      before = snapshot(tenant)

      assert %{status: :managed_name_taken, error: nil, types: types} =
               ParentRollout.run_tenant(tenant.schema_name, [])

      assert types["category"] == :managed_name_taken
      assert snapshot(tenant) == before
    end

    test "a type managed by another module is a conflict" do
      tenant = old_tenant!("req586c-p8a", :other_module)
      before = snapshot(tenant)

      assert %{status: :conflict, types: types} = ParentRollout.run_tenant(tenant.schema_name, [])
      assert types["category"] == :other_module_managed
      assert snapshot(tenant) == before
    end

    test "an existing parent_id of another shape is a conflict" do
      tenant = old_tenant!("req586c-p8b", :other_shape)
      before = snapshot(tenant)

      assert %{status: :conflict, types: %{"category" => :conflict}} =
               ParentRollout.run_tenant(tenant.schema_name, [])

      assert snapshot(tenant) == before
    end
  end

  # ── P9 / P10 / P13 / P17 ───────────────────────────────────────────────────────────────────

  describe "two tenants" do
    test "A's failure rolls A back as a tag only, B is untouched until its turn and then upgrades" do
      a = old_tenant!("req586c-p10a")
      b = old_tenant!("req586c-p10b")

      # A: a column of the wrong type is already there -> the promotion cannot add parent_id
      Repo.query!("ALTER TABLE #{a.schema_name}.entity_category ADD COLUMN parent_id text")
      before_a = snapshot(a)
      before_b = snapshot(b)

      report_a = ParentRollout.run_tenant(a.schema_name, [])

      assert %{
               status: :failed,
               error: {:promotion_failed, "category", :column_type_conflict},
               types: %{"category" => :skipped, "question" => :skipped}
             } = report_a

      refute inspect(report_a) =~ "text"
      # P17: the whole tenant rolled back, so the definition (and Authoring) still lack parent_id
      assert snapshot(a) == before_a
      refute declares_parent?(active!(a.schema_name, "category"), "category")
      assert snapshot(b) == before_b

      # the sweep goes on: B is upgraded afterwards, A's column is not B's
      assert %{status: :upgraded} = ParentRollout.run_tenant(b.schema_name, [])
      assert declares_parent?(active!(b.schema_name, "category"), "category")
      assert [["uuid", false]] = parent_column(b.schema_name, "entity_category")
      assert [["text", false]] = parent_column(a.schema_name, "entity_category")

      # P13: the cause is fixed -> A upgrades from scratch, one version
      Repo.query!("ALTER TABLE #{a.schema_name}.entity_category DROP COLUMN parent_id")
      versions_before = length(versions(a.schema_name, "category"))
      assert %{status: :upgraded, error: nil} = ParentRollout.run_tenant(a.schema_name, [])
      assert length(versions(a.schema_name, "category")) == versions_before + 1
      assert [["uuid", false]] = parent_column(a.schema_name, "entity_category")
    end

    test "a cross-tenant parent is not readable in the other tenant" do
      a = old_tenant!("req586c-p9a")
      b = old_tenant!("req586c-p9b")
      assert %{status: :upgraded} = ParentRollout.run_tenant(a.schema_name, [])
      {:ok, %{record: p}} = create_category!(a.schema_name)
      {:ok, %{record: c}} = create_category!(a.schema_name, p.record_id)

      assert {:ok, %{field_values: %{"parent_id" => _}}} =
               Latest.get(c.record_id, "category", a.schema_name)

      refute declares_parent?(active!(b.schema_name, "category"), "category")
      assert [] = parent_column(b.schema_name, "entity_category")
      assert {:error, _not_found} = Latest.get(c.record_id, "category", b.schema_name)
    end

    test "run/1 maps run_tenant/2 over every registration without halting" do
      source = File.read!("lib/letflow/modules/exam/parent_rollout.ex")

      assert source =~
               "for %Registration{schema_name: schema} <- TenantProvisioning.list_registrations()"

      assert source =~ "run_tenant(schema, opts)"
      refute source =~ "reduce_while(TenantProvisioning.list_registrations"
    end
  end

  describe "P13 resume of a partial state" do
    test "a current definition without its promotion row and index is completed" do
      tenant = old_tenant!("req586c-p13")
      schema = tenant.schema_name
      assert %{status: :upgraded} = ParentRollout.run_tenant(schema, [])

      # undo steps 2 and 3 only: the definition stays current
      Repo.query!("ALTER TABLE #{schema}.entity_category DROP COLUMN parent_id")

      Repo.delete_all(
        from(p in ColumnPromotion,
          where:
            p.tenant_id == ^tenant.tenant_id and p.entity_type == "category" and
              p.attribute == "parent_id"
        )
      )

      assert %{category: false} =
               Enum.find(ParentRollout.verify().tenants, &(&1.schema_name == schema))

      versions_before = length(versions(schema, "category"))

      assert %{
               status: :upgraded,
               types: %{"category" => :completed, "question" => :already_current}
             } =
               ParentRollout.run_tenant(schema, [])

      assert length(versions(schema, "category")) == versions_before
      assert [["uuid", false]] = parent_column(schema, "entity_category")
      assert TenantProvisioning.entity_index_exists?(schema, "idx_category_parent_id")

      assert %{category: true} =
               Enum.find(ParentRollout.verify().tenants, &(&1.schema_name == schema))
    end
  end

  # ── P16 ────────────────────────────────────────────────────────────────────────────────────

  describe "P16 ensure_entity_indexes/4" do
    test "creates once, skips an existing index, and verify/0 notices a dropped one" do
      tenant = old_tenant!("req586c-p16")
      schema = tenant.schema_name
      assert %{status: :upgraded} = ParentRollout.run_tenant(schema, [])
      document = TenantProvisioning.document_from_persisted(active!(schema, "category"))

      Repo.query!("DROP INDEX #{schema}.idx_category_parent_id")
      refute TenantProvisioning.entity_index_exists?(schema, "idx_category_parent_id")

      assert %{category: false} =
               Enum.find(ParentRollout.verify().tenants, &(&1.schema_name == schema))

      names = ["idx_category_parent_id"]
      assert :ok = TenantProvisioning.ensure_entity_indexes(schema, "category", document, names)
      assert :ok = TenantProvisioning.ensure_entity_indexes(schema, "category", document, names)
      assert TenantProvisioning.entity_index_exists?(schema, "idx_category_parent_id")
      # an index that is not named is not touched
      refute TenantProvisioning.entity_index_exists?(schema, "idx_nothing")

      assert {:error, :invalid_entity_type} =
               TenantProvisioning.ensure_entity_indexes(schema, "bad name", document, names)
    end
  end

  # ── P11 / P12 / P14 ────────────────────────────────────────────────────────────────────────

  describe "P11 release entry point" do
    test "rollout/1 forwards dry_run only; verify/0 reports readiness per tenant" do
      tenant = old_tenant!("req586c-p11")
      schema = tenant.schema_name

      report = Release.rollout(dry_run: true, lock_timeout_ms: 1, anything: :else)
      assert report.dry_run
      assert %{status: :upgraded} = tenant_report(report, schema)
      assert refute_written(tenant)

      verify = Release.verify()
      refute verify.ready

      assert %{category: false, question: false} =
               Enum.find(verify.tenants, &(&1.schema_name == schema))

      assert %{status: :upgraded} = ParentRollout.run_tenant(schema, [])

      assert %{category: true, question: true} =
               Enum.find(Release.verify().tenants, &(&1.schema_name == schema))
    end

    defp refute_written(tenant) do
      refute declares_parent?(active!(tenant.schema_name, "category"), "category")
      true
    end
  end

  describe "P12 boundary" do
    test "the release module reaches the exam module only through Catalog" do
      source = File.read!("lib/letflow/release/exam_parent_id.ex")
      refute source =~ "Letflow.Modules.Exam"
      assert source =~ ~s|Catalog.fetch("exam")|
      assert source =~ "Keyword.take(opts, [:dry_run])"
    end
  end

  describe "P14 drift guard" do
    test "the entries the rollout adds equal the shipped parent_id field, fk and index" do
      tenant = old_tenant!("req586c-p14")
      schema = tenant.schema_name
      assert %{status: :upgraded} = ParentRollout.run_tenant(schema, [])

      for type <- @types do
        shipped = @definitions_dir |> Path.join("#{type}.json") |> File.read!() |> Jason.decode!()
        stored = active!(schema, type).definition_json

        pick = fn json, key, field, name ->
          json |> Map.fetch!(key) |> Enum.find(&(&1[field] == name))
        end

        s_field = pick.(shipped, "fields", "name", "parent_id")
        t_field = pick.(stored, "fields", "name", "parent_id")
        assert Map.take(t_field, ["name", "type", "queried", "required"]) == s_field

        assert pick.(stored, "foreign_keys", "name", "fk_#{type}_parent_id")
               |> Map.take(["name", "field", "references_entity"]) ==
                 pick.(shipped, "foreign_keys", "name", "fk_#{type}_parent_id")

        assert pick.(stored, "indexes", "name", "idx_#{type}_parent_id")
               |> Map.take(["name", "fields"]) ==
                 pick.(shipped, "indexes", "name", "idx_#{type}_parent_id")
      end
    end
  end
end
