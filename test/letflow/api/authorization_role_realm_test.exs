defmodule Letflow.Api.AuthorizationRoleRealmTest do
  @moduledoc """
  REQ-129 — proves the role set agrees between `Letflow.Api.Authorization`
  (the authorization matrix) and `priv/keycloak/realms/bpm-default.json`
  (the realm REQ-128 created), per `decisions/0013-authorization-role-set.md`.

  This is a *proving* test, not a reconciling one: it does not change either
  source. It reads the realm file's `roles.realm` list off disk and asserts
  it is exactly equal (same members, no more, no fewer) to
  `Letflow.Api.Authorization.roles/0`. Equality both directions is
  deliberate here — unlike the SPA-side check (`web/tests/guards/role-set.spec.ts`),
  there is no expected asymmetry between the matrix and the realm: per
  decision 0013, every realm Letflow authenticates against must define all
  five roles, `AGENT_RUNNER` included, so the realm can issue it even though
  no human user is seeded with it and the SPA never gates on it.

  A role added to or removed from either side alone must fail this test —
  see `authorization_ac9_test.exs` and `authorization_test.exs` for the
  matrix's own behavioral coverage; this file only checks the two sources
  stay in lockstep.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Api.Authorization

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

  describe "realm role list vs. Letflow.Api.Authorization.roles/0" do
    test "the realm file defines exactly the matrix's role set, no more, no fewer" do
      realm_json = @realm_path |> File.read!() |> Jason.decode!()

      # Compared as strings, not atoms: `String.to_existing_atom/1` depends on
      # `Letflow.Api.Authorization` already being *loaded* (not merely
      # compiled) in this BEAM instance, which is not guaranteed by test
      # ordering or by mix's incremental-compile cache. Strings sidestep
      # that entirely and are just as precise for an equality check.
      realm_roles =
        realm_json
        |> get_in(["roles", "realm"])
        |> Enum.map(& &1["name"])
        |> Enum.sort()

      matrix_roles =
        Authorization.roles()
        |> Enum.map(&Atom.to_string/1)
        |> Enum.sort()

      assert realm_roles == matrix_roles,
             """
             The realm file's role list and Letflow.Api.Authorization.roles/0 have \
             drifted apart.

             Realm (priv/keycloak/realms/bpm-default.json): #{inspect(realm_roles)}
             Matrix (Letflow.Api.Authorization.roles/0):     #{inspect(matrix_roles)}

             Per decisions/0013-authorization-role-set.md, every realm Letflow \
             authenticates against must define all five roles the matrix defines. \
             Do not resolve this by editing this test — fix whichever source is \
             wrong, or write a new decision record if the role set itself is \
             changing.
             """
    end
  end
end
