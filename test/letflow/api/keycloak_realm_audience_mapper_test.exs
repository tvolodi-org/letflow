defmodule Letflow.Api.KeycloakRealmAudienceMapperTest do
  @moduledoc """
  ISS-0275 regression — proves `priv/keycloak/realms/bpm-default.json`'s
  `letflow-web` client carries an `oidc-audience-mapper` protocol mapper that
  populates the access token's `aud` claim with `"letflow-web"`.

  Why this test exists: `Oidcc.Token.validate_jwt/3`
  (`deps/oidcc/src/oidcc_token.erl`) unconditionally requires the access
  token's `aud` claim to contain the configured `client_id`
  (`"letflow-web"`, per `config/dev.exs`/`config/test.exs`'s `:oidc`
  config). Before ISS-0275's fix, `letflow-web`'s `protocolMappers` array
  held only the `realm-roles` mapper — nothing ever populated `aud`, so
  every real Keycloak-issued token failed validation and every
  authenticated request 401'd, regardless of route. This is a static,
  file-only check (no live Keycloak required) that the fix's mapper is
  present in the tracked realm fixture with the exact config keys that
  make it effective, so a future edit to this file cannot silently drop it
  again. See `lib/letflow/design/iss0275-audience-mapper-fix.md` for the
  full root-cause writeup and field-by-field rationale.

  This is a *fixture-content* test, not a live-token test — it does not
  start Keycloak or decode a real JWT. Live end-to-end verification (a
  freshly-provisioned Keycloak container issuing a token with `aud:
  "letflow-web"`) was already performed by ELIXIR-DEV during ISS-0275's
  fix and is not repeated here; this test guards against regressing the
  tracked file that makes that live behavior possible.
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

    letflow_web =
      realm_json |> get_in(["clients"]) |> Enum.find(&(&1["clientId"] == "letflow-web"))

    refute is_nil(letflow_web),
           "expected priv/keycloak/realms/bpm-default.json to define a client with clientId \"letflow-web\""

    protocol_mappers = letflow_web["protocolMappers"] || []

    {:ok, protocol_mappers: protocol_mappers}
  end

  describe "letflow-web client's oidc-audience-mapper" do
    test "a protocol mapper of type oidc-audience-mapper is present", %{
      protocol_mappers: protocol_mappers
    } do
      audience_mapper =
        Enum.find(protocol_mappers, &(&1["protocolMapper"] == "oidc-audience-mapper"))

      refute is_nil(audience_mapper),
             """
             letflow-web's protocolMappers array has no mapper with \
             protocolMapper == "oidc-audience-mapper".

             Without it, tokens Keycloak issues for letflow-web carry no `aud` \
             claim, and Oidcc.Token.validate_jwt/3 rejects every one of them \
             outright (ISS-0275). See \
             lib/letflow/design/iss0275-audience-mapper-fix.md.

             protocolMappers found: #{inspect(Enum.map(protocol_mappers, & &1["name"]))}
             """
    end

    test "its config sets included.client.audience to letflow-web", %{
      protocol_mappers: protocol_mappers
    } do
      audience_mapper =
        Enum.find(protocol_mappers, &(&1["protocolMapper"] == "oidc-audience-mapper"))

      refute is_nil(audience_mapper),
             "precondition: oidc-audience-mapper must exist (see prior test)"

      assert get_in(audience_mapper, ["config", "included.client.audience"]) == "letflow-web",
             "the oidc-audience-mapper's config[\"included.client.audience\"] must be " <>
               "\"letflow-web\" — this is the value actually added to the access token's " <>
               "aud claim, and must match the client_id Oidcc.Token.validate_jwt/3 checks " <>
               "for (config/dev.exs and config/test.exs's :oidc config)."
    end

    test "its config sets access.token.claim to \"true\"", %{protocol_mappers: protocol_mappers} do
      audience_mapper =
        Enum.find(protocol_mappers, &(&1["protocolMapper"] == "oidc-audience-mapper"))

      refute is_nil(audience_mapper),
             "precondition: oidc-audience-mapper must exist (see prior test)"

      assert get_in(audience_mapper, ["config", "access.token.claim"]) == "true",
             "the oidc-audience-mapper's config[\"access.token.claim\"] must be the string " <>
               "\"true\" — this is the field that makes the mapper actually run against the " <>
               "access token, the token Oidcc.Token.validate_jwt/3 rejects. If this is " <>
               "\"false\" or missing, the mapper exists but has no effect."
    end
  end

  describe "regression guard: pre-existing realm-roles mapper" do
    test "the realm-roles (oidc-usermodel-realm-role-mapper) mapper is still present and unmodified",
         %{protocol_mappers: protocol_mappers} do
      realm_roles_mapper = Enum.find(protocol_mappers, &(&1["name"] == "realm-roles"))

      refute is_nil(realm_roles_mapper),
             "the pre-existing \"realm-roles\" mapper must not be removed while touching " <>
               "letflow-web's protocolMappers array — SPA role claims depend on it."

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
             },
             "the realm-roles mapper's shape changed unexpectedly — this guards against a " <>
               "future edit to this file accidentally modifying it while adding/touching " <>
               "other mappers on the same client."
    end
  end
end
