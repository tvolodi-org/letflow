defmodule Letflow.Entities.ReferenceCheck do
  @moduledoc """
  Module references by record id on tenant-owned record types (REQ-636, decision 0070 slice C,
  GH #3556).

  A string field of a tenant-owned record type may declare
  `"reference" => %{"module_id" => m, "entity_type" => t}` in its definition. A write that carries
  a non-empty value in such a field is stored only when the value names a live, active record of
  type `t` of module `m` in the caller's tenant, and `m` is installed there and opted `t` in with
  the manifest key `:reference_targets` (`Letflow.Modules.Catalog` rule 19).

  The target is read only through the module's public `lookup/2` and `active?/2`
  (`Catalog.reference_target/2` resolves the entry module); this file never touches a module table
  or schema (decision 0050 D8). The tenant is the `prefix` the caller passes, always the
  authenticated tenant's schema, never a request value (INV-1, INV-10).

  Every failure (dangling id, retired target, another tenant's record, another type, not a uuid,
  module not installed or not opted in) is the same value, so a caller learns nothing about which
  one it was (INV-5). A module-managed type is skipped: its owner validates its own references
  (decision 0050 D3.5). The check refuses nothing it does not understand and never raises on the
  shape of `field_values` (INV-8). Existing stored values are never rechecked; only a write is.

  Called by the record create/update routes, import create and upsert, process-step writes and
  module write handlers, after their access decision and before the store.
  """

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs
  alias Letflow.Api.Validation.FieldError

  @type result :: :ok | {:error, {:reference_invalid, [String.t()]}}

  @doc """
  `:ok`, or `{:error, {:reference_invalid, field_names}}` with the failing field names in
  definition order.
  """
  @spec check(entity_type :: term(), field_values :: term(), prefix :: term()) :: result()
  def check(entity_type, field_values, prefix)
      when is_binary(entity_type) and is_map(field_values) and is_binary(prefix) do
    case ManagedTypes.owner_of(entity_type, prefix) do
      :unmanaged -> check_unmanaged(entity_type, field_values, prefix)
      _managed_or_error -> :ok
    end
  end

  def check(_entity_type, _field_values, _prefix), do: :ok

  @doc "The 422 field errors for the names of a `:reference_invalid` refusal. Constant text."
  @spec field_errors([String.t()]) :: [FieldError.t()]
  def field_errors(names) do
    Enum.map(names, fn name ->
      %FieldError{
        field: name,
        constraint: "reference",
        message: "must refer to an available record"
      }
    end)
  end

  defp check_unmanaged(entity_type, field_values, prefix) do
    case Definitions.get_active_definition_by_name(entity_type, prefix) do
      {:ok, %EntityDefinition{definition_json: %{"fields" => fields}}} when is_list(fields) ->
        fields
        |> Enum.flat_map(&reference_field/1)
        |> Enum.reject(fn {name, _target} -> empty?(Map.get(field_values, name)) end)
        |> Enum.reject(fn {name, target} ->
          valid?(target, Map.get(field_values, name), prefix)
        end)
        |> Enum.map(fn {name, _target} -> name end)
        |> case do
          [] -> :ok
          names -> {:error, {:reference_invalid, names}}
        end

      _ ->
        :ok
    end
  end

  defp reference_field(%{"name" => name, "reference" => %{"module_id" => m, "entity_type" => t}})
       when is_binary(name) and is_binary(m) and is_binary(t),
       do: [{name, {m, t}}]

  defp reference_field(_field), do: []

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?(_value), do: false

  defp valid?({module_id, type}, value, prefix) when is_binary(value) do
    with {:ok, entry} <- Catalog.reference_target(module_id, type),
         true <- Installs.installed?(module_id, prefix: prefix),
         {:ok, %{"entity_type" => ^type}} <- entry.lookup(prefix, value) do
      entry.active?(prefix, value) == true
    else
      _ -> false
    end
  end

  defp valid?(_target, _value, _prefix), do: false
end
