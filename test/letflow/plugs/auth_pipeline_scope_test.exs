defmodule Letflow.Plugs.AuthPipelineScopeTest do
  @moduledoc """
  REQ-497 PR 1b (GH #2533), AC6: the per-request scope-enforcement flag and the OIDC grants
  load/memo in `Letflow.Plugs.AuthPipeline`. Design
  `lib/letflow/design/req497-1b-allowed-flag-shadow-n1.md` section 2 (r1, CDV B1) and 12.2, plus
  section 18 (SECURITY-REVIEWER r2 availability advisory); spec `test/specs/REQ-497-1b.md`,
  tests T-P1..T-P4 and T-P5 (grants load failure).

  The real `AuthPipeline.call/2` is driven with `Letflow.Oidc.ConfigurableTokenVerifierDouble`
  (`"realm-token:<realm>"`, swapped in per test exactly as `authorization_ac9_test.exs` does) for
  OIDC, and with a real minted API token for the token branch. Query counts come from the
  `[:letflow, :repo, :query]` telemetry of the calling process
  (`PlatformTenantFixture.capture_repo_queries/1`), matched on each query's `source` table.

  Binding rulings pinned here:

    * the OIDC grants load runs on EVERY request whatever the flag (one query on
      `role_scope_grants`, in the same step as and right after the role read);
    * a `Postgrex.Error` (table made unreadable) or a `DBConnection.ConnectionError` (the query
      outlives the Repo timeout behind a held ACCESS EXCLUSIVE lock) during that load does not
      fail the login: the memo is `:not_loaded`, `allowed?/3` denies `:grants_unavailable`, and
      `principal_from_conn/1` does NOT retry (zero queries).

  The API-token query count: the pinned literal is the three statements the token branch
  issues today (`get_tenant_by_slug` on `tenants`, the `verify_api_token` select and the
  best-effort `last_used_at` update on `api_tokens`). `last_used_at` is reset before each
  measured request so the update always runs (otherwise an unchanged second-truncated value
  would make Ecto skip it and the count would depend on the wall clock).

  `async: false`: dedicated provisioned tenants (sandbox `:auto`), DDL and cross-connection
  locks, and the VM-global `:oidc` config swap.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Letflow.Api.Scope
  alias Letflow.Api.Scope.Grants
  alias Letflow.Identity
  alias Letflow.Identity.ApiToken
  alias Letflow.Oidc.ConfigurableTokenVerifierDouble
  alias Letflow.Plugs.AuthPipeline
  alias Letflow.ScopeEnforcement
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.TokenMintFixture
  alias Letflow.TenantFixture

  @would_deny [:letflow, :scope, :shadow, :would_deny]

  setup do
    original_oidc_config = Application.fetch_env!(:letflow, :oidc)

    Application.put_env(
      :letflow,
      :oidc,
      Keyword.put(original_oidc_config, :token_verifier, ConfigurableTokenVerifierDouble)
    )

    on_exit(fn -> Application.put_env(:letflow, :oidc, original_oidc_config) end)
    Fixture.unpin!()
    :ok
  end

  # --- fixtures --------------------------------------------------------------------------------

  defp oidc_tenant!(prefix) do
    realm = Letflow.TenantSlugFixture.unique_realm(prefix)

    fx =
      TenantFixture.provisioned_tenant!(
        slug_prefix: prefix,
        display_name: "REQ-497 1b pipeline tenant",
        oidc_mode: :enabled,
        idp_realm_id: realm
      )

    Map.put(fx, :realm, realm)
  end

  defp oidc_conn(fx, method, path) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer realm-token:" <> fx.realm)
  end

  defp run_pipeline(conn), do: AuthPipeline.call(conn, AuthPipeline.init([]))

  defp oidc!(fx) do
    conn = fx |> oidc_conn(:get, "/whatever") |> run_pipeline()
    refute conn.halted, "OIDC request was rejected: #{inspect(conn.resp_body)}"
    conn
  end

  # First request JIT-provisions the OIDC user; it then gets TENANT_ADMIN by group membership
  # (binding plus its tenant-wide group row from TokenMintFixture). Returns the user id.
  defp oidc_admin!(fx) do
    user_id = oidc!(fx).assigns.auth_context.user_id
    TokenMintFixture.grant_roles!(fx.schema_name, user_id, ["TENANT_ADMIN"])
    user_id
  end

  defp flip!(fx, :shadow) do
    assert {:ok, %{mode: :shadow}} =
             ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :shadow, %{
               actor_id: nil,
               reason: nil,
               trace_id: nil
             })
  end

  defp flip!(fx, :off) do
    assert {:ok, %{mode: :off}} =
             ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :off, %{
               actor_id: nil,
               reason: "REQ-497 1b pipeline test",
               trace_id: nil
             })
  end

  # The plug's own prefix as Letflow.Plugs.Authorize assigns it (AuthPipeline alone does not).
  defp with_prefix(conn, fx), do: assign(conn, :scoped_opts, prefix: fx.schema_name)

  defp sources(queries), do: Enum.map(queries, &Map.get(&1, :source))

  defp reset_last_used!(fx) do
    Repo.update_all(ApiToken, [set: [last_used_at: nil]], prefix: fx.schema_name)
  end

  # A TENANT_ADMIN token whose owner holds TENANT_ADMIN by group membership, so the token's
  # roles do not exceed the owner's (otherwise the off -> shadow flip is refused).
  defp admin_token!(fx) do
    owner = TokenMintFixture.role_holder!(fx.schema_name, ["TENANT_ADMIN"])

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(owner.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: fx.schema_name
      )

    plaintext
  end

  defp token_conn(fx, plaintext) do
    conn(:get, "/whatever")
    |> put_req_header("authorization", "Bearer " <> plaintext)
    |> put_req_header("x-tenant-slug", fx.tenant.slug)
  end

  @doc false
  def handle_event(event, measurements, metadata, test_pid),
    do: send(test_pid, {:telemetry, event, measurements, metadata})

  # --- T-P1 ------------------------------------------------------------------------------------

  test "T-P1 OIDC under off AND shadow: the memo is the Grants struct load_grants/2 returns, and principal_from_conn/1 twice issues 0 queries" do
    fx = oidc_tenant!("req497-p1")
    user_id = oidc_admin!(fx)

    for mode <- [:off, :shadow] do
      if mode == :shadow, do: flip!(fx, :shadow)

      conn = oidc!(fx)
      ctx = conn.assigns.auth_context

      assert ctx.credential == :oidc
      assert ctx.scope_enforcement == mode
      assert %Grants{user_id: ^user_id} = ctx.scope_grants
      assert ctx.scope_grants == Scope.load_grants(user_id, fx.schema_name)
      assert Map.has_key?(ctx.scope_grants.rows_by_role, "TENANT_ADMIN")

      conn = with_prefix(conn, fx)

      {{first, second}, queries} =
        Fixture.capture_repo_queries(fn ->
          {:ok, conn2, p1} = Scope.principal_from_conn(conn)
          {:ok, _conn3, p2} = Scope.principal_from_conn(conn2)
          {p1, p2}
        end)

      assert queries == [], "memoised principal issued #{length(queries)} queries (#{mode})"
      assert first.grants == ctx.scope_grants
      assert second.grants == ctx.scope_grants
    end
  end

  # --- T-P2 ------------------------------------------------------------------------------------

  test "T-P2 API token: the pipeline's queries are identical under off and shadow, equal to the pinned literal, and scope_grants is :token" do
    fx = oidc_tenant!("req497-p2")
    plaintext = admin_token!(fx)

    measured =
      for mode <- [:off, :shadow] do
        if mode == :shadow, do: flip!(fx, :shadow)
        reset_last_used!(fx)

        {conn, queries} =
          Fixture.capture_repo_queries(fn -> fx |> token_conn(plaintext) |> run_pipeline() end)

        refute conn.halted
        assert conn.assigns.auth_context.credential == :api_token
        assert conn.assigns.auth_context.scope_enforcement == mode
        assert conn.assigns.auth_context.scope_grants == :token
        sources(queries)
      end

    [off, shadow] = measured
    assert off == shadow
    # Pinned literal: get_tenant_by_slug, the verify_api_token select, the last_used_at update.
    assert off == ["tenants", "api_tokens", "api_tokens"]
    refute "role_scope_grants" in off
  end

  # --- T-P3 ------------------------------------------------------------------------------------

  describe "T-P3 OIDC query count" do
    test "identical under off and shadow; exactly one grants query, right after the role read" do
      fx = oidc_tenant!("req497-p3")
      _user_id = oidc_admin!(fx)

      measured =
        for mode <- [:off, :shadow] do
          if mode == :shadow, do: flip!(fx, :shadow)
          {conn, queries} = Fixture.capture_repo_queries(fn -> oidc!(fx) end)
          assert conn.assigns.auth_context.scope_enforcement == mode
          sources(queries)
        end

      [off, shadow] = measured
      assert off == shadow
      assert Enum.count(off, &(&1 == "role_scope_grants")) == 1
      # The same step: the role read (group_members join tenant_role), then the grants load,
      # and nothing after it.
      assert Enum.take(off, -2) == ["group_members", "role_scope_grants"]
    end

    test "a hand-assigned context without scope_grants makes principal_from_conn/1 load once; a second call issues 0 queries" do
      fx = oidc_tenant!("req497-p3b")
      user = TokenMintFixture.role_holder!(fx.schema_name, ["TENANT_ADMIN"])

      conn =
        conn(:get, "/whatever")
        |> assign(:auth_context, %{
          user_id: user.id,
          tenant_id: fx.tenant_id,
          roles: ["TENANT_ADMIN"],
          credential: :oidc
        })
        |> with_prefix(fx)

      {{:ok, conn2, p1}, first} =
        Fixture.capture_repo_queries(fn -> Scope.principal_from_conn(conn) end)

      assert sources(first) == ["role_scope_grants"]
      assert p1.grants == Scope.load_grants(user.id, fx.schema_name)
      assert conn2.assigns.auth_context.scope_grants == p1.grants

      {{:ok, _conn3, p2}, second} =
        Fixture.capture_repo_queries(fn -> Scope.principal_from_conn(conn2) end)

      assert second == []
      assert p2.grants == p1.grants
    end
  end

  # --- T-P4 ------------------------------------------------------------------------------------

  test "T-P4 the flag is read per request: after flip/4 the very next request carries the new mode, both credentials" do
    fx = oidc_tenant!("req497-p4")
    _user_id = oidc_admin!(fx)
    plaintext = admin_token!(fx)

    token_mode = fn ->
      (fx |> token_conn(plaintext) |> run_pipeline()).assigns.auth_context.scope_enforcement
    end

    assert oidc!(fx).assigns.auth_context.scope_enforcement == :off
    assert token_mode.() == :off

    flip!(fx, :shadow)
    assert oidc!(fx).assigns.auth_context.scope_enforcement == :shadow
    assert token_mode.() == :shadow

    flip!(fx, :off)
    assert oidc!(fx).assigns.auth_context.scope_enforcement == :off
    assert token_mode.() == :off
  end

  # --- T-P5 (binding ruling: grants load failure) -----------------------------------------------

  describe "T-P5 a failing OIDC grants load gives :not_loaded and does not fail the login" do
    test "Postgrex.Error (role_scope_grants unreadable): 200 through the full router, memo :not_loaded, :grants_unavailable, no retry" do
      fx = oidc_tenant!("req497-p5a")
      user_id = oidc_admin!(fx)
      flip!(fx, :shadow)

      handler = {__MODULE__, make_ref()}
      :telemetry.attach(handler, @would_deny, &__MODULE__.handle_event/4, self())

      table = ~s|"#{fx.schema_name}".role_scope_grants|
      Repo.query!("ALTER TABLE #{table} RENAME TO role_scope_grants_req497_hidden")

      {conn, log} =
        try do
          with_log(fn ->
            fx
            |> oidc_conn(:get, "/api/v1/identity/tokens")
            |> Letflow.Router.call(Letflow.Router.init([]))
          end)
        after
          Repo.query!(
            ~s|ALTER TABLE "#{fx.schema_name}".role_scope_grants_req497_hidden RENAME TO role_scope_grants|
          )

          :telemetry.detach(handler)
        end

      # The login and the route succeeded; nothing was denied.
      assert conn.status == 200
      assert conn.assigns.auth_context.user_id == user_id
      assert conn.assigns.auth_context.scope_grants == :not_loaded

      assert log =~ "scope_grants_load_failed credential=oidc"
      [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ "scope_grants_load_failed"))
      refute line =~ user_id
      refute line =~ fx.schema_name
      refute line =~ "role_scope_grants"

      # The shadow observer counted it as :grants_unavailable (it did not retry the load).
      assert_received {:telemetry, @would_deny, %{count: 1}, %{reason: :grants_unavailable}}

      assert_not_loaded_is_final(conn, fx)
    end

    @tag timeout: 120_000
    test "connection-level failure (the grants query outlives the Repo timeout behind a held lock): memo :not_loaded, no retry" do
      fx = oidc_tenant!("req497-p5b")
      user_id = oidc_admin!(fx)
      parent = self()

      holder =
        Task.async(fn ->
          Repo.transaction(
            fn ->
              Repo.query!(
                ~s|LOCK TABLE "#{fx.schema_name}".role_scope_grants IN ACCESS EXCLUSIVE MODE|
              )

              send(parent, :grants_locked)

              receive do
                :release -> :ok
              after
                60_000 -> :ok
              end
            end,
            timeout: 90_000
          )
        end)

      try do
        assert_receive :grants_locked, 5_000

        # The real pipeline (default Repo timeout) hits a connection-level failure inside
        # load_grants/2. Depending on the driver path it surfaces as DBConnection.ConnectionError
        # or Postgrex.Error (57014 query_canceled); both must give :not_loaded. The raw exception
        # class of a standalone query is deliberately not asserted (no timing dependence).
        {conn, log} = with_log(fn -> oidc!(fx) end)

        assert conn.assigns.auth_context.user_id == user_id
        assert conn.assigns.auth_context.scope_grants == :not_loaded
        assert log =~ "scope_grants_load_failed credential=oidc"

        # The captured log is debug level (it includes SQL), so the no-leak check is on the failure line.
        [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ "scope_grants_load_failed"))
        refute line =~ user_id
        refute line =~ fx.schema_name

        send(holder.pid, :release)
        assert {:ok, {:ok, :ok}} = Task.yield(holder, 10_000)

        assert_not_loaded_is_final(conn, fx)
      after
        if Process.alive?(holder.pid) do
          send(holder.pid, :release)
          Task.shutdown(holder, 5_000)
        end
      end
    end
  end

  # With the table readable again: the :not_loaded memo is NOT retried (0 queries) and the
  # decision is :grants_unavailable.
  defp assert_not_loaded_is_final(conn, fx) do
    conn = with_prefix(conn, fx)

    {{:ok, _conn, principal}, queries} =
      Fixture.capture_repo_queries(fn -> Scope.principal_from_conn(conn) end)

    assert queries == []
    assert principal.grants == :not_loaded
    assert :TENANT_ADMIN in principal.roles

    assert Scope.allowed?(principal, :UsersGroupsRolesManage, :tenant_wide) ==
             {:deny, :grants_unavailable}
  end
end
