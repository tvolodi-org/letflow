defmodule Letflow.Entities.HiddenLabels do
  @moduledoc """
  The hidden-label loaders of decision 0062 R8: which `"entity_type.field_name"` labels a caller may
  not see in an instance variable's value (`Letflow.Engine.VariableLabels`).

  They read the same restriction tables as `Letflow.Entities.Query.FieldGrants`, but they are not
  part of the entity query pipeline, so they live here. The routers that redact instance variables
  call this module; `Letflow.Routers.Entities` remains the only router that runs the query pipeline
  (`Query.Cursor` and `Query.FieldGrants`).

  Both loaders are scoped to the tenant schema named by `prefix` (INV-1).
  """

  import Ecto.Query

  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @doc """
  The `"entity_type.field_name"` labels of every restricted field the user has no
  `user_entity_grants` row for, across all entity types. This is the hidden set that
  `Letflow.Engine.VariableLabels` takes: the same anti-join as `FieldGrants.load_restrictions/3`,
  unscoped by entity type.
  """
  @spec load_hidden_labels(user_id :: String.t(), prefix :: String.t()) ::
          {:ok, MapSet.t(String.t())} | {:error, :invalid_schema_name}
  def load_hidden_labels(user_id, prefix) when is_binary(user_id) and is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      query =
        from(fr in "entity_field_restrictions",
          left_join: g in "user_entity_grants",
          on:
            g.entity_type == fr.entity_type and
              g.field_name == fr.field_name and
              g.user_id == type(^user_id, Ecto.UUID),
          where: is_nil(g.id),
          select: {fr.entity_type, fr.field_name}
        )

      {:ok, label_set(Repo.all(query, prefix: prefix))}
    end
  end

  @doc """
  Every `entity_field_restrictions` row as a `"entity_type.field_name"` label. The platform principal
  holds no entity grants (decision 0062 R8), so its hidden set is the whole restriction table.
  """
  @spec load_platform_hidden_labels(prefix :: String.t()) ::
          {:ok, MapSet.t(String.t())} | {:error, :invalid_schema_name}
  def load_platform_hidden_labels(prefix) when is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      query = from(fr in "entity_field_restrictions", select: {fr.entity_type, fr.field_name})

      {:ok, label_set(Repo.all(query, prefix: prefix))}
    end
  end

  defp label_set(pairs) do
    MapSet.new(pairs, fn {entity_type, field_name} -> "#{entity_type}.#{field_name}" end)
  end
end
