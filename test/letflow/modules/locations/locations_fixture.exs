defmodule Letflow.LocationsFixture do
  @moduledoc """
  Shared fixtures for the locations behaviour and read API tests (GH #3501 / REQ-625).

  `installed_tenant!/1` provisions a real tenant, seeds its event types and installs the real
  `locations` module through the real `Letflow.Routers.TenantModules`. The owner writers go
  through `Letflow.Entities.Records` with
  `ManagedTypes.owner_for!(Letflow.Modules.Locations)`, exactly as the module's own code will
  (the module ships no write functions in this slice).

  This is a `.exs` under `test/letflow/modules/locations/`, NOT a `test/support/**/*.ex`
  file: the R1/R2 caller guard in `managed_types_callers_test.exs` scans `test/support/**/*.ex`
  and rejects `owner_for!(Locations)` outside `lib/letflow/modules/locations`.
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

  @doc "A provisioned tenant with `locations` installed: `%{tenant_id: _, schema: _}`."
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

    install_locations!(tenant.tenant_id)

    %{tenant_id: tenant.tenant_id, schema: tenant.schema_name}
  end

  @doc "Installs `locations` in the tenant through the real router as TENANT_ADMIN; raises unless 201."
  def install_locations!(tenant_id) do
    conn =
      Plug.Test.conn(:post, "/")
      |> Map.put(:body_params, %{
        "module_id" => "locations",
        "rationale" => "GH-3501 test install"
      })
      |> put_req_header("content-type", "application/json")
      |> assign(:auth_context, %{
        user_id: Ecto.UUID.generate(),
        tenant_id: tenant_id,
        roles: ["TENANT_ADMIN"]
      })
      |> assign(:trace_id, "gh3501-locations-fixture-trace")
      |> Letflow.Routers.TenantModules.call(@install_opts)

    if conn.status != 201,
      do: raise("locations install failed: #{conn.status} #{conn.resp_body}")

    :ok
  end

  @doc "The Owner authority of the locations module."
  def owner, do: ManagedTypes.owner_for!(Letflow.Modules.Locations)

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

  @doc "An owner-path location_node with `code` and `node_kind`; `extra` overrides fields."
  def node!(schema, code, node_kind \\ "site", extra \\ %{}) do
    create!(
      schema,
      "location_node",
      values("location_node", code, Map.put(extra, "node_kind", node_kind))
    )
  end

  @doc "Owner-path full-document update that must succeed; returns the stored `Latest` row."
  def update!(schema, record, field_values) do
    {:ok, %{record: updated}} =
      Records.update_record(
        %{
          entity_type: record.entity_type,
          record_id: record.record_id,
          field_values: field_values,
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
        },
        schema,
        owner()
      )

    updated
  end

  @doc "Valid field values for `type` and `code`; `extra` overrides or adds."
  def values("location_node", code, extra) do
    Map.merge(
      %{"code" => code, "name" => "Location #{code}", "node_kind" => "site", "active" => true},
      extra
    )
  end
end
