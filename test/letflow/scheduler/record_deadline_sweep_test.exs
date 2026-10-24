defmodule Letflow.Scheduler.RecordDeadlineSweepTest do
  @moduledoc """
  Tests for REQ-331 -- `Letflow.Scheduler.RecordDeadlineSweep`, the generic
  deadline-driven record transition sweep added as an eighth per-tenant
  sweep on `Letflow.Scheduler.Poller`.

  REQ-331's own gating requirement (REQ-330) confirmed this requirement's
  bucket-B premise rather than overturning it -- not re-scoped; built exactly
  as filed. The verdict itself is quoted in ELIXIR-DEV's completion report,
  not here (0022 rule 1 -- see below).

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  `async: false` because `Letflow.TenantFixture.provisioned_tenant!/1`
  switches the sandbox to global `:auto` mode (its own moduledoc), which is
  also exactly what makes the AC-4 concurrency test below a real two-connection
  race rather than a single shared sandboxed transaction.

  No module, function, config key, permission atom, log message, error atom,
  test name, or comment in this file names any of REQ-331's six forbidden
  words -- see the plain module/rule vocabulary used throughout ("widget",
  "open"/"closed", "due_at"/"closed_at").
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EventStore.Event
  alias Letflow.Scheduler.RecordDeadlineSweep
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp tenant_ctx(slug_prefix) do
    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: slug_prefix,
        display_name: "REQ-331 deadline sweep test tenant"
      )

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)

    %{schema_name: tenant.schema_name, tenant_id: tenant.tenant_id}
  end

  defp create_active_definition!(schema, definition) do
    {:ok, entity_definition} =
      Definitions.create_definition(
        %{definition: definition, created_by: Ecto.UUID.generate()},
        schema
      )

    {:ok, activated} =
      Definitions.activate_definition(
        entity_definition.name,
        Ecto.UUID.generate(),
        "req331 go-live",
        schema
      )

    activated
  end

  defp widget_fields do
    [
      %{name: "due_at", type: :datetime, queried: true},
      %{name: "state", type: :string, queried: true},
      %{name: "closed_at", type: :datetime}
    ]
  end

  defp rule(overrides \\ %{}) do
    Map.merge(
      %{
        entity_type: "widget",
        datetime_field: "due_at",
        status_field: "state",
        due_status_value: "open",
        new_status_value: "closed",
        completion_field: "closed_at",
        callback_mfa: nil
      },
      overrides
    )
  end

  defp create_record!(schema, field_values) do
    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: "widget",
          field_values: field_values,
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
        },
        schema
      )

    record
  end

  defp past_iso(seconds_ago) do
    DateTime.utc_now()
    |> DateTime.add(-seconds_ago, :second)
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end

  defp record_updated_event_count(schema) do
    Repo.one!(
      from(e in Event, where: e.event_type == "ENTITY_RECORD_UPDATED", select: count(e.event_id)),
      prefix: schema
    )
  end

  # ---------------------------------------------------------------------------
  # AC-4/AC-9 -- SKIP LOCKED: two concurrent sweeps over the same due record
  # ---------------------------------------------------------------------------

  describe "AC-4: SKIP LOCKED prevents double transition under concurrency" do
    test "two concurrent sweeps over the same due record produce exactly one transition" do
      ctx = tenant_ctx("req331-lock")

      create_active_definition!(ctx.schema_name, %{
        name: "widget",
        display_name: "Widget",
        fields: widget_fields()
      })

      record =
        create_record!(ctx.schema_name, %{
          "due_at" => past_iso(60),
          "state" => "open"
        })

      the_rule = rule()

      t1 = Task.async(fn -> RecordDeadlineSweep.run(ctx.schema_name, the_rule) end)
      t2 = Task.async(fn -> RecordDeadlineSweep.run(ctx.schema_name, the_rule) end)

      Task.await(t1, 10_000)
      Task.await(t2, 10_000)

      {:ok, reloaded} = Latest.get(record.record_id, "widget", ctx.schema_name)
      assert reloaded.field_values["state"] == "closed"

      # Exactly one of the two concurrent runs actually wrote -- proven by the
      # event log, not just the final field value (which a double-write would
      # also leave at "closed").
      assert record_updated_event_count(ctx.schema_name) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # AC-8 -- per-record transaction isolation
  # ---------------------------------------------------------------------------

  describe "AC-8: one record's failure does not block the others" do
    test "several due records, one fails validation, the others still transition and the failure is logged" do
      ctx = tenant_ctx("req331-isolation")

      create_active_definition!(ctx.schema_name, %{
        name: "widget",
        display_name: "Widget",
        fields: widget_fields()
      })

      # Created under the FIRST active definition version -- no "note" field.
      failing_record =
        create_record!(ctx.schema_name, %{"due_at" => past_iso(90), "state" => "open"})

      # A second, later-activated definition version adds a NEW required
      # field. Records created under the first version (above) never got a
      # chance to supply it, so re-validating `failing_record`'s existing
      # field_values against the NOW-active definition (what
      # `Letflow.Entities.Records.update_record/2` always does, per its own
      # moduledoc's "definition may differ from creation time" note) fails --
      # a real, unmocked validation failure, not a simulated one.
      create_active_definition!(ctx.schema_name, %{
        name: "widget",
        display_name: "Widget",
        fields: widget_fields() ++ [%{name: "note", type: :string, required: true}]
      })

      ok_record_1 =
        create_record!(ctx.schema_name, %{
          "due_at" => past_iso(80),
          "state" => "open",
          "note" => "first"
        })

      ok_record_2 =
        create_record!(ctx.schema_name, %{
          "due_at" => past_iso(70),
          "state" => "open",
          "note" => "second"
        })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          RecordDeadlineSweep.run(ctx.schema_name, rule())
        end)

      assert log =~ "one record failed to transition"

      {:ok, failing_reloaded} = Latest.get(failing_record.record_id, "widget", ctx.schema_name)
      assert failing_reloaded.field_values["state"] == "open"

      {:ok, ok_reloaded_1} = Latest.get(ok_record_1.record_id, "widget", ctx.schema_name)
      assert ok_reloaded_1.field_values["state"] == "closed"

      {:ok, ok_reloaded_2} = Latest.get(ok_record_2.record_id, "widget", ctx.schema_name)
      assert ok_reloaded_2.field_values["state"] == "closed"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-6 -- completion timestamp is the record's deadline, not the sweep time
  # ---------------------------------------------------------------------------

  describe "AC-6: completion timestamp equals the deadline value exactly" do
    test "a record due at T, swept at T plus a measurable delay, completes at exactly T" do
      ctx = tenant_ctx("req331-deadline-value")

      create_active_definition!(ctx.schema_name, %{
        name: "widget",
        display_name: "Widget",
        fields: widget_fields()
      })

      due_at_iso = past_iso(60)

      record =
        create_record!(ctx.schema_name, %{"due_at" => due_at_iso, "state" => "open"})

      # A measurable delay between "now" (when the record became due, already
      # in the past by construction above) and the actual sweep call below --
      # proves the completion value tracks the record's own stored deadline,
      # never DateTime.utc_now() at sweep time.
      Process.sleep(50)

      RecordDeadlineSweep.run(ctx.schema_name, rule())

      {:ok, reloaded} = Latest.get(record.record_id, "widget", ctx.schema_name)

      assert reloaded.field_values["state"] == "closed"
      assert reloaded.field_values["closed_at"] == due_at_iso
      refute reloaded.field_values["closed_at"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # GH #2689 D1 -- a stored record over the entity size cap still transitions
  # ---------------------------------------------------------------------------

  describe "GH #2689 D1: the sweep on a record stored over the size cap" do
    test "the oversize value is carried over unchanged, the status flips, nothing is retried" do
      ctx = tenant_ctx("gh2689-sweep")

      create_active_definition!(ctx.schema_name, %{
        name: "widget",
        display_name: "Widget",
        fields: widget_fields() ++ [%{name: "blob", type: :string}]
      })

      record = create_record!(ctx.schema_name, %{"due_at" => past_iso(60), "state" => "open"})
      over = String.duplicate("x", 65_536 + 500)

      # Stored over the cap the way a pre-cap record is: written directly.
      {1, _} =
        Repo.update_all(
          from(l in Latest, where: l.record_id == ^record.record_id),
          [set: [field_values: Map.put(record.field_values, "blob", over)]],
          prefix: ctx.schema_name
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          RecordDeadlineSweep.run(ctx.schema_name, rule())
        end)

      refute log =~ "one record failed to transition"
      {:ok, reloaded} = Latest.get(record.record_id, "widget", ctx.schema_name)
      assert reloaded.field_values["state"] == "closed"
      assert reloaded.field_values["blob"] == over
    end
  end

  # ---------------------------------------------------------------------------
  # INV-1 -- a sweep rule configured for one tenant never transitions
  # another tenant's data.
  # ---------------------------------------------------------------------------

  describe "INV-1: tenant isolation" do
    test "sweeping tenant A's schema never transitions a due record in tenant B's schema" do
      ctx_a = tenant_ctx("req331-inv1-a")
      ctx_b = tenant_ctx("req331-inv1-b")

      for ctx <- [ctx_a, ctx_b] do
        create_active_definition!(ctx.schema_name, %{
          name: "widget",
          display_name: "Widget",
          fields: widget_fields()
        })
      end

      record_a =
        create_record!(ctx_a.schema_name, %{"due_at" => past_iso(60), "state" => "open"})

      record_b =
        create_record!(ctx_b.schema_name, %{"due_at" => past_iso(60), "state" => "open"})

      # Sweep ONLY tenant A's schema.
      RecordDeadlineSweep.run(ctx_a.schema_name, rule())

      {:ok, reloaded_a} = Latest.get(record_a.record_id, "widget", ctx_a.schema_name)
      assert reloaded_a.field_values["state"] == "closed"

      {:ok, reloaded_b} = Latest.get(record_b.record_id, "widget", ctx_b.schema_name)
      assert reloaded_b.field_values["state"] == "open"
    end
  end
end
