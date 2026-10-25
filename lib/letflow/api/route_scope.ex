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
    * `:self_service` -- tenant-level, non-sensitive reads that do not depend on the caller's
      scope rows; the coarse permission of the policy key still applies (defined and
      assigned by REQ-518 AC 21; the ruled list is `@self_service_routes`, below). Passes
      through after the coarse allow. DEFINITION: the response is either the caller's own
      principal data or tenant-level metadata with no per-resource data (no entity record, task,
      instance or attachment), and a caller-supplied id may appear only as a FILTER, never to
      select a resource the caller must be scoped for. No field derived from a resource the
      caller must be scoped for may be added to a `:self_service` response; doing so requires a
      new SECURITY-REVIEWER ruling and an edit of `@self_service_routes`.

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
          | {:self_service_not_listed, route_row()}
          | {:self_service_list_mismatch, route_row()}
          | {:tenant_wide_unruled, route_row() | String.t()}
          | {:pending_marker_unlisted, String.t()}
          | {:unexpected_filter_route, route_row()}
          | {:unexpected_resolver_route, route_row()}
          | {:data_route_default, route_row()}
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

  # The committed expectation of `:filter` routes (SEC F-1), as `METHOD FULL_PATH KEY` lines
  # (`snapshot_line/1`). REQ-518 PR 2c-i-b: the three entity list/aggregate/export routes; PR 2d
  # adds `GET /tasks` and `GET /tasks/inbox` (listed below). The walk fails a `:filter` route that is not listed
  # AND a listed route that is mounted with another class (AC 18).
  @expected_filter_routes [
    "POST /entities/query EntitiesQuery",
    "POST /entities/query/aggregate EntitiesAggregate",
    "POST /entities/records/:entity_type/export EntitiesRecordsExport",
    "GET /tasks TasksList",
    "GET /tasks/inbox TasksList"
  ]

  # The committed expectation of `{:resolver, _}` routes (SEC F-1, same line format), REQ-518
  # PR 2c-ii (AC 19): the nine entity record write, history and attachment routes (REQ-516 S2
  # adds the record history read); PR 2d adds the five task routes. The walk fails a resolver
  # route that is not listed AND a listed route that is mounted with another class (a resolver
  # silently dropped).
  @expected_resolver_routes [
    "DELETE /entities/records/:entity_type/:record_id EntitiesRecordsWrite",
    "DELETE /entities/records/:entity_type/:record_id/attachments/:attachment_id EntitiesAttachmentsManage",
    "GET /entities/records/:entity_type/:record_id/attachments EntitiesAttachmentsRead",
    "GET /entities/records/:entity_type/:record_id/attachments/:attachment_id EntitiesAttachmentsRead",
    "GET /entities/records/:entity_type/:record_id/history EntitiesQuery",
    "POST /entities/records/:entity_type EntitiesRecordsWrite",
    "POST /entities/records/:entity_type/:record_id/attachments EntitiesAttachmentsManage",
    "POST /entities/records/:entity_type/import EntitiesRecordsImport",
    "PUT /entities/records/:entity_type/:record_id EntitiesRecordsWrite",
    "GET /tasks/:id TasksGetById",
    "POST /tasks/:id/assign TasksAssign",
    "POST /tasks/:id/claim TasksComplete",
    "POST /tasks/:id/complete TasksComplete",
    "POST /tasks/:id/reassign TasksReassign",
    "POST /documents/:document_id/hold DocumentHold",
    "POST /documents/:document_id/hold/release DocumentHold"
  ]

  # AC 19: every route of these routers is CLASSIFIED (declared or admin key table); a default-
  # sourced one fails `:data_route_default`, so a route added without a class breaks the build.
  # REQ-518 PR 2d added `Letflow.Routers.Tasks` together with the classification of its seven routes.
  @data_routers [Letflow.Routers.Entities, Letflow.Routers.Tasks, Letflow.Routers.Documents]

  # `:self_service` routes are allowed from REQ-518 PR 2c-i-b (AC 21); WHICH routes is the
  # committed `@self_service_routes` list below (SEC F-1).
  @self_service_routes_allowed? true

  # The shape of one `@self_service_routes` entry, checked when the module compiles (GH #2825).
  # The entries stay plain maps: the walk and the tests read them as maps, so a struct would
  # change what `self_service_routes/0` returns. Rules the walk applies to the list (a pending
  # ruling must not stand on a route that is not `:tenant_wide`, the REQ-519 AC 9 blocker) are
  # still the walk's job; this module refuses only what the walk cannot state as a shape.
  # The guard checks the path shape only: a route must sit under /me, /help or /definitions
  # (path-segment match); it does not rule on whether a route is safe as :self_service.
  defmodule SelfServiceEntry do
    @moduledoc false

    @fields [:class, :key, :route, :ruling]
    @methods ~w(GET POST PUT PATCH DELETE)
    @prefixes ["/me", "/help", "/definitions"]

    @typedoc """
    One ruled `/me`, `/help` or `/definitions` route: `route` is `"METHOD FULL_PATH"`. The guard
    checks the path shape only.
    """
    @type t :: %{
            route: String.t(),
            key: atom(),
            class: :self_service | :tenant_wide,
            ruling: String.t() | :pending_sec_ruling
          }

    @doc "Returns `entry` when it has the entry shape; raises `ArgumentError` naming the fault."
    @spec validate!(term()) :: t()
    def validate!(entry) do
      case check(entry) do
        :ok ->
          entry

        {:error, reason} ->
          raise ArgumentError,
                "malformed @self_service_routes entry #{inspect(entry)}: #{reason}"
      end
    end

    defp check(%{} = entry) do
      if Map.keys(entry) |> Enum.sort() == @fields do
        check_fields(entry)
      else
        {:error, "fields must be exactly route, key, class and ruling"}
      end
    end

    defp check(_entry), do: {:error, "an entry must be a map"}

    defp check_fields(%{route: route, key: key, class: class, ruling: ruling}) do
      with :ok <- check_route(route),
           :ok <- check_key(key),
           :ok <- check_class(class) do
        check_ruling(class, ruling)
      end
    end

    defp check_route(route) when is_binary(route) do
      case String.split(route, " ", parts: 2) do
        [method, path] ->
          cond do
            method not in @methods ->
              {:error, "unknown method in route #{inspect(route)}"}

            not Enum.any?(@prefixes, &(path == &1 or String.starts_with?(path, &1 <> "/"))) ->
              {:error, "route #{inspect(route)} is not under /me, /help or /definitions"}

            true ->
              :ok
          end

        _ ->
          {:error, "route must be \"METHOD FULL_PATH\""}
      end
    end

    defp check_route(_route), do: {:error, "route must be a string"}

    defp check_key(key) when is_atom(key) and key not in [nil, true, false], do: :ok
    defp check_key(_key), do: {:error, "key must be a policy key atom"}

    defp check_class(class) when class in [:self_service, :tenant_wide], do: :ok
    defp check_class(_class), do: {:error, "class must be :self_service or :tenant_wide"}

    defp check_ruling(:tenant_wide, :pending_sec_ruling), do: :ok

    defp check_ruling(_class, :pending_sec_ruling),
      do: {:error, ":pending_sec_ruling is only valid on a :tenant_wide entry"}

    defp check_ruling(_class, ruling) when is_binary(ruling) do
      if String.trim(ruling) == "",
        do: {:error, "ruling must be a ruling id, not blank"},
        else: :ok
    end

    defp check_ruling(_class, _ruling),
      do: {:error, "ruling must be a ruling id string or :pending_sec_ruling"}
  end

  # REQ-518 AC 21 (design 4.2): the ONE named place where the `/me` and `/help` routes are
  # ruled. Each entry: `route` (`"METHOD FULL_PATH"`), the policy `key`, `class`
  # (`:self_service`, or `:tenant_wide` for the "SEC-ruled tenant-wide" state) and `ruling` (a
  # ruling id, or `:pending_sec_ruling` for a route awaiting a ruling, which blocks REQ-519
  # AC 9). A route joins or leaves the class by editing this list AND its `scope:` declaration.
  @self_service_routes [
    %{
      route: "GET /me/memberships",
      key: :MembershipsRead,
      class: :self_service,
      ruling: "0051-A7"
    },
    %{
      route: "GET /me/modules",
      key: :MyModulesRead,
      class: :self_service,
      ruling: "SEC-518-R2-modules"
    },
    %{
      route: "GET /me/access",
      key: :MyAccessRead,
      class: :self_service,
      ruling: "SEC-REQ-449-access"
    },
    %{
      route: "GET /help/resolved",
      key: :HelpRead,
      class: :self_service,
      ruling: "SEC-518-R2-help"
    }
  ]

  # Compile-time shape check of every entry above (GH #2825): a malformed entry raises here,
  # so the build stops instead of the route walk finding it at test time.
  Enum.each(@self_service_routes, &SelfServiceEntry.validate!/1)

  # The path prefixes whose every route must appear in `@self_service_routes`.
  @self_service_prefixes ["/me", "/help"]

  @doc "The admin-plane key table."
  @spec admin_plane_keys() :: [atom()]
  def admin_plane_keys, do: @admin_plane_keys

  @doc "The committed ruled list of the `/me` and `/help` routes (AC 21, design 4.2)."
  @spec self_service_routes() :: [SelfServiceEntry.t()]
  def self_service_routes, do: @self_service_routes

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
  @spec audit_routes(
          routes :: [route_row()],
          default_snapshot :: [String.t()],
          self_service_list :: [map()]
        ) :: [error()]
  def audit_routes(routes, default_snapshot, self_service_list \\ @self_service_routes) do
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
      for r <- routes,
          (r.class == :filter and snapshot_line(r) not in @expected_filter_routes) or
            (r.class != :filter and snapshot_line(r) in @expected_filter_routes),
          do: {:unexpected_filter_route, r}

    unexpected_resolvers =
      for r <- routes,
          (match?({:resolver, _}, r.class) and snapshot_line(r) not in @expected_resolver_routes) or
            (not match?({:resolver, _}, r.class) and
               snapshot_line(r) in @expected_resolver_routes),
          do: {:unexpected_resolver_route, r}

    data_defaults =
      for r <- routes,
          r.router in @data_routers,
          r.source == :default,
          do: {:data_route_default, r}

    self_service_errors = audit_self_service(routes, self_service_list)

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
      self_service ++
      unexpected_filters ++
      unexpected_resolvers ++
      data_defaults ++ unknown_permissions ++ exam_reclassified ++ self_service_errors
  end

  # REQ-518 AC 21 (i), design 4.2. Every `/me` and `/help` route is on the list; the routes of
  # class `:self_service` are EXACTLY the list entries classed `:self_service`; a `:tenant_wide`
  # route of those prefixes (or entry) carries a ruling id or the `:pending_sec_ruling` marker; a
  # marker on an entry that is not a `:tenant_wide` route is stale.
  defp audit_self_service(routes, list) do
    by_route = Map.new(list, &{&1.route, &1})

    not_listed =
      for r <- routes,
          self_service_prefix?(r),
          not Map.has_key?(by_route, route_string(r)),
          do: {:self_service_not_listed, r}

    mismatch =
      for r <- routes,
          entry = Map.get(by_route, route_string(r)),
          self_service?(r) != self_service?(entry),
          do: {:self_service_list_mismatch, r}

    unlisted_self_service =
      for r <- routes,
          r.class == :self_service,
          not Map.has_key?(by_route, route_string(r)),
          do: {:self_service_list_mismatch, r}

    unruled_routes =
      for r <- routes,
          self_service_prefix?(r),
          r.class == :tenant_wide,
          entry = Map.get(by_route, route_string(r)),
          not ruled?(entry),
          do: {:tenant_wide_unruled, r}

    unruled_entries =
      for %{class: :tenant_wide} = entry <- list,
          not ruled?(entry),
          do: {:tenant_wide_unruled, entry.route}

    stale_markers =
      for %{ruling: :pending_sec_ruling} = entry <- list,
          entry.class != :tenant_wide or
            Enum.any?(routes, &(route_string(&1) == entry.route and &1.class != :tenant_wide)),
          do: {:pending_marker_unlisted, entry.route}

    not_listed ++
      mismatch ++ unlisted_self_service ++ unruled_routes ++ unruled_entries ++ stale_markers
  end

  defp self_service_prefix?(%{path: path}),
    do: Enum.any?(@self_service_prefixes, &(path == &1 or String.starts_with?(path, &1 <> "/")))

  defp self_service?(%{class: class}), do: class == :self_service

  defp route_string(%{method: method, path: path}), do: "#{method} #{path}"

  defp ruled?(%{ruling: :pending_sec_ruling}), do: true
  defp ruled?(%{ruling: ruling}), do: is_binary(ruling) and ruling != ""

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
