defmodule Letflow.Routers.TenantsScriptPolicyTest do
  @moduledoc """
  GH 2534 PR 7b-2a (decision 0053 D7), design `lib/letflow/design/gh2534-7b2a-script-policy.md`
  sections 9.2 and 12: the operator's `GET /tenants/:slug/script-policy` and
  `PUT /tenants/:slug/script-policy/kill-switch`, dispatched directly into
  `Letflow.Routers.Tenants` with a hand-assigned `auth_context`.

    * AC3: a platform-tenant PLATFORM_ADMIN (OIDC) flips the PLATFORM latch; the target
      tenant's chain gets one entry with a nil actor and `actor_class: platform_operator`, the
      platform chain one entry carrying the operator id, in the same transaction; a PLATFORM_ADMIN
      of a non-platform tenant is 403; an unknown and an unprovisioned slug are the plain 404.
    * SEC F2: the GET and the PUT answer EXACTLY the `platform_policy_map/1` key set, never the
      tenant admin's reason or user id (stored on the row).
    * AC4 (route side): the operator's PUT never touches the tenant latch; a TENANT_ADMIN cannot
      reach the platform latch.
    * AC6: a token caller's PUT is 403 `api_token_not_allowed`, nothing written; its GET is 200.

  The unverifiable-platform-prefix refusal (500, nothing written) cannot be reached through the
  router once the platform gate passed (the gate and the prefix derive from the same pinned
  tenant); it is asserted at the context in `test/letflow/scripts/policy_test.exs`.

  `async: false`: the platform tenant pin is VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity
  alias Letflow.Scripts.Policy
  alias Letflow.Scripts.ScriptPolicy
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.ScriptPolicyFixture, as: SP

  @operator ["PLATFORM_ADMIN"]

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  defp call(method, path, caller, roles, body, opts \\ []) do
    conn =
      Fixture.router_conn(method, path, caller, roles, body)
      |> Plug.Conn.assign(:auth_context, %{
        user_id: Keyword.get(opts, :user_id, Ecto.UUID.generate()),
        tenant_id: caller.tenant_id,
        roles: roles,
        credential: Keyword.get(opts, :credential, :oidc)
      })
      |> Plug.Conn.assign(:trace_id, "operator-trace")

    Letflow.Routers.Tenants.call(conn, Letflow.Routers.Tenants.init([]))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp detail(conn), do: json(conn)["detail"]
  defp stored(fixture), do: Repo.get!(ScriptPolicy, 1, prefix: fixture.schema_name)

  defp assert_platform_shape(body) do
    assert body |> Map.keys() |> Enum.sort() == ["kill_switch_on", "platform", "tenant"]
    assert body["platform"] |> Map.keys() |> Enum.sort() == ["on", "reason", "set_at"]
    assert body["tenant"] |> Map.keys() |> Enum.sort() == ["on", "set_at"]
  end

  describe "AC3: the platform latch" do
    test "the operator flips it: two audit entries (nil-actor tenant entry, operator platform entry); exact key set on GET and PUT without the tenant's reason or user id",
         ctx do
      tenant_admin = Ecto.UUID.generate()

      assert {:ok, _} =
               Policy.set_tenant_kill_switch(
                 ctx.a.schema_name,
                 true,
                 "tenant private reason",
                 SP.actor(tenant_admin)
               )

      operator = Ecto.UUID.generate()
      path = "/#{ctx.a.tenant.slug}/script-policy/kill-switch"

      conn =
        call(:put, path, ctx.p, @operator, %{"on" => true, "reason" => "incident 42"},
          user_id: operator
        )

      assert conn.status == 200, conn.resp_body
      put_body = json(conn)
      assert_platform_shape(put_body)
      assert put_body["kill_switch_on"] == true
      assert put_body["platform"]["on"] == true
      assert put_body["platform"]["reason"] == "incident 42"
      assert put_body["tenant"]["on"] == true

      get_conn = call(:get, "/#{ctx.a.tenant.slug}/script-policy", ctx.p, @operator, nil)
      assert get_conn.status == 200
      assert_platform_shape(json(get_conn))
      assert json(get_conn) == put_body

      for resp <- [conn.resp_body, get_conn.resp_body] do
        refute resp =~ "tenant private reason"
        refute resp =~ tenant_admin
      end

      row = stored(ctx.a)
      assert row.platform_kill_switch
      assert row.platform_kill_switch_reason == "incident 42"
      # the tenant latch is untouched
      assert row.tenant_kill_switch
      assert row.tenant_kill_switch_reason == "tenant private reason"
      assert row.tenant_kill_switch_set_by == tenant_admin

      assert [tenant_entry] =
               SP.entries(ctx.a.schema_name, "script_policy.platform_kill_switch_set")

      assert tenant_entry.actor_id == nil
      assert tenant_entry.trace_id == nil
      assert tenant_entry.after_state["actor_class"] == "platform_operator"
      assert tenant_entry.after_state["platform_kill_switch"] == true
      refute inspect(tenant_entry) =~ operator

      assert [platform_entry] =
               SP.entries(ctx.p.schema_name, "platform.tenant_script_kill_switch.set")

      assert platform_entry.actor_id == operator
      assert platform_entry.trace_id == "operator-trace"

      assert {platform_entry.resource_type, platform_entry.resource_id} ==
               {"tenant", ctx.a.tenant_id}

      assert platform_entry.after_state["tenant_id"] == ctx.a.tenant_id

      # no-op: 200, nothing more audited
      noop = call(:put, path, ctx.p, @operator, %{"on" => true, "reason" => "again"})
      assert noop.status == 200
      assert length(SP.entries(ctx.a.schema_name, "script_policy.platform_kill_switch_set")) == 1
      assert length(SP.entries(ctx.p.schema_name, "platform.tenant_script_kill_switch.set")) == 1

      # the operator clears only its own latch: the tenant's stop holds
      off = call(:put, path, ctx.p, @operator, %{"on" => false, "reason" => "resolved"})
      assert off.status == 200
      assert json(off)["kill_switch_on"] == true
      assert json(off)["platform"]["on"] == false
      assert stored(ctx.a).tenant_kill_switch
    end

    test "validation: invalid reason and non-boolean on are 422, nothing written", ctx do
      path = "/#{ctx.a.tenant.slug}/script-policy/kill-switch"

      for {body, code} <- [
            {%{"on" => true}, "invalid_reason"},
            {%{"on" => true, "reason" => " "}, "invalid_reason"},
            {%{"on" => "yes", "reason" => "r"}, "invalid_state"}
          ] do
        conn = call(:put, path, ctx.p, @operator, body)
        assert {conn.status, detail(conn)} == {422, code}, inspect(body)
      end

      refute stored(ctx.a).platform_kill_switch
      assert SP.policy_entries(ctx.a.schema_name) == []
    end

    test "a PLATFORM_ADMIN of a non-platform tenant and a TENANT_ADMIN are 403 on both routes",
         ctx do
      for {caller, roles} <- [{ctx.a, @operator}, {ctx.b, @operator}, {ctx.a, ["TENANT_ADMIN"]}],
          {method, path, body} <- [
            {:get, "/#{ctx.a.tenant.slug}/script-policy", nil},
            {:put, "/#{ctx.a.tenant.slug}/script-policy/kill-switch",
             %{"on" => true, "reason" => "r"}}
          ] do
        assert call(method, path, caller, roles, body).status == 403,
               "#{inspect(roles)} of #{caller.tenant.slug}: #{method} #{path}"
      end

      refute stored(ctx.a).platform_kill_switch
      assert SP.policy_entries(ctx.a.schema_name) == []
    end

    test "a provisioned tenant without its policy row is a 500 on the GET and the PUT, nothing written",
         ctx do
      schema = ctx.a.schema_name
      Repo.query!(~s(ALTER TABLE "#{schema}".script_policy DISABLE TRIGGER script_policy_guard))

      try do
        Repo.delete_all(ScriptPolicy, prefix: schema)

        assert call(:get, "/#{ctx.a.tenant.slug}/script-policy", ctx.p, @operator, nil).status ==
                 500

        put =
          call(
            :put,
            "/#{ctx.a.tenant.slug}/script-policy/kill-switch",
            ctx.p,
            @operator,
            %{"on" => true, "reason" => "r"}
          )

        assert put.status == 500
        assert SP.policy_entries(schema) == []
        assert SP.entries(ctx.p.schema_name, "platform.tenant_script_kill_switch.set") == []
      after
        Repo.query!(
          ~s|INSERT INTO "#{schema}".script_policy (id, inserted_at, updated_at) VALUES (1, now(), now()) ON CONFLICT DO NOTHING|
        )

        Repo.query!(~s(ALTER TABLE "#{schema}".script_policy ENABLE TRIGGER script_policy_guard))
      end
    end

    test "an unknown slug and an unprovisioned tenant are the plain 404", ctx do
      {:ok, unprovisioned} =
        Identity.create_tenant(%{
          slug: "gh2534-unprov-#{System.unique_integer([:positive])}",
          display_name: "Unprovisioned"
        })

      responses =
        for slug <- ["no-such-tenant-#{System.unique_integer([:positive])}", unprovisioned.slug],
            {method, path, body} <- [
              {:get, "/#{slug}/script-policy", nil},
              {:put, "/#{slug}/script-policy/kill-switch", %{"on" => true, "reason" => "r"}}
            ] do
          conn = call(method, path, ctx.p, @operator, body)
          {conn.status, conn.resp_body}
        end

      [{404, same} | _] = responses
      assert Enum.all?(responses, &(&1 == {404, same})), inspect(responses)
    end
  end

  describe "AC6: API-token operator" do
    test "the PUT is 403 api_token_not_allowed and writes nothing; the GET is allowed", ctx do
      token = [credential: :api_token]

      conn =
        call(
          :put,
          "/#{ctx.a.tenant.slug}/script-policy/kill-switch",
          ctx.p,
          @operator,
          %{"on" => true, "reason" => "r"},
          token
        )

      assert {conn.status, detail(conn)} == {403, "api_token_not_allowed"}
      refute stored(ctx.a).platform_kill_switch
      assert SP.policy_entries(ctx.a.schema_name) == []
      assert SP.entries(ctx.p.schema_name, "platform.tenant_script_kill_switch.set") == []

      assert call(:get, "/#{ctx.a.tenant.slug}/script-policy", ctx.p, @operator, nil, token).status ==
               200
    end
  end
end
