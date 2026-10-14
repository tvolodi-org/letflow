defmodule Letflow.TenantProvisioningEventSeedTest do
  @moduledoc """
  WF-03 regression test for ISS-0072 (GH#257): `Letflow.EventStore.append/2`
  rejected `TASK_COMPLETED`, `INSTANCE_CANCELLED`, `INSTANCE_PINS_REBOUND`,
  `SUB_PROCESS_COMPLETED`, and `EXECUTION_ERROR` against any real,
  non-test-fixture tenant schema, because
  `Letflow.TenantProvisioning.maybe_seed_platform_event_types/2` only ever
  seeded `INSTANCE_STARTED`. See `test/specs/ISS-0072.md` for the full
  fail-then-pass methodology and the OQ-1 collision finding this file's
  moduledoc also documents.

  ## Why this file provisions tenants the *normal* way, not via a test fixture

  ISS-0072's bug was specifically that a tenant schema provisioned through
  the real, default-manifest `TenantProvisioning.replay_migrations/2` path
  (i.e. every real, non-test tenant) had no registry row for these 5 types --
  every *test* in the suite that exercised these write paths worked anyway,
  because each test file's own fixture called
  `Letflow.EventStore.Registry.register_type/2` directly for itself before
  exercising the code under test (ISS-0072's own description names
  `engine_cancel_instance_test.exs`, `engine_complete_task_test.exs`,
  `event_store_test.exs` as exactly this pattern). A test that also
  self-registers these types would defeat the entire point of this
  regression test -- it would pass identically against both the buggy and
  the fixed code, proving nothing. This file therefore calls
  `TenantProvisioning.provision_tenant_schema/1` +
  `TenantProvisioning.replay_migrations/2` (its **default**
  `migration_source`, i.e. the real `tenant_scoped_migrations/0` manifest --
  never a caller-supplied fixture list) and never calls
  `Registry.register_type/2` itself anywhere in this file. Matches
  `test/letflow/event_store_test.exs`'s own `provisioned_tenant/1` fixture
  pattern (real `CREATE SCHEMA`, real migration replay, Sandbox `:auto` mode
  + manual `on_exit/1` cleanup because `Ecto.Migrator` needs a second real DB
  connection the DataCase sandbox can't hand out) -- see that file's
  moduledoc for the full ExUnit-source-level proof behind the `async: false`
  + `:auto`-mode combination this file reuses verbatim.

  ## Verified fail-then-pass (not merely asserted -- see test/specs/ISS-0072.md)

  Confirmed directly from `lib/letflow/tenant_provisioning.ex` at the
  pre-fix commit (`09ac8ee`, `git show
  09ac8ee:lib/letflow/tenant_provisioning.ex`): the pre-fix
  `@instance_started_event_type_attrs` module attribute held exactly one
  entry, `"INSTANCE_STARTED"`, and `maybe_seed_platform_event_types/2`'s body
  called `Registry.register_type/2` exactly once, against that one entry.
  None of `"TASK_COMPLETED"`, `"INSTANCE_CANCELLED"`,
  `"INSTANCE_PINS_REBOUND"`, `"SUB_PROCESS_COMPLETED"`, or
  `"EXECUTION_ERROR"` appeared anywhere in that pre-fix file. Every payload
  this test file appends for those 5 types would therefore have hit
  `Registry.get_type/2`'s "no matching row" branch and
  `EventStore.append/2` would have returned `{:error, :unknown_event_type}}`
  for every one of them, against the pre-fix code, in a schema provisioned
  the way this file provisions it (no test-fixture self-registration) --
  exactly the failure this regression test is designed to catch. This was
  independently re-confirmed empirically per this file's own git history
  note in `test/specs/ISS-0072.md` (checked out the pre-fix commit and ran
  a probe equivalent to this file's own assertions).
  """

  use Letflow.DataCase, async: false

  alias Letflow.EventStore
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.EventStore.Registry.EventType
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  import Ecto.Query

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- mirrors event_store_test.exs's provisioned_tenant/1 /
  # append_attrs/2 / seed_projection!/4 pattern exactly (see moduledoc). Provisioned
  # via Letflow.TenantFixture (ISS-0112 / GH#366).
  # ---------------------------------------------------------------------------------

  # THE key fixture: provisions a tenant exactly the way a real, production
  # tenant is provisioned -- real CREATE SCHEMA, real default-manifest
  # replay_migrations/2 (no caller-supplied migration_source, so
  # maybe_seed_platform_event_types/2's `using_default_manifest?` guard is
  # true and the real seed path runs) -- and registers NOTHING itself. Any
  # event type this test can successfully append was seeded by production
  # code alone. `template: :replay` (not TenantFixture's default `:clone`) is
  # deliberate and load-bearing here: this file's whole point is to exercise
  # the real `provision_tenant_schema/1` + `replay_migrations/2` (default
  # manifest) path per tenant, not a copy of a pre-built template schema --
  # see moduledoc's "Why this file provisions tenants the normal way".
  defp provisioned_tenant do
    TenantFixture.provisioned_tenant!(
      slug_prefix: "iss0072",
      display_name: "ISS-0072 Regression Test Tenant",
      template: :replay
    )
  end

  defp unique_idempotency_key(prefix \\ "ISS0072") do
    prefix <> "_" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp seed_projection!(schema_name, instance_id, status \\ :active) do
    %InstanceProjection{}
    |> InstanceProjection.insert_changeset(%{
      instance_id: instance_id,
      status: status,
      last_event_seq: 0,
      definition_id: Ecto.UUID.generate()
    })
    |> Repo.insert!(prefix: schema_name)
  end

  defp append_attrs(event_type, payload_map) do
    %{
      instance_id: Ecto.UUID.generate(),
      event_type: event_type,
      payload: Jason.encode!(payload_map),
      actor_id: Ecto.UUID.generate(),
      idempotency_key: unique_idempotency_key()
    }
  end

  # Minimal valid payload per §4 of lib/letflow/design/iss072-event-type-registration.md
  # -- exactly the required-field shape each json_schema literal demands, nothing more.
  defp minimal_payload_for("INSTANCE_STARTED") do
    %{"definition_id" => Ecto.UUID.generate(), "initial_variables" => %{}}
  end

  defp minimal_payload_for("TASK_COMPLETED") do
    %{
      "task_id" => Ecto.UUID.generate(),
      "node_id" => "task",
      "output_variables" => %{},
      "activated_nodes" => []
    }
  end

  defp minimal_payload_for("INSTANCE_CANCELLED") do
    %{"cancelled_task_ids" => [], "cancelled_token_ids" => []}
  end

  defp minimal_payload_for("INSTANCE_PINS_REBOUND") do
    %{"entries" => [], "actor" => "iss0072-test-actor"}
  end

  defp minimal_payload_for("SUB_PROCESS_COMPLETED") do
    %{
      "child_instance_id" => Ecto.UUID.generate(),
      "output_variables" => %{},
      "activated_nodes" => []
    }
  end

  defp minimal_payload_for("EXECUTION_ERROR") do
    %{
      "error_type" => "iss0072_probe",
      "affected" => %{"kind" => "node"},
      "reason" => "iss0072 regression probe",
      "variables" => %{}
    }
  end

  # The 5 types ISS-0072 found unregistered against a real, non-fixture
  # tenant schema. INSTANCE_STARTED (the pre-existing, already-working seed)
  # is asserted separately below, since it isn't part of ISS-0072's bug --
  # asserting it here too would blur "already worked" with "ISS-0072 fixed
  # this".
  @newly_seeded_event_types [
    "TASK_COMPLETED",
    "INSTANCE_CANCELLED",
    "INSTANCE_PINS_REBOUND",
    "SUB_PROCESS_COMPLETED",
    "EXECUTION_ERROR"
  ]

  # ---------------------------------------------------------------------------------
  # Core regression: each of the 5 types ISS-0072 found unregistered now
  # appends successfully against a REAL, non-test-fixture tenant schema.
  # ---------------------------------------------------------------------------------

  describe "ISS-0072: the 5 newly-seeded event types now append against a real tenant schema" do
    for event_type <- @newly_seeded_event_types do
      test "#{event_type} -- EventStore.append/2 succeeds where it used to reject with :unknown_event_type" do
        event_type = unquote(event_type)

        %{schema_name: schema_name} = provisioned_tenant()

        attrs = append_attrs(event_type, minimal_payload_for(event_type))
        seed_projection!(schema_name, attrs.instance_id)

        assert {:ok, %{event: event, is_duplicate: false}} =
                 EventStore.append(attrs, prefix: schema_name)

        assert event.event_type == event_type
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # Regression against the pre-existing seed: INSTANCE_STARTED must still work
  # (proves the fix's Enum.reduce_while/3 rewrite didn't regress the one entry
  # that already worked before ISS-0072).
  # ---------------------------------------------------------------------------------

  describe "INSTANCE_STARTED still works (pre-existing seed, not touched by ISS-0072's 5 additions)" do
    test "EventStore.append/2 succeeds for INSTANCE_STARTED against a freshly-provisioned tenant" do
      %{schema_name: schema_name} = provisioned_tenant()

      attrs = append_attrs("INSTANCE_STARTED", minimal_payload_for("INSTANCE_STARTED"))
      seed_projection!(schema_name, attrs.instance_id)

      assert {:ok, %{event: event, is_duplicate: false}} =
               EventStore.append(attrs, prefix: schema_name)

      assert event.event_type == "INSTANCE_STARTED"
    end
  end

  # ---------------------------------------------------------------------------------
  # Negative control: a genuinely still-unregistered type is still rejected --
  # proves the fix seeds exactly the 9 named types, not indiscriminately
  # everything.
  #
  # REQ-140 note: this used to name DEFINITION_PROMOTED as the still-unregistered
  # example (one of the 3 types the design doc §1 "Out of scope" explicitly named
  # as deliberately NOT seeded, "no production writer exists for it"). REQ-140
  # gave DEFINITION_PROMOTED, DEFINITION_VERSION_ROLLED_BACK and
  # PROMOTION_ASSERTION_TEARDOWN_FAILED real production writers
  # (Letflow.EventStore.PlatformEvents) and added all three to
  # @platform_event_type_seed_attrs, so DEFINITION_PROMOTED is now registered and
  # would no longer prove this negative control. Retargeted to a fabricated type
  # name that is not, and will never be, seeded by production code, so this
  # control keeps testing what it always meant to: the seed list isn't
  # indiscriminate.
  # ---------------------------------------------------------------------------------

  describe "still-unregistered types remain rejected (proves the seed list isn't indiscriminate)" do
    test "EventStore.append/2 still returns {:error, :unknown_event_type} for a type never seeded by production code" do
      %{schema_name: schema_name} = provisioned_tenant()

      # No instance_projections row is seeded here -- Registry.validate_payload/3
      # runs (and fails) before append/2 ever touches instance_projections, so
      # this assertion is unaffected by projection state (confirmed directly
      # from lib/letflow/event_store.ex's `with` chain: fetch_event_type/1 and
      # Registry.validate_payload/3 both precede the transactional phase).
      attrs =
        append_attrs("ISS0072_NEGATIVE_CONTROL_NEVER_SEEDED", %{"anything" => "goes"})

      assert {:error, :unknown_event_type} = EventStore.append(attrs, prefix: schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # OQ-1 (design doc §9): confirms register_type/2's own idempotency backstop
  # ({:error, :duplicate_event_type_version} folding to :ok) still holds for a
  # SECOND replay_migrations/2 call against an already-seeded tenant -- the
  # production-code half of OQ-1. The test-fixture-collision half of OQ-1 (an
  # existing test file's OWN register_type/2 call colliding with this seed) is
  # NOT reproduced here -- see test/specs/ISS-0072.md's "OQ-1 finding" section
  # for that investigation; it is a defect in unrelated pre-existing test
  # fixture files, not in the production seeding logic this test file covers,
  # and has been filed as its own issue rather than fixed in this file.
  # ---------------------------------------------------------------------------------

  describe "OQ-1: replay_migrations/2 re-run against an already-seeded tenant stays idempotent" do
    test "a second replay_migrations/2 call for the same tenant still returns :ok overall, and the 20 rows are not duplicated" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()

      assert {:ok, _} = TenantProvisioning.replay_migrations(tenant_id)

      %{rows: [[count]]} =
        Repo.query!(
          "SELECT COUNT(*) FROM \"#{schema_name}\".\"event_type_registry\"",
          []
        )

      # REQ-215 (lib/letflow/design/req215-service-task-engine-wiring.md §3.2)
      # added SERVICE_TASK_COMPLETED to @platform_event_type_seed_attrs,
      # raising the seeded total from 12 to 13. ISS-0721
      # (lib/letflow/design/iss0721-entity-event-type-seeding.md) adds the 3
      # ENTITY_RECORD_* types on top of that, raising the total to 16. REQ-391
      # adds ATTACHMENT_ATTACHED/ATTACHMENT_REMOVED on top of that, raising
      # the total to 18. GH 2534 7c-1 adds SCRIPT_TASK_COMPLETED/SCRIPT_RUN_RECORDED,
      # raising it to 20.
      assert count == 20

      # And the seeded types are still all usable after the re-seed no-op.
      attrs = append_attrs("TASK_COMPLETED", minimal_payload_for("TASK_COMPLETED"))
      seed_projection!(schema_name, attrs.instance_id)

      assert {:ok, %{event: event}} = EventStore.append(attrs, prefix: schema_name)
      assert event.event_type == "TASK_COMPLETED"
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-140 AC12: "a tenant provisioned BEFORE this change gains the three
  # registry rows after a replay_migrations/2 call, and a second
  # replay_migrations/2 call on the same tenant is a no-op returning success --
  # one test covers both halves"
  #
  # This tree cannot literally provision a tenant under the pre-REQ-140 code (the
  # @platform_event_type_seed_attrs list has since grown further, most recently
  # REQ-391's ATTACHMENT_ATTACHED/ATTACHMENT_REMOVED pair -- 15 entries total as
  # of this test), so "provisioned BEFORE this change" is reproduced structurally
  # instead: provision a tenant normally (seeding all 15 rows, since replay_migrations/2 is
  # already generic over the list's length per REQ-140's design §5.1), then
  # directly delete the exact 3 rows REQ-140 added -- reproducing the
  # only-10-rows-present state a pre-REQ-140 tenant would actually be in -- and
  # confirm a subsequent replay_migrations/2 call (the REAL, already-shipped
  # maybe_seed_platform_event_types/2, unmodified by this file) re-adds exactly
  # those 3 rows. A second replay_migrations/2 call after that must be a pure
  # no-op returning :ok, per register_type/2's own
  # {:error, :duplicate_event_type_version} -> :ok folding (unchanged by REQ-140).
  # ---------------------------------------------------------------------------------

  describe "REQ-140 AC12: a pre-existing (6-row) tenant gains the 3 new registry rows on replay, idempotently" do
    test "replay_migrations/2 backfills the 3 REQ-140 types, and a second call is a no-op" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()

      # Reproduce the pre-REQ-140 (6-row) state: delete exactly the 3 rows
      # REQ-140 added, leaving the other rows (ISS-0072's own 6, plus every
      # later addition -- TIMER_FIRED/effect_applied/
      # ordering_lag_threshold_exceeded/SERVICE_TASK_COMPLETED) untouched.
      req140_types = [
        "DEFINITION_PROMOTED",
        "DEFINITION_VERSION_ROLLED_BACK",
        "PROMOTION_ASSERTION_TEARDOWN_FAILED"
      ]

      {3, _} =
        Repo.delete_all(
          from(t in EventType, where: t.name in ^req140_types),
          prefix: schema_name
        )

      count_before =
        Repo.aggregate(EventType, :count, prefix: schema_name)

      # ISS-0721 (lib/letflow/design/iss0721-entity-event-type-seeding.md)
      # now seeds the 3 ENTITY_RECORD_* types unconditionally for every real
      # tenant at provisioning time, and REQ-391 adds
      # ATTACHMENT_ATTACHED/ATTACHMENT_REMOVED on top of that, so the
      # pre-REQ-140 (6-row) state reproduced above by deleting the 3 REQ-140
      # rows leaves 15 rows here (18 total - 3 deleted), not 10; GH 2534 7c-1 adds the two
      # SCRIPT_* types, so 17 (20 - 3).
      assert count_before == 17

      # First replay_migrations/2 call after the simulated pre-existing state --
      # backfills the 3 missing rows.
      assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant_id)

      names_after_backfill =
        EventType
        |> Repo.all(prefix: schema_name)
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert names_after_backfill ==
               Enum.sort([
                 "INSTANCE_STARTED",
                 "TASK_COMPLETED",
                 "INSTANCE_CANCELLED",
                 "INSTANCE_PINS_REBOUND",
                 "SUB_PROCESS_COMPLETED",
                 "EXECUTION_ERROR",
                 "DEFINITION_PROMOTED",
                 "DEFINITION_VERSION_ROLLED_BACK",
                 "PROMOTION_ASSERTION_TEARDOWN_FAILED",
                 "TIMER_FIRED",
                 "SERVICE_TASK_COMPLETED",
                 "effect_applied",
                 "ordering_lag_threshold_exceeded",
                 # ISS-0721: the 3 ENTITY_RECORD_* types are seeded
                 # unconditionally alongside the platform types and were
                 # never deleted by this test's req140_types delete, so they
                 # are present both before and after the backfill.
                 "ENTITY_RECORD_CREATED",
                 "ENTITY_RECORD_UPDATED",
                 "ENTITY_RECORD_DELETED",
                 # REQ-391: seeded unconditionally alongside the other
                 # platform types, never deleted by this test's
                 # req140_types delete, so present both before and after
                 # the backfill (same shape as the ENTITY_RECORD_* trio
                 # above).
                 "ATTACHMENT_ATTACHED",
                 "ATTACHMENT_REMOVED",
                 # GH 2534 7c-1: the script SERVICE_TASK route's two instance event types.
                 "SCRIPT_TASK_COMPLETED",
                 "SCRIPT_RUN_RECORDED"
               ])

      # The 3 backfilled types are usable via append_platform_event/2 --
      # confirms these aren't just registry rows but genuinely functional.
      assert {:ok, %{event: event}} =
               EventStore.append_platform_event(
                 %{
                   instance_id: EventStore.platform_instance_id(),
                   event_type: "DEFINITION_PROMOTED",
                   actor_id: Ecto.UUID.generate(),
                   payload:
                     Jason.encode!(%{
                       "review_id" => Ecto.UUID.generate(),
                       "source_tenant_id" => Ecto.UUID.generate(),
                       "target_tenant_id" => Ecto.UUID.generate(),
                       "source_definition_id" => Ecto.UUID.generate(),
                       "target_definition_id" => Ecto.UUID.generate(),
                       "process_key" => "req140-ac12-probe"
                     }),
                   idempotency_key: "req140-ac12-probe-#{System.unique_integer([:positive])}"
                 },
                 prefix: schema_name
               )

      assert event.event_type == "DEFINITION_PROMOTED"

      # Second replay_migrations/2 call: a no-op, still returns success, and
      # does NOT duplicate any of the 20 rows (13 platform + 3 ISS-0721
      # ENTITY_RECORD_* entity types + 2 REQ-391 ATTACHMENT_* types).
      assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant_id)

      count_after_second_call =
        Repo.aggregate(EventType, :count, prefix: schema_name)

      assert count_after_second_call == 20
    end
  end
end
