defmodule Letflow.Modules.Locations do
  @moduledoc """
  Foundation module `locations` (GH #3501 / REQ-625, GH #3591 / REQ-645, GH #3586 / REQ-644;
  decisions 0050 D1, 0057 D1, 0066): the location master.

  Two entity types, `location_node` and `location_org_unit_link`, shipped by the pack `priv/modules/locations/pack.json` (generated
  from `priv/modules/locations/entity_definitions/` by `priv/modules/locations/generate_pack.exs`).
  The nodes form one tree through `parent_id`, the record id of the parent node, which is a real
  foreign key in the pack (nullable uuid, self-referencing, `ON DELETE RESTRICT`). `node_kind` is a
  free non-empty text per level (no fixed list) and the depth has no bound. Following decision 0066
  the tree is stored as the parent link only: no path and no depth is stored. An optional `segment`
  (never containing a dash) can compose the scannable `address` once, at create. `address` is unique
  per tenant when set; a location is retired with `active` false, never deleted. It carries the
  nullable `external_ref_system` / `external_ref_id` import key (0057 D1) with a unique pair.

  The type is declared in `manages_entity_types`, so after install the generic entity routes answer
  403 `entity_type_managed`. The module ships no routes, no permissions and no role grants. Its write
  functions are in `Letflow.Modules.Locations.Tree`: `create_node/3`, `move_node/4` (one parent change
  with a cycle walk; refusals `:node_not_found`, `:parent_not_found`, `:parent_inactive`, `:cycle`),
  `update_node/4` (name, kind, segment, address and the import key; `{:field_not_allowed, key}` for
  anything else), `retire_node/3` (`:has_active_descendants`; no un-retire, no delete). The read
  `descendant_ids/2` returns a subtree by one recursive query. The import of the tree (GH #3601 / REQ-652)
  is `import_row/3`, which writes only through the three functions above. All writes take the tenant tree lock
  first (GH #3588 / REQ-646). The type has the scope declaration `:tenant_wide` (decision 0051 M4); enforcement is
  REQ-519. Tenants that installed an older version keep the old definition (no module upgrade yet).

  ## Links to organization units (GH #3586 / REQ-644)

  `location_org_unit_link` is a many to many link: `location_id` (a real foreign key onto
  `location_node`, `ON DELETE RESTRICT`), `org_unit_id` (a record id of module `org`, no foreign key
  across packs) and `active`; the pair is unique. The manifest depends on `org` and declares the link
  scope `{:column, "org_unit_id"}`. The writers are in `Letflow.Modules.Locations.Links` (GH #3616 / REQ-662): `link_unit_location/4` and
  `unlink_unit_location/4`, one transaction and one audit entry each. Linking refuses an unknown, soft-deleted or
  retired unit or location (`:unit_not_found`, `:unit_inactive`, `:location_not_found`, `:location_inactive`);
  a pair with an inactive link is reactivated on the same record; unlinking sets `active` false, never deletes,
  and works when an end is retired. Unlinking checks no stock (no ledger code exists yet). Three reads, all by `prefix` alone:
  `linked?/3` (the movement rule: true only when a live active link joins an active org unit and an
  active location), `location_ids_for_org_unit/2` and `org_unit_ids_for_location/2` (sorted, unique,
  only active ends of live active links). `lookup/2` and `active?/2` answer for `location_node` only.

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

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.EntityActivation
  alias Letflow.Modules.Org
  alias Letflow.Modules.ReadApi
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @node ["location_node"]
  @link "location_org_unit_link"

  # Must stay equal to `manages_entity_types` in the manifest below (defmanifest takes literals).
  @types ["location_node", "location_org_unit_link"]

  @impl true
  defmanifest(
    id: "locations",
    version: "0.3.0",
    depends_on: ["org"],
    pack: "modules/locations/pack.json",
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [],
    manages_entity_types: ["location_node", "location_org_unit_link"],
    scope_declarations: %{
      "location_node" => :tenant_wide,
      "location_org_unit_link" => {:column, "org_unit_id"}
    },
    import_functions: [%{entity_type: "location_node", function: :import_row}]
  )

  @impl true
  def on_install(prefix, _settings, ctx) do
    EntityActivation.activate_and_promote(prefix, ctx, @types)
  end

  @doc """
  The import function of `location_node` (GH #3601 / REQ-652, manifest `:import_functions`): one row
  of a file, called by the core import route. See `Letflow.Modules.Locations.Import`.
  """
  @spec import_row(prefix :: String.t(), entry :: map(), ctx :: map()) ::
          {:ok, map()} | {:error, term()}
  def import_row(prefix, entry, ctx),
    do: Letflow.Modules.Locations.Import.row(prefix, entry, ctx)

  @doc "Creates a location node; see `Letflow.Modules.Locations.Tree.create_node/3`."
  defdelegate create_node(prefix, attrs, opts), to: Letflow.Modules.Locations.Tree

  @doc "Moves a node; see `Letflow.Modules.Locations.Tree.move_node/4`."
  defdelegate move_node(prefix, node_id, new_parent_id, opts), to: Letflow.Modules.Locations.Tree

  @doc "Updates a node; see `Letflow.Modules.Locations.Tree.update_node/4`."
  defdelegate update_node(prefix, node_id, attrs, opts), to: Letflow.Modules.Locations.Tree

  @doc "Retires a node; see `Letflow.Modules.Locations.Tree.retire_node/3`."
  defdelegate retire_node(prefix, node_id, opts), to: Letflow.Modules.Locations.Tree

  @doc "Links an org unit to a location; see `Letflow.Modules.Locations.Links.link_unit_location/4`."
  defdelegate link_unit_location(prefix, org_unit_id, location_id, opts),
    to: Letflow.Modules.Locations.Links

  @doc "Unlinks an org unit from a location; see `Letflow.Modules.Locations.Links.unlink_unit_location/4`."
  defdelegate unlink_unit_location(prefix, org_unit_id, location_id, opts),
    to: Letflow.Modules.Locations.Links

  @doc "Live descendant ids of a node; see `Letflow.Modules.Locations.Tree.descendant_ids/2`."
  defdelegate descendant_ids(prefix, node_id), to: Letflow.Modules.Locations.Tree

  @doc """
  Read API (GH #3501 / REQ-625, decision 0050 D2): the live `location_node` with record `id` (a
  `record_id` uuid) in tenant schema `prefix`.

  The map has string keys: `"record_id"`, `"entity_type"` (`"location_node"`) and every stored field
  value. A value that is not a uuid, an unknown uuid, a soft-deleted record, the id of a record of
  another type and a non-text `prefix` are all `{:error, :not_found}` (never a raise, never
  distinguishable). Read-only and tenant-scoped by `prefix` alone.
  """
  @spec lookup(prefix :: String.t(), id :: term()) :: {:ok, map()} | {:error, :not_found}
  def lookup(prefix, id), do: ReadApi.lookup(prefix, id, @node)

  @doc """
  True only for an existing, non-deleted `location_node` whose `active` field is `true`. A non-uuid
  `id` is `false`.
  """
  @spec active?(prefix :: String.t(), id :: term()) :: boolean()
  def active?(prefix, id), do: ReadApi.active?(prefix, id, @node)

  @doc """
  True only when a live, active `location_org_unit_link` joins `org_unit_id` and `location_id`, the
  org unit is a live active `org_unit` (an `org_site` id is `false`) and the location is an active
  `location_node`. A value that is not a uuid, an unknown prefix or a non-text prefix is `false`.
  """
  @spec linked?(prefix :: String.t(), org_unit_id :: term(), location_id :: term()) :: boolean()
  def linked?(prefix, org_unit_id, location_id) do
    with {:ok, unit} <- cast(org_unit_id),
         {:ok, loc} <- cast(location_id),
         true <- tenant?(prefix),
         true <- active?(prefix, loc),
         true <- unit_active?(prefix, unit) do
      link_values(prefix, "org_unit_id", unit, "location_id", loc) != []
    else
      _ -> false
    end
  end

  @doc """
  Ids of the active locations linked, by a live active link, to the active org unit `org_unit_id`,
  sorted ascending. `[]` for anything that is not an active org unit of the tenant.
  """
  @spec location_ids_for_org_unit(prefix :: String.t(), org_unit_id :: term()) :: [String.t()]
  def location_ids_for_org_unit(prefix, org_unit_id) do
    with {:ok, unit} <- cast(org_unit_id),
         true <- tenant?(prefix),
         true <- unit_active?(prefix, unit) do
      prefix
      |> link_values("org_unit_id", unit, nil, nil)
      |> Enum.map(& &1["location_id"])
      |> Enum.uniq()
      |> Enum.filter(&active?(prefix, &1))
      |> Enum.sort()
    else
      _ -> []
    end
  end

  @doc """
  Ids of the active org units linked, by a live active link, to the active location `location_id`,
  sorted ascending. `[]` for anything that is not an active location of the tenant.
  """
  @spec org_unit_ids_for_location(prefix :: String.t(), location_id :: term()) :: [String.t()]
  def org_unit_ids_for_location(prefix, location_id) do
    with {:ok, loc} <- cast(location_id),
         true <- tenant?(prefix),
         true <- active?(prefix, loc) do
      prefix
      |> link_values("location_id", loc, nil, nil)
      |> Enum.map(& &1["org_unit_id"])
      |> Enum.uniq()
      |> Enum.filter(&unit_active?(prefix, &1))
      |> Enum.sort()
    else
      _ -> []
    end
  end

  defp cast(id) when is_binary(id), do: Ecto.UUID.cast(id)
  defp cast(_), do: :error

  defp tenant?(prefix) when is_binary(prefix),
    do: match?({:ok, _}, TenantProvisioning.tenant_id_for_schema_name(prefix))

  defp tenant?(_), do: false

  defp unit_active?(prefix, unit_id) do
    match?(
      {:ok, %{"entity_type" => "org_unit", "active" => true}},
      Org.lookup(prefix, unit_id)
    )
  end

  # Field maps of the live active links whose `key1` equals `val1` (and `key2` equals `val2` when
  # given). Keys are fixed literals; values are bound parameters (INV-7).
  defp link_values(prefix, key1, val1, key2, val2) do
    query =
      from(r in Latest,
        where:
          r.entity_type == ^@link and not r.deleted and
            fragment("?->>'active' = 'true'", r.field_values) and
            fragment("?->>? = ?", r.field_values, ^key1, ^val1),
        select: r.field_values
      )

    query =
      if key2 do
        from(r in query, where: fragment("?->>? = ?", r.field_values, ^key2, ^val2))
      else
        query
      end

    Repo.all(query, prefix: prefix)
  end
end
