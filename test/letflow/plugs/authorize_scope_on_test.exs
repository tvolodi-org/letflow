defmodule Letflow.Plugs.AuthorizeScopeOnTest.FixtureRouter do
  @moduledoc false
  # A test-only router (defined here, NOT under test/support, so the route inventory of the real
  # mounted routers never sees it) with one route of every scope class, all behind the same policy
  # key, whose handler answers a recognisable 200 body. It proves what `Letflow.Plugs.Authorize`
  # does under `on` for each class WITHOUT depending on any real handler. The `:filter` and
  # `{:resolver, _}` handlers call `Letflow.Api.ScopeGate` as a real handler must (REQ-518 R-4
  # backstop: a 2xx without the gate marker is a 500 under `on`).

  use Letflow.Api.AuthorizedRouter

  authz_get "/filtered", :InstancesRead, scope: :filter do
    {conn, _set} = Letflow.Api.ScopeGate.scope_set(conn, :InstancesRead)
    send_resp(conn, 200, "handler-ran")
  end

  authz_get "/resolver", :InstancesRead,
    scope: {:resolver, {Letflow.Api.RouteScope, :class_of}} do
    {conn, _set} = Letflow.Api.ScopeGate.scope_set(conn, :InstancesRead)
    send_resp(conn, 200, "handler-ran")
  end

  authz_get "/self-service", :InstancesRead, scope: :self_service do
    send_resp(conn, 200, "handler-ran")
  end

  authz_get "/explicit", :InstancesRead, scope: :tenant_wide do
    send_resp(conn, 200, "handler-ran")
  end

  authz_get "/default", :InstancesRead do
    send_resp(conn, 200, "handler-ran")
  end

  # an admin-plane key that (wrongly) declares :filter: the key table wins at runtime
  authz_get "/weakened-admin", :GroupsManage, scope: :filter do
    send_resp(conn, 200, "handler-ran")
  end

  authz_unmatched(:ordinary)
end

