defmodule Letflow.Api.KeycloakRealmMobileClientTest do
  @moduledoc """
  REQ-418 — proves `priv/keycloak/realms/bpm-default.json` defines the new
  `letflow-mobile` public OIDC client (Authorization-Code+PKCE, S256) with the
  exact shape the design (`lib/letflow/design/req418-mobile-oidc-client.md`
  §1) requires, and proves `letflow-web`'s own client object is byte-for-byte
  unchanged by this requirement.

  Why this test exists: MOB-2's `flutter_appauth` flow needs an OIDC client
  the mobile app can name. Reusing `letflow-web` was rejected — its wildcard
  `redirectUris: ["*"]` would let any app registering any scheme receive a
  mobile authorization code, and its `directAccessGrantsEnabled: true` has no
  place on a device. This is a static, file-only check (no live Keycloak
  required) that the new client's security-relevant fields are present and
  correctly shaped, and a regression guard against `letflow-web` being
  touched while adding it. Live PKCE/redirect-uri/audience-claim behavior
  (REQ-418's AC3/AC4) is exercised separately against a running Keycloak
  container, not repeated here (design §1.5).

  See `lib/letflow/design/iss0275-audience-mapper-fix.md` for why the
  `oidc-audience-mapper` protocol mapper is mandatory, not optional, on any
  client issuing tokens against this realm (`Letflow.Oidc.TokenVerifier.Oidcc`
  rejects any access token whose `aud` claim omits the configured
  `"letflow-web"` client id, regardless of which client issued the token).
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @realm_path Path.join([
                __DIR__,
                "..",
                "..",
                "..",
                "priv",
                "keycloak",
                "realms",
                "bpm-default.json"
              ])

  setup do
    realm_json = @realm_path |> File.read!() |> Jason.decode!()
    clients = get_in(realm_json, ["clients"]) || []

    {:ok, clients: clients}
  end

  describe "letflow-mobile client's shape (design §1.1)" do
    setup %{clients: clients} do
      mobile = Enum.find(clients, &(&1["clientId"] == "letflow-mobile"))

      refute is_nil(mobile),
             "expected priv/keycloak/realms/bpm-default.json to define a client with clientId \"letflow-mobile\""

      {:ok, mobile: mobile}
    end

    test "publicClient is true", %{mobile: mobile} do
      assert mobile["publicClient"] == true
    end

    test "standardFlowEnabled is true (Authorization Code flow, required for PKCE)", %{
      mobile: mobile
    } do
      assert mobile["standardFlowEnabled"] == true
    end

    test "directAccessGrantsEnabled is false -- password grant has no place on a device", %{
      mobile: mobile
    } do
      assert mobile["directAccessGrantsEnabled"] == false
    end

    test "implicitFlowEnabled is false", %{mobile: mobile} do
      assert mobile["implicitFlowEnabled"] == false
    end

    test "serviceAccountsEnabled is false -- no server-to-server use case for a mobile app", %{
      mobile: mobile
    } do
      assert mobile["serviceAccountsEnabled"] == false
    end

    test "attributes[\"pkce.code.challenge.method\"] is S256 -- server-side PKCE enforcement",
         %{mobile: mobile} do
      assert get_in(mobile, ["attributes", "pkce.code.challenge.method"]) == "S256"
    end

    test "attributes[\"post.logout.redirect.uris\"] matches the app's custom-scheme redirect", %{
      mobile: mobile
    } do
      assert get_in(mobile, ["attributes", "post.logout.redirect.uris"]) ==
               "com.bizdala.letflow:/oauth2redirect"
    end

    test "redirectUris is exactly [\"com.bizdala.letflow:/oauth2redirect\"] -- no wildcard, no http(s) entry",
         %{mobile: mobile} do
      assert mobile["redirectUris"] == ["com.bizdala.letflow:/oauth2redirect"]
    end

    test "webOrigins is exactly [] -- a native app makes no browser-origin CORS request", %{
      mobile: mobile
    } do
      assert mobile["webOrigins"] == []
    end

    test "no wildcard/http(s) entry hides in redirectUris or webOrigins", %{mobile: mobile} do
      for uri <- mobile["redirectUris"] ++ mobile["webOrigins"] do
        refute uri == "*", "found a literal wildcard entry: #{inspect(uri)}"
        refute String.starts_with?(uri, "http"), "found an http(s) entry: #{inspect(uri)}"
      end
    end

    test "carries a realm-roles mapper (same as letflow-web)", %{mobile: mobile} do
      protocol_mappers = mobile["protocolMappers"] || []
      realm_roles_mapper = Enum.find(protocol_mappers, &(&1["name"] == "realm-roles"))

      refute is_nil(realm_roles_mapper),
             "letflow-mobile's protocolMappers array has no mapper named \"realm-roles\""

      assert realm_roles_mapper == %{
               "name" => "realm-roles",
               "protocol" => "openid-connect",
               "protocolMapper" => "oidc-usermodel-realm-role-mapper",
               "consentRequired" => false,
               "config" => %{
                 "multivalued" => "true",
                 "userinfo.token.claim" => "true",
                 "id.token.claim" => "true",
                 "access.token.claim" => "true",
                 "claim.name" => "roles",
                 "jsonType.label" => "String"
               }
             }
    end

    test "carries a MANDATORY oidc-audience-mapper naming letflow-web (ISS-0275 recurrence guard)",
         %{mobile: mobile} do
      protocol_mappers = mobile["protocolMappers"] || []

      audience_mapper =
        Enum.find(protocol_mappers, &(&1["protocolMapper"] == "oidc-audience-mapper"))

      refute is_nil(audience_mapper),
             """
             letflow-mobile's protocolMappers array has no mapper with \
             protocolMapper == "oidc-audience-mapper".

             Without it, tokens Keycloak issues for letflow-mobile carry no `aud` \
             claim satisfying Oidcc.Token.validate_jwt/3's verify_aud_claim check \
             (which requires "letflow-web" regardless of issuing client), so every \
             authenticated mobile API call would 401 -- the identical defect \
             ISS-0275 already fixed once for letflow-web, recurring on a second \
             client. See lib/letflow/design/iss0275-audience-mapper-fix.md.
             """

      assert get_in(audience_mapper, ["config", "included.client.audience"]) == "letflow-web"
      assert get_in(audience_mapper, ["config", "access.token.claim"]) == "true"
    end
  end

  describe "letflow-web client is byte-for-byte unchanged (design §1.3)" do
    test "letflow-web's full client object equals an inline literal, exact equality", %{
      clients: clients
    } do
      letflow_web = Enum.find(clients, &(&1["clientId"] == "letflow-web"))

      refute is_nil(letflow_web),
             "expected priv/keycloak/realms/bpm-default.json to still define a client with clientId \"letflow-web\""

      # Inline literal, not `git show origin/main:...` (unavailable under CI's
      # shallow checkout, and tautological once this change lands on main).
      # Exact `==` equality, not a partial/subset match -- proves no field
      # was added, removed, reordered, or edited while adding letflow-mobile.
      assert letflow_web == %{
               "clientId" => "letflow-web",
               "name" => "Letflow Web",
               "enabled" => true,
               "protocol" => "openid-connect",
               "publicClient" => true,
               "directAccessGrantsEnabled" => true,
               "standardFlowEnabled" => true,
               "serviceAccountsEnabled" => false,
               "redirectUris" => ["*"],
               "webOrigins" => ["*"],
               "protocolMappers" => [
                 %{
                   "name" => "realm-roles",
                   "protocol" => "openid-connect",
                   "protocolMapper" => "oidc-usermodel-realm-role-mapper",
                   "consentRequired" => false,
                   "config" => %{
                     "multivalued" => "true",
                     "userinfo.token.claim" => "true",
                     "id.token.claim" => "true",
                     "access.token.claim" => "true",
                     "claim.name" => "roles",
                     "jsonType.label" => "String"
                   }
                 },
                 %{
                   "name" => "letflow-web-audience",
                   "protocol" => "openid-connect",
                   "protocolMapper" => "oidc-audience-mapper",
                   "consentRequired" => false,
                   "config" => %{
                     "included.client.audience" => "letflow-web",
                     "included.custom.audience" => "",
                     "id.token.claim" => "false",
                     "access.token.claim" => "true"
                   }
                 }
               ]
             }
    end
  end
end
