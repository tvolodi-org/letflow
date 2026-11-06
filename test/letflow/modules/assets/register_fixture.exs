defmodule Letflow.AssetsRegisterFixture do
  @moduledoc """
  Shared setup of the assets register router tests (REQ-749 / GH #3893): committed tenants bound to realms of a
  local mock OIDC provider, the `assets` module installed, postings made through `Letflow.LedgerFixture`
  with the module's real registration and `declare/2`, and requests through the full `Letflow.Router`
  with real bearer tokens. A `.exs` file loaded with `Code.require_file/2`, like `codes_fixture.exs`.
  Callers are `async: false` and run in Sandbox `:auto` mode.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]
  import Plug.Conn

  alias Letflow.Identity.RoleRegistry
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs
  alias Letflow.Modules.Assets.LedgerPolicy
  alias Letflow.Oidc.TokenVerifier.Oidcc
  alias Letflow.Support.MockOidcProvider
  alias Letflow.TenantFixture

  @base "/api/v1/modules/assets"

  def base, do: @base

  @doc "Sandbox auto mode, the boot ledger registry, the mock provider and the real verifier. Returns the realm map."
  def setup_oidc!(names) do
    Fx.setup_auto_mode!()
    Fx.put_registry!(Catalog.ledger_registry())

    original = Application.fetch_env!(:letflow, :oidc)
    on_exit(fn -> Application.put_env(:letflow, :oidc, original) end)

    realm_names = Map.new(names, &{&1, Letflow.TenantSlugFixture.unique_realm("ast-#{&1}")})
    %{base_url: base_url, realms: realms} = MockOidcProvider.start(Map.values(realm_names))

    Application.put_env(
      :letflow,
      :oidc,
      Keyword.merge(original, keycloak_base_url: base_url, token_verifier: Oidcc)
    )

    %{names: realm_names, realms: realms}
  end

  @doc "A committed tenant bound to `realm` with the role groups seeded and `assets` installed."
  def tenant!(prefix, realm, opts \\ []) do
    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: prefix,
        idp_realm_id: realm,
        oidc_mode: :enabled,
        teardown: false
      )

    on_exit(fn -> Letflow.EntityWritesFixture.drop_committed_tenant!(tenant.tenant_id) end)

    if Keyword.get(opts, :platform, false),
      do: Letflow.Support.PlatformTenantFixture.pin!(tenant.tenant_id)

    {:ok, _roles} = RoleRegistry.seed_default_platform_role_groups(prefix: tenant.schema_name)

    if Keyword.get(opts, :install, true) do
      {:ok, _seeded} = Letflow.Entities.EventTypes.seed!(tenant.schema_name)
      on_exit(fn -> drop_pack_rows!(tenant.tenant_id) end)

      # assets depends on org and locations (install order: org first).
      for module_id <- ["org", "locations", "assets"] do
        {:ok, _} =
          Installs.install(module_id, Ecto.UUID.generate(),
            prefix: tenant.schema_name,
            rationale: "test: REQ-749"
          )
      end
    end

    tenant
  end

  @doc "Deletes the pack install rows of a tenant (module packs ship entity types now), before the tenant drop."
  def drop_pack_rows!(tenant_id) do
    import Ecto.Query, only: [from: 2]
    alias Letflow.Definitions.SolutionPackArtefactBase
    alias Letflow.Definitions.SolutionPackInstall
    alias Letflow.TenantProvisioning.ColumnPromotion

    Letflow.Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant_id))
    Letflow.Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id))
    Letflow.Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant_id))
    :ok
  end

  def registration do
    {:ok, registration} = Catalog.fetch_ledger("assets", "assets")
    registration
  end

  @doc "A bearer token of the realm with the roles claim."
  def token(ctx, name, roles, opts \\ []) do
    MockOidcProvider.sign_token(
      ctx.realms,
      Map.fetch!(ctx.names, name),
      Keyword.merge([roles: roles], opts)
    )
  end

  @doc "GET `path` (with query string) through the full router with a bearer token."
  def get(path, token, headers \\ []) do
    conn =
      Plug.Test.conn(:get, @base <> path) |> put_req_header("authorization", "Bearer " <> token)

    headers
    |> Enum.reduce(conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  def json(conn), do: Jason.decode!(conn.resp_body)

  @doc "Posts `command` through the assets `declare/2` and the core as `cause`; returns the posted map."
  def post!(schema, cause, command, opts \\ []) do
    {audit, opts} = Keyword.pop(opts, :audit, true)
    registration = registration()
    {:ok, posting} = LedgerPolicy.declare(Map.put(command, :cause, cause), registration)

    Fx.post!(
      Fx.capability(
        schema,
        cause,
        posting.legs,
        [
          ledger_id: "assets",
          registration: registration,
          ensure_storage: false,
          posting: posting
        ] ++ opts
      ),
      audit: audit
    )
  end

  def uuid, do: Ecto.UUID.generate()

  def side(unit, responsible, extra \\ %{}),
    do: Map.merge(%{org_unit: unit, material_responsible: responsible}, extra)

  def line(asset, quantity, sides, extra \\ %{}) do
    Map.merge(Map.merge(%{line_id: uuid(), asset: asset, quantity: quantity}, sides), extra)
  end
end
