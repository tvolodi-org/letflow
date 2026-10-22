defmodule Letflow.Engine.VariableLabelsEventSchemaTest do
  @moduledoc """
  Decision 0062 R8h-5 (GH #2616 part 1): the five event types that carry a variable value declare
  their optional label fields at a bumped schema version. E-1 seeded versions, E-2 payload
  validation, E-3 a tenant provisioned before the bump reaches the versions on
  `replay_migrations`, E-4 the backfill upgrades an old-version tenant.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.EventStore.Registry
  alias Letflow.EventStore.Registry.EventType
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Backfill

  @bumped %{
    "INSTANCE_STARTED" => 2,
    "TASK_COMPLETED" => 4,
    "SUB_PROCESS_COMPLETED" => 2,
    "EXECUTION_ERROR" => 2,
    "SCRIPT_TASK_COMPLETED" => 2
  }
  @names Map.keys(@bumped)

  defp versions(schema) do
    EventType
    |> where([t], t.name in ^@names)
    |> select([t], {t.name, max(t.schema_version)})
    |> group_by([t], t.name)
    |> Repo.all(prefix: schema)
    |> Map.new()
  end

  # Leaves each bumped type at v1 with a permissive schema: a tenant provisioned before the bump.
  defp lower_to_v1!(schema) do
    Repo.delete_all(from(t in EventType, where: t.name in ^@names), prefix: schema)

    for name <- @names do
      %EventType{}
      |> EventType.changeset(%{
        "name" => name,
        "schema_version" => 1,
        "description" => "pre-0062 fixture",
        "json_schema" => %{"type" => "object"}
      })
      |> Repo.insert!(prefix: schema)
    end
  end

  @labels %{"x" => ["customer.salary"]}

  defp payload("INSTANCE_STARTED", labelled) do
    base = %{"definition_id" => "d", "initial_variables" => %{"x" => 1}}
    if labelled, do: Map.put(base, "initial_labels", @labels), else: base
  end

  defp payload("TASK_COMPLETED", labelled) do
    base = %{
      "task_id" => "t",
      "node_id" => "n",
      "output_variables" => %{"x" => 1},
      "activated_nodes" => []
    }

    if labelled do
      Map.merge(base, %{
        "output_labels" => @labels,
        "merged_variable_events" => [
          %{"event" => "variable_overwritten", "key" => "x", "old_labels" => ["a.b"]},
          %{"event" => "computed_field_disagreement", "server_labels" => ["a.b"]},
          %{"event" => "visible_when_false_value_discarded", "discarded_labels" => ["a.b"]}
        ]
      })
    else
      base
    end
  end

  defp payload("SUB_PROCESS_COMPLETED", labelled) do
    base = %{"child_instance_id" => "c", "output_variables" => %{}, "activated_nodes" => []}

    if labelled do
      Map.merge(base, %{
        "output_labels" => @labels,
        "merged_variable_events" => [
          %{"event" => "variable_overwritten", "key" => "x", "new_labels" => ["a.b"]}
        ]
      })
    else
      base
    end
  end

  defp payload("EXECUTION_ERROR", labelled) do
    base = %{
      "error_type" => "e",
      "affected" => %{"kind" => "node", "node_id" => "n"},
      "reason" => "r",
      "variables" => %{"x" => 1}
    }

    if labelled, do: Map.put(base, "labels", @labels), else: base
  end

  defp payload("SCRIPT_TASK_COMPLETED", labelled) do
    base = %{
      "dispatch_id" => "d",
      "node_id" => "n",
      "attempt" => 1,
      "script_key" => "k",
      "script_version" => 1,
      "output" => %{"x" => 1}
    }

    if labelled, do: Map.put(base, "output_labels", @labels), else: base
  end

  test "E-1: a new tenant is seeded at the bumped versions" do
    %{schema_name: schema} = TenantFixture.provisioned_tenant!(slug_prefix: "gh2616-e1")
    assert versions(schema) == @bumped
  end

  test "E-2: a labelled payload validates at the current version, a malformed one is rejected" do
    %{tenant_id: tenant_id} = TenantFixture.provisioned_tenant!(slug_prefix: "gh2616-e2")

    for name <- @names do
      assert :ok =
               Registry.validate_payload(name, Jason.encode!(payload(name, false)), tenant_id),
             "#{name} unlabelled"

      assert :ok =
               Registry.validate_payload(name, Jason.encode!(payload(name, true)), tenant_id),
             "#{name} labelled"
    end

    field = %{
      "INSTANCE_STARTED" => "initial_labels",
      "TASK_COMPLETED" => "output_labels",
      "SUB_PROCESS_COMPLETED" => "output_labels",
      "EXECUTION_ERROR" => "labels",
      "SCRIPT_TASK_COMPLETED" => "output_labels"
    }

    for name <- @names do
      bad = Map.put(payload(name, false), field[name], ["not", "an", "object"])

      assert {:error, {:payload_validation_failed, _}} =
               Registry.validate_payload(name, Jason.encode!(bad), tenant_id),
             "#{name} malformed"
    end

    bad_entry =
      payload("TASK_COMPLETED", true)
      |> Map.put("merged_variable_events", [
        %{"event" => "variable_overwritten", "key" => "x", "old_labels" => "customer.salary"}
      ])

    assert {:error, {:payload_validation_failed, _}} =
             Registry.validate_payload("TASK_COMPLETED", Jason.encode!(bad_entry), tenant_id)
  end

  test "E-3: a tenant provisioned before the bump reaches the new versions on replay_migrations" do
    %{tenant_id: tenant_id, schema_name: schema} =
      TenantFixture.provisioned_tenant!(slug_prefix: "gh2616-e3")

    lower_to_v1!(schema)
    assert versions(schema) |> Map.values() |> Enum.uniq() == [1]

    assert {:ok, _} = TenantProvisioning.replay_migrations(tenant_id)
    assert versions(schema) == @bumped
  end

  test "E-4: the backfill brings an old-version tenant to the seeded versions" do
    %{schema_name: schema} = TenantFixture.provisioned_tenant!(slug_prefix: "gh2616-e4")
    lower_to_v1!(schema)

    for name <- @names do
      attrs = TenantProvisioning.platform_event_type_seed_attrs(name)
      assert attrs.schema_version == @bumped[name]
      assert {:ok, %{updated: updated}} = Backfill.run(attrs)
      assert updated >= 1
    end

    assert versions(schema) == @bumped
  end
end
