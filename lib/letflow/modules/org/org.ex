defmodule Letflow.Modules.Org do
  @moduledoc """
  Foundation module `org` (GH #2661 / REQ-473, WMS foundation slice 0; decisions 0050 D1, 0052,
  0054 option A, 0057 D1): the shared organisation masters.

  Four entity types, shipped by the pack `priv/modules/org/pack.json` (generated from
  `priv/modules/org/entity_definitions/` by `priv/modules/org/generate_pack.exs`):

    * `org_legal_entity`, `org_site`, `org_unit` (a tree through the `parent` id string): the
      masters, each with a unique `code` and the nullable `external_ref_system` /
      `external_ref_id` import key (0057 D1);
    * `org_unit_membership`: a Letflow user id (text) in an org unit, unique per pair.

  All four are declared in `manages_entity_types`, so after install the generic entity routes
  answer 403 `entity_type_managed`. This skeleton ships no routes, no permissions, no role
  grants and no write functions: the unit functions (create, move, retire) are REQ-495 and the
  read API is REQ-506. References between the types are declarative strings (0050 D3.6), no
  foreign keys.

  `on_install/3` activates and promotes the four packed definitions inside the install
  transaction (decision 0052 D2) through `Letflow.Modules.EntityActivation`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  import Ecto.Query, only: [from: 2, limit: 2]

  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.EntityActivation
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  # Must stay equal to `manages_entity_types` in the manifest below (defmanifest takes literals).
  @types [
    "org_legal_entity",
    "org_site",
    "org_unit",
    "org_unit_membership"
  ]

  @membership "org_unit_membership"
  @unit "org_unit"

  @impl true
  defmanifest(
    id: "org",
    version: "0.1.0",
    depends_on: [],
    pack: "modules/org/pack.json",
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [],
    manages_entity_types: [
      "org_legal_entity",
      "org_site",
      "org_unit",
      "org_unit_membership"
    ]
  )

  @impl true
  def on_install(prefix, _settings, ctx) do
    EntityActivation.activate_and_promote(prefix, ctx, @types)
  end

  @doc """
  Read API (GH #2662 / REQ-506, decision 0050 D2): the live record `id` (a `record_id` uuid) in
  tenant schema `prefix`, searched across the four org types.

  The map has string keys: `"record_id"`, `"entity_type"` (the type name) and every stored field
  value. A value that is not a uuid, an unknown uuid and a soft-deleted record are all
  `{:error, :not_found}` (never a raise, never distinguishable). Read-only and tenant-scoped by
  `prefix` alone.
  """
  @spec lookup(prefix :: String.t(), id :: term()) :: {:ok, map()} | {:error, :not_found}
  def lookup(prefix, id) when is_binary(prefix) do
    with {:ok, record_id} <- Ecto.UUID.cast(id),
         {:ok, row} <- first_live(prefix, record_id, @types) do
      {:ok, to_map(row)}
    else
      _ -> {:error, :not_found}
    end
  end

  def lookup(_prefix, _id), do: {:error, :not_found}

  @doc """
  True only for an existing, non-deleted record (any of the four types) whose `active` field is
  `true`. A non-uuid `id` is `false`.
  """
  @spec active?(prefix :: String.t(), id :: term()) :: boolean()
  def active?(prefix, id) do
    match?({:ok, %{"active" => true}}, lookup(prefix, id))
  end

  @doc """
  True only when `user_id` has an active `org_unit_membership` in `org_unit_id` and that
  `org_unit` is itself live and active. `org_unit_id` is a record_id uuid; a non-uuid value or a
  non-text `user_id` is `false`.
  """
  @spec member?(prefix :: String.t(), user_id :: term(), org_unit_id :: term()) :: boolean()
  def member?(prefix, user_id, org_unit_id)
      when is_binary(prefix) and is_binary(user_id) do
    with {:ok, unit_id} <- Ecto.UUID.cast(org_unit_id),
         {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, %{"active" => true}} <- unit_by_id(prefix, unit_id) do
      active_membership?(prefix, user_id, unit_id)
    else
      _ -> false
    end
  end

  def member?(_prefix, _user_id, _org_unit_id), do: false

  defp unit_by_id(prefix, unit_id) do
    case Latest.get_live(unit_id, @unit, prefix) do
      {:ok, row} -> {:ok, row.field_values}
      error -> error
    end
  end

  defp active_membership?(prefix, user_id, unit_id) do
    query =
      from(r in Latest,
        where:
          r.entity_type == @membership and not r.deleted and
            fragment("?->>'user_id' = ?", r.field_values, ^user_id) and
            fragment("?->>'org_unit_id' = ?", r.field_values, ^unit_id) and
            fragment("?->>'active' = 'true'", r.field_values)
      )

    Repo.exists?(limit(query, 1), prefix: prefix)
  end

  defp first_live(_prefix, _record_id, []), do: {:error, :not_found}

  defp first_live(prefix, record_id, [type | rest]) do
    case Latest.get_live(record_id, type, prefix) do
      {:ok, _row} = found -> found
      _ -> first_live(prefix, record_id, rest)
    end
  end

  defp to_map(%Latest{} = row) do
    Map.merge(row.field_values, %{"record_id" => row.record_id, "entity_type" => row.entity_type})
  end
end
