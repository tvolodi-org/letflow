defmodule Letflow.Routers.SharedStockAccessTest do
  @moduledoc """
  REQ-858 / GH #4573 (decision 0091 sections 3 to 5): `GET`, `POST` and `DELETE /shared-stock-access`
  through `Letflow.Routers.Identity` (the real Authorize plug) over provisioned tenant schemas.
  IDs follow the acceptance criteria: C1 create and status, C2 given value and hash, C3 rotate and
  revoke, C4 not enabled, C5 refusals and cross-tenant (INV-10), C6 audit and no value elsewhere,
  C7 matrix and manifest pins.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test
  import Ecto.Query, only: [from: 2]

  alias Letflow.Api.Scope.Grants
  alias Letflow.Audit.Entry
  alias Letflow.Repo
  alias Letflow.SharedStockAccess.Credential
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Identity.init([])
  @good String.duplicate("ab12", 16)

  setup do
    a = TenantFixture.provisioned_tenant!(slug_prefix: "t2088-a")
    b = TenantFixture.provisioned_tenant!(slug_prefix: "t2088-b")
    original = Application.fetch_env(:letflow, :shared_stock_access_tenants)

    on_exit(fn ->
      case original do
        {:ok, v} -> Application.put_env(:letflow, :shared_stock_access_tenants, v)
        :error -> Application.delete_env(:letflow, :shared_stock_access_tenants)
      end
    end)

    enable!([a, b])
    {:ok, a: a, b: b}
  end

  defp enable!(fxs),
    do:
      Application.put_env(:letflow, :shared_stock_access_tenants, Enum.map(fxs, & &1.tenant.slug))

  defp wide(uid),
    do: %Grants{
      user_id: uid,
      rows_by_role: %{
        "TENANT_ADMIN" => [%{principal_type: :group, tenant_wide: true, scope_node_id: nil}]
      }
    }

  defp call(method, fx, opts \\ []) do
    uid = Keyword.get(opts, :user_id, Ecto.UUID.generate())

    auth = %{
      user_id: uid,
      tenant_id: fx.tenant_id,
      roles: Keyword.get(opts, :roles, ["TENANT_ADMIN"]),
      credential: Keyword.get(opts, :credential, :oidc),
      scope_grants: wide(uid)
    }

    conn(method, "/shared-stock-access")
    |> Map.put(:body_params, Keyword.get(opts, :body, %{}))
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, auth)
    |> assign(:trace_id, "t2088-trace")
    |> Letflow.Routers.Identity.call(@opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp rows(fx), do: Repo.all(Credential, prefix: fx.schema_name)
  defp active(fx), do: Enum.find(rows(fx), &is_nil(&1.revoked_at))
  defp hash(v), do: Base.encode16(:crypto.hash(:sha256, v), case: :lower)

  defp audits(fx),
    do:
      Repo.all(from(e in Entry, where: like(e.action, "shared_stock_access.%")),
        prefix: fx.schema_name
      )

  describe "C1 create and status" do
    test "C1 empty POST answers 201 with the value once; GET shows status without value or hash",
         %{a: a} do
      uid = Ecto.UUID.generate()
      conn = call(:post, a, user_id: uid)
      assert conn.status == 201
      assert %{"value" => value} = json(conn)
      assert value =~ ~r/\A[0-9a-f]{64}\z/

      get = call(:get, a)
      assert get.status == 200
      body = json(get)
      assert %{"enabled" => true, "exists" => true, "created_by" => ^uid} = body
      assert is_binary(body["created_at"])
      assert body["rotated_at"] == nil
      refute get.resp_body =~ value
      refute get.resp_body =~ hash(value)
      refute Map.has_key?(body, "value")
      refute Map.has_key?(body, "token_hash")
    end

    test "C1 GET with nothing answers exists false", %{a: a} do
      assert %{"enabled" => true, "exists" => false, "created_at" => nil} =
               a |> then(&call(:get, &1)) |> json()
    end
  end

  describe "C2 given value" do
    test "C2 a given value is stored as its SHA-256 hex only", %{a: a} do
      conn = call(:post, a, body: %{"value" => @good})
      assert conn.status == 201
      assert json(conn)["value"] == @good
      row = active(a)
      assert row.token_hash == Base.encode16(:crypto.hash(:sha256, @good), case: :lower)
      refute inspect(Map.from_struct(row)) =~ @good
    end

    test "C2 too short, with space, control character, non-ASCII or non-string: 422, nothing changes",
         %{a: a} do
      for bad <- [
            "short",
            String.duplicate("a", 31),
            String.duplicate("a", 32),
            String.duplicate("a", 63),
            String.duplicate("g", 64),
            String.duplicate("!", 64),
            String.duplicate("a", 16) <> " " <> String.duplicate("a", 20),
            String.duplicate("a", 40) <> "\n",
            String.duplicate("a", 40) <> <<0>>,
            String.duplicate("я", 40),
            String.duplicate("a", 257),
            12345,
            nil
          ] do
        conn = call(:post, a, body: %{"value" => bad})
        assert conn.status == 422
        assert json(conn)["detail"] == "shared_access_value_invalid"
      end

      assert rows(a) == []
      assert audits(a) == []
    end
  end

  describe "C3 rotate and revoke" do
    test "C3 a second POST rotates; created_at kept, rotated_at set, only the new hash stays",
         %{a: a} do
      first = call(:post, a, body: %{"value" => @good}) |> json()
      before_row = active(a)
      second = call(:post, a) |> json()
      assert second["value"] != first["value"]
      assert [row] = rows(a)
      assert row.id == before_row.id
      assert row.token_hash == hash(second["value"])
      refute row.token_hash == hash(@good)
      assert row.created_at == before_row.created_at
      assert row.rotated_at
      assert row.actor_id == before_row.actor_id
      assert %{"rotated_at" => rotated} = call(:get, a) |> json()
      assert is_binary(rotated)
    end

    test "C3 DELETE answers 204, GET shows exists false, a second DELETE answers 404", %{a: a} do
      assert call(:delete, a).status == 404
      call(:post, a)
      assert call(:delete, a).status == 204
      assert %{"exists" => false} = call(:get, a) |> json()
      assert call(:delete, a).status == 404
      # the revoked row stays as an audit anchor; a new create starts a new row
      assert [%Credential{revoked_at: %DateTime{}}] = rows(a)
      assert call(:post, a).status == 201
      assert length(rows(a)) == 2
      assert active(a)
    end
  end

  describe "C4 not enabled" do
    test "C4 unset, empty or another slug: POST 409, nothing written, GET enabled false",
         %{a: a, b: b} do
      for setting <- [nil, [], [b.tenant.slug]] do
        if setting,
          do: Application.put_env(:letflow, :shared_stock_access_tenants, setting),
          else: Application.delete_env(:letflow, :shared_stock_access_tenants)

        conn = call(:post, a)
        assert conn.status == 409
        assert json(conn)["detail"] == "shared_access_not_enabled"
        assert rows(a) == []
        assert audits(a) == []
        assert %{"enabled" => false, "exists" => false} = call(:get, a) |> json()
      end
    end

    test "C4 the setting text is parsed with trimming and empty entries dropped" do
      assert Letflow.SharedStockAccess.parse_tenants(nil) == []
      assert Letflow.SharedStockAccess.parse_tenants("") == []
      assert Letflow.SharedStockAccess.parse_tenants(" a-b , ,c ") == ["a-b", "c"]
    end

    test "C4 delisting leaves the row; DELETE still cleans up, GET says enabled false", %{a: a} do
      call(:post, a)
      Application.put_env(:letflow, :shared_stock_access_tenants, [])
      assert %{"enabled" => false, "exists" => true} = call(:get, a) |> json()
      assert call(:delete, a).status == 204
    end
  end

  describe "C5 refusals and cross-tenant" do
    test "C5 other roles get 403 on all three routes, nothing is written", %{a: a} do
      for role <- ["STOREKEEPER", "TENANT_AUDITOR", "PROCESS_OPERATOR"],
          method <- [:get, :post, :delete] do
        conn = call(method, a, roles: [role])
        assert conn.status == 403, "#{role} #{method}"
      end

      assert rows(a) == []
    end

    test "C5 an API token of a TENANT_ADMIN gets 403 on all three routes", %{a: a} do
      call(:post, a)

      for method <- [:get, :post, :delete] do
        assert call(method, a, credential: :api_token).status == 403
      end

      assert active(a)
    end

    test "C5 a caller without a credential key is refused too", %{a: a} do
      conn =
        conn(:get, "/shared-stock-access")
        |> assign(:auth_context, %{
          user_id: Ecto.UUID.generate(),
          tenant_id: a.tenant_id,
          roles: ["TENANT_ADMIN"]
        })
        |> Letflow.Routers.Identity.call(@opts)

      assert conn.status == 403
    end

    test "C5 INV-10: tenant B sees and changes only B's state while A has one", %{a: a, b: b} do
      call(:post, a, body: %{"value" => @good})
      a_before = active(a)

      assert %{"exists" => false} = call(:get, b) |> json()
      assert call(:delete, b).status == 404
      other = String.duplicate("cd34", 16)
      assert call(:post, b, body: %{"value" => other}).status == 201
      assert call(:delete, b).status == 204

      assert active(a) == a_before
      assert active(a).token_hash == hash(@good)
      assert %{"exists" => true} = call(:get, a) |> json()
    end

    test "C5 TokensManage stays with PLATFORM_ADMIN and TENANT_ADMIN only" do
      holders =
        for role <- Letflow.Api.Authorization.roles(),
            Letflow.Api.Authorization.evaluate_access(
              %Letflow.Api.Authorization.AccessContext{
                user_id: Ecto.UUID.generate(),
                roles: [role],
                platform_tenant?: true
              },
              :TokensManage
            ).kind != :Deny403,
            do: role

      assert Enum.sort(holders) == [:PLATFORM_ADMIN, :TENANT_ADMIN]
    end
  end

  describe "C6 audit and the value" do
    test "C6 create, rotate and revoke each write one audit entry; the value is only in the 201 body",
         %{a: a} do
      uid = Ecto.UUID.generate()

      {{created, rotated, revoked, gets}, log} =
        with_log(fn ->
          created = call(:post, a, user_id: uid, body: %{"value" => @good})
          g1 = call(:get, a, user_id: uid)
          rotated = call(:post, a, user_id: uid)
          g2 = call(:get, a, user_id: uid)
          revoked = call(:delete, a, user_id: uid)
          {created, rotated, revoked, [g1, g2]}
        end)

      assert [%{"value" => v1}, %{"value" => v2}] = [json(created), json(rotated)]
      assert revoked.status == 204

      entries = audits(a) |> Enum.sort_by(& &1.timestamp)

      assert Enum.map(entries, & &1.action) == [
               "shared_stock_access.created",
               "shared_stock_access.rotated",
               "shared_stock_access.revoked"
             ]

      assert Enum.all?(entries, &(&1.actor_id == uid and &1.trace_id == "t2088-trace"))

      dump = inspect(Repo.all(Entry, prefix: a.schema_name), limit: :infinity)

      for secret <- [v1, v2, hash(v1), hash(v2)] do
        refute dump =~ secret
        # the Ecto debug SQL log carries the stored hash as a parameter (never the value)
        if secret in [v1, v2], do: refute(log =~ secret)
        for g <- gets, do: refute(g.resp_body =~ secret)
        refute revoked.resp_body =~ secret
      end

      assert created.resp_body =~ v1
    end

    test "C6 an audit failure rolls the write back and is {:error, :failed}", %{a: a} do
      "tenant_" <> hex = a.schema_name
      renamed = "t2088_" <> hex

      result =
        try do
          Repo.query!(~s|ALTER SCHEMA "#{a.schema_name}" RENAME TO "#{renamed}"|)
          # the credential table is reachable only under the renamed schema: use the context
          Letflow.SharedStockAccess.put(renamed, a.tenant.slug, %{}, %{
            user_id: Ecto.UUID.generate(),
            trace_id: nil
          })
        after
          Repo.query!(~s|ALTER SCHEMA "#{renamed}" RENAME TO "#{a.schema_name}"|)
        end

      assert result == {:error, :failed}
      assert rows(a) == []
    end
  end

  describe "C7 manifest" do
    test "C7 the migration is registered and the table has the active-row unique index", %{a: a} do
      assert Enum.any?(
               Letflow.TenantProvisioning.tenant_scoped_migrations(),
               &match?(
                 {20_261_117_400_001, Letflow.Repo.Migrations.CreateSharedStockAccess},
                 &1
               )
             )

      call(:post, a)
      row = active(a)

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(
          %Credential{
            token_hash: hash("x"),
            actor_id: Ecto.UUID.generate(),
            created_by_user_id: Ecto.UUID.generate(),
            created_at: DateTime.utc_now()
          },
          prefix: a.schema_name
        )
      end

      assert active(a).id == row.id
    end
  end
end
