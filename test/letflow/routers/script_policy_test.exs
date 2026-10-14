defmodule Letflow.Routers.ScriptPolicyTest do
  @moduledoc """
  GH 2534 PR 7b-2a (decision 0053 D5, D7; advisor Q3), design
  `lib/letflow/design/gh2534-7b2a-script-policy.md` sections 9.1 and 12: the tenant's
  `/script-policy` routes, dispatched directly into the router with a hand-assigned
  `auth_context` (the style of `script_rules_test.exs`).

    * AC2: the tenant latch (OIDC TENANT_ADMIN): stored set_by/set_at/reason, one audit entry
      in the same transaction; reason and `on` validation; a no-op writes and audits nothing.
    * AC5 (route level): while on, dry-run and publish answer 409 `scripts_disabled` (no
      dry-run audit); draft create/save/discard, retire and revoke still succeed.
    * AC6: every write via an API token is 403 `api_token_not_allowed`, nothing written; reads
      via a token are allowed.
    * AC7: readable masters set (201 / 200 unchanged), unknown, inactive and restricted types,
      the 201st flag, clear of an unknown type, clear listing and auditing the references.
    * AC12: TENANT_ADMIN reads and writes; PROCESS_DESIGNER reads only; every other tenant
      role 403 on all five routes.
    * Responses equal the allowlist maps exactly (no extra keys); a missing policy row is 500.

  `async: false`: the platform tenant pin is VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.Scripts
  alias Letflow.Scripts.Policy
  alias Letflow.Scripts.ReadableMaster
  alias Letflow.Scripts.ScriptPolicy
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.ScriptPolicyFixture, as: SP

  @admin ["TENANT_ADMIN"]
  @designer ["PROCESS_DESIGNER"]
  @trace "platform-scope-test-trace-id"

  # GH 2534 7b-2b added the sod object (S8: no admin count).
  @policy_keys ["kill_switch_on", "platform", "sod", "tenant"]
  @tenant_keys ["on", "reason", "set_at", "set_by"]
  @platform_keys ["on", "reason", "set_at"]
  @master_keys ["entity_type", "reason", "set_at", "set_by"]

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp call(router, method, path, fixture, roles, body, opts) do
    conn =
      Fixture.router_conn(method, path, fixture, roles, body)
      |> Plug.Conn.assign(:auth_context, %{
        user_id: Keyword.get(opts, :user_id, Ecto.UUID.generate()),
        tenant_id: fixture.tenant_id,
        roles: roles,
        credential: Keyword.get(opts, :credential, :oidc)
      })

    router.call(conn, router.init([]))
  end

  defp policy_call(method, path, fixture, roles, body, opts \\ []),
    do: call(Letflow.Routers.ScriptPolicy, method, path, fixture, roles, body, opts)

  defp rules_call(method, path, fixture, roles, body, opts \\ []),
    do: call(Letflow.Routers.ScriptRules, method, path, fixture, roles, body, opts)

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp detail(conn), do: json(conn)["detail"]
  defp keys(map), do: map |> Map.keys() |> Enum.sort()

  defp assert_policy_shape(map) do
    assert keys(map) == @policy_keys
    assert keys(map["tenant"]) == @tenant_keys
    assert keys(map["platform"]) == @platform_keys
  end

  defp stored(fixture), do: Repo.get!(ScriptPolicy, 1, prefix: fixture.schema_name)

  defp key, do: "rule_#{System.unique_integer([:positive])}"

  @plain_manifest %{
    "input_schema" => %{"type" => "object", "properties" => %{"x" => %{"type" => "integer"}}},
    "output_schema" => %{"type" => "object", "properties" => %{"y" => %{"type" => "integer"}}},
    "fail_codes" => []
  }

  defp rule_body(manifest \\ @plain_manifest, source \\ "return {y = 1}", cases \\ nil) do
    %{
      "hook_kind" => "service_task",
      "source" => source,
      "manifest" => manifest,
      "test_cases" =>
        cases ||
          [%{"name" => "one", "input" => %{"x" => 1}, "expect" => %{"output" => %{"y" => 1}}}]
    }
  end

  defp create_rule!(fixture, k, body \\ rule_body()) do
    conn = rules_call(:post, "/#{k}/versions", fixture, @designer, body)
    assert conn.status == 201, conn.resp_body
    json(conn)
  end

  defp publish_rule!(fixture, k, sha) do
    conn = rules_call(:post, "/#{k}/versions/1/publish", fixture, @admin, %{"sha256" => sha})
    assert conn.status == 200, conn.resp_body
    json(conn)
  end

  # ── GET / and AC2 ──────────────────────────────────────────────────────────

  describe "AC2: the tenant latch" do
    test "GET / answers the allowlist shape with both latches off", ctx do
      conn = policy_call(:get, "/", ctx.a, @admin, nil)
      assert conn.status == 200
      body = json(conn)
      assert_policy_shape(body)
      assert body["kill_switch_on"] == false
      assert body["tenant"] == %{"on" => false, "set_by" => nil, "set_at" => nil, "reason" => nil}
      assert body["platform"] == %{"on" => false, "set_at" => nil, "reason" => nil}
    end

    test "an OIDC TENANT_ADMIN flips the latch: stored, audited once; a no-op is 200 with no audit",
         ctx do
      user = Ecto.UUID.generate()

      conn =
        policy_call(:put, "/kill-switch", ctx.a, @admin, %{"on" => true, "reason" => "incident"},
          user_id: user
        )

      assert conn.status == 200, conn.resp_body
      body = json(conn)
      assert_policy_shape(body)
      assert body["kill_switch_on"] == true
      assert body["tenant"]["on"] == true
      assert body["tenant"]["set_by"] == user
      assert body["tenant"]["reason"] == "incident"
      assert is_binary(body["tenant"]["set_at"])

      row = stored(ctx.a)
      assert row.tenant_kill_switch
      assert row.tenant_kill_switch_set_by == user
      assert row.tenant_kill_switch_reason == "incident"

      assert [entry] = SP.policy_entries(ctx.a.schema_name)
      assert entry.action == "script_policy.kill_switch_set"
      assert entry.actor_id == user
      assert entry.trace_id == @trace
      assert {entry.resource_type, entry.resource_id} == {"script_policy", "1"}
      assert entry.before_state == %{"tenant_kill_switch" => false}

      assert entry.after_state == %{
               "tenant_kill_switch" => true,
               "reason" => "incident",
               "effective" => true
             }

      noop =
        policy_call(:put, "/kill-switch", ctx.a, @admin, %{"on" => true, "reason" => "again"})

      assert noop.status == 200
      assert json(noop)["tenant"]["reason"] == "incident"
      assert length(SP.policy_entries(ctx.a.schema_name)) == 1

      off =
        policy_call(:put, "/kill-switch", ctx.a, @admin, %{"on" => false, "reason" => "fixed"})

      assert off.status == 200
      assert json(off)["kill_switch_on"] == false
      assert length(SP.policy_entries(ctx.a.schema_name)) == 2
    end

    test "reason missing, blank, over 500 or with control characters is 422 invalid_reason; a non-boolean on is 422 invalid_state; nothing written",
         ctx do
      for reason <- [
            nil,
            "",
            "   ",
            String.duplicate("r", 501),
            "a\u0000b",
            "tab\tinside",
            "line\u2028break",
            7
          ] do
        body = if reason == nil, do: %{"on" => true}, else: %{"on" => true, "reason" => reason}
        conn = policy_call(:put, "/kill-switch", ctx.a, @admin, body)
        assert {conn.status, detail(conn)} == {422, "invalid_reason"}, inspect(reason)
      end

      for on <- ["true", 1, nil] do
        conn = policy_call(:put, "/kill-switch", ctx.a, @admin, %{"on" => on, "reason" => "r"})
        assert {conn.status, detail(conn)} == {422, "invalid_state"}, inspect(on)
      end

      refute stored(ctx.a).tenant_kill_switch
      assert SP.policy_entries(ctx.a.schema_name) == []
    end

    test "a missing policy row is a 500 on GET and on the PUT (never fabricated, never a 404), nothing audited",
         ctx do
      schema = ctx.a.schema_name
      Repo.query!(~s(ALTER TABLE "#{schema}".script_policy DISABLE TRIGGER script_policy_guard))

      try do
        Repo.delete_all(ScriptPolicy, prefix: schema)
        assert policy_call(:get, "/", ctx.a, @admin, nil).status == 500

        assert policy_call(:put, "/kill-switch", ctx.a, @admin, %{"on" => true, "reason" => "r"}).status ==
                 500

        assert SP.policy_entries(schema) == []
      after
        Repo.query!(
          ~s|INSERT INTO "#{schema}".script_policy (id, inserted_at, updated_at) VALUES (1, now(), now()) ON CONFLICT DO NOTHING|
        )

        Repo.query!(~s(ALTER TABLE "#{schema}".script_policy ENABLE TRIGGER script_policy_guard))
      end
    end
  end

  # ── AC5 (route level) ──────────────────────────────────────────────────────

  describe "AC5: while the kill switch is on" do
    test "dry-run and publish are 409 scripts_disabled; drafts, retire and revoke succeed", ctx do
      published = key()
      v1 = create_rule!(ctx.a, published)
      publish_rule!(ctx.a, published, v1["sha256"])
      to_revoke = key()
      v2 = create_rule!(ctx.a, to_revoke)
      publish_rule!(ctx.a, to_revoke, v2["sha256"])
      draft = key()
      d1 = create_rule!(ctx.a, draft)

      assert policy_call(:put, "/kill-switch", ctx.a, @admin, %{"on" => true, "reason" => "stop"}).status ==
               200

      dry =
        rules_call(:post, "/#{draft}/dry-run", ctx.a, @designer, %{
          "version" => 1,
          "input" => %{"x" => 1}
        })

      assert {dry.status, detail(dry)} == {409, "scripts_disabled"}

      pub =
        rules_call(:post, "/#{draft}/versions/1/publish", ctx.a, @admin, %{
          "sha256" => d1["sha256"]
        })

      assert {pub.status, detail(pub)} == {409, "scripts_disabled"}

      assert Repo.all(
               from(e in Entry, where: e.action == "script_rule.dry_run"),
               prefix: ctx.a.schema_name
             ) == []

      # allowed: create, save, discard, retire, revoke
      other = key()
      create_rule!(ctx.a, other)
      assert rules_call(:put, "/#{other}/versions/1", ctx.a, @designer, rule_body()).status == 200
      assert rules_call(:delete, "/#{other}/versions/1", ctx.a, @designer, nil).status == 204

      assert rules_call(:post, "/#{published}/versions/1/retire", ctx.a, @admin, %{
               "reason" => "r"
             }).status ==
               200

      assert rules_call(:post, "/#{to_revoke}/versions/1/revoke", ctx.a, @admin, %{
               "reason" => "r"
             }).status ==
               200

      # off again: dry-run runs
      assert policy_call(:put, "/kill-switch", ctx.a, @admin, %{"on" => false, "reason" => "ok"}).status ==
               200

      assert rules_call(:post, "/#{draft}/dry-run", ctx.a, @designer, %{
               "version" => 1,
               "input" => %{"x" => 1}
             }).status == 200
    end

    test "dry-run passes the body's reads fixture to the script", ctx do
      schema = ctx.a.schema_name
      SP.active_definition!(schema, "customer")
      SP.flag!(schema, "customer")
      k = key()

      source =
        "local r = ctx.input.reads.cust[1] if r == nil then return {name = 'none'} end return {name = r.name}"

      cases = [
        %{
          "name" => "c",
          "input" => %{"cid" => "a"},
          "expect" => %{"output" => %{"name" => "none"}}
        }
      ]

      create_rule!(
        ctx.a,
        k,
        rule_body(SP.manifest([SP.id_read("cust", "customer")]), source, cases)
      )

      conn =
        rules_call(:post, "/#{k}/dry-run", ctx.a, @designer, %{
          "version" => 1,
          "input" => %{"cid" => "a"},
          "reads" => %{"cust" => [%{"id" => "a", "name" => "Ann"}]}
        })

      assert conn.status == 200, conn.resp_body
      assert json(conn)["output"] == %{"name" => "Ann"}

      bad =
        rules_call(:post, "/#{k}/dry-run", ctx.a, @designer, %{
          "version" => 1,
          "input" => %{"cid" => "a"},
          "reads" => %{"cust" => [%{"ssn" => "x"}]}
        })

      assert {bad.status, detail(bad)} == {422, "invalid_input"}
    end
  end

  # ── AC6 ────────────────────────────────────────────────────────────────────

  describe "AC6: API-token callers" do
    test "every write is 403 api_token_not_allowed and writes nothing; reads are allowed", ctx do
      schema = ctx.a.schema_name
      SP.active_definition!(schema, "customer")
      SP.active_definition!(schema, "vendor")
      SP.flag!(schema, "vendor")
      token = [credential: :api_token]

      for {method, path, body} <- [
            {:put, "/kill-switch", %{"on" => true, "reason" => "r"}},
            {:put, "/readable-masters/customer", %{"reason" => "r"}},
            {:post, "/readable-masters/vendor/clear", %{"reason" => "r"}}
          ] do
        conn = policy_call(method, path, ctx.a, @admin, body, token)
        assert {conn.status, detail(conn)} == {403, "api_token_not_allowed"}, path
      end

      refute stored(ctx.a).tenant_kill_switch
      refute Policy.readable_master?(schema, "customer")
      assert Policy.readable_master?(schema, "vendor")

      assert SP.policy_entries(schema) |> Enum.map(& &1.action) == [
               "script_policy.readable_master_set"
             ]

      assert policy_call(:get, "/", ctx.a, @admin, nil, token).status == 200
      assert policy_call(:get, "/readable-masters", ctx.a, @designer, nil, token).status == 200
    end

    test "a context without the credential field is refused (fail closed)", ctx do
      conn =
        Fixture.router_conn(:put, "/kill-switch", ctx.a, @admin, %{"on" => true, "reason" => "r"})
        |> Letflow.Routers.ScriptPolicy.call(Letflow.Routers.ScriptPolicy.init([]))

      assert {conn.status, detail(conn)} == {403, "api_token_not_allowed"}
    end
  end

  # ── AC7 ────────────────────────────────────────────────────────────────────

  describe "AC7: readable masters" do
    test "set: 201 and audited; again: 200 and no audit; listed in the allowlist shape", ctx do
      schema = ctx.a.schema_name
      SP.active_definition!(schema, "customer")
      user = Ecto.UUID.generate()

      conn =
        policy_call(:put, "/readable-masters/customer", ctx.a, @admin, %{"reason" => "lookup"},
          user_id: user
        )

      assert conn.status == 201, conn.resp_body
      body = json(conn)
      assert keys(body) == @master_keys
      assert body["entity_type"] == "customer"
      assert body["set_by"] == user
      assert body["reason"] == "lookup"

      assert [entry] = SP.entries(schema, "script_policy.readable_master_set")
      assert entry.actor_id == user
      assert entry.trace_id == @trace
      assert {entry.resource_type, entry.resource_id} == {"script_readable_master", "customer"}
      assert entry.before_state == nil
      assert entry.after_state == %{"entity_type" => "customer", "reason" => "lookup"}

      again = policy_call(:put, "/readable-masters/customer", ctx.a, @admin, %{"reason" => "x"})
      assert again.status == 200
      assert json(again)["reason"] == "lookup"
      assert length(SP.policy_entries(schema)) == 1

      list = json(policy_call(:get, "/readable-masters", ctx.a, @designer, nil))
      assert keys(list) == ["items"]
      assert [item] = list["items"]
      assert item == body
    end

    test "unknown, malformed and inactive types are 422 unknown_entity_type; a type-restricted type is 422 entity_type_restricted; nothing written",
         ctx do
      schema = ctx.a.schema_name
      SP.inactive_definition!(schema, "draft_type")
      SP.active_definition!(schema, "secret")
      SP.restrict_type!(schema, "secret")

      for type <- ["nope", "draft_type", "Bad-Type"] do
        conn = policy_call(:put, "/readable-masters/#{type}", ctx.a, @admin, %{"reason" => "r"})
        assert {conn.status, detail(conn)} == {422, "unknown_entity_type"}, type
      end

      conn = policy_call(:put, "/readable-masters/secret", ctx.a, @admin, %{"reason" => "r"})
      assert {conn.status, detail(conn)} == {422, "entity_type_restricted"}

      SP.active_definition!(schema, "customer")
      conn = policy_call(:put, "/readable-masters/customer", ctx.a, @admin, %{})
      assert {conn.status, detail(conn)} == {422, "invalid_reason"}

      assert Policy.list_readable_masters(schema) == []
      assert SP.policy_entries(schema) == []
    end

    test "the 201st flag is 422 too_many_masters", ctx do
      schema = ctx.a.schema_name
      SP.active_definition!(schema, "customer")
      for i <- 1..200, do: SP.flag_raw!(schema, "t_#{i}")

      conn = policy_call(:put, "/readable-masters/customer", ctx.a, @admin, %{"reason" => "r"})
      assert {conn.status, detail(conn)} == {422, "too_many_masters"}
      assert Repo.aggregate(ReadableMaster, :count, prefix: schema) == 200
      assert SP.policy_entries(schema) == []
    end

    test "clear: an unknown or unflagged type is the plain 404; a flagged type is cleared and the referencing published/retired versions are returned and audited",
         ctx do
      schema = ctx.a.schema_name
      SP.active_definition!(schema, "customer")
      SP.flag!(schema, "customer")

      responses =
        for type <- ["nope", "Bad-Type"] do
          conn =
            policy_call(:post, "/readable-masters/#{type}/clear", ctx.a, @admin, %{
              "reason" => "r"
            })

          {conn.status, conn.resp_body}
        end

      assert [{404, same}, {404, same}] = responses

      manifest = SP.manifest([SP.id_read("cust", "customer")])
      source = "return {name = 'x'}"

      cases = [
        %{"name" => "c", "input" => %{"cid" => "a"}, "expect" => %{"output" => %{"name" => "x"}}}
      ]

      [k1, k2, k3] = Enum.sort([key(), key(), key()])

      for k <- [k1, k2] do
        v = create_rule!(ctx.a, k, rule_body(manifest, source, cases))
        publish_rule!(ctx.a, k, v["sha256"])
      end

      assert rules_call(:post, "/#{k2}/versions/1/retire", ctx.a, @admin, %{"reason" => "old"}).status ==
               200

      create_rule!(ctx.a, k3, rule_body(manifest, source, cases))

      user = Ecto.UUID.generate()

      conn =
        policy_call(
          :post,
          "/readable-masters/customer/clear",
          ctx.a,
          @admin,
          %{"reason" => "narrow"},
          user_id: user
        )

      assert conn.status == 200, conn.resp_body
      body = json(conn)
      assert keys(body) == ["entity_type", "referenced_by", "referenced_total"]
      assert body["entity_type"] == "customer"

      assert body["referenced_by"] == [
               %{"key" => k1, "version" => 1, "status" => "published"},
               %{"key" => k2, "version" => 1, "status" => "retired"}
             ]

      assert body["referenced_total"] == 2
      refute Policy.readable_master?(schema, "customer")

      assert [entry] = SP.entries(schema, "script_policy.readable_master_cleared")
      assert entry.actor_id == user
      assert entry.trace_id == @trace
      assert {entry.resource_type, entry.resource_id} == {"script_readable_master", "customer"}
      assert entry.before_state["entity_type"] == "customer"
      assert is_binary(entry.before_state["set_by"])
      assert entry.before_state["set_at"]
      assert entry.after_state["reason"] == "narrow"
      assert entry.after_state["referenced_by"] == body["referenced_by"]
      assert entry.after_state["referenced_total"] == 2

      # clearing again is the same plain 404
      again =
        policy_call(:post, "/readable-masters/customer/clear", ctx.a, @admin, %{"reason" => "r"})

      assert {again.status, again.resp_body} == {404, same}
    end
  end

  # ── AC12 ───────────────────────────────────────────────────────────────────

  describe "AC12: permissions" do
    test "a process designer reads but cannot write", ctx do
      SP.active_definition!(ctx.a.schema_name, "customer")

      assert policy_call(:get, "/", ctx.a, @designer, nil).status == 200
      assert policy_call(:get, "/readable-masters", ctx.a, @designer, nil).status == 200

      for {method, path, body} <- writes() do
        assert policy_call(method, path, ctx.a, @designer, body).status == 403, path
      end

      refute stored(ctx.a).tenant_kill_switch
      refute Policy.readable_master?(ctx.a.schema_name, "customer")
    end

    test "the auditor and the other non-script roles get 403 on all five routes", ctx do
      SP.active_definition!(ctx.a.schema_name, "customer")
      SP.flag!(ctx.a.schema_name, "customer")

      for roles <- [
            ["TENANT_AUDITOR"],
            ["PROCESS_OPERATOR"],
            ["TASK_WORKER"],
            ["AGENT_RUNNER"],
            ["CANDIDATE"]
          ],
          {method, path, body} <- [{:get, "/", nil}, {:get, "/readable-masters", nil} | writes()] do
        assert policy_call(method, path, ctx.a, roles, body).status == 403,
               "#{inspect(roles)} #{method} #{path}"
      end

      refute stored(ctx.a).tenant_kill_switch
      assert Policy.readable_master?(ctx.a.schema_name, "customer")
    end

    test "the tenant routes act on the caller's own tenant only", ctx do
      assert policy_call(:put, "/kill-switch", ctx.a, @admin, %{"on" => true, "reason" => "r"}).status ==
               200

      refute stored(ctx.b).tenant_kill_switch
      assert json(policy_call(:get, "/", ctx.b, @admin, nil))["kill_switch_on"] == false
      refute Scripts.Policy.kill_switch_on?(ctx.b.schema_name)
    end
  end

  defp writes do
    [
      {:put, "/kill-switch", %{"on" => true, "reason" => "r"}},
      {:put, "/readable-masters/customer", %{"reason" => "r"}},
      {:post, "/readable-masters/customer/clear", %{"reason" => "r"}}
    ]
  end
end
