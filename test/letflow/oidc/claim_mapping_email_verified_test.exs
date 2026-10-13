defmodule Letflow.Oidc.ClaimMappingEmailVerifiedTest do
  @moduledoc """
  ISS-1030 PR 2 -- the `email_verified` field of `Letflow.Oidc.IdentityContext`, set by
  `Letflow.Oidc.ClaimMapping.map_verified_claims/3` (design section 4.4).

  Pure: no database. The rule is strict equality with the JSON boolean `true`, because the value
  is the one fact that decides whether a pending administrator grant may bind, and a token's claim
  can carry any JSON shape (a realm mapper that stringifies a boolean is a real configuration).
  """

  use ExUnit.Case, async: true

  alias Letflow.Oidc.ClaimMapping
  alias Letflow.Oidc.ClaimMappingConfig
  alias Letflow.Oidc.IdentityContext

  defp map(claims) do
    base = %{
      "iss" => "https://placeholder-keycloak.invalid/realms/claim-test",
      "sub" => "subject-1",
      "email" => "person@example.com",
      "preferred_username" => "person",
      "realm_access" => %{"roles" => []}
    }

    config = ClaimMappingConfig.for_realm("claim-test")

    {:ok, context} =
      ClaimMapping.map_verified_claims(config, "subject-1", Map.merge(base, claims))

    context
  end

  test "email_verified is true only for the JSON boolean true" do
    assert map(%{"email_verified" => true}).email_verified == true

    for value <- [
          false,
          nil,
          "true",
          "TRUE",
          "True",
          "false",
          "yes",
          1,
          0,
          1.0,
          ["true"],
          [true],
          %{"verified" => true},
          ""
        ] do
      assert map(%{"email_verified" => value}).email_verified == false,
             "#{inspect(value)} was treated as verified"
    end

    # A missing claim, and the claim under any other name.
    assert map(%{}).email_verified == false
    assert map(%{"emailVerified" => true}).email_verified == false
    assert map(%{"email_verified " => true}).email_verified == false
    assert map(%{"EMAIL_VERIFIED" => true}).email_verified == false

    # Nothing else about the context changes with the flag.
    verified = map(%{"email_verified" => true})
    unverified = map(%{"email_verified" => false})
    assert %{verified | email_verified: false} == unverified
  end

  test "an IdentityContext built without the field defaults email_verified to false" do
    context = %IdentityContext{
      external_user_id: "subject-1",
      tenant_id: nil,
      realm: "claim-test",
      roles: [],
      email: "person@example.com",
      preferred_username: "person",
      display_name: nil
    }

    assert context.email_verified == false
  end
end
