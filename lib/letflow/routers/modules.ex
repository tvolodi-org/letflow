defmodule Letflow.Routers.Modules do
  @moduledoc """
  REQ-404 — the D4/D5 module-router dispatch mount. See
  `lib/letflow/design/req404-module-router-mount.md` for the full design (a
  CODE-DESIGN-VALIDATOR-approved design), not a fresh design of its own.

  Mounted at `/modules` by `Letflow.Plugs.ApiPipeline` (full path
  `/api/v1/modules/<module_id>/<rest...>`).

  ## A plain `Plug`, not `Letflow.Api.AuthorizedRouter` (design §1.1)

  `AuthorizedRouter`'s `plug(:match) -> plug(Letflow.Plugs.Authorize) ->
  plug(:dispatch)` chain runs a permission check on EVERY request before any
  handler code runs. D5 requires the OPPOSITE order here: "is this module
  installed for this tenant" must be answered, and can return 404, BEFORE
  any permission evaluation, for every role including `PLATFORM_ADMIN`. So
  this dispatcher does no authorization evaluation of its own — it forwards
  to the module's own `router/0` (an `AuthorizedRouter`-based router, per
  the module contract's `router/0` callback), which performs the REAL
  permission check.

  ## D5's ordering invariant, restated precisely for this dispatcher

  No branch in `call/2` below ever calls
  `Letflow.Api.Authorization.evaluate_access/2` or any function that does.
  The only downstream code that evaluates a permission is the
  forwarded-to module's own `Letflow.Plugs.Authorize`, reached only after
  every 404 branch below has already been cleared.

  ## Response-body minimality / no information leak (D5)

  Every 404 branch below calls the exact same zero-argument
  `Letflow.Api.Response.not_found/1` — the response cannot distinguish
  "module doesn't exist" from "module exists but isn't installed for you"
  from "module exists, installed, but has no `router/0`."

  ## Deploy-skew gate (decision 0055 D5, T-1548)

  `resolve/2` asks `Installs.gate_state/2` (ONE query, replacing `installed?/2`) and, for an installed
  module with a router, `Installs.version_verdict/2`: a stored data version below the manifest's
  `min_data_version` answers 503 `module_upgrade_required`; above the build's `:version` answers 503
  `module_version_ahead`. Both are sent before the module's own permission check, with fixed text (no
  version, hash or module id). Every 404 branch is unchanged. This is NOT the 409 `upgrade_required`
  (manifest-hash based, task completion and reactivate paths); the two share no code path.

  ## INV-1 (tenant scoping is server-derived only)

  `scoped_opts` here is derived exclusively from
  `conn.assigns.auth_context.tenant_id` via
  `Letflow.Api.Context.scoped_repo_opts/1` — the identical function and
  identical source `Letflow.Plugs.Authorize` itself uses. No path segment,
  query parameter, or header is read for tenant identification.

  ## D3 (module boundary)

  This file never names a concrete module. Every module reference here is
  one of `Letflow.Modules.Catalog`, `Letflow.Modules.Installs`, or a
  runtime value (`entry_module`) obtained from `Catalog.fetch/1` — never a
  literal `Letflow.Modules.<id>` name.

  ## INV-5 timing parity (design §9, post-SECURITY-REVIEWER amendment)

  `resolve/2` below computes `Installs.installed?/2`'s DB round trip
  UNCONDITIONALLY, independent of the free in-memory catalog/router-export
  checks — never behind a short-circuiting `with`-chain gated on those
  checks. Every request that reaches `resolve/2` pays exactly one DB round
  trip, whether `module_id` is unknown to the catalog, known but has no
  `router/0`, or known-and-installed. This closes a real timing side
  channel: a `with`-chain that fails the free catalog check first (0 DB
  round trips) versus one that clears it and only then fails the DB-backed
  install check (1 DB round trip) lets a caller distinguish "module never
  registered" from "registered but not installed for you" purely by
  latency — forbidden by INV-5/D5. See design §9.1–§9.4 for the full
  analysis, including why reordering the chain (instead of decoupling the
  DB check from short-circuit evaluation entirely) does not fix it.
  """

  @behaviour Plug

  alias Letflow.Api.Context
  alias Letflow.Api.Response
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(_opts), do: []

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case conn.path_info do
      [] ->
        Response.not_found(conn)

      [module_id | rest] ->
        gate(conn, module_id, rest)
    end
  end

  # Design §9.3: step 2's scoped_opts resolution is unchanged and still
  # short-circuits first (no DB-cost asymmetry to fix there). Steps 3-6 are
  # then delegated to resolve/2, which must NOT be wired as a
  # short-circuiting with-chain against Installs.installed?/2 (see moduledoc
  # "INV-5 timing parity").
  @spec gate(Plug.Conn.t(), module_id :: String.t(), rest :: [String.t()]) ::
          Plug.Conn.t()
  defp gate(conn, module_id, rest) do
    case Context.scoped_repo_opts(conn) do
      {:ok, scoped_opts} ->
        conn = Plug.Conn.assign(conn, :scoped_opts, scoped_opts)

        case resolve(module_id, scoped_opts) do
          {:ok, _entry_module, router} -> Plug.forward(conn, rest, router, router.init([]))
          :reject -> Response.not_found(conn)
          {:refuse, :too_old} -> Response.module_data_version_too_old(conn)
          {:refuse, :ahead} -> Response.module_version_ahead(conn)
        end

      {:error, :missing_auth_context} ->
        Response.internal_error(conn)

      {:error, :invalid_tenant_id} ->
        Response.internal_error(conn)
    end
  end

  # Design §9.3/§9.4: `installed?` is computed UNCONDITIONALLY, in every
  # call, independent of catalog_result/has_router? -- never nested inside
  # an `if`/`with` guarded by either of those free checks. The catalog
  # lookup and function_exported?/3 check remain free/in-memory and may
  # still short-circuit against EACH OTHER (no timing asymmetry exists
  # between "unknown id" and "id has no router", since both are zero-cost);
  # only the DB-touching check must never be skipped. The three outcomes
  # collapse into a single undifferentiated :reject -- the caller cannot
  # observe which sub-check failed, preserving AC3's byte-identical 404
  # body.
  @spec resolve(module_id :: String.t(), scoped_opts :: keyword()) ::
          {:ok, entry_module :: module(), router :: module()}
          | :reject
          | {:refuse, :too_old | :ahead}
  defp resolve(module_id, scoped_opts) do
    gate_state = Installs.gate_state(module_id, scoped_opts)

    case Catalog.fetch(module_id) do
      {:ok, entry_module} ->
        has_router? = function_exported?(entry_module, :router, 0)

        case {has_router?, gate_state} do
          {true, {:installed, stored}} ->
            case Installs.version_verdict(entry_module.manifest(), stored) do
              :ok -> {:ok, entry_module, entry_module.router()}
              refusal -> {:refuse, refusal}
            end

          _ ->
            :reject
        end

      {:error, :not_found} ->
        :reject
    end
  end
end
