defmodule Letflow.Api.AdminPlaneUnderOnTest do
  @moduledoc """
  REQ-517 / GH #2535 PR 2b, AC 18 (design
  `lib/letflow/design/req517-scoped-grants-admin-plane.md` section 4.3, last paragraph; spec
  `test/specs/REQ-517-2b.md`, T-N1): the table-driven admin-plane test. ONE ROW PER ADMIN-PLANE
  ROUTE, generated from the real route table (every route whose class is `:admin_plane`, found
  through `Letflow.Support.RouteInventory`, then expanded to the owning router's local paths):

    * a caller whose TENANT_ADMIN role is held ONLY through a scoped row (a scoped user row,
      inserted directly) is refused with the unchanged uniform `403 insufficient permissions` when
      the tenant is stored `on`, on every row, with the policy key in the
      `[:letflow, :scope, :enforce, :denied]` event (the observable the design names; the coarse
      `AuthzDenyLog` line cannot serve as the marker because `Enforce` calls the same function);
    * with the tenant `off` or `shadow` the plug does not halt the same caller: NO such event on any
      row, and on the handler-gated routes (the stage-1 scope-enforcement GETs and the 2a grant
      read, which call `Scope.require_tenant_wide/2` themselves) the explicit expected 403 is
      listed in `@handler_gated_get_keys` and asserted;
    * a tenant-wide TENANT_ADMIN is never refused by this rule in any of the three modes.

  Dispatch goes straight into the owning router's `call/2` with a hand-assigned `auth_context`
  (`credential: :oidc`, a real user, `scope_enforcement` = the mode), so `Letflow.Plugs.Authorize`
  runs for real. A handler may answer anything (or raise on the placeholder path ids) in the modes
  where the plug lets the request through; those responses are not asserted, only the event.

  `async: false`: committed writes and VM-global telemetry handlers.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Api.RouteScope
  alias Letflow.Support.RouteInventory
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.Support.ScopedGrantsFixture, as: S

  @admin "TENANT_ADMIN"
  @placeholder "6f1c2b9e-0517-4a11-8c20-00000000aa01"
  # Admin-plane GET routes whose handler gates on a tenant-wide grant itself, with no path param.
  @handler_gated_get_keys [
    :ScopeEnforcementRead,
    :ScopeGrantsIntegrityRead,
    :ScopeEnforcementTokensRead,
    :RoleScopeGrantsRead
  ]

  # --- the table -------------------------------------------------------------------------------

  # {router, method_atom, local_path_with_placeholders, key} for every admin-plane route.
  defp admin_rows do
    routers =
      RouteInventory.routes()
      |> Enum.filter(&(&1.class == :admin_plane))
      |> Enum.map(& &1.router)
      |> Enum.uniq()

    for router <- routers,
        {method, local, key} <- router.__authz_routes__(),
        key in RouteScope.admin_plane_keys() do
      {router, method |> String.downcase() |> String.to_atom(), fill(local), key}
    end
  end

  defp fill(local) do
    local
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> _param -> @placeholder
      segment -> segment
    end)
  end

  defp body_for(:get), do: nil
  defp body_for(_other), do: %{}

  # A request whose handler may do anything: only the plug's decision is observed.
  defp dispatch(router, method, path, fx, user_id, mode) do
    On.call(router, method, path, fx, user_id, [@admin], mode, body_for(method))
  rescue
    _handler_raised -> :handler_raised
  catch
    _kind, _reason -> :handler_raised
  end

  defp setup_world(slug_prefix) do
    fx = S.tenant!(slug_prefix)
    scoped = On.scoped_holder!(fx, @admin)
    ref = On.attach_enforce_denied!()
    %{fx: fx, scoped: scoped, ref: ref, rows: admin_rows()}
  end

  # ===========================================================================================
  test "the table is not empty and covers every admin-plane route of the real inventory" do
    rows = admin_rows()
    inventory = Enum.filter(RouteInventory.routes(), &(&1.class == :admin_plane))

    assert length(rows) == length(inventory)
    assert length(rows) >= 13

    keys = rows |> Enum.map(fn {_router, _method, _path, key} -> key end) |> Enum.uniq()
    assert Enum.sort(keys) == Enum.sort(RouteScope.admin_plane_keys())
  end

  test "on: a TENANT_ADMIN held only through a scoped row is refused 403 on EVERY admin-plane route" do
    %{fx: fx, scoped: scoped, ref: ref, rows: rows} = setup_world("r517-n1-on")

    for {router, method, path, key} <- rows do
      conn = On.call(router, method, path, fx, scoped.id, [@admin], :on, body_for(method))
      label = "#{method} #{inspect(router)} #{path} (#{key})"

      assert conn.status == 403, label
      assert conn.halted, label
      assert Jason.decode!(conn.resp_body)["detail"] == "insufficient permissions", label

      assert [{%{count: 1}, %{policy: ^key, reason: :not_tenant_wide}}] = On.drain(ref), label
    end
  end

  test "on: the uniform 403 bytes are identical on every row (nothing tells the routes apart)" do
    %{fx: fx, scoped: scoped, rows: rows} = setup_world("r517-n1-bytes")

    bodies =
      for {router, method, path, _key} <- rows do
        conn = On.call(router, method, path, fx, scoped.id, [@admin], :on, body_for(method))
        assert conn.status == 403
        conn.resp_body
      end

    assert bodies |> Enum.uniq() |> length() == 1
  end

  for mode <- [:off, :shadow] do
    test "#{mode}: the same scoped caller is NOT refused by the plug on any admin-plane route (no enforce event)" do
      mode = unquote(mode)
      %{fx: fx, scoped: scoped, ref: ref, rows: rows} = setup_world("r517-n1-#{mode}")

      for {router, method, path, key} <- rows do
        result = dispatch(router, method, path, fx, scoped.id, mode)

        assert On.drain(ref) == [],
               "#{method} #{path} (#{key}) emitted an enforce deny under #{mode}"

        if method == :get and key in @handler_gated_get_keys and
             not String.contains?(path, @placeholder) do
          assert %Plug.Conn{status: 403} = result,
                 "#{path} (#{key}) is handler-gated and must answer its own 403 under #{mode}"
        end
      end
    end
  end

  for mode <- [:off, :shadow, :on] do
    test "#{mode}: a tenant-wide TENANT_ADMIN is never refused by the scope rule on any admin-plane route" do
      mode = unquote(mode)
      %{fx: fx, ref: ref, rows: rows} = setup_world("r517-n1-tw-#{mode}")

      for {router, method, path, key} <- rows do
        _ = dispatch(router, method, path, fx, fx.admin.id, mode)
        assert On.drain(ref) == [], "#{method} #{path} (#{key}) was refused under #{mode}"
      end
    end
  end
end
