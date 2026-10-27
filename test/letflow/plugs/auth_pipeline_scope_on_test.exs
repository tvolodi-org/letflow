defmodule Letflow.Plugs.AuthPipelineScopeOnTest do
  @moduledoc """
  REQ-517 / GH #2535 PR 2b, AC 16 and AC 19 (design
  `lib/letflow/design/req517-scoped-grants-admin-plane.md` section 4.2; spec
  `test/specs/REQ-517-2b.md`, T-O3 and the end-to-end half of T-G2 / T-G6): the stored value `on`
  in `Letflow.Plugs.AuthPipeline`, in the style of `auth_pipeline_scope_test.exs` (the real
  `AuthPipeline.call/2` with `Letflow.Oidc.ConfigurableTokenVerifierDouble` for OIDC and a real
  minted API token).

    * the pipeline maps the tenant column to `scope_enforcement: :on` on BOTH the OIDC and the
      API-token path, and the queries each path issues are IDENTICAL under `off`, `shadow` and `on`
      (the token path equals the pinned three-statement literal; the OIDC path has exactly one
      `role_scope_grants` read, right after the role read): the mapping adds no query;
    * the column is read per request: a direct change (`ScopeEnforcementFixture`, the only way to
      reach `on`) takes effect on the very next request of either credential, no restart;
    * through the FULL `Letflow.Router`: under `on` a tenant-wide OIDC administrator and an API
      token pass the admin-plane route `GET /api/v1/identity/tokens`; the same administrator whose
      TENANT_ADMIN group holds only a scoped row is refused 403, and is NOT refused under `off` or
      `shadow`; an unreadable `role_scope_grants` table (`:not_loaded`) is refused 403 under `on`
      (fail closed) while the request still succeeds under `shadow`.

  `async: false`: dedicated provisioned tenants (sandbox `:auto`), DDL and the VM-global `:oidc`
  config swap.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Letflow.Identity
  alias Letflow.Identity.ApiToken
  alias Letflow.Oidc.ConfigurableTokenVerifierDouble
  alias Letflow.Plugs.AuthPipeline
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeEnforcementFixture
  alias Letflow.Support.TokenMintFixture
  alias Letflow.TenantFixture

  @modes [:off, :shadow, :on]
  @admin_route "/api/v1/identity/tokens"

  setup do
    original_oidc_config = Application.fetch_env!(:letflow, :oidc)

    Application.put_env(
      :letflow,
      :oidc,
      Keyword.put(original_oidc_config, :token_verifier, ConfigurableTokenVerifierDouble)
    )

    on_exit(fn -> Application.put_env(:letflow, :oidc, original_oidc_config) end)
    Fixture.unpin!()
    :ok
  end

  # --- fixtures --------------------------------------------------------------------------------

  defp oidc_tenant!(prefix) do
    realm = Letflow.TenantSlugFixture.unique_realm(prefix)

    fx =
      TenantFixture.provisioned_tenant!(
        slug_prefix: prefix,
        display_name: "REQ-517 2b pipeline tenant",
        oidc_mode: :enabled,
        idp_realm_id: realm
      )

    Map.put(fx, :realm, realm)
  end

  defp oidc_conn(fx, method, path) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer realm-token:" <> fx.realm)
  end

  defp run_pipeline(conn), do: AuthPipeline.call(conn, AuthPipeline.init([]))

  defp oidc!(fx) do
    conn = fx |> oidc_conn(:get, "/whatever") |> run_pipeline()
    refute conn.halted, "OIDC request was rejected: #{inspect(conn.resp_body)}"
    conn
  end

  # The first request JIT-provisions the OIDC user, which then gets TENANT_ADMIN by group
  # membership (binding plus its tenant-wide group row from TokenMintFixture).
  defp oidc_admin!(fx) do
    user_id = oidc!(fx).assigns.auth_context.user_id
    TokenMintFixture.grant_roles!(fx.schema_name, user_id, ["TENANT_ADMIN"])
    user_id
  end

  defp admin_token!(fx) do
    owner = TokenMintFixture.role_holder!(fx.schema_name, ["TENANT_ADMIN"])

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(owner.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: fx.schema_name
      )

    plaintext
  end

  defp token_conn(fx, plaintext, method, path) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer " <> plaintext)
    |> put_req_header("x-tenant-slug", fx.tenant.slug)
  end

  defp sources(queries), do: Enum.map(queries, &Map.get(&1, :source))

  defp reset_last_used!(fx),
    do: Repo.update_all(ApiToken, [set: [last_used_at: nil]], prefix: fx.schema_name)

  defp store!(fx, mode), do: ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, mode)

  defp full_router(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  # --- T-O3 ------------------------------------------------------------------------------------

  describe "T-O3 query counts are identical under off, shadow and on" do
    test "API token: the pipeline issues the pinned four statements in every mode, scope_grants is :token" do
      fx = oidc_tenant!("r517-o3-token")
      plaintext = admin_token!(fx)

      measured =
        for mode <- @modes do
          store!(fx, mode)
          reset_last_used!(fx)

          {conn, queries} =
            Fixture.capture_repo_queries(fn ->
              fx |> token_conn(plaintext, :get, "/whatever") |> run_pipeline()
            end)

          refute conn.halted
          assert conn.assigns.auth_context.credential == :api_token
          assert conn.assigns.auth_context.scope_enforcement == mode
          assert conn.assigns.auth_context.scope_grants == :token
          {mode, sources(queries)}
        end

      for {mode, queries} <- measured do
        assert queries == ["tenants", "tenant_lifecycles", "api_tokens", "api_tokens"],
               "mode #{mode}"
      end
    end

    test "OIDC: identical queries in every mode, exactly one role_scope_grants read right after the role read" do
      fx = oidc_tenant!("r517-o3-oidc")
      _user_id = oidc_admin!(fx)

      measured =
        for mode <- @modes do
          store!(fx, mode)
          {conn, queries} = Fixture.capture_repo_queries(fn -> oidc!(fx) end)
          assert conn.assigns.auth_context.credential == :oidc
          assert conn.assigns.auth_context.scope_enforcement == mode
          assert %Letflow.Api.Scope.Grants{} = conn.assigns.auth_context.scope_grants
          {mode, sources(queries)}
        end

      [{:off, off}, {:shadow, shadow}, {:on, on}] = measured
      assert shadow == off
      assert on == off
      assert Enum.count(on, &(&1 == "role_scope_grants")) == 1
      assert Enum.take(on, -2) == ["group_members", "role_scope_grants"]
    end

    test "the column is read per request: a direct change takes effect on the very next request of both credentials, no restart" do
      fx = oidc_tenant!("r517-o3-live")
      _user_id = oidc_admin!(fx)
      plaintext = admin_token!(fx)

      token_mode = fn ->
        conn = fx |> token_conn(plaintext, :get, "/whatever") |> run_pipeline()
        conn.assigns.auth_context.scope_enforcement
      end

      oidc_mode = fn -> oidc!(fx).assigns.auth_context.scope_enforcement end

      assert {oidc_mode.(), token_mode.()} == {:off, :off}

      for mode <- [:on, :shadow, :on, :off, :on] do
        store!(fx, mode)
        assert {oidc_mode.(), token_mode.()} == {mode, mode}, "after storing #{mode}"
      end
    end
  end

  # --- the full router -------------------------------------------------------------------------

  describe "through the full Letflow.Router" do
    test "a tenant-wide OIDC administrator and an API token pass the admin-plane route in every mode" do
      fx = oidc_tenant!("r517-o3-pass")
      _user_id = oidc_admin!(fx)
      plaintext = admin_token!(fx)

      for mode <- @modes do
        store!(fx, mode)

        oidc = fx |> oidc_conn(:get, @admin_route) |> full_router()
        assert oidc.status == 200, "oidc under #{mode}: #{oidc.resp_body}"

        token = fx |> token_conn(plaintext, :get, @admin_route) |> full_router()
        assert token.status == 200, "token under #{mode}: #{token.resp_body}"
      end
    end

    test "an administrator whose TENANT_ADMIN group holds only a scoped row is refused 403 under on, and not refused under off or shadow" do
      fx = oidc_tenant!("r517-o3-scoped")
      _user_id = oidc_admin!(fx)
      s = fx.schema_name
      _node = RSG.make_group_scoped_only!(s, RSG.group_of!(s, "TENANT_ADMIN"), "TENANT_ADMIN")

      for mode <- [:off, :shadow] do
        store!(fx, mode)
        conn = fx |> oidc_conn(:get, @admin_route) |> full_router()
        assert conn.status == 200, "under #{mode}: #{conn.resp_body}"
      end

      store!(fx, :on)
      conn = fx |> oidc_conn(:get, @admin_route) |> full_router()
      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["detail"] == "insufficient permissions"

      # back to off: served again, no restart
      store!(fx, :off)
      assert (fx |> oidc_conn(:get, @admin_route) |> full_router()).status == 200
    end

    test "an unreadable role_scope_grants table (:not_loaded) is refused 403 under on and still served under shadow (fail closed)" do
      fx = oidc_tenant!("r517-o3-hidden")
      user_id = oidc_admin!(fx)
      table = ~s|"#{fx.schema_name}".role_scope_grants|
      Repo.query!("ALTER TABLE #{table} RENAME TO role_scope_grants_req517_hidden")

      try do
        {results, log} =
          with_log(fn ->
            for mode <- [:shadow, :on] do
              store!(fx, mode)
              conn = fx |> oidc_conn(:get, @admin_route) |> full_router()
              {mode, conn.status, conn.assigns.auth_context}
            end
          end)

        assert [{:shadow, 200, shadow_ctx}, {:on, 403, on_ctx}] = results
        assert shadow_ctx.scope_grants == :not_loaded
        assert on_ctx.scope_grants == :not_loaded
        assert on_ctx.user_id == user_id
        assert log =~ "scope_grants_load_failed credential=oidc"
      after
        Repo.query!(
          ~s|ALTER TABLE "#{fx.schema_name}".role_scope_grants_req517_hidden RENAME TO role_scope_grants|
        )
      end
    end
  end
end
