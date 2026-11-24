defmodule Letflow.Engine.NotifyWriteTargetsTest do
  @moduledoc """
  T-2592 (pilot gap G4): the READ KEYS of a notification step are refused in a
  task completion body -- the T-2430 rule, carried to the notification step.

  A notification step reads the RECIPIENT's variable and the variables of its
  values out of the running instance. The person who STARTS the process decides
  them; the person who COMPLETES a task in it may not. Without this refusal a
  completer would decide where the message goes: `POST /tasks/:id/complete`
  with `{"admin_email": "attacker@evil.com"}` overwrites the address the
  process started with, and the step then sends the message there.

  The activation fence of the step (`Letflow.Definitions.NotifyCalls`) only
  refuses a variable a human task DECLARES as its input -- a completer may send
  any other key in the body, so the refusal has to exist on the completion path
  itself. That is what this file proves, through the REAL
  `Letflow.Engine.complete_task/3`.

  The unit half -- which keys are in the refusal set -- is
  `test/letflow/engine/write_targets_test.exs` (WTU-5).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.OutboundDestinations
  alias Letflow.TenantFixture

  defp provisioned_tenant do
    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "t2592-notify-keys",
        display_name: "T-2592 notify keys"
      )

    # T-2597 (pilot gap G14): the tenant's OUTBOUND ALLOW-LIST -- the mail
    # channel. The list is empty by default, and a definition that carries a
    # notification step is refused at the activation while the channel is
    # closed (the guardrail task's own test file covers the refusal). Only the
    # CHANNEL is opened here: the recipient's domain is a runtime variable, so
    # no destination is known at activation time.
    {:ok, _entry} =
      OutboundDestinations.add(tenant.schema_name, nil, "email", nil)

    tenant
  end

  defp unique_name,
    do: "t2592-notify-def-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp unique_idempotency_key(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  # START -> task_a(HUMAN_TASK) -> task_b(HUMAN_TASK) -> notify(SERVICE_TASK) -> END
  #
  # The notification step sits AFTER the second human task, so both completions
  # below stop before it: the step is never dispatched by the engine (its
  # wiring is a later task of the pilot), and this file is about the KEYS.
  defp graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task_a", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "a"}},
        %{"id" => "task_b", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "b"}},
        %{
          "id" => "notify",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{
            "notify" => %{
              "template_key" => "tenant_registered",
              "recipient" => %{"var" => "admin_email"},
              "values" => %{"tenant_name" => %{"var" => "tenant_name"}}
            }
          }
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task_a"},
        %{"id" => "e2", "source" => "task_a", "target" => "task_b"},
        %{"id" => "e3", "source" => "task_b", "target" => "notify"},
        %{"id" => "e4", "source" => "notify", "target" => "end"}
      ]
    }
  end

  defp active_definition!(schema_name) do
    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: unique_name(),
                 version: "1.0.0",
                 graph: graph(),
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema_name
             )

    # The notification step reads the address and the name out of the instance,
    # so the definition DECLARES those variables: the typed mapping of the
    # step (T-2594's rule, carried to the notification step) binds a read to a
    # declared variable schema, and activation refuses a read the definition
    # does not declare.
    assert {:ok, _count} =
             Definitions.register_variable_schemas(
               definition.id,
               [
                 %{variable_key: "admin_email", json_schema: %{"type" => "string"}},
                 %{variable_key: "tenant_name", json_schema: %{"type" => "string"}}
               ],
               prefix: schema_name
             )

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  defp start_instance!(schema_name, definition, initial_variables) do
    assert {:ok, result} =
             Engine.create(
               %{
                 definition_id: definition.id,
                 initial_variables: initial_variables,
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique_idempotency_key("start")
               },
               prefix: schema_name
             )

    result.instance_id
  end

  defp complete_attrs(output_variables) do
    %{
      output_variables: output_variables,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: unique_idempotency_key("complete")
    }
  end

  defp find_task(schema_name, instance_id, node_id) do
    EngineTask
    |> where([t], t.instance_id == ^instance_id and t.node_id == ^node_id)
    |> Repo.one!(prefix: schema_name)
  end

  defp variables_of(schema_name, instance_id) do
    Repo.get!(InstanceProjection, instance_id, prefix: schema_name).variables
  end

  test "NT-1 a completion that carries the notification's read key is refused" do
    %{schema_name: schema_name} = provisioned_tenant()
    definition = active_definition!(schema_name)

    instance_id =
      start_instance!(schema_name, definition, %{
        "admin_email" => "real-admin@example.com",
        "tenant_name" => "Acme"
      })

    task = find_task(schema_name, instance_id, "task_a")

    assert {:error, {:output_refused, %{missing_keys: [], rejected_keys: ["admin_email"]}}} =
             Engine.complete_task(
               task.id,
               complete_attrs(%{"admin_email" => "attacker@evil.com"}),
               prefix: schema_name
             )
  end

  test "NT-2 the refused completion changes NOTHING: the address is the one the process started with" do
    %{schema_name: schema_name} = provisioned_tenant()
    definition = active_definition!(schema_name)

    instance_id =
      start_instance!(schema_name, definition, %{
        "admin_email" => "real-admin@example.com",
        "tenant_name" => "Acme"
      })

    task = find_task(schema_name, instance_id, "task_a")

    assert {:error, {:output_refused, %{missing_keys: [], rejected_keys: ["admin_email"]}}} =
             Engine.complete_task(
               task.id,
               complete_attrs(%{"admin_email" => "attacker@evil.com"}),
               prefix: schema_name
             )

    assert variables_of(schema_name, instance_id) == %{
             "admin_email" => "real-admin@example.com",
             "tenant_name" => "Acme"
           }

    # The task is still open: the completion was refused, not applied.
    assert EngineTask
           |> where([t], t.instance_id == ^instance_id and t.node_id == "task_a")
           |> Repo.one!(prefix: schema_name)
           |> Map.fetch!(:status) == :pending
  end

  test "NT-3 a completion WITHOUT the notification's read key is not refused" do
    %{schema_name: schema_name} = provisioned_tenant()
    definition = active_definition!(schema_name)

    instance_id =
      start_instance!(schema_name, definition, %{
        "admin_email" => "real-admin@example.com",
        "tenant_name" => "Acme"
      })

    task = find_task(schema_name, instance_id, "task_a")

    assert {:ok, _result} =
             Engine.complete_task(
               task.id,
               complete_attrs(%{"note" => "done"}),
               prefix: schema_name
             )

    assert variables_of(schema_name, instance_id)["admin_email"] == "real-admin@example.com"
    assert variables_of(schema_name, instance_id)["note"] == "done"
  end
end
