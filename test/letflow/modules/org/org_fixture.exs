defmodule Letflow.OrgFixture do
  @moduledoc """
  Shared fixtures for the org behaviour and read API tests (GH #2662 / REQ-506).

  `installed_tenant!/1` provisions a real tenant, seeds its event types and installs the real
  `org` module through the real `Letflow.Routers.TenantModules`. The owner writers go through
  `Letflow.Entities.Records` with `ManagedTypes.owner_for!(Letflow.Modules.Org)`, exactly as the
  module's own code will (the module ships no write functions in this slice).
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

  @doc "A provisioned tenant with `org` installed: `%{tenant_id: _, schema: _}`."
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
      |> Map.put(:body_params, %{"module_id" => "org", "rationale" => "GH-2662 test install"})
      |> put_req_header("content-type", "application/json")
      |> assign(:auth_context, %{
        user_id: Ecto.UUID.generate(),
        tenant_id: tenant.tenant_id,
        roles: ["TENANT_ADMIN"]
      })
      |> assign(:trace_id, "gh2662-org-fixture-trace")
      |> Letflow.Routers.TenantModules.call(@install_opts)

    if conn.status != 201, do: raise("org install failed: #{conn.status} #{conn.resp_body}")

    %{tenant_id: tenant.tenant_id, schema: tenant.schema_name}
  end

  @doc "The Owner authority of the org module."
  def owner, do: ManagedTypes.owner_for!(Letflow.Modules.Org)

  @doc "Owner-path create with a fresh idempotency key."
  def create(schema, type, field_values) do
    create(schema, type, field_values, Ecto.UUID.generate())
  end

  @doc "Owner-path create with an explicit idempotency key."
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

  @doc "Valid field values for `type` and `code`."
  def values(type, code), do: values(type, code, %{})

  @doc "Valid field values for `type` and `code`; `extra` overrides or adds."
  def values("org_legal_entity", code, extra) do
    Map.merge(
      %{"code" => code, "name" => "LE #{code}", "bin" => "123456789012", "active" => true},
      extra
    )
  end

  def values("org_site", code, extra) do
    Map.merge(
      %{"code" => code, "name" => "Site #{code}", "legal_entity_id" => "le-1", "active" => true},
      extra
    )
  end

  def values("org_unit", code, extra) do
    Map.merge(
      %{
        "code" => code,
        "name" => "Unit #{code}",
        "legal_entity_id" => "le-1",
        "site_id" => "site-1",
        "active" => true
      },
      extra
    )
  end

  def values("org_unit_membership", _code, extra) do
    Map.merge(%{"user_id" => "user-1", "org_unit_id" => "unit-1", "active" => true}, extra)
  end
end
