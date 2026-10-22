#!/usr/bin/env bash
# seed_swiftroute_definition.sh
#
# Deploys the SwiftRoute "Shipment Approval" v1.7 ProcessDefinition to a
# live Letflow QA instance. Version-aware idempotency (versions compared
# numerically by `sort -V`, see scripts/lib/seed_service_task_base.sh):
#   none ACTIVE               -> create the fixture version and activate it
#   ACTIVE == fixture version -> skip (no-op)
#   ACTIVE older than fixture -> create + activate the fixture version; the
#                                platform deprecates the prior ACTIVE one
#   ACTIVE newer than fixture -> warn, do not downgrade, skip (exit 0)
# A 409 on create means (name, fixture version) already exists as DRAFT /
# DEPRECATED / ARCHIVED: bump the fixture "version"; never delete.
#
# Prerequisites:
#   - curl and jq installed
#   - QA_AUTH_TOKEN: Bearer token for a PROCESS_DESIGNER user in the swiftroute tenant
#       (TENANT_ADMIN also works). Least role per call (REQ-454; derived from
#       Letflow.Api.Authorization):
#         GET /api/v1/definitions          DefinitionsRead              -> PROCESS_DESIGNER
#         POST /api/v1/definitions         DefinitionsWrite             -> PROCESS_DESIGNER
#         POST /api/v1/definitions/:id/activate  DefinitionsWrite       -> PROCESS_DESIGNER
#       The start-up check requires DefinitionsRead and DefinitionsWrite and exits 1 naming
#       a missing one before anything is written. The AC2/AC3 verification commands printed
#       below (POST /api/v1/instances) need InstancesStart, which PROCESS_DESIGNER also holds.
#   - SERVICE_TASK_MOCK_BASE_URL: optional https:// base that every SERVICE_TASK
#       endpoint in the seeded fixture is pointed at (default:
#       https://httpbin.org/anything). Engine service tasks need an absolute,
#       public https URL returning 2xx JSON (ISS-0930). http:// is refused.
#   - QA_URL: base URL of the QA instance (default: https://qa.bizdala.com)
#   - SWIFTROUTE_TENANT_ID: UUID of the swiftroute tenant (optional; not read by
#       this script: the API calls are scoped by the authenticated user's OIDC token).
#
# Usage:
#   export QA_AUTH_TOKEN="<bearer-token>"
#   bash scripts/seed_swiftroute_definition.sh
#
#   # Or override defaults:
#   QA_URL=https://qa.bizdala.com QA_AUTH_TOKEN="<token>" bash scripts/seed_swiftroute_definition.sh
#
# If the swiftroute tenant does not yet exist on QA, provision it first. This is a
# platform-scope call (POST /api/v1/tenants, :TenantsManage), run by the platform
# operator with the platform account's token, not by this script and not with a tenant token:
#   curl -sf -X POST "$QA_URL/api/v1/tenants" \
#     -H "Authorization: Bearer $PLATFORM_ACCOUNT_TOKEN" \
#     -H "Content-Type: application/json" \
#     -d '{"slug":"swiftroute","display_name":"SwiftRoute Ltd","admin_email":"admin@swiftroute.example"}'
#
# Design source: lib/letflow/design/req395-swiftroute-definition-deployment.md
# Payload source of truth: test/fixtures/simulation/swiftroute/process_route_approval.yaml
# REQ: REQ-395 (Stage S7)

set -euo pipefail

QA_URL="${QA_URL:-https://qa.bizdala.com}"
API="${QA_URL}/api/v1"

if [[ -z "${QA_AUTH_TOKEN:-}" ]]; then
  echo "ERROR: QA_AUTH_TOKEN is not set." >&2
  echo "       Set it to a Bearer token for a user with DefinitionsWrite in the swiftroute tenant." >&2
  exit 1
fi

AUTH_HEADER="Authorization: Bearer ${QA_AUTH_TOKEN}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/seed_service_task_base.sh
source "${SCRIPT_DIR}/lib/seed_service_task_base.sh"
# shellcheck source=lib/seed_token_check.sh
source "${SCRIPT_DIR}/lib/seed_token_check.sh"
FIXTURE_PATH="${SCRIPT_DIR}/../test/fixtures/qa/swiftroute_process_definition.json"

echo "=== seed_swiftroute_definition.sh ==="
echo "QA_URL: ${QA_URL}"
echo "Service-task mock base: ${SERVICE_TASK_EFFECTIVE_BASE_URL}"

# Least role: PROCESS_DESIGNER. Checked before any call, so a short token changes nothing.
seed_require_permissions PROCESS_DESIGNER DefinitionsRead DefinitionsWrite

# --- Idempotency guard ---
# Check if a definition named "Shipment Approval" with status ACTIVE already exists.
echo "--- Checking for existing active definition ---"
EXISTING=$(curl -sf \
  -H "${AUTH_HEADER}" \
  "${API}/definitions?name=Shipment+Approval&status=active") || {
  echo "ERROR: GET /api/v1/definitions failed (HTTP error)." >&2
  exit 1
}

EXISTING_ID=$(echo "${EXISTING}" | jq -r '.items[0].id // empty')
EXISTING_VERSION=$(echo "${EXISTING}" | jq -r '.items[0].version // empty')
FIXTURE_VERSION=$(jq -r '.version' "${FIXTURE_PATH}")

