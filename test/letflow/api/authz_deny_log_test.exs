defmodule Letflow.Api.AuthzDenyLogTest do
  @moduledoc """
  ISS-0995 / Q-976 (design `lib/letflow/design/iss0995-authz-deny-attribution-log.md`, section 13,
  tests (a)-(j); spec `test/specs/ISS-0995.md`).

  Every `:Deny403` of `Letflow.Plugs.Authorize` emits ONE attribution line through
  `Letflow.Api.AuthzDenyLog`: method, route PATTERN, policy key, platform-scope boolean, keyed
  hashes of the caller and tenant ids, sampled for repeated denials, carrying nothing INV-4 forbids,
  and never altering the 403 (INV-5 / INV-10).

  `async: false`: the log sink handler (`sink_log/1`), Application env (window, clock, master key,
  platform-tenant pin) and `:persistent_term` (sampler, one-time flags) are VM-global. `setup`
  zeroes the module's state and every env key this file touches is restored on exit.
  """

  use Letflow.DataCase, async: false
  @moduletag :slow

  import Plug.Conn, only: [assign: 3, put_private: 3, get_resp_header: 2]

  alias Letflow.Api.Authorization.AccessContext
  alias Letflow.Api.AuthzDenyLog
  alias Letflow.Identity.User
  alias Letflow.Plugs.Authorize
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Test.LoggerCollector

  @label "letflow/authz-deny-log/v1"
  @env_keys [:authz_deny_log_window_s, :authz_deny_log_clock, :secrets_master_key]
  @fixed_master :binary.copy(<<7>>, 32)

  # Forwards every %{authz_*} log event, with its metadata, to the owner test process.
  defmodule Forwarder do
    @moduledoc false
    def log(%{meta: %{authz_method: _}} = event, %{config: %{pid: pid, ref: ref}}) do
      send(pid, {:authz_event, ref, event})
    end

    def log(_event, _config), do: :ok
  end

  # Runs `fun`, then returns the formatted text of every log event it emitted that came from
  # the authz deny log, one per line, in arrival order. Replaces `capture_log/1` (a GLOBAL
  # capture that can lose or add lines under concurrent load) with the shared synchronous
  # `Letflow.Test.LoggerCollector` handler: it runs in the emitting process and `send/2`s
  # before the log call returns, and it only forwards events attributable to THIS test
  # process (itself, its Tasks via `$callers`). A deliberate narrowing: the leak checks
  # examine what AuthzDenyLog emitted, not other loggers' lines, and message text only (no
  # level or metadata; the Forwarder test covers those).
  defp sink_log(fun) do
    collector = LoggerCollector.attach!(attribute_to: self(), sasl: false, raw: false)

    try do
      fun.()

      # a crashed handler is removed by :logger; fail loudly rather than pass "logs nothing" vacuously
      LoggerCollector.assert_alive!(collector)
    after
      LoggerCollector.detach(collector)
    end

    collector
    |> LoggerCollector.collected()
    |> Enum.map(& &1.text)
    |> Enum.filter(&String.contains?(&1, ["authz_deny", "authz deny log"]))
    |> Enum.join("\n")
  end

  setup do
    saved = for key <- @env_keys, do: {key, Application.fetch_env(:letflow, key)}

    on_exit(fn ->
      for {key, saved_value} <- saved do
        case saved_value do
          {:ok, value} -> Application.put_env(:letflow, key, value)
          :error -> Application.delete_env(:letflow, key)
        end
      end

      AuthzDenyLog.reset()
    end)

    AuthzDenyLog.reset()
    # Unless a test is about sampling, every denial logs.
    Application.put_env(:letflow, :authz_deny_log_window_s, 0)
    Application.delete_env(:letflow, :authz_deny_log_clock)

    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  # --- helpers ---------------------------------------------------------------

  defp master, do: Application.fetch_env!(:letflow, :secrets_master_key)

  defp mac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  # Independent re-derivation of the design's hash (pins label, domain tag, truncation).
  defp expected_hash(kind, id, master_key) do
    subkey = mac(master_key, @label <> <<1>>)
    tag = if kind == :user, do: "user:", else: "tenant:"

    subkey
    |> mac(tag <> id)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp deny_lines(log) do
    log
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "authz_deny "))
    |> Enum.map(&String.trim/1)
  end

  defp parse(line) do
    [_prefix, rest] = String.split(line, "authz_deny ", parts: 2)

    rest
    |> String.split(" ", trim: true)
    |> Map.new(fn token ->
      [k, v] = String.split(token, "=", parts: 2)
      {k, v}
    end)
  end

  defp one_line!(log) do
    assert [line] = deny_lines(log), "expected exactly one authz_deny line, got: #{log}"
    parse(line)
  end

  defp mint!(fixture, roles) do
    before_ids = fixture |> users() |> Enum.map(& &1.id)
    token = Fixture.mint_token!(fixture, roles)
    [user] = fixture |> users() |> Enum.reject(&(&1.id in before_ids))
    %{token: token, user_id: user.id, email: user.email}
  end

  defp users(fixture), do: Repo.all(User, prefix: fixture.schema_name)

  # Full-router request by a freshly minted caller; returns {conn, identity}.
  defp api(method, path, fixture, roles, body) do
    identity = mint!(fixture, roles)

    conn =
      method
      |> Fixture.api_conn(path, identity.token, fixture.tenant.slug, body)
      |> Fixture.dispatch_api()

    {conn, identity}
  end

  # A conn + ctx pair for a direct `Authorize.call/2` / `log_denial/3`, no router, no :plug_route.
  defp direct(fixture, user_id, roles, policy_key) do
    conn =
      :get
      |> Plug.Test.conn("/direct")
      |> assign(:auth_context, %{user_id: user_id, tenant_id: fixture.tenant_id, roles: roles})
      |> assign(:trace_id, "authz-deny-log-test-trace-id")

    conn = if policy_key, do: put_private(conn, :policy_key, policy_key), else: conn

    ctx = %AccessContext{
      user_id: user_id,
      roles: Letflow.Api.Authorization.roles_from_strings(roles),
      platform_tenant?: Letflow.PlatformTenant.platform_tenant?(fixture.tenant_id)
    }

    {conn, ctx}
  end

  defp deny_direct(fixture, user_id, roles, policy_key) do
    {conn, _ctx} = direct(fixture, user_id, roles, policy_key)
    Authorize.call(conn, [])
  end

  defp forbidden_bytes do
    conn = Letflow.Api.Response.forbidden(Plug.Test.conn(:get, "/"), "insufficient permissions")
    bytes(conn)
  end

  # status, body and content-type; the per-request `trace_id` member is the only body field that
  # legitimately varies between requests (as in `platform_prefix_uniform_403_test.exs`, the
  # request/trace id is excluded) and is therefore dropped from the decoded body.
  defp bytes(conn) do
    body = conn.resp_body |> Jason.decode!() |> Map.delete("trace_id")
    {conn.status, body, get_resp_header(conn, "content-type")}
  end

  defp new_clock(start) do
    ref = :atomics.new(1, signed: true)
    :atomics.put(ref, 1, start)
    Application.put_env(:letflow, :authz_deny_log_clock, fn -> :atomics.get(ref, 1) end)
    ref
  end

  defp set_clock(ref, t), do: :atomics.put(ref, 1, t)

  # Spins until `n` callers have incremented `ref` (a barrier for the race test); bounded by a
  # monotonic deadline so a missing arrival fails the test rather than hanging it.
  defp await_arrivals(ref, n, deadline) do
    cond do
      :atomics.get(ref, 1) >= n -> :ok
      System.monotonic_time(:millisecond) > deadline -> raise "barrier deadline exceeded"
      true -> await_arrivals(ref, n, deadline)
    end
  end

  @caller_a "11111111-1111-4111-8111-111111111111"
  @caller_b "22222222-2222-4222-8222-222222222222"

  # Deterministic sampling fixtures: a fixed master key makes every slot index fixed too.
  defp sampling_setup(ctx) do
    Application.put_env(:letflow, :authz_deny_log_window_s, 60)
    Application.put_env(:letflow, :secrets_master_key, @fixed_master)
    AuthzDenyLog.reset()
    ctx.a
  end

  defp log_k(fixture, caller, policy) do
    {conn, access} = direct(fixture, caller, ["PLATFORM_ADMIN"], policy)
    sink_log(fn -> assert :ok = AuthzDenyLog.log_denial(conn, access, policy) end)
  end

  # --- (a) platform-scope denial ---------------------------------------------

  describe "(a) platform-scope denial" do
    test "direct plug call: one line, hashes equal the independent HMAC recomputation", ctx do
      caller = Ecto.UUID.generate()

      log =
        sink_log(fn ->
          conn = deny_direct(ctx.a, caller, ["PLATFORM_ADMIN"], :TenantsManage)
          assert conn.status == 403
          assert conn.halted
        end)

      tokens = one_line!(log)

      assert tokens["method"] == "GET"
      assert tokens["route"] == "unmatched"
      assert tokens["policy"] == "TenantsManage"
      assert tokens["platform_scope"] == "true"
      assert tokens["caller_platform_tenant"] == "false"
      assert tokens["caller"] == expected_hash(:user, caller, master())
      assert tokens["tenant"] == expected_hash(:tenant, ctx.a.tenant_id, master())
      refute Map.has_key?(tokens, "suppressed")

      assert Map.keys(tokens) |> Enum.sort() ==
               ~w(caller caller_platform_tenant method platform_scope policy route tenant)
    end

    test "the platform tenant's own non-admin role is attributed caller_platform_tenant=true",
         ctx do
      log =
        sink_log(fn ->
          conn = deny_direct(ctx.p, Ecto.UUID.generate(), ["PROCESS_DESIGNER"], :TenantsManage)
          assert conn.status == 403
        end)

      tokens = one_line!(log)
      assert tokens["platform_scope"] == "true"
      assert tokens["caller_platform_tenant"] == "true"
    end

    test "through the real router: the route PATTERN, not the path, with a real token", ctx do
      slug = "uniq-route-9d41c7"

      log =
        sink_log(fn ->
          {conn, identity} =
            api(:get, "/api/v1/tenants/" <> slug, ctx.a, ["PROCESS_DESIGNER"], nil)

          assert conn.status == 403

          send(self(), {:identity, identity})
        end)

      assert_received {:identity, identity}
      tokens = one_line!(log)

      assert tokens["route"] == "/api/v1/tenants/:slug"
      assert tokens["method"] == "GET"
      assert tokens["policy"] == "TenantsManage"
      assert tokens["platform_scope"] == "true"
      assert tokens["caller"] == expected_hash(:user, identity.user_id, master())
      assert tokens["tenant"] == expected_hash(:tenant, ctx.a.tenant_id, master())
      refute log =~ slug
    end

    test "A's TENANT_ADMIN on a cross-tenant platform route is attributed and denied (INV-10)",
         ctx do
      log =
        sink_log(fn ->
          {conn, _identity} =
            api(:patch, "/api/v1/tenants/" <> ctx.b.tenant.slug, ctx.a, ["TENANT_ADMIN"], %{
              "display_name" => "Hijacked"
            })

          assert conn.status == 403
        end)

      tokens = one_line!(log)
      assert tokens["method"] == "PATCH"
      assert tokens["route"] == "/api/v1/tenants/:slug"
      assert tokens["platform_scope"] == "true"
      assert tokens["caller_platform_tenant"] == "false"
      # the OTHER tenant addressed by the path is not disclosed
      refute log =~ ctx.b.tenant.slug
      refute log =~ ctx.b.tenant_id
      refute log =~ ctx.b.schema_name
    end

    test "message and logger metadata are generated from the same fields", ctx do
      caller = Ecto.UUID.generate()
      {conn, access} = direct(ctx.a, caller, ["PLATFORM_ADMIN"], :TenantsManage)
      f = AuthzDenyLog.build_fields(conn, access, :TenantsManage)

      forwarder_ref = make_ref()
      handler_id = :"authz_deny_forwarder_#{System.unique_integer([:positive])}"

      :ok =
        :logger.add_handler(handler_id, Forwarder, %{
          level: :all,
          config: %{pid: self(), ref: forwarder_ref}
        })

      on_exit(fn -> :logger.remove_handler(handler_id) end)

      sink_log(fn -> assert :ok = AuthzDenyLog.log_denial(conn, access, :TenantsManage) end)

      assert_receive {:authz_event, ^forwarder_ref, event}, 1000
      assert event.level == :warning
      assert {:string, msg} = event.msg
      assert IO.chardata_to_string(msg) == AuthzDenyLog.format_message(f, 0)

      meta = event.meta
      expected = AuthzDenyLog.metadata(f, 0)

      assert Keyword.keys(expected) ==
               ~w(authz_method authz_route authz_policy authz_platform_scope
                  authz_caller_platform_tenant authz_caller authz_tenant)a

      for {key, value} <- expected, do: assert(Map.fetch!(meta, key) == value)
      refute Map.has_key?(meta, :authz_suppressed)
    end

    test "format_message/2 and metadata/2 add suppressed only when n > 0", ctx do
      {conn, access} = direct(ctx.a, @caller_a, ["PLATFORM_ADMIN"], :TenantsManage)
      f = AuthzDenyLog.build_fields(conn, access, :TenantsManage)

      refute AuthzDenyLog.format_message(f, 0) =~ "suppressed"

      assert AuthzDenyLog.format_message(f, 7) ==
               AuthzDenyLog.format_message(f, 0) <> " suppressed=7"

      assert List.last(AuthzDenyLog.metadata(f, 7)) == {:authz_suppressed, 7}
      refute Keyword.has_key?(AuthzDenyLog.metadata(f, 0), :authz_suppressed)
      assert Enum.drop(AuthzDenyLog.metadata(f, 7), -1) == AuthzDenyLog.metadata(f, 0)
    end
  end

  # --- (b) tenant-scope denial -----------------------------------------------

  describe "(b) tenant-scope denial" do
    test "a role lacking a tenant permission is attributed with platform_scope=false", ctx do
      log =
        sink_log(fn ->
          {conn, _identity} =
            api(:post, "/api/v1/definitions", ctx.a, ["TASK_WORKER"], %{"name" => "x"})

          assert conn.status == 403
        end)

      tokens = one_line!(log)
      assert tokens["method"] == "POST"
      assert tokens["route"] == "/api/v1/definitions/"
      assert tokens["policy"] == "DefinitionsCreate"
      assert tokens["platform_scope"] == "false"
      assert tokens["caller_platform_tenant"] == "false"
    end
  end

  # --- (c) :Unknown and the two markers --------------------------------------

  describe "(c) :Unknown and the router catch-all markers" do
    test "no :policy_key private key -> policy=Unknown, platform_scope=false", ctx do
      log =
        sink_log(fn ->
          conn = deny_direct(ctx.a, Ecto.UUID.generate(), ["PROCESS_DESIGNER"], nil)
          assert conn.status == 403
        end)

      tokens = one_line!(log)
      assert tokens["policy"] == "Unknown"
      assert tokens["platform_scope"] == "false"
    end

    test "direct :UnmatchedPlatformPath for a non-operator -> platform_scope=true", ctx do
      log =
        sink_log(fn ->
          conn =
            deny_direct(ctx.a, Ecto.UUID.generate(), ["PROCESS_DESIGNER"], :UnmatchedPlatformPath)

          assert conn.status == 403
        end)

      tokens = one_line!(log)
      assert tokens["policy"] == "UnmatchedPlatformPath"
      assert tokens["platform_scope"] == "true"
    end

    test "unmatched path under a platform prefix through the real router keeps the /*_path catch-all",
         ctx do
      value = "zzz-uniq-3c7e19"

      log =
        sink_log(fn ->
          {conn, _identity} =
            api(
              :get,
              "/api/v1/tenants/#{value}/#{value}/#{value}",
              ctx.a,
              ["PROCESS_DESIGNER"],
              nil
            )

          assert conn.status == 403
        end)

      tokens = one_line!(log)
      assert tokens["policy"] == "UnmatchedPlatformPath"
      assert tokens["platform_scope"] == "true"
      assert tokens["route"] == "/api/v1/tenants/*_path"
      refute log =~ value
    end

    test ":UnmatchedRoute under an ordinary router for a non-admin -> platform_scope=false",
         ctx do
      value = "zzz-uniq-6a02d4"

      log =
        sink_log(fn ->
          {conn, _identity} =
            api(
              :get,
              "/api/v1/definitions/#{value}/#{value}/#{value}",
              ctx.a,
              ["TASK_WORKER"],
              nil
            )

          assert conn.status == 403
        end)

      tokens = one_line!(log)
      assert tokens["policy"] == "UnmatchedRoute"
      assert tokens["platform_scope"] == "false"
      assert String.ends_with?(tokens["route"], "/*_path")
      assert String.starts_with?(tokens["route"], "/api/v1/definitions")
      refute log =~ value
    end

    test "platform_scope?/1: explicit marker clauses, table lookup, fail-closed fallthrough" do
      assert AuthzDenyLog.platform_scope?(:UnmatchedPlatformPath)
      refute AuthzDenyLog.platform_scope?(:UnmatchedRoute)
      refute AuthzDenyLog.platform_scope?(:Unknown)
      assert AuthzDenyLog.platform_scope?(:TenantsManage)
      refute AuthzDenyLog.platform_scope?(:DefinitionsCreate)
      # any other term is platform-scope (fail closed)
      assert AuthzDenyLog.platform_scope?(:ThisKeyIsNotInAnyTable)
    end
  end

  # --- (d) no leak ------------------------------------------------------------

  describe "(d) INV-4: no raw identifier reaches the log" do
    test "caller/tenant ids, slug, schema, email, token, path/query/body values, keys", ctx do
      path_value = "uniq-5f0c1ad9"
      query_value = "uniq-query-5f0c1ad9"
      body_value = "uniq-body-5f0c1ad9"

      scenarios = [
        {:get, "/api/v1/tenants/#{path_value}?q=#{query_value}", ["PROCESS_DESIGNER"], nil},
        {:post, "/api/v1/definitions?q=#{query_value}", ["TASK_WORKER"], %{"name" => body_value}},
        {:get, "/api/v1/tenants/#{path_value}/#{path_value}?q=#{query_value}",
         ["PROCESS_DESIGNER"], nil},
        {:get, "/api/v1/definitions/#{path_value}/#{path_value}?q=#{query_value}",
         ["TASK_WORKER"], nil}
      ]

      for {method, path, roles, body} <- scenarios do
        log =
          sink_log(fn ->
            {conn, identity} = api(method, path, ctx.a, roles, body)
            assert conn.status == 403
            send(self(), {:identity, identity})
          end)

        assert_received {:identity, identity}
        assert [_one] = deny_lines(log), "#{method} #{path}: #{log}"

        subkey = AuthzDenyLog.subkey()
        # only the attribution line is inspected: the capture also holds unrelated debug SQL
        # (the fixture's own INSERT of the caller carries the raw ids by necessity).
        line_text = Enum.join(deny_lines(log), "\n")

        secrets = [
          {"raw user id", identity.user_id},
          {"raw tenant id", ctx.a.tenant_id},
          {"tenant schema name", ctx.a.schema_name},
          {"tenant slug", ctx.a.tenant.slug},
          {"email", identity.email},
          {"bearer token", identity.token},
          {"path value", path_value},
          {"query value", query_value},
          {"body value", body_value},
          {"master key raw", master()},
          {"master key hex", Base.encode16(master(), case: :lower)},
          {"master key HEX", Base.encode16(master(), case: :upper)},
          {"sub-key raw", subkey},
          {"sub-key hex", Base.encode16(subkey, case: :lower)}
        ]

        for {name, secret} <- secrets do
          refute String.contains?(line_text, secret),
                 "#{method} #{path}: the log leaks the #{name}"
        end

        for dump <- ["user_id", "tenant_id", "auth_context", "Bearer", "authorization"] do
          refute String.contains?(line_text, dump), "#{method} #{path}: raw dump marker #{dump}"
        end
      end
    end
  end

  # --- (e) hash algorithm pin -------------------------------------------------

  describe "(e) hash algorithm" do
    test "hash_id/3 equals the independent HMAC-SHA256(derived sub-key) recomputation" do
      id = "4b0c0d6e-1f2a-4c3b-9d8e-7f6a5b4c3d2e"
      key = master()

      assert AuthzDenyLog.subkey() == mac(key, @label <> <<1>>)
      assert byte_size(AuthzDenyLog.subkey()) == 32

      assert AuthzDenyLog.hash_id(:user, id, AuthzDenyLog.subkey()) ==
               expected_hash(:user, id, key)

      assert AuthzDenyLog.hash_id(:tenant, id, AuthzDenyLog.subkey()) ==
               expected_hash(:tenant, id, key)

      assert expected_hash(:user, id, key) =~ ~r/\A[0-9a-f]{16}\z/
    end

    test "domain separation, stability, id- and key-dependence" do
      id = Ecto.UUID.generate()
      other_id = Ecto.UUID.generate()
      sub = AuthzDenyLog.subkey()

      user = AuthzDenyLog.hash_id(:user, id, sub)
      tenant = AuthzDenyLog.hash_id(:tenant, id, sub)

      assert user != tenant
      assert user == AuthzDenyLog.hash_id(:user, id, sub)
      assert user != AuthzDenyLog.hash_id(:user, other_id, sub)
      assert user =~ ~r/\A[0-9a-f]{16}\z/
      refute user =~ id

      Application.put_env(:letflow, :secrets_master_key, :binary.copy(<<9>>, 32))
      other_sub = AuthzDenyLog.subkey()
      assert other_sub != sub
      assert AuthzDenyLog.hash_id(:user, id, other_sub) != user

      assert AuthzDenyLog.hash_id(:user, id, other_sub) ==
               expected_hash(:user, id, :binary.copy(<<9>>, 32))
    end

    test "a non-binary or empty id renders none" do
      sub = AuthzDenyLog.subkey()

      for bad <- [nil, "", 123, :atom, %{"id" => "x"}, ["a"], 1.5] do
        assert AuthzDenyLog.hash_id(:user, bad, sub) == "none"
        assert AuthzDenyLog.hash_id(:tenant, bad, sub) == "none"
      end
    end
  end

  # --- (f) INV-5 / response bytes ---------------------------------------------

  describe "(f) the 403 bytes are unchanged (INV-5, INV-10)" do
    test "platform-scope 403 equals Response.forbidden/2 and is identical for existing vs missing",
         ctx do
      expected = forbidden_bytes()
      assert {403, _body, [content_type]} = expected
      assert content_type =~ "application/problem+json"

      for {method, slug, body} <- [
            {:get, ctx.b.tenant.slug, nil},
            {:get, ctx.a.tenant.slug, nil},
            {:get, "no-such-slug-uniq-77", nil},
            {:patch, ctx.b.tenant.slug, %{"display_name" => "X"}},
            {:patch, "no-such-slug-uniq-77", %{"display_name" => "X"}}
          ],
          roles <- [["TENANT_ADMIN"], ["PROCESS_DESIGNER"]] do
        {conn, _identity} = api(method, "/api/v1/tenants/" <> slug, ctx.a, roles, body)

        assert bytes(conn) == expected,
               "#{method} #{slug} #{inspect(roles)}: the 403 differs from Response.forbidden/2"

        refute conn.resp_body =~ ctx.b.tenant_id
        refute conn.resp_body =~ ctx.b.tenant.slug
      end
    end

    test "a direct Authorize denial returns exactly Response.forbidden/2's bytes", ctx do
      conn = deny_direct(ctx.a, Ecto.UUID.generate(), ["PLATFORM_ADMIN"], :TenantsManage)
      assert bytes(conn) == forbidden_bytes()
    end

    test "the denial reaches the same bytes with logging made to fail (log_denial cannot alter it)",
         ctx do
      Application.put_env(:letflow, :authz_deny_log_clock, fn -> raise "boom" end)
      Application.put_env(:letflow, :authz_deny_log_window_s, 60)

      sink_log(fn ->
        conn = deny_direct(ctx.a, Ecto.UUID.generate(), ["PLATFORM_ADMIN"], :TenantsManage)
        assert bytes(conn) == forbidden_bytes()
      end)
    end
  end

  # --- (g) method allow-list and log injection --------------------------------

  describe "(g) method allow-list and injection" do
    test "method_token/1 over the allow-list and hostile values" do
      for m <- ~w(GET POST PUT PATCH DELETE HEAD OPTIONS),
          do: assert(AuthzDenyLog.method_token(m) == m)

      for bad <- ["get", "PURGE", "GET\r\nFAKE", String.duplicate("A", 5000), nil, :get, 5, ""] do
        assert AuthzDenyLog.method_token(bad) == "OTHER"
      end
    end

    test "an unknown method at a router catch-all logs method=OTHER on one line", ctx do
      log =
        sink_log(fn ->
          {conn, _identity} =
            api("PURGE", "/api/v1/tenants/zzz/zzz/zzz", ctx.a, ["PROCESS_DESIGNER"], nil)

          assert conn.status == 403
        end)

      tokens = one_line!(log)
      assert tokens["method"] == "OTHER"
      assert tokens["policy"] == "UnmatchedPlatformPath"
    end

    test "CR/LF in the method, path and a header cannot create a second record or forge fields",
         ctx do
      hostile_method = "PURGE\r\nauthz_deny caller=deadbeefdeadbeef"

      log =
        sink_log(fn ->
          identity = mint!(ctx.a, ["PROCESS_DESIGNER"])

          conn =
            hostile_method
            |> Plug.Test.conn(
              "/api/v1/tenants/zzz/zzz/zzz?x=%0D%0Aauthz_deny%20caller=deadbeefdeadbeef"
            )
            |> Plug.Conn.put_req_header("authorization", "Bearer " <> identity.token)
            |> Plug.Conn.put_req_header("x-tenant-slug", ctx.a.tenant.slug)
            |> Plug.Conn.put_req_header("x-injected", "a\r\nauthz_deny caller=deadbeefdeadbeef")
            |> Fixture.dispatch_api()

          assert conn.status == 403
        end)

      tokens = one_line!(log)
      assert tokens["method"] == "OTHER"
      refute log =~ ~r/deadbeef/i
      assert tokens["caller"] =~ ~r/\A[0-9a-f]{16}\z/
    end
  end

  # --- (h) sampling -----------------------------------------------------------

  describe "(h) sampling with an injected clock" do
    test "the window table: emit, withhold, boundary, suppressed counts, backwards clock", ctx do
      fixture = sampling_setup(ctx)
      clock = new_clock(1000)

      # 1. K#1 emits (no suppressed); K#2..K#5 withheld; other caller and other policy get own lines.
      first = log_k(fixture, @caller_a, :TenantsManage)
      assert first |> one_line!() |> Map.has_key?("suppressed") == false

      for _ <- 2..5, do: assert(deny_lines(log_k(fixture, @caller_a, :TenantsManage)) == [])

      other_caller = log_k(fixture, @caller_b, :TenantsManage)

      assert other_caller |> one_line!() |> Map.fetch!("caller") ==
               expected_hash(:user, @caller_b, @fixed_master)

      other_policy = log_k(fixture, @caller_a, :DefinitionsCreate)
      assert other_policy |> one_line!() |> Map.fetch!("policy") == "DefinitionsCreate"

      # 2. 59 s later: still inside the window.
      set_clock(clock, 1059)
      assert deny_lines(log_k(fixture, @caller_a, :TenantsManage)) == []

      # 3. 60 s: window elapsed -> emit with suppressed=5 (K#2..K#5 and K#6); K#8 withheld.
      set_clock(clock, 1060)
      assert %{"suppressed" => "5"} = one_line!(log_k(fixture, @caller_a, :TenantsManage))
      assert deny_lines(log_k(fixture, @caller_a, :TenantsManage)) == []

      # 4. another window: suppressed=1.
      set_clock(clock, 1120)
      assert %{"suppressed" => "1"} = one_line!(log_k(fixture, @caller_a, :TenantsManage))

      # 5. nothing withheld in between: no suppressed field.
      set_clock(clock, 1180)
      refute Map.has_key?(one_line!(log_k(fixture, @caller_a, :TenantsManage)), "suppressed")

      # 6. clock moved backwards: emit (never silenced longer than one window).
      set_clock(clock, 500)
      refute Map.has_key?(one_line!(log_k(fixture, @caller_a, :TenantsManage)), "suppressed")
    end

    test "window 0 disables sampling: every denial logs, none carries suppressed", ctx do
      Application.put_env(:letflow, :authz_deny_log_window_s, 0)
      new_clock(1000)

      lines = for _ <- 1..5, do: one_line!(log_k(ctx.a, @caller_a, :TenantsManage))
      assert length(lines) == 5
      refute Enum.any?(lines, &Map.has_key?(&1, "suppressed"))
    end

    test "an invalid window (-1, \"x\", 1.5) behaves as the 60 s default", ctx do
      fixture = sampling_setup(ctx)

      for {invalid, caller} <- [
            {-1, "aaaaaaaa-0000-4000-8000-000000000001"},
            {"x", "aaaaaaaa-0000-4000-8000-000000000002"},
            {1.5, "aaaaaaaa-0000-4000-8000-000000000003"}
          ] do
        Application.put_env(:letflow, :authz_deny_log_window_s, invalid)
        new_clock(1000)

        assert %{} = one_line!(log_k(fixture, caller, :TenantsManage))

        for _ <- 1..4,
            do: assert(deny_lines(log_k(fixture, caller, :TenantsManage)) == [])
      end
    end

    test "50 concurrent denials of one key emit exactly one line; the rest are counted", ctx do
      fixture = sampling_setup(ctx)
      new_clock(1000)
      {conn, access} = direct(fixture, @caller_a, ["PLATFORM_ADMIN"], :TenantsManage)

      # The sampler is created lazily and, by design (section 7), that FIRST-USE creation is the one
      # documented race that may emit an extra line. Warm it up and zero it so this test pins the CAS
      # guarantee alone, whatever order the tests run in.
      log_k(fixture, @caller_b, :TenantsManage)
      AuthzDenyLog.reset()

      # Deterministic race: the sampler reads the clock BEFORE it reads the slot, so a clock that blocks
      # until all 50 tasks have arrived makes every task see "never emitted" and reach the
      # compare-and-swap together. Exactly one may win it; an unconditional write would let all 50 emit.
      arrived = :atomics.new(1, signed: true)

      Application.put_env(:letflow, :authz_deny_log_clock, fn ->
        :atomics.add(arrived, 1, 1)
        await_arrivals(arrived, 50, System.monotonic_time(:millisecond) + 8_000)
        1000
      end)

      log =
        sink_log(fn ->
          1..50
          |> Enum.map(fn _ ->
            Task.async(fn -> AuthzDenyLog.log_denial(conn, access, :TenantsManage) end)
          end)
          |> Task.await_many(10_000)
        end)

      # One CAS winner. A loser may increment the counter between the winner's CAS and its
      # `exchange(..., 0)`, so the winner's own line may already report some of the 49 withheld
      # denials; the invariant is conservation: reported now + reported next window == 49.
      first_count = log |> one_line!() |> Map.get("suppressed", "0") |> String.to_integer()
      assert first_count in 0..49

      new_clock(1060)
      next = log_k(fixture, @caller_a, :TenantsManage) |> one_line!()
      assert first_count + String.to_integer(Map.get(next, "suppressed", "0")) == 49
    end
  end

  # --- (i) never raises / fail-safe -------------------------------------------

  describe "(i) never raises, failure path leaks nothing" do
    test "master key absent or not 32 bytes: same 403, one line, one fallback notice per boot",
         ctx do
      for bad <- [:absent, "too-short"] do
        AuthzDenyLog.reset()

        if bad == :absent,
          do: Application.delete_env(:letflow, :secrets_master_key),
          else: Application.put_env(:letflow, :secrets_master_key, bad)

        log =
          sink_log(fn ->
            first = deny_direct(ctx.a, Ecto.UUID.generate(), ["PLATFORM_ADMIN"], :TenantsManage)
            assert bytes(first) == forbidden_bytes()
            second = deny_direct(ctx.a, Ecto.UUID.generate(), ["PLATFORM_ADMIN"], :TenantsManage)
            assert bytes(second) == forbidden_bytes()
          end)

        assert length(deny_lines(log)) == 2, "#{inspect(bad)}: #{log}"

        for line <- deny_lines(log), do: assert(parse(line)["caller"] =~ ~r/\A[0-9a-f]{16}\z/)

        notices =
          log
          |> String.split("\n")
          |> Enum.filter(&(&1 =~ "authz deny log hash key fallback in use"))

        assert length(notices) == 1, "#{inspect(bad)}: #{log}"
        assert hd(notices) =~ ~r/fallback in use\s*$/

        fallback = :persistent_term.get({AuthzDenyLog, :fallback_key})
        refute String.contains?(log, fallback)
        refute String.contains?(log, Base.encode16(fallback, case: :lower))
      end
    end

    test "a non-binary user id renders caller=none and the 403 is unchanged", ctx do
      log =
        sink_log(fn ->
          conn = deny_direct(ctx.a, 12_345, ["PLATFORM_ADMIN"], :TenantsManage)
          assert bytes(conn) == forbidden_bytes()
        end)

      tokens = one_line!(log)
      assert tokens["caller"] == "none"
      assert tokens["tenant"] == expected_hash(:tenant, ctx.a.tenant_id, master())
      refute log =~ "12345"
    end

    test "a raising clock fails open: the line is emitted, the 403 unchanged, no exception text",
         ctx do
      sentinel = "SENTINEL-USER-ID-777"
      Application.put_env(:letflow, :authz_deny_log_window_s, 60)
      Application.put_env(:letflow, :authz_deny_log_clock, fn -> raise RuntimeError, sentinel end)

      log =
        sink_log(fn ->
          conn = deny_direct(ctx.a, Ecto.UUID.generate(), ["PLATFORM_ADMIN"], :TenantsManage)
          assert bytes(conn) == forbidden_bytes()
        end)

      assert [_one] = deny_lines(log)
      refute log =~ sentinel
    end

    test "a non-integer clock also fails open", ctx do
      Application.put_env(:letflow, :authz_deny_log_window_s, 60)
      Application.put_env(:letflow, :authz_deny_log_clock, fn -> "not-an-integer" end)

      log =
        sink_log(fn ->
          conn = deny_direct(ctx.a, Ecto.UUID.generate(), ["PLATFORM_ADMIN"], :TenantsManage)
          assert bytes(conn) == forbidden_bytes()
        end)

      assert [_one] = deny_lines(log)
    end

    test "the outer failure path returns :ok and logs only the constant line, once per class/module",
         ctx do
      sentinel = "SENTINEL-USER-ID-777"
      access = %AccessContext{user_id: sentinel, roles: [], platform_tenant?: false}
      _ = ctx

      log =
        sink_log(fn ->
          assert :ok = AuthzDenyLog.log_denial(:not_a_conn, access, :SentinelPolicyKey)
          assert :ok = AuthzDenyLog.log_denial(:not_a_conn, access, :SentinelPolicyKey)
        end)

      failure_lines =
        log |> String.split("\n") |> Enum.filter(&String.contains?(&1, "authz_deny_log_failed"))

      assert [line] = failure_lines, "expected exactly one failure line, got: #{log}"

      [_prefix, rest] = String.split(line, "authz_deny_log_failed", parts: 2)
      assert String.trim(rest) =~ ~r/\Aclass=error exception=Elixir\.\w+\z/

      assert deny_lines(log) == []
      refute log =~ sentinel
      refute log =~ "not_a_conn"
      refute log =~ "SentinelPolicyKey"
    end
  end

  # --- (j) allowed requests log nothing ---------------------------------------

  describe "(j) allowed requests and the 500 branch log nothing from this module" do
    test "platform operator on a platform route, tenant admin on a tenant route", ctx do
      log =
        sink_log(fn ->
          {operator, _identity} =
            api(:get, "/api/v1/tenants/" <> ctx.a.tenant.slug, ctx.p, ["PLATFORM_ADMIN"], nil)

          refute operator.status == 403

          {tenant_admin, _identity} =
            api(:get, "/api/v1/definitions", ctx.a, ["PROCESS_DESIGNER"], nil)

          refute tenant_admin.status == 403
        end)

      assert deny_lines(log) == []
    end

    test "a conn without auth_context takes the 500 branch and logs no attribution line" do
      log =
        sink_log(fn ->
          conn = Authorize.call(Plug.Test.conn(:get, "/x"), [])
          assert conn.status == 500
        end)

      assert deny_lines(log) == []
    end
  end

  # --- pure helpers -----------------------------------------------------------

  describe "route_pattern/1 and policy_token/1" do
    test "no :plug_route -> unmatched; the forward glob is removed; the catch-all is kept" do
      conn = Plug.Test.conn(:get, "/anything")
      assert AuthzDenyLog.route_pattern(conn) == "unmatched"

      glob = put_private(conn, :plug_route, {"/api/v1/*glob/tenants/*glob/:slug", fn -> :ok end})
      assert AuthzDenyLog.route_pattern(glob) == "/api/v1/tenants/:slug"

      catch_all =
        put_private(conn, :plug_route, {"/api/v1/*glob/tenants/*glob/*_path", fn -> :ok end})

      assert AuthzDenyLog.route_pattern(catch_all) == "/api/v1/tenants/*_path"
    end

    test "a template that is not printable ASCII (or too long) fails safe to unmatched" do
      conn = Plug.Test.conn(:get, "/anything")

      for bad <- ["/a b", "/a\r\nb", "/a\tb", "/café", "", "/" <> String.duplicate("a", 250)] do
        assert conn
               |> put_private(:plug_route, {bad, fn -> :ok end})
               |> AuthzDenyLog.route_pattern() ==
                 "unmatched"
      end
    end

    test "policy_token/1: printable atom names only" do
      assert AuthzDenyLog.policy_token(:TenantsManage) == "TenantsManage"
      assert AuthzDenyLog.policy_token(:"bad key") == "unknown"
      assert AuthzDenyLog.policy_token(:"bad\nkey") == "unknown"
      assert AuthzDenyLog.policy_token("TenantsManage") == "unknown"
      assert AuthzDenyLog.policy_token(nil) == "nil"
    end
  end
end
