defmodule Letflow.Definitions.SnapshotStoreTest do
  @moduledoc """
  Tests for `Letflow.Definitions.SnapshotStore.create/3` and
  `.get_by_instance_id/2` (REQ-033). See `test/specs/REQ-033.md` for the full
  test-case rationale, including the REVIEWER-recommended
  differing-`definition_id` first-writer-wins case and the INV-8 UUID-cast
  guard coverage.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database
  anywhere in this file.

  ## Fixture strategy -- read before adding a test here

  Mirrors `test/letflow/event_store_test.exs`'s and
  `test/letflow/definitions/migrations_test.exs`'s established
  `provisioned_tenant/1` pattern exactly: each test provisions its own tenant
  (real `CREATE SCHEMA` via `TenantProvisioning.provision_tenant_schema/1`,
  real `TenantProvisioning.replay_migrations/1`, which includes both of
  REQ-027's definition migrations). `Ecto.Migrator` needs a second real DB
  connection the sandbox can't hand out, hence Sandbox `:auto` mode and
  manual `on_exit/1` cleanup instead of the normal rolled-back transaction.
  `async: false` for the whole module -- required for the same reason those
  two files are `async: false`: the `:auto`-mode switch is only safe because
  ExUnit fully drains every `async: true` module before running any
  `async: false` module, and runs `async: false` modules one at a time.

  Every test provisions its own `process_definitions` row(s) directly via
  `ProcessDefinition.create_changeset/2` + `Repo.insert!/2` (REQ-030's CRUD
  layer doesn't exist yet) and uses a fresh `Ecto.UUID.generate()` for every
  `instance_id`/`definition_id` -- no shared or hard-coded identifiers, no
  test depends on another test's data or on execution order.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.SnapshotStore
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- provisions via Letflow.TenantFixture (ISS-0112 / GH#366).
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant(_context \\ %{}) do
    TenantFixture.provisioned_tenant!(
      slug_prefix: "req033",
      display_name: "REQ-033 Test Tenant"
    )
  end

  defp unique_name(prefix \\ "req033-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp insert_definition!(schema_name, overrides \\ %{}) do
    base = %{
      name: unique_name(),
      version: "1.0.0",
      graph: %{"nodes" => [], "edges" => []},
      created_by: Ecto.UUID.generate()
    }

    %ProcessDefinition{}
    |> ProcessDefinition.create_changeset(Map.merge(base, overrides))
    |> Repo.insert!(prefix: schema_name)
  end

  defp snapshot_count(schema_name) do
    Repo.aggregate(InstanceDefinitionSnapshot, :count, prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 1: "create/2 against a valid definition_id inserts a
  # snapshot row whose graph matches the source process_definitions row's graph
  # at the moment of the call"
  # ---------------------------------------------------------------------------------

  describe "create/3 (AC1)" do
    test "create/3 inserts a snapshot row whose graph, name and version match the source process_definitions row" do
      %{schema_name: schema_name} = provisioned_tenant()

      distinctive_graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "start"},
          %{"id" => "end", "node_type" => "end"}
        ],
        "edges" => [%{"from" => "start", "to" => "end"}]
      }

      definition =
        insert_definition!(schema_name, %{version: "2.4.1", graph: distinctive_graph})

      instance_id = Ecto.UUID.generate()

      assert {:ok, %InstanceDefinitionSnapshot{} = snapshot} =
               SnapshotStore.create(instance_id, definition.id, prefix: schema_name)

      assert snapshot.instance_id == instance_id
      assert snapshot.definition_id == definition.id
      assert snapshot.definition_name == definition.name
      assert snapshot.definition_ver == "2.4.1"
      assert snapshot.graph == distinctive_graph
      assert %DateTime{} = snapshot.snapshotted_at

      # Re-selected directly from Postgres, not just the in-memory reply.
      assert {:ok, reselected} =
               SnapshotStore.get_by_instance_id(instance_id, prefix: schema_name)

      assert reselected.graph == distinctive_graph
      assert reselected.definition_name == definition.name
      assert reselected.definition_ver == "2.4.1"
      assert snapshot_count(schema_name) == 1
    end

    test "create/3 with a definition_id that names no process_definitions row returns {:error, :definition_not_found} and writes zero rows" do
      %{schema_name: schema_name} = provisioned_tenant()

      instance_id = Ecto.UUID.generate()
      dangling_definition_id = Ecto.UUID.generate()

      assert {:error, :definition_not_found} =
               SnapshotStore.create(instance_id, dangling_definition_id, prefix: schema_name)

      assert snapshot_count(schema_name) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 2 ("create/2 called twice with the same instance_id is
  # idempotent") plus REVIEWER's explicit Step 2d recommendation: a differing
  # definition_id on the retry is silently discarded (first-writer-wins), not an
  # error -- design doc §4.3, §9 OQ-2.
  # ---------------------------------------------------------------------------------

  describe "create/3 idempotency (AC2)" do
    test "a second create/3 call with the SAME instance_id and SAME definition_id returns the pre-existing snapshot, inserts zero additional rows" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition = insert_definition!(schema_name)
      instance_id = Ecto.UUID.generate()

      assert {:ok, first} = SnapshotStore.create(instance_id, definition.id, prefix: schema_name)
      assert snapshot_count(schema_name) == 1

      assert {:ok, second} = SnapshotStore.create(instance_id, definition.id, prefix: schema_name)

      # Same row, not a fresh insert -- proven by the read_after_writes timestamp
      # being identical, which a second real insert would not produce.
      assert first.snapshotted_at == second.snapshotted_at
      assert first.definition_id == second.definition_id
      assert snapshot_count(schema_name) == 1
    end

    test "a second create/3 call with the SAME instance_id but a DIFFERENT definition_id is silently discarded -- the original snapshot is returned unchanged, no error" do
      %{schema_name: schema_name} = provisioned_tenant()

      graph_1 = %{"nodes" => [%{"id" => "n1", "node_type" => "start"}], "edges" => []}
      graph_2 = %{"nodes" => [%{"id" => "n2", "node_type" => "start"}], "edges" => []}

      definition_1 = insert_definition!(schema_name, %{version: "1.0.0", graph: graph_1})
      definition_2 = insert_definition!(schema_name, %{version: "9.9.9", graph: graph_2})

      refute definition_1.id == definition_2.id

      instance_id = Ecto.UUID.generate()

      assert {:ok, first} =
               SnapshotStore.create(instance_id, definition_1.id, prefix: schema_name)

      assert first.definition_id == definition_1.id
      assert first.graph == graph_1

      # The REVIEWER-recommended pin: this call must NOT error, must NOT raise, and
      # must NOT adopt definition_2's identity -- it silently returns the original.
      assert {:ok, second} =
               SnapshotStore.create(instance_id, definition_2.id, prefix: schema_name)

      assert second.instance_id == instance_id

      assert second.definition_id == definition_1.id,
             "the retry's differing definition_id leaked into the stored snapshot -- expected first-writer-wins"

      refute second.definition_id == definition_2.id
      assert second.definition_name == definition_1.name
      assert second.definition_ver == "1.0.0"
      assert second.graph == graph_1
      refute second.graph == graph_2

      # Only one row was ever written for this instance_id.
      assert snapshot_count(schema_name) == 1

      # Confirmed against a fresh re-select too, not just the two in-memory replies.
      assert {:ok, reselected} =
               SnapshotStore.get_by_instance_id(instance_id, prefix: schema_name)

      assert reselected.definition_id == definition_1.id
      assert reselected.graph == graph_1
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 3: "get_by_instance_id/1 against an instance_id with no
  # snapshot returns a not-found error, not nil silently"
  # ---------------------------------------------------------------------------------

  describe "get_by_instance_id/2 (AC3)" do
    test "get_by_instance_id/2 for an instance_id with no snapshot returns {:error, :snapshot_not_found}, never nil" do
      %{schema_name: schema_name} = provisioned_tenant()

      never_created_instance_id = Ecto.UUID.generate()

      # apply/3 keeps the compiler's type checker from flagging the deliberate nil comparison.
      result =
        apply(SnapshotStore, :get_by_instance_id, [
          never_created_instance_id,
          [prefix: schema_name]
        ])

      assert result == {:error, :snapshot_not_found}
      refute is_nil(result)
    end

    test "get_by_instance_id/2 finds a snapshot created by create/3 in a distinct call" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition = insert_definition!(schema_name)
      instance_id = Ecto.UUID.generate()

      assert {:ok, _snapshot} =
               SnapshotStore.create(instance_id, definition.id, prefix: schema_name)

      assert {:ok, %InstanceDefinitionSnapshot{instance_id: ^instance_id}} =
               SnapshotStore.get_by_instance_id(instance_id, prefix: schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 4: "deleting a process_definitions row that an
  # instance_definition_snapshots row references is rejected by the database
  # (foreign_key_violation), and the snapshot row remains present and unmodified"
  #
  # Per the design doc §7, this is REQ-027's already-shipped FK, not SnapshotStore's
  # own code -- there is no SnapshotStore delete function to call, so this test
  # exercises Repo.delete/2 directly against the process_definitions row.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- delete-rejection is not SnapshotStore's own code" do
    test "deleting a process_definitions row referenced by a snapshot raises Ecto.ConstraintError (foreign_key_violation) and the snapshot survives, byte-for-byte" do
      %{schema_name: schema_name} = provisioned_tenant()

      captured_graph = %{
        "nodes" => [%{"id" => "start", "node_type" => "start"}],
        "edges" => []
      }

      definition = insert_definition!(schema_name, %{graph: captured_graph})
      instance_id = Ecto.UUID.generate()

      assert {:ok, snapshot_before} =
               SnapshotStore.create(instance_id, definition.id, prefix: schema_name)

      exception =
        assert_raise Ecto.ConstraintError, fn ->
          Repo.delete(definition, prefix: schema_name)
        end

      assert exception.message =~ "instance_definition_snapshots_definition_id_fkey"

      # The snapshot is intact -- same struct, not merely "still exists".
      assert {:ok, snapshot_after} =
               SnapshotStore.get_by_instance_id(instance_id, prefix: schema_name)

      assert snapshot_after == snapshot_before
      assert snapshot_after.graph == captured_graph

      # ...and the definition itself is still there, since the delete was rejected.
      assert Repo.get(ProcessDefinition, definition.id, prefix: schema_name)
      assert snapshot_count(schema_name) == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 5: "the moduledoc explicitly states the EE-01
  # instance-start integration point is S3 scope, not built here"
  #
  # A doc-content check per the requirement's own wording -- no database I/O.
  # ---------------------------------------------------------------------------------

  describe "AC5 -- moduledoc scope statement" do
    test "SnapshotStore's moduledoc states EE-01/instance-start integration is S3 scope, not built here" do
      {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(SnapshotStore)

      normalized = String.replace(moduledoc, ~r/\s+/, " ")

      assert normalized =~ "EE-01"

      assert normalized =~ "S3 scope, not built here",
             "moduledoc does not state the EE-01 integration point is S3 scope, not built here: #{normalized}"

      assert normalized =~ "instance-start"
    end
  end

  # ---------------------------------------------------------------------------------
  # INV-8 UUID-cast and :prefix guards (ELIXIR-DEV's documented deliberate
  # divergence from the design doc's literal §4.3 text): malformed/struct-shaped
  # instance_id, definition_id, and opts[:prefix] each return a typed
  # {:error, _}, never raise.
  # ---------------------------------------------------------------------------------

  describe "INV-8 UUID-cast and prefix guards" do
    test "create/3 with a non-UUID-string instance_id returns {:error, :invalid_instance_id}, no raise" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition = insert_definition!(schema_name)

      assert {:error, :invalid_instance_id} =
               SnapshotStore.create("not-a-uuid", definition.id, prefix: schema_name)

      assert snapshot_count(schema_name) == 0
    end

    test "create/3 with a non-UUID-string definition_id returns {:error, :invalid_definition_id}, no raise" do
      %{schema_name: schema_name} = provisioned_tenant()

      instance_id = Ecto.UUID.generate()

      assert {:error, :invalid_definition_id} =
               SnapshotStore.create(instance_id, "not-a-uuid", prefix: schema_name)

      assert snapshot_count(schema_name) == 0
    end

    test "create/3 with a struct-shaped instance_id returns {:error, :invalid_instance_id}, not a raised error" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition = insert_definition!(schema_name)

      assert {:error, :invalid_instance_id} =
               SnapshotStore.create(~D[2026-01-01], definition.id, prefix: schema_name)

      assert snapshot_count(schema_name) == 0
    end

    test "create/3 with a struct-shaped definition_id returns {:error, :invalid_definition_id}, not a raised error" do
      %{schema_name: schema_name} = provisioned_tenant()

      instance_id = Ecto.UUID.generate()

      assert {:error, :invalid_definition_id} =
               SnapshotStore.create(instance_id, ~D[2026-01-01], prefix: schema_name)

      assert snapshot_count(schema_name) == 0
    end

    test "create/3 with opts missing :prefix, or prefix: \"\", returns {:error, :missing_prefix}" do
      instance_id = Ecto.UUID.generate()
      definition_id = Ecto.UUID.generate()

      assert {:error, :missing_prefix} = SnapshotStore.create(instance_id, definition_id, [])

      assert {:error, :missing_prefix} =
               SnapshotStore.create(instance_id, definition_id, prefix: "")

      assert {:error, :missing_prefix} =
               SnapshotStore.create(instance_id, definition_id, prefix: nil)
    end

    test "get_by_instance_id/2 with a malformed instance_id returns {:error, :invalid_instance_id}, no raise" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:error, :invalid_instance_id} =
               SnapshotStore.get_by_instance_id("also-not-a-uuid", prefix: schema_name)
    end

    test "get_by_instance_id/2 with a struct-shaped instance_id returns {:error, :invalid_instance_id}, not a raised error" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:error, :invalid_instance_id} =
               SnapshotStore.get_by_instance_id(~D[2026-01-01], prefix: schema_name)
    end

    test "get_by_instance_id/2 with opts missing :prefix returns {:error, :missing_prefix}" do
      instance_id = Ecto.UUID.generate()

      assert {:error, :missing_prefix} = SnapshotStore.get_by_instance_id(instance_id, [])
      assert {:error, :missing_prefix} = SnapshotStore.get_by_instance_id(instance_id, prefix: "")
    end
  end
end
