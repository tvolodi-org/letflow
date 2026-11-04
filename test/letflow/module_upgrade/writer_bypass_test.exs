defmodule Letflow.ModuleUpgrade.WriterBypassTest do
  @moduledoc """
  REQ-683 criterion 8 (H1, decision 0055 D3 bypass rule): a migrated write fires no tenant write
  hook and no record trigger, and writes no audit row.

  A type with a hook that refuses every write still takes `migrate_record/5`; a type with a record
  trigger (flag on) gets an outbox row from a normal update and none from a migration.

  `async: false`: tenant provisioning switches the sandbox to `:auto` and the flag is app env.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.Engine.Lua.ScriptRunner
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Records
  alias Letflow.EntityTypeHooks, as: Hooks
  alias Letflow.ModuleUpgrade.Capability
  alias Letflow.ModuleUpgrade.Writer
  alias Letflow.RecordTriggersFixture, as: RF
  alias Letflow.Support.ScriptPolicyFixture, as: P
  alias Letflow.Support.ScriptTaskFixture, as: F

  @actor "00000000-0000-4000-8000-0000000000a1"
  @now ~U[2026-10-28 08:00:00.000000Z]

  setup_all do
    opts = [
      tenant: "tenant_warmup",
      timeout_ms: 5_000,
      ctx: %{instance_id: "i", node_id: "n", token_id: "t", now: @now}
    ]

    {:ok, _} = ScriptRunner.run("return { ok = true }", %{}, opts)
    :ok
  end

  setup do
    previous = Application.fetch_env(:letflow, :record_triggers_enabled)
    Application.put_env(:letflow, :record_triggers_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, :record_triggers_enabled, old)
        :error -> Application.delete_env(:letflow, :record_triggers_enabled)
      end
    end)

    tenant = F.tenant!("w683h")
    schema = tenant.schema_name
    assert {:ok, _} = EventTypes.seed!(schema)
    {:ok, cap} = Capability.new(tenant.tenant_id, "up-h", "plan-h", @actor)
    %{schema: schema, cap: cap}
  end

  defp create!(schema, type, values) do
    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: type,
          field_values: values,
          actor_id: @actor,
          idempotency_key: Ecto.UUID.generate()
        },
        schema
      )

    record.record_id
  end

  defp update(schema, type, record_id, values),
    do:
      Records.update_record(
        %{
          entity_type: type,
          record_id: record_id,
          field_values: values,
          actor_id: @actor,
          idempotency_key: Ecto.UUID.generate()
        },
        schema
      )

  defp audit_count(schema), do: Repo.aggregate(Entry, :count, prefix: schema)

  defp hook_rows(schema),
    do: Repo.all(from(a in Entry, where: a.action == "entity_write_hook.run"), prefix: schema)

  test "H1: a refusing write hook does not run for a migrated write", %{schema: schema, cap: cap} do
    P.active_definition!(schema, "bp", ["name", "note", "total"])
    record_id = create!(schema, "bp", %{"name" => "Ann"})

    manifest = %{
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}, "note" => %{"type" => "string"}}
      },
      "output_schema" => %{
        "type" => "object",
        "properties" => %{"total" => %{"type" => "string"}},
        "additionalProperties" => false
      },
      "derived_fields" => ["total"],
      "fail_codes" => ["too_big"],
      "limits" => %{"timeout_ms" => 5_000}
    }

    rule = F.published!(schema, "k_bp", ~s|fail("too_big")|, manifest, hook_kind: "entity_write")

    pin = %{
      "script_key" => rule.key,
      "script_version" => rule.version,
      "script_sha256" => rule.sha256
    }

    assert {:ok, _binding} = Hooks.bind(schema, "bp", pin, P.actor())

    # The hook is live: a normal update is refused and leaves a hook audit row.
    assert {:error, _refused} = update(schema, "bp", record_id, %{"name" => "Bob"})
    hook_rows_before = length(hook_rows(schema))
    assert hook_rows_before >= 1

    audit_before = audit_count(schema)
    outbox_before = length(RF.outbox_rows(schema))

    assert {:ok, :appended} =
             Writer.migrate_record(cap, "bp", record_id, %{"name" => "Migrated"}, "s1")

    assert length(hook_rows(schema)) == hook_rows_before
    assert audit_count(schema) == audit_before
    assert length(RF.outbox_rows(schema)) == outbox_before
  end

  test "H1: a record trigger enqueues for a normal update and not for a migration", %{
    schema: schema,
    cap: cap
  } do
    P.active_definition!(schema, "tr", ["name", "note", "total"])
    RF.bind!(schema, "tr", "updated")
    record_id = create!(schema, "tr", %{"name" => "Ann"})

    base = length(RF.outbox_rows(schema))
    assert {:ok, _} = update(schema, "tr", record_id, %{"name" => "Bob"})
    assert length(RF.outbox_rows(schema)) == base + 1

    audit_before = audit_count(schema)

    assert {:ok, :appended} =
             Writer.migrate_record(cap, "tr", record_id, %{"name" => "Migrated"}, "s1")

    assert length(RF.outbox_rows(schema)) == base + 1
    assert audit_count(schema) == audit_before
  end
end
