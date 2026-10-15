defmodule Letflow.EventStore.RegistryEntityWritesTest do
  @moduledoc """
  GH #2587 / REQ-499 PR A1 (design `lib/letflow/design/gh2587-req499-pr-a-prerequisites.md`
  2.3, 2.4, 11 A1 "event types registered"): `INSTANCE_SYS_VARIABLES_SET` and
  `TASK_ENTITY_WRITES_APPLIED` are seeded at schema_version 1 for a new tenant, re-seeded by
  `replay_migrations/1` for a tenant provisioned before the change, and both schemas are
  closed (additionalProperties false, every key required). Mirrors
  `tenant_provisioning_script_events_test.exs`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.EventStore.Registry
  alias Letflow.EventStore.Registry.EventType
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @sys "INSTANCE_SYS_VARIABLES_SET"
  @applied "TASK_ENTITY_WRITES_APPLIED"
  @types [@sys, @applied]

  defp registered(schema) do
    EventType
    |> where([t], t.name in ^@types)
    |> select([t], {t.name, t.schema_version})
    |> Repo.all(prefix: schema)
    |> Enum.sort()
  end

  defp sys_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "node_id" => "task_1",
        "cause" => "entity_writes",
        "values" => %{"_sys.r" => Ecto.UUID.generate(), "_sys.r.seq" => 7}
      },
      overrides
    )
  end

  defp line(overrides \\ %{}) do
    Map.merge(
      %{
        "line_index" => 0,
        "entity_type" => "invoice",
        "record_id" => Ecto.UUID.generate(),
        "event_global_seq" => 42
      },
      overrides
    )
  end

  defp applied_payload(overrides) do
    Map.merge(
      %{
        "node_id" => "task_1",
        "task_id" => Ecto.UUID.generate(),
        "dispatch_id" => nil,
        "lines_hash" => String.duplicate("a", 64),
        "lines" => [line()]
      },
      overrides
    )
  end

  defp validate(type, payload, tenant_id),
    do: Registry.validate_payload(type, Jason.encode!(payload), tenant_id)

  test "new tenant: both rows at schema_version 1" do
    %{schema_name: schema} = TenantFixture.provisioned_tenant!(slug_prefix: "gh2587-ev")
    assert registered(schema) == [{@sys, 1}, {@applied, 1}]
  end

  test "rows deleted -> unknown_event_type; replay_migrations/1 re-seeds them" do
    %{tenant_id: tenant_id, schema_name: schema} =
      TenantFixture.provisioned_tenant!(slug_prefix: "gh2587-ev-old")

    {2, _} = Repo.delete_all(from(t in EventType, where: t.name in ^@types), prefix: schema)
    assert registered(schema) == []

    assert {:error, :unknown_event_type} = validate(@sys, sys_payload(), tenant_id)

    assert {:error, :unknown_event_type} =
             validate(@applied, applied_payload(%{}), tenant_id)

    assert {:ok, _} = TenantProvisioning.replay_migrations(tenant_id)
    assert registered(schema) == [{@sys, 1}, {@applied, 1}]

    assert :ok = validate(@sys, sys_payload(), tenant_id)
    assert :ok = validate(@applied, applied_payload(%{}), tenant_id)

    assert :ok =
             validate(
               @applied,
               applied_payload(%{"task_id" => nil, "dispatch_id" => Ecto.UUID.generate()}),
               tenant_id
             )
  end

  describe "closed schemas" do
    setup do
      %{tenant_id: tenant_id} = TenantFixture.provisioned_tenant!(slug_prefix: "gh2587-ev-inv")
      %{tenant_id: tenant_id}
    end

    test "INSTANCE_SYS_VARIABLES_SET: extra key, missing key, cause outside the enum", %{
      tenant_id: tenant_id
    } do
      assert {:error, {:payload_validation_failed, [_ | _]}} =
               validate(@sys, sys_payload(%{"extra" => 1}), tenant_id)

      assert {:error, {:payload_validation_failed, [_ | _]}} =
               validate(@sys, Map.delete(sys_payload(), "values"), tenant_id)

      assert {:error, {:payload_validation_failed, [%{constraint: "enum"}]}} =
               validate(@sys, sys_payload(%{"cause" => "form"}), tenant_id)
    end

    test "TASK_ENTITY_WRITES_APPLIED: extra key, missing key, lines item extra / missing key", %{
      tenant_id: tenant_id
    } do
      assert {:error, {:payload_validation_failed, [_ | _]}} =
               validate(@applied, applied_payload(%{"extra" => 1}), tenant_id)

      assert {:error, {:payload_validation_failed, [_ | _]}} =
               validate(@applied, Map.delete(applied_payload(%{}), "lines_hash"), tenant_id)

      assert {:error, {:payload_validation_failed, [%{constraint: "additionalProperties"}]}} =
               validate(
                 @applied,
                 applied_payload(%{"lines" => [line(%{"value" => "secret"})]}),
                 tenant_id
               )

      assert {:error, {:payload_validation_failed, [%{constraint: "required"}]}} =
               validate(
                 @applied,
                 applied_payload(%{"lines" => [Map.delete(line(), "record_id")]}),
                 tenant_id
               )

      assert {:error, {:payload_validation_failed, [%{constraint: "minimum"}]}} =
               validate(
                 @applied,
                 applied_payload(%{"lines" => [line(%{"line_index" => -1})]}),
                 tenant_id
               )
    end
  end
end
