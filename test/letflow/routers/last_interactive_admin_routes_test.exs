defmodule Letflow.Routers.LastInteractiveAdminRoutesTest do
  @moduledoc """
  GH #2869 part (a) (design `lib/letflow/design/gh2869-last-interactive-admin-guard.md` r4,
  section 3.8 and T-LA-H1..H7, T-LA-23 HTTP half; spec
  `test/specs/GH2869-last-interactive-admin-guard.md`): the seven mapped routes answer a typed
  409 `last_interactive_tenant_wide_admin` for the last interactive admin of an `on` tenant.

    * every route in the "last interactive" fixture (a live TENANT_ADMIN token owner exists, so
      the OLD guard would pass): status 409, `detail` the new code, the body names NO id of any
      principal, binding or group and carries NO count, and nothing changed;
    * every route that already had the old guard answers the OLD code `last_tenant_wide_admin`
      when no token owner is left (the older rule wins, the mapping is unchanged);
    * `PUT /users/:id/service-principal` has its own clause BEFORE the server-fault catch-all
      (without it the refusal would surface as a 500: MU-LA-14);
    * every route answers the detail-free 500 when the stored mode cannot be read (fail closed,
      INV-8), changing nothing.

  Requests are dispatched straight into the routers with a hand-assigned `auth_context` for the
  tenant's interactive TENANT_ADMIN A1. `async: false`: committed state, committed DDL.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Support.LastInteractiveAdminFixture, as: LIA
  alias Letflow.Support.OnGateFixture, as: F
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopedGrantsFixture, as: SG

  @identity Letflow.Routers.Identity
  @grants Letflow.Routers.TenantRoleScopeGrants

  @routes [:h1a, :h1b, :h2, :h3, :h4, :h5, :h6]
  @old_guarded [:h1a, :h1b, :h2, :h3, :h4, :h5]

  setup do
    LIA.purge_stale!()
    :ok
  end

  # --- the seven routes as data ----------------------------------------------------------------
  #
  # prepare(route, fx) does the RAW setup the route needs (a zero-row admin group for the grant
  # row delete and the F3 shape of the rebind) and returns the request data.

  defp prepare(:h4, fx) do
    _row_id = LIA.userize_admin_row!(fx)
    {group, _member} = LIA.rowless_group_with_member!(fx)
    %{group_id: group.id}
  end

  defp prepare(:h5, fx), do: %{row_id: LIA.userize_admin_row!(fx)}
  defp prepare(_route, _fx), do: %{}

  # the request: {router, method, path, body}
  defp request(:h1a, fx, _data),
    do: {@identity, :patch, "/users/#{fx.admin.id}", %{"status" => "inactive"}}

  defp request(:h1b, fx, _data),
    do: {@identity, :post, "/users/#{fx.admin.id}/status", %{"status" => "inactive"}}

  defp request(:h2, fx, _data),
    do: {@identity, :delete, "/groups/#{fx.ta_group_id}/members/#{fx.admin.id}", nil}

  defp request(:h3, fx, _data),
    do:
      {@identity, :post, "/roles",
       %{"name" => "TENANT_ADMIN", "kind" => "process_routing_role", "group_id" => fx.ta_group_id}}

  defp request(:h4, fx, %{group_id: group_id}),
    do:
      {@identity, :post, "/roles/#{fx.binding.id}/rebind",
       %{"group_id" => group_id, "reason" => LIA.reason()}}

  defp request(:h5, _fx, %{row_id: row_id}), do: {@grants, :delete, "/#{row_id}", nil}

  defp request(:h6, fx, _data),
    do:
      {@identity, :put, "/users/#{fx.admin.id}/service-principal",
       %{"flagged" => true, "reason" => LIA.reason()}}

  defp send_request(route, fx, data) do
    {router, method, path, body} = request(route, fx, data)
    SG.as_admin(router, method, path, fx, body)
  end

  # nothing of the 409 identifies a principal, a binding, a group or a count
  defp assert_detail_free!(conn, fx) do
    body = SG.body(conn)
    refute F.uuid_in?(conn.resp_body), conn.resp_body
    refute conn.resp_body =~ fx.admin.id
    refute conn.resp_body =~ fx.t1.id
    refute conn.resp_body =~ fx.ta_group_id
    refute conn.resp_body =~ fx.binding.id
    refute Map.has_key?(body, "counted_admins")
    refute Map.has_key?(body, "count")
    body
  end

  # ===========================================================================================
  describe "T-LA-H1..H7 the new typed 409" do
    for route <- @routes do
      @tag route: route
      test "#{route} answers 409 last_interactive_tenant_wide_admin, names no id, changes nothing",
           %{
             route: route
           } do
        fx = LIA.on_tenant!("h-#{route}")
        data = prepare(route, fx)
        snap = LIA.snapshot(fx)
        ids = LIA.entry_ids(fx)

        conn = send_request(route, fx, data)

        assert conn.status == 409, conn.resp_body
        body = assert_detail_free!(conn, fx)
        assert body["detail"] == LIA.new_code()
        assert LIA.snapshot(fx) == snap

        assert [entry] = LIA.new_entries(fx, ids)
        assert entry.action == LIA.event()
        assert entry.after_state["reason_code"] == LIA.new_code()
        assert entry.after_state["counted_admins"] == 0
      end
    end

    test "the service-principal route is a 409, not a 500 (the clause sits before the catch-all)" do
      fx = LIA.on_tenant!("h6-not-500")
      conn = send_request(:h6, fx, %{})
      refute conn.status == 500, conn.resp_body
      assert conn.status == 409
    end

    for route <- @routes do
      @tag route: route
      test "#{route} succeeds with a SECOND interactive admin present (the control)", %{
        route: route
      } do
        fx = LIA.on_tenant!("h-ok-#{route}")
        data = prepare(route, fx)
        a2 = LIA.add_admin!(fx)
        # h5 runs on the zero-row shape: the second admin needs his own user row there
        if route == :h5, do: :ok = RSG.raw_user_row!(fx.schema_name, a2.id, "TENANT_ADMIN", nil)

        conn = send_request(route, fx, data)

        if route in [:h3, :h4] do
          # an unbind and a rebind take every member-admin along: still refused with two admins
          # (h4: A2 is not a member of the new group either)
          assert conn.status == 409, conn.resp_body
        else
          assert conn.status in [200, 204], conn.resp_body
        end
      end
    end
  end

  # ===========================================================================================
  describe "T-LA-H the old guard keeps its code and its mapping" do
    for route <- @old_guarded do
      @tag route: route
      test "#{route} with no token owner left answers 409 last_tenant_wide_admin", %{route: route} do
        fx = LIA.on_tenant!("hold-#{route}")
        :ok = LIA.drop_token_owner!(fx)

        data =
          if route == :h4,
            do: %{group_id: RSG.fresh_group!(fx.schema_name).id},
            else: prepare(route, fx)

        conn = send_request(route, fx, data)

        assert conn.status == 409, conn.resp_body
        body = assert_detail_free!(conn, fx)
        assert body["detail"] == LIA.old_code()
      end
    end
  end

  # ===========================================================================================
  describe "T-LA-23 HTTP half: an unreadable stored mode is the detail-free 500" do
    for route <- @routes do
      @tag route: route
      test "#{route} answers 500, names nothing, changes nothing", %{route: route} do
        fx = LIA.on_tenant!("h500-#{route}")
        data = prepare(route, fx)
        snap = LIA.snapshot(fx)
        ids = LIA.entry_ids(fx)

        conn = LIA.with_unreadable_mode(fx, fn rfx -> send_request(route, rfx, data) end)

        assert conn.status == 500, conn.resp_body
        refute F.uuid_in?(conn.resp_body), conn.resp_body
        refute conn.resp_body =~ "unavailable"
        assert LIA.snapshot(fx) == snap
        assert LIA.new_entries(fx, ids) == []
      end
    end
  end
end
