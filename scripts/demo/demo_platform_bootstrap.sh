#!/usr/bin/env bash
# demo_platform_bootstrap.sh -- the platform tenant and PLATFORM_ADMIN of a brand-new database (T-1473, O3).
#
# A fresh database has no platform tenant, and every route that creates tenants needs a PLATFORM_ADMIN of an
# existing one, so the first one is made on the release itself. Order (each step can be repeated):
#   1. create   makes tenant `platform` (realm demo-platform), provisions its schema, prints PLATFORM_TENANT_ID=<uuid>
#   2. (infra)  put that uuid in the backend environment as LETFLOW_PLATFORM_TENANT_ID and restart the backend:
#               the variable is read once at boot (Letflow.PlatformTenant)
#   3. finish   creates the PLATFORM_ADMIN role group (Release.backfill_platform_roles) and checks it
#               (Release.check_platform_role_groups); needs the restarted release
#   4. verify   signs in as the platform user and checks /api/v1/me/access says platform_tenant and PLATFORM_ADMIN
#               (runs scripts/demo_smoke_read.sh; needs SMOKE_PASSWORD_FILE, SMOKE_USER=demo-platform-admin)
# `--print-elixir` prints the expression `create` runs, for an operator without this script.
#
# Environment:
#   RELEASE_CMD  how to reach the release, default `bin/letflow`; for a container for example
#                `docker exec -i <container> bin/letflow`. `create` uses `rpc` (release running), `finish` uses `eval`.
#   For verify: SMOKE_PASSWORD_FILE, BASE_URL, KEYCLOAK_URL (see demo_smoke_read.sh); SMOKE_REALM defaults to
#   demo-platform, SMOKE_CLIENT_ID to letflow-demo-smoke, SMOKE_USER to demo-platform-admin here.
# Output: the release's own lines. No secret is read or printed. Exit codes: 0 done, 1 a step failed, 2 bad input.
set -euo pipefail
set +x

ELIXIR_CREATE='slug = "platform"
tenant =
  case Letflow.Identity.get_tenant_by_slug(slug) do
    {:ok, tenant} ->
      tenant

    {:error, :not_found} ->
      {:ok, tenant} =
        Letflow.Identity.create_tenant(%{
          "slug" => slug,
          "display_name" => "Letflow demo platform",
          "status" => "migrating",
          "tenant_type" => "production",
          "idp_realm_id" => "demo-platform"
        })

      tenant
  end

{:ok, _registration} = Letflow.TenantOnboarding.provision_and_migrate(tenant.id)
IO.puts("PLATFORM_TENANT_ID=" <> tenant.id)'

usage() { printf 'usage: demo_platform_bootstrap.sh create | finish | verify | --print-elixir\n' >&2; exit 2; }
[ "$#" -eq 1 ] || usage

RELEASE_CMD="${RELEASE_CMD:-bin/letflow}"

case "$1" in
  --print-elixir)
    printf '%s\n' "$ELIXIR_CREATE"
    ;;
  create)
    # RELEASE_CMD is a command line chosen by the operator.
    eval "$RELEASE_CMD rpc \"\$ELIXIR_CREATE\"" || { echo "create: failed (is the release running?)" >&2; exit 1; }
    echo "next: set LETFLOW_PLATFORM_TENANT_ID to the uuid above, restart the backend, then run: finish" >&2
    ;;
  finish)
    eval "$RELEASE_CMD eval 'Letflow.Release.backfill_platform_roles()'" || { echo "finish: backfill failed" >&2; exit 1; }
    eval "$RELEASE_CMD eval 'Letflow.Release.check_platform_role_groups()'" || { echo "finish: role group check failed" >&2; exit 1; }
    ;;
  verify)
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    SMOKE_REALM="${SMOKE_REALM:-demo-platform}" \
    SMOKE_USER="${SMOKE_USER:-demo-platform-admin}" \
    SMOKE_TENANT_SLUG="${SMOKE_TENANT_SLUG:-platform}" \
    SMOKE_READ_PATH=/api/v1/me/access \
    EXPECT_JQ='.platform_tenant == true and ((.roles | index("PLATFORM_ADMIN")) != null)' \
      bash "$here/../demo_smoke_read.sh"
    ;;
  *)
    usage
    ;;
esac
