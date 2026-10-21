defmodule Letflow.Oidc.ClaimMappingPropertyTest do
  @moduledoc """
  Property-based test for `Letflow.Oidc.ClaimMapping.map_verified_claims/3`, following
  this project's established `StreamData` precedent
  (`test/letflow/process_instance_test.exs`). See `test/specs/REQ-017.md`'s "Property
  test rationale" section for why this specific property was judged worth the
  investment: SECURITY-REVIEWER/REVIEWER's sign-off rests on `resolve_claim_path/2`
  never raising regardless of claim shape, and this property exercises that guarantee
  across a much wider space of malformed/adversarial claim shapes than a fixed set of
  hand-picked examples could.

  Plain `ExUnit.Case, async: true` — no DB, no `Letflow.DataCase` (see
  `claim_mapping_test.exs`'s moduledoc for the same reasoning).
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Letflow.Oidc.ClaimMapping
  alias Letflow.Oidc.ClaimMappingConfig
  alias Letflow.Oidc.IdentityContext

  # A recursive generator producing arbitrary JSON-like values: the kind of
  # attacker-controlled shapes that could appear anywhere inside a decoded JWT claims
  # map, including in places the configured claim paths expect a string or a list.
  defp claim_value_generator do
    leaf =
      StreamData.one_of([
        StreamData.string(:printable, max_length: 20),
        StreamData.integer(),
        StreamData.boolean(),
        StreamData.constant(nil)
      ])

    StreamData.tree(leaf, fn child ->
      StreamData.one_of([
        StreamData.list_of(child, max_length: 4),
        StreamData.map_of(StreamData.string(:alphanumeric, min_length: 1, max_length: 8), child,
          max_length: 4
        )
      ])
    end)
  end

  defp claims_generator do
    StreamData.map_of(
      StreamData.string(:alphanumeric, min_length: 1, max_length: 12),
      claim_value_generator(),
      max_length: 6
    )
  end

  defp non_empty_subject_generator do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
  end

  test "for any claims map and any non-empty string sub, map_verified_claims/3 never raises and always returns a well-shaped {:ok, %IdentityContext{}}" do
    check all(
            subject <- non_empty_subject_generator(),
            claims <- claims_generator(),
            realm <- StreamData.string(:alphanumeric, min_length: 1, max_length: 12)
          ) do
      config = ClaimMappingConfig.default(realm)

      # "sub" itself may also be present (and malformed) inside claims — the function
      # must not confuse the claims-map "sub" key with its own `subject` argument, and
      # must still behave per the subject argument regardless of what's in claims.
      claims = Map.put(claims, "sub", subject)

      assert {:ok, %IdentityContext{} = ctx} =
               ClaimMapping.map_verified_claims(config, subject, claims)

      assert ctx.external_user_id == subject
      assert is_binary(ctx.realm)
      assert is_binary(ctx.email)
      assert is_binary(ctx.preferred_username)
      assert is_list(ctx.roles)
      assert Enum.all?(ctx.roles, &is_binary/1)
      assert is_nil(ctx.tenant_id) or is_binary(ctx.tenant_id)
      assert is_nil(ctx.display_name) or is_binary(ctx.display_name)
    end
  end

  test "for any claims map, an empty-string subject always returns {:error, :sub_claim_missing}, never raises" do
    check all(
            claims <- claims_generator(),
            realm <- StreamData.string(:alphanumeric, min_length: 1, max_length: 12)
          ) do
      config = ClaimMappingConfig.default(realm)

      assert {:error, :sub_claim_missing} = ClaimMapping.map_verified_claims(config, "", claims)
    end
  end
end
