Code.require_file("../org/org_fixture.exs", __DIR__)

defmodule Letflow.AssetsFixture do
  @moduledoc """
  Shared fixtures for the assets module tests (GH #3894 / REQ-748).

  `installed_tenant!/1` provisions a real tenant (with the default role groups and a TENANT_ADMIN
  user, `Letflow.Support.ScopedGrantsFixture.tenant!/1`), seeds its event types and installs the real
  `org`, `locations` and `assets` modules through the real `Letflow.Routers.TenantModules`.
  `card!/3` writes through `Letflow.Entities.Records` with
  `ManagedTypes.owner_for!(Letflow.Modules.Assets)`, as the module's own code will.

  This is a `.exs` under `test/letflow/modules/assets/`, NOT a `test/support/**/*.ex` file: the
  R1/R2 caller guard in `managed_types_callers_test.exs` rejects `owner_for!(Assets)` elsewhere.
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
  alias Letflow.Support.ScopedGrantsFixture, as: S
  alias Letflow.TenantProvisioning.ColumnPromotion

  @install_opts Letflow.Routers.TenantModules.init([])

  @doc "A provisioned tenant (a `ScopedGrantsFixture` map) with org, locations and assets installed."
  def installed_tenant!(slug_prefix) do
    fx = provisioned_tenant!(slug_prefix)

    for module_id <- ~w(org catalog_items locations codes stock assets) do
      install_module!(fx.tenant_id, module_id)
    end

    fx
  end

  @doc "A provisioned tenant with event types seeded and no module installed."
  def provisioned_tenant!(slug_prefix) do
    fx = S.tenant!(slug_prefix)

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^fx.tenant_id))
      Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^fx.tenant_id))
      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^fx.tenant_id))
    end)

    {:ok, _seeded} = EventTypes.seed!(fx.schema_name)
    fx
  end

  @doc "Installs `module_id` through the real router as TENANT_ADMIN; raises unless 201."
  def install_module!(tenant_id, module_id) do
    conn =
      Plug.Test.conn(:post, "/")
      |> Map.put(:body_params, %{"module_id" => module_id, "rationale" => "GH-3894 test install"})
      |> put_req_header("content-type", "application/json")
      |> assign(:auth_context, %{
        user_id: Ecto.UUID.generate(),
        tenant_id: tenant_id,
        roles: ["TENANT_ADMIN"]
      })
      |> assign(:trace_id, "gh3894-assets-fixture-trace")
      |> Letflow.Routers.TenantModules.call(@install_opts)

    if conn.status != 201,
      do: raise("#{module_id} install failed: #{conn.status} #{conn.resp_body}")

    :ok
  end

  @doc "The Owner authority of the assets module."
  def owner, do: ManagedTypes.owner_for!(Letflow.Modules.Assets)

  @doc "Owner-path create; returns `{:ok, _}` or `{:error, _}` as `Records.create_record/3`."
  def create(schema, field_values) do
    Records.create_record(
      %{
        entity_type: "assets_card",
        field_values: field_values,
        actor_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate()
      },
      schema,
      owner()
    )
  end

  @doc "Owner-path create that must succeed; returns the stored `Latest` row."
  def card!(schema, inventory_number, extra \\ %{}) do
    {:ok, %{record: record}} = create(schema, values(inventory_number, extra))
    record
  end

  @doc "Valid card field values; `extra` overrides or adds."
  def values(inventory_number, extra \\ %{}) do
    Map.merge(
      %{
        "inventory_number" => inventory_number,
        "name" => "Card #{inventory_number}",
        "kind" => "fixed",
        "org_unit_id" => Ecto.UUID.generate(),
        "active" => true
      },
      extra
    )
  end
end
