defmodule Letflow.Routers.Gh2573RevokeTokenErrorsTest do
  @moduledoc """
  GH 2573 (INV-8): `DELETE /tokens/:id` answers a typed response for every shape
  `Identity.revoke_token/2` returns; none reaches a `CaseClauseError`.

  The changeset and audit-failure shapes have no HTTP trigger (the revoke changeset casts one
  server-built timestamp; an audit failure needs a tenant schema that is not `tenant_<hex>`),
  so the context is forced into the audit failure and the handler's mapping is exercised
  through `Letflow.Routers.Identity.render_revoke_result/2` for every shape.

  `async: false`: the fixture flips the sandbox to `:auto` and the platform pin is VM-global.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.Identity
  alias Letflow.Identity.ApiToken
  alias Letflow.Routers.Identity, as: IdentityRouter
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.TokenMintFixture, as: Mint

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  defp conn(fx), do: Fixture.router_conn(:delete, "/tokens/x", fx, ["TENANT_ADMIN"], nil)

  defp token!(fx) do
    owner = Mint.role_holder!(fx.schema_name, [])

    {:ok, %{token: token}} =
      Identity.create_token(owner.id, %{roles: ["TASK_WORKER"], expires_at: nil},
        prefix: fx.schema_name
      )

    token
  end

  defp with_renamed_schema(schema, fun) do
    "tenant_" <> hex = schema
    renamed = "gh2573_" <> hex
    Repo.query!(~s|ALTER SCHEMA "#{schema}" RENAME TO "#{renamed}"|)

    try do
      fun.(renamed)
    after
      Repo.query!(~s|ALTER SCHEMA "#{renamed}" RENAME TO "#{schema}"|)
    end
  end

  describe "Identity.revoke_token/2" do
    test "a non-raising audit failure is {:error, {:audit_failed, reason}} and nothing is revoked",
         %{a: a} do
      token = token!(a)

      result =
        with_renamed_schema(a.schema_name, fn renamed ->
          Identity.revoke_token(token.id, prefix: renamed)
        end)

      assert result == {:error, {:audit_failed, :invalid_schema_name}}
      assert Repo.get!(ApiToken, token.id, prefix: a.schema_name).revoked_at == nil
    end
  end

  describe "Identity.mint_token/4 (POST /tokens)" do
    test "a non-raising audit failure is {:error, {:audit_failed, reason}} and no row is inserted",
         %{a: a} do
      issuer = Mint.role_holder!(a.schema_name, ["TENANT_ADMIN", "TASK_WORKER"])
      target = Mint.role_holder!(a.schema_name, ["TASK_WORKER"])
      before_count = Repo.aggregate(ApiToken, :count, :id, prefix: a.schema_name)

      result =
        with_renamed_schema(a.schema_name, fn renamed ->
          Identity.mint_token(
            issuer.id,
            target.id,
            %{roles: ["TASK_WORKER"], expires_at: nil},
            prefix: renamed
          )
        end)

      assert result == {:error, {:audit_failed, :invalid_schema_name}}
      assert Repo.aggregate(ApiToken, :count, :id, prefix: a.schema_name) == before_count
    end

    test "render_mint_result: {:audit_failed, _} -> 500, reason not leaked", %{a: a} do
      log =
        capture_log(fn ->
          conn = IdentityRouter.render_mint_result(conn(a), {:error, {:audit_failed, :secret}})
          assert conn.status == 500
          refute conn.resp_body =~ "secret"
        end)

      refute log =~ "CaseClauseError"
    end

    test "render_mint_result: changeset -> 422 validation failed", %{a: a} do
      changeset = ApiToken.revoke_changeset(%ApiToken{}, %{revoked_at: "not a date"})
      conn = IdentityRouter.render_mint_result(conn(a), {:error, changeset})
      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["detail"] == "validation failed"
    end
  end

  describe "DELETE /tokens/:id handler, one case per return shape" do
    test "{:ok, token} -> 200", %{a: a} do
      {:ok, revoked} = Identity.revoke_token(token!(a).id, prefix: a.schema_name)
      conn = IdentityRouter.render_revoke_result(conn(a), {:ok, revoked})
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["status"] == "revoked"
    end

    test "{:error, :not_found} -> 404", %{a: a} do
      assert IdentityRouter.render_revoke_result(conn(a), {:error, :not_found}).status == 404
    end

    test "{:error, :last_tenant_wide_admin} -> 409", %{a: a} do
      conn = IdentityRouter.render_revoke_result(conn(a), {:error, :last_tenant_wide_admin})
      assert conn.status == 409
    end

    test "{:error, changeset} -> 422 with a stable code", %{a: a} do
      changeset = ApiToken.revoke_changeset(%ApiToken{}, %{revoked_at: "not a date"})
      refute changeset.valid?

      conn = IdentityRouter.render_revoke_result(conn(a), {:error, changeset})
      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["detail"] == "validation failed"
    end

    test "{:error, {:audit_failed, _}} -> 500, reason not leaked", %{a: a} do
      log =
        capture_log(fn ->
          conn = IdentityRouter.render_revoke_result(conn(a), {:error, {:audit_failed, :secret}})
          assert conn.status == 500
          refute conn.resp_body =~ "secret"
        end)

      refute log =~ "CaseClauseError"
    end

    test "{:error, {:transaction_failed, _}} -> 500", %{a: a} do
      conn =
        IdentityRouter.render_revoke_result(
          conn(a),
          {:error, {:transaction_failed, %RuntimeError{message: "boom"}}}
        )

      assert conn.status == 500
      refute conn.resp_body =~ "boom"
    end
  end
end
