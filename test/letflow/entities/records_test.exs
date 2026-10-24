defmodule Letflow.Entities.RecordsTest do
  @moduledoc """
  Integration tests for `Letflow.Entities.EventTypes`, `Letflow.Entities.Records`,
  `Letflow.Entities.Record.Latest`, and `Letflow.Entities.EntityTypeInstance`
  (REQ-228) -- event-type registration, create/update/delete commands,
  idempotent-replay parity, and the per-entity-TYPE synthetic-instance
  mapping. See
  `lib/letflow/design/req228-entity-event-registration-commands.md` for the
  design this file verifies, and REQ-228's own `docs/requirements.yaml`
  entry for the authoritative 8 acceptance criteria this file's `describe`
  blocks are grouped by.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  Self-contained: provisions its own tenant schema(s), mirroring
  `test/letflow/entities/definitions_test.exs`'s own hand-rolled
  tenant-fixture pattern (DIRECTIVE T-4).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EventStore
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.EventStore.InstanceSequence
  alias Letflow.EventStore.Registry
  alias Letflow.EventStore.Registry.EventType
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration
  alias Letflow.Test.SandboxAutoMode

  import Ecto.Query

  # ---------------------------------------------------------------------------------
  # Fixtures -- provisions via Letflow.TenantFixture (ISS-0112 / GH#366),
  # teardown: false because this file wraps provisioning in
  # SandboxAutoMode.provision!/2 and needs its own on_exit to force :auto mode
  # back on before the drop/delete cleanup and restore :manual afterward (the
  # ISS-0580 leak fix) -- TenantFixture's own default teardown does not do that
  # composition, so it stays disabled and this file's pre-existing on_exit is
  # kept untouched, matching category A's documented pattern. The extra
  # EventTypes.seed!/1 call after provisioning is this file's own
  # category-B step, likewise kept unchanged.
  # ---------------------------------------------------------------------------------

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp provisioned_tenant do
    SandboxAutoMode.provision!(Letflow.Repo, fn ->
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "req228-entities",
          display_name: "REQ-228 Entity Records Test Tenant",
          teardown: false
        )

      on_exit(fn ->
        # ISS-0580 rework: this callback runs AFTER the test process (and thus
        # SandboxAutoMode.provision!/2's own restore-to-:manual-plus-checkout,
        # scoped to that now-gone process) is gone -- so it must not assume
        # :manual mode still has a connection checked out for THIS (OnExitHandler)
        # process. Force :auto mode first so the DROP SCHEMA/delete_all cleanup
        # below always gets a real, checked-in connection regardless of what mode
        # the test process left the pool in. Mirrors role_registry_test.exs's own
        # on_exit/1 handling of this exact hazard.
        Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

        case TenantProvisioning.schema_name_for_tenant(tenant_id) do
          {:ok, schema_name} -> drop_schema!(schema_name)
          {:error, :invalid_tenant_id} -> :ok
        end

        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))

        # REVIEWER fix (ISS-0580): restore :manual after cleanup -- leaving the
        # force-:auto above unrestored would reopen this exact leak, once per
        # test in this file instead of once ever. No checkout needed (same
        # reasoning as SandboxAutoMode.exit_auto_mode!/1's own doc: this
        # OnExitHandler process is not going to issue another Repo call).
        SandboxAutoMode.exit_auto_mode!(Letflow.Repo)
      end)

      assert {:ok, _seed_result} = EventTypes.seed!(schema_name)

      %{tenant_id: tenant_id, schema_name: schema_name}
    end)
  end

  defp valid_definition(overrides \\ %{}) do
    Map.merge(
      %{
        name: "customer",
        display_name: "Customer",
        fields: [
          %{name: "customer_name", type: :string, required: true},
          %{name: "age", type: :integer}
        ]
      },
      overrides
    )
  end

  defp create_active_definition!(schema, overrides \\ %{}) do
    definition = valid_definition(overrides)

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
        entity_type: "customer",
        field_values: %{"customer_name" => "Acme", "age" => 42},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate()
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- ENTITY_RECORD_CREATED/UPDATED/DELETED each registered exactly once.
  # ---------------------------------------------------------------------------------

  describe "AC1 -- EventTypes.seed!/1 registers the three event types exactly once" do
    test "each of the three event types is registered exactly once, verified against event_type_registry" do
      %{schema_name: schema} = provisioned_tenant()

      for name <- ~w(ENTITY_RECORD_CREATED ENTITY_RECORD_UPDATED ENTITY_RECORD_DELETED) do
        rows = Repo.all(from(e in EventType, where: e.name == ^name), prefix: schema)
        assert length(rows) == 1
        # GH #2659: CREATED is bumped IN PLACE to v2 (optional external_ref); no v1 row beside it.
        expected_version = if name == "ENTITY_RECORD_CREATED", do: 2, else: 1
        assert hd(rows).schema_version == expected_version
      end
    end

    test "calling seed!/1 a second time is idempotent -- no duplicate rows, no error" do
      %{schema_name: schema} = provisioned_tenant()

      assert {:ok, %{registered: [], skipped: skipped}} = EventTypes.seed!(schema)

      assert Enum.sort(skipped) ==
               Enum.sort(~w(ENTITY_RECORD_CREATED ENTITY_RECORD_UPDATED ENTITY_RECORD_DELETED))

      entity_event_type_count =
        EventType
        |> where(
          [e],
          e.name in ~w(ENTITY_RECORD_CREATED ENTITY_RECORD_UPDATED ENTITY_RECORD_DELETED)
        )
        |> Repo.aggregate(:count, prefix: schema)

      assert entity_event_type_count == 3
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- create_record/2 appends exactly one event + updates
  # entity_record_latest in the same transaction; a forced mid-transaction
  # failure leaves neither committed.
  # ---------------------------------------------------------------------------------

  describe "AC2 -- create_record/2 atomicity" do
    test "appends exactly one ENTITY_RECORD_CREATED event and inserts one entity_record_latest row" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, %{record: record, is_duplicate: false}} =
               Records.create_record(create_attrs(), schema)

      assert record.entity_type == "customer"
      assert record.field_values == %{"customer_name" => "Acme", "age" => 42}
      refute record.deleted

      assert Repo.aggregate(Event, :count, prefix: schema) == 1
      assert Repo.aggregate(Latest, :count, prefix: schema) == 1

      [event] = Repo.all(Event, prefix: schema)
      assert event.event_type == "ENTITY_RECORD_CREATED"
      assert event.payload["record_id"] == record.record_id
    end

    test "a forced failure after the event append but before the projection update leaves NEITHER committed" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      # Reach directly into the same composable pipeline create_record/2 uses,
      # but inject a failing final step in place of :upsert_record_latest --
      # proves the whole thing is one transaction, not two independent writes.
      entity_type = "customer"
      {:ok, instance_id} = EntityTypeInstance.get_or_create(entity_type, schema)

      event_attrs = %{
        instance_id: instance_id,
        event_type: "ENTITY_RECORD_CREATED",
        payload:
          Jason.encode!(%{
            "entity_type" => entity_type,
            "entity_def_version" => "aa",
            "record_id" => Ecto.UUID.generate(),
            "field_values" => %{"customer_name" => "Acme", "age" => 42}
          }),
        actor_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate()
      }

      assert {:ok, multi} = EventStore.append_multi(Ecto.Multi.new(), event_attrs, prefix: schema)

      result =
        multi
        |> Ecto.Multi.run(:upsert_record_latest, fn _repo, _changes ->
          {:error, :forced_failure_for_test}
        end)
        |> Repo.transaction()

      assert {:error, :upsert_record_latest, :forced_failure_for_test, _changes} = result

      assert Repo.aggregate(Event, :count, prefix: schema) == 0
      assert Repo.aggregate(Latest, :count, prefix: schema) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- duplicate idempotency-key submission returns the ORIGINAL record
  # both times (ISS-0159/GH#480 parity).
  # ---------------------------------------------------------------------------------

  describe "AC3 -- idempotent replay returns the ORIGINAL record" do
    test "submitting create_record/2 twice with the same idempotency_key returns the same record_id/field_values both times" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      attrs = create_attrs()

      assert {:ok, %{record: first_record, is_duplicate: false}} =
               Records.create_record(attrs, schema)

      assert {:ok, %{record: second_record, is_duplicate: true}} =
               Records.create_record(attrs, schema)

      assert first_record.record_id == second_record.record_id
      assert first_record.field_values == second_record.field_values
      assert first_record.entity_type == second_record.entity_type

      # Only one event and one entity_record_latest row exist -- no second
      # record was minted on replay.
      assert Repo.aggregate(Event, :count, prefix: schema) == 1
      assert Repo.aggregate(Latest, :count, prefix: schema) == 1
    end

    test "a THIRD submission with the same idempotency_key still returns the same original record" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      attrs = create_attrs()

      assert {:ok, %{record: r1}} = Records.create_record(attrs, schema)
      assert {:ok, %{record: r2}} = Records.create_record(attrs, schema)
      assert {:ok, %{record: r3}} = Records.create_record(attrs, schema)

      assert r1.record_id == r2.record_id
      assert r2.record_id == r3.record_id
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- a create command whose field_values fail REQ-227's validation is
  # rejected with zero events appended.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- REQ-227 inner field_values validation rejects zero-event on failure" do
    test "a payload missing a required field is rejected with zero events appended" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:error, {:record_payload_invalid, violations}} =
               Records.create_record(create_attrs(%{field_values: %{"age" => 42}}), schema)

      assert [%Registry.ValidationFailure{field_path: "/customer_name", constraint: "required"}] =
               violations

      assert Repo.aggregate(Event, :count, prefix: schema) == 0
      assert Repo.aggregate(Latest, :count, prefix: schema) == 0
    end

    test "a payload with a wrong-typed field is rejected with zero events appended" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:error, {:record_payload_invalid, violations}} =
               Records.create_record(
                 create_attrs(%{
                   field_values: %{"customer_name" => "Acme", "age" => "not-a-number"}
                 }),
                 schema
               )

      assert [%Registry.ValidationFailure{field_path: "/age", constraint: "type"}] = violations

      assert Repo.aggregate(Event, :count, prefix: schema) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- entity_type_instances creates exactly one row per TYPE, not per
  # record.
  # ---------------------------------------------------------------------------------

  describe "AC5/AC6 -- synthetic-instance-per-entity-TYPE mapping" do
    test "creating three records of the same entity type produces exactly one synthetic instance row for that type" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      for n <- 1..3 do
        assert {:ok, _} =
                 Records.create_record(
                   create_attrs(%{field_values: %{"customer_name" => "Acme #{n}", "age" => n}}),
                   schema
                 )
      end

      assert Repo.aggregate(Latest, :count, prefix: schema) == 3
      assert Repo.aggregate(EntityTypeInstance, :count, prefix: schema) == 1
      assert Repo.aggregate(InstanceProjection, :count, prefix: schema) == 1

      [entity_type_instance] = Repo.all(EntityTypeInstance, prefix: schema)
      assert entity_type_instance.entity_type == "customer"

      # AC6 -- design artefact's own §2 resolves per-TYPE, not per-record; this
      # is the executable proof that the shipped code matches that resolution.
      events = Repo.all(Event, prefix: schema)
      assert length(events) == 3
      assert Enum.uniq(Enum.map(events, & &1.instance_id)) == [entity_type_instance.instance_id]
    end

    test "two different entity types get two independent synthetic instance rows" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema, %{name: "customer"})

      create_active_definition!(schema, %{
        name: "invoice",
        fields: [%{name: "amount", type: :integer}]
      })

      assert {:ok, _} = Records.create_record(create_attrs(%{entity_type: "customer"}), schema)

      assert {:ok, _} =
               Records.create_record(
                 create_attrs(%{
                   entity_type: "invoice",
                   field_values: %{"amount" => 100}
                 }),
                 schema
               )

      assert Repo.aggregate(EntityTypeInstance, :count, prefix: schema) == 2
    end
  end

  # ---------------------------------------------------------------------------------
  # AC7 -- outer envelope schema and REQ-227's inner validation are each
  # independently exercised.
  # ---------------------------------------------------------------------------------

  describe "AC7 -- outer envelope vs. inner field_values validation, independently exercised" do
    test "the OUTER envelope schema rejects a malformed payload at Registry.validate_payload/3 (bypassing the command function)" do
      %{schema_name: schema} = provisioned_tenant()
      {:ok, tenant_id} = TenantProvisioning.tenant_id_for_schema_name(schema)

      # Missing "record_id" -- violates ENTITY_RECORD_CREATED's own outer
      # envelope schema, entirely independent of REQ-227's field_values check.
      malformed_envelope =
        Jason.encode!(%{
          "entity_type" => "customer",
          "entity_def_version" => "aa",
          "field_values" => %{"customer_name" => "Acme", "age" => 42}
        })

      assert {:error, {:payload_validation_failed, failures}} =
               Registry.validate_payload("ENTITY_RECORD_CREATED", malformed_envelope, tenant_id)

      assert Enum.any?(failures, &(&1.constraint == "required"))
    end

    test "the INNER field_values check (REQ-227) rejects an enum violation independent of the outer envelope" do
      %{schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "ticket",
        fields: [%{name: "status", type: :enum, enum_values: ["open", "closed"], required: true}]
      })

      assert {:error, {:record_payload_invalid, violations}} =
               Records.create_record(
                 create_attrs(%{
                   entity_type: "ticket",
                   field_values: %{"status" => "not-a-real-status"}
                 }),
                 schema
               )

      assert [%Registry.ValidationFailure{constraint: "enum"}] = violations
    end
  end

  # ---------------------------------------------------------------------------------
  # update_record/2 / delete_record/2 -- design §5.2's own scope, exercised
  # alongside the 8 acceptance criteria above.
  # ---------------------------------------------------------------------------------

  describe "update_record/2 and delete_record/2" do
    test "update_record/2 replaces field_values in full and appends ENTITY_RECORD_UPDATED" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)

      assert {:ok, %{record: updated, is_duplicate: false}} =
               Records.update_record(
                 %{
                   entity_type: "customer",
                   record_id: created.record_id,
                   field_values: %{"customer_name" => "Acme Renamed", "age" => 43},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      assert updated.record_id == created.record_id
      assert updated.field_values == %{"customer_name" => "Acme Renamed", "age" => 43}

      assert Repo.aggregate(Event, :count, prefix: schema) == 2
      assert Repo.aggregate(Latest, :count, prefix: schema) == 1
    end

    test "update_record/2 on a non-existent record returns {:error, {:record_not_found, _}}" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:error, {:record_not_found, _}} =
               Records.update_record(
                 %{
                   entity_type: "customer",
                   record_id: Ecto.UUID.generate(),
                   field_values: %{"customer_name" => "Acme", "age" => 1},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )
    end

    test "delete_record/2 marks deleted: true and retains the last field_values" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)

      assert {:ok, %{record: deleted, is_duplicate: false}} =
               Records.delete_record(
                 %{
                   entity_type: "customer",
                   record_id: created.record_id,
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      assert deleted.deleted
      assert deleted.field_values == created.field_values

      [event] =
        Repo.all(from(e in Event, where: e.event_type == "ENTITY_RECORD_DELETED"), prefix: schema)

      refute Map.has_key?(event.payload, "field_values")
    end

    test "delete_record/2 on an already-deleted record is a no-op success (is_duplicate: false)" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)

      delete_attrs = %{
        entity_type: "customer",
        record_id: created.record_id,
        actor_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate()
      }

      assert {:ok, %{record: first_delete}} = Records.delete_record(delete_attrs, schema)

      assert {:ok, %{record: second_delete, is_duplicate: false}} =
               Records.delete_record(
                 %{delete_attrs | idempotency_key: Ecto.UUID.generate()},
                 schema
               )

      assert first_delete.record_id == second_delete.record_id
      assert Repo.aggregate(Event, :count, prefix: schema) == 2
    end

    test "update_record/2 on an already-deleted record returns {:error, {:record_already_deleted, _}}" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)

      assert {:ok, _} =
               Records.delete_record(
                 %{
                   entity_type: "customer",
                   record_id: created.record_id,
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      assert {:error, {:record_already_deleted, record_id}} =
               Records.update_record(
                 %{
                   entity_type: "customer",
                   record_id: created.record_id,
                   field_values: %{"customer_name" => "Acme", "age" => 1},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      assert record_id == created.record_id
    end
  end

  # ---------------------------------------------------------------------------------
  # create_record/2 -- {:error, {:definition_not_found, _}} for an
  # unknown/inactive entity_type.
  # ---------------------------------------------------------------------------------

  describe "create_record/2 -- definition resolution" do
    test "an unknown entity_type is rejected with {:error, {:definition_not_found, _}}" do
      %{schema_name: schema} = provisioned_tenant()

      assert {:error, {:definition_not_found, "does-not-exist"}} =
               Records.create_record(create_attrs(%{entity_type: "does-not-exist"}), schema)
    end

    test "an inactive (never-activated) definition is rejected with {:error, {:definition_not_found, _}}" do
      %{schema_name: schema} = provisioned_tenant()

      assert {:ok, _} =
               Definitions.create_definition(
                 %{definition: valid_definition(), created_by: Ecto.UUID.generate()},
                 schema
               )

      assert {:error, {:definition_not_found, "customer"}} =
               Records.create_record(create_attrs(), schema)
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0519 fix (B) regression -- T7: reproduce ISS-0519's originally filed
  # repro path (Records.delete_record/2 against a name with 2+
  # entity_definitions rows). See
  # lib/letflow/design/iss0519-entity-definition-versioning-fix.md §8.
  # ---------------------------------------------------------------------------------

  describe "ISS-0519 fix (B) regression -- delete_record/2 no longer crashes under 2+ definition versions" do
    test "T7: delete_record/2 resolves the correct active definition instead of raising Ecto.MultipleResultsError" do
      %{schema_name: schema} = provisioned_tenant()

      # v1: created and activated.
      activated_v1 = create_active_definition!(schema)

      assert {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)

      # v2: a second entity_definitions row under the SAME name, created
      # after v1 was activated, and never itself activated -- this is the
      # exact "2+ rows share `name`" condition ISS-0519 names. Pre-fix, any
      # get_definition_by_name/2 call against "customer" from this point on
      # raises Ecto.MultipleResultsError.
      assert {:ok, _v2} =
               Definitions.create_definition(
                 %{
                   definition:
                     valid_definition(%{
                       fields: [
                         %{name: "customer_name", type: :string, required: true},
                         %{name: "age", type: :integer},
                         %{name: "loyalty_tier", type: :string}
                       ]
                     }),
                   created_by: Ecto.UUID.generate()
                 },
                 schema
               )

      assert {:ok, %{record: deleted, is_duplicate: false}} =
               Records.delete_record(
                 %{
                   entity_type: "customer",
                   record_id: created.record_id,
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      assert deleted.deleted
      assert deleted.record_id == created.record_id
      assert deleted.entity_def_version == activated_v1.logical_shape_version
    end
  end

  # ---------------------------------------------------------------------------------
  # Scope: no route or controller file added for this requirement.
  # ---------------------------------------------------------------------------------

  describe "scope -- no route/controller surface exists for entity records" do
    test "lib/letflow/router.ex does not forward to an entity-records router" do
      router_source = File.read!(Path.expand("../../../lib/letflow/router.ex", __DIR__))

      refute router_source =~ ~r/entity_record/i
    end

    test "no lib/letflow/routers/entity_records.ex file exists" do
      refute File.exists?(Path.expand("../../../lib/letflow/routers/entity_records.ex", __DIR__))
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0624 / GH#1311 regression -- `Records`'s private `field_document/1`
  # only carried `name`/`type`/`required`/`enum_values` when reconstructing a
  # field map from the persisted, string-keyed `definition_json`, silently
  # dropping `locales`/`search_strategy`/`decimal_precision`/`decimal_scale`.
  # A `:localized_text` field then reached
  # `Record.Validator.field_subschema/1`'s `%{type: :localized_text, locales:
  # locales}` clause (added by ISS-0617) with no `locales` key at all, so
  # `create_record/2` raised `FunctionClauseError` on EVERY write against a
  # definition declaring one -- end to end, through the real
  # `create_definition/2` -> `activate_definition/3` -> `create_record/2`
  # path, not just `Record.Validator.build_record_schema/1` called directly
  # with a hand-built map that already had `locales` (ISS-0617's own test
  # file only ever did the latter, which is why this gap went uncaught).
  # ---------------------------------------------------------------------------------

  describe "ISS-0624 -- field_document/1 carries locales/decimal_precision/decimal_scale through create_record/2" do
    test "create_record/2 succeeds (does not raise) for a definition with a :localized_text field, and the value round-trips" do
      %{schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        fields: [
          %{name: "customer_name", type: :string, required: true},
          %{name: "bio", type: :localized_text, locales: ["en", "fr"]}
        ]
      })

      assert {:ok, %{record: created}} =
               Records.create_record(
                 create_attrs(%{
                   field_values: %{
                     "customer_name" => "Acme",
                     "bio" => %{"en" => "Hello", "fr" => "Bonjour"}
                   }
                 }),
                 schema
               )

      assert created.field_values == %{
               "customer_name" => "Acme",
               "bio" => %{"en" => "Hello", "fr" => "Bonjour"}
             }

      [persisted] = Repo.all(Latest, prefix: schema)
      assert persisted.field_values["bio"] == %{"en" => "Hello", "fr" => "Bonjour"}
    end

    test "create_record/2 succeeds (does not raise) for a definition with a :decimal field, and the value round-trips" do
      %{schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        fields: [
          %{name: "customer_name", type: :string, required: true},
          %{name: "price", type: :decimal, decimal_precision: 10, decimal_scale: 2}
        ]
      })

      assert {:ok, %{record: created}} =
               Records.create_record(
                 create_attrs(%{
                   field_values: %{"customer_name" => "Acme", "price" => 19.99}
                 }),
                 schema
               )

      assert created.field_values["price"] == 19.99
    end

    test "a definition with BOTH a :localized_text and a :decimal field allows create_record/2 to succeed for either alone" do
      %{schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        fields: [
          %{name: "customer_name", type: :string, required: true},
          %{name: "bio", type: :localized_text, locales: ["en"]},
          %{name: "price", type: :decimal, decimal_precision: 6, decimal_scale: 2}
        ]
      })

      assert {:ok, %{record: created}} =
               Records.create_record(
                 create_attrs(%{
                   field_values: %{
                     "customer_name" => "Acme",
                     "bio" => %{"en" => "Hello"},
                     "price" => 5.5
                   }
                 }),
                 schema
               )

      assert created.field_values["bio"] == %{"en" => "Hello"}
      assert created.field_values["price"] == 5.5
    end
  end

  # ---------------------------------------------------------------------------------
  # GH #2528 -- optimistic concurrency on update_record/2 / delete_record/2
  # (lib/letflow/design/gh2528-record-version-conflict.md §8).
  # ---------------------------------------------------------------------------------

  defp gh2528_update_attrs(record_id, name, overrides \\ %{}) do
    Map.merge(
      %{
        entity_type: "customer",
        record_id: record_id,
        field_values: %{"customer_name" => name, "age" => 1},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp gh2528_delete_attrs(record_id, overrides \\ %{}) do
    Map.merge(
      %{
        entity_type: "customer",
        record_id: record_id,
        actor_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp gh2528_event_count(schema), do: Repo.aggregate(Event, :count, prefix: schema)

  defp gh2528_latest!(schema, record_id) do
    {:ok, record} = Latest.get(record_id, "customer", schema)
    record
  end

  describe "expected_last_event_global_seq" do
    test "absent expected keeps last-writer-wins: two updates both succeed, the second value is stored" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)

      assert {:ok, %{is_duplicate: false}} =
               Records.update_record(gh2528_update_attrs(created.record_id, "First"), schema)

      assert {:ok, %{is_duplicate: false}} =
               Records.update_record(gh2528_update_attrs(created.record_id, "Second"), schema)

      assert gh2528_latest!(schema, created.record_id).field_values["customer_name"] == "Second"
    end

    test "an explicit nil expected behaves exactly like an absent one" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)

      {:ok, _} = Records.update_record(gh2528_update_attrs(created.record_id, "First"), schema)

      assert {:ok, %{is_duplicate: false}} =
               Records.update_record(
                 gh2528_update_attrs(created.record_id, "Second", %{
                   expected_last_event_global_seq: nil
                 }),
                 schema
               )
    end

    test "matching expected updates and advances last_event_global_seq" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)
      s1 = created.last_event_global_seq

      assert {:ok, %{record: updated, is_duplicate: false}} =
               Records.update_record(
                 gh2528_update_attrs(created.record_id, "Matched", %{
                   expected_last_event_global_seq: s1
                 }),
                 schema
               )

      assert updated.last_event_global_seq > s1
      assert updated.field_values["customer_name"] == "Matched"

      stored = gh2528_latest!(schema, created.record_id)
      assert stored.field_values["customer_name"] == "Matched"
      assert stored.last_event_global_seq == updated.last_event_global_seq
    end

    test "stale expected is refused atomically and does not claim the idempotency key" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)
      s1 = created.last_event_global_seq

      {:ok, %{record: %{last_event_global_seq: s2}}} =
        Records.update_record(gh2528_update_attrs(created.record_id, "Winner"), schema)

      events_before = gh2528_event_count(schema)
      key = Ecto.UUID.generate()

      assert {:error, :record_version_conflict} =
               Records.update_record(
                 gh2528_update_attrs(created.record_id, "Stale", %{
                   expected_last_event_global_seq: s1,
                   idempotency_key: key
                 }),
                 schema
               )

      stored = gh2528_latest!(schema, created.record_id)
      assert stored.field_values["customer_name"] == "Winner"
      assert stored.last_event_global_seq == s2
      assert gh2528_event_count(schema) == events_before

      # The rolled-back attempt did not claim `key`: a retry with the same key
      # and the correct expected value is a fresh write, not a replay.
      assert {:ok, %{record: retried, is_duplicate: false}} =
               Records.update_record(
                 gh2528_update_attrs(created.record_id, "Retried", %{
                   expected_last_event_global_seq: s2,
                   idempotency_key: key
                 }),
                 schema
               )

      assert retried.field_values["customer_name"] == "Retried"
      assert gh2528_event_count(schema) == events_before + 1
    end

    test "delete with matching expected deletes" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)

      assert {:ok, %{record: deleted, is_duplicate: false}} =
               Records.delete_record(
                 gh2528_delete_attrs(created.record_id, %{
                   expected_last_event_global_seq: created.last_event_global_seq
                 }),
                 schema
               )

      assert deleted.deleted
      assert gh2528_latest!(schema, created.record_id).deleted
    end

    test "delete with stale expected is refused atomically and leaves deleted: false" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)
      s1 = created.last_event_global_seq

      {:ok, %{record: %{last_event_global_seq: s2}}} =
        Records.update_record(gh2528_update_attrs(created.record_id, "Winner"), schema)

      events_before = gh2528_event_count(schema)

      assert {:error, :record_version_conflict} =
               Records.delete_record(
                 gh2528_delete_attrs(created.record_id, %{expected_last_event_global_seq: s1}),
                 schema
               )

      stored = gh2528_latest!(schema, created.record_id)
      refute stored.deleted
      assert stored.last_event_global_seq == s2
      assert stored.field_values["customer_name"] == "Winner"
      assert gh2528_event_count(schema) == events_before
    end

    test "delete of an already-deleted record stays a no-op success regardless of the expected value (D7)" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)
      {:ok, _} = Records.delete_record(gh2528_delete_attrs(created.record_id), schema)
      events_before = gh2528_event_count(schema)

      assert {:ok, %{record: %{deleted: true}, is_duplicate: false}} =
               Records.delete_record(
                 gh2528_delete_attrs(created.record_id, %{
                   expected_last_event_global_seq: created.last_event_global_seq
                 }),
                 schema
               )

      assert gh2528_event_count(schema) == events_before
    end

    test "identical replay returns the original, not a conflict" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)

      attrs =
        gh2528_update_attrs(created.record_id, "Once", %{
          expected_last_event_global_seq: created.last_event_global_seq
        })

      assert {:ok, %{record: first, is_duplicate: false}} = Records.update_record(attrs, schema)
      assert {:ok, %{record: replay, is_duplicate: true}} = Records.update_record(attrs, schema)

      assert replay.last_event_global_seq == first.last_event_global_seq
      assert replay.field_values == first.field_values
    end

    # GH #2543 split this #2528 test in two: the expected sequence is not part
    # of the idempotency binding (design D5), the field values are.
    test "same values, different stale expected -> is_duplicate: true" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)
      s1 = created.last_event_global_seq
      key = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()

      assert {:ok, %{record: first, is_duplicate: false}} =
               Records.update_record(
                 gh2528_update_attrs(created.record_id, "Original", %{
                   expected_last_event_global_seq: s1,
                   idempotency_key: key,
                   actor_id: actor_id
                 }),
                 schema
               )

      events_before = gh2528_event_count(schema)
      # s1 - 1 must stay a valid (non-negative) expected value.
      assert s1 > 0

      # s1 is stale now (first advanced the row): the idempotency short-circuit
      # runs before the version check, so the same request is a replay and
      # nothing is re-checked or written.
      assert {:ok, %{record: replay, is_duplicate: true}} =
               Records.update_record(
                 gh2528_update_attrs(created.record_id, "Original", %{
                   expected_last_event_global_seq: s1 - 1,
                   idempotency_key: key,
                   actor_id: actor_id
                 }),
                 schema
               )

      assert replay.field_values == first.field_values
      assert replay.last_event_global_seq == first.last_event_global_seq

      stored = gh2528_latest!(schema, created.record_id)
      assert stored.field_values["customer_name"] == "Original"
      assert stored.last_event_global_seq == first.last_event_global_seq
      assert gh2528_event_count(schema) == events_before
    end

    test "different values, same key -> idempotency_key_reuse, nothing written" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)
      s1 = created.last_event_global_seq
      key = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()

      assert {:ok, %{record: first, is_duplicate: false}} =
               Records.update_record(
                 gh2528_update_attrs(created.record_id, "Original", %{
                   expected_last_event_global_seq: s1,
                   idempotency_key: key,
                   actor_id: actor_id
                 }),
                 schema
               )

      events_before = gh2528_event_count(schema)
      assert s1 > 0

      # The key is reused for a different request: refused before the version
      # check, so neither the stale expected nor the new values are applied.
      assert {:error, :idempotency_key_reuse} =
               Records.update_record(
                 gh2528_update_attrs(created.record_id, "Different", %{
                   expected_last_event_global_seq: s1 - 1,
                   idempotency_key: key,
                   actor_id: actor_id
                 }),
                 schema
               )

      stored = gh2528_latest!(schema, created.record_id)
      assert stored.field_values["customer_name"] == "Original"
      assert stored.last_event_global_seq == first.last_event_global_seq
      assert gh2528_event_count(schema) == events_before
    end

    test "EventTypes unchanged: an opted-in update's stored UPDATED payload has exactly the four keys" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)

      {:ok, _} =
        Records.update_record(
          gh2528_update_attrs(created.record_id, "Checked", %{
            expected_last_event_global_seq: created.last_event_global_seq
          }),
          schema
        )

      [event] =
        Repo.all(from(e in Event, where: e.event_type == "ENTITY_RECORD_UPDATED"), prefix: schema)

      assert event.payload |> Map.keys() |> Enum.sort() ==
               ~w(entity_def_version entity_type field_values record_id)
    end

    test "a non-nil expected that is not a non-negative integer raises ArgumentError, live or deleted" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      {:ok, %{record: live}} = Records.create_record(create_attrs(), schema)
      {:ok, %{record: gone}} = Records.create_record(create_attrs(), schema)
      {:ok, _} = Records.delete_record(gh2528_delete_attrs(gone.record_id), schema)

      for bad <- [-1, "5", 1.0] do
        assert_raise ArgumentError, fn ->
          Records.update_record(
            gh2528_update_attrs(live.record_id, "x", %{expected_last_event_global_seq: bad}),
            schema
          )
        end

        assert_raise ArgumentError, fn ->
          Records.delete_record(
            gh2528_delete_attrs(gone.record_id, %{expected_last_event_global_seq: bad}),
            schema
          )
        end
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # GH #2528 design §8.1 -- real concurrency. :auto sandbox mode for the whole
  # test (not SandboxAutoMode.provision!/2, which restores :manual + checkout on
  # return and would make every Task share the test's single connection: no
  # real race, and the lock-holder test would deadlock). Mirrors
  # test/letflow/engine_concurrency_test.exs's provisioned_tenant/0. Every write
  # commits for real; each iteration uses a fresh record and asserts deltas.
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant_auto do
    SandboxAutoMode.enter_auto_mode!(Letflow.Repo)

    # Registered FIRST so it runs LAST (LIFO): the cleanup below still needs
    # :auto mode active to commit its DROP SCHEMA/delete_all.
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Letflow.Repo) end)

    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "gh2528-race",
        display_name: "GH-2528 Record Version Race Tenant",
        teardown: false
      )

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant_id) do
        {:ok, schema_name} -> drop_schema!(schema_name)
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
    end)

    assert {:ok, _seed_result} = EventTypes.seed!(schema_name)

    %{tenant_id: tenant_id, schema_name: schema_name}
  end

  # Starts a Task that announces itself, waits for :go, then runs `fun`.
  defp gh2528_barrier_task(fun) do
    parent = self()

    Task.async(fn ->
      send(parent, {:ready, self()})

      receive do
        :go -> fun.()
      after
        5_000 -> flunk("writer task never received :go")
      end
    end)
  end

  defp gh2528_race_outcome!(results) do
    oks = for {:ok, %{record: record}} <- results, do: record
    conflicts = for {:error, :record_version_conflict} = c <- results, do: c

    assert length(oks) == 1 and length(conflicts) == 1,
           "expected exactly one {:ok, _} and one {:error, :record_version_conflict}, got: " <>
             inspect(results)

    hd(oks)
  end

  defp gh2528_waiting_on_sequence_lock(schema) do
    %Postgrex.Result{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query ILIKE $1",
        ["%\"#{schema}\".\"instance_sequence\"%FOR UPDATE%"]
      )

    count
  end

  # 200 x 20 ms = 4 s, under the holder's 5 s :release wait.
  defp gh2528_await_two_waiters!(schema, polls_left \\ 200)

  defp gh2528_await_two_waiters!(_schema, 0),
    do: flunk("the two writers never both blocked on the held instance_sequence row")

  defp gh2528_await_two_waiters!(schema, polls_left) do
    if gh2528_waiting_on_sequence_lock(schema) == 2 do
      :ok
    else
      receive do
      after
        20 -> gh2528_await_two_waiters!(schema, polls_left - 1)
      end
    end
  end

  describe "expected_last_event_global_seq -- concurrency" do
    test "barrier race, same expected, different values: exactly one wins, the other conflicts (20 iterations)" do
      %{schema_name: schema} = provisioned_tenant_auto()
      create_active_definition!(schema)

      for i <- 1..20 do
        {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)
        s1 = created.last_event_global_seq
        events_before = gh2528_event_count(schema)

        tasks =
          for name <- ["A#{i}", "B#{i}"] do
            gh2528_barrier_task(fn ->
              Records.update_record(
                gh2528_update_attrs(created.record_id, name, %{
                  expected_last_event_global_seq: s1
                }),
                schema
              )
            end)
          end

        assert_receive {:ready, p1}, 5_000
        assert_receive {:ready, p2}, 5_000
        send(p1, :go)
        send(p2, :go)

        winner = tasks |> Enum.map(&Task.await(&1, 5_000)) |> gh2528_race_outcome!()

        stored = gh2528_latest!(schema, created.record_id)
        assert stored.field_values == winner.field_values
        assert stored.last_event_global_seq == winner.last_event_global_seq
        assert gh2528_event_count(schema) == events_before + 1
      end
    end

    test "control: the same race without expected gives two {:ok, _} (20 iterations)" do
      %{schema_name: schema} = provisioned_tenant_auto()
      create_active_definition!(schema)

      for i <- 1..20 do
        {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)
        events_before = gh2528_event_count(schema)

        tasks =
          for name <- ["A#{i}", "B#{i}"] do
            gh2528_barrier_task(fn ->
              Records.update_record(gh2528_update_attrs(created.record_id, name), schema)
            end)
          end

        assert_receive {:ready, p1}, 5_000
        assert_receive {:ready, p2}, 5_000
        send(p1, :go)
        send(p2, :go)

        results = Enum.map(tasks, &Task.await(&1, 5_000))
        assert [{:ok, _}, {:ok, _}] = results
        assert gh2528_event_count(schema) == events_before + 2
      end
    end

    # MANDATORY (design §8.1 Test 3): forces both writers to pre-read S1 before
    # either commits, so a check against ctx.existing_record would let both
    # through. Deterministic, not probabilistic.
    test "deterministic lock-holder: both writers pre-read S1, only the locked re-read decides" do
      %{schema_name: schema} = provisioned_tenant_auto()
      create_active_definition!(schema)
      {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)
      s1 = created.last_event_global_seq
      {:ok, instance_id} = EntityTypeInstance.get_or_create("customer", schema)
      events_before = gh2528_event_count(schema)
      parent = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.one!(
              from(s in InstanceSequence,
                where: s.instance_id == ^instance_id,
                lock: "FOR UPDATE"
              ),
              prefix: schema
            )

            send(parent, {:locked, self()})

            receive do
              :release -> :ok
            after
              5_000 -> flunk("lock holder never received :release")
            end
          end)
        end)

      assert_receive {:locked, holder_pid}, 5_000

      writers =
        for name <- ["A", "B"] do
          Task.async(fn ->
            Records.update_record(
              gh2528_update_attrs(created.record_id, name, %{expected_last_event_global_seq: s1}),
              schema
            )
          end)
        end

      gh2528_await_two_waiters!(schema)

      send(holder_pid, :release)
      assert {:ok, :ok} = Task.await(holder, 5_000)

      winner = writers |> Enum.map(&Task.await(&1, 5_000)) |> gh2528_race_outcome!()

      stored = gh2528_latest!(schema, created.record_id)
      assert stored.field_values == winner.field_values
      assert stored.last_event_global_seq == winner.last_event_global_seq
      assert gh2528_event_count(schema) == events_before + 1
    end
  end

  # ---------------------------------------------------------------------------------
  # GH #2529 -- append-only entity types. Every fixture goes through the real
  # Definitions.create_definition/2 + activate_definition/4 round-trip, so the
  # flag Records reads is the string-keyed JSONB read back from Postgres.
  # ---------------------------------------------------------------------------------

  defp gh2529_activate!(schema, overrides) do
    assert {:ok, row} =
             Definitions.create_definition(
               %{definition: valid_definition(overrides), created_by: Ecto.UUID.generate()},
               schema
             )

    assert {:ok, activated} =
             Definitions.activate_definition(row.name, Ecto.UUID.generate(), "gh2529", schema)

    activated
  end

  defp gh2529_update_attrs(record_id, name) do
    %{
      entity_type: "customer",
      record_id: record_id,
      field_values: %{"customer_name" => name, "age" => 7},
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate()
    }
  end

  defp gh2529_delete_attrs(record_id) do
    %{
      entity_type: "customer",
      record_id: record_id,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate()
    }
  end

  defp gh2529_type_event_count(schema) do
    {:ok, instance_id} = EntityTypeInstance.get_or_create("customer", schema)

    Event
    |> where([e], e.instance_id == ^instance_id)
    |> Repo.aggregate(:count, prefix: schema)
  end

  # Shaped like Letflow.Scheduler.RecordDeadlineSweep's
  # claim_and_transition_one/3 + apply_transition/3 (record_deadline_sweep.ex
  # 199-216, 254): a `case` over update_record/2 inside Repo.transaction/1,
  # rolling back on any `{:error, _}` -- never an unconditional `{:ok, _} =`.
  defp gh2529_sweep_like_transition(record_id, schema) do
    Repo.transaction(fn ->
      case Records.update_record(gh2529_update_attrs(record_id, "Swept"), schema) do
        {:ok, _result} -> {:transitioned, record_id}
        {:error, reason} -> Repo.rollback({record_id, reason})
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, {id, reason}} -> {:record_error, id, reason}
    end
  end

  describe "append_only" do
    test "the flag survives the real create/activate round-trip as string-keyed JSONB" do
      %{schema_name: schema} = provisioned_tenant()
      activated = gh2529_activate!(schema, %{append_only: true})

      {:ok, reloaded} = Definitions.get_active_definition_by_name("customer", schema)
      assert reloaded.id == activated.id
      assert reloaded.definition_json["append_only"] == true
      refute Map.has_key?(reloaded.definition_json, :append_only)
    end

    test "create succeeds on an append-only type" do
      %{schema_name: schema} = provisioned_tenant()
      gh2529_activate!(schema, %{append_only: true})

      assert {:ok, %{record: record, is_duplicate: false}} =
               Records.create_record(create_attrs(), schema)

      assert record.field_values == %{"customer_name" => "Acme", "age" => 42}
      assert gh2529_type_event_count(schema) == 1
    end

    test "update refused, record and event count unchanged" do
      %{schema_name: schema} = provisioned_tenant()
      gh2529_activate!(schema, %{append_only: true})
      {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)
      events_before = gh2529_type_event_count(schema)
      all_events_before = Repo.aggregate(Event, :count, prefix: schema)

      assert {:error, {:entity_append_only, "customer"}} =
               Records.update_record(gh2529_update_attrs(created.record_id, "Changed"), schema)

      stored = gh2528_latest!(schema, created.record_id)
      assert stored.field_values == created.field_values
      refute stored.deleted
      assert stored.last_event_global_seq == created.last_event_global_seq
      assert gh2529_type_event_count(schema) == events_before
      assert Repo.aggregate(Event, :count, prefix: schema) == all_events_before
    end

    test "delete refused, record and event count unchanged" do
      %{schema_name: schema} = provisioned_tenant()
      gh2529_activate!(schema, %{append_only: true})
      {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)
      events_before = gh2529_type_event_count(schema)

      assert {:error, {:entity_append_only, "customer"}} =
               Records.delete_record(gh2529_delete_attrs(created.record_id), schema)

      stored = gh2528_latest!(schema, created.record_id)
      assert stored.field_values == created.field_values
      refute stored.deleted
      assert stored.last_event_global_seq == created.last_event_global_seq
      assert gh2529_type_event_count(schema) == events_before
    end

    test "random non-existent record_id gets entity_append_only, not record_not_found" do
      %{schema_name: schema} = provisioned_tenant()
      gh2529_activate!(schema, %{append_only: true})
      missing = Ecto.UUID.generate()

      assert {:error, {:entity_append_only, "customer"}} =
               Records.update_record(gh2529_update_attrs(missing, "Ghost"), schema)

      assert {:error, {:entity_append_only, "customer"}} =
               Records.delete_record(gh2529_delete_attrs(missing), schema)

      assert Repo.aggregate(Event, :count, prefix: schema) == 0
    end

    test "append_only: false behaves as mutable incl. delete idempotency" do
      %{schema_name: schema} = provisioned_tenant()
      activated = gh2529_activate!(schema, %{append_only: false})
      assert activated.definition_json["append_only"] == false
      {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)

      assert {:ok, %{record: updated, is_duplicate: false}} =
               Records.update_record(gh2529_update_attrs(created.record_id, "Changed"), schema)

      assert updated.field_values["customer_name"] == "Changed"

      assert {:ok, %{record: deleted, is_duplicate: false}} =
               Records.delete_record(gh2529_delete_attrs(created.record_id), schema)

      assert deleted.deleted
      events_after_delete = gh2529_type_event_count(schema)

      assert {:ok, %{record: again, is_duplicate: false}} =
               Records.delete_record(gh2529_delete_attrs(created.record_id), schema)

      assert again.deleted
      assert gh2529_type_event_count(schema) == events_after_delete
    end

    # Behaviour change pinned on purpose (records.ex delete_record/2 @doc): the
    # append-only check runs before the already-deleted no-op, so a record
    # deleted while the type was mutable is refused, not answered with the
    # 200 no-op success, once the flag is active.
    test "delete of an already-deleted record is refused once the flag is active" do
      %{schema_name: schema} = provisioned_tenant()
      gh2529_activate!(schema, %{})
      {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)

      assert {:ok, %{record: deleted}} =
               Records.delete_record(gh2529_delete_attrs(created.record_id), schema)

      assert deleted.deleted

      # Premise: while mutable, a second delete is the no-op success.
      assert {:ok, %{record: %{deleted: true}, is_duplicate: false}} =
               Records.delete_record(gh2529_delete_attrs(created.record_id), schema)

      gh2529_activate!(schema, %{
        append_only: true,
        fields: [
          %{name: "customer_name", type: :string, required: true},
          %{name: "age", type: :integer},
          %{name: "loyalty_tier", type: :string}
        ]
      })

      events_before = gh2529_type_event_count(schema)

      assert {:error, {:entity_append_only, "customer"}} =
               Records.delete_record(gh2529_delete_attrs(created.record_id), schema)

      stored = gh2528_latest!(schema, created.record_id)
      assert stored.deleted
      assert stored.last_event_global_seq == deleted.last_event_global_seq
      assert gh2529_type_event_count(schema) == events_before
    end

    test "activating a version without the flag unlocks; re-adding it locks again" do
      %{schema_name: schema} = provisioned_tenant()
      gh2529_activate!(schema, %{append_only: true})
      {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)

      assert {:error, {:entity_append_only, "customer"}} =
               Records.update_record(gh2529_update_attrs(created.record_id, "V1"), schema)

      # v2: no flag -> mutable again.
      v2 = gh2529_activate!(schema, %{})
      refute Map.has_key?(v2.definition_json, "append_only")

      assert {:ok, %{record: updated}} =
               Records.update_record(gh2529_update_attrs(created.record_id, "V2"), schema)

      assert updated.field_values["customer_name"] == "V2"

      # v3: flag again plus one extra optional field (a logical shape distinct
      # from v1, else the per-name shape unique index rejects the row).
      v3 =
        gh2529_activate!(schema, %{
          append_only: true,
          fields: [
            %{name: "customer_name", type: :string, required: true},
            %{name: "age", type: :integer},
            %{name: "loyalty_tier", type: :string}
          ]
        })

      assert v3.definition_json["append_only"] == true
      events_before = gh2529_type_event_count(schema)

      assert {:error, {:entity_append_only, "customer"}} =
               Records.update_record(gh2529_update_attrs(created.record_id, "V3"), schema)

      assert {:error, {:entity_append_only, "customer"}} =
               Records.delete_record(gh2529_delete_attrs(created.record_id), schema)

      assert gh2528_latest!(schema, created.record_id).field_values["customer_name"] == "V2"
      assert gh2529_type_event_count(schema) == events_before
    end

    test "a deadline-sweep-shaped caller gets the refusal without crashing" do
      %{schema_name: schema} = provisioned_tenant()
      gh2529_activate!(schema, %{append_only: true})
      {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)
      record_id = created.record_id

      assert {:record_error, ^record_id, {:entity_append_only, "customer"}} =
               gh2529_sweep_like_transition(record_id, schema)

      assert gh2528_latest!(schema, record_id).field_values == created.field_values
    end

    test "no new write path: only four lib files name the update/delete event types" do
      git =
        System.find_executable("git") ||
          flunk("git is not available; this test must fail, not skip")

      repo_root = Path.expand("../../..", __DIR__)

      {out, status} =
        System.cmd(
          git,
          [
            "grep",
            "--untracked",
            "-l",
            "-E",
            "ENTITY_RECORD_UPDATED|ENTITY_RECORD_DELETED",
            "--",
            "lib",
            ":!lib/letflow/design"
          ],
          cd: repo_root,
          stderr_to_stdout: true
        )

      assert status == 0, "git grep failed: #{out}"

      files = out |> String.split(["\r\n", "\n"], trim: true) |> Enum.sort()

      # api/response.ex names the two types only to drop `field_values` from the history view
      # (GH #2701, REQ-516 S3): it shapes a response and writes nothing.
      assert files == [
               "lib/letflow/api/response.ex",
               "lib/letflow/entities/event_types.ex",
               "lib/letflow/entities/record/projector.ex",
               "lib/letflow/entities/records.ex"
             ]
    end
  end

  # ---------------------------------------------------------------------------------
  # GH #2543 -- an idempotency_key is bound to the request that first used it
  # (lib/letflow/design/gh2543-idempotency-key-binding.md §2, §3, §8).
  # ---------------------------------------------------------------------------------

  @gh2543_json_fields [
    %{name: "customer_name", type: :string, required: true},
    %{name: "age", type: :integer},
    %{name: "data", type: :json}
  ]

  defp gh2543_definition!(schema, name \\ "customer") do
    create_active_definition!(schema, %{
      name: name,
      display_name: String.capitalize(name),
      fields: @gh2543_json_fields
    })
  end

  defp gh2543_update_attrs(record_id, actor_id, key, name \\ "Updated") do
    %{
      entity_type: "customer",
      record_id: record_id,
      field_values: %{"customer_name" => name, "age" => 1},
      actor_id: actor_id,
      idempotency_key: key
    }
  end

  defp gh2543_delete_attrs(record_id, actor_id, key) do
    %{entity_type: "customer", record_id: record_id, actor_id: actor_id, idempotency_key: key}
  end

  defp gh2543_event_count(schema), do: Repo.aggregate(Event, :count, prefix: schema)

  defp gh2543_stored_payload(schema, key) do
    Event
    |> where([e], e.idempotency_key == ^key)
    |> select([e], e.payload)
    |> Repo.one!(prefix: schema)
  end

  # > 4096 bytes of payload, so EventStore stores it in event_payload_store
  # and the event row carries %{"$ref" => event_id}.
  defp gh2543_big_name(char), do: String.duplicate(char, 5_000)

  describe "GH #2543 -- idempotency key bound to the request" do
    test "update key reused for a different record_id -> idempotency_key_reuse, target unchanged, no event" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      {:ok, %{record: a}} = Records.create_record(create_attrs(), schema)
      {:ok, %{record: b}} = Records.create_record(create_attrs(), schema)
      actor_id = Ecto.UUID.generate()
      key = Ecto.UUID.generate()

      assert {:ok, %{is_duplicate: false}} =
               Records.update_record(gh2543_update_attrs(a.record_id, actor_id, key), schema)

      events_before = gh2543_event_count(schema)

      assert {:error, :idempotency_key_reuse} =
               Records.update_record(gh2543_update_attrs(b.record_id, actor_id, key), schema)

      stored_b = gh2528_latest!(schema, b.record_id)
      assert stored_b.field_values == b.field_values
      assert stored_b.last_event_global_seq == b.last_event_global_seq
      assert gh2543_event_count(schema) == events_before
    end

    test "create key reused for update -> reuse" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      attrs = create_attrs()
      {:ok, %{record: created}} = Records.create_record(attrs, schema)
      events_before = gh2543_event_count(schema)

      assert {:error, :idempotency_key_reuse} =
               Records.update_record(
                 %{
                   entity_type: "customer",
                   record_id: created.record_id,
                   field_values: attrs.field_values,
                   actor_id: attrs.actor_id,
                   idempotency_key: attrs.idempotency_key
                 },
                 schema
               )

      stored = gh2528_latest!(schema, created.record_id)
      assert stored.last_event_global_seq == created.last_event_global_seq
      assert gh2543_event_count(schema) == events_before
    end

    test "create key reused for delete -> reuse" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      attrs = create_attrs()
      {:ok, %{record: created}} = Records.create_record(attrs, schema)
      events_before = gh2543_event_count(schema)

      assert {:error, :idempotency_key_reuse} =
               Records.delete_record(
                 gh2543_delete_attrs(created.record_id, attrs.actor_id, attrs.idempotency_key),
                 schema
               )

      refute gh2528_latest!(schema, created.record_id).deleted
      assert gh2543_event_count(schema) == events_before
    end

    test "delete key reused against a different record_id -> reuse, second record not deleted, no event" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      {:ok, %{record: a}} = Records.create_record(create_attrs(), schema)
      {:ok, %{record: b}} = Records.create_record(create_attrs(), schema)
      actor_id = Ecto.UUID.generate()
      key = Ecto.UUID.generate()

      assert {:ok, %{record: %{deleted: true}}} =
               Records.delete_record(gh2543_delete_attrs(a.record_id, actor_id, key), schema)

      events_before = gh2543_event_count(schema)

      assert {:error, :idempotency_key_reuse} =
               Records.delete_record(gh2543_delete_attrs(b.record_id, actor_id, key), schema)

      stored_b = gh2528_latest!(schema, b.record_id)
      refute stored_b.deleted
      assert stored_b.last_event_global_seq == b.last_event_global_seq
      assert gh2543_event_count(schema) == events_before
    end

    test "update replay of the same request with an upper-case record_id -> is_duplicate: true" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      {:ok, %{record: b}} = Records.create_record(create_attrs(), schema)
      actor_id = Ecto.UUID.generate()
      key = Ecto.UUID.generate()

      assert {:ok, %{is_duplicate: false}} =
               Records.update_record(gh2543_update_attrs(b.record_id, actor_id, key), schema)

      events_before = gh2543_event_count(schema)

      # Design §3: UUIDs are compared after Ecto.UUID.cast/1 on both sides.
      assert {:ok, %{is_duplicate: true}} =
               Records.update_record(
                 gh2543_update_attrs(String.upcase(b.record_id), actor_id, key),
                 schema
               )

      assert gh2543_event_count(schema) == events_before
    end

    test "oversized original reused with different field_values -> reuse, no event" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      attrs = create_attrs(%{field_values: %{"customer_name" => gh2543_big_name("a")}})
      {:ok, %{record: created}} = Records.create_record(attrs, schema)

      assert %{"$ref" => _event_id} = gh2543_stored_payload(schema, attrs.idempotency_key)
      events_before = gh2543_event_count(schema)

      assert {:error, :idempotency_key_reuse} =
               Records.create_record(
                 %{attrs | field_values: %{"customer_name" => gh2543_big_name("b")}},
                 schema
               )

      assert gh2543_event_count(schema) == events_before
      assert Repo.aggregate(Latest, :count, prefix: schema) == 1
      assert gh2528_latest!(schema, created.record_id).field_values == attrs.field_values
    end

    test "create key reused with different field_values -> reuse" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      attrs = create_attrs()
      {:ok, _} = Records.create_record(attrs, schema)

      assert {:error, :idempotency_key_reuse} =
               Records.create_record(
                 %{attrs | field_values: %{"customer_name" => "Other", "age" => 42}},
                 schema
               )

      assert gh2543_event_count(schema) == 1
      assert Repo.aggregate(Latest, :count, prefix: schema) == 1
    end

    test "update key reused with different field_values -> reuse" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)
      actor_id = Ecto.UUID.generate()
      key = Ecto.UUID.generate()

      {:ok, %{record: first}} =
        Records.update_record(
          gh2543_update_attrs(created.record_id, actor_id, key, "One"),
          schema
        )

      events_before = gh2543_event_count(schema)

      assert {:error, :idempotency_key_reuse} =
               Records.update_record(
                 gh2543_update_attrs(created.record_id, actor_id, key, "Two"),
                 schema
               )

      stored = gh2528_latest!(schema, created.record_id)
      assert stored.field_values["customer_name"] == "One"
      assert stored.last_event_global_seq == first.last_event_global_seq
      assert gh2543_event_count(schema) == events_before
    end

    test "create key reused on another entity type with identical field_values -> reuse" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      create_active_definition!(schema, %{name: "supplier", display_name: "Supplier"})
      attrs = create_attrs()
      {:ok, _} = Records.create_record(attrs, schema)

      assert {:error, :idempotency_key_reuse} =
               Records.create_record(%{attrs | entity_type: "supplier"}, schema)

      assert gh2543_event_count(schema) == 1

      assert Repo.aggregate(from(l in Latest, where: l.entity_type == "supplier"), :count,
               prefix: schema
             ) == 0
    end

    test "same key and payload from another actor -> reuse" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      attrs = create_attrs()
      {:ok, _} = Records.create_record(attrs, schema)

      assert {:error, :idempotency_key_reuse} =
               Records.create_record(%{attrs | actor_id: Ecto.UUID.generate()}, schema)

      assert gh2543_event_count(schema) == 1
    end

    test "key first used by a non-entity event -> reuse, no raise" do
      %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant()
      create_active_definition!(schema)
      {:ok, instance_id} = EntityTypeInstance.get_or_create("customer", schema)

      event_type = "GH2543_FOREIGN_" <> to_string(System.unique_integer([:positive]))

      assert {:ok, _} =
               Registry.register_type(
                 %{
                   "name" => event_type,
                   "schema_version" => 1,
                   "json_schema" => %{"type" => "object"},
                   "description" => "GH #2543 test fixture"
                 },
                 tenant_id
               )

      attrs = create_attrs()

      assert {:ok, _event} =
               EventStore.append(
                 %{
                   instance_id: instance_id,
                   event_type: event_type,
                   payload: Jason.encode!(%{"something" => "else"}),
                   actor_id: attrs.actor_id,
                   idempotency_key: attrs.idempotency_key
                 },
                 prefix: schema
               )

      events_before = gh2543_event_count(schema)

      assert {:error, :idempotency_key_reuse} = Records.create_record(attrs, schema)
      assert gh2543_event_count(schema) == events_before
      assert Repo.aggregate(Latest, :count, prefix: schema) == 0
    end

    test "replay with reordered keys and 1 vs 1.0 -> is_duplicate: true, one event" do
      %{schema_name: schema} = provisioned_tenant()
      gh2543_definition!(schema)

      attrs =
        create_attrs(%{
          field_values: %{
            "customer_name" => "Acme",
            "data" => %{"z" => 1, "aa" => %{"n" => [1, 2.0], "m" => true}}
          }
        })

      assert {:ok, %{record: first, is_duplicate: false}} = Records.create_record(attrs, schema)

      replay_values = %{
        "data" => %{"aa" => %{"m" => true, "n" => [1.0, 2]}, "z" => 1.0},
        "customer_name" => "Acme"
      }

      assert {:ok, %{record: replay, is_duplicate: true}} =
               Records.create_record(%{attrs | field_values: replay_values}, schema)

      assert replay.record_id == first.record_id
      assert gh2543_event_count(schema) == 1

      # A string "1" never matches the number 1.
      assert {:error, :idempotency_key_reuse} =
               Records.create_record(
                 %{
                   attrs
                   | field_values: %{
                       "customer_name" => "Acme",
                       "data" => %{"z" => "1", "aa" => %{"n" => [1, 2.0], "m" => true}}
                     }
                 },
                 schema
               )
    end

    test "replay with a float >= 2^53 (1.0e23, 12345678901234567890.5 and 9.099724907720628e285) -> is_duplicate: true, one event" do
      %{schema_name: schema} = provisioned_tenant()
      gh2543_definition!(schema)

      data = %{
        "f1" => 1.0e23,
        "f2" => 12_345_678_901_234_567_890.5,
        "f3" => 9.099724907720628e285
      }

      attrs = create_attrs(%{field_values: %{"customer_name" => "Acme", "data" => data}})

      assert {:ok, %{record: first, is_duplicate: false}} = Records.create_record(attrs, schema)

      # Premise: jsonb printed each float as a plain decimal that Jason decodes
      # as an INTEGER, so plain == would call this identical replay different.
      stored = gh2543_stored_payload(schema, attrs.idempotency_key)["field_values"]["data"]
      assert is_integer(stored["f1"]) and is_integer(stored["f2"]) and is_integer(stored["f3"])
      refute stored == data
      # ... and :erlang.float/1 truncates the last one (design §3).
      refute :erlang.float(stored["f3"]) == data["f3"]

      assert {:ok, %{record: replay, is_duplicate: true}} = Records.create_record(attrs, schema)
      assert replay.record_id == first.record_id
      assert gh2543_event_count(schema) == 1
    end

    test "oversized (> 4096 B payload) create replay -> is_duplicate: true, full field_values" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      attrs =
        create_attrs(%{field_values: %{"customer_name" => gh2543_big_name("q"), "age" => 3}})

      assert {:ok, %{record: first, is_duplicate: false}} = Records.create_record(attrs, schema)
      assert %{"$ref" => _event_id} = gh2543_stored_payload(schema, attrs.idempotency_key)

      assert {:ok, %{record: replay, is_duplicate: true}} = Records.create_record(attrs, schema)
      assert replay.record_id == first.record_id
      assert replay.field_values == attrs.field_values
      assert replay.entity_def_version == first.entity_def_version
      assert gh2543_event_count(schema) == 1
    end

    test ":target create with different values -> original, is_duplicate: true" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      attrs = create_attrs(%{idempotency_match: :target})

      assert {:ok, %{record: first, is_duplicate: false}} = Records.create_record(attrs, schema)

      assert {:ok, %{record: replay, is_duplicate: true}} =
               Records.create_record(
                 %{attrs | field_values: %{"customer_name" => "Changed", "age" => 1}},
                 schema
               )

      assert replay.record_id == first.record_id
      assert replay.field_values == first.field_values
      assert gh2543_event_count(schema) == 1
    end

    test ":target create on another type -> reuse" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      create_active_definition!(schema, %{name: "supplier", display_name: "Supplier"})
      attrs = create_attrs(%{idempotency_match: :target})
      {:ok, _} = Records.create_record(attrs, schema)

      assert {:error, :idempotency_key_reuse} =
               Records.create_record(%{attrs | entity_type: "supplier"}, schema)

      assert {:error, :idempotency_key_reuse} =
               Records.create_record(%{attrs | actor_id: Ecto.UUID.generate()}, schema)

      assert gh2543_event_count(schema) == 1
    end

    test "invalid idempotency_match raises ArgumentError" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      # nil is not the default: an explicit nil is not :request (Map.get/3
      # only defaults a missing key), so it raises like any other value.
      for bad <- [:bogus, "target", nil] do
        assert_raise ArgumentError, ~r/idempotency_match/, fn ->
          Records.create_record(create_attrs(%{idempotency_match: bad}), schema)
        end

        # Raised before the definition lookup, so on every path.
        assert_raise ArgumentError, ~r/idempotency_match/, fn ->
          Records.create_record(
            create_attrs(%{entity_type: "no_such_type", idempotency_match: bad}),
            schema
          )
        end
      end

      assert gh2543_event_count(schema) == 0
    end

    test "update/delete ignore idempotency_match: :target still binds update field_values, :bogus does not raise" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)
      actor_id = Ecto.UUID.generate()
      key = Ecto.UUID.generate()

      first =
        created.record_id
        |> gh2543_update_attrs(actor_id, key, "One")
        |> Map.put(:idempotency_match, :target)

      assert {:ok, %{record: one, is_duplicate: false}} = Records.update_record(first, schema)
      events_before = gh2543_event_count(schema)

      # :target is create-only: an update with the same key and other values
      # is still a reuse, never the original returned as a duplicate.
      assert {:error, :idempotency_key_reuse} =
               Records.update_record(
                 %{first | field_values: %{"customer_name" => "Two", "age" => 1}},
                 schema
               )

      stored = gh2528_latest!(schema, created.record_id)
      assert stored.field_values["customer_name"] == "One"
      assert stored.last_event_global_seq == one.last_event_global_seq

      # Not read at all: a value create_record/2 rejects does not raise here.
      assert {:ok, %{is_duplicate: true}} =
               Records.update_record(%{first | idempotency_match: :bogus}, schema)

      assert gh2543_event_count(schema) == events_before

      delete_attrs =
        created.record_id
        |> gh2543_delete_attrs(actor_id, Ecto.UUID.generate())
        |> Map.put(:idempotency_match, :bogus)

      assert {:ok, %{record: %{deleted: true}}} = Records.delete_record(delete_attrs, schema)
    end

    test "reused key on an append-only type -> entity_append_only" do
      %{schema_name: schema} = provisioned_tenant()
      gh2529_activate!(schema, %{})
      {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)
      attrs = gh2543_update_attrs(created.record_id, Ecto.UUID.generate(), Ecto.UUID.generate())
      assert {:ok, %{is_duplicate: false}} = Records.update_record(attrs, schema)

      gh2529_activate!(schema, %{append_only: true})
      events_before = gh2543_event_count(schema)

      # The same request would be a replay, but ensure_mutable runs first.
      assert {:error, {:entity_append_only, "customer"}} = Records.update_record(attrs, schema)
      assert gh2543_event_count(schema) == events_before
    end
  end

  # ---------------------------------------------------------------------------------
  # GH #2532 -- min/max/non_negative enforced on create and update. Every
  # fixture goes through the real Definitions.create_definition/2 +
  # activate_definition/4 round-trip, so the bounds Records enforces are the
  # string-keyed JSONB read back from Postgres via field_document/1.
  # ---------------------------------------------------------------------------------

  defp gh2532_activate!(schema, qty_overrides) do
    definition =
      valid_definition(%{
        fields: [
          %{name: "customer_name", type: :string, required: true},
          Map.merge(%{name: "qty", type: :integer}, qty_overrides)
        ]
      })

    assert {:ok, row} =
             Definitions.create_definition(
               %{definition: definition, created_by: Ecto.UUID.generate()},
               schema
             )

    assert {:ok, activated} =
             Definitions.activate_definition(row.name, Ecto.UUID.generate(), "gh2532", schema)

    activated
  end

  defp gh2532_create_attrs(qty) do
    create_attrs(%{field_values: %{"customer_name" => "Acme", "qty" => qty}})
  end

  defp gh2532_update_attrs(record_id, qty) do
    %{
      entity_type: "customer",
      record_id: record_id,
      field_values: %{"customer_name" => "Acme", "qty" => qty},
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate()
    }
  end

  defp gh2532_event_count(schema), do: Repo.aggregate(Event, :count, prefix: schema)

  describe "GH #2532 non_negative qty" do
    test "the key is stored string-keyed and survives the round-trip" do
      %{schema_name: schema} = provisioned_tenant()
      gh2532_activate!(schema, %{non_negative: true})

      {:ok, reloaded} = Definitions.get_active_definition_by_name("customer", schema)
      qty = Enum.find(reloaded.definition_json["fields"], &(&1["name"] == "qty"))
      assert qty["non_negative"] == true
      refute Map.has_key?(qty, "min")
      refute Map.has_key?(qty, "max")
    end

    test "create with -1 is refused with zero events; 0 succeeds" do
      %{schema_name: schema} = provisioned_tenant()
      gh2532_activate!(schema, %{non_negative: true})

      assert {:error, {:record_payload_invalid, [_ | _] = violations}} =
               Records.create_record(gh2532_create_attrs(-1), schema)

      assert Enum.any?(violations, &(&1.field_path == "/qty" and &1.constraint == "minimum"))
      assert gh2532_event_count(schema) == 0
      assert Repo.all(Latest, prefix: schema) == []

      assert {:ok, %{record: created}} = Records.create_record(gh2532_create_attrs(0), schema)
      assert created.field_values["qty"] == 0
      assert gh2532_event_count(schema) == 1
    end

    test "update to -3 is refused and the row is unchanged" do
      %{schema_name: schema} = provisioned_tenant()
      gh2532_activate!(schema, %{non_negative: true})
      {:ok, %{record: created}} = Records.create_record(gh2532_create_attrs(4), schema)
      events_before = gh2532_event_count(schema)

      assert {:error, {:record_payload_invalid, [_ | _]}} =
               Records.update_record(gh2532_update_attrs(created.record_id, -3), schema)

      stored = gh2528_latest!(schema, created.record_id)
      assert stored.field_values == created.field_values
      assert stored.last_event_global_seq == created.last_event_global_seq
      assert gh2532_event_count(schema) == events_before

      assert {:ok, %{record: updated}} =
               Records.update_record(gh2532_update_attrs(created.record_id, 0), schema)

      assert updated.field_values["qty"] == 0
    end
  end

  # Each key on its own: if Records' private field_document/1 dropped any one
  # of min/max/non_negative, that key's test would accept the value.
  describe "GH #2532 read-back carries each key" do
    test "min only: below min refused, at min accepted" do
      %{schema_name: schema} = provisioned_tenant()
      gh2532_activate!(schema, %{min: 3})

      assert {:error, {:record_payload_invalid, [%{constraint: "minimum"}]}} =
               Records.create_record(gh2532_create_attrs(2), schema)

      assert {:ok, _} = Records.create_record(gh2532_create_attrs(3), schema)
    end

    test "max only: above max refused, at max accepted" do
      %{schema_name: schema} = provisioned_tenant()
      gh2532_activate!(schema, %{max: 10})

      assert {:error, {:record_payload_invalid, [%{constraint: "maximum"}]}} =
               Records.create_record(gh2532_create_attrs(11), schema)

      assert {:ok, _} = Records.create_record(gh2532_create_attrs(10), schema)
    end

    test "non_negative only: negative refused" do
      %{schema_name: schema} = provisioned_tenant()
      gh2532_activate!(schema, %{non_negative: true})

      assert {:error, {:record_payload_invalid, [%{constraint: "minimum"}]}} =
               Records.create_record(gh2532_create_attrs(-1), schema)
    end

    test "a key-less definition still accepts any integer" do
      %{schema_name: schema} = provisioned_tenant()
      gh2532_activate!(schema, %{})

      assert {:ok, _} = Records.create_record(gh2532_create_attrs(-1_000_000), schema)
    end
  end

  # INV-8: a definition_json written directly (bypassing the Validator) with a
  # malformed bound must not crash a write; the malformed key is ignored.
  describe "GH #2532 corrupt stored bound" do
    for {label, corrupt} <- [
          {"min \"a\"", %{"min" => "a"}},
          {"non_negative \"yes\"", %{"non_negative" => "yes"}},
          {"max nil", %{"max" => nil}}
        ] do
      @gh2532_corrupt corrupt
      test "stored #{label}: create_record accepts -1 and nothing raises" do
        %{schema_name: schema} = provisioned_tenant()
        activated = gh2532_activate!(schema, %{})

        fields =
          Enum.map(activated.definition_json["fields"], fn
            %{"name" => "qty"} = field -> Map.merge(field, @gh2532_corrupt)
            field -> field
          end)

        corrupted = Map.put(activated.definition_json, "fields", fields)

        {1, _} =
          Repo.update_all(
            from(d in Letflow.Entities.EntityDefinition, where: d.id == ^activated.id),
            [set: [definition_json: corrupted]],
            prefix: schema
          )

        {:ok, reloaded} = Definitions.get_active_definition_by_name("customer", schema)
        qty = Enum.find(reloaded.definition_json["fields"], &(&1["name"] == "qty"))
        assert Map.take(qty, Map.keys(@gh2532_corrupt)) == @gh2532_corrupt

        assert {:ok, %{record: created}} = Records.create_record(gh2532_create_attrs(-1), schema)
        assert created.field_values["qty"] == -1

        assert {:ok, _} =
                 Records.update_record(gh2532_update_attrs(created.record_id, -2), schema)
      end
    end
  end
end
