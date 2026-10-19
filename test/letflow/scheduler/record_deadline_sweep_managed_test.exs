defmodule Letflow.Scheduler.RecordDeadlineSweepManagedTest do
  @moduledoc """
  GH #2583 AC3 (design `lib/letflow/design/gh2583-records-managed-type-guard.md` section 6,
  T-12..T-14; spec `test/specs/GH-2583.md`): `Letflow.Scheduler.RecordDeadlineSweep` writes
  through `Records.update_record/2` (`:tenant`), so a rule configured on a module-managed type is
  refused per due record by `Records` itself: the record is not transitioned, no
  `ENTITY_RECORD_UPDATED` event is appended, and the existing per-record warning logs the ids and
  the reason atom `:entity_type_managed`, never a field value (decision 0054 D12: no entity write
  from timers). The same rule shape on the unmanaged `fxm_free` transitions (control).

  The fixture types have a single `name :: string` field, so one field serves as both the
  datetime field and the status field of the rule: the due status value IS a past timestamp.

  `async: false`: tenant provisioning switches the sandbox to `:auto` and the install runs DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EventStore.Event
  alias Letflow.Modules.FixtureManaged
  alias Letflow.Modules.Installs
  alias Letflow.Scheduler.RecordDeadlineSweep
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @due "2020-01-01T00:00:00Z"
  @next "2020-01-02T00:00:00Z"

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2583-sweep")

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.tenant_id))
    end)

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)

    {:ok, _tenant_module} =
      Installs.install("fixture_managed", Ecto.UUID.generate(),
        prefix: tenant.schema_name,
        rationale: "GH #2583 sweep test install"
      )

    {:ok, schema: tenant.schema_name}
  end

  defp rule(entity_type) do
    %{
      entity_type: entity_type,
      datetime_field: "name",
      status_field: "name",
      due_status_value: @due,
      new_status_value: @next
    }
  end

  defp record_count(schema, entity_type) do
    Repo.aggregate(from(l in Latest, where: l.entity_type == ^entity_type), :count,
      prefix: schema
    )
  end

  defp updated_event_count(schema) do
    Repo.one!(
      from(e in Event,
        where: e.event_type == "ENTITY_RECORD_UPDATED",
        select: count(e.event_id)
      ),
      prefix: schema
    )
  end

  defp stored(schema, entity_type, record_id) do
    {:ok, record} = Latest.get(record_id, entity_type, schema)
    Map.take(record, [:field_values, :deleted, :last_event_global_seq])
  end

  # The only due fxm_unit record of a fresh tenant, created by the owning module.
  defp managed_due_record!(schema) do
    # The rule's cast `(field_values->>'name')::timestamptz` must see ONLY this record.
    assert record_count(schema, "fxm_unit") == 0

    {:ok, %{record: record}} = FixtureManaged.create_record("fxm_unit", %{"name" => @due}, schema)
    assert record_count(schema, "fxm_unit") == 1
    record
  end

  describe "T-12/T-13 (AC3): a rule on a managed type transitions nothing" do
    test "T-12: run/2 returns :ok, the record is unchanged and no ENTITY_RECORD_UPDATED is appended",
         %{schema: schema} do
      record = managed_due_record!(schema)
      before = stored(schema, "fxm_unit", record.record_id)
      events = updated_event_count(schema)

      assert RecordDeadlineSweep.run(schema, rule("fxm_unit")) == :ok

      assert stored(schema, "fxm_unit", record.record_id) == before
      assert before.field_values == %{"name" => @due}
      assert updated_event_count(schema) == events
    end

    test "T-13: the per-record warning carries the reason atom and ids, never the field value",
         %{schema: schema} do
      record = managed_due_record!(schema)

      log =
        ExUnit.CaptureLog.capture_log(
          [
            level: :warning,
            format: "[$level] $metadata| $message\n",
            metadata: [:schema, :entity_type, :record_id, :reason]
          ],
          fn -> assert RecordDeadlineSweep.run(schema, rule("fxm_unit")) == :ok end
        )

      assert log =~ "deadline sweep: one record failed to transition"
      assert log =~ "reason=:entity_type_managed"
      assert log =~ "entity_type=fxm_unit"
      assert log =~ "record_id=#{record.record_id}"
      assert log =~ "schema=#{schema}"
      refute log =~ @due
      # One due record, refused once: failed_ids stops a retry within the same call.
      assert length(String.split(log, "one record failed to transition")) == 2
    end
  end

  describe "T-14 (AC3): control on the unmanaged fxm_free" do
    test "the same rule shape transitions the record and appends one ENTITY_RECORD_UPDATED",
         %{schema: schema} do
      {:ok, %{record: record}} =
        Records.create_record(
          %{
            entity_type: "fxm_free",
            field_values: %{"name" => @due},
            actor_id: Ecto.UUID.generate(),
            idempotency_key: Ecto.UUID.generate()
          },
          schema
        )

      events = updated_event_count(schema)

      assert RecordDeadlineSweep.run(schema, rule("fxm_free")) == :ok

      assert stored(schema, "fxm_free", record.record_id).field_values == %{"name" => @next}
      assert updated_event_count(schema) == events + 1
    end
  end
end
