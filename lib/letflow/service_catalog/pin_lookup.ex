defmodule Letflow.ServiceCatalog.PinLookup do
  @moduledoc """
  REQ-373 (design `lib/letflow/design/req373-service-catalog-version-lifecycle.md`
  §5) -- the first REAL (non-`default_lookup/0`) `Letflow.Engine.PinResolver.Lookup`
  implementation. Wired into `Letflow.Engine.create/2`'s `pin_lookup/2` helper
  (§6) in place of `PinResolver.default_lookup/0`.

  **`catalog_entry` resolution only.** `module_lookup` stays a permanent
  `{:error, :not_found}` stub -- PLC-01 (the process module catalog) does
  not exist in this codebase and is unscoped to any stage, exactly the gap
  `Letflow.Engine.PinResolver`'s own moduledoc names under its "SCOPE GAP —
  service_catalog (S6) and PLC-01 (unscoped) are not built" section. This
  module closes the `service_catalog` half of that gap only; the PLC-01 half
  remains open, not silently expanded into this requirement's scope.

  **START-time only.** This lookup answers "what is the current ACTIVE
  version of this service today, as visible to THIS tenant" (refuses RETIRED).
  Tenant-scoped since ISS-0922: a `:tenant`-scoped service owned by another
  tenant is `{:error, :not_found}`, identical to a missing service. It is NOT
  used for SERVICE_TASK dispatch: since ISS-0917, `Letflow.Engine` resolves
  an instance's PINNED version at activation through
  `Letflow.ServiceCatalog.resolve_pinned_version/3`.

  Not folded into `Letflow.ServiceCatalog` itself (unlike
  `scope_validator_lookup/1`) because `build/0`'s shape needs to compose
  with `PinResolver.default_lookup/0`'s own `variable_schema_lookup` rather
  than reimplement it -- see `build/0` below.
  """

  alias Letflow.Engine.PinResolver
  alias Letflow.ServiceCatalog
  alias Letflow.ServiceCatalog.Entry

  @doc """
  Constructs a tenant-scoped `PinResolver.Lookup.t()` whose `module_lookup`/
  `variable_schema_lookup` fields are copied verbatim from
  `PinResolver.default_lookup/0`'s own result (guaranteeing byte-identical
  behavior for both, with zero risk of drift between the two
  implementations) and whose `catalog_lookup` field is this module's own
  `catalog_lookup/2` closed over `tenant_id`. Performs no `Repo` call itself -- only constructs
  closures; all I/O happens when `PinResolver.resolve/4` later invokes one.
  """
  @spec build(tenant_id :: Ecto.UUID.t()) :: PinResolver.Lookup.t()
  def build(tenant_id) when is_binary(tenant_id) do
    %{PinResolver.default_lookup() | catalog_lookup: &catalog_lookup(&1, tenant_id)}
  end

  @doc """
  `build/1` plus the script registry's `script_lookup` closure for the tenant schema `prefix`
  (GH 2534 PR 7c-1). The one place the default pin lookup of an instance is assembled: used by
  `Letflow.Engine.create/2` and by a sub-process child's own pin resolution (GH #2694).
  """
  @spec build(tenant_id :: Ecto.UUID.t(), prefix :: String.t()) :: PinResolver.Lookup.t()
  def build(tenant_id, prefix) when is_binary(prefix) do
    %{build(tenant_id) | script_lookup: Letflow.Scripts.Runtime.pin_lookup(prefix)}
  end

  @doc """
  Resolves a `SERVICE_TASK` node's `service_id` attribute against the
  versioned `service_catalog` table.

    * no row at all -> `{:error, :not_found}` (identical to
      `default_lookup/0`'s permanent stub answer -- a definition referencing
      a `service_id` nobody ever registered behaves exactly as before this
      module existed).
    * row with `status: :ACTIVE` -> `{:ok, %{resolved_id: version_id,
      version: version}}`.
    * row with `status: :RETIRED` -> `{:error, :not_found}` -- the design's
      explicit AC4 "retire fails outright" decision
      (`Letflow.ServiceCatalog.retire/1`'s own `@doc`), implemented at the
      one place `PinResolver.resolve/4` actually calls into.
  """
  @spec catalog_lookup(service_id :: String.t(), tenant_id :: Ecto.UUID.t()) ::
          {:ok, %{resolved_id: String.t(), version: String.t()}} | {:error, :not_found}
  def catalog_lookup(service_id, tenant_id) when is_binary(service_id) and is_binary(tenant_id) do
    # Same SVC-01 visibility rule as resolve_pinned_version/3 (ISS-0922):
    # invisible and missing are the identical {:error, :not_found}.
    case ServiceCatalog.get_for_tenant(service_id, tenant_id) do
      {:ok, %Entry{status: :ACTIVE, version_id: version_id, version: version}} ->
        {:ok, %{resolved_id: version_id, version: version}}

      {:ok, %Entry{status: :RETIRED}} ->
        {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end
end
