defmodule Letflow.CatalogItemsFixture do
  @moduledoc """
  Shared fixtures for the catalog_items behaviour and read API tests (GH #2664 / REQ-507).

  `installed_tenant!/1` provisions a real tenant, seeds its event types and installs the real
  `catalog_items` module through the real `Letflow.Routers.TenantModules`. The owner writers go
  through `Letflow.Entities.Records` with
  `ManagedTypes.owner_for!(Letflow.Modules.CatalogItems)`, exactly as the module's own code will
  (the module ships no write functions in this slice).

  This is a `.exs` under `test/letflow/modules/catalog_items/`, NOT a `test/support/**/*.ex`
  file: the R1/R2 caller guard in `managed_types_callers_test.exs` scans `test/support/**/*.ex`
  and rejects `owner_for!(CatalogItems)` outside `lib/letflow/modules/catalog_items`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]
  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Records
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @install_opts Letflow.Routers.TenantModules.init([])

  @doc "A provisioned tenant with `catalog_items` installed: `%{tenant_id: _, schema: _}`."
  @spec installed_tenant!(String.t()) :: %{tenant_id: String.t(), schema: String.t()}
  def installed_tenant!(slug_prefix) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.tenant_id))
    end)

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)

    conn =
      Plug.Test.conn(:post, "/")
      |> Map.put(:body_params, %{
        "module_id" => "catalog_items",
        "rationale" => "GH-2664 test install"
      })
      |> put_req_header("content-type", "application/json")
      |> assign(:auth_context, %{
        user_id: Ecto.UUID.generate(),
        tenant_id: tenant.tenant_id,
        roles: ["TENANT_ADMIN"]
      })
      |> assign(:trace_id, "gh2664-catalog-items-fixture-trace")
      |> Letflow.Routers.TenantModules.call(@install_opts)

    if conn.status != 201,
      do: raise("catalog_items install failed: #{conn.status} #{conn.resp_body}")

    %{tenant_id: tenant.tenant_id, schema: tenant.schema_name}
  end

  @doc "The Owner authority of the catalog_items module."
  def owner, do: ManagedTypes.owner_for!(Letflow.Modules.CatalogItems)

  @doc "Owner-path create with a fresh actor and idempotency key."
  def create(schema, type, field_values) do
    create(schema, type, field_values, Ecto.UUID.generate())
  end

  @doc "Owner-path create with a fresh actor and an explicit idempotency key."
  def create(schema, type, field_values, key) do
    Records.create_record(
      %{
        entity_type: type,
        field_values: field_values,
        actor_id: Ecto.UUID.generate(),
        idempotency_key: key
      },
      schema,
      owner()
    )
  end

  @doc "Owner-path create that must succeed; returns the stored `Latest` row."
  def create!(schema, type, field_values) do
    {:ok, %{record: record}} = create(schema, type, field_values)
    record
  end

  @doc "Owner-path soft delete that must succeed."
  def delete!(schema, record) do
    {:ok, _} =
      Records.delete_record(
        %{
          entity_type: record.entity_type,
          record_id: record.record_id,
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
        },
        schema,
        owner()
      )

    :ok
  end

  @doc "An active unit of measure (owner path) with `code`; `extra` overrides fields."
  def uom!(schema, code, extra \\ %{}) do
    create!(schema, "catalog_uom", values("catalog_uom", code, extra))
  end

  @doc "A catalog_item (owner path) whose base unit is `base_uom_id`; `extra` overrides fields."
  def item!(schema, code, base_uom_id, extra \\ %{}) do
    create!(
      schema,
      "catalog_item",
      values("catalog_item", code, Map.merge(%{"base_uom_id" => base_uom_id}, extra))
    )
  end

  @doc "Valid field values for `type` and `code`; `extra` overrides or adds."
  def values("catalog_uom", code, extra) do
    Map.merge(%{"code" => code, "name" => "UoM #{code}", "active" => true}, extra)
  end

  def values("catalog_item", code, extra) do
    Map.merge(
      %{
        "code" => code,
        "name" => "Item #{code}",
        "base_uom_id" => "uom-1",
        "kind" => "material",
        "active" => true
      },
      extra
    )
  end
end
