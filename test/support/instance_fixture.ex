defmodule Letflow.TestSupport.InstanceFixture do
  @moduledoc """
  Shared "real instance for a tenant" fixture (GH #2718, design O8).

  The `/instances/:id/attachments...` routes answer an unknown or synthetic instance
  id with the Instances 404, so a route test that wants to reach the attachment logic
  needs an instance whose `instance_projections` row really exists in the tenant
  schema. `real_instance!/1` starts one through `Letflow.Engine.create/2` from a
  freshly activated one-task definition (a HUMAN_TASK keeps it ACTIVE).

  Takes anything with a `:schema_name` (the `TenantFixture.provisioned_tenant!/1` map)
  or the schema name itself. Test-only; compiled under `elixirc_paths(:test)`.
  """

  alias Letflow.Definitions
  alias Letflow.Engine

  @doc "Creates an active definition and one running instance; returns the instance id."
  @spec real_instance!(%{schema_name: String.t()} | String.t()) :: Ecto.UUID.t()
  def real_instance!(%{schema_name: schema_name}), do: real_instance!(schema_name)

  def real_instance!(schema_name) when is_binary(schema_name) do
    {:ok, definition} =
      Definitions.create(
        %{
          name: "gh2718-def-" <> to_string(System.unique_integer([:positive])),
          version: "1.0.0",
          graph: graph(),
          created_by: Ecto.UUID.generate()
        },
        prefix: schema_name
      )

    {:ok, %{definition: activated}} = Definitions.activate(definition.id, prefix: schema_name)

    {:ok, result} =
      Engine.create(
        %{
          definition_id: activated.id,
          initial_variables: %{},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: "gh2718-start-" <> to_string(System.unique_integer([:positive]))
        },
        prefix: schema_name
      )

    result.instance_id
  end

  defp graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end
end
