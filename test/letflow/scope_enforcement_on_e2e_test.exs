defmodule Letflow.ScopeEnforcementOnE2eTest do
  @moduledoc """
  REQ-519 slice 2f-b (GH #2535), AC 16, AC 17 and AC 22 (the route walk first), plus the platform
  tenant tests T-O7 / T-O8 of SEC C-6 (design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` sections 4.2a, 4.8; tests T-Z*; spec
  `test/specs/REQ-519-2f-b.md`): ONE suite, real HTTP through the full `Letflow.Router` (OIDC
  users and API tokens), a real database. T-Z1, T-Z16 and T-Z17 reach `on` through the REAL guarded flip (the PUT, or
  `ScopeEnforcement.flip/4`; shadow evidence satisfied by a backdated raw audit entry and persisted
  counters); T-Z2, T-O7, T-O8 and T-Z15 store the mode directly with `ScopeEnforcementFixture`
  because the flip is not what they test (the gate would refuse their deliberately odd tenants).

    * T-Z0 the route walk is green FIRST (AC 22, SEC C-1);
    * T-Z1 the lifecycle: a scoped TASK_WORKER is served under `shadow`; after the interactive
      tenant-wide admin flips `shadow -> on` the SAME request is a uniform 403, a self-service read
      (`/me/memberships`) still works, a tenant-wide user and an API token are unaffected; the
      binding writers refuse to widen (`scope_required`) and the IdP sync suppresses a tenant-wide
      group for a user with scoped rows; `on -> shadow` with a reason restores today's behaviour
      byte for byte, and so does `-> off`;
    * T-Z2 a scoped-only TENANT_ADMIN is refused on the admin plane and on the flag route under `on`
      while the interactive tenant-wide admin reaches both (the turn-off path);
    * T-O7 / T-O8 the PLATFORM tenant stored `on` does not lock its PLATFORM_ADMIN out of the
      platform-scope routes (even through a group with ZERO rows), the flag route stays
      TENANT_ADMIN-only there, and in an ordinary `on` tenant a PLATFORM_ADMIN role is inert;
    * T-Z15..T-Z17 fail closed in `on`: a binding with zero rows denies (`:no_grant_rows`, uniform 403),
      and neither deleting a user's last scoped row nor retiring a referenced node can make a user
      tenant-wide.

  `async: false`: dedicated provisioned tenants (sandbox `:auto`), the VM-global `:oidc` config swap
  and platform pin.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Api.RouteScope
  alias Letflow.Api.Scope
  alias Letflow.Identity
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.User
  alias Letflow.Oidc.ConfigurableTokenVerifierDouble
  alias Letflow.Plugs.AuthPipeline
  alias Letflow.ScopeEnforcement
  alias Letflow.ScopeNodePaths
  alias Letflow.Support.OnGateFixture, as: F
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.RouteInventory
  alias Letflow.Support.ScopeEnforcementFixture
  alias Letflow.Support.ScopedGrantsFixture, as: S
  alias Letflow.Support.SyncScopeFixture
  alias Letflow.Support.TokenMintFixture
  alias Letflow.TenantFixture

  @flag_path "/api/v1/tenant/scope-enforcement"
  @tenant_wide_route "/api/v1/services"
  @self_service_route "/api/v1/me/memberships"
  @admin_plane_route "/api/v1/identity/tokens"
  @platform_route "/api/v1/tenants"
  @worker "TASK_WORKER"

  setup do
    original = Application.fetch_env!(:letflow, :oidc)

    Application.put_env(
      :letflow,
      :oidc,
      Keyword.put(original, :token_verifier, ConfigurableTokenVerifierDouble)
    )

    on_exit(fn -> Application.put_env(:letflow, :oidc, original) end)
    Fixture.unpin!()
    :ok
  end

  # --- helpers ---------------------------------------------------------------------------------

  defp oidc_tenant!(prefix) do
    realm = Letflow.TenantSlugFixture.unique_realm(prefix)

    fx =
      TenantFixture.provisioned_tenant!(
        slug_prefix: prefix,
        display_name: "REQ-519 2f-b e2e tenant",
        oidc_mode: :enabled,
        idp_realm_id: realm
      )

    Map.put(fx, :realm, realm)
  end

  defp bearer(fx, sub), do: "Bearer realm-token:" <> fx.realm <> ":sub=" <> sub

  # One request through the FULL router as the OIDC user `sub` of the tenant.
  defp request(fx, sub, method, path, body) do
    conn = conn(method, path, if(body, do: Jason.encode!(body), else: nil))

    conn =
      if body, do: put_req_header(conn, "content-type", "application/json"), else: conn

    conn
    |> put_req_header("authorization", bearer(fx, sub))
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp get(fx, sub, path), do: request(fx, sub, :get, path, nil)
  defp json(conn), do: Jason.decode!(conn.resp_body)

  # The JIT-provisioned user of `sub`: the auth pipeline alone provisions it (a role-less user has
  # no permission for any route, so a routed request would only answer 403).
  defp user_of!(fx, sub) do
    conn =
      :get
      |> conn("/whatever")
      |> put_req_header("authorization", bearer(fx, sub))
      |> AuthPipeline.call(AuthPipeline.init([]))

    refute conn.halted, "provisioning failed: #{conn.resp_body}"
    Repo.get!(User, conn.assigns.auth_context.user_id, prefix: fx.schema_name)
  end

  # An OIDC user holding TENANT_ADMIN through the tenant-wide default group.
  defp admin!(fx, sub) do
    user = user_of!(fx, sub)
    _ = TokenMintFixture.grant_roles!(fx.schema_name, user.id, ["TENANT_ADMIN"])
    user
  end

  # An OIDC user holding TASK_WORKER ONLY through a group whose single row is scoped.
  defp scoped_worker!(fx, sub) do
    user = user_of!(fx, sub)
    node = RSG.node!(fx.schema_name)
    group = SyncScopeFixture.platform_group!(fx.schema_name, @worker, [{:node, node}])
    _ = RSG.member!(fx.schema_name, group.id, user)
    %{user: user, group: group, node: node}
  end

  defp mode!(fx) do
    {:ok, mode} = ScopeEnforcement.get_mode(fx.tenant_id)
    mode
  end

  defp forbidden?(conn),
    do: conn.status == 403 and json(conn)["detail"] == "insufficient permissions"

  # --- T-Z0 ---------------------------------------------------------------------------------------

  describe "T-Z0 the route walk is green first (AC 22)" do
    test "audit_routes/3 is [] and no /me, /help or ruled /definitions route is default-sourced or pending" do
      routes = RouteInventory.routes()

      assert RouteScope.audit_routes(routes, RouteInventory.read_snapshot()) == []

      self_service =
        Enum.filter(
          routes,
          &(String.starts_with?(&1.path, "/me") or String.starts_with?(&1.path, "/help") or
              (&1.method == "GET" and
                 &1.path in [
                   "/definitions",
                   "/definitions/search",
                   "/definitions/:id",
                   "/definitions/active/:name"
                 ]))
        )

      assert length(self_service) == 8
      assert Enum.all?(self_service, &(&1.class == :self_service and &1.source == :declared))
      assert Enum.all?(RouteScope.self_service_routes(), &is_binary(&1.ruling))
    end
  end

  # --- REQ-545 (GH #2535, IMPL-525-A): GET /definitions and /definitions/search -----------------

  @collection_routes ["/api/v1/definitions", "/api/v1/definitions/search?q=req545"]
  @event [:letflow, :scope, :shadow, :would_deny]

  @doc false
  def handle_event(_event, measurements, metadata, {pid, ref}) do
    if self() == pid, do: send(pid, {:would_deny, ref, measurements, metadata})
    :ok
  end

  defp definition!(schema, name) do
    graph = %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }

    {:ok, definition} =
      Letflow.Definitions.create_with_variable_schemas(
        %{name: name, version: "1.0.0", graph: graph, created_by: Ecto.UUID.generate()},
        [],
        prefix: schema
      )

    definition
  end

  defp role_user!(fx, sub, roles) do
    user = user_of!(fx, sub)
    _ = TokenMintFixture.grant_roles!(fx.schema_name, user.id, roles)
    user
  end

  # The comparable form of a response: status, headers and body. The per-request trace id (header
  # `x-trace-id`, problem body `trace_id`) is the only part allowed to differ.
  defp wire(conn) do
    body = conn.resp_body |> Jason.decode!() |> Map.delete("trace_id")
    {conn.status, List.keydelete(conn.resp_headers, "x-trace-id", 0), body}
  end

  defp shape(%{} = map), do: Map.new(map, fn {k, v} -> {k, shape(v)} end)
  defp shape([first | _]), do: [shape(first)]
  defp shape([]), do: []
  defp shape(v) when is_binary(v), do: :string
  defp shape(v) when is_number(v), do: :number
  defp shape(nil), do: nil
  defp shape(v) when is_boolean(v), do: :boolean

  describe "REQ-545 the definition collection reads are :self_service" do
    test "under on a scoped DefinitionsRead holder gets 200 on both routes, with the tenant-wide holder's shape; the other definition reads still refuse" do
      fx = oidc_tenant!("req545-on")
      _admin = admin!(fx, "r545-admin")
      _worker = scoped_worker!(fx, "r545-worker")
      _ = definition!(fx.schema_name, "req545-alpha")
      :ok = ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, :on)

      for path <- @collection_routes do
        scoped = get(fx, "r545-worker", path)
        wide = get(fx, "r545-admin", path)
        assert scoped.status == 200, scoped.resp_body
        assert wide.status == 200
        assert [_ | _] = json(scoped)["items"]
        assert shape(json(scoped)) == shape(json(wide)), path
        assert Map.keys(json(scoped)) |> Enum.sort() == ["items", "next_cursor"]
      end

      id = Ecto.UUID.generate()
      assert forbidden?(get(fx, "r545-worker", "/api/v1/definitions/#{id}/export"))

      assert forbidden?(
               request(fx, "r545-worker", :post, "/api/v1/definitions/#{id}/validate", %{})
             )

      # REQ-546: the single-object read is no longer refused; an absent id is a 404
      assert get(fx, "r545-worker", "/api/v1/definitions/#{id}").status == 404
    end

    test "a principal without DefinitionsRead gets the 403 of the unchanged export route on both routes, in a tenant with and without definitions" do
      full = oidc_tenant!("req545-403a")
      empty = oidc_tenant!("req545-403b")
      _ = definition!(full.schema_name, "req545-beta")

      for fx <- [full, empty], role <- ["AGENT_RUNNER", "CANDIDATE"] do
        sub = "r545-" <> String.downcase(role)
        _ = role_user!(fx, sub, [role])
        :ok = ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, :on)

        reference = get(fx, sub, "/api/v1/definitions/#{Ecto.UUID.generate()}/export")
        assert forbidden?(reference)

        for path <- @collection_routes do
          got = get(fx, sub, path)
          assert wire(got) == wire(reference), "#{role} #{path}"
        end
      end
    end

    test "a tenant B holder, scoped or tenant-wide, sees nothing of tenant A; a name known only to A answers as a name known nowhere" do
      a = oidc_tenant!("req545-xa")
      b = oidc_tenant!("req545-xb")
      _ = definition!(a.schema_name, "req545-only-in-a")
      _ = definition!(b.schema_name, "req545-in-b")
      before_a = Repo.all(Letflow.Definitions.ProcessDefinition, prefix: a.schema_name)

      _ = admin!(b, "r545-b-admin")
      _ = scoped_worker!(b, "r545-b-worker")
      :ok = ScopeEnforcementFixture.set_stored_mode!(b.tenant_id, :on)

      for sub <- ["r545-b-admin", "r545-b-worker"] do
        list = get(b, sub, "/api/v1/definitions")
        assert list.status == 200
        refute list.resp_body =~ "req545-only-in-a"

        known_to_a = get(b, sub, "/api/v1/definitions/search?q=req545-only-in-a")
        nowhere = get(b, sub, "/api/v1/definitions/search?q=zzz-nowhere-at-all")
        assert known_to_a.status == 200
        assert json(known_to_a)["items"] == []
        assert wire(known_to_a) == wire(nowhere)
      end

      assert Repo.all(Letflow.Definitions.ProcessDefinition, prefix: a.schema_name) == before_a
    end

    test "under shadow both routes are counted as requests and produce no would-deny for a scoped holder" do
      fx = oidc_tenant!("req545-sh")
      _ = scoped_worker!(fx, "r545-sh-worker")
      :ok = ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, :shadow)

      ref = make_ref()
      :telemetry.attach({__MODULE__, ref}, @event, &__MODULE__.handle_event/4, {self(), ref})
      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

      requests = fn ->
        Letflow.Api.Scope.ShadowEvidence.flush()
        today = Date.utc_today()

        Letflow.Api.Scope.ShadowEvidence.counts_between(fx.schema_name, today, today).requests
      end

      # warm-up: the first request provisions the user
      _ = get(fx, "r545-sh-worker", "/api/v1/me/memberships")
      before = requests.()

      for path <- @collection_routes, do: assert(get(fx, "r545-sh-worker", path).status == 200)

      assert requests.() - before == 2
      refute_received {:would_deny, ^ref, _, _}
    end
  end

  # --- REQ-546 (GH #2535, IMPL-525-B): GET /definitions/:id and /definitions/active/:name -------

  @single_keys ~w(activation_state archived_at created_at created_by description graph id name needs_reactivation_at needs_reactivation_reason owner_module owner_module_version stage status updated_at version)

  defp single_routes(def_),
    do: ["/api/v1/definitions/#{def_.id}", "/api/v1/definitions/active/#{def_.name}"]

  describe "REQ-546 the single-object definition reads are :self_service" do
    test "under on a scoped holder gets 200 on both routes with the tenant-wide holder's shape; export and validate still refuse" do
      fx = oidc_tenant!("req546-on")
      _ = admin!(fx, "r546-admin")
      _ = scoped_worker!(fx, "r546-worker")
      definition = definition!(fx.schema_name, "req546-alpha")
      {:ok, _} = Letflow.Definitions.activate(definition.id, prefix: fx.schema_name)
      :ok = ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, :on)

      for path <- single_routes(definition) do
        scoped = get(fx, "r546-worker", path)
        wide = get(fx, "r546-admin", path)
        assert scoped.status == 200, scoped.resp_body
        assert wide.status == 200, wide.resp_body
        assert shape(json(scoped)) == shape(json(wide)), path
        assert Map.keys(json(scoped)) |> Enum.sort() == @single_keys, path
      end

      assert forbidden?(get(fx, "r546-worker", "/api/v1/definitions/#{definition.id}/export"))

      assert forbidden?(
               request(
                 fx,
                 "r546-worker",
                 :post,
                 "/api/v1/definitions/#{definition.id}/validate",
                 %{}
               )
             )
    end

    test "a principal without DefinitionsRead gets the 403 of the unchanged export route on both routes" do
      fx = oidc_tenant!("req546-403")
      definition = definition!(fx.schema_name, "req546-beta")

      for role <- ["AGENT_RUNNER", "CANDIDATE"] do
        sub = "r546-" <> String.downcase(role)
        _ = role_user!(fx, sub, [role])
        :ok = ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, :on)

        reference = get(fx, sub, "/api/v1/definitions/#{definition.id}/export")
        assert forbidden?(reference)

        for path <- single_routes(definition) do
          assert wire(get(fx, sub, path)) == wire(reference), "#{role} #{path}"
        end
      end
    end

    test "absent and cross-tenant ids and names answer one 404 for scoped and tenant-wide holders in tenant B (INV-5, INV-10)" do
      a = oidc_tenant!("req546-xa")
      b = oidc_tenant!("req546-xb")
      only_a = definition!(a.schema_name, "req546-only-in-a")
      {:ok, _} = Letflow.Definitions.activate(only_a.id, prefix: a.schema_name)
      before_a = Repo.all(Letflow.Definitions.ProcessDefinition, prefix: a.schema_name)

      _ = admin!(b, "r546-b-admin")
      _ = scoped_worker!(b, "r546-b-worker")
      :ok = ScopeEnforcementFixture.set_stored_mode!(b.tenant_id, :on)

      for sub <- ["r546-b-admin", "r546-b-worker"] do
        absent_id = get(b, sub, "/api/v1/definitions/#{Ecto.UUID.generate()}")
        cross_id = get(b, sub, "/api/v1/definitions/#{only_a.id}")
        absent_name = get(b, sub, "/api/v1/definitions/active/req546-nowhere")
        cross_name = get(b, sub, "/api/v1/definitions/active/#{only_a.name}")

        assert absent_id.status == 404
        assert wire(cross_id) == wire(absent_id), sub
        assert absent_name.status == 404
        assert wire(cross_name) == wire(absent_name), sub
        refute cross_id.resp_body =~ "req546-only-in-a"
        refute cross_name.resp_body =~ "req546-only-in-a"
      end

      assert Repo.all(Letflow.Definitions.ProcessDefinition, prefix: a.schema_name) == before_a
    end

    test "under shadow both routes are counted as requests and produce no would-deny for a scoped holder" do
      fx = oidc_tenant!("req546-sh")
      _ = scoped_worker!(fx, "r546-sh-worker")
      definition = definition!(fx.schema_name, "req546-gamma")
      {:ok, _} = Letflow.Definitions.activate(definition.id, prefix: fx.schema_name)
      :ok = ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, :shadow)

      ref = make_ref()
      :telemetry.attach({__MODULE__, ref}, @event, &__MODULE__.handle_event/4, {self(), ref})
      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

      requests = fn ->
        Letflow.Api.Scope.ShadowEvidence.flush()
        today = Date.utc_today()
        Letflow.Api.Scope.ShadowEvidence.counts_between(fx.schema_name, today, today).requests
      end

      _ = get(fx, "r546-sh-worker", "/api/v1/me/memberships")
      before = requests.()

      for path <- single_routes(definition),
          do: assert(get(fx, "r546-sh-worker", path).status == 200)

      assert requests.() - before == 2
      refute_received {:would_deny, ^ref, _, _}
    end
  end

  # --- T-Z1 ---------------------------------------------------------------------------------------

  describe "T-Z1 a tenant reaches on through the real flip and back" do
    test "scoped users are denied tenant-wide routes under on, nothing else changes, and on -> shadow restores byte for byte" do
      fx = oidc_tenant!("req519-z1")
      s = fx.schema_name

      _admin = admin!(fx, "z1-admin")
      _worker = scoped_worker!(fx, "z1-worker")
      _ = F.backdate_shadow!(fx)

      # an API token owned by the tenant-wide admin (unaffected by on)
      admin_user = user_of!(fx, "z1-admin")

      {:ok, %{plaintext: token}} =
        Identity.create_token(admin_user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: s
        )

      token_get = fn path ->
        conn(:get, path)
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("x-tenant-slug", fx.tenant.slug)
        |> Letflow.Router.call(Letflow.Router.init([]))
      end

      # --- under shadow: nothing is denied, the denial is only counted
      shadow_scoped = get(fx, "z1-worker", @tenant_wide_route)
      assert shadow_scoped.status == 200, shadow_scoped.resp_body
      assert get(fx, "z1-admin", @tenant_wide_route).status == 200
      assert mode!(fx) == :shadow

      # --- the REAL flip, by the interactive tenant-wide admin
      flip =
        request(fx, "z1-admin", :put, @flag_path, %{"mode" => "on", "reason" => "req519 e2e"})

      assert flip.status == 200, flip.resp_body
      assert json(flip) == %{"mode" => "on", "previous" => "shadow", "changed" => true}
      assert mode!(fx) == :on

      # --- under on: the scoped worker is refused with the uniform 403 on a tenant-wide route
      denied = get(fx, "z1-worker", @tenant_wide_route)
      assert forbidden?(denied), denied.resp_body

      # the self-service read still works for a scoped user, and so do the tenant-wide user and the token
      assert get(fx, "z1-worker", @self_service_route).status == 200
      assert get(fx, "z1-admin", @tenant_wide_route).status == 200
      assert token_get.(@tenant_wide_route).status == 200
      assert get(fx, "z1-admin", @admin_plane_route).status == 200

      # --- the scoped worker cannot flip anything, and the flag does not move
      refused = request(fx, "z1-worker", :put, @flag_path, %{"mode" => "off", "reason" => "x"})
      assert forbidden?(refused)
      assert mode!(fx) == :on

      # --- writers refuse to widen (AC 1 in the enforced tenant, reached through the real flip)
      group = RSG.fresh_group!(s)

      assert RoleRegistry.upsert_role_report("PROCESS_DESIGNER", :platform_role, group.id,
               prefix: s
             ) ==
               {:error, :scope_required}

      assert RSG.binding(s, "PROCESS_DESIGNER") == nil

      # --- the IdP sync suppresses a tenant-wide group for a user who holds scoped rows
      sync_group = SyncScopeFixture.platform_group!(s, "SYNC_ROLE_E2E", [:tenant_wide])
      holder = RSG.user!(s)
      :ok = RSG.raw_user_row!(s, holder.id, "SYNC_ROLE_E2E", RSG.node!(s))

      assert {:suppressed, _user, %{suppressed: [%{group_id: group_id, role: "SYNC_ROLE_E2E"}]}} =
               SyncScopeFixture.sync(s, holder, ["SYNC_ROLE_E2E"])

      assert group_id == sync_group.id
      assert SyncScopeFixture.memberships(s, holder.id) == []

      # --- on -> shadow needs a reason, and restores today's behaviour
      no_reason = request(fx, "z1-admin", :put, @flag_path, %{"mode" => "shadow"})
      assert no_reason.status == 422
      assert json(no_reason)["detail"] == "reason_required"
      assert mode!(fx) == :on

      down =
        request(fx, "z1-admin", :put, @flag_path, %{
          "mode" => "shadow",
          "reason" => "req519 e2e down"
        })

      assert down.status == 200, down.resp_body
      assert json(down) == %{"mode" => "shadow", "previous" => "on", "changed" => true}

      restored = get(fx, "z1-worker", @tenant_wide_route)
      assert restored.status == 200
      # byte-identical to the answer the same request got before the flip
      assert restored.resp_body == shadow_scoped.resp_body

      off =
        request(fx, "z1-admin", :put, @flag_path, %{"mode" => "off", "reason" => "req519 e2e off"})

      assert off.status == 200
      assert get(fx, "z1-worker", @tenant_wide_route).resp_body == shadow_scoped.resp_body
    end
  end

  # --- T-Z2 ---------------------------------------------------------------------------------------

  describe "T-Z2 the admin plane under on" do
    test "a scoped-only TENANT_ADMIN is refused the admin plane and the flag route; the interactive tenant-wide admin reaches both" do
      fx = oidc_tenant!("req519-z2")
      s = fx.schema_name

      admin = admin!(fx, "z2-admin")
      # a second OIDC user in the same TENANT_ADMIN group; the group is then made scoped-only, and
      # the admin keeps a tenant-wide USER row, so only the admin is tenant-wide
      scoped = user_of!(fx, "z2-scoped")
      group_id = RSG.group_of!(s, "TENANT_ADMIN")
      _ = RSG.member!(s, group_id, scoped)
      :ok = RSG.raw_user_row!(s, admin.id, "TENANT_ADMIN", nil)
      node = RSG.make_group_scoped_only!(s, group_id, "TENANT_ADMIN")
      assert is_binary(node)

      :ok = ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, :on)

      # the scoped member: admin plane and flag route are refused
      assert forbidden?(get(fx, "z2-scoped", @admin_plane_route))

      assert forbidden?(
               request(fx, "z2-scoped", :put, @flag_path, %{"mode" => "off", "reason" => "x"})
             )

      assert mode!(fx) == :on

      # the admin holds a tenant-wide USER row: the admin plane and the turn-off path are open
      assert get(fx, "z2-admin", @admin_plane_route).status == 200

      off =
        request(fx, "z2-admin", :put, @flag_path, %{
          "mode" => "off",
          "reason" => "req519 turn off"
        })

      assert off.status == 200, off.resp_body
      assert mode!(fx) == :off
    end
  end

  # --- T-O7 / T-O8 --------------------------------------------------------------------------------

  describe "T-O7 / T-O8 platform authority never reads grants" do
    test "T-O7 the platform tenant stored on does not lock out its PLATFORM_ADMIN, even through a group with zero rows" do
      p = oidc_tenant!("req519-o7")
      :ok = Fixture.pin!(p.tenant_id)
      s = p.schema_name

      operator = user_of!(p, "o7-operator")
      _ = TokenMintFixture.grant_roles!(s, operator.id, ["PLATFORM_ADMIN"])
      # fail closed for grants: the PLATFORM_ADMIN binding has NO rows at all
      gid = RSG.group_of!(s, "PLATFORM_ADMIN")
      _ = RSG.raw_delete_rows!(s, gid, "PLATFORM_ADMIN")
      assert RSG.rows(s) |> Enum.filter(&match?({:group, ^gid, "PLATFORM_ADMIN", _, _}, &1)) == []

      for mode <- [:off, :shadow, :on] do
        :ok = ScopeEnforcementFixture.set_stored_mode!(p.tenant_id, mode)

        conn = get(p, "o7-operator", @platform_route)

        assert conn.status == 200,
               "platform route under #{mode}: #{conn.status} #{conn.resp_body}"
      end

      # the flag route stays TENANT_ADMIN-only: a PLATFORM_ADMIN without TENANT_ADMIN is refused
      flag = request(p, "o7-operator", :put, @flag_path, %{"mode" => "off", "reason" => "x"})
      assert forbidden?(flag)
      assert mode!(p) == :on
    end

    test "T-O8 in an ordinary tenant stored on, a PLATFORM_ADMIN role is inert" do
      fx = oidc_tenant!("req519-o8")
      user = user_of!(fx, "o8-user")
      _ = TokenMintFixture.grant_roles!(fx.schema_name, user.id, ["PLATFORM_ADMIN"])

      :ok = ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, :on)

      assert forbidden?(get(fx, "o8-user", @platform_route))

      assert forbidden?(
               request(fx, "o8-user", :put, @flag_path, %{"mode" => "off", "reason" => "x"})
             )

      assert mode!(fx) == :on
    end
  end

  # --- AC 17: fail closed ------------------------------------------------------------------------------

  describe "T-Z15 / T-Z16 / T-Z17 fail closed in on" do
    test "a principal with a binding but ZERO rows is denied :no_grant_rows and gets the uniform 403 on a tenant-wide route" do
      fx = oidc_tenant!("req519-z15")
      s = fx.schema_name
      _admin = admin!(fx, "z15-admin")
      holder = user_of!(fx, "z15-holder")

      group = SyncScopeFixture.platform_group!(s, @worker, [])
      _ = RSG.member!(s, group.id, holder)
      assert RSG.rows(s) |> Enum.filter(&match?({:group, _, @worker, _, _}, &1)) == []

      :ok = ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, :on)

      principal = S.principal(fx, holder.id)
      assert Scope.allowed?(principal, :DefinitionsRead, :tenant_wide) == {:deny, :no_grant_rows}

      assert forbidden?(get(fx, "z15-holder", @tenant_wide_route))
      # the tenant-wide administrator is served by the same route
      assert get(fx, "z15-admin", @tenant_wide_route).status == 200
    end

    test "T-Z16 deleting a user's LAST scoped row is refused (409 last_scoped_row) and the scope is unchanged, in on" do
      fx = on_tenant_via_flip!("req519-z16")
      s = fx.schema_name

      member = TokenMintFixture.role_holder!(s, [@worker])
      gid = S.rowless_group!(fx, @worker)
      node = RSG.node!(s)

      created =
        S.as_admin(
          Letflow.Routers.TenantRoleScopeGrants,
          :post,
          "/",
          fx,
          S.create_body(:group, gid, @worker, node)
        )

      assert created.status in [200, 201], created.resp_body
      row_id = S.body(created)["id"]

      conn = S.as_admin(Letflow.Routers.TenantRoleScopeGrants, :delete, "/#{row_id}", fx, nil)
      assert conn.status == 409
      assert S.body(conn)["detail"] == "last_scoped_row"

      assert Scope.allowed?(S.principal(fx, member.id), :TasksRead, {:node, node}) ==
               {:allow, :subtree}

      assert mode!(fx) == :on
    end

    test "T-Z17 a node that a grant references cannot be retired; nobody becomes tenant-wide by it, in on" do
      fx = on_tenant_via_flip!("req519-z17")
      s = fx.schema_name

      member = TokenMintFixture.role_holder!(s, [@worker])
      gid = S.rowless_group!(fx, @worker)
      node = RSG.node!(s)

      created =
        S.as_admin(
          Letflow.Routers.TenantRoleScopeGrants,
          :post,
          "/",
          fx,
          S.create_body(:group, gid, @worker, node)
        )

      assert created.status in [200, 201], created.resp_body

      assert ScopeNodePaths.write({:retire, node}, s) == {:error, :node_has_grants}

      assert Scope.allowed?(S.principal(fx, member.id), :TasksRead, {:node, node}) ==
               {:allow, :subtree}

      assert Scope.allowed?(S.principal(fx, member.id), :TasksRead, :tenant_wide) |> elem(0) ==
               :deny
    end
  end

  # A tenant (default role groups seeded, admin under :admin) that is on through the REAL flip at
  # the real clock (backdated evidence).
  defp on_tenant_via_flip!(slug_prefix) do
    fx = S.tenant!(slug_prefix)
    _ = F.backdate_shadow!(fx)

    attrs = %{actor_id: fx.admin.id, reason: "req519 e2e", trace_id: "req519-2fb-e2e-trace-0001"}

    assert {:ok, %{mode: :on, previous: :shadow, changed: true}} =
             ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :on, attrs)

    fx
  end
end