defmodule Letflow.Plugs.AuthorizeScopeOnTest do
  @moduledoc """
  REQ-517 / GH #2535 PR 2b, AC 19 (design
  `lib/letflow/design/req517-scoped-grants-admin-plane.md` section 4.3; spec
  `test/specs/REQ-517-2b.md`, T-G2..T-G5, T-G9, T-C9 and the `Authorize` third branch): what
  `Letflow.Plugs.Authorize` does for a tenant stored `on`, `shadow` and `off`, through real routers
  (so the plug runs in front of a real handler):

    * a seeded fixture router with one route per class: under `on` a scoped-only caller is refused
      403 on the `:tenant_wide` route, the DEFAULT-sourced route (fail closed, T-G3) and an
      admin-plane key that declares `:filter` (the key table wins), and PASSES THROUGH to the
      handler on the `:filter`, `:self_service` and `{:resolver, _}` routes (T-G4); a tenant-wide
      holder reaches every handler; an explicit `:tenant_wide` route and a default-sourced one
      behave identically (T-C9);
    * under `off` and `shadow` the same scoped caller reaches every handler (the plug never halts);
    * the real tasks list (`AllowWithRowFilter`): a tenant-wide TASK_WORKER gets the same 200 body
      under `on` as under `off` (T-G9), a scoped-only worker gets the 200 filtered page
      since REQ-518 2d reclassified GET /tasks to `:filter` (it was a 403 before);
    * the unmatched-route catch-all of a real router keeps its uniform 403 under `on` (T-G5).

  `async: false`: committed writes and VM-global telemetry handlers.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn

  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.Support.ScopedGrantsFixture, as: S
  alias Letflow.Support.TokenMintFixture

  @fixture Letflow.Plugs.AuthorizeScopeOnTest.FixtureRouter
  @admin "TENANT_ADMIN"

  defp fixture_call(path, fx, user_id, mode),
    do: On.call(@fixture, :get, path, fx, user_id, [@admin], mode, nil)

  # ===========================================================================================
  describe "T-G4 / T-G3 / T-C9 under on" do
    setup do
      fx = S.tenant!("r517-aon")
      %{fx: fx, scoped: On.scoped_holder!(fx, @admin), ref: On.attach_enforce_denied!()}
    end

    test "a scoped-only caller passes through to the handler on :filter, :self_service and {:resolver, _} routes (N3)",
         %{fx: fx, scoped: scoped, ref: ref} do
      for path <- ["/filtered", "/self-service", "/resolver"] do
        conn = fixture_call(path, fx, scoped.id, :on)
        assert conn.status == 200, path
        assert conn.resp_body == "handler-ran", path
      end

      assert On.drain(ref) == []
    end

    test "a scoped-only caller is refused 403 on the :tenant_wide route, on a route with NO declared class, and on an admin key that declares :filter",
         %{fx: fx, scoped: scoped, ref: ref} do
      for path <- ["/explicit", "/default", "/weakened-admin"] do
        conn = fixture_call(path, fx, scoped.id, :on)
        assert conn.status == 403, path
        assert conn.halted, path
        assert Jason.decode!(conn.resp_body)["detail"] == "insufficient permissions", path
        refute conn.resp_body =~ "handler-ran"
      end

      policies = ref |> On.drain() |> Enum.map(fn {_m, meta} -> meta.policy end)
      assert policies == [:InstancesRead, :InstancesRead, :GroupsManage]
    end

    test "an explicit :tenant_wide route and a default-sourced route answer identical bytes (T-C9)",
         %{fx: fx, scoped: scoped} do
      explicit = fixture_call("/explicit", fx, scoped.id, :on)
      default = fixture_call("/default", fx, scoped.id, :on)

      assert explicit.status == default.status
      assert explicit.resp_body == default.resp_body
      assert get_resp_header(explicit, "content-type") == get_resp_header(default, "content-type")

      tenant_wide_explicit = fixture_call("/explicit", fx, fx.admin.id, :on)
      tenant_wide_default = fixture_call("/default", fx, fx.admin.id, :on)
      assert tenant_wide_explicit.status == 200 and tenant_wide_default.status == 200
      assert tenant_wide_explicit.resp_body == tenant_wide_default.resp_body
    end

    test "a tenant-wide holder reaches every handler, whatever the class",
         %{fx: fx, ref: ref} do
      for path <- [
            "/filtered",
            "/self-service",
            "/resolver",
            "/explicit",
            "/default",
            "/weakened-admin"
          ] do
        conn = fixture_call(path, fx, fx.admin.id, :on)
        assert conn.status == 200, path
        assert conn.resp_body == "handler-ran", path
      end

      assert On.drain(ref) == []
    end

    test "the coarse deny still comes first: a caller with no role is refused by the unchanged plug, no enforce event",
         %{fx: fx, ref: ref} do
      conn =
        On.call(@fixture, :get, "/default", fx, Ecto.UUID.generate(), [], :on, nil)

      assert conn.status == 403
      assert On.drain(ref) == []
    end

    test "pass-through classes apply only AFTER the coarse allow: a caller with no role is refused 403 on :self_service, :filter and {:resolver, _} routes, in every mode (AC 19)",
         %{fx: fx, ref: ref} do
      for mode <- [:off, :shadow, :on], path <- ["/self-service", "/filtered", "/resolver"] do
        conn = On.call(@fixture, :get, path, fx, Ecto.UUID.generate(), [], mode, nil)
        assert conn.status == 403, "#{path} under #{mode}"
        assert conn.halted, "#{path} under #{mode}"
        refute conn.resp_body =~ "handler-ran", "#{path} under #{mode}"
      end

      assert On.drain(ref) == []
    end

    test "pass-through classes are never reached by an unauthenticated request (no auth_context at all): halted, the handler never runs (AC 19)",
         _context do
      for path <- ["/self-service", "/filtered", "/resolver", "/default"] do
        conn = Plug.Test.conn(:get, path) |> then(&@fixture.call(&1, @fixture.init([])))

        assert conn.halted, path
        assert conn.status in 400..599, path
        refute conn.resp_body =~ "handler-ran", path
      end
    end

    test "the router's own catch-all keeps its uniform 403 for a non-operator under on (T-G5)",
         %{fx: fx, scoped: scoped, ref: ref} do
      conn = fixture_call("/no/such/route", fx, scoped.id, :on)

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["detail"] == "insufficient permissions"
      # the skipped key (:UnmatchedRoute) is never enforced: the 403 is the coarse deny
      assert On.drain(ref) == []
    end
  end

  # ===========================================================================================
  test "T-G5 the platform operator still reaches the router's own 404 under on (the skipped key is not enforced)" do
    fx = S.tenant!("r517-aon-404")
    Fixture.pin!(fx.tenant_id)
    operator = RSG.user!(fx.schema_name)
    ref = On.attach_enforce_denied!()

    conn =
      On.call(@fixture, :get, "/no/such/route", fx, operator.id, ["PLATFORM_ADMIN"], :on, nil)

    assert conn.status == 404
    assert On.drain(ref) == []
  end

  # ===========================================================================================
  describe "off and shadow never halt in front of a handler" do
    for mode <- [:off, :shadow] do
      test "#{mode}: a scoped-only caller reaches the handler on every class" do
        mode = unquote(mode)
        fx = S.tenant!("r517-aon-#{mode}")
        scoped = On.scoped_holder!(fx, @admin)
        ref = On.attach_enforce_denied!()

        for path <-
              [
                "/filtered",
                "/self-service",
                "/resolver",
                "/explicit",
                "/default",
                "/weakened-admin"
              ] do
          conn = fixture_call(path, fx, scoped.id, mode)
          assert conn.status == 200, "#{path} under #{mode}"
          assert conn.resp_body == "handler-ran", "#{path} under #{mode}"
        end

        assert On.drain(ref) == []
      end
    end
  end

  # ===========================================================================================
  describe "T-G9 the real tasks list (AllowWithRowFilter)" do
    test "a tenant-wide TASK_WORKER gets the same 200 body under on as under off; a scoped-only worker gets 200 and the filtered body (REQ-518 2d)" do
      fx = S.tenant!("r517-aon-tasks")
      worker = TokenMintFixture.role_holder!(fx.schema_name, ["TASK_WORKER"])
      scoped_worker = On.scoped_holder!(fx, "TASK_WORKER")
      router = Letflow.Routers.Tasks

      off = On.call(router, :get, "/", fx, worker.id, ["TASK_WORKER"], :off, nil)
      on = On.call(router, :get, "/", fx, worker.id, ["TASK_WORKER"], :on, nil)

      assert off.status == 200
      assert on.status == 200
      assert on.resp_body == off.resp_body
      assert Jason.decode!(on.resp_body) == %{"items" => [], "next_cursor" => nil, "count" => 0}

      ref = On.attach_enforce_denied!()
      # REQ-518 2d: GET /tasks is a :filter route, so the scoped-only worker is no longer refused
      # by the tenant-wide rule; the F1 filter answers 200 with the (here empty) filtered page.
      filtered = On.call(router, :get, "/", fx, scoped_worker.id, ["TASK_WORKER"], :on, nil)
      assert filtered.status == 200

      assert Jason.decode!(filtered.resp_body) == %{
               "items" => [],
               "next_cursor" => nil,
               "count" => 0
             }

      assert On.drain(ref) == []

      # off: unchanged, the same scoped worker is not refused by the scope rule
      assert On.call(router, :get, "/", fx, scoped_worker.id, ["TASK_WORKER"], :off, nil).status ==
               200
    end
  end
end
