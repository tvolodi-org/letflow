defmodule Letflow.Api.AuthorizedRouter do
  @moduledoc """
  The single route-declaration surface for every sub-router under
  `lib/letflow/routers/` (REQ-131, per REQ-130's design §2.3/§2.4). Replaces
  `use Plug.Router` + a router-local `with_authorized_scope/4`/
  `with_authorization/4` copy — every router that used either of those
  (`identity.ex`, `audit.ex`, `definitions.ex`, `instances.ex`,
  `onboarding.ex`, `tenants.ex`, `tasks.ex`) now `use`s this module instead,
  and so does every router that had no authorization call at all
  (`solution_packs.ex`, `promotion.ex`, `metrics.ex`) — one mechanism for
  the whole tree, not two.

  ## What `use Letflow.Api.AuthorizedRouter` does

    1. `use Plug.Router` — unchanged base behaviour.
    2. Registers an accumulating `@authz_routes` module attribute and, via
       `@before_compile`, a `__authz_routes__/0` function returning the
       accumulated `{method, path_template, policy_key}` list — this is the
       compiled route table `test/letflow/api/authorization_enforcement_test.exs`
       (REQ-131's enforcement artefact, design §4) introspects. Reflection,
       not source re-parsing.
    3. `plug(:match)`, then `plug(Letflow.Plugs.Authorize)`, then
       `plug(:dispatch)` — the mandatory plug runs for **every** request
       reaching this router, whether the matched route was declared with
       `authz_get/3` (etc, below) or with a plain `get`/`post`/`patch`/
       `delete`/`match` route. There is no route shape in a router using
       this module that bypasses `Letflow.Plugs.Authorize`.

  ## `authz_get/3`, `authz_post/3`, `authz_put/3`, `authz_patch/3`, `authz_delete/3`

  Drop-in replacements for `Plug.Router`'s `get/3`/`post/3`/`put/3`/
  `patch/3`/`delete/3` that additionally take a **compile-time literal** policy-key
  atom (an `Letflow.Api.Authorization.endpoint_policy_key()` value) as the
  second argument (and an OPTIONAL `scope:` class, below):

      authz_get "/users/:id", :UsersManage do
        handle_get(conn, conn.params["id"])
      end

  expands to a plain `Plug.Router.match/3` call carrying
  `private: %{policy_key: :UsersManage}` — resolved by the compiled
  `:match` plug at route-match time, before the body runs, so
  `Letflow.Plugs.Authorize` (running immediately after `:match`) already
  has the policy key by the time it evaluates the request. The route is
  also recorded into `@authz_routes` for the enforcement test.

  Inside the `do` block, a handler reads `conn.assigns.scoped_opts` (the
  `[prefix: schema]` keyword list) and `conn.assigns.access_decision` (the
  full `%Letflow.Api.Authorization.AccessDecision{}`, needed only by a
  handler with a row-scoped concept of its resource — today, only
  `Letflow.Routers.Tasks`'s list/inbox handlers) instead of receiving `opts`
  as a wrapped-function argument the way the deleted
  `with_authorized_scope/4` helpers used to pass it.

  ## Route scope class (REQ-517 2b, decision 0051 D5/D11)

  Every `authz_*` macro also has an arity-4 form that declares the route's scope class:

      authz_post "/instances/:id/attachments/:attachment_id/link", :AttachmentLinksIssue,
        scope: :tenant_wide do
        ...
      end

  The class must be a compile-time literal: `:admin_plane`, `:tenant_wide`, `:filter`,
  `:self_service` or `{:resolver, {Module, :function}}`; anything else is a `CompileError`.
  A declared class is stored in the route's private map as `scope_class` (beside
  `policy_key`) and accumulated into a SECOND attribute, exposed as
  `__authz_route_scopes__/0` (`{method, path, class}` for DECLARED routes only).
  `__authz_routes__/0` keeps its 3-tuple shape. A route with no declared class is classified
  by `Letflow.Api.RouteScope.class_of/1` (key table, then the fail-closed `:tenant_wide`
  default); see that module.

  ## No plain verb macros (ISS-0993 G0)

  `use Letflow.Api.AuthorizedRouter` re-imports `Plug.Router` WITHOUT the plain
  `get`/`post`/`put`/`patch`/`delete`/`head`/`options` macros (keeping only
  `match/2,3` and `forward/2`), so a route declared with a plain verb macro no
  longer compiles: every route carries an explicit policy key via `authz_*`,
  and none can resolve to `:Unknown`. The router's own catch-all is declared
  with `authz_unmatched(:platform_prefix | :ordinary)`, which attaches a private
  marker key (`:UnmatchedPlatformPath` / `:UnmatchedRoute`, see
  `Letflow.Api.Authorization.evaluate_access/2` rule 1a) and answers the same 404.
  """

  defmacro __using__(_opts) do
    quote do
      use Plug.Router

      # ISS-0993 G0: re-import Plug.Router WITHOUT the plain get/post/put/patch/
      # delete/head/options macros (a later `import` of the same module replaces
      # the earlier one), keeping `match/2,3` for the router's own `match _`
      # catch-all and `forward/2`. A route declared with a plain-verb macro
      # therefore no longer compiles; every route must use `authz_*` and so
      # carries an explicit policy key (never `:Unknown`).
      import Plug.Router, only: [match: 2, match: 3, forward: 2]

      Module.register_attribute(__MODULE__, :authz_routes, accumulate: true)
      Module.register_attribute(__MODULE__, :authz_route_scopes, accumulate: true)
      @before_compile Letflow.Api.AuthorizedRouter

      import Letflow.Api.AuthorizedRouter,
        only: [
          authz_get: 3,
          authz_get: 4,
          authz_post: 3,
          authz_post: 4,
          authz_put: 3,
          authz_put: 4,
          authz_patch: 3,
          authz_patch: 4,
          authz_delete: 3,
          authz_delete: 4,
          authz_unmatched: 1
        ]

      plug(:match)
      plug(Letflow.Plugs.Authorize)
      plug(:dispatch)
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc false
      @spec __authz_routes__() :: [
              {String.t(), String.t(), Letflow.Api.Authorization.endpoint_policy_key()}
            ]
      def __authz_routes__, do: @authz_routes

      @doc false
      @spec __authz_route_scopes__() :: [
              {String.t(), String.t(), Letflow.Api.RouteScope.class()}
            ]
      def __authz_route_scopes__, do: @authz_route_scopes
    end
  end

  defmacro authz_get(path, policy_key, do: block) do
    build_route("GET", :get, path, policy_key, nil, block)
  end

  defmacro authz_get(path, policy_key, opts, do: block) do
    build_route("GET", :get, path, policy_key, scope_class!(opts, __CALLER__), block)
  end

  defmacro authz_post(path, policy_key, do: block) do
    build_route("POST", :post, path, policy_key, nil, block)
  end

  defmacro authz_post(path, policy_key, opts, do: block) do
    build_route("POST", :post, path, policy_key, scope_class!(opts, __CALLER__), block)
  end

  defmacro authz_put(path, policy_key, do: block) do
    build_route("PUT", :put, path, policy_key, nil, block)
  end

  defmacro authz_put(path, policy_key, opts, do: block) do
    build_route("PUT", :put, path, policy_key, scope_class!(opts, __CALLER__), block)
  end

  defmacro authz_patch(path, policy_key, do: block) do
    build_route("PATCH", :patch, path, policy_key, nil, block)
  end

  defmacro authz_patch(path, policy_key, opts, do: block) do
    build_route("PATCH", :patch, path, policy_key, scope_class!(opts, __CALLER__), block)
  end

  defmacro authz_delete(path, policy_key, do: block) do
    build_route("DELETE", :delete, path, policy_key, nil, block)
  end

  defmacro authz_delete(path, policy_key, opts, do: block) do
    build_route("DELETE", :delete, path, policy_key, scope_class!(opts, __CALLER__), block)
  end

  @doc """
  Declares a router's catch-all (ISS-0993 design section 7.5). Replaces
  `match _ do Response.not_found(conn) end`: sets the private marker policy key
  for the request and answers the same zero-detail 404.

    * `:platform_prefix` -> marker `:UnmatchedPlatformPath` (routers mounted at
      `/tenants`, `/onboarding`, `/platform-migrations`, `/event-retention`,
      `/admin/services`): only a platform-tenant `PLATFORM_ADMIN` reaches the 404;
      every other caller gets the same 403 as a matched platform route (OQ-4).
    * `:ordinary` -> marker `:UnmatchedRoute` (every other router): only the
      PLATFORM-TENANT operator (`platform_tenant?` true and `PLATFORM_ADMIN`) reaches
      the router's own 404; every other caller, a tenant admin included, gets the
      uniform 403. A tenant `PLATFORM_ADMIN` no longer exists outside the platform
      tenant (REQ-447 PR 2).

  A catch-all is not a route, so it is not recorded in `__authz_routes__/0`.
  """
  defmacro authz_unmatched(kind) when kind in [:platform_prefix, :ordinary] do
    marker =
      case kind do
        :platform_prefix -> :UnmatchedPlatformPath
        :ordinary -> :UnmatchedRoute
      end

    quote do
      Plug.Router.match _, private: %{policy_key: unquote(marker)} do
        Letflow.Api.Response.not_found(var!(conn))
      end
    end
  end

  # Generates a plain, fully-qualified Plug.Router.match/3 call (never
  # relying on get/post/patch/delete being imported into the caller's own
  # scope, sidestepping macro-hygiene ambiguity entirely) carrying the
  # policy key as route-match :private metadata, plus an @authz_routes
  # accumulation for the enforcement test to introspect.
  @spec build_route(String.t(), atom(), term(), term(), term(), term()) :: Macro.t()
  defp build_route(method, verb, path, policy_key, nil, block) do
    quote do
      @authz_routes {unquote(method), unquote(path), unquote(policy_key)}

      Plug.Router.match unquote(path),
        via: unquote(verb),
        private: %{policy_key: unquote(policy_key)} do
        unquote(block)
      end
    end
  end

  # A DECLARED class: also recorded in the second accumulator and carried in the private map.
  defp build_route(method, verb, path, policy_key, class, block) do
    escaped_class = Macro.escape(class)

    quote do
      @authz_routes {unquote(method), unquote(path), unquote(policy_key)}
      @authz_route_scopes {unquote(method), unquote(path), unquote(escaped_class)}

      Plug.Router.match unquote(path),
        via: unquote(verb),
        private: %{policy_key: unquote(policy_key), scope_class: unquote(escaped_class)} do
        unquote(block)
      end
    end
  end

  # The `scope:` option must be a keyword list with exactly that key and a compile-time
  # literal class (REQ-517 AC 17); anything else is a CompileError at the route.
  @spec scope_class!(Macro.t(), Macro.Env.t()) :: Letflow.Api.RouteScope.class()
  defp scope_class!(opts, caller) do
    with true <- Keyword.keyword?(opts),
         [:scope] <- Keyword.keys(opts),
         {:ok, class} <- class_literal(Keyword.fetch!(opts, :scope), caller) do
      class
    else
      _invalid -> bad_scope!(caller)
    end
  end

  defp class_literal(class, _caller)
       when class in [:admin_plane, :tenant_wide, :filter, :self_service],
       do: {:ok, class}

  defp class_literal({:resolver, {module_ast, fun}}, caller) when is_atom(fun) do
    case Macro.expand(module_ast, caller) do
      module when is_atom(module) and module not in [nil, true, false] ->
        {:ok, {:resolver, {module, fun}}}

      _not_a_module ->
        :error
    end
  end

  defp class_literal(_other, _caller), do: :error

  defp bad_scope!(caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "authz_* route option must be exactly `scope: <class>` with a literal class " <>
          "(:admin_plane, :tenant_wide, :filter, :self_service or {:resolver, {Module, :fun}})"
  end
end
