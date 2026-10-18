defmodule Letflow.Api.RouteScope do
  @moduledoc """
  The scope class of a route (REQ-517 PR 2b / GH #2535, decision 0051 D5 and D11; design
  `lib/letflow/design/req517-scoped-grants-admin-plane.md` section 4.1). Pure: no database.

  ## Classes

    * `:admin_plane` -- the tenant-admin surface (D11). Decided against `:tenant_wide`.
    * `:tenant_wide` -- the route needs the permission held tenant-wide.
    * `{:resolver, {module, function}}` -- the scope comes from the loaded resource
      (`module.function/1`, REQ-518 defines the resolvers). Passes through `Authorize`.
    * `:filter` -- a list endpoint whose handler applies the scope (REQ-518). Passes through.
    * `:self_service` -- tenant-level, non-sensitive, role-independent reads (defined and
      assigned by REQ-518 AC 21; in 2b no route carries it). Passes through after the coarse
      allow.

  ## Where a class comes from (`class_of/1`)

    1. the key table (`admin_plane_keys/0`): a route whose policy key is in it is ALWAYS
       `:admin_plane` (`:key_table`), whatever it declares (an option cannot weaken the admin
       plane; the walk reports such a declaration as `:declared_conflicts_with_key_table`);
    2. the class DECLARED with the route (`scope: <class>` on the `authz_*` macro,
       `:declared`);
    3. otherwise the fail-closed default `:tenant_wide` (`:default`).

  A default-sourced route is legal only when it is on the committed snapshot
  (`test/fixtures/route_scope/tenant_wide_default_routes.txt`); the walk fails for one that
  is not (`:unclassified`) and for a snapshot line that is no longer default-sourced
  (`:stale_snapshot`). Runtime treats a default-sourced route exactly as `:tenant_wide`.
  """

  alias Letflow.Api.Authorization

  @type class ::
          :admin_plane
          | :tenant_wide
          | :filter
          | :self_service
          | {:resolver, {module(), atom()}}
  @type source :: :declared | :key_table | :default
  @type route_row :: %{
          router: module(),
          method: String.t(),
          path: String.t(),
          key: atom(),
          declared: class() | nil,
          class: class(),
          source: source()
        }
  @type error ::
          {:unclassified, route_row()}
          | {:stale_snapshot, String.t()}
          | {:declared_conflicts_with_key_table, route_row()}
          | {:resolver_not_exported, route_row()}
          | {:admin_key_not_in_table, atom()}
          | {:link_route_reclassified, route_row()}
          | {:self_service_not_allowed, route_row()}
          | {:unexpected_filter_route, route_row()}
          | {:unknown_permission, atom()}
          | {:exam_route_reclassified, route_row()}

  # 0051 D11 admin plane, by policy key. `:UsersGroupsRolesManage` is a permission, not a key:
  # the completeness rule in `audit_routes/2` derives the rest from `required_permission/1`.
  @admin_plane_keys [
    :GroupsManage,
    :UsersManage,
    :TokensManage,
    :RolesManage,
    :RolesRebind,
    :ScopeNodePathsConsistencyRead,
    :ScopeEnforcementRead,
    :ScopeEnforcementManage,
    :ScopeGrantsIntegrityRead,
    :ScopeEnforcementTokensRead,
    :RoleScopeGrantsRead,
    :RoleScopeGrantsManage,
    :ServicePrincipalManage
  ]

  # 0051 M7: no issue-time scoped lookup of an attachment's parent exists, so the two link
  # routes may only be `:tenant_wide`. Flip to true only together with such a lookup.
  @issue_time_parent_lookup? false

  # The committed expectation of `:filter` routes (SEC F-1): none until REQ-518 reclassifies
  # list endpoints. REQ-518 replaces this list in the same change that declares them.
  @expected_filter_routes []

  # `:self_service` is defined but NO route may carry it until REQ-518 AC 21 (SEC F-1).
  @self_service_routes_allowed? false

  @doc "The admin-plane key table."
  @spec admin_plane_keys() :: [atom()]
  def admin_plane_keys, do: @admin_plane_keys

  @doc "0051 M7: whether an issue-time scoped lookup of the attachment parent exists (false)."
  @spec issue_time_parent_lookup?() :: boolean()
  def issue_time_parent_lookup?, do: @issue_time_parent_lookup?

  @doc """
  The class and source of the route whose `Plug.Conn` private map (or route-private map) is
  `private`. Order: key table, declared, default (moduledoc). A route with no policy key is
  `:Unknown`, i.e. default-sourced.
  """
  @spec class_of(private :: map()) :: {class(), source()}
  def class_of(private) when is_map(private) do
    key = Map.get(private, :policy_key, :Unknown)

    cond do
      key in @admin_plane_keys -> {:admin_plane, :key_table}
      Map.has_key?(private, :scope_class) -> {Map.fetch!(private, :scope_class), :declared}
      true -> {:tenant_wide, :default}
    end
  end

  @doc "The snapshot line of a route: `METHOD FULL_PATH KEY`."
  @spec snapshot_line(route_row()) :: String.t()
  def snapshot_line(%{method: method, path: path, key: key}), do: "#{method} #{path} #{key}"

  @doc "Every route whose class is `:filter`; `audit_routes/2` pins the set to the committed expectation."
  @spec filter_routes([route_row()]) :: [route_row()]
  def filter_routes(routes), do: Enum.filter(routes, &(&1.class == :filter))

  @doc """
  The walk logic. `routes` are the mounted routes (FULL mounted paths), `default_snapshot` the
  committed `METHOD FULL_PATH KEY` lines. Returns every violation; `[]` is a pass.
  """
  @spec audit_routes(routes :: [route_row()], default_snapshot :: [String.t()]) :: [error()]
  def audit_routes(routes, default_snapshot) do
    snapshot = MapSet.new(default_snapshot)

    default_lines =
      for r <- routes, r.source == :default, into: MapSet.new(), do: snapshot_line(r)

    unclassified =
      for r <- routes,
          r.source == :default,
          not MapSet.member?(snapshot, snapshot_line(r)),
          do: {:unclassified, r}

    stale =
      for line <- default_snapshot,
          not MapSet.member?(default_lines, line),
          do: {:stale_snapshot, line}

    conflicts =
      for r <- routes,
          r.declared != nil,
          r.key in @admin_plane_keys,
          r.declared != :admin_plane,
          do: {:declared_conflicts_with_key_table, r}

    unresolved =
      for %{class: {:resolver, {module, fun}}} = r <- routes,
          not (Code.ensure_loaded?(module) and function_exported?(module, fun, 1)),
          do: {:resolver_not_exported, r}

    missing_keys =
      for key <- routes |> Enum.map(& &1.key) |> Enum.uniq() |> Enum.sort(),
          admin_by_permission?(key),
          key not in @admin_plane_keys,
          do: {:admin_key_not_in_table, key}

    reclassified =
      if @issue_time_parent_lookup? do
        []
      else
        for r <- routes,
            link_route?(r),
            r.class != :tenant_wide,
            do: {:link_route_reclassified, r}
      end

    self_service =
      if @self_service_routes_allowed? do
        []
      else
        for r <- routes, r.class == :self_service, do: {:self_service_not_allowed, r}
      end

    unexpected_filters =
      for r <- filter_routes(routes),
          snapshot_line(r) not in @expected_filter_routes,
          do: {:unexpected_filter_route, r}

    # REQ-518 R-1 (SEC-518-R1) guard: the literal `:all` at the exam data-access sites is safe only
    # while EVERY route mounted by the exam module (/modules/exam/...) is `:tenant_wide`; a scoped
    # principal is then refused before exam code runs. The ruling lapses if this rule is removed.
    exam_reclassified =
      for r <- routes,
          exam_route?(r),
          r.class != :tenant_wide,
          do: {:exam_route_reclassified, r}

    # SEC F-3: every policy key maps to a real permission, or `allowed?/3` would deny it to
    # everyone (admins included) under `on`.
    unknown_permissions =
      for key <- routes |> Enum.map(& &1.key) |> Enum.uniq() |> Enum.sort(),
          Authorization.required_permission(key) not in Authorization.permissions(),
          do: {:unknown_permission, key}

    unclassified ++
      stale ++
      conflicts ++
      unresolved ++
      missing_keys ++
      reclassified ++
      self_service ++ unexpected_filters ++ unknown_permissions ++ exam_reclassified
  end

  # Completeness rule (AC 17): every key whose permission is :UsersGroupsRolesManage, plus
  # :TokensManage and :RolesManage, belongs to the admin plane.
  defp admin_by_permission?(key) when key in [:TokensManage, :RolesManage], do: true

  defp admin_by_permission?(key),
    do: Authorization.required_permission(key) == :UsersGroupsRolesManage

  defp exam_route?(%{path: path}),
    do: path == "/modules/exam" or String.starts_with?(path, "/modules/exam/")

  defp link_route?(%{method: "POST", path: path}),
    do: String.ends_with?(path, "/attachments/:attachment_id/link")

  defp link_route?(%{method: "GET", path: path}),
    do: String.ends_with?(path, "/attachments/:attachment_id/link-content")

  defp link_route?(_other), do: false
end
