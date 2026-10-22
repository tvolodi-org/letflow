defmodule Letflow.Release.PlatformAdminTokensTest do
  @moduledoc """
  GH 2579: the operator wrappers `Letflow.Release.platform_admin_token_inventory/1` and
  `Letflow.Release.reissue_platform_admin_token/4`: their printed lines (ids, counts, no token
  value), their exit contract (`halt: false` in tests) and their refusals. Spec:
  `test/specs/GH-2579.md`. The core behaviour is in
  `test/letflow/identity/platform_admin_tokens_test.exs`.

  `async: false`: the platform tenant pin is VM-global.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureIO

  alias Letflow.Identity
  alias Letflow.Identity.ApiToken
  alias Letflow.Release
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.TokenMintFixture, as: Mint

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    tenants
  end

  defp owner!(p), do: Mint.role_holder!(p.schema_name, ["PLATFORM_ADMIN"])

  defp legacy_pa_token!(p, owner) do
    {:ok, %{token: token, plaintext: plaintext}} =
      Identity.create_token(owner.id, %{roles: ["PLATFORM_ADMIN"], expires_at: nil},
        prefix: p.schema_name
      )

    {token, plaintext}
  end

  describe "platform_admin_token_inventory/1" do
    test "T7: prints one PA_TOKEN_NO_EXPIRY line, one TENANT line and one SUMMARY; a missing schema is errored and the others still run",
         %{p: p} do
      owner = owner!(p)
      {token, plaintext} = legacy_pa_token!(p, owner)
      missing = %{tenant_id: Ecto.UUID.generate(), schema_name: "tenant_gh2579_missing"}

      registrations = [%{tenant_id: p.tenant_id, schema_name: p.schema_name}, missing]

      {result, output} =
        with_io(fn ->
          Release.platform_admin_token_inventory(
            registrations: registrations,
            start: false,
            halt: false
          )
        end)

      assert {:error, %{non_expiring_platform_admin: 1, legacy_no_issuer: 1, errored: 1}} = result

      assert output =~
               "PA_TOKEN_NO_EXPIRY tenant=#{p.tenant_id} schema=#{p.schema_name} " <>
                 "token_id=#{token.id} owner_user_id=#{owner.id} issuer_user_id=legacy "

      assert output =~
               "TENANT tenant=#{p.tenant_id} schema=#{p.schema_name} non_expiring_platform_admin=1 legacy_no_issuer=1 errored=0"

      assert output =~ "TENANT tenant=#{missing.tenant_id} schema=tenant_gh2579_missing errored=1"

      assert output =~
               "SUMMARY tenants=2 non_expiring_platform_admin=1 legacy_no_issuer=1 errored=1"

      # INV-4: no value, no hash, no token name.
      refute output =~ plaintext
      refute output =~ "lf_tok_"
      refute output =~ "token-"
    end

    test "an empty fleet of tokens prints a clean SUMMARY and returns :ok", %{p: p} do
      {result, output} =
        with_io(fn ->
          Release.platform_admin_token_inventory(
            registrations: [%{tenant_id: p.tenant_id, schema_name: p.schema_name}],
            start: false,
            halt: false
          )
        end)

      assert {:ok, %{errored: 0}} = result

      assert output =~
               "SUMMARY tenants=1 non_expiring_platform_admin=0 legacy_no_issuer=0 errored=0"
    end
  end

  describe "reissue_platform_admin_token/4" do
    @tag :tmp_dir
    test "prints one REISSUE line with the file path and never the value", %{
      p: p,
      tmp_dir: tmp_dir
    } do
      owner = owner!(p)
      operator = Mint.role_holder!(p.schema_name, ["PLATFORM_ADMIN"])
      {old, old_plaintext} = legacy_pa_token!(p, owner)
      path = Path.join(tmp_dir, "new-token.txt")

      {result, output} =
        with_io(fn ->
          Release.reissue_platform_admin_token(p.tenant_id, old.id, operator.id,
            cause: "rotate legacy token",
            plaintext_file: path,
            start: false,
            halt: false
          )
        end)

      assert {:ok, done} = result

      assert output =~
               "REISSUE old_token_id=#{old.id} new_token_id=#{done.new_token_id} owner_user_id=#{owner.id}"

      assert output =~ "cause_recorded=true plaintext_file=#{path}"
      refute output =~ "lf_tok_"
      refute output =~ old_plaintext

      assert String.starts_with?(File.read!(path), "lf_tok_")
      assert Repo.get!(ApiToken, old.id, prefix: p.schema_name).revoked_at != nil
    end

    @tag :tmp_dir
    test "a refusal prints one ERROR line and changes nothing", %{p: p, tmp_dir: tmp_dir} do
      owner = owner!(p)
      operator = Mint.role_holder!(p.schema_name, ["PLATFORM_ADMIN"])
      {old, _} = legacy_pa_token!(p, owner)
      path = Path.join(tmp_dir, "new-token.txt")

      {result, output} =
        with_io(fn ->
          Release.reissue_platform_admin_token(p.tenant_id, Ecto.UUID.generate(), operator.id,
            cause: "rotate legacy token",
            plaintext_file: path,
            start: false,
            halt: false
          )
        end)

      assert {:error, :not_found} = result
      assert output == "ERROR :not_found\n"
      refute File.exists?(path)
      assert Repo.get!(ApiToken, old.id, prefix: p.schema_name).revoked_at == nil
    end
  end
end
