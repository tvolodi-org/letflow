defmodule Letflow.Api.ScopeShadowTest do
  @moduledoc """
  REQ-497 PR 1b, AC8 (decision 0051 Rollout 3): shadow mode computes the org-scope decision
  and COUNTS would-denies, and denies nothing (design
  `lib/letflow/design/req497-1b-allowed-flag-shadow-n1.md` section 4, tests T-S1..T-S5; spec
  `test/specs/REQ-497-1b.md`).

    * T-S1 the real `Letflow.Router` pipeline, API-token and OIDC credentials, a fixed request
      matrix: status and body identical with the tenant flag `off` and `shadow` (in `shadow`
      the OIDC principal's grant rows are removed, so the observer DOES emit would-denies
      while the responses stay identical).
    * T-S2 a principal holding a role whose binding has no grant row: under `shadow` exactly
      one `[:letflow, :scope, :shadow, :would_deny]` event (`reason: :no_grant_rows`) and
      `letflow_scope_shadow_would_deny_total{reason="no_grant_rows"}` +1; under `off` none.
    * T-S3 the sampled log line has the 4.3 shape and carries no bearer token, `lf_tok_`,
      user id, tenant id, e-mail, role name, group id, node id or body value.
    * T-S4 a raising dependency (a corrupted grants memo): `observe/3` returns the conn, the
      request still succeeds, one `scope_shadow_failed` line.
    * T-S5 the 1a binding/membership writers give the same row sets (and T9 0) with the tenant
      in `shadow` as in `off` (writers do not read the flag in stage 1).

  T-S2..T-S4 drive the routers directly with a hand-assigned `auth_context` carrying
  `scope_enforcement` (exactly what `Letflow.Plugs.AuthPipeline` attaches); T-S1 goes through
  the real pipeline, where the flag comes from the tenant row.

  `async: false`: real tenants, the VM-global OIDC verifier selection, platform pin, metrics
  table and once-per-boot `persistent_term` flags.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Letflow.Api.Authorization
  alias Letflow.Api.Scope.Grants
  alias Letflow.Api.Scope.Shadow
  alias Letflow.Api.Scope.ShadowLog
  alias Letflow.Identity
  alias Letflow.Identity.Group
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Metrics.Registry
  alias Letflow.ScopeEnforcement
  alias Letflow.Support.PendingAdminHelper, as: H
  alias Letflow.Support.PendingAdminTokenVerifierDouble, as: Double
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TokenMintFixture
  alias Letflow.TenantFixture

  @event [:letflow, :scope, :shadow, :would_deny]
  @trace "req497-shadow-fixed-trace"
  @bearer "lf_tok_" <> String.duplicate("ab", 32)

  setup do
    ShadowLog.reset()
    erase_failure_flags()
    on_exit(&erase_failure_flags/0)
    :ok
  end

  # --- helpers -----------------------------------------------------------------------------------

  defp erase_failure_flags do
    for {key, _value} <- :persistent_term.get(),
        match?({Shadow, :failure_noted, _class, _mod}, key),
        do: :persistent_term.erase(key)

    :ok
  end

  defp seeded_tenant!(slug_prefix) do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    {:ok, _roles} = RoleRegistry.seed_default_platform_role_groups(prefix: fx.schema_name)
    fx
  end

  @doc false
  def handle_event(_event, measurements, metadata, {pid, ref}) do
    if self() == pid, do: send(pid, {:would_deny, ref, measurements, metadata})
    :ok
  end

  defp attach_would_deny! do
    ref = make_ref()
    :telemetry.attach({__MODULE__, ref}, @event, &__MODULE__.handle_event/4, {self(), ref})
    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  defp drain(ref, acc \\ []) do
    receive do
      {:would_deny, ^ref, measurements, metadata} -> drain(ref, [{measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp counter(reason) do
    Map.get(Registry.snapshot().counters, {:scope_shadow_would_deny_total, %{reason: reason}}, 0)
  end

  defp ctx(fx, user_id, roles, mode) do
    %{
      user_id: user_id,
      tenant_id: fx.tenant_id,
      roles: roles,
      credential: :oidc,
      scope_enforcement: mode
    }
  end

  defp identity_call(auth_context, method, path, body) do
    conn = conn(method, path)

    conn =
      if body,
        do: %{conn | body_params: body} |> put_req_header("content-type", "application/json"),
        else: conn

    conn
    |> put_req_header("authorization", "Bearer " <> @bearer)
    |> assign(:auth_context, auth_context)
    |> assign(:trace_id, @trace)
    |> Letflow.Routers.Identity.call(Letflow.Routers.Identity.init([]))
  end

  # Everything a caller can observe of the response, minus the per-request trace id.
  defp observable(conn) do
    {conn.status, Regex.replace(~r/"trace_id":"[^"]*",?/, conn.resp_body, "")}
  end

  defp shadow_lines(log) do
    log |> String.split("\n") |> Enum.filter(&String.contains?(&1, "scope_shadow_would_deny"))
  end

  # --- T-S5 helpers -------------------------------------------------------------------------

  # Group ids differ per tenant; rows are compared by the group's NAME.
  defp named_rows(schema) do
    for {type, principal_id, role, node, tenant_wide} <- RSG.rows(schema) do
      %Group{name: name} = Repo.get!(Group, principal_id, prefix: schema)
      {type, name, role, node, tenant_wide}
    end
    |> Enum.sort()
  end

  # The 1a T-W subset: new binding, kind change both ways, rebind, member add/remove,
  # default seeding. Returns the named row set after each step.
  defp writer_scenario(schema) do
    a = RSG.group!(schema, "req497-s5-a")
    b = RSG.group!(schema, "req497-s5-b")
    user = RSG.user!(schema)
    opts = [prefix: schema]

    steps = [
      fn ->
        {:ok, _} = RoleRegistry.upsert_role("PROCESS_OPERATOR", :platform_role, a.id, opts)
      end,
      fn ->
        {:ok, _} =
          RoleRegistry.upsert_role("PROCESS_OPERATOR", :process_routing_role, a.id, opts)
      end,
      fn ->
        {:ok, _} = RoleRegistry.upsert_role("PROCESS_OPERATOR", :platform_role, a.id, opts)
      end,
      fn ->
        role = RSG.binding(schema, "PROCESS_OPERATOR")

        {:ok, _} =
          RoleRegistry.rebind_role(role.id, b.id, %{actor_id: nil, reason: "REQ-497 T-S5"}, opts)
      end,
      fn -> {:ok, _} = Identity.add_group_member(b.id, user.id, opts) end,
      fn -> :ok = Identity.remove_group_member(b.id, user.id, opts) end,
      fn -> {:ok, _} = RoleRegistry.seed_default_platform_role_groups(opts) end
    ]

    for step <- steps do
      step.()
      RSG.assert_t9_zero!(schema)
      named_rows(schema)
    end
  end

  # ===========================================================================================
  test "T-S1 a fixed request matrix answers identically under off and shadow, both credentials (real pipeline)" do
    H.use_double!()
    world = H.world!()
    schema = world.tenant.schema_name
    slug = world.tenant.tenant.slug

    # The owner must itself hold the token's role tenant-wide, or the off -> shadow flip is refused
    # with :tokens_exceed_owner (a token whose roles exceed its owner's).
    holder = TokenMintFixture.role_holder!(schema, ["TENANT_ADMIN"])

    {:ok, %{plaintext: api_token}} =
      Identity.create_token(holder.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: schema
      )

    oidc_token =
      Double.token(world.realm,
        sub: "req497-ts1-sub",
        email: "req497-ts1@example.com",
        roles: ["PROCESS_DESIGNER", "TASK_WORKER"]
      )

    paths = [
      "/api/v1/identity/roles",
      "/api/v1/identity/groups",
      "/api/v1/definitions",
      "/api/v1/instances",
      "/api/v1/tasks",
      "/api/v1/tenant/settings",
      "/api/v1/entities/definitions",
      "/api/v1/script-policy"
    ]

    run = fn ->
      for path <- paths, credential <- [:api_token, :oidc], into: %{} do
        conn =
          case credential do
            :api_token ->
              :get |> Fixture.api_conn(path, api_token, slug, nil) |> Fixture.dispatch_api()

            :oidc ->
              conn(:get, path)
              |> put_req_header("authorization", "Bearer " <> oidc_token)
              |> Letflow.Router.call(Letflow.Router.init([]))
          end

        {{credential, path}, observable(conn)}
      end
    end

    ref = attach_would_deny!()

    capture_log(fn ->
      # Warm-up: the first OIDC request provisions the user and syncs its role claims.
      _ = run.()
      off = run.()
      off_events = drain(ref)

      assert Enum.count(off, fn {_key, {status, _body}} -> status == 200 end) >= 3,
             "the matrix must exercise allowed routes: #{inspect(off)}"

      assert {:ok, %{mode: :shadow, changed: true}} =
               ScopeEnforcement.flip(world.tenant.tenant_id, schema, :shadow, %{
                 actor_id: nil,
                 reason: nil,
                 trace_id: nil
               })

      # The OIDC principal now holds its roles through bindings with no row: would-deny.
      for role <- ["PROCESS_DESIGNER", "TASK_WORKER"] do
        assert RSG.raw_delete_rows!(schema, RSG.group_of!(schema, role), role) == 1
      end

      shadow = run.()
      shadow_events = drain(ref)

      assert off_events == []
      assert shadow_events != [], "the shadow observer never ran"
      assert Enum.all?(shadow_events, fn {_m, meta} -> meta.reason == :no_grant_rows end)

      for key <- Map.keys(off) do
        assert shadow[key] == off[key],
               "#{inspect(key)} differs: #{inspect({off[key], shadow[key]})}"
      end
    end)
  end

  # ===========================================================================================
  test "T-S2 a role held through a binding with no row: one would-deny event and counter +1 under shadow, none under off" do
    fx = seeded_tenant!("req497-ts2")
    s = fx.schema_name
    admin = TokenMintFixture.role_holder!(s, ["TENANT_ADMIN"])
    assert RSG.raw_delete_rows!(s, RSG.group_of!(s, "TENANT_ADMIN"), "TENANT_ADMIN") == 1
    ref = attach_would_deny!()

    {{off_conn, shadow_conn, off_delta, shadow_delta}, _log} =
      with_log(fn ->
        before = counter("no_grant_rows")
        off_conn = identity_call(ctx(fx, admin.id, ["TENANT_ADMIN"], :off), :get, "/users", nil)
        off_delta = counter("no_grant_rows") - before
        assert drain(ref) == []

        before = counter("no_grant_rows")

        shadow_conn =
          identity_call(ctx(fx, admin.id, ["TENANT_ADMIN"], :shadow), :get, "/users", nil)

        {off_conn, shadow_conn, off_delta, counter("no_grant_rows") - before}
      end)

    assert [{%{count: 1}, %{reason: :no_grant_rows, policy: :UsersManage}}] = drain(ref)
    assert off_delta == 0
    assert shadow_delta == 1
    assert off_conn.status == 200
    assert observable(shadow_conn) == observable(off_conn)
  end

  # ===========================================================================================
  test "T-S3 the would-deny log line has the 4.3 shape and carries no secret, id, name or body value" do
    fx = seeded_tenant!("req497-ts3")
    s = fx.schema_name
    admin = TokenMintFixture.role_holder!(s, ["TENANT_ADMIN"])
    ta_group = RSG.group_of!(s, "TENANT_ADMIN")
    # The TA group holds TENANT_ADMIN only at one node: the decision is :not_tenant_wide and the
    # node id is in the principal's grants.
    node_id = RSG.make_group_scoped_only!(s, ta_group, "TENANT_ADMIN")
    body_value = "req497-ts3-secret-group-value"

    log =
      capture_log(fn ->
        conn =
          identity_call(ctx(fx, admin.id, ["TENANT_ADMIN"], :shadow), :post, "/groups", %{
            "name" => body_value
          })

        assert conn.status in [200, 201], conn.resp_body
      end)

    assert [line] = shadow_lines(log)

    assert line =~
             ~r/scope_shadow_would_deny method=POST route=\S+ policy=GroupsManage permission=\w+ reason=not_tenant_wide credential=oidc caller=[0-9a-f]{16} tenant=[0-9a-f]{16}/

    for secret <- [
          @bearer,
          "lf_tok_",
          admin.id,
          fx.tenant_id,
          admin.email,
          "TENANT_ADMIN",
          ta_group,
          node_id,
          body_value
        ] do
      refute String.contains?(line, secret), "the line leaks #{inspect(secret)}: #{line}"
    end
  end

  # ===========================================================================================
  describe "T-S4 a raising dependency" do
    setup do
      fx = seeded_tenant!("req497-ts4")
      user_id = TokenMintFixture.role_holder!(fx.schema_name, ["TENANT_ADMIN"]).id
      # A memo of the right user whose rows are not a map: effective_scope/2 raises.
      corrupted = %Grants{user_id: user_id, rows_by_role: :corrupted}
      %{fx: fx, user_id: user_id, corrupted: corrupted}
    end

    test "T-S4a observe/3 returns the original conn and logs one scope_shadow_failed line",
         %{fx: fx, user_id: user_id, corrupted: corrupted} do
      auth_context =
        fx |> ctx(user_id, ["TENANT_ADMIN"], :shadow) |> Map.put(:scope_grants, corrupted)

      conn =
        conn(:get, "/users")
        |> assign(:auth_context, auth_context)
        |> assign(:scoped_opts, prefix: fx.schema_name)

      access = %Authorization.AccessContext{
        user_id: user_id,
        roles: [:TENANT_ADMIN],
        platform_tenant?: false
      }

      {result, log} = with_log(fn -> Shadow.observe(conn, access, :UsersManage) end)

      assert result == conn

      assert [_one] =
               log
               |> String.split("\n")
               |> Enum.filter(&String.contains?(&1, "scope_shadow_failed"))

      assert log =~ "scope_shadow_failed class=error exception=BadMapError"
      refute log =~ user_id
    end

    test "T-S4b the request still succeeds with the same response as under off",
         %{fx: fx, user_id: user_id, corrupted: corrupted} do
      off =
        fx
        |> ctx(user_id, ["TENANT_ADMIN"], :off)
        |> Map.put(:scope_grants, corrupted)
        |> identity_call(:get, "/users", nil)

      {shadow, log} =
        with_log(fn ->
          fx
          |> ctx(user_id, ["TENANT_ADMIN"], :shadow)
          |> Map.put(:scope_grants, corrupted)
          |> identity_call(:get, "/users", nil)
        end)

      assert off.status == 200
      assert observable(shadow) == observable(off)
      assert log =~ "scope_shadow_failed"
    end
  end

  # ===========================================================================================
  describe "T-S5 writers behave identically in shadow" do
    test "T-S5 the same writer sequence gives the same row sets and T9 0 under off and shadow" do
      off = TenantFixture.provisioned_tenant!(slug_prefix: "req497-ts5-off")
      shadow = TenantFixture.provisioned_tenant!(slug_prefix: "req497-ts5-shadow")

      assert {:ok, %{mode: :shadow, changed: true}} =
               ScopeEnforcement.flip(shadow.tenant_id, shadow.schema_name, :shadow, %{
                 actor_id: nil,
                 reason: nil,
                 trace_id: nil
               })

      assert ScopeEnforcement.get_mode(off.tenant_id) == {:ok, :off}
      assert ScopeEnforcement.get_mode(shadow.tenant_id) == {:ok, :shadow}

      off_trace = writer_scenario(off.schema_name)
      shadow_trace = writer_scenario(shadow.schema_name)

      assert length(off_trace) == 7
      assert shadow_trace == off_trace
      # Spot checks that the sequence did write: a row on b for PROCESS_OPERATOR after the rebind.
      assert {:group, "req497-s5-b", "PROCESS_OPERATOR", nil, true} in Enum.at(off_trace, 3)
      refute Enum.any?(Enum.at(off_trace, 1), &match?({_, _, "PROCESS_OPERATOR", _, _}, &1))
    end
  end
end
