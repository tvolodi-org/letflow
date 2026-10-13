defmodule Letflow.Plugs.TenantStatus do
  @moduledoc """
  Tenant status gate — two independent, linearly-composed checks over the
  same tenant lookup.

  PROVENANCE (historical, not current decision authority):
  1. **Deactivation check (REQ-075, all methods).** A request against a
     tenant whose `status` is `:inactive`, from a caller whose roles
     (`conn.assigns.auth_context.roles`) do not include `"PLATFORM_ADMIN"`,
     is rejected with `403` and body `{"error": "tenant_inactive", "detail":
     "tenant is deactivated"}` (no `Retry-After` header — that header is
     specific to check 2 below). Runs for **every** HTTP method, including
     `GET`/`HEAD`, matching R-Co's `enforceTenantActiveForOperation`/
     `isTenantInactive` (`src/identity/service.zig:133-151`,
     `src/api/middleware/auth.zig:1663-1674`). ISS-0993 (A2): the exemption now applies ONLY
     to a `PLATFORM_ADMIN` of the platform tenant (`Letflow.PlatformTenant`); a
     `PLATFORM_ADMIN` of the inactive tenant itself is halted. `TENANT_ADMIN` (REQ-447) and `TENANT_AUDITOR` (REQ-448)
     have no exemption from this gate: they are halted in an inactive tenant, including the
     platform tenant's own `TENANT_ADMIN` for the platform tenant.
     Authorized exactly in this shape by REVIEWER — see
     `docs/migration/stage-4-api-surface.md`'s 2026-08-22 (REQ-075) sign-off
     entry; do not narrow to write-only or widen the exemption without a
     fresh sign-off.

  PROVENANCE (historical, not current decision authority):
  2. **Write-pause check (REQ-021, ports `src/api/middleware/tenant_status.zig`'s
     `checkTenantWritePause/4`), unchanged.** A write request
     (`POST`/`PUT`/`PATCH`/`DELETE`) against a tenant whose `status` is
     `:migrating` is rejected with `503` and a `Retry-After` header.
     `GET`/`HEAD` (and any other non-write method) pass through this second
     check unchanged. No PLATFORM_ADMIN exemption on this check: an
     in-progress migration is a data-integrity window, not an authorization
     decision, so no role overrides it (unlike check 1's deactivation gate
     above, which is a policy/authorization decision PLATFORM_ADMIN can
     legitimately override).

  Both checks reuse the **same** `Repo.get(Tenant, tenant_id)` lookup — one
  query per request, not two. Call this **after** `Letflow.Plugs.AuthPipeline`
  has resolved `conn.assigns[:auth_context][:tenant_id]` (and `:roles`), and
  before dispatching to any sub-router.

  PROVENANCE (historical, not current decision authority):
  **Fail-closed on a genuine DB error during the tenant-status lookup** — a
  deliberate divergence from `tenant_status.zig`'s own fail-open behavior
  (pool exhaustion / query failure both let the request through in R-Co).
  This plug instead lets a lookup failure propagate as a crash of the
  handling process (letting the existing OTP/Bandit request-handling
  isolation apply) rather than silently bypassing a data-integrity
  safeguard. See `lib/letflow/design/req021-auth-plug-pipeline.md` §6.4
  (OQ-14) — the design states this as a recommendation, not a mandate;
  REVIEWER has confirmed this holds for the REQ-075 check too (INV-8 does
  not favor a narrower/isolated alternative — see the sign-off entry above).

  **Mounted since REQ-071**, immediately after `Letflow.Plugs.AuthPipeline` in
  `Letflow.Plugs.ApiPipeline`'s plug chain, matching this module's own calling
  convention above — every `/api/v1/*` request has `conn.assigns[:auth_context]`
  populated by `AuthPipeline` before this plug runs.
  """

  @behaviour Plug

  import Plug.Conn

  alias Letflow.Identity.Tenant
  alias Letflow.PlatformTenant
  alias Letflow.Repo

  @write_methods ~w(POST PUT PATCH DELETE)
  @retry_after_seconds "30"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    tenant_id = get_in(conn.assigns, [:auth_context, :tenant_id])
    check_tenant_status(conn, tenant_id)
  end

  # No auth context resolved ahead of this plug — undefined per this design
  # (§6.3's OQ-12: TenantStatus is only ever mounted after AuthPipeline in
  # the same pipeline; this case should not occur in practice). Passing
  # through rather than crashing is the safer of two unspecified choices,
  # but this is explicitly not a defended-against case.
  defp check_tenant_status(conn, nil), do: conn

  defp check_tenant_status(conn, tenant_id) do
    case Repo.get(Tenant, tenant_id) do
      nil ->
        # Should not occur — AuthPipeline already resolved this tenant via
        # resolve_tenant_by_realm/1. A race/deletion between steps, not a
        # normal case; pass through rather than fail the request over it.
        conn

      %Tenant{} = tenant ->
        # ISS-0993 / INV-10 (A2): the deactivated-tenant exemption belongs ONLY
        # to a PLATFORM_ADMIN of the platform tenant. The facts are recomputed
        # from the resolved row id and the raw role strings through
        # PlatformTenant.scope_facts/2 (which parses roles with
        # Authorization.roles_from_strings/1, the ISS-0808 normalisation), so a
        # PLATFORM_ADMIN of the deactivated tenant itself is halted.
        raw_roles = get_in(conn.assigns, [:auth_context, :roles]) || []
        platform_scope? = PlatformTenant.scope_facts(tenant.id, raw_roles).platform_scope?

        cond do
          tenant.status == :inactive and not platform_scope? ->
            reject_inactive(conn)

          conn.method in @write_methods and tenant.status == :migrating ->
            reject_migrating(conn)

          true ->
            conn
        end
    end
  end

  defp reject_inactive(conn) do
    body =
      Jason.encode!(%{
        error: "tenant_inactive",
        detail: "tenant is deactivated"
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, body)
    |> halt()
  end

  defp reject_migrating(conn) do
    body =
      Jason.encode!(%{
        error: "tenant_migrating",
        detail: "tenant is being migrated; writes are paused"
      })

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("retry-after", @retry_after_seconds)
    |> send_resp(503, body)
    |> halt()
  end
end
