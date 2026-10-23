defmodule Letflow.ManagedTypesSupport do
  @moduledoc """
  Test support (GH #2581): plants an UNMANAGED entity type whose name a module declares in
  `manages_entity_types`, the way a tenant squat that pre-dates the creation-time refusal
  looks in a deployed tenant. `Definitions.create_definition/2` refuses such a name now, so
  the install-side backstop (`managed_name_taken`) is tested with a row inserted directly,
  exactly like `Letflow.Entities.Definitions` does after its `ManagedTypes.check_create/3`.
  """

  alias Letflow.Entities.Definition.Shape
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Repo
  alias Letflow.Repository
  alias Letflow.TenantProvisioning

  @spec plant_legacy_squat!(schema :: String.t(), name :: String.t(), fields :: [map()]) ::
          EntityDefinition.t()
  def plant_legacy_squat!(
        schema,
        name,
        fields \\ [%{name: "name", type: :string, required: true}]
      ) do
    plant_legacy_definition!(schema, %{
      name: name,
      display_name: "legacy #{name}",
      fields: fields
    })
  end

  @doc "Like `plant_legacy_squat!/3`, from a complete definition map (`:name`, `:display_name`, ...)."
  @spec plant_legacy_definition!(schema :: String.t(), definition :: map()) ::
          EntityDefinition.t()
  def plant_legacy_definition!(schema, %{name: name} = definition) do
    {:ok, tenant_id} = TenantProvisioning.tenant_id_for_schema_name(schema)

    {:ok, %Repository.ArtifactVersion{version_id: version_id}} =
      Repository.create(
        %{
          artifact_kind: :entity,
          artifact_name: name,
          content_type: "application/json",
          content: Jason.encode!(definition),
          created_by: Ecto.UUID.generate()
        },
        schema
      )

    %EntityDefinition{}
    |> EntityDefinition.changeset(%{
      tenant_id: tenant_id,
      name: name,
      display_name: Map.fetch!(definition, :display_name),
      definition_json: definition,
      content_hash: Shape.content_hash(definition),
      logical_shape_version: Shape.logical_shape_of(definition),
      artifact_version_id: version_id,
      status: :inactive
    })
    |> EntityDefinition.put_write_class(legacy_write_class(name))
    |> Repo.insert!(prefix: schema)
  end

  # GH #2618: the class a legacy row gets from the migration backfill (`org_` names are `org_tree`,
  # every other name here is `ordinary`). Only the names these fixtures plant are covered.
  defp legacy_write_class("org_" <> _rest), do: "org_tree"
  defp legacy_write_class(_name), do: "ordinary"
end
