defmodule Letflow.Api.Scope.EnforceBackstopTest.FixtureRouter do
  @moduledoc false
  # A test-only router (defined here, NOT under test/support, so the route inventory of the real
  # mounted routers never sees it). Every route sits behind the same policy key; the handlers
  # differ in whether and how they use `Letflow.Api.ScopeGate` and in the status they answer.

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.ScopeGate

  # --- :filter handlers ---
  authz_get "/filter-omits", :InstancesRead, scope: :filter do
    send_resp(conn, 200, "leaked-rows")
  end

  authz_get "/filter-gated", :InstancesRead, scope: :filter do
    {conn, _set} = ScopeGate.scope_set(conn, :InstancesRead)
    send_resp(conn, 200, "gated-rows")
  end

  authz_get "/filter-gated-resource", :InstancesRead, scope: :filter do
    {conn, _allowed} = ScopeGate.resource_allowed?(conn, :InstancesRead, :tenant_wide)
    send_resp(conn, 200, "gated-by-resource")
  end

  authz_get "/filter-omits-201", :InstancesRead, scope: :filter do
    send_resp(conn, 201, "leaked-created")
  end

  authz_get "/filter-omits-204", :InstancesRead, scope: :filter do
    send_resp(conn, 204, "")
  end

  authz_get "/filter-omits-404", :InstancesRead, scope: :filter do
    send_resp(conn, 404, "plain-not-found")
  end

  authz_get "/filter-omits-422", :InstancesRead, scope: :filter do
    send_resp(conn, 422, "plain-unprocessable")
  end

  authz_get "/filter-omits-302", :InstancesRead, scope: :filter do
    conn |> put_resp_header("location", "/elsewhere") |> send_resp(302, "")
  end

  # the handler gates but then answers on the conn it started with, so the marker is lost
  authz_get "/filter-drops-conn", :InstancesRead, scope: :filter do
    {_gated, _set} = ScopeGate.scope_set(conn, :InstancesRead)
    send_resp(conn, 200, "dropped-marker")
  end

  # --- {:resolver, _} handlers ---
  authz_get "/resolver-omits", :InstancesRead,
    scope: {:resolver, {Letflow.Api.RouteScope, :class_of}} do
    send_resp(conn, 200, "leaked-resolver")
  end

  authz_get "/resolver-gated", :InstancesRead,
    scope: {:resolver, {Letflow.Api.RouteScope, :class_of}} do
    {conn, _set} = ScopeGate.scope_set(conn, :InstancesRead)
    send_resp(conn, 200, "resolver-ok")
  end

  # --- classes the backstop must NOT touch ---
  authz_get "/self-service-omits", :InstancesRead, scope: :self_service do
    send_resp(conn, 200, "self-service-body")
  end

  authz_get "/tenant-wide-omits", :InstancesRead, scope: :tenant_wide do
    send_resp(conn, 200, "tenant-wide-body")
  end

  authz_unmatched(:ordinary)
end

