defmodule Letflow.Routers.ScriptPolicySodTest do
  @moduledoc """
  GH 2534 PR 7b-2b (decision 0053 D6 + amendment), design
  `lib/letflow/design/gh2534-7b2b-script-sod.md` sections 6, 7, 8, at the route level
  (direct dispatch with a hand-assigned `auth_context`, the style of `script_policy_test.exs`):

    * AC2: `PUT /script-policy/sod` (forbidden by the platform, a second admin via group
      membership and separately via a TENANT_ADMIN token, a caller outside the admin set,
      reason and value validation, API token, audit; `strict` always allowed, reads no count).
    * AC3: `PUT /tenants/:slug/script-policy/solo-audited` (9a8aa7ca audit split, the S3 reset,
      exact `platform_policy_map/1` key set on PUT and GET).
    * AC8 (route): `GET /script-policy/pending-review` shape.
    * AC12: every row of the 6.6 table reachable through a route answers its status and code;
      responses carry no admin count (S8).

  `async: false`: the platform tenant pin is VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Scripts
  alias Letflow.Scripts.Policy
  alias Letflow.Scripts.ScriptPolicy
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.ScriptPolicyFixture, as: SP

  @admin ["TENANT_ADMIN"]
  @designer ["PROCESS_DESIGNER"]
  @operator ["PLATFORM_ADMIN"]

  @sod_keys [
    "declared",
    "effective",
    "effective_reason",
    "platform_allowed",
    "reason",
    "set_at",
    "set_by",
    "set_by_class"
  ]

  @summary_keys [
    "confirmed_at",
    "discarded_at",
    "hook_kind",
    "key",
    "published_at",
    "publisher_id",
    "retired_at",
    "revoked_at",
    "self_published",
    "sha256",
    "status",
    "version"
  ]

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    SP.seed_roles!(tenants.a.schema_name)
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
      |> Plug.Conn.assign(:trace_id, "sod-trace")

    router.call(conn, router.init([]))
  end

  defp policy_call(method, path, fixture, roles, body, opts \\ []),
    do: call(Letflow.Routers.ScriptPolicy, method, path, fixture, roles, body, opts)

  defp rules_call(method, path, fixture, roles, body, opts \\ []),
    do: call(Letflow.Routers.ScriptRules, method, path, fixture, roles, body, opts)

  defp tenants_call(method, path, fixture, roles, body, opts \\ []),
    do: call(Letflow.Routers.Tenants, method, path, fixture, roles, body, opts)

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp detail(conn), do: json(conn)["detail"]
  defp keys(map), do: map |> Map.keys() |> Enum.sort()
  defp stored(fixture), do: Repo.get!(ScriptPolicy, 1, prefix: fixture.schema_name)
  defp key, do: "sod_#{System.unique_integer([:positive])}"

  defp put_sod(fixture, user_id, body, opts \\ []),
    do: policy_call(:put, "/sod", fixture, @admin, body, Keyword.put(opts, :user_id, user_id))

  defp rule_body,
    do: %{
      "hook_kind" => "service_task",
      "source" => "return {y = 1}",
      "manifest" => %{
        "input_schema" => %{"type" => "object", "properties" => %{"x" => %{"type" => "integer"}}},
        "output_schema" => %{"type" => "object", "properties" => %{"y" => %{"type" => "integer"}}},
        "fail_codes" => []
      },
      "test_cases" => [
        %{"name" => "one", "input" => %{"x" => 1}, "expect" => %{"output" => %{"y" => 1}}}
      ]
    }

  defp self_published!(fixture, admin) do
    k = key()
    {:ok, rule} = Scripts.create_draft(fixture.schema_name, k, rule_body(), SP.actor(admin))

    {:ok, published} =
      Scripts.publish(fixture.schema_name, k, 1, rule.sha256, SP.actor(admin), false)

    assert published.self_published
    published
  end

  # ── AC2 ────────────────────────────────────────────────────────────────────

  describe "AC2 PUT /script-policy/sod" do
    test "to solo: 409 while forbidden, 403 for a caller outside the admin set, 422 validation, 403 token; then 200 for the sole admin, audited",
         ctx do
      a = SP.admin!(ctx.a.schema_name)
      solo = %{"sod" => "solo_audited", "reason" => "we are one"}

      conn = put_sod(ctx.a, a, solo)
      assert {conn.status, detail(conn)} == {409, "solo_audited_forbidden"}

      SP.allow_solo!(ctx.a.schema_name, ctx.a.tenant_id, ctx.p.schema_name)

      conn = put_sod(ctx.a, SP.user!(ctx.a.schema_name), solo)
      assert {conn.status, detail(conn)} == {403, "not_tenant_wide_admin"}

      for {body, code} <- [
            {%{"sod" => "solo_audited"}, "invalid_reason"},
            {%{"sod" => "lenient", "reason" => "r"}, "invalid_state"},
            {%{"reason" => "r"}, "invalid_state"}
          ] do
        conn = put_sod(ctx.a, a, body)
        assert {conn.status, detail(conn)} == {422, code}, inspect(body)
      end

      conn = put_sod(ctx.a, a, solo, credential: :api_token)
      assert {conn.status, detail(conn)} == {403, "api_token_not_allowed"}
      assert stored(ctx.a).sod == "strict"
      assert SP.entries(ctx.a.schema_name, "script_policy.sod_set") == []

      conn = put_sod(ctx.a, a, solo)
      assert conn.status == 200, conn.resp_body
      sod = json(conn)["sod"]
      assert keys(sod) == @sod_keys
      assert sod["declared"] == "solo_audited"
      assert {sod["effective"], sod["effective_reason"]} == {"solo_audited", "solo_allowed"}

      assert {sod["set_by"], sod["set_by_class"], sod["reason"]} ==
               {a, "tenant_admin", "we are one"}

      assert sod["platform_allowed"] == true

      assert [entry] = SP.entries(ctx.a.schema_name, "script_policy.sod_set")
      assert entry.actor_id == a
      assert entry.trace_id == "sod-trace"
      assert entry.before_state == %{"sod" => "strict"}
      assert entry.after_state == %{"sod" => "solo_audited", "reason" => "we are one"}

      # no-op: 200, nothing more audited
      assert put_sod(ctx.a, a, solo).status == 200
      assert length(SP.entries(ctx.a.schema_name, "script_policy.sod_set")) == 1
    end

    test "to solo is 409 multiple_tenant_admins with a second admin via group membership", ctx do
      a = SP.admin!(ctx.a.schema_name)
      SP.admin!(ctx.a.schema_name)
      SP.allow_solo!(ctx.a.schema_name, ctx.a.tenant_id, ctx.p.schema_name)

      conn = put_sod(ctx.a, a, %{"sod" => "solo_audited", "reason" => "r"})
      assert {conn.status, detail(conn)} == {409, "multiple_tenant_admins"}
      assert stored(ctx.a).sod == "strict"
    end

    test "to solo is 409 multiple_tenant_admins with a second admin via an unexpired TENANT_ADMIN token of an active user",
         ctx do
      a = SP.admin!(ctx.a.schema_name)
      SP.token_admin!(ctx.a.schema_name)
      SP.allow_solo!(ctx.a.schema_name, ctx.a.tenant_id, ctx.p.schema_name)

      conn = put_sod(ctx.a, a, %{"sod" => "solo_audited", "reason" => "r"})
      assert {conn.status, detail(conn)} == {409, "multiple_tenant_admins"}
    end

    test "to strict is always allowed (any :ScriptsPublish caller) and reads no count or admin set",
         ctx do
      a = SP.admin!(ctx.a.schema_name)
      SP.solo!(ctx.a.schema_name, ctx.a.tenant_id, a)
      SP.admin!(ctx.a.schema_name)

      {conn, queries} =
        Fixture.capture_repo_queries(fn ->
          put_sod(ctx.a, Ecto.UUID.generate(), %{"sod" => "strict", "reason" => "back"})
        end)

      assert conn.status == 200, conn.resp_body
      assert json(conn)["sod"]["declared"] == "strict"
      assert json(conn)["sod"]["effective_reason"] == "declared_strict"

      # the write path itself (the response builder reads no count for a strict row either)
      refute Enum.any?(queries, fn q ->
               sql = Map.get(q, :query) || ""
               sql =~ "group_members" or sql =~ "api_tokens"
             end)
    end

    test "a PROCESS_DESIGNER cannot write it", ctx do
      conn = policy_call(:put, "/sod", ctx.a, @designer, %{"sod" => "strict", "reason" => "r"})
      assert conn.status == 403
    end
  end

  # ── S8 / GET / ─────────────────────────────────────────────────────────────

  describe "S8 responses" do
    test "GET / carries sod with the effective reason, never an admin count", ctx do
      a = SP.admin!(ctx.a.schema_name)
      SP.solo!(ctx.a.schema_name, ctx.a.tenant_id, a)
      SP.admin!(ctx.a.schema_name)

      conn = policy_call(:get, "/", ctx.a, @designer, nil)
      assert conn.status == 200
      sod = json(conn)["sod"]
      assert keys(sod) == @sod_keys

      assert {sod["declared"], sod["effective"], sod["effective_reason"]} ==
               {"solo_audited", "strict", "multiple_admins"}

      refute conn.resp_body =~ "count"
      refute conn.resp_body =~ "admin_ids"
    end
  end

  # ── AC8 route ──────────────────────────────────────────────────────────────

  describe "AC8 GET /script-policy/pending-review" do
    test "empty with one admin; lists summary maps once a second admin exists; designer may read",
         ctx do
      a = SP.admin!(ctx.a.schema_name)
      SP.solo!(ctx.a.schema_name, ctx.a.tenant_id, a)
      published = self_published!(ctx.a, a)

      conn = policy_call(:get, "/pending-review", ctx.a, @designer, nil)
      assert {conn.status, json(conn)} == {200, %{"items" => [], "truncated" => false}}

      SP.admin!(ctx.a.schema_name)
      conn = policy_call(:get, "/pending-review", ctx.a, @designer, nil)
      assert conn.status == 200
      assert %{"items" => [item], "truncated" => false} = json(conn)
      assert keys(item) == @summary_keys

      assert {item["key"], item["self_published"], item["confirmed_at"]} ==
               {published.key, true, nil}

      assert policy_call(:get, "/pending-review", ctx.a, ["TENANT_AUDITOR"], nil).status == 403
    end
  end

  # ── AC12 confirm / publish through ScriptRules ─────────────────────────────

  describe "AC12 error mapping on the ScriptRules routes" do
    setup ctx do
      a = SP.admin!(ctx.a.schema_name)
      SP.solo!(ctx.a.schema_name, ctx.a.tenant_id, a)
      published = self_published!(ctx.a, a)
      b = SP.admin!(ctx.a.schema_name)
      {:ok, admin_a: a, admin_b: b, rule: published}
    end

    defp confirm(fixture, k, version, sha, user_id, opts \\ []) do
      rules_call(
        :post,
        "/#{k}/versions/#{version}/confirm",
        fixture,
        @admin,
        %{"sha256" => sha},
        Keyword.put(opts, :user_id, user_id)
      )
    end

    test "confirm: 403 / 409 / 404 rows, then 200 with the detail map", ctx do
      k = ctx.rule.key
      sha = ctx.rule.sha256

      for {user, sha_sent, opts, status, code} <- [
            {SP.user!(ctx.a.schema_name), sha, [], 403, "not_tenant_wide_admin"},
            {ctx.admin_a, sha, [], 403, "confirmer_is_contributor"},
            {ctx.admin_b, String.duplicate("0", 64), [], 409, "content_changed"},
            {ctx.admin_b, sha, [credential: :api_token], 403, "api_token_not_allowed"}
          ] do
        conn = confirm(ctx.a, k, 1, sha_sent, user, opts)
        assert {conn.status, detail(conn)} == {status, code}, code
      end

      not_found = confirm(ctx.a, k, 7, sha, ctx.admin_b)
      assert not_found.status == 404
      assert confirm(ctx.b, k, 1, sha, ctx.admin_b).resp_body == not_found.resp_body

      conn = confirm(ctx.a, k, 1, sha, ctx.admin_b)
      assert conn.status == 200, conn.resp_body
      body = json(conn)
      assert {body["confirmed_by"], body["confirmed_sha256"]} == {ctx.admin_b, sha}
      assert body["sod_excluded"] == [ctx.admin_a]
      assert body["confirmed_at"]

      conn = confirm(ctx.a, k, 1, sha, ctx.admin_b)
      assert {conn.status, detail(conn)} == {409, "not_pending_review"}

      # a designer cannot confirm (authorization)
      conn =
        rules_call(:post, "/#{k}/versions/1/confirm", ctx.a, @designer, %{"sha256" => sha},
          user_id: ctx.admin_b
        )

      assert conn.status == 403
    end

    test "publish: 403 publisher_is_contributor (auto-strict with two admins)", ctx do
      k = key()
      {:ok, rule} = Scripts.create_draft(ctx.a.schema_name, k, rule_body(), SP.actor(ctx.admin_a))

      conn =
        rules_call(:post, "/#{k}/versions/1/publish", ctx.a, @admin, %{"sha256" => rule.sha256},
          user_id: ctx.admin_a
        )

      assert {conn.status, detail(conn)} == {403, "publisher_is_contributor"}
      assert stored(ctx.a).sod == "strict"
    end
  end

  # ── AC3 platform route ─────────────────────────────────────────────────────

  describe "AC3 PUT /tenants/:slug/script-policy/solo-audited" do
    defp assert_platform_shape(body) do
      assert keys(body) == ["kill_switch_on", "platform", "solo_audited", "tenant"]
      assert keys(body["solo_audited"]) == ["allowed", "reason", "set_at"]
      assert keys(body["platform"]) == ["on", "reason", "set_at"]
      assert keys(body["tenant"]) == ["on", "set_at"]
    end

    test "allow then forbid: audit split, S3 reset of a declared solo, exact key set on PUT and GET",
         ctx do
      path = "/#{ctx.a.tenant.slug}/script-policy/solo-audited"
      operator = Ecto.UUID.generate()

      conn =
        tenants_call(:put, path, ctx.p, @operator, %{"allowed" => true, "reason" => "small org"},
          user_id: operator
        )

      assert conn.status == 200, conn.resp_body
      assert_platform_shape(json(conn))
      assert json(conn)["solo_audited"]["allowed"] == true

      a = SP.admin!(ctx.a.schema_name)
      {:ok, _} = Policy.set_sod(ctx.a.schema_name, "solo_audited", "tenant secret", SP.actor(a))

      conn =
        tenants_call(:put, path, ctx.p, @operator, %{"allowed" => false, "reason" => "audit"},
          user_id: operator
        )

      assert conn.status == 200, conn.resp_body
      put_body = json(conn)
      assert_platform_shape(put_body)

      assert put_body["solo_audited"] |> Map.delete("set_at") == %{
               "allowed" => false,
               "reason" => "audit"
             }

      get_conn = tenants_call(:get, "/#{ctx.a.tenant.slug}/script-policy", ctx.p, @operator, nil)
      assert get_conn.status == 200
      assert json(get_conn) == put_body

      for resp <- [conn.resp_body, get_conn.resp_body] do
        refute resp =~ "tenant secret"
        refute resp =~ "sod"
        refute resp =~ a
      end

      row = stored(ctx.a)
      assert {row.platform_solo_audited_allowed, row.sod} == {false, "strict"}

      assert {row.sod_set_by, row.sod_set_by_class, row.sod_reason} ==
               {nil, "platform_operator", "audit"}

      entries = SP.entries(ctx.a.schema_name, "script_policy.platform_solo_audited_set")
      assert [allow, forbid] = entries
      assert Enum.all?(entries, &(&1.actor_id == nil and &1.trace_id == nil))
      refute inspect(entries) =~ operator
      assert allow.after_state["sod"] == "strict"

      assert forbid.before_state == %{
               "platform_solo_audited_allowed" => true,
               "sod" => "solo_audited"
             }

      assert forbid.after_state == %{
               "platform_solo_audited_allowed" => false,
               "reason" => "audit",
               "sod" => "strict",
               "actor_class" => "platform_operator"
             }

      platform = SP.entries(ctx.p.schema_name, "platform.tenant_script_solo_audited.set")
      assert length(platform) == 2
      assert Enum.all?(platform, &(&1.actor_id == operator and &1.trace_id == "sod-trace"))
      assert Enum.all?(platform, &(&1.resource_id == ctx.a.tenant_id))

      # no-op: nothing more audited
      assert tenants_call(:put, path, ctx.p, @operator, %{"allowed" => false, "reason" => "x"}).status ==
               200

      assert length(SP.entries(ctx.a.schema_name, "script_policy.platform_solo_audited_set")) == 2
    end

    test "422 validation, 403 token, 403 TENANT_ADMIN, plain 404 for an unknown slug; nothing written",
         ctx do
      path = "/#{ctx.a.tenant.slug}/script-policy/solo-audited"

      for {body, code} <- [
            {%{"allowed" => true}, "invalid_reason"},
            {%{"allowed" => "yes", "reason" => "r"}, "invalid_state"}
          ] do
        conn = tenants_call(:put, path, ctx.p, @operator, body)
        assert {conn.status, detail(conn)} == {422, code}
      end

      conn =
        tenants_call(:put, path, ctx.p, @operator, %{"allowed" => true, "reason" => "r"},
          credential: :api_token
        )

      assert {conn.status, detail(conn)} == {403, "api_token_not_allowed"}

      assert tenants_call(:put, path, ctx.a, @admin, %{"allowed" => true, "reason" => "r"}).status ==
               403

      assert tenants_call(
               :put,
               "/no-such-#{System.unique_integer([:positive])}/script-policy/solo-audited",
               ctx.p,
               @operator,
               %{"allowed" => true, "reason" => "r"}
             ).status == 404

      refute stored(ctx.a).platform_solo_audited_allowed
      assert SP.entries(ctx.a.schema_name, "script_policy.platform_solo_audited_set") == []
    end
  end
end
