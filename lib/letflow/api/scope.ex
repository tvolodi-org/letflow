defmodule Letflow.Api.Scope do
  @moduledoc """
  The only place a 0051 scope decision is made (decision 0051 D1, D4; REQ-497 PR 1b / GH
  #2533, design `lib/letflow/design/req497-1b-allowed-flag-shadow-n1.md` section 1).

  `allowed?/3` runs AFTER the coarse `Letflow.Api.Authorization.evaluate_access/2`, which it
  does not change. It reads the database only for a `{:node, id}` resource, through
  `Letflow.ScopeNodePaths.resolve/2` (the 0050 D8 interface, the ONLY tree access). Grants
  are loaded by `load_grants/2` (one query through `Letflow.Identity.RoleScopeGrants`), once
  per request: the OIDC pipeline stores them in `auth_context.scope_grants`, the request
  memo every later consumer reads.

  ## Decision order of `allowed?/3`

    0. a permission outside `Authorization.permissions/0` -> `{:deny, :role_not_held}`;
    1. a platform-scope permission -> `{:allow, :platform}` iff
       `Authorization.has_permission_in_scope?/3`, else `{:deny, :role_not_held}` (grants
       and resource never read; INV-10);
    2. resource `:unresolvable` -> `{:deny, :unresolvable}`, for every principal;
    3. no held role allows the permission -> `{:deny, :role_not_held}`;
    4. a platform-tenant `PLATFORM_ADMIN` among those roles -> `{:allow, :platform}`;
    5. a token principal -> `{:allow, :token}` (tenant-wide for its token roles, D1);
    6. grants not loaded -> `{:deny, :grants_unavailable}`;
    7. combine `effective_scope/2` per candidate role: tenant-wide wins; else the union of
       nodes; nothing -> `{:deny, :no_grant_rows}` (a binding with zero rows is denied);
    8. resource `:tenant_wide`: `{:allow, :tenant_wide}` or `{:deny, :not_tenant_wide}`;
    9. resource `{:node, id}`: tenant-wide -> allow without a read; else the node or one of
       its ancestors in the node set -> `{:allow, :subtree}`, otherwise
       `{:deny, :out_of_scope}`; a missing, malformed or retired node ->
       `{:deny, :unresolvable}`.

  A resource node that is RETIRED is `{:deny, :unresolvable}` for a scoped principal
  (decision 0051 T6, REQ-517 2b); a tenant-wide principal is allowed without any read, so a
  retired node is still allowed for it. Only the resource node's own `retired_at` is
  considered (a grant can never name a retired node after 2a). A `script` principal (0051 D1) is
  not constructed in stage 1; the type excludes it on purpose.
  """

  import Plug.Conn, only: [assign: 3]

  require Logger

  alias Letflow.Api.Authorization
  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.PlatformTenant
  alias Letflow.ScopeNodePaths
  alias Letflow.TenantProvisioning

  # The closed set of deny reasons, the one literal list in lib/. `deny_reason()` is built from it
  # and `deny_reasons/0` exposes it, so ShadowEvidence and the metrics registry derive from here.
  # The migration CHECK of scope_shadow_counters is frozen history and stays literal; the
  # agreement test (test/letflow/api/scope/deny_reason_agreement_test.exs) guards it.
  @deny_reasons [
    :role_not_held,
    :no_grant_rows,
    :not_tenant_wide,
    :out_of_scope,
    :unresolvable,
    :grants_unavailable
  ]
  @deny_reason_union Enum.reduce(tl(@deny_reasons), hd(@deny_reasons), &{:|, [], [&1, &2]})

  @type node_id :: String.t()
  @type resource_scope :: :tenant_wide | {:node, node_id()} | :unresolvable
  @type allow_basis :: :tenant_wide | :subtree | :token | :platform
  @type deny_reason :: unquote(@deny_reason_union)
  @type decision :: {:allow, allow_basis()} | {:deny, deny_reason()}
  @type effective :: :tenant_wide | {:nodes, [node_id()]} | :deny

  @doc "The closed set of six deny reasons (`deny_reason()`), in declaration order."
  @spec deny_reasons() :: [deny_reason()]
  def deny_reasons, do: @deny_reasons

  defmodule ScopeSetError do
    @moduledoc """
    Raised by `Letflow.Api.Scope.allowed_set/2` when the allowed node set cannot be computed
    (REQ-518 SEC C-1). Carries only the reason atom; the message is constant (INV-4). It
    implements `Plug.Exception` with status 500; `Letflow.Plugs.ApiPipeline.handle_errors/2`
    turns it into the detail-free 500 response.
    """
    defexception [:reason]

    @type t :: %__MODULE__{reason: atom()}

    @impl true
    def message(_exception), do: "scope_set_failed"
  end

  defimpl Plug.Exception, for: ScopeSetError do
    def status(_exception), do: 500
    def actions(_exception), do: []
  end

  defmodule Grants do
    @moduledoc """
    The applicable `role_scope_grants` rows of one user, grouped by role name (0051 D1 step
    2). Built only by `Letflow.Api.Scope.load_grants/2`.
    """
    @enforce_keys [:user_id, :rows_by_role]
    defstruct [:user_id, :rows_by_role]

    @type row :: %{
            principal_type: :user | :group,
            tenant_wide: boolean(),
            scope_node_id: String.t() | nil
          }

    @type t :: %__MODULE__{user_id: Ecto.UUID.t(), rows_by_role: %{String.t() => [row()]}}
  end

  defmodule Principal do
    @moduledoc """
    Who is asking, as `Letflow.Api.Scope.allowed?/3` sees it. `prefix` is the plug's own
    `scoped_opts[:prefix]`, `platform_tenant?` is recomputed from the tenant id, `roles` are
    the effective roles, `grants` is `:token` for a token principal.
    """
    @enforce_keys [:kind, :user_id, :prefix, :platform_tenant?, :roles, :grants]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            kind: :user | :token,
            user_id: Ecto.UUID.t(),
            prefix: String.t(),
            platform_tenant?: boolean(),
            roles: [Authorization.role()],
            grants: Letflow.Api.Scope.Grants.t() | :token | :not_loaded
          }
  end

  @doc """
  The scope decision for `principal` exercising `permission` on `resource_scope` (decision
  order in the moduledoc). Never raises on a missing or malformed node; a DB error from the
  node read propagates (INV-8).
  """
  @spec allowed?(Principal.t(), Authorization.permission() | atom(), resource_scope()) ::
          decision()
  def allowed?(%Principal{} = principal, permission, resource_scope) do
    cond do
      permission not in Authorization.permissions() ->
        {:deny, :role_not_held}

      Authorization.permission_scope(permission) == :platform ->
        if Authorization.has_permission_in_scope?(
             principal.roles,
             permission,
             principal.platform_tenant?
           ),
           do: {:allow, :platform},
           else: {:deny, :role_not_held}

      resource_scope == :unresolvable ->
        {:deny, :unresolvable}

      true ->
        decide_tenant_permission(principal, permission, resource_scope)
    end
  end

  @doc """
  REQ-518 (design 3.3): the EXPANDED allowed node-id set of `principal` for `permission`, for
  the scoped data path: `{:ok, :all}` for a tenant-wide, token or platform principal,
  `{:ok, :none}` when the permission is not held, grants are unavailable or the grants name no
  live node, `{:ok, {:nodes, ids}}` otherwise (grant roots plus their LIVE descendants,
  sorted). Same decision order as `allowed?/3` (they share `tenant_effective/2`).

  Fail closed (SEC C-1, INV-8): if the node expansion fails (`:invalid_node_id`,
  `:invalid_schema_name`, `:too_many_ids`) this RAISES `Letflow.Api.Scope.ScopeSetError`
  carrying only the reason atom, after one constant log line; it never returns `:all`, a
  partial set or a silent `:none`. A database error from the node reads propagates.
  """
  @spec allowed_set(Principal.t(), Authorization.permission() | atom()) ::
          {:ok, Letflow.Entities.Query.Types.scope_set()}
  def allowed_set(%Principal{} = principal, permission) do
    cond do
      permission not in Authorization.permissions() ->
        {:ok, :none}

      Authorization.permission_scope(permission) == :platform ->
        if Authorization.has_permission_in_scope?(
             principal.roles,
             permission,
             principal.platform_tenant?
           ),
           do: {:ok, :all},
           else: {:ok, :none}

      true ->
        principal |> tenant_effective(permission) |> expand_set(principal)
    end
  end

  @doc """
  REQ-518 PR 2d (design C.3, the F1 rule): like `allowed?/3`, but only the effective scope of the
  ONE role named `role` counts, never the union of the roles that allow some permission. A role
  the principal does not hold is `{:deny, :role_not_held}`; a token principal that holds the
  role is `{:allow, :token}`; grants not loaded is `{:deny, :grants_unavailable}`; a role with
  no applicable row is `{:deny, :no_grant_rows}`; otherwise the same resource rules as
  `allowed?/3` (they share `decide_resource/3`, so the two cannot diverge).
  """
  @spec allowed_for_role?(Principal.t(), role :: String.t(), resource_scope()) :: decision()
  def allowed_for_role?(%Principal{} = principal, role, resource_scope) when is_binary(role) do
    cond do
      resource_scope == :unresolvable ->
        {:deny, :unresolvable}

      not role_held?(principal, role) ->
        {:deny, :role_not_held}

      principal.kind == :token ->
        {:allow, :token}

      not is_struct(principal.grants, Grants) ->
        {:deny, :grants_unavailable}

      true ->
        decide_resource(effective_scope(principal, role), resource_scope, principal)
    end
  end

  @doc """
  REQ-518 PR 2d (design C.3): the expanded allowed node set of `principal` for the ONE role
  `role` (same relation to `allowed_for_role?/3` as `allowed_set/2` has to `allowed?/3`): `:all`
  for a token principal holding the role or a tenant-wide grant of it, `:none` when the role is
  not held, grants are unavailable or no row names a live node, else `{:nodes, ids}`. Fails
  closed exactly like `allowed_set/2` (raises `ScopeSetError`, never `:all` or a partial set).
  """
  @spec allowed_set_for_role(Principal.t(), role :: String.t()) ::
          {:ok, Letflow.Entities.Query.Types.scope_set()}
  def allowed_set_for_role(%Principal{} = principal, role) when is_binary(role) do
    cond do
      not role_held?(principal, role) -> {:ok, :none}
      principal.kind == :token -> {:ok, :all}
      not is_struct(principal.grants, Grants) -> {:ok, :none}
      true -> expand_set({:combined, effective_scope(principal, role)}, principal)
    end
  end

  defp role_held?(principal, role),
    do: Enum.any?(principal.roles, &(Atom.to_string(&1) == role))

  defp expand_set({:decided, {:allow, _basis}}, _principal), do: {:ok, :all}
  defp expand_set({:decided, {:deny, _reason}}, _principal), do: {:ok, :none}
  defp expand_set({:combined, :tenant_wide}, _principal), do: {:ok, :all}
  defp expand_set({:combined, :deny}, _principal), do: {:ok, :none}

  defp expand_set({:combined, {:nodes, roots}}, principal) do
    case ScopeNodePaths.allowed_node_ids(roots, principal.prefix) do
      {:ok, []} -> {:ok, :none}
      {:ok, ids} -> {:ok, {:nodes, ids}}
      {:error, reason} -> raise_scope_set_error(reason)
    end
  end

  defp raise_scope_set_error(reason) do
    Logger.error("scope_set_failed reason=#{reason}")
    raise ScopeSetError, reason: reason
  end

  defp decide_tenant_permission(principal, permission, resource_scope) do
    case tenant_effective(principal, permission) do
      {:decided, decision} -> decision
      {:combined, combined} -> decide_resource(combined, resource_scope, principal)
    end
  end

  # Steps 3-7 of the decision order, shared by `allowed?/3` and `allowed_set/2` so the two
  # cannot diverge (REQ-518 D1): either a final decision, or the combined effective scope.
  defp tenant_effective(principal, permission) do
    candidates = Enum.filter(principal.roles, &Authorization.role_allows?(&1, permission))

    cond do
      candidates == [] ->
        {:decided, {:deny, :role_not_held}}

      :PLATFORM_ADMIN in candidates and principal.platform_tenant? == true ->
        {:decided, {:allow, :platform}}

      principal.kind == :token ->
        {:decided, {:allow, :token}}

      not is_struct(principal.grants, Grants) ->
        {:decided, {:deny, :grants_unavailable}}

      true ->
        {:combined,
         candidates
         |> Enum.map(&effective_scope(principal, Atom.to_string(&1)))
         |> combine()}
    end
  end

  defp combine(effectives) do
    if :tenant_wide in effectives do
      :tenant_wide
    else
      case for({:nodes, ids} <- effectives, id <- ids, do: id) do
        [] -> :deny
        ids -> {:nodes, ids |> Enum.uniq() |> Enum.sort()}
      end
    end
  end

  defp decide_resource(:deny, _resource_scope, _principal), do: {:deny, :no_grant_rows}
  defp decide_resource(:tenant_wide, _resource_scope, _principal), do: {:allow, :tenant_wide}
  defp decide_resource({:nodes, _ids}, :tenant_wide, _principal), do: {:deny, :not_tenant_wide}

  defp decide_resource({:nodes, ids}, {:node, node_id}, principal) do
    case ScopeNodePaths.resolve(node_id, principal.prefix) do
      {:ok, %{node: %{retired_at: retired_at}}} when not is_nil(retired_at) ->
        {:deny, :unresolvable}

      {:ok, %{ancestors: ancestors}} ->
        if node_id in ids or Enum.any?(ancestors, &(&1.node_id in ids)),
          do: {:allow, :subtree},
          else: {:deny, :out_of_scope}

      {:error, reason} when reason in [:node_not_found, :invalid_node_id, :invalid_schema_name] ->
        {:deny, :unresolvable}
    end
  end

  defp decide_resource({:nodes, _ids}, _malformed_resource, _principal),
    do: {:deny, :unresolvable}

  @doc """
  0051 D1 resolution for one role name: `:deny` when the role is not among the principal's
  roles, when `grants` is not loaded, or when the role has no applicable row;
  `:tenant_wide` when any applicable row is tenant-wide; else `{:nodes, ids}` (sorted,
  deduplicated). Pure.
  """
  @spec effective_scope(Principal.t(), role :: String.t()) :: effective()
  def effective_scope(%Principal{grants: %Grants{} = grants} = principal, role)
      when is_binary(role) do
    if role_held?(principal, role) do
      grants.rows_by_role |> Map.get(role, []) |> effective_from_rows()
    else
      :deny
    end
  end

  def effective_scope(%Principal{}, _role), do: :deny

  @doc """
  The scope of one role's applicable grant rows (the pure core of `effective_scope/2`, REQ-519
  2e-b): `:deny` for no rows, `:tenant_wide` when any row is tenant-wide, else the sorted,
  deduplicated scope node ids. Each row is a map with `:tenant_wide` and `:scope_node_id`.
  """
  @spec effective_from_rows(rows :: [map()]) :: effective()
  def effective_from_rows([]), do: :deny

  def effective_from_rows(rows) do
    if Enum.any?(rows, & &1.tenant_wide) do
      :tenant_wide
    else
      case rows |> Enum.map(& &1.scope_node_id) |> Enum.reject(&is_nil/1) do
        [] -> :deny
        ids -> {:nodes, ids |> Enum.uniq() |> Enum.sort()}
      end
    end
  end

  @doc """
  Loads the applicable grant rows of `user_id` in the tenant schema `prefix` with ONE query
  (`Letflow.Identity.RoleScopeGrants.applicable_rows_for_user/2`), grouped by role.
  """
  @spec load_grants(user_id :: Ecto.UUID.t(), prefix :: String.t()) :: Grants.t()
  def load_grants(user_id, prefix) when is_binary(prefix) do
    rows_by_role =
      user_id
      |> RoleScopeGrants.applicable_rows_for_user(prefix)
      |> Enum.group_by(& &1.role, &Map.delete(&1, :role))

    %Grants{user_id: user_id, rows_by_role: rows_by_role}
  end

  @doc """
  Builds the principal of the request. Requires `auth_context` with credential `:oidc`
  (a `:user`) or `:api_token` (a `:token`), and the plug's `scoped_opts[:prefix]`, which must
  be the schema of `auth_context.tenant_id`; otherwise `{:error, :no_principal}` (fail
  closed).

  Grants of a user: the memo in `auth_context.scope_grants` when it is a `Grants` struct of
  that user; `:not_loaded` when the pipeline stored `:not_loaded` (its load failed; no
  retry, so `allowed?/3` denies with `:grants_unavailable`); when the key is absent (a
  context that did not come from the pipeline), `load_grants/2` runs ONCE and the result is
  memoised in the returned conn, so a second call issues no query.
  """
  @spec principal_from_conn(Plug.Conn.t()) ::
          {:ok, Plug.Conn.t(), Principal.t()} | {:error, :no_principal}
  def principal_from_conn(%Plug.Conn{} = conn) do
    with %{} = ctx <- Map.get(conn.assigns, :auth_context),
         {:ok, kind} <- principal_kind(Map.get(ctx, :credential)),
         user_id when is_binary(user_id) <- Map.get(ctx, :user_id),
         {:ok, prefix} <- scoped_prefix(conn, Map.get(ctx, :tenant_id)) do
      platform_tenant? = PlatformTenant.platform_tenant?(Map.get(ctx, :tenant_id))
      roles = Authorization.effective_roles(Map.get(ctx, :roles, []), platform_tenant?)
      {conn, grants} = grants_for(conn, ctx, kind, user_id, prefix)

      {:ok, conn,
       %Principal{
         kind: kind,
         user_id: user_id,
         prefix: prefix,
         platform_tenant?: platform_tenant?,
         roles: roles,
         grants: grants
       }}
    else
      _no_principal -> {:error, :no_principal}
    end
  end

  defp principal_kind(:oidc), do: {:ok, :user}
  defp principal_kind(:api_token), do: {:ok, :token}
  defp principal_kind(_other), do: :error

  # The prefix is the plug's own (never derived here); it must match the tenant's schema.
  defp scoped_prefix(conn, tenant_id) do
    with opts when is_list(opts) <- Map.get(conn.assigns, :scoped_opts),
         prefix when is_binary(prefix) <- Keyword.get(opts, :prefix),
         {:ok, ^prefix} <- TenantProvisioning.schema_name_for_tenant(tenant_id) do
      {:ok, prefix}
    else
      _missing_or_mismatch -> :error
    end
  end

  defp grants_for(conn, _ctx, :token, _user_id, _prefix), do: {conn, :token}

  defp grants_for(conn, ctx, :user, user_id, prefix) do
    case Map.fetch(ctx, :scope_grants) do
      {:ok, %Grants{user_id: ^user_id} = grants} ->
        {conn, grants}

      {:ok, :not_loaded} ->
        {conn, :not_loaded}

      _absent_or_stale ->
        grants = load_grants(user_id, prefix)
        {assign(conn, :auth_context, Map.put(ctx, :scope_grants, grants)), grants}
    end
  end

  @doc """
  The admin-plane gate (0051 D11) of the stage-1 scope-enforcement routes:
  `principal_from_conn/1`, then `allowed?(principal, permission, :tenant_wide)`. An allow
  returns the (possibly memoised) conn; a deny or no principal returns
  `{:error, conn, :not_tenant_wide}` and the caller answers the unchanged 403.
  """
  @spec require_tenant_wide(Plug.Conn.t(), permission :: atom()) ::
          {:ok, Plug.Conn.t()} | {:error, Plug.Conn.t(), :not_tenant_wide}
  def require_tenant_wide(%Plug.Conn{} = conn, permission) do
    case principal_from_conn(conn) do
      {:ok, conn, principal} ->
        case allowed?(principal, permission, :tenant_wide) do
          {:allow, _basis} -> {:ok, conn}
          {:deny, _reason} -> {:error, conn, :not_tenant_wide}
        end

      {:error, :no_principal} ->
        {:error, conn, :not_tenant_wide}
    end
  end

  @doc """
  The shared authority of the two admin-only flag-like routes (REQ-519 2f-b, SEC S-3; REQ-517
  AC 12): `PUT /tenant/scope-enforcement` and `PUT /users/:id/service-principal`. In this
  order: (1) an interactive credential (`auth_context.credential == :oidc`, so an API token,
  even one holding TENANT_ADMIN, is refused; an absent credential is refused); (2)
  `:UsersGroupsRolesManage` held tenant-wide (`require_tenant_wide/2`); (3) the caller holds
  TENANT_ADMIN, tenant-wide (a platform-tenant PLATFORM_ADMIN alone does not). Every refusal
  is the same `{:error, conn, :forbidden}`; the caller answers the unchanged uniform 403.
  """
  @spec require_interactive_tenant_admin(Plug.Conn.t()) ::
          {:ok, Plug.Conn.t()} | {:error, Plug.Conn.t(), :forbidden}
  def require_interactive_tenant_admin(%Plug.Conn{} = conn) do
    with :oidc <- Map.get(conn.assigns[:auth_context] || %{}, :credential),
         {:ok, conn} <- require_tenant_wide(conn, :UsersGroupsRolesManage),
         {:ok, conn, principal} <- principal_from_conn(conn),
         true <- :TENANT_ADMIN in principal.roles,
         :tenant_wide <- effective_scope(principal, "TENANT_ADMIN") do
      {:ok, conn}
    else
      _not_allowed -> {:error, conn, :forbidden}
    end
  end
end
