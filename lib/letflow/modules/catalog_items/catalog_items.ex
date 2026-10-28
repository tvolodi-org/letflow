defmodule Letflow.Modules.CatalogItems do
  @moduledoc """
  Foundation module `catalog_items` (GH #2663 / REQ-474, WMS foundation slice 0; decisions 0050
  D1, 0052, 0054 option A, 0057 D1): the shared item, unit-of-measure and supplier masters. The manifest
  id is `catalog_items` because `catalog` collides with `Letflow.Modules.Catalog`.

  Three entity types, shipped by the pack `priv/modules/catalog_items/pack.json` (generated from
  `priv/modules/catalog_items/entity_definitions/` by
  `priv/modules/catalog_items/generate_pack.exs`):

    * `catalog_uom`: a unit of measure, unique `code`;
    * `catalog_item`: an item, unique `code`, with a `base_uom_id` (the record id of a
      `catalog_uom`, a declarative string) and a `kind` enum (`material | service`);
    * `catalog_counterparty`: a supplier master (GH #3407 / REQ-604), unique `code`, a `kind` enum
      (`supplier | contractor`) and an optional `tax_id`; retired with `active` false, never deleted.

  All three carry the nullable `external_ref_system` / `external_ref_id` import key (0057 D1) with a
  unique constraint over the pair.

  All are declared in `manages_entity_types`, so after install the generic entity routes answer
  403 `entity_type_managed`. The module ships no routes, no permissions, no role grants and
  no write functions; the read API (REQ-507, GH #2664) is below. The unit scale and conversion factors
  are REQ-504 (#2660), not here. References between the types are declarative strings (0050
  D3.6), no foreign keys.

  ## Read API contract (GH #2664)

  `prefix` must be derived server-side from the authenticated tenant, never from HTTP input:
  isolation is by `prefix` alone, and a wrong prefix reads another tenant with no check. The
  never-raise guarantee holds for a provisioned tenant prefix; a well-formed but unprovisioned
  `tenant_<hex>` prefix raises `undefined_table` from Postgres (not caught).

  `on_install/3` activates and promotes the three packed definitions inside the install
  transaction (decision 0052 D2) through `Letflow.Modules.EntityActivation`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.EntityActivation
  alias Letflow.Modules.ReadApi

  # Must stay equal to `manages_entity_types` in the manifest below (defmanifest takes literals).
  @types [
    "catalog_uom",
    "catalog_item",
    "catalog_counterparty"
  ]

  @uom "catalog_uom"
  @item "catalog_item"

  @impl true
  defmanifest(
    id: "catalog_items",
    version: "0.1.0",
    depends_on: [],
    pack: "modules/catalog_items/pack.json",
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [],
    manages_entity_types: [
      "catalog_uom",
      "catalog_item",
      "catalog_counterparty"
    ]
  )

  @impl true
  def on_install(prefix, _settings, ctx) do
    EntityActivation.activate_and_promote(prefix, ctx, @types)
  end

  @doc """
  Read API (GH #2664 / REQ-507, decision 0050 D2): the live record `id` (a `record_id` uuid) in
  tenant schema `prefix`, searched across `catalog_uom`, `catalog_item` and `catalog_counterparty`; the caller checks `"entity_type"`.

  The map has string keys: `"record_id"`, `"entity_type"` (the type name) and every stored field
  value. A value that is not a uuid, an unknown uuid, a soft-deleted record and a non-text
  `prefix` are all `{:error, :not_found}` (never a raise, never distinguishable). Read-only and
  tenant-scoped by `prefix` alone.
  """
  @spec lookup(prefix :: String.t(), id :: term()) :: {:ok, map()} | {:error, :not_found}
  def lookup(prefix, id), do: ReadApi.lookup(prefix, id, @types)

  @doc """
  True only for an existing, non-deleted record (any of the three types) whose `active` field is `true`. A
  non-uuid `id` is `false`.
  """
  @spec active?(prefix :: String.t(), id :: term()) :: boolean()
  def active?(prefix, id) do
    ReadApi.active?(prefix, id, @types)
  end

  @doc """
  True only when `item_id` is a live, active `catalog_item`, `uom_id` is a live, active
  `catalog_uom`, and `uom_id` equals the item's `base_uom_id` (slice 1 allows only the base
  unit). Any non-uuid value, unknown or inactive item or unit is `false`, never a raise.
  `uom_id` is compared as canonical lowercase uuid text against the stored `base_uom_id`
  (exact text, like `Letflow.Modules.Org.member?/3`).
  """
  @spec item_uom_valid?(prefix :: String.t(), item_id :: term(), uom_id :: term()) :: boolean()
  def item_uom_valid?(prefix, item_id, uom_id) when is_binary(prefix) do
    with {:ok, item_uuid} <- Ecto.UUID.cast(item_id),
         {:ok, uom_uuid} <- Ecto.UUID.cast(uom_id),
         {:ok, %{"active" => true, "base_uom_id" => ^uom_uuid}} <-
           live_fields(prefix, item_uuid, @item),
         {:ok, %{"active" => true}} <- live_fields(prefix, uom_uuid, @uom) do
      true
    else
      _ -> false
    end
  end

  def item_uom_valid?(_prefix, _item_id, _uom_id), do: false

  defp live_fields(prefix, record_id, type) do
    case Latest.get_live(record_id, type, prefix) do
      {:ok, row} -> {:ok, row.field_values}
      error -> error
    end
  end
end
