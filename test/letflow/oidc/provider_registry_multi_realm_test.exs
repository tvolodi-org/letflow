defmodule Letflow.Oidc.ProviderRegistryMultiRealmTest do
  @moduledoc """
  REQ-370 (SECURITY-CRITICAL: multi-issuer OIDC token verification) — AC2/AC3/AC4/AC5,
  plus direct `Letflow.Oidc.ProviderRegistry` unit coverage and the `:malformed_token`
  vs. crash-boundary split (OQ-4). See `test/specs/REQ-370.md` for the full case-by-case
  rationale and `lib/letflow/design/req370-multi-issuer-oidc-verification.md` §11/§12
  for the design's own testing notes and acceptance-criteria traceability table.

  **Why a local mock OIDC provider (`Letflow.Support.MockOidcProvider`), not real
  Keycloak.** AC2's own negative case needs a token whose `iss` claims realm A but is
  SIGNED WITH REALM B'S OWN KEY -- the design doc's own §11 "AC2" text: "constructing
  this directly via the test double's/fixture's own key material -- not obtainable
  from a real Keycloak, since that would require possessing another realm's private
  key". Having built that fixture (real RSA keypairs, real RS256 signatures, a real
  local discovery+JWKS HTTP server), AC3/AC5 reuse it too, for determinism: this
  environment's real `docker compose` Keycloak container (used by
  `test/letflow/integration/keycloak_auth_pipeline_test.exs`) was directly observed
  during this same test-design session to intermittently `{:error, {:transport_error,
  :timeout}}` under repeated `:httpc` calls, which would make a real-Keycloak-based
  AC2/AC3/AC5 file flaky for reasons unrelated to the property under test.

  **`async: false` (required, not a style choice).** Every test in this module swaps
  `config :letflow, :oidc`'s `:keycloak_base_url`/`:token_verifier` via
  `Application.put_env/3` -- global, process-shared state -- mirroring
  `test/letflow/plugs/auth_pipeline_configurable_verifier_test.exs`'s own documented
  reasoning. `Letflow.Oidc.ProviderRegistry` is also a real, permanently-running
  `DynamicSupervisor` (part of `Letflow.Application`'s own supervision tree, started
  once at node boot, never torn down between tests -- design doc §4.2's own "no
  teardown" decision) so every realm name used anywhere in this file is generated via
  `unique_realm/1` (UUID-suffixed) specifically so a worker
  started by one test's mock server (bound to that test's own ephemeral port and key
  material) can never be found and reused by a later test under the same realm name.

  ## Production defect found and fixed during test design

  Writing AC2's positive case against the REAL `Letflow.Oidc.TokenVerifier.Oidcc`
  adapter (not a double) reproducibly raised `** (ArgumentError) errors were found at
  the given arguments: * 1st argument: not an atom` from `:erlang.whereis/1`, called
  from `deps/oidcc/src/oidcc_client_context.erl`'s `from_configuration_worker/4`'s own
  non-pid clause. Root cause: `oidcc`'s `from_configuration_worker/3,4` resolves a
  non-pid `ProviderName` via the raw Erlang BIF `erlang:whereis/1`, which accepts only
  a locally-registered ATOM name -- never a `{:via, Registry, _}` tuple, which is
  exactly what `Letflow.Oidc.ProviderRegistry.via_name/1` returns (design doc §4.2).
  The design doc's own §0/§4.2 confirmed only that `{:via, Registry, _}` naming is
  accepted by `Oidcc.ProviderConfiguration.Worker.start_link/1` (true) -- it did not
  separately confirm that `from_configuration_worker/3,4` could look such a name back
  up afterward (false). Every test written before this file exercised only the
  test-double `Letflow.Oidc.TokenVerifier` implementations (`TokenVerifierDouble`/
  `ConfigurableTokenVerifierDouble`), never this real adapter's post-REQ-370 code
  path end to end -- so this was never caught until a real, non-double provider was
  exercised here.

  **Fix applied** (`lib/letflow/oidc/token_verifier/oidcc.ex`, `verify_signature/2`):
  resolve `provider_ref` (the via-tuple) to a pid via `GenServer.whereis/1` --
  Elixir's own wrapper, which DOES resolve `{:via, Registry, _}` names, unlike the raw
  Erlang BIF -- before calling `Oidcc.ClientContext.from_configuration_worker/3`.
  `from_configuration_worker/3`'s `is_pid(ProviderName)` clause then handles the
  resolved pid identically regardless of how it was registered. This changes nothing
  about `ProviderRegistry`'s naming/supervision shape (design §4.2) -- it is a
  one-call-site fix inside the adapter, not a design change. **Flagged prominently for
  SECURITY-REVIEWER + REVIEWER re-review**, since it is a production `lib/` change
  made outside the normal CODE-DESIGNER -> ELIXIR-DEV sequence, discovered only
  because this file exercises the real verification path instead of a double.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity.Tenant
  alias Letflow.Oidc.ProviderRegistry
  alias Letflow.Oidc.TokenVerifier.Oidcc
  alias Letflow.Support.MockOidcProvider
  alias Letflow.TenantSlugFixture

  import Plug.Test
  import Plug.Conn

  setup do
    original_oidc_config = Application.fetch_env!(:letflow, :oidc)
    on_exit(fn -> Application.put_env(:letflow, :oidc, original_oidc_config) end)
    :ok
  end

  defp unique_realm(prefix), do: TenantSlugFixture.unique_realm(prefix)

  defp insert_tenant!(realm) do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: TenantSlugFixture.unique_slug("req370"),
        display_name: "REQ-370 multi-realm test tenant",
        idp_realm_id: realm
      },
      :enabled
    )
    |> Repo.insert!()
  end

  # Swaps :keycloak_base_url (so ProviderRegistry.start_worker/2 points at this
  # test's own MockOidcProvider instance) and :token_verifier (so the REAL adapter,
  # not config/test.exs's default TokenVerifierDouble, is exercised) -- restored by
  # this module's own `setup` on_exit above.
  defp point_at_real_verifier(base_url) do
    original_oidc_config = Application.fetch_env!(:letflow, :oidc)

    Application.put_env(
      :letflow,
      :oidc,
      Keyword.merge(original_oidc_config, keycloak_base_url: base_url, token_verifier: Oidcc)
    )
  end

  # A standalone, self-signed JWT independent of MockOidcProvider -- used only for
  # AC4/malformed-token cases, which are rejected (per §2's trust-gate ordering, or
  # peek_realm/1's own structural check) BEFORE any HTTP discovery/JWKS call is ever
  # made, so no mock server needs to be running or even aware of this token's claimed
  # issuer for these specific cases.
  defp standalone_token(claims_overrides) do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    now = System.system_time(:second)

    default_claims = %{
      "iss" => "https://unreachable-mock-idp.invalid/realms/does-not-matter",
      "sub" => "standalone-subject",
      "aud" => "letflow-web",
      "exp" => now + 300,
      "iat" => now
    }

    claims = default_claims |> Map.merge(claims_overrides) |> prune_nils()

    {_jws, compact_token} =
      jwk
      |> JOSE.JWT.sign(%{"alg" => "RS256"}, JOSE.JWT.from_map(claims))
      |> JOSE.JWS.compact()

    compact_token
  end

  defp prune_nils(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)

  defp call_pipeline(headers) do
    conn = conn(:post, "/whatever")

    conn =
      Enum.reduce(headers, conn, fn {key, value}, acc -> put_req_header(acc, key, value) end)

    Letflow.Plugs.AuthPipeline.call(conn, Letflow.Plugs.AuthPipeline.init([]))
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- the NEW verify_bearer_token/1 routing/verification step itself does not
  # cross-accept. Both assertions call verify_bearer_token/1 DIRECTLY (never through
  # AuthPipeline), with both realms' providers concurrently registered/started, per
  # design §11 "AC2" -- a routing bug needs a second, live provider actually present
  # to mis-route into, or this test could not detect a mix-up at all.
  # ---------------------------------------------------------------------------------

  describe "AC2 — cross-realm routing does not cross-accept" do
    test "positive routing-isolation: realm A's genuinely-signed token verifies as A while realm B's provider is also live" do
      realm_a = unique_realm("ac2-a")
      realm_b = unique_realm("ac2-b")

      %{base_url: base_url, realms: fixtures} = MockOidcProvider.start([realm_a, realm_b])
      point_at_real_verifier(base_url)

      insert_tenant!(realm_a)
      insert_tenant!(realm_b)

      # Both providers concurrently registered/started BEFORE this test's own
      # assertions -- a test with only realm A registered could not detect a
      # mix-up at all (there would be nothing else to mis-route into).
      assert {:ok, _via_a} = ProviderRegistry.ensure_started(realm_a)
      assert {:ok, _via_b} = ProviderRegistry.ensure_started(realm_b)

      token_a = MockOidcProvider.sign_token(fixtures, realm_a)

      assert {:ok, claims} = Oidcc.verify_bearer_token(token_a)
      assert claims["iss"] == fixtures[realm_a].issuer
    end

    test "negative cross-accept/forgery check: iss claims realm A but the signature was produced with realm B's own key" do
      realm_a = unique_realm("ac2-forge-a")
      realm_b = unique_realm("ac2-forge-b")

      %{base_url: base_url, realms: fixtures} = MockOidcProvider.start([realm_a, realm_b])
      point_at_real_verifier(base_url)

      insert_tenant!(realm_a)
      insert_tenant!(realm_b)

      assert {:ok, _via_a} = ProviderRegistry.ensure_started(realm_a)
      assert {:ok, _via_b} = ProviderRegistry.ensure_started(realm_b)

      # iss claims realm A's own issuer, but signed with realm B's private key --
      # simulates an attacker who controls realm B's tenant attempting to have a
      # token accepted AS realm A. Never obtainable from a real Keycloak (moduledoc).
      forged_token = MockOidcProvider.sign_token(fixtures, realm_a, signing_realm: realm_b)

      assert {:error, _reason} = Oidcc.verify_bearer_token(forged_token)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- at least 2 distinct, independently-registered realms each verify
  # successfully, proving routing genuinely selected the correct per-realm
  # worker/JWKS, not just "some" worker.
  # ---------------------------------------------------------------------------------

  describe "AC3 — >= 2 independently-registered realms each verify successfully" do
    test "two distinct realms, each genuinely issued by its own issuer, both verify" do
      realm_1 = unique_realm("ac3-one")
      realm_2 = unique_realm("ac3-two")

      %{base_url: base_url, realms: fixtures} = MockOidcProvider.start([realm_1, realm_2])
      point_at_real_verifier(base_url)

      insert_tenant!(realm_1)
      insert_tenant!(realm_2)

      token_1 = MockOidcProvider.sign_token(fixtures, realm_1)
      token_2 = MockOidcProvider.sign_token(fixtures, realm_2)

      assert {:ok, claims_1} = Oidcc.verify_bearer_token(token_1)
      assert claims_1["iss"] == fixtures[realm_1].issuer

      assert {:ok, claims_2} = Oidcc.verify_bearer_token(token_2)
      assert claims_2["iss"] == fixtures[realm_2].issuer
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- a token whose iss claims an issuer with NO corresponding tenant row is
  # rejected by the verification step itself, not a wildcard/catch-all accept. Both
  # unit-level (direct Oidcc.verify_bearer_token/1 call) and integration-level
  # (through the full AuthPipeline, confirming the generic 401/no-oracle claim in
  # practice) per design §11 "AC4".
  # ---------------------------------------------------------------------------------

  describe "AC4 — unknown-issuer rejection" do
    test "verify_bearer_token/1 rejects a token whose iss claims a realm with no tenant row" do
      realm = unique_realm("ac4-unknown")
      token = standalone_token(%{"iss" => "https://unreachable-mock-idp.invalid/realms/#{realm}"})

      # No tenant row for `realm` exists anywhere -- resolve_provider/1's trust gate
      # (Letflow.Oidc.ProviderRegistry.ensure_started/1 -> Identity.resolve_tenant_by_realm/1)
      # must reject before ever attempting network I/O against the claimed issuer.
      assert {:error, :untrusted_issuer} = Oidcc.verify_bearer_token(token)
    end

    test "AuthPipeline rejects the same token end to end with the standard generic 401" do
      realm = unique_realm("ac4-unknown-e2e")
      token = standalone_token(%{"iss" => "https://unreachable-mock-idp.invalid/realms/#{realm}"})

      # keycloak_base_url need not be reachable -- :untrusted_issuer short-circuits
      # before ProviderRegistry ever attempts to start a worker or make an HTTP call.
      point_at_real_verifier("http://127.0.0.1:1")

      conn = call_pipeline([{"authorization", "Bearer " <> token}])

      assert conn.halted
      assert conn.status == 401

      assert %{"error" => "unauthorized", "detail" => "invalid or expired bearer token"} =
               Jason.decode!(conn.resp_body)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- revoking/removing a tenant's idp_realm_id binding causes SUBSEQUENT tokens
  # from that realm to be rejected: the trusted set is derived from CURRENT tenants
  # state on every call, never cached/latched from a prior successful verification
  # (design §2/§4.3 -- "the single most load-bearing line" per SECURITY-REVIEWER and
  # REVIEWER's own sign-off comments). Per design §4.3/OQ-2: no public "revoke realm"
  # API exists (Tenant.update_changeset/2 structurally omits idp_realm_id, REQ-019),
  # so this test uses direct Repo manipulation -- REVIEWER-accepted at design-review
  # time as the sanctioned mechanism.
  # ---------------------------------------------------------------------------------

  describe "AC5 — revocation causes rejection (fresh-every-call trust gate)" do
    test "the SAME realm that verified successfully once is rejected after its tenant binding is removed" do
      realm = unique_realm("ac5-revoke")

      %{base_url: base_url, realms: fixtures} = MockOidcProvider.start([realm])
      point_at_real_verifier(base_url)

      tenant = insert_tenant!(realm)

      token_before = MockOidcProvider.sign_token(fixtures, realm)

      # First call: trusted, and it also warms the per-realm worker cache -- this is
      # deliberate. AC5's property is specifically that a live, cached worker does
      # NOT override a since-revoked trust decision (design §4.3) -- so this test
      # must prove the SAME realm that just succeeded now fails, not merely that an
      # always-untrusted realm fails (that would only re-prove AC4).
      assert {:ok, claims_before} = Oidcc.verify_bearer_token(token_before)
      assert claims_before["iss"] == fixtures[realm].issuer

      # Revoke: remove the tenant row bound to this realm. No public API exists for
      # this (OQ-2) -- direct Repo manipulation, bypassing update_changeset/2's
      # structural immutability guard, is this design's own sanctioned test mechanism.
      Repo.delete!(tenant)

      token_after = MockOidcProvider.sign_token(fixtures, realm)

      assert {:error, :untrusted_issuer} = Oidcc.verify_bearer_token(token_after)
    end
  end

  # ---------------------------------------------------------------------------------
  # Unit coverage for Letflow.Oidc.ProviderRegistry directly (design §11's own
  # explicit ask), not only observed indirectly through the verifier.
  # ---------------------------------------------------------------------------------

  describe "ProviderRegistry.ensure_started/1 — direct unit coverage" do
    test "a trusted realm's second call reuses the same registered pid (no duplicate worker)" do
      realm = unique_realm("registry-reuse")
      %{base_url: base_url} = MockOidcProvider.start([realm])
      point_at_real_verifier(base_url)
      insert_tenant!(realm)

      assert {:ok, via} = ProviderRegistry.ensure_started(realm)
      assert via == ProviderRegistry.via_name(realm)
      assert [{pid_first, _value}] = Registry.lookup(Letflow.Registry, {:oidc_provider, realm})

      assert {:ok, ^via} = ProviderRegistry.ensure_started(realm)
      assert [{pid_second, _value}] = Registry.lookup(Letflow.Registry, {:oidc_provider, realm})

      assert pid_first == pid_second
    end

    test "an untrusted realm returns {:error, :unknown_realm} and starts no process at all" do
      realm = unique_realm("registry-untrusted")

      assert {:error, :unknown_realm} = ProviderRegistry.ensure_started(realm)
      assert Registry.lookup(Letflow.Registry, {:oidc_provider, realm}) == []
    end

    # GH #3252 / REQ-572
    test "an inactive tenant's realm is refused and starts no process; an active one starts" do
      realm = unique_realm("registry-inactive")
      %{base_url: base_url} = MockOidcProvider.start([realm])
      point_at_real_verifier(base_url)
      tenant = insert_tenant!(realm)

      assert {:ok, _via} = ProviderRegistry.ensure_started(realm)
      assert :ok = ProviderRegistry.stop(realm)

      tenant |> Ecto.Changeset.change(status: :inactive) |> Repo.update!()

      assert {:error, :unknown_realm} = ProviderRegistry.ensure_started(realm)
      assert Registry.lookup(Letflow.Registry, {:oidc_provider, realm}) == []
    end

    test "stop/1 terminates a running worker, is idempotent, and ensure_started restarts it" do
      realm = unique_realm("registry-stop")
      %{base_url: base_url} = MockOidcProvider.start([realm])
      point_at_real_verifier(base_url)
      insert_tenant!(realm)

      assert {:ok, _via} = ProviderRegistry.ensure_started(realm)
      assert [{pid, _}] = Registry.lookup(Letflow.Registry, {:oidc_provider, realm})
      ref = Process.monitor(pid)

      assert :ok = ProviderRegistry.stop(realm)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
      assert :ok = ProviderRegistry.stop(realm)
      assert :ok = ProviderRegistry.stop(unique_realm("registry-stop-none"))

      assert {:ok, _via} = ProviderRegistry.ensure_started(realm)
    end
  end

  # ---------------------------------------------------------------------------------
  # :malformed_token vs. the existing generic crash-boundary classification (OQ-4).
  # ---------------------------------------------------------------------------------

  describe "malformed-token / crash-boundary coverage (OQ-4)" do
    test "garbage, non-JWT-shaped input is rejected, never raises" do
      assert {:error, _reason} = Oidcc.verify_bearer_token("not-a-jwt-at-all")
    end

    test "a well-formed JWT payload missing the iss claim entirely is rejected as :malformed_token" do
      token = standalone_token(%{"iss" => nil})

      assert {:error, :malformed_token} = Oidcc.verify_bearer_token(token)
    end

    test "a well-formed JWT whose iss has no /realms/<realm> suffix is rejected as :malformed_token" do
      token =
        standalone_token(%{"iss" => "https://unreachable-mock-idp.invalid/not-a-realm-path"})

      assert {:error, :malformed_token} = Oidcc.verify_bearer_token(token)
    end
  end
end