SKIP=0
if [[ -n "${EXISTING_ID}" ]]; then
  if [[ "${EXISTING_VERSION}" == "${FIXTURE_VERSION}" ]]; then
    echo "Definition already exists and is ACTIVE at v${FIXTURE_VERSION} — skipping creation."
    SKIP=1
  elif version_is_older "${EXISTING_VERSION}" "${FIXTURE_VERSION}"; then
    echo "Replacing ACTIVE v${EXISTING_VERSION} (id ${EXISTING_ID}) with v${FIXTURE_VERSION}; the platform will deprecate v${EXISTING_VERSION}."
  else
    echo "WARNING: ACTIVE v${EXISTING_VERSION} is newer than fixture v${FIXTURE_VERSION}; not downgrading. Bump the fixture version above v${EXISTING_VERSION} to re-seed." >&2
    SKIP=1
  fi
fi

if [[ "${SKIP}" -eq 1 ]]; then
  echo "  Definition ID : ${EXISTING_ID}"
  echo "  Name          : $(echo "${EXISTING}" | jq -r '.items[0].name')"
  echo "  Version       : $(echo "${EXISTING}" | jq -r '.items[0].version')"
  echo "  Status        : $(echo "${EXISTING}" | jq -r '.items[0].status')"
  echo ""
  echo "Browse at: ${QA_URL}/api/v1/definitions/${EXISTING_ID}"
  echo "  Scenario process_id : proc-swiftroute-shipment-approval (see test/fixtures/uat/process-definition-aliases/proc-swiftroute-shipment-approval.yaml)"
  exit 0
fi

# --- Step 1: POST /api/v1/definitions (create as DRAFT) ---
echo "--- Creating definition v${FIXTURE_VERSION} (DRAFT) ---"
PAYLOAD=$(rewrite_service_task_base "$(cat "${FIXTURE_PATH}")")

CREATE_RESPONSE=$(printf '%s' "${PAYLOAD}" | curl -sf \
  -X POST \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  --data-binary @- \
  "${API}/definitions") || {
  echo "ERROR: POST /api/v1/definitions failed." >&2
  echo "       A 409 means 'Shipment Approval' v${FIXTURE_VERSION} already exists as DRAFT, DEPRECATED or ARCHIVED; bump the fixture \"version\" (do not delete)." >&2
  exit 1
}

DEFINITION_ID=$(echo "${CREATE_RESPONSE}" | jq -r '.id')
if [[ -z "${DEFINITION_ID}" || "${DEFINITION_ID}" == "null" ]]; then
  echo "ERROR: POST /api/v1/definitions returned no id." >&2
  echo "Response: ${CREATE_RESPONSE}" >&2
  exit 1
fi

echo "  Created (DRAFT) — ID: ${DEFINITION_ID}"
echo "  Status: $(echo "${CREATE_RESPONSE}" | jq -r '.status')"

# --- Step 2: POST /api/v1/definitions/{id}/activate ---
echo "--- Activating definition ---"
ACTIVATE_RESPONSE=$(curl -sf \
  -X POST \
  -H "${AUTH_HEADER}" \
  "${API}/definitions/${DEFINITION_ID}/activate") || {
  echo "ERROR: POST /api/v1/definitions/${DEFINITION_ID}/activate failed." >&2
  echo "       If you see a 422, check OQ-3 (CEL single-quote syntax) and OQ-4 (QA code version includes REQ-396)." >&2
  exit 1
}

echo "  Activated — Status: $(echo "${ACTIVATE_RESPONSE}" | jq -r '.status')"
echo ""
echo "=== Deployment complete ==="
echo "  Definition ID   : ${DEFINITION_ID}"
echo "  Name            : $(echo "${ACTIVATE_RESPONSE}" | jq -r '.name')"
echo "  Version         : $(echo "${ACTIVATE_RESPONSE}" | jq -r '.version')"
echo "  Status          : $(echo "${ACTIVATE_RESPONSE}" | jq -r '.status')"
echo "  Browse at       : ${QA_URL}/api/v1/definitions/${DEFINITION_ID}"
echo "  Scenario process_id : proc-swiftroute-shipment-approval (see test/fixtures/uat/process-definition-aliases/proc-swiftroute-shipment-approval.yaml)"
echo ""
echo "--- AC1 verification ---"
echo "Run: curl -sf -H \"Authorization: Bearer \$QA_AUTH_TOKEN\" \"${API}/definitions?name=Shipment+Approval&status=active\" | jq ."
echo ""
echo "--- AC2 verification (declared_value: 750) ---"
echo "Run: curl -sf -X POST -H \"Authorization: Bearer \$QA_AUTH_TOKEN\" -H \"Content-Type: application/json\" \\"
echo "  -d '{\"definition_id\":\"${DEFINITION_ID}\",\"initial_variables\":{\"declared_value\":750}}' \\"
echo "  \"${API}/instances\" | jq ."
echo ""
echo "--- AC3 verification (declared_value: 400) ---"
echo "Run: curl -sf -X POST -H \"Authorization: Bearer \$QA_AUTH_TOKEN\" -H \"Content-Type: application/json\" \\"
echo "  -d '{\"definition_id\":\"${DEFINITION_ID}\",\"initial_variables\":{\"declared_value\":400}}' \\"
echo "  \"${API}/instances\" | jq ."
