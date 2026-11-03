defmodule Letflow.Entities.Record.ProjectorTest do
  @moduledoc """
  Tests for `Letflow.Entities.Record.Projector` (REQ-229) --
  `replay_record/3` and `rebuild_projection/2`. See
  `lib/letflow/design/req229-entity-record-projection-replay.md` for the
  design this file verifies, and REQ-229's own `docs/requirements.yaml`
  entry for the authoritative 6 acceptance criteria this file's `describe`
  blocks are grouped by.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  Self-contained: provisions its own tenant schema(s), mirroring
  `test/letflow/entities/records_test.exs`'s own hand-rolled tenant-fixture
  pattern (DIRECTIVE T-4).

  ## AC2's second test does NOT go through `Definitions.create_definition/2`
  + `activate_definition/4` a second time for the same entity-type name

  A genuine, already-shipped gap was found while writing this test:
  `Letflow.Entities.Definitions.get_definition_by_name/2` runs `Repo.one/2`
  against `where: e.name == ^name` with **no** `status`/order/limit filter.
  `entity_definitions`'s only uniqueness constraint is
  `(tenant_id, name, logical_shape_version)` (design doc §1, restated from
  REQ-226) -- so creating and activating a *second* definition version under
  the same `name` (the literal way to "advance the entity definition to a
  new version" the requirement text describes) leaves **two** rows sharing
  that `name` in `entity_definitions`, and every subsequent
  `get_definition_by_name/2` call for that name (including the one inside
  `delete_record/2`'s own `fetch_active_definition/2`) raises
  `Ecto.MultipleResultsError`, not a clean `{:error, _}` tuple. This is a
  latent defect in REQ-226/228's already-shipped code, entirely outside
  `Letflow.Entities.Record.Projector`'s (this requirement's) scope --
  flagged here for REVIEWER rather than silently worked around inside
  `Projector` itself or silently avoided without comment.

  To still directly test the exact defect class CODE-DESIGN-VALIDATOR
  caught (the fold's `entity_def_version` DELETE-case rule) without
  depending on that separately-broken code path, the second AC2 test below
  appends `ENTITY_RECORD_CREATED`/`UPDATED`/`DELETED` events directly via
  `Letflow.EventStore.append_multi/3` (the same low-level call
  `test/letflow/entities/records_test.exs`'s own "forced failure" test
  already uses), crafting the `DELETED` event's payload with a
  **different** `entity_def_version` hex string than the earlier events --
  exactly the observable shape a real entity-definition version advance
  between last-update and delete would produce on the wire, per
  `Letflow.Entities.Records.base_payload/1`'s own unconditional inclusion of
  `entity_def_version` in every event kind's payload.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Record.Projector
  alias Letflow.Entities.Records
  alias Letflow.EventStore
  alias Letflow.Repo
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Fixtures -- provisions via Letflow.TenantFixture (ISS-0112 / GH#366).
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "req229-projector",
        display_name: "REQ-229 Projector Test Tenant"
      )

    assert {:ok, _seed_result} = EventTypes.seed!(schema_name)

    %{tenant_id: tenant_id, schema_name: schema_name}
  end

  defp valid_definition(overrides) do
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

  defp update_attrs(record_id, overrides \\ %{}) do
    Map.merge(
      %{
        entity_type: "customer",
        record_id: record_id,
        field_values: %{"customer_name" => "Acme Corp", "age" => 43},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp delete_attrs(record_id, overrides \\ %{}) do
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

  # Low-level event append, bypassing Letflow.Entities.Records entirely --
  # used only by the AC2 "definition version advanced before delete" test
  # (see moduledoc) to control each event's own `entity_def_version` payload
  # value directly.
  defp append_event!(schema, instance_id, event_type, payload_map) do
    attrs = %{
      instance_id: instance_id,
      event_type: event_type,
      payload: Jason.encode!(payload_map),
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate()
    }

    assert {:ok, multi} = EventStore.append_multi(Ecto.Multi.new(), attrs, prefix: schema)
    assert {:ok, _changes} = Repo.transaction(multi)
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- replaying create + two updates (no delete) matches actual current
  # field_values.
  # ---------------------------------------------------------------------------------

  describe "AC1 -- replay_record/3 matches the record's actual current field_values" do
    test "create, then two updates, produces a snapshot matching entity_record_latest" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)
      record_id = created.record_id

      assert {:ok, %{record: _first_update}} =
               Records.update_record(
                 update_attrs(record_id, %{
                   field_values: %{"customer_name" => "Acme Corp", "age" => 43}
                 }),
                 schema
               )

      assert {:ok, %{record: second_update}} =
               Records.update_record(
                 update_attrs(record_id, %{
                   field_values: %{"customer_name" => "Acme Global", "age" => 44}
                 }),
                 schema
               )

      assert {:ok, snapshot} = Projector.replay_record("customer", record_id, schema)

      assert snapshot.entity_type == "customer"
      assert snapshot.record_id == record_id
      assert snapshot.field_values == second_update.field_values
      refute snapshot.deleted
      assert snapshot.entity_def_version == second_update.entity_def_version
      assert snapshot.last_event_global_seq == second_update.last_event_global_seq
      assert snapshot.last_event_sequence_number == 3
      assert snapshot.last_event_type == "ENTITY_RECORD_UPDATED"

      # Cross-check against the live `entity_record_latest` row too (AC1's
      # own "matching the record's actual current field_values" framing).
      assert {:ok, live} = Latest.get(record_id, "customer", schema)
      assert snapshot.field_values == live.field_values
      assert snapshot.entity_def_version == live.entity_def_version
      assert snapshot.deleted == live.deleted
    end

    test "an unknown record_id under a real entity type returns {:error, :record_not_found}" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, _} = Records.create_record(create_attrs(), schema)

      assert Projector.replay_record("customer", Ecto.UUID.generate(), schema) ==
               {:error, :record_not_found}
    end

    test "an entity type that has never had a record created returns {:error, :entity_type_not_found}" do
      %{schema_name: schema} = provisioned_tenant()

      assert Projector.replay_record("never_created", Ecto.UUID.generate(), schema) ==
               {:error, :entity_type_not_found}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- a stream ending in ENTITY_RECORD_DELETED produces a snapshot
  # correctly reflecting deletion per the stated representation.
  # ---------------------------------------------------------------------------------

  # ---------------------------------------------------------------------------------
  # REQ-683 P1-P3 -- the ENTITY_RECORD_MIGRATED fold clause (pure: merged events in, snapshot out).
  # ---------------------------------------------------------------------------------

  describe "REQ-683 -- fold_record_events/3 and ENTITY_RECORD_MIGRATED" do
    @rid "11111111-1111-1111-1111-111111111111"

    defp fold_event(type, seq, payload) do
      %{
        event_type: type,
        payload: payload,
        sequence_number: seq,
        global_seq: seq + 100,
        event_id: Ecto.UUID.generate()
      }
    end

    defp created_event do
      fold_event("ENTITY_RECORD_CREATED", 1, %{
        "entity_type" => "customer",
        "entity_def_version" => "aa",
        "record_id" => @rid,
        "field_values" => %{"keep" => 1, "touch" => "old"}
      })
    end

    defp migrated_event(seq) do
      fold_event("ENTITY_RECORD_MIGRATED", seq, %{
        "entity_type" => "customer",
        "entity_def_version" => "bb",
        "record_id" => @rid,
        "before" => %{"touch" => "old", "new" => nil},
        "after" => %{"touch" => "new", "new" => 2}
      })
    end

    test "P1: merges after over field_values, takes the payload version and the event fields" do
      migrated = migrated_event(2)

      assert {:ok, snap} =
               Projector.fold_record_events("customer", @rid, [created_event(), migrated])

      assert snap.field_values == %{"keep" => 1, "touch" => "new", "new" => 2}
      assert snap.entity_def_version == Base.decode16!("bb", case: :lower)
      assert snap.deleted == false
      assert snap.last_event_type == "ENTITY_RECORD_MIGRATED"
      assert snap.last_event_sequence_number == 2
      assert snap.last_event_global_seq == migrated.global_seq
    end

    test "P2: MIGRATED as the first event is a missing_created_event error" do
      assert {:error, {:corrupt_event_stream, {:missing_created_event, @rid}}} =
               Projector.fold_record_events("customer", @rid, [migrated_event(1)])
    end

    test "P3: MIGRATED after DELETED is an event_after_delete error" do
      deleted =
        fold_event("ENTITY_RECORD_DELETED", 2, %{
          "entity_type" => "customer",
          "entity_def_version" => "aa",
          "record_id" => @rid
        })

      migrated = migrated_event(3)

      assert {:error,
              {:corrupt_event_stream, {:event_after_delete, @rid, "ENTITY_RECORD_MIGRATED", id}}} =
               Projector.fold_record_events("customer", @rid, [created_event(), deleted, migrated])

      assert id == migrated.event_id
    end
  end

  describe "AC2 -- replay_record/3 on a stream ending in DELETED reflects deletion correctly" do
    test "deleted: true, field_values retained at its last pre-delete value" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)
      record_id = created.record_id

      assert {:ok, %{record: updated}} = Records.update_record(update_attrs(record_id), schema)
      assert {:ok, %{record: deleted}} = Records.delete_record(delete_attrs(record_id), schema)

      assert {:ok, snapshot} = Projector.replay_record("customer", record_id, schema)

      assert snapshot.deleted == true
      assert snapshot.field_values == updated.field_values
      assert snapshot.field_values == deleted.field_values
      assert snapshot.entity_def_version == deleted.entity_def_version
      assert snapshot.last_event_type == "ENTITY_RECORD_DELETED"
      assert snapshot.last_event_sequence_number == 3

      # Cross-check against the live row, matching REQ-228's already-shipped
      # write path field-by-field (design doc §3.4).
      assert {:ok, live} = Latest.get(record_id, "customer", schema)
      assert snapshot.field_values == live.field_values
      assert snapshot.deleted == live.deleted
      assert snapshot.entity_def_version == live.entity_def_version
    end

    test "entity_def_version on a DELETE is re-decoded from the DELETE event's OWN payload, not carried forward from the pre-delete value (the exact defect class CODE-DESIGN-VALIDATOR caught)" do
      %{schema_name: schema} = provisioned_tenant()
      entity_type = "customer"
      record_id = Ecto.UUID.generate()

      {:ok, instance_id} = EntityTypeInstance.get_or_create(entity_type, schema)

      pre_delete_version_hex = "aaaaaaaaaaaaaaaa"
      post_delete_version_hex = "bbbbbbbbbbbbbbbb"

      field_values = %{"customer_name" => "Acme", "age" => 42}
      updated_field_values = %{"customer_name" => "Acme Corp", "age" => 43}

      append_event!(schema, instance_id, "ENTITY_RECORD_CREATED", %{
        "entity_type" => entity_type,
        "entity_def_version" => pre_delete_version_hex,
        "record_id" => record_id,
        "field_values" => field_values
      })

      append_event!(schema, instance_id, "ENTITY_RECORD_UPDATED", %{
        "entity_type" => entity_type,
        "entity_def_version" => pre_delete_version_hex,
        "record_id" => record_id,
        "field_values" => updated_field_values
      })

      # Simulates the entity type's active definition having advanced
      # between the last update and the delete -- the DELETE event's own
      # payload carries the NEW version, exactly like
      # `Letflow.Entities.Records.delete_record/2`'s real
      # `fetch_active_definition/2` + `base_payload/1` call would produce.
      append_event!(schema, instance_id, "ENTITY_RECORD_DELETED", %{
        "entity_type" => entity_type,
        "entity_def_version" => post_delete_version_hex,
        "record_id" => record_id
      })

      assert {:ok, snapshot} = Projector.replay_record(entity_type, record_id, schema)

      expected_version = Base.decode16!(post_delete_version_hex, case: :lower)
      pre_delete_version = Base.decode16!(pre_delete_version_hex, case: :lower)

      assert snapshot.deleted == true
      assert snapshot.entity_def_version == expected_version
      refute snapshot.entity_def_version == pre_delete_version
      # field_values IS carried forward unchanged (different rule from
      # entity_def_version -- design doc §3.4).
      assert snapshot.field_values == updated_field_values
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- rebuild_projection/2 restores exactly what replay_record/3 would
  # independently compute, after an artificial corruption of one entity
  # type's rows.
  # ---------------------------------------------------------------------------------

  describe "AC3 -- rebuild_projection/2 restores exactly the state replay independently computes" do
    test "after corrupting entity_record_latest rows for one entity type, rebuild restores them" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      # Three "customer" records: one plain create, one create+update, one
      # create+update+delete.
      assert {:ok, %{record: r1}} = Records.create_record(create_attrs(), schema)

      assert {:ok, %{record: r2_created}} =
               Records.create_record(
                 create_attrs(%{idempotency_key: Ecto.UUID.generate()}),
                 schema
               )

      assert {:ok, %{record: r2}} =
               Records.update_record(update_attrs(r2_created.record_id), schema)

      assert {:ok, %{record: r3_created}} =
               Records.create_record(
                 create_attrs(%{idempotency_key: Ecto.UUID.generate()}),
                 schema
               )

      assert {:ok, %{record: _r3_updated}} =
               Records.update_record(update_attrs(r3_created.record_id), schema)

      assert {:ok, %{record: r3}} =
               Records.delete_record(delete_attrs(r3_created.record_id), schema)

      record_ids = [r1.record_id, r2.record_id, r3.record_id]

      expected =
        for record_id <- record_ids, into: %{} do
          assert {:ok, snapshot} = Projector.replay_record("customer", record_id, schema)
          {record_id, snapshot}
        end

      # Artificially corrupt entity_record_latest for "customer" only --
      # garbage field_values, flip deleted flags.
      Repo.update_all(
        from(l in Latest, where: l.entity_type == "customer"),
        [set: [field_values: %{"corrupted" => true}, deleted: true]],
        prefix: schema
      )

      for record_id <- record_ids do
        assert {:ok, corrupted} = Latest.get(record_id, "customer", schema)
        assert corrupted.field_values == %{"corrupted" => true}
      end

      assert {:ok, result} = Projector.rebuild_projection(schema, entity_type: "customer")

      assert result.entity_types_rebuilt == ["customer"]
      assert result.records_rebuilt == 3

      for record_id <- record_ids do
        assert {:ok, restored} = Latest.get(record_id, "customer", schema)
        expected_snapshot = Map.fetch!(expected, record_id)

        assert restored.field_values == expected_snapshot.field_values
        assert restored.deleted == expected_snapshot.deleted
        assert restored.entity_def_version == expected_snapshot.entity_def_version
      end
    end

    test "rebuild_projection/2 for an unknown entity_type returns {:error, :entity_type_not_found}" do
      %{schema_name: schema} = provisioned_tenant()

      assert Projector.rebuild_projection(schema, entity_type: "never_created") ==
               {:error, :entity_type_not_found}
    end

    test "a corrupt event stream for one entity type aborts that type's rebuild without touching others" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      create_active_definition!(schema, %{name: "invoice", display_name: "Invoice"})

      assert {:ok, %{record: good_record}} =
               Records.create_record(create_attrs(%{entity_type: "invoice"}), schema)

      # Corrupt "customer"'s own event log directly: append an
      # ENTITY_RECORD_UPDATED with no prior ENTITY_RECORD_CREATED for a
      # brand-new record_id -- a malformed stream the command path itself
      # can never produce.
      {:ok, instance_id} = EntityTypeInstance.get_or_create("customer", schema)
      orphan_record_id = Ecto.UUID.generate()

      append_event!(schema, instance_id, "ENTITY_RECORD_UPDATED", %{
        "entity_type" => "customer",
        "entity_def_version" => "cc",
        "record_id" => orphan_record_id,
        "field_values" => %{"customer_name" => "Orphan"}
      })

      assert {:error, {:corrupt_event_stream, {:missing_created_event, ^orphan_record_id}}} =
               Projector.rebuild_projection(schema, entity_type: "customer")

      # "invoice" was never touched by this call at all.
      assert {:ok, still_good} = Latest.get(good_record.record_id, "invoice", schema)
      assert still_good.field_values == good_record.field_values
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- rebuild_projection/2 is tenant-scoped.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- rebuild_projection/2 is tenant-scoped" do
    test "rebuilding tenant A's projection does not read or write tenant B's entity_record_latest rows" do
      %{schema_name: schema_a} = provisioned_tenant()
      %{schema_name: schema_b} = provisioned_tenant()

      create_active_definition!(schema_a)
      create_active_definition!(schema_b)

      assert {:ok, %{record: record_a}} = Records.create_record(create_attrs(), schema_a)

      assert {:ok, %{record: record_b}} =
               Records.create_record(
                 create_attrs(%{field_values: %{"customer_name" => "Tenant B Co", "age" => 7}}),
                 schema_b
               )

      # Corrupt tenant B's row too, so a cross-tenant leak would be
      # observable either as an unexpected rebuild count or as tenant B's
      # corruption being silently repaired by a call scoped to tenant A.
      Repo.update_all(
        from(l in Latest, where: l.entity_type == "customer"),
        [set: [field_values: %{"corrupted" => true}]],
        prefix: schema_b
      )

      assert {:ok, result} = Projector.rebuild_projection(schema_a, [])
      assert result.entity_types_rebuilt == ["customer"]
      assert result.records_rebuilt == 1

      assert {:ok, restored_a} = Latest.get(record_a.record_id, "customer", schema_a)
      assert restored_a.field_values == record_a.field_values

      # Tenant B's row is untouched -- still corrupted, not silently fixed,
      # and definitely not deleted, by tenant A's rebuild call.
      assert {:ok, still_corrupted_b} = Latest.get(record_b.record_id, "customer", schema_b)
      assert still_corrupted_b.field_values == %{"corrupted" => true}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- no route or controller file added or modified.
  # ---------------------------------------------------------------------------------

  describe "AC5 -- no route/controller file added or modified" do
    test "git diff --stat against this branch's base commit touches no lib/letflow_web path" do
      base_commit = "9613d348"

      {output, 0} = System.cmd("git", ["diff", "--stat", base_commit, "--", "."])

      web_lines =
        output
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "lib/letflow_web"))

      assert web_lines == [],
             "expected no lib/letflow_web/** files touched, got: #{inspect(web_lines)}"
    end
  end
end
