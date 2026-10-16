defmodule Letflow.Entities.ManagedTypes.StampTriggerTest do
  @moduledoc """
  GH #2596, design `lib/letflow/design/gh2596-exam-managed-types.md` section 4 and tests T-07,
  T-08, T-09, T-09b, T-10 (spec `test/specs/GH2596-exam-managed.md`): the database exception to
  REQ-496 D3 immutability that migration `AllowExamManagedByStamp` adds to the trigger function
  `entity_definitions_managed_by_guard()`.

  Runs OUTSIDE the Ecto sandbox transaction (SECURITY F-1): `async: false`, and
  `Letflow.TenantFixture.provisioned_tenant!/1` switches `Ecto.Adapters.SQL.Sandbox` to `:auto`
  (which checks in the case's own sandbox checkout), so every `Repo.transaction/1` below really
  begins and ends the transaction under test. Inside a sandbox-wrapped test "the setting resets
  at commit" would be vacuous. The tenant schema is dropped by the fixture's teardown.

  All raw `UPDATE`s go through `attempt/5`, which runs ONE statement in its own transaction and
  reports `:allowed` or `{:refused, message}`; a refused statement aborts its transaction, which
  is rolled back.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.ManagedTypes.Stamp
  alias Letflow.Entities.ManagedTypes.TamperInventory
  alias Letflow.ExamStampFixtures, as: Fx
  alias Letflow.Repo.Migrations.AllowExamManagedByStamp
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @migration AllowExamManagedByStamp
  @version Fx.exception_version()
  @old_version 20_261_014_100_001
  @old_migration Letflow.Repo.Migrations.AddManagedByToEntityDefinitions

  @refused "entity_definitions.managed_by is immutable"

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2596-trigger")

    # Loads every manifest migration module (they are not compiled into the app).
    migrations = TenantProvisioning.tenant_scoped_migrations()
    assert {@version, @migration} in migrations

    {:ok, schema: tenant.schema_name}
  end

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────

  # A minimal NULL-stamped definition row; returns its id.
  defp row!(schema, name) do
    Fx.create_definition!(schema, %{
      name: name,
      display_name: "GH2596 #{name}",
      fields: [Fx.field("name", :string)]
    }).id
  end

  # One UPDATE in its own transaction, with `letflow.managed_by_stamp` set to `setting` (nil = not
  # set). Rolled back unless `commit?`. Returns :allowed | {:refused, message}.
  defp attempt(schema, id, set_sql, setting, commit?) do
    result =
      Repo.transaction(fn ->
        if setting do
          Repo.query!("SELECT set_config('letflow.managed_by_stamp', $1, true)", [setting])
        end

        outcome =
          Repo.query(
            ~s|UPDATE "#{schema}".entity_definitions SET #{set_sql} WHERE id = $1|,
            [Ecto.UUID.dump!(id)]
          )

        case outcome do
          {:ok, %{num_rows: 1}} when commit? ->
            :allowed

          {:ok, %{num_rows: 1}} ->
            Repo.rollback(:allowed)

          {:error, %Postgrex.Error{postgres: %{message: message}}} ->
            Repo.rollback({:refused, message})
        end
      end)

    case result do
      {:ok, :allowed} -> :allowed
      {:error, :allowed} -> :allowed
      {:error, {:refused, message}} -> {:refused, message}
    end
  end

  defp stamp!(schema, id), do: :allowed = attempt(schema, id, "managed_by = 'exam'", "exam", true)

  defp managed_by(schema, id) do
    %{rows: [[value]]} =
      Repo.query!(~s|SELECT managed_by FROM "#{schema}".entity_definitions WHERE id = $1|, [
        Ecto.UUID.dump!(id)
      ])

    value
  end

  defp delete_attempt(schema, id) do
    result =
      Repo.transaction(fn ->
        case Repo.query(~s|DELETE FROM "#{schema}".entity_definitions WHERE id = $1|, [
               Ecto.UUID.dump!(id)
             ]) do
          {:ok, %{num_rows: 1}} ->
            Repo.rollback(:allowed)

          {:error, %Postgrex.Error{postgres: %{message: message}}} ->
            Repo.rollback({:refused, message})
        end
      end)

    case result do
      {:error, :allowed} -> :allowed
      {:error, {:refused, message}} -> {:refused, message}
    end
  end

  defp setting do
    %{rows: [[value]]} = Repo.query!("SELECT current_setting('letflow.managed_by_stamp', true)")
    value
  end

  defp prosrc(schema) do
    %{rows: [[source]]} =
      Repo.query!(
        """
        SELECT p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = $1 AND p.proname = 'entity_definitions_managed_by_guard'
        """,
        [schema]
      )

    source
  end

  defp trigger_state(schema) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT t.tgname, t.tgenabled::text, p.proname
        FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_proc p ON p.oid = t.tgfoid
        WHERE n.nspname = $1 AND c.relname = 'entity_definitions'
          AND t.tgname LIKE 'entity_definitions_managed_by_%'
        ORDER BY t.tgname
        """,
        [schema]
      )

    for [name, enabled, function] <- rows, do: {name, enabled, function}
  end

  defp migrate(schema, version, module, direction) do
    Ecto.Migrator.run(Repo, [{version, module}], direction,
      all: true,
      prefix: schema,
      log: false
    )
  end

  # The function body of the first `AS $$ ... $$ LANGUAGE` heredoc in a migration file, with the
  # heredoc's own indentation removed (what Elixir's heredoc hands Postgres).
  defp heredoc_bodies(path) do
    source = File.read!(path)

    for [_, body] <- Regex.scan(~r/AS \$\$(.*?)\$\$ LANGUAGE/s, source) do
      lines = String.split(body, "\n")
      begin_line = Enum.find(lines, &String.contains?(&1, "BEGIN"))
      indent = byte_size(begin_line) - byte_size(String.trim_leading(begin_line))

      lines
      |> Enum.map(fn line ->
        if String.length(line) >= indent and String.trim(String.slice(line, 0, indent)) == "",
          do: String.slice(line, indent..-1//1),
          else: String.trim_leading(line)
      end)
      |> Enum.join("\n")
    end
  end

  # ── T-07 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-07 (AC3): with no setting the REQ-496 D3 guard is exactly as before" do
    test "NULL -> 'exam' is refused on a runtime name; a stamped row cannot be cleared, re-stamped, renamed or deleted",
         %{schema: schema} do
      id = row!(schema, "session")

      assert {:refused, @refused} = attempt(schema, id, "managed_by = 'exam'", nil, false)
      assert managed_by(schema, id) == nil

      # Stamp it through the sanctioned opener, then every post-stamp change is refused.
      stamp!(schema, id)
      assert managed_by(schema, id) == "exam"

      assert {:refused, @refused} = attempt(schema, id, "managed_by = NULL", nil, false)
      assert {:refused, @refused} = attempt(schema, id, "managed_by = 'other'", nil, false)
      assert {:refused, @refused} = attempt(schema, id, "name = 'session_renamed'", nil, false)
      assert {:refused, @refused} = delete_attempt(schema, id)

      # Even with the setting open, a stamped row stays immutable.
      assert {:refused, @refused} = attempt(schema, id, "managed_by = NULL", "exam", false)
      assert {:refused, @refused} = attempt(schema, id, "managed_by = 'other'", "exam", false)
      assert {:refused, @refused} = attempt(schema, id, "name = 'session_renamed'", "exam", false)

      # Unchanged behaviour: a status flip on a stamped row is still allowed.
      assert :allowed = attempt(schema, id, "status = 'active'", nil, false)
    end
  end

  # ── T-08 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-08 (AC3): with the setting 'exam' the exception is exactly NULL -> 'exam' on the six" do
    test "succeeds on each of the six runtime names", %{schema: schema} do
      for name <- Fx.runtime_types() do
        id = row!(schema, name)
        assert :allowed = attempt(schema, id, "managed_by = 'exam'", "exam", false), name
      end
    end

    test "is refused on each of the ten authoring names and on org_unit", %{schema: schema} do
      for name <- Fx.authoring_types() ++ ["org_unit"] do
        id = row!(schema, name)

        assert {:refused, @refused} = attempt(schema, id, "managed_by = 'exam'", "exam", false),
               name
      end
    end

    test "is refused for another module id, another setting value and an empty setting", %{
      schema: schema
    } do
      id = row!(schema, "session")

      assert {:refused, @refused} = attempt(schema, id, "managed_by = 'other'", "exam", false)
      assert {:refused, @refused} = attempt(schema, id, "managed_by = 'exam'", "other", false)
      assert {:refused, @refused} = attempt(schema, id, "managed_by = 'exam'", "", false)
      assert {:refused, @refused} = attempt(schema, id, "managed_by = 'exam'", "EXAM", false)
      assert managed_by(schema, id) == nil
    end

    test "is refused when the same statement also changes anything else about the row", %{
      schema: schema
    } do
      id = row!(schema, "session")

      for extra <- [
            "name = 'session_x'",
            "status = 'active'",
            "display_name = 'changed'",
            "definition_json = '{}'::jsonb",
            "content_hash = '\\x00'::bytea",
            "tenant_id = gen_random_uuid()"
          ] do
        assert {:refused, @refused} =
                 attempt(schema, id, "managed_by = 'exam', #{extra}", "exam", false),
               extra
      end

      assert managed_by(schema, id) == nil
      # The clean single-column statement is still allowed on the same row afterwards.
      assert :allowed = attempt(schema, id, "managed_by = 'exam'", "exam", false)
    end
  end

  # ── T-09 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-09 (AC3, SECURITY F-1): the setting is transaction-local and a nested call is typed" do
    test "after commit AND after rollback the setting is closed again in the SAME connection",
         %{schema: schema} do
      id = row!(schema, "session")

      Repo.checkout(fn ->
        {:ok, :done} =
          Repo.transaction(fn ->
            Repo.query!("SELECT set_config('letflow.managed_by_stamp', 'exam', true)")
            :done
          end)

        assert setting() in [nil, ""]

        {:error, :rolled_back} =
          Repo.transaction(fn ->
            Repo.query!("SELECT set_config('letflow.managed_by_stamp', 'exam', true)")
            Repo.rollback(:rolled_back)
          end)

        assert setting() in [nil, ""]
      end)

      assert {:refused, @refused} = attempt(schema, id, "managed_by = 'exam'", nil, false)
      assert managed_by(schema, id) == nil

      assert [
               {"entity_definitions_managed_by_no_delete", "O",
                "entity_definitions_managed_by_guard"},
               {"entity_definitions_managed_by_no_update", "O",
                "entity_definitions_managed_by_guard"}
             ] = trigger_state(schema)
    end

    test "Stamp.run_tenant and TamperInventory.run_tenant inside an outer transaction are typed refusals and leave the guard closed",
         %{schema: schema} do
      id = row!(schema, "session")
      Fx.insert_exam_row!(schema)

      {:error, {stamp, inventory, after_refusal}} =
        Repo.transaction(fn ->
          stamp = Stamp.run_tenant(schema, [])
          inventory = TamperInventory.run_tenant(schema, [])

          # The setting must NOT be open in this outer transaction: a plain stamp is refused.
          after_refusal =
            case Repo.query(
                   ~s|UPDATE "#{schema}".entity_definitions SET managed_by = 'exam' WHERE id = $1|,
                   [Ecto.UUID.dump!(id)]
                 ) do
              {:error, %Postgrex.Error{postgres: %{message: message}}} -> {:refused, message}
              {:ok, _result} -> :allowed
            end

          Repo.rollback({stamp, inventory, after_refusal})
        end)

      assert %{status: :failed, error: :nested_transaction, rows_stamped: 0} = stamp
      assert %{skipped: :nested_transaction, findings: []} = inventory
      assert {:refused, @refused} = after_refusal
      assert managed_by(schema, id) == nil
    end

    test "the clearing statement set_config('letflow.managed_by_stamp', '', true) keeps the branch closed",
         %{schema: schema} do
      id = row!(schema, "session")

      {:error, outcome} =
        Repo.transaction(fn ->
          Repo.query!("SELECT set_config('letflow.managed_by_stamp', 'exam', true)")
          Repo.query!("SELECT set_config('letflow.managed_by_stamp', '', true)")

          outcome =
            case Repo.query(
                   ~s|UPDATE "#{schema}".entity_definitions SET managed_by = 'exam' WHERE id = $1|,
                   [Ecto.UUID.dump!(id)]
                 ) do
              {:error, %Postgrex.Error{postgres: %{message: message}}} -> {:refused, message}
              {:ok, _result} -> :allowed
            end

          Repo.rollback(outcome)
        end)

      assert {:refused, @refused} = outcome
    end
  end

  # ── T-09b ───────────────────────────────────────────────────────────────────────────────────

  describe "T-09b (AC3): AllowExamManagedByStamp down/up round trip" do
    @tag timeout: 120_000
    test "down restores the previous body byte for byte and closes the exception; up reopens it; Stamp reports :exception_not_installed in between",
         %{schema: schema} do
      Fx.insert_exam_row!(schema)
      id = row!(schema, "session")

      [old_body | _] =
        heredoc_bodies(
          "priv/repo/migrations/20261014100001_add_managed_by_to_entity_definitions.exs"
        )

      [_up_body, new_down_body] =
        heredoc_bodies("priv/repo/migrations/20261016120001_allow_exam_managed_by_stamp.exs")

      # The migration's own `down` text is the previous body, copied (not re-typed).
      assert new_down_body == old_body

      up_body = prosrc(schema)
      refute up_body == old_body
      assert up_body =~ "letflow.managed_by_stamp"

      assert migrate(schema, @version, @migration, :down) == [@version]
      assert prosrc(schema) == old_body
      refute prosrc(schema) =~ "letflow.managed_by_stamp"

      assert [
               {"entity_definitions_managed_by_no_delete", "O",
                "entity_definitions_managed_by_guard"},
               {"entity_definitions_managed_by_no_update", "O",
                "entity_definitions_managed_by_guard"}
             ] = trigger_state(schema)

      # With the exception retired the setting does nothing.
      assert {:refused, @refused} = attempt(schema, id, "managed_by = 'exam'", "exam", false)

      # The tenant's schema_migrations no longer lists the version, so Stamp does not try.
      assert %{status: :exception_not_installed, rows_stamped: 0} = Stamp.run_tenant(schema, [])
      assert managed_by(schema, id) == nil

      assert migrate(schema, @version, @migration, :up) == [@version]
      assert prosrc(schema) == up_body

      assert [
               {"entity_definitions_managed_by_no_delete", "O",
                "entity_definitions_managed_by_guard"},
               {"entity_definitions_managed_by_no_update", "O",
                "entity_definitions_managed_by_guard"}
             ] = trigger_state(schema)

      assert :allowed = attempt(schema, id, "managed_by = 'exam'", "exam", false)
      assert {:refused, @refused} = attempt(schema, id, "managed_by = 'exam'", nil, false)
    end

    test "the older migration is still registered, so the round trip cannot silently skip it",
         %{schema: _schema} do
      assert {@old_version, @old_migration} in TenantProvisioning.tenant_scoped_migrations()
    end
  end

  # ── T-10 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-10 (AC3): the three name lists are one list" do
    test "migration stamp_names/0 == Stamp.stamp_names/0 == the literal six, a subset of the manifest set" do
      literal =
        Enum.sort(
          ~w(certificate session session_answer session_event session_question session_question_score)
        )

      assert Enum.sort(AllowExamManagedByStamp.stamp_names()) == literal
      assert Enum.sort(Stamp.stamp_names()) == literal
      assert Enum.sort(Fx.runtime_types()) == literal

      manifest = MapSet.new(Letflow.Modules.Exam.manifest().manages_entity_types)
      assert MapSet.subset?(MapSet.new(literal), manifest)
    end

    test "the function body's literal array holds exactly those six names", %{schema: schema} do
      assert [[_, array]] = Regex.scan(~r/ARRAY\[([^\]]*)\]/, prosrc(schema))

      literal =
        ~r/'([a-z_]+)'/ |> Regex.scan(array) |> Enum.map(&List.last/1) |> Enum.sort()

      assert literal == Enum.sort(AllowExamManagedByStamp.stamp_names())
      # The ten authoring names are not in that array.
      assert literal -- Fx.authoring_types() == literal
    end
  end
end
