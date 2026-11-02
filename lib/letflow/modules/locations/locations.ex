defmodule Letflow.Modules.Locations do
  @moduledoc """
  Foundation module `locations` (GH #3501 / REQ-625, GH #3591 / REQ-645; decisions 0050 D1, 0057 D1,
  0066): the location master.

  One entity type, `location_node`, shipped by the pack `priv/modules/locations/pack.json` (generated
  from `priv/modules/locations/entity_definitions/` by `priv/modules/locations/generate_pack.exs`).
  The nodes form one tree through `parent_id`, the record id of the parent node, which is a real
  foreign key in the pack (nullable uuid, self-referencing, `ON DELETE RESTRICT`). `node_kind` is a
  free non-empty text per level (no fixed list) and the depth has no bound. Following decision 0066
  the tree is stored as the parent link only: no path and no depth is stored. An optional `segment`
  (never containing a dash) can compose the scannable `address` once, at create. `address` is unique
  per tenant when set; a location is retired with `active` false, never deleted. It carries the
  nullable `external_ref_system` / `external_ref_id` import key (0057 D1) with a unique pair.

  The type is declared in `manages_entity_types`, so after install the generic entity routes answer
  403 `entity_type_managed`. The module ships no routes, no permissions and no role grants. It has one
  write function, `create_node/3` (`Letflow.Modules.Locations.Tree`); move, update and retire are
  REQ-646. The type has the scope declaration `:tenant_wide` (decision 0051 M4); enforcement is
  REQ-519. Tenants that installed version 0.1.0 keep the old definition (no module upgrade yet).

  ## Read API contract (GH #2664)

  `prefix` must be derived server-side from the authenticated tenant, never from HTTP input:
  isolation is by `prefix` alone, and a wrong prefix reads another tenant with no check. The
  never-raise guarantee holds for a provisioned tenant prefix; a well-formed but unprovisioned
  `tenant_<hex>` prefix raises `undefined_table` from Postgres (not caught).

  `on_install/3` activates and promotes the packed definition inside the install transaction
  (decision 0052 D2) through `Letflow.Modules.EntityActivation`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  alias Letflow.Modules.EntityActivation
  alias Letflow.Modules.ReadApi

  # Must stay equal to `manages_entity_types` in the manifest below (defmanifest takes literals).
  @types ["location_node"]

  @impl true
  defmanifest(
    id: "locations",
    version: "0.2.0",
    depends_on: [],
    pack: "modules/locations/pack.json",
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [],
    manages_entity_types: ["location_node"],
    scope_declarations: %{"location_node" => :tenant_wide}
  )

  @impl true
  def on_install(prefix, _settings, ctx) do
    EntityActivation.activate_and_promote(prefix, ctx, @types)
  end

  @doc "Creates a location node; see `Letflow.Modules.Locations.Tree.create_node/3`."
  defdelegate create_node(prefix, attrs, opts), to: Letflow.Modules.Locations.Tree

  @doc """
  Read API (GH #3501 / REQ-625, decision 0050 D2): the live `location_node` with record `id` (a
  `record_id` uuid) in tenant schema `prefix`.

  The map has string keys: `"record_id"`, `"entity_type"` (`"location_node"`) and every stored field
  value. A value that is not a uuid, an unknown uuid, a soft-deleted record, the id of a record of
  another type and a non-text `prefix` are all `{:error, :not_found}` (never a raise, never
  distinguishable). Read-only and tenant-scoped by `prefix` alone.
  """
  @spec lookup(prefix :: String.t(), id :: term()) :: {:ok, map()} | {:error, :not_found}
  def lookup(prefix, id), do: ReadApi.lookup(prefix, id, @types)

  @doc """
  True only for an existing, non-deleted `location_node` whose `active` field is `true`. A non-uuid
  `id` is `false`.
  """
  @spec active?(prefix :: String.t(), id :: term()) :: boolean()
  def active?(prefix, id), do: ReadApi.active?(prefix, id, @types)
end
