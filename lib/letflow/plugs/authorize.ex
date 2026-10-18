defmodule Letflow.Plugs.Authorize do
  @moduledoc """
  Mandatory authorization plug (REQ-131), built exactly to REQ-130's design
  (`lib/letflow/design/req130-authorization-generalization.md` §2.3).
  Supersedes every router-local `with_authorized_scope/4`/`with_authorization/4`
  copy that existed before this requirement (`identity.ex`, `audit.ex`,
  `definitions.ex`, `instances.ex`, `onboarding.ex`, `tenants.ex`, `tasks.ex`)
  — all deleted, not adapted, by this same requirement.

  Mounted automatically by every sub-router under `lib/letflow/routers/`
  that does `use Letflow.Api.AuthorizedRouter` (which `plug`s this module
  between `:match` and `:dispatch`) — never wired by hand at a route, and
  never opt-in per route. A route declared with `Letflow.Api.AuthorizedRouter`'s
  `authz_get/3`/`authz_post/3`/`authz_patch/3`/`authz_delete/3` macros gets
  its own literal policy key enforced; a route declared with the plain
  `Plug.Router` `get`/`post`/`patch`/`delete` macros (or the router's own
  catch-all `match _`) still passes through this plug — since it is
  unconditionally in the pipeline — and is evaluated as `:Unknown`, which is
  DENIED for every role (ISS-0993 A2). There is no route shape that reaches a
  handler without going through this plug.

  ## Ordering (design §2.3)

  Runs strictly after `Letflow.Plugs.AuthPipeline` (so
  `conn.assigns.auth_context` — `user_id`, `tenant_id`, `roles` — is already
  populated) and performs the tenant-scope resolution
  (`Letflow.Api.Context.scoped_repo_opts/1`) itself, before evaluating
  authorization — matching every incumbent per-router preamble's own
  ordering (scope resolved first, permission checked second, matching
  `identity.ex`'s/`tasks.ex`'s former `with_authorized_scope/4`). A
  scope-resolution failure (`{:error, :missing_auth_context |
  :invalid_tenant_id}`) is an immediate `500`
  (`Letflow.Api.Response.internal_error/1`), sent and the conn halted,
  before `Letflow.Api.Authorization.evaluate_access/2` is ever called.

  ## Policy key resolution — literal, never request-derived (design §2.1, §2.3)

  `Letflow.Api.AuthorizedRouter`'s route macros attach the route's policy
  key as `conn.private[:policy_key]` via `Plug.Router`'s own `:private`
  route-match option — resolved by the compiled `:match` plug at
  route-match time from a **compile-time literal atom** baked into the
  route declaration, never derived from `conn.request_path`,
  `conn.path_info`, or any other request-observed value. This preserves
  REQ-130's design §2.1 safety property (the same one every incumbent
  per-call-site helper already honoured) while moving *where* the literal
  lives (declared once at the route) and *who* enforces it runs
  (unconditionally, for every route under a router using
  `Letflow.Api.AuthorizedRouter`).

  A route matched with no `:policy_key` private key present — i.e. a route
  declared with the plain `get`/`post`/`patch`/`delete` macros instead of
  `authz_*` — is treated as `endpoint == :Unknown`, which
  `Letflow.Api.Authorization.evaluate_access/2` denies (403) for EVERY role,
  `PLATFORM_ADMIN` included (ISS-0993 rule 1). A router's own catch-all is
  declared through `authz_unmatched/1` and carries one of two marker keys
  instead (design section 7.5), so a platform-tenant operator keeps the 404.

  ## Platform scope (ISS-0993 / ISS-0994, INV-10) -- enforcing (A2)

  The plug recomputes `platform_tenant?` from the database-resolved
  `auth_context.tenant_id` (`Letflow.PlatformTenant.platform_tenant?/1`; the flag
  stored by the pipeline is never read). A platform-scope permission is honoured
  only for a `PLATFORM_ADMIN` of the platform tenant; with no pin configured it is
  denied to everyone (fail closed). Every `:Deny403` emits one attribution log
  line through `Letflow.Api.AuthzDenyLog` (ISS-0995): HTTP method, route
  pattern, policy key, platform-scope boolean, and keyed hashes of the caller
  and tenant ids, sampled for repeated denials. Nothing identifying (token,
  email, raw ids, path values) reaches the line (INV-4), and the denial
  response is identical: it still carries no tenant id, role or token.

  ## Scope modes (REQ-497 / REQ-517)

  After the coarse allow, a tenant stored as `shadow` is only observed
  (`Letflow.Api.Scope.Shadow`) and one stored as `on` is enforced
  (`Letflow.Api.Scope.Enforce`, which may halt with a 403 or a fail-closed 500); `off`
  changes nothing.

  ## What reaches the handler on `:Allow`/`:AllowWithRowFilter` (design §6)

    * `conn.assigns[:scoped_opts]` — the `[prefix: schema]` keyword list
      every handler passes to its own `Repo`/context-module calls. Replaces
      the `opts` argument every incumbent `with_authorized_scope/4`-wrapped
      handler used to receive as a function argument.
    * `conn.assigns[:access_decision]` — the **full** `%AccessDecision{}`
      struct, never collapsed to a bare boolean or to its `:kind` alone —
      so a handler that needs `decision.task_scope` (today, only
      `Letflow.Routers.Tasks`'s `GET /tasks`/`GET /tasks/inbox`, the only
      policy key that can ever produce `:AllowWithRowFilter`) can read it.
      A handler with no row-scoped concept of its resource ignores this key
      entirely, exactly like every already-wired router except `tasks.ex`
      already does.

  On `:Deny403`, this plug itself sends `403` via
  `Letflow.Api.Response.forbidden/2` (RFC 9457 problem document via
  `Letflow.Api.Response`/`Letflow.Api.Error`, `Content-Type:
  application/problem+json`, per REQ-066's contract) and halts the conn —
  no handler runs, no `Repo` call of any kind has happened by this point.
  """

  @behaviour Plug

  import Plug.Conn

  alias Letflow.Api.Authorization
  alias Letflow.Api.AuthzDenyLog
  alias Letflow.Api.Context
  alias Letflow.Api.Response
  alias Letflow.PlatformTenant

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Context.scoped_repo_opts(conn) do
      {:error, _missing_auth_context_or_invalid_tenant_id} ->
        conn |> Response.internal_error() |> halt()

      {:ok, prefix: _schema} = ok ->
        # ISS-0993 (design section 4): `platform_tenant?` is RECOMPUTED from the
        # database-resolved tenant id; the flag stored in auth_context (if any)
        # is never read, so a hand-assigned context stays fail-closed.
        platform_tenant? =
          PlatformTenant.platform_tenant?(Map.get(conn.assigns.auth_context, :tenant_id))

        # REQ-447 PR 2 (design 3.5): PLATFORM_ADMIN is dropped outside the
        # platform tenant by the one shared resolution function.
        ctx = %Authorization.AccessContext{
          user_id: conn.assigns.auth_context.user_id,
          roles: Authorization.effective_roles(conn.assigns.auth_context.roles, platform_tenant?),
          platform_tenant?: platform_tenant?
        }

        # No :policy_key private key present (a plain get/post/patch/delete)
        # -> :Unknown, which evaluate_access/2 denies for every role.
        policy_key = Map.get(conn.private, :policy_key, :Unknown)

        decision = Authorization.evaluate_access(ctx, policy_key)

        case decision.kind do
          :Deny403 ->
            AuthzDenyLog.log_denial(conn, ctx, policy_key)
            conn |> Response.forbidden("insufficient permissions") |> halt()

          _allow_or_allow_with_row_filter ->
            {:ok, opts} = ok

            conn
            |> assign(:scoped_opts, opts)
            |> assign(:access_decision, decision)
            |> apply_scope_mode(ctx, policy_key)
        end
    end
  end

  # Runs after the assigns, so both modes use this plug's own `scoped_opts[:prefix]`. A
  # context without the `scope_enforcement` key (or any other value) reads as `:off`.
  #
  #   * `:shadow` (REQ-497 PR 1b, design section 4.1, 0051 Rollout 3): the scope decision is
  #     computed AFTER the coarse allow and only observed (counters + sampled log); it never
  #     halts or changes the response.
  #   * `:on` (REQ-517 PR 2b, design section 4.3): `Letflow.Api.Scope.Enforce.check/3` applies
  #     the route's scope class and may halt with a 403 (or a fail-closed 500).
  defp apply_scope_mode(conn, ctx, policy_key) do
    case Map.get(conn.assigns.auth_context, :scope_enforcement) do
      # MUTANT N1: Enforce also runs under shadow
      :shadow ->
        conn
        |> Letflow.Api.Scope.Shadow.observe(ctx, policy_key)
        |> Letflow.Api.Scope.Enforce.check(ctx, policy_key)

      :on -> Letflow.Api.Scope.Enforce.check(conn, ctx, policy_key)
      _off_or_absent -> conn
    end
  end
end
