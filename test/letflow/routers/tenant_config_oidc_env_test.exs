defmodule Letflow.Routers.TenantConfigOidcEnvTest do
  @moduledoc """
  ISS-0720 regression for `GET /api/tenant-config`: `oidc_issuer_base/0` must read
  `:keycloak_base_url`, not the retired `:issuer` key (design
  `lib/letflow/design/iss0720-tenant-config-stale-issuer-key.md` §1).

  Pre-fix, `oidc_issuer_base/0` read `Application.get_env(:letflow, :oidc, [])[:issuer]`,
  always nil since REQ-370, so `idp_base_url/0` fell through to the compiled localhost
  default whenever `BPM_IDP_BASE_URL`/`KEYCLOAK_BASE_URL` were unset (ISS-0719's QA symptom).

  Own module with `async: false` (flaky-sweep row 4, T-1938): the test mutates the
  VM-global `:letflow, :oidc` Application env, which async modules reading
  `/api/tenant-config` concurrently would otherwise observe. ExUnit runs async: false
  modules only after all async modules have finished; `on_exit/1` restores the env.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  @router_opts Letflow.Router.init([])

  test "oidc_authority is built from :letflow, :oidc, :keycloak_base_url when BPM_IDP_BASE_URL/KEYCLOAK_BASE_URL are unset" do
    # Precondition: if either env var were set it would win over :keycloak_base_url and
    # this test would stop discriminating the bug.
    refute System.get_env("BPM_IDP_BASE_URL")
    refute System.get_env("KEYCLOAK_BASE_URL")

    original_oidc_config = Application.get_env(:letflow, :oidc, [])

    on_exit(fn -> Application.put_env(:letflow, :oidc, original_oidc_config) end)

    Application.put_env(
      :letflow,
      :oidc,
      Keyword.put(
        original_oidc_config,
        :keycloak_base_url,
        "https://iss0720-regression-test-authority.example"
      )
    )

    conn = conn(:get, "/api/tenant-config")
    assert get_req_header(conn, "authorization") == []

    conn = Letflow.Router.call(conn, @router_opts)
    body = Jason.decode!(conn.resp_body)

    assert conn.status == 200

    assert String.starts_with?(
             body["oidc_authority"],
             "https://iss0720-regression-test-authority.example/realms/"
           )

    refute body["oidc_authority"] =~ "localhost"
  end
end
