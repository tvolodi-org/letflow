defmodule Letflow.TenantProvisioning.EntityEventTypeSeedingTest do
  @moduledoc """
  Regression test for ISS-0721: `Letflow.Entities.EventTypes.seed!/1`
  (REQ-228) registers the three `ENTITY_RECORD_CREATED/UPDATED/DELETED`
  event types, but before this fix had zero production call sites -- every
  call site outside `event_types.ex` itself was a test fixture manually
  invoking `seed!/1`. A freshly-provisioned tenant's `event_type_registry`
  therefore had no rows for these event types, so the first real
  entity-record write failed with `{:error, :unknown_event_type}`.

  See `lib/letflow/design/iss0721-entity-event-type-seeding.md` section 6
  for the exact coverage this file provides. Unlike every other test in
  `test/letflow/tenant_provisioning/` and `test/letflow/entities/`, this
  fixture deliberately does **not** call `EventTypes.seed!/1` manually --
  the whole point of this regression test is to prove provisioning alone
  (via `Letflow.TenantProvisioning.replay_migrations/2`'s
  `maybe_seed_entity_event_types/2` clause) is now sufficient.

  Uses `Letflow.DataCase` (real Postgres), `async: false` -- provisions a
  real tenant schema. Fixture shape mirrors
  `test/letflow/entities/records_test.exs`'s own `provisioned_tenant/0`,
  minus the manual `EventTypes.seed!/1` call.

  ISS-0112 batch-7 migration note: this file grep-matched the A∩B batch
  category (SandboxAutoMode teardown + EventTypes.seed! step), but a fresh
  read (per the migration plan's §3 step 1) found it is NOT actually a B
  file -- the whole point of this regression test is that it deliberately
  omits the manual `EventTypes.seed!/1` call the B pattern would add, to
  prove `replay_migrations/2`'s own `maybe_seed_entity_event_types/2` path
  seeds those event types on its own. Only the A half (teardown: false
  composed with this file's own on_exit) applies here; no B-pattern seed!
  call was added. Also note `TenantFixture.provisioned_tenant!/1` defaults
  to `template: :clone` (schema-clone fast path, ISS-0427), which does NOT
  call `replay_migrations/2` at all -- that would silently skip the exact
  code path (`maybe_seed_entity_event_types/2`) this regression test
  exists to exercise. `template: :replay` is passed explicitly below to
  keep that path live.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.Records
  alias Letflow.EventStore.Registry
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration
  alias Letflow.Test.SandboxAutoMode

  import Ecto.Query

  @entity_event_types [
    "ENTITY_RECORD_CREATED",
    "ENTITY_RECORD_UPDATED",
    "ENTITY_RECORD_DELETED",
    "ENTITY_RECORD_MIGRATED"
  ]

  # ---------------------------------------------------------------------------------
  # Fixture -- provisions via Letflow.TenantFixture (ISS-0112 / GH#366),
  # teardown: false + template: :replay (see moduledoc note above for why
  # :replay is required here, and why this file omits the B-pattern
  # EventTypes.seed!/1 call other A∩B-classified files in this batch add).
  # ---------------------------------------------------------------------------------

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp provisioned_tenant_no_manual_seed do
    SandboxAutoMode.provision!(Letflow.Repo, fn ->
      # No migration_source given -> using_default_manifest? is true inside
      # replay_migrations/2 -> maybe_seed_entity_event_types/2's true clause
      # runs. Deliberately NO `EventTypes.seed!/1` call here.
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "iss0721-entity-event-seed",
          display_name: "ISS-0721 Entity Event Type Seeding Test Tenant",
          teardown: false,
          template: :replay
        )

      on_exit(fn ->
        # Same ISS-0580 hazard as every other provisioned_tenant/0 fixture in
        # this suite (see column_promotion_test.exs's own comment for the
        # full explanation): this callback runs after the test process is
        # gone, so it must not assume :manual mode still has a connection
        # checked out for THIS (OnExitHandler) process.
        Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

        case TenantProvisioning.schema_name_for_tenant(tenant_id) do
          {:ok, schema_name} -> drop_schema!(schema_name)
          {:error, :invalid_tenant_id} -> :ok
        end

        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))

        SandboxAutoMode.exit_auto_mode!(Letflow.Repo)
      end)

      %{tenant_id: tenant_id, schema_name: schema_name}
    end)
  end

  defp create_active_definition!(schema) do
    definition = %{
      name: "widget",
      display_name: "Widget",
      fields: [%{name: "label", type: :string}]
    }

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

  defp create_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        entity_type: "widget",
        field_values: %{"label" => "first"},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate()
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------------
  # Core regression assertion: a real entity-record write succeeds right
  # after provisioning, with no manual seed!/1 call anywhere in this test.
  # ---------------------------------------------------------------------------------

  describe "ISS-0721 -- entity event types are auto-seeded by replay_migrations/2" do
    test "the three ENTITY_RECORD_* event types are registered as a side effect of provisioning alone" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant_no_manual_seed()

      for event_type <- @entity_event_types do
        assert {:ok, _type} = Registry.get_type(event_type, tenant_id)
      end

      # The concrete, positive assertion the design doc calls for: drive a
      # real entity-record write through the actual production path
      # (Records.create_record/2) rather than asserting Registry.get_type/2
      # alone -- this is the exact reproduction path ISSUE-FIXER confirmed
      # ISS-0721 through, so it is the strongest proof the gap is closed.
      create_active_definition!(schema)

      assert {:ok, %{record: record}} = Records.create_record(create_attrs(), schema)
      refute record.deleted

      assert {:ok, %{record: updated}} =
               Records.update_record(
                 create_attrs(%{
                   record_id: record.record_id,
                   field_values: %{"label" => "second"}
                 }),
                 schema
               )

      assert updated.field_values["label"] == "second"

      assert {:ok, %{record: deleted}} =
               Records.delete_record(
                 %{
                   record_id: record.record_id,
                   entity_type: "widget",
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      assert deleted.deleted
    end

    test "a second replay_migrations/2 call against the same tenant does not error, and writes still succeed" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant_no_manual_seed()

      # Simulates a tenant re-migration -- seed!/1's internal duplicate
      # tolerance (design doc §4) must make this a no-op, not an error.
      assert {:ok, _applied_versions_again} = TenantProvisioning.replay_migrations(tenant_id)

      create_active_definition!(schema)

      assert {:ok, %{record: record}} = Records.create_record(create_attrs(), schema)
      refute record.deleted
    end
  end
end
