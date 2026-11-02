defmodule Letflow.Plugs.AuthorizeTest do
  @moduledoc """
  Direct, DB-free unit tests for `Letflow.Plugs.Authorize` (REQ-131).

  Written by TEST-DESIGNER during REQ-131's WF-02 Step 3 coverage-verification
  pass, closing gaps left by ELIXIR-DEV's `test/letflow/api/authorization_enforcement_test.exs`
  (which only proves every route's *declared* policy key resolves to a real,
  present `Letflow.Api.Authorization.endpoint_policy_key/2` clause — a
  structural check, not a runtime one) and by the router/integration tests
  updated for REQ-131 (`test/letflow/router_test.exs`,
  `test/letflow/plugs/api_pipeline_integration_test.exs`), which only ever
  exercise a caller whose role is dropped entirely (unrecognized "VIEWER"),
  never a real `PLATFORM_ADMIN`.

  `authorization_enforcement_test.exs`'s own moduledoc explicitly defers the
  "route with NO policy key" runtime case to a file named
  `test/letflow/api/authorize_plug_test.exs` for AC5's unmatched-route case —
  that file does not exist anywhere in this codebase (confirmed by a
  filesystem search before writing this one). This file is that missing
  runtime coverage, named to match this module's own location instead
  (`test/letflow/plugs/`, matching every other `Letflow.Plugs.*` test in this
  directory) since router-independent unit coverage of the plug itself is
  the more direct proof.

  Dispatches straight to `Letflow.Plugs.Authorize.call/2` — no router, no
  `Plug.Test` HTTP verb dispatch, no DB — since the plug's own behaviour
  depends only on `conn.private[:policy_key]` and `conn.assigns[:auth_context]`,
  and `Letflow.TenantProvisioning.schema_name_for_tenant/1` (called internally
  via `Letflow.Api.Context.scoped_repo_opts/1`) is pure UUID-string
  manipulation with no I/O (confirmed by reading `lib/letflow/tenant_provisioning.ex`
  directly) — a syntactically valid UUID is sufficient, no real tenant needs
  to exist.

  Covers REQ-131's acceptance criteria:

    * AC1 — a 403 is an RFC 9457 problem document via `Letflow.Api.Response`,
      asserted on both body shape and `Content-Type`.
    * AC4 — the enforcement artefact that fails, at runtime, when a route
      carries no policy key: `no_policy_key_denies_non_admin_test/1` below
      exercises this every run (not just a one-time manual demo during
      implementation).
    * AC5 — an unmatched `(method, path)`, i.e. no `:policy_key` private key
      present, denies every role except `PLATFORM_ADMIN` — both halves: the
      non-admin denial (already indirectly covered elsewhere) AND the
      `PLATFORM_ADMIN` allow, which no other test in this codebase exercises.
    * AC6 — an unrecognized role string is treated as holding no role, not as
      an unknown-but-accepted one, exercised directly against the plug (not
      just `Letflow.Api.Authorization.roles_from_strings/1` in isolation,
      which `test/letflow/api/authorization_test.exs` already covers).
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  import Plug.Test
  import Plug.Conn

  alias Letflow.Plugs.Authorize

  @opts Authorize.init([])

  defp build_conn(auth_context, policy_key \\ :__no_policy_key__) do
    conn = conn(:get, "/whatever") |> assign(:trace_id, "authorize-plug-test-trace")

    conn =
      if is_nil(auth_context) do
        conn
      else
        assign(conn, :auth_context, auth_context)
      end

    case policy_key do
      :__no_policy_key__ -> conn
      key -> put_private(conn, :policy_key, key)
    end
  end

  defp ctx(roles, overrides \\ %{}) do
    Map.merge(
      %{user_id: Ecto.UUID.generate(), tenant_id: Ecto.UUID.generate(), roles: roles},
      overrides
    )
  end

  # ── AC1 — 403 is an RFC 9457 problem document, body shape + Content-Type ──

  describe "AC1: a Deny403 sends an RFC 9457 problem document" do
    test "insufficient role on a real policy key -> 403, problem+json Content-Type, RFC 9457 body shape" do
      conn = build_conn(ctx(["TASK_WORKER"]), :UsersManage) |> Authorize.call(@opts)

      assert conn.status == 403
      assert conn.halted

      assert get_resp_header(conn, "content-type") |> hd() =~ "application/problem+json"

      body = Jason.decode!(conn.resp_body)
      assert body["status"] == 403
      assert Map.has_key?(body, "type")
      assert Map.has_key?(body, "title")
      assert Map.has_key?(body, "detail")
      assert body["detail"] == "insufficient permissions"
    end
  end

  # ── AC4 — the enforcement artefact that fails when a route has no policy key ──
  #
  # This is the RUNTIME half AC4 requires ("FAILS when a route ... carries no
  # policy key"): a route matched with no :policy_key private key set (the
  # plain get/post/patch/delete macros, or a router's own `match _`
  # catch-all) must still deny a non-admin caller -- proving the plug is
  # unconditional rather than opt-in. Unlike authorization_enforcement_test.exs
  # (which asserts every route's DECLARED key resolves to a real matrix
  # clause, a static/structural property), this exercises the actual
  # fail-closed behaviour a route WITHOUT any key gets at request time.

  describe "AC4/AC5: a route with no policy key (:Unknown) is denied for EVERY role (ISS-0993 A2)" do
    test "no :policy_key private key, non-admin role -> 403" do
      conn = build_conn(ctx(["TASK_WORKER"])) |> Authorize.call(@opts)

      assert conn.status == 403
      assert conn.halted
    end

    test "no :policy_key private key, no roles at all -> 403" do
      conn = build_conn(ctx([])) |> Authorize.call(@opts)

      assert conn.status == 403
      assert conn.halted
    end

    test "no :policy_key private key, PLATFORM_ADMIN -> 403 too (A2: :Unknown is denied for every role)" do
      tenant_id = Ecto.UUID.generate()
      conn = build_conn(ctx(["PLATFORM_ADMIN"], %{tenant_id: tenant_id})) |> Authorize.call(@opts)

      assert conn.halted
      assert conn.status == 403
      refute Map.has_key?(conn.assigns, :scoped_opts)
    end
  end

  # ── AC6 — an unrecognized role string is treated as no role ───────────────

  describe "AC6: an unrecognized role string is dropped, not accepted-unknown" do
    test "a token carrying only unrecognized role strings on a real policy key is denied exactly like holding no roles" do
      conn_unrecognized =
        build_conn(ctx(["NOT_A_REAL_ROLE", "ALSO_NOT_REAL"]), :UsersManage)
        |> Authorize.call(@opts)

      conn_no_roles = build_conn(ctx([]), :UsersManage) |> Authorize.call(@opts)

      assert conn_unrecognized.status == 403
      assert conn_no_roles.status == 403
      assert conn_unrecognized.resp_body == conn_no_roles.resp_body
    end

    test "a token mixing a recognized insufficient role with unrecognized strings is still evaluated on only the recognized one" do
      conn_mixed =
        build_conn(ctx(["TASK_WORKER", "NOT_A_REAL_ROLE"]), :UsersManage)
        |> Authorize.call(@opts)

      conn_recognized_only =
        build_conn(ctx(["TASK_WORKER"]), :UsersManage) |> Authorize.call(@opts)

      assert conn_mixed.status == 403
      assert conn_mixed.resp_body == conn_recognized_only.resp_body
    end
  end

  # ── Ordering / structural: missing auth_context is a 500, never silently allowed ──

  describe "ordering: this plug requires auth_context already populated" do
    test "no auth_context assigned at all -> 500, never reaches the authorization decision" do
      conn = build_conn(nil, :UsersManage) |> Authorize.call(@opts)

      assert conn.status == 500
      assert conn.halted
      refute Map.has_key?(conn.assigns, :scoped_opts)
    end

    test "an invalid tenant_id in auth_context -> 500, never reaches the authorization decision" do
      conn =
        build_conn(ctx(["TENANT_ADMIN"], %{tenant_id: "not-a-uuid"}), :UsersManage)
        |> Authorize.call(@opts)

      assert conn.status == 500
      assert conn.halted
    end
  end

  # ── Sufficient role on a real policy key still passes ──────────────────────

  describe "a sufficient role on a real policy key passes through" do
    test "TENANT_ADMIN on :UsersManage is allowed, scoped_opts and access_decision assigned" do
      tenant_id = Ecto.UUID.generate()

      conn =
        build_conn(ctx(["TENANT_ADMIN"], %{tenant_id: tenant_id}), :UsersManage)
        |> Authorize.call(@opts)

      refute conn.halted
      assert conn.status == nil
      assert conn.assigns.scoped_opts == [prefix: "tenant_" <> String.replace(tenant_id, "-", "")]
      assert conn.assigns.access_decision.kind == :Allow
    end

    # REQ-447 PR 2: the legacy own-tenant PLATFORM_ADMIN power is removed -- outside the platform
    # tenant (here: no pin at all) a hand-assigned PLATFORM_ADMIN holds nothing.
    test "a PLATFORM_ADMIN outside the platform tenant is denied on :UsersManage" do
      tenant_id = Ecto.UUID.generate()

      conn =
        build_conn(ctx(["PLATFORM_ADMIN"], %{tenant_id: tenant_id}), :UsersManage)
        |> Authorize.call(@opts)

      assert conn.halted
      assert conn.status == 403
      refute Map.has_key?(conn.assigns, :scoped_opts)
    end
  end
end