defmodule Letflow.Api.Scope.EnforceBackstopTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-i-b, SEC ruling R-4 and design T-B1 (`lib/letflow/design/
  req518-compiler-scope-filter.md` 3.5, 10.1; spec `test/specs/REQ-518-2c-i-b.md`): the DETECTIVE
  before-send backstop `Letflow.Api.Scope.Enforce` registers on `:filter` and `{:resolver, _}`
  routes, through a real router (so `Letflow.Plugs.Authorize` runs in front of the handler).

    * `on`: a handler that omits `ScopeGate` has its 2xx (200, 201, 204) replaced by the
      detail-free 500 and one constant `scope_not_applied` log line; the leaked body never reaches
      the wire; a handler that gates (`scope_set/2` or `resource_allowed?/3`) is untouched;
    * a non-2xx answer (404, 422, 302) of an omitting handler is NOT touched, and no line is logged;
    * a handler that drops the conn `ScopeGate` returned loses the marker and fails closed (500);
    * `off` and `shadow`: the omitting handler answers 200 unchanged (the backstop is registered
      only in the `on` branch) and nothing is logged;
    * `:self_service` and `:tenant_wide` routes are never touched, gate or no gate.

  `async: false`: committed writes and `Logger` capture.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn

  alias Letflow.Api.Response
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.Support.ScopedGrantsFixture, as: S

  @fixture Letflow.Api.Scope.EnforceBackstopTest.FixtureRouter
  @admin "TENANT_ADMIN"

  setup do
    fx = S.tenant!("r518-bk")
    {:ok, fx: fx, scoped: On.scoped_holder!(fx, @admin)}
  end

  defp call_logged(fx, user, path, mode) do
    {conn, log} =
      with_log(fn -> On.call(@fixture, :get, path, fx, user.id, [@admin], mode, nil) end)

    {conn, log}
  end

  defp count(log, needle), do: length(String.split(log, needle)) - 1

  # the detail-free 500 any fail-closed path of the pipeline answers, for the same trace id
  defp internal_error_conn do
    Plug.Test.conn(:get, "/")
    |> assign(:trace_id, S.trace())
    |> Response.internal_error()
  end

  defp assert_detail_free_500(conn) do
    expected = internal_error_conn()
    assert conn.status == 500
    assert conn.resp_body == expected.resp_body
    assert get_resp_header(conn, "content-type") == get_resp_header(expected, "content-type")
    refute conn.resp_body =~ "leaked"
    refute conn.resp_body =~ "scope_not_applied"
  end

  # ===========================================================================================
  describe "T-B1 under on" do
    test "a :filter handler and a {:resolver, _} handler that omit the gate answer the detail-free 500 and log ONE scope_not_applied line; the leaked body never reaches the wire",
         %{fx: fx, scoped: scoped} do
      for path <- ["/filter-omits", "/resolver-omits"] do
        {conn, log} = call_logged(fx, scoped, path, :on)
        assert_detail_free_500(conn)
        assert count(log, "scope_not_applied") == 1, "#{path}: #{log}"
      end
    end

    test "every 2xx status of an omitting handler is replaced (200, 201 and an empty 204)",
         %{fx: fx, scoped: scoped} do
      for path <- ["/filter-omits", "/filter-omits-201", "/filter-omits-204"] do
        {conn, log} = call_logged(fx, scoped, path, :on)
        assert_detail_free_500(conn)
        assert count(log, "scope_not_applied") == 1, path
      end
    end

    test "the same holds for a tenant-wide caller: the backstop checks the handler, not the principal",
         %{fx: fx} do
      {conn, log} = call_logged(fx, fx.admin, "/filter-omits", :on)
      assert_detail_free_500(conn)
      assert count(log, "scope_not_applied") == 1
    end

    test "a handler that calls the gate is untouched: scope_set/2 and resource_allowed?/3 both mark the conn; nothing is logged",
         %{fx: fx, scoped: scoped} do
      for {path, body} <- [
            {"/filter-gated", "gated-rows"},
            {"/filter-gated-resource", "gated-by-resource"},
            {"/resolver-gated", "resolver-ok"}
          ] do
        {conn, log} = call_logged(fx, scoped, path, :on)
        assert conn.status == 200, path
        assert conn.resp_body == body, path
        assert count(log, "scope_not_applied") == 0, path
      end
    end

    test "a non-2xx answer of an omitting handler is NOT replaced (404, 422, 302) and nothing is logged",
         %{fx: fx, scoped: scoped} do
      for {path, status, body} <- [
            {"/filter-omits-404", 404, "plain-not-found"},
            {"/filter-omits-422", 422, "plain-unprocessable"},
            {"/filter-omits-302", 302, ""}
          ] do
        {conn, log} = call_logged(fx, scoped, path, :on)
        assert conn.status == status, path
        assert conn.resp_body == body, path
        assert count(log, "scope_not_applied") == 0, path
      end
    end

    test "a handler that gates but answers on the conn it started with (marker lost) fails closed with the 500",
         %{fx: fx, scoped: scoped} do
      {conn, log} = call_logged(fx, scoped, "/filter-drops-conn", :on)
      assert_detail_free_500(conn)
      refute conn.resp_body =~ "dropped-marker"
      assert count(log, "scope_not_applied") == 1
    end

    test ":self_service and :tenant_wide routes are never touched by the backstop, gate or no gate",
         %{fx: fx, scoped: scoped} do
      {self_service, log} = call_logged(fx, scoped, "/self-service-omits", :on)
      assert self_service.status == 200
      assert self_service.resp_body == "self-service-body"
      assert count(log, "scope_not_applied") == 0

      {tenant_wide, log} = call_logged(fx, fx.admin, "/tenant-wide-omits", :on)
      assert tenant_wide.status == 200
      assert tenant_wide.resp_body == "tenant-wide-body"
      assert count(log, "scope_not_applied") == 0
    end
  end

  # ===========================================================================================
  describe "T-B1 under off and shadow" do
    for mode <- [:off, :shadow] do
      test "#{mode}: the omitting handlers answer 200 unchanged and nothing is logged",
           %{fx: fx, scoped: scoped} do
        mode = unquote(mode)

        for {path, body} <- [
              {"/filter-omits", "leaked-rows"},
              {"/resolver-omits", "leaked-resolver"},
              {"/filter-omits-201", "leaked-created"},
              {"/filter-drops-conn", "dropped-marker"}
            ] do
          {conn, log} = call_logged(fx, scoped, path, mode)
          assert conn.status in [200, 201], "#{path} under #{mode}"
          assert conn.resp_body == body, "#{path} under #{mode}"
          assert count(log, "scope_not_applied") == 0, "#{path} under #{mode}"
        end
      end
    end
  end
end
