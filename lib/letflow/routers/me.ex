defmodule Letflow.Routers.Me do
  @moduledoc """
  REQ-384 Part A — implements
  `lib/letflow/design/req384-tenant-switcher-cache-isolation.md` §2.2 exactly
  (a CODE-DESIGN-VALIDATOR-approved design), not a fresh design of its own.
  Mounted at `/me` by `Letflow.Plugs.ApiPipeline` (full path
  `/api/v1/me/memberships`) — the normal authenticated `/api/v1` forward
  chain every other sub-router uses, not an unauthenticated route.

  ## Route

  | Handler | Method/path | Delegates to | Permission | Response |
  |---|---|---|---|---|
  | handle_list_memberships | `GET /me/memberships` | `Letflow.Identity.list_memberships_for_subject/1` | `:MembershipsRead` | 200 |
  | handle_list_modules | `GET /me/modules` | `Letflow.Modules.Installs.list_installed/1` | `:MyModulesRead` | 200 |

  ## `GET /me/modules` (REQ-403)

  Granted to every role, including `CANDIDATE` and `AGENT_RUNNER` — unlike
  `:MembershipsRead` above, this route deliberately does NOT widen
  `CANDIDATE`'s ISS-0646 closed permission set; instead it grows that set
  by exactly one new atom, `:MyModulesRead`, via a role-agnostic
  `role_allows?/2` clause. See `lib/letflow/api/authorization.ex`'s
  `role_allows?/2` and
  `lib/letflow/design/req403-module-install-route.md` §1/§5.2 for the full
  reasoning (decided by ORCH 2026-09-24, not re-opened here). `prefix` is
  resolved only from `conn.assigns.scoped_opts` (INV-1) — no path/query/
  header value is read for tenant selection. Response body:
  `{"installed_modules": [{"module_id", "version"}, ...]}` — exactly those
  two keys per entry, no `installed_at`, no `settings`, no `id`.

  ## `:MembershipsRead` permission — CANDIDATE deliberately excluded

  Design §2.2 states this route is for "any authenticated user, no extra
  role gate." `lib/letflow/api/authorization.ex` implements the same
  deliberate, flagged deviation `:HelpRead` (REQ-366) already established:
  granted to `PLATFORM_ADMIN`, `PROCESS_DESIGNER`, `PROCESS_OPERATOR`,
  `TASK_WORKER`, `AGENT_RUNNER`, `TENANT_ADMIN`, `TENANT_AUDITOR`, but **not** `CANDIDATE` — widening
  `CANDIDATE`'s ISS-0646 closed permission set is a call for
  SECURITY-REVIEWER/REVIEWER, not something silently decided here. See that
  module's moduledoc "MembershipsRead" section.

  ## Response shape (design §2.2 points 4-5)

  `{"memberships": [{"tenant_id", "tenant_slug", "tenant_display_name",
  "display_label"}, ...]}` — **always includes the caller's own current
  tenant as one entry**, prepended by this handler and never itself stored
  as a `tenant_memberships` row (a user is always a "member" of the tenant
  whose JWT authenticated this request). If an admin-granted
  `tenant_memberships` row for the caller's own home tenant also exists
  (not expected, not prevented at the DB layer either), it is de-duplicated
  here rather than rendering the home tenant twice.

  Field selection is server-side only (INV-2) — `tenant_id`/`tenant_slug`/
  `tenant_display_name`/`display_label` only, never `idp_realm_id` or any
  OIDC config. The realm/authority a client needs to silently authenticate
  against a target tenant is resolved through the existing, separate
  `GET /api/tenant-config?slug=` bootstrap route (design §2.2 point 5) —
  not this one.
  """

  use Letflow.Api.AuthorizedRouter

  require Logger

  alias Letflow.Api.Response
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantMembership
  alias Letflow.Identity.User
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule

  authz_get "/memberships", :MembershipsRead do
    handle_list_memberships(conn)
  end

  authz_get "/modules", :MyModulesRead do
    handle_list_modules(conn)
  end

  authz_unmatched(:ordinary)

  # ── GET /me/memberships (design §2.2) ───────────────────────────────────

  defp handle_list_memberships(conn) do
    %{user_id: user_id, tenant_id: home_tenant_id} = conn.assigns.auth_context
    prefix = Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

    case resolve_caller(user_id, home_tenant_id, prefix) do
      {:ok, %User{email: email}, %Tenant{} = home_tenant} ->
        # design §2.2 point 2 -- same normalization TenantMembership's own
        # write-side create_changeset/2 applies, load-bearing: a mismatch
        # would silently hide or duplicate memberships.
        subject_key = TenantMembership.normalize_subject_key(email)
        {:ok, memberships} = Identity.list_memberships_for_subject(subject_key)

        other_entries =
          memberships
          |> Enum.reject(fn %{tenant: %Tenant{id: tenant_id}} -> tenant_id == home_tenant.id end)
          |> Enum.map(&membership_json/1)

        Response.ok(conn, %{"memberships" => [home_tenant_json(home_tenant) | other_entries]})

      {:error, :not_found} ->
        Logger.warning(
          "GET /me/memberships: could not resolve the caller's own user or tenant row " <>
            "(user_id=#{user_id}, tenant_id=#{home_tenant_id})"
        )

        Response.internal_error(conn)
    end
  end

  @spec resolve_caller(String.t(), String.t(), String.t()) ::
          {:ok, User.t(), Tenant.t()} | {:error, :not_found}
  defp resolve_caller(user_id, home_tenant_id, prefix) do
    with {:ok, %User{} = user} <- Identity.get_user(user_id, prefix: prefix),
         {:ok, %Tenant{} = home_tenant} <- Identity.get_tenant(home_tenant_id) do
      {:ok, user, home_tenant}
    end
  end

  @spec home_tenant_json(Tenant.t()) :: map()
  defp home_tenant_json(%Tenant{} = tenant) do
    %{
      "tenant_id" => tenant.id,
      "tenant_slug" => tenant.slug,
      "tenant_display_name" => tenant.display_name,
      "display_label" => nil
    }
  end

  @spec membership_json(%{tenant: Tenant.t(), display_label: String.t() | nil}) :: map()
  defp membership_json(%{tenant: %Tenant{} = tenant, display_label: display_label}) do
    %{
      "tenant_id" => tenant.id,
      "tenant_slug" => tenant.slug,
      "tenant_display_name" => tenant.display_name,
      "display_label" => display_label
    }
  end

  # ── GET /me/modules (REQ-403 design §3) ─────────────────────────────────

  @spec handle_list_modules(Plug.Conn.t()) :: Plug.Conn.t()
  defp handle_list_modules(conn) do
    prefix = Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

    installed_modules =
      Installs.list_installed(prefix: prefix)
      |> Enum.map(&installed_module_json/1)

    Response.ok(conn, %{"installed_modules" => installed_modules})
  end

  @spec installed_module_json(TenantModule.t()) :: map()
  defp installed_module_json(%TenantModule{} = tenant_module) do
    %{"module_id" => tenant_module.module_id, "version" => tenant_module.version}
  end
end
