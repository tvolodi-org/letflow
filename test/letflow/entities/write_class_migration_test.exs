defmodule Letflow.Entities.WriteClassMigrationTest do
  @moduledoc """
  GH #2618 (decision 0054 D4a.2 amendment): the `write_class` column of `entity_definitions`, its
  backfill from the interim denied-name list it replaced, and the write path that assigns it.

    * T3 (AC2): the backfill, run on the real migration SQL, gives every type the interim list refused a
      class other than `ordinary`, for the fixture names and for the names the shipped modules declare.
    * T4 (AC1, no bypass): a new version of a legacy refused name cannot take the flag.
    * T5 (AC1, tenant input): a `write_class` key in a tenant definition is never read.
    * T6 / T7 (AC1): the database refuses a class outside the vocabulary, a NULL class, and a change of an
      existing row's class.
    * T10 (AC1, the stamp blocker): a legacy row stamped by the `managed_by` exception window still refuses
      the flag, through the stamp argument of the create path and through `writable?/1`.

  ## How T3 reaches the pre-migration state

  `async: false`: `TenantFixture.provisioned_tenant!/1` sets the sandbox to `:auto`. The tenant is provisioned
  with the full manifest (this migration included). Its rows are inserted while the column exists, with a
  placeholder class. The migration's `down` then drops the column, and `replay_migrations/2` with only this
  migration runs its `up`, which is the real backfill. The same shape as
  `test/letflow/migrations/backfill_exam_tenant_modules_test.exs`.

  `old_refused?/1` is a test-only copy of the interim denied-name rule (GH #2587), kept here so the
  comparison is against the migration's literal patterns, not against the product code that was deleted.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.ProcessWritable
  alias Letflow.Repo
  alias Letflow.Repository
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_023_100_001
  @migration_module Letflow.Repo.Migrations.AddWriteClassToEntityDefinitions

  # The interim denied-name rule (GH #2587 PR A4), copied verbatim.
  @old_exact ~w(org orgs user users role roles permission permissions principal principals group groups
                membership memberships attachment attachments)
  @old_prefixes ~w(org_ user_ users_ role_ roles_ permission_ permissions_ principal_ principals_ group_
                   groups_ membership_ attachment_ attachments_)

  # The classes the backfill gives (decision 0054 D4a.2 amendment, item 4).
  @org_exact ~w(org orgs)
  @identity_exact ~w(user users role roles permission permissions principal principals group groups
                     membership memberships)
  @attachment_exact ~w(attachment attachments)
  @identity_prefixes ~w(user_ users_ role_ roles_ permission_ permissions_ principal_ principals_ group_
                        groups_ membership_)
  @attachment_prefixes ~w(attachment_ attachments_)

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────

  # Test-only copy of the interim rule (`denied_name?/1` before GH #2618).
  defp old_refused?(name) do
    lowered = String.downcase(name)

    lowered in @old_exact or Enum.any?(@old_prefixes, &String.starts_with?(lowered, &1))
  end

  # A legacy row: a real artifact version (the FK), an unmanaged or stamped type, a unique shape hash.
  # `write_class` is set to a placeholder ("ordinary") so the row satisfies the column while it exists;
  # the backfill recomputes it.
  defp insert_row!(schema, tenant_id, name, opts \\ []) do
    unique = System.unique_integer([:positive])
    hash = :crypto.hash(:sha256, "gh2618-#{name}-#{unique}")

    {:ok, %Repository.ArtifactVersion{version_id: version_id}} =
      Repository.create(
        %{
          artifact_kind: :entity,
          artifact_name: "gh2618_fixture_#{unique}",
          content_type: "application/json",
          content: "{}",
          created_by: Ecto.UUID.generate()
        },
        schema
      )

    Repo.insert!(
      %EntityDefinition{
        tenant_id: tenant_id,
        name: name,
        display_name: "legacy #{name}",
        definition_json: %{"name" => name, "display_name" => "legacy #{name}"},
        content_hash: hash,
        logical_shape_version: hash,
        artifact_version_id: version_id,
        status: :inactive,
        managed_by: Keyword.get(opts, :managed_by),
        write_class: Keyword.get(opts, :write_class, "ordinary")
      },
      prefix: schema
    )
  end

  # Pre-migration state: drop the column, its constraints and trigger (the migration's `down`), then run
  # the migration's `up` with this migration alone. Returns the replay result.
  defp backfill_from_scratch!(schema, tenant_id) do
    Ecto.Migrator.run(Repo, [{@version, @migration_module}], :down,
      all: true,
      prefix: schema,
      log: false
    )

    TenantProvisioning.replay_migrations(tenant_id, [{@version, @migration_module}])
  end

  defp class_of(schema, id) do
    Repo.one!(from(d in EntityDefinition, where: d.id == ^id, select: d.write_class),
      prefix: schema
    )
  end

  defp definition(name, extra) do
    Map.merge(
      %{
        name: name,
        display_name: "GH2618 #{name}",
        fields: [%{name: "title", type: :string, required: true}]
      },
      extra
    )
  end

  # ── T3 (AC2): the backfill against the interim list ─────────────────────────────────────────

  describe "T3: the backfill classifies existing rows the way the interim denied-name list refused them" do
    setup do
      %{tenant_id: tenant_id, schema_name: schema} =
        TenantFixture.provisioned_tenant!(slug_prefix: "gh2618-t3")

      %{tenant_id: tenant_id, schema: schema}
    end

    test "every interim exact name, every interim prefix, near misses, mixed case and a stamped row",
         %{tenant_id: tenant_id, schema: schema} do
      cases =
        Enum.map(@org_exact, &{&1, nil, "org_tree"}) ++
          [{"org_x", nil, "org_tree"}] ++
          Enum.map(@identity_exact, &{&1, nil, "identity_adjacent"}) ++
          Enum.map(@identity_prefixes, &{&1 <> "x", nil, "identity_adjacent"}) ++
          Enum.map(@attachment_exact, &{&1, nil, "attachment_metadata"}) ++
          Enum.map(@attachment_prefixes, &{&1 <> "x", nil, "attachment_metadata"}) ++
          [
            {"orgx", nil, "ordinary"},
            {"usery", nil, "ordinary"},
            {"rolex", nil, "ordinary"},
            {"groupie", nil, "ordinary"},
            {"invoice", nil, "ordinary"},
            {"ordinary_x", nil, "ordinary"},
            {"user_feedback", nil, "identity_adjacent"},
            {"Role", nil, "identity_adjacent"},
            {"ROLE_x", nil, "identity_adjacent"},
            {"Org_Unit", nil, "org_tree"},
            {"session", "exam", "managed"},
            {"invoice_line", "exam", "managed"}
          ]

      rows =
        for {name, managed_by, expected} <- cases do
          {insert_row!(schema, tenant_id, name, managed_by: managed_by), name, expected}
        end

      assert {:ok, [@version]} = backfill_from_scratch!(schema, tenant_id)

      for {%EntityDefinition{id: id}, name, expected} <- rows do
        class = class_of(schema, id)

        assert class == expected, "#{name}: got #{inspect(class)}, expected #{expected}"

        # AC2: a row is not `ordinary` exactly when the interim list refused it, or it is stamped.
        managed? = expected == "managed"

        assert class != "ordinary" == (old_refused?(name) or managed?),
               "#{name}: class #{class} disagrees with the interim list"
      end
    end

    test "the names the shipped modules declare keep the refusal the interim list gave them",
         %{tenant_id: tenant_id, schema: schema} do
      names =
        "priv/modules/*/entity_definitions/*.json"
        |> Path.wildcard()
        |> Enum.map(&(&1 |> File.read!() |> Jason.decode!() |> Map.fetch!("name")))
        |> Enum.uniq()

      assert "org_unit" in names
      assert "session" in names

      rows = for name <- names, do: {insert_row!(schema, tenant_id, name), name}

      assert {:ok, [@version]} = backfill_from_scratch!(schema, tenant_id)

      for {%EntityDefinition{id: id}, name} <- rows do
        class = class_of(schema, id)

        assert class != "ordinary" == old_refused?(name),
               "#{name}: class #{class}, interim refused #{old_refused?(name)}"
      end

      assert class_of(schema, Enum.find_value(rows, fn {r, n} -> n == "org_unit" && r.id end)) ==
               "org_tree"
    end
  end

  # ── T4 (AC1): no bypass by a version bump ───────────────────────────────────────────────────

  describe "T4: a new version of a legacy refused name cannot take the flag" do
    test "the new version inherits identity_adjacent and the flag is refused with the stable rule" do
      %{tenant_id: tenant_id, schema_name: schema} =
        TenantFixture.provisioned_tenant!(slug_prefix: "gh2618-t4")

      insert_row!(schema, tenant_id, "roles_x", write_class: "identity_adjacent")

      assert {:error, {:validation, [violation]}} =
               Letflow.ManagedTypesSupport.create_definition(
                 %{
                   definition:
                     definition("roles_x", %{
                       writable_by_process: true,
                       fields: [
                         %{name: "title", type: :string, required: true},
                         %{name: "note", type: :string}
                       ]
                     }),
                   created_by: Ecto.UUID.generate()
                 },
                 schema
               )

      assert violation.rule == :writable_by_process_not_permitted
      assert violation.path == [:writable_by_process]
      assert violation.message =~ ~s(classified "identity_adjacent")
    end
  end

  # ── T5 (AC1): tenant input cannot assign the class ──────────────────────────────────────────

  describe "T5: a tenant definition cannot assign or change the write class" do
    test "a write_class key in the definition is ignored: a new name is ordinary and the key is not stored" do
      %{schema_name: schema} = TenantFixture.provisioned_tenant!(slug_prefix: "gh2618-t5")

      assert {:ok, %EntityDefinition{} = row} =
               Letflow.ManagedTypesSupport.create_definition(
                 %{
                   definition:
                     definition("feedback_note", %{
                       writable_by_process: true,
                       write_class: "managed",
                       classification: "org_tree"
                     }),
                   created_by: Ecto.UUID.generate()
                 },
                 schema
               )

      assert row.write_class == "ordinary"
      assert ProcessWritable.writable?(row)
      refute Map.has_key?(row.definition_json, "write_class")
    end

    test "a write_class key in a version of a legacy identity name does not change the inherited class" do
      %{tenant_id: tenant_id, schema_name: schema} =
        TenantFixture.provisioned_tenant!(slug_prefix: "gh2618-t5b")

      insert_row!(schema, tenant_id, "users_x", write_class: "identity_adjacent")

      assert {:error, {:validation, [%{rule: :writable_by_process_not_permitted}]}} =
               Letflow.ManagedTypesSupport.create_definition(
                 %{
                   definition:
                     definition("users_x", %{
                       writable_by_process: true,
                       write_class: "ordinary",
                       fields: [
                         %{name: "title", type: :string, required: true},
                         %{name: "note", type: :string}
                       ]
                     }),
                   created_by: Ecto.UUID.generate()
                 },
                 schema
               )
    end
  end

  # ── T6 / T7 (AC1): the database enforces the vocabulary, non-NULL, and immutability ─────────

  describe "T6/T7: the column is enforced in the database" do
    setup do
      %{tenant_id: tenant_id, schema_name: schema} =
        TenantFixture.provisioned_tenant!(slug_prefix: "gh2618-t6")

      %{tenant_id: tenant_id, schema: schema}
    end

    test "T6: a class outside the vocabulary is refused by the CHECK", %{
      tenant_id: tenant_id,
      schema: schema
    } do
      assert_raise Ecto.ConstraintError, ~r/entity_definitions_write_class_chk/, fn ->
        insert_row!(schema, tenant_id, "bad_class", write_class: "admin")
      end
    end

    test "T6: a NULL class is refused by NOT NULL", %{tenant_id: tenant_id, schema: schema} do
      assert_raise Postgrex.Error, ~r/write_class/, fn ->
        insert_row!(schema, tenant_id, "null_class", write_class: nil)
      end
    end

    test "T7: an update that changes an existing row's class is refused by the trigger", %{
      tenant_id: tenant_id,
      schema: schema
    } do
      row = insert_row!(schema, tenant_id, "roles_fixed", write_class: "identity_adjacent")

      assert_raise Postgrex.Error, ~r/write_class is immutable/, fn ->
        Repo.update_all(
          from(d in EntityDefinition, where: d.id == ^row.id),
          [set: [write_class: "ordinary"]],
          prefix: schema
        )
      end

      assert class_of(schema, row.id) == "identity_adjacent"
    end
  end

  # ── T10 (AC1): the stamp blocker (GH #2618 design gate, blocker) ─────────────────────────────

  describe "T10: a legacy row stamped after the backfill keeps its class and still refuses the flag" do
    test "stamp argument refuses a module-owned flag-true version; a tenant version is refused by name" do
      %{tenant_id: tenant_id, schema_name: schema} =
        TenantFixture.provisioned_tenant!(slug_prefix: "gh2618-t10")

      legacy = insert_row!(schema, tenant_id, "session")
      assert class_of(schema, legacy.id) == "ordinary"

      # The exception window of `Letflow.Entities.ManagedTypes.Stamp.stamp_rows/3`: the only UPDATE of
      # `managed_by` the guard trigger allows, under its `letflow.managed_by_stamp` setting.
      Repo.transaction(fn ->
        Repo.query!("SELECT set_config('letflow.managed_by_stamp', $1, true)", ["exam"])

        Repo.update_all(
          from(d in EntityDefinition, where: d.id == ^legacy.id),
          [set: [managed_by: "exam"]],
          prefix: schema
        )
      end)

      stamped = Repo.get!(EntityDefinition, legacy.id, prefix: schema)
      assert stamped.managed_by == "exam"
      assert class_of(schema, legacy.id) == "ordinary"

      refute ProcessWritable.writable?(%{
               stamped
               | definition_json: %{"writable_by_process" => true}
             })

      # A module-owned version with the flag: the stamp argument refuses it, whatever the class.
      assert {:error, {:validation, [violation]}} =
               ProcessWritable.check_settable(
                 %{name: "session", writable_by_process: true},
                 "exam",
                 class_of(schema, legacy.id)
               )

      assert violation.message ==
               "writable_by_process cannot be set: the entity type is managed by a module"
    end
  end
end
