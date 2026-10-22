#!/usr/bin/env bash
# seed_meridian_definition.sh
#
# Deploys the two Meridian ProcessDefinitions to a live Letflow QA instance:
#   1. "Loan Origination" v1.16       (proc-meridian-loan-origination)
#   2. "Regulatory Compliance Review" v1.10 (proc-meridian-regulatory-compliance-review)
# Version-aware idempotency per unit (versions compared numerically by
# `sort -V`, see scripts/lib/seed_service_task_base.sh):
#   none ACTIVE                -> create the fixture version and activate it
#   ACTIVE == fixture version  -> skip (no-op)
#   ACTIVE older than fixture  -> create + activate the fixture version; the
#                                 platform deprecates the prior ACTIVE one
#   ACTIVE newer than fixture  -> warn, do not downgrade, skip (exit 0)
# A 409 on create means (name, fixture version) already exists as DRAFT /
# DEPRECATED / ARCHIVED: bump the fixture "version"; never delete.
# A failure in one unit still exits the whole script (set -euo pipefail).
#
# Prerequisites:
#   - curl and jq installed
#   - QA_AUTH_TOKEN: Bearer token for a PROCESS_DESIGNER user in the meridian tenant
#       (TENANT_ADMIN also works). Least role per call (REQ-454; derived from
#       Letflow.Api.Authorization): GET /api/v1/definitions (DefinitionsRead), POST
#       /api/v1/definitions and POST /api/v1/definitions/:id/activate (DefinitionsWrite),
#       all PROCESS_DESIGNER. The start-up check requires DefinitionsRead and DefinitionsWrite
#       and exits 1 naming a missing one before anything is written. Provisioned via
#       `qa-uat-env.sh token meridian-admin-user` (ai-dala-infra, sibling repo).
#   - SERVICE_TASK_MOCK_BASE_URL: optional https:// base that every SERVICE_TASK
#       endpoint in the seeded fixtures is pointed at (default:
#       https://httpbin.org/anything). Engine service tasks need an absolute,
#       public https URL returning 2xx JSON (ISS-0930). http:// is refused.
#   - QA_URL: base URL of the QA instance (default: https://qa.bizdala.com)
#
# Usage:
#   export QA_AUTH_TOKEN="<bearer-token>"
#   bash scripts/seed_meridian_definition.sh
#
#   # Or override defaults:
#   QA_URL=https://qa.bizdala.com QA_AUTH_TOKEN="<token>" bash scripts/seed_meridian_definition.sh
#
# Design source: lib/letflow/design/iss0897-meridian-vortex-definition-seeding.md
# Payload sources of truth:
#   test/fixtures/simulation/meridian/process_claim_intake.yaml   (-> Loan Origination)
#   test/fixtures/simulation/meridian/process_policy_binding.yaml (-> Regulatory Compliance Review)
# Issue: ISS-0897

set -euo pipefail

QA_URL="${QA_URL:-https://qa.bizdala.com}"
API="${QA_URL}/api/v1"

if [[ -z "${QA_AUTH_TOKEN:-}" ]]; then
  echo "ERROR: QA_AUTH_TOKEN is not set." >&2
  echo "       Set it to a Bearer token for a user with DefinitionsWrite in the meridian tenant." >&2
  exit 1
fi

AUTH_HEADER="Authorization: Bearer ${QA_AUTH_TOKEN}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/seed_service_task_base.sh
source "${SCRIPT_DIR}/lib/seed_service_task_base.sh"
# shellcheck source=lib/seed_token_check.sh
source "${SCRIPT_DIR}/lib/seed_token_check.sh"

echo "=== seed_meridian_definition.sh ==="
echo "QA_URL: ${QA_URL}"
echo "Service-task mock base: ${SERVICE_TASK_EFFECTIVE_BASE_URL}"

# Least role: PROCESS_DESIGNER. Checked before any call, so a short token changes nothing.
seed_require_permissions PROCESS_DESIGNER DefinitionsRead DefinitionsWrite

seed_definition() {
  local display_name="$1"
  local encoded_name="$2"
  local fixture_path="$3"
  shift 3
  local aliases=("$@")

  echo ""
  echo "--- ${display_name}: checking for existing active definition ---"
  local existing
  existing=$(curl -sf \
    -H "${AUTH_HEADER}" \
    "${API}/definitions?name=${encoded_name}&status=active") || {
    echo "ERROR: GET /api/v1/definitions failed (HTTP error) for '${display_name}'." >&2
    exit 1
  }

  local existing_id existing_version fixture_version
  existing_id=$(echo "${existing}" | jq -r '.items[0].id // empty')
  existing_version=$(echo "${existing}" | jq -r '.items[0].version // empty')
  fixture_version=$(jq -r '.version' "${SCRIPT_DIR}/../${fixture_path}")

  if [[ -n "${existing_id}" ]]; then
    local skip=1
    if [[ "${existing_version}" == "${fixture_version}" ]]; then
      echo "Definition already exists and is ACTIVE at v${fixture_version} — skipping creation."
    elif version_is_older "${existing_version}" "${fixture_version}"; then
      echo "Replacing ACTIVE v${existing_version} (id ${existing_id}) with v${fixture_version}; the platform will deprecate v${existing_version}."
      skip=0
    else
      echo "WARNING: ACTIVE v${existing_version} is newer than fixture v${fixture_version}; not downgrading. Bump the fixture version above v${existing_version} to re-seed." >&2
    fi
    if [[ "${skip}" -eq 1 ]]; then
      echo "  Definition ID : ${existing_id}"
      echo "  Name          : $(echo "${existing}" | jq -r '.items[0].name')"
      echo "  Version       : ${existing_version}"
      echo "  Status        : $(echo "${existing}" | jq -r '.items[0].status')"
      echo ""
      echo "Browse at: ${QA_URL}/api/v1/definitions/${existing_id}"
      for alias in "${aliases[@]}"; do
        echo "  Scenario process_id : ${alias} (see test/fixtures/uat/process-definition-aliases/${alias}.yaml)"
      done
      return 0
    fi
  fi

  echo "--- ${display_name}: creating definition v${fixture_version} (DRAFT) ---"
  local payload
  payload=$(rewrite_service_task_base "$(cat "${SCRIPT_DIR}/../${fixture_path}")")

  local create_response
  create_response=$(printf '%s' "${payload}" | curl -sf \
    -X POST \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    --data-binary @- \
    "${API}/definitions") || {
    echo "ERROR: POST /api/v1/definitions failed for '${display_name}'." >&2
    echo "       A 409 means '${display_name}' v${fixture_version} already exists as DRAFT, DEPRECATED or ARCHIVED; bump the fixture \"version\" (do not delete)." >&2
    exit 1
  }

  local definition_id
  definition_id=$(echo "${create_response}" | jq -r '.id')
  if [[ -z "${definition_id}" || "${definition_id}" == "null" ]]; then
    echo "ERROR: POST /api/v1/definitions returned no id for '${display_name}'." >&2
    echo "Response: ${create_response}" >&2
    exit 1
  fi

  echo "  Created (DRAFT) — ID: ${definition_id}"
  echo "  Status: $(echo "${create_response}" | jq -r '.status')"

  echo "--- ${display_name}: activating definition ---"
  local activate_response
  activate_response=$(curl -sf \
    -X POST \
    -H "${AUTH_HEADER}" \
    "${API}/definitions/${definition_id}/activate") || {
    echo "ERROR: POST /api/v1/definitions/${definition_id}/activate failed for '${display_name}'." >&2
    exit 1
  }

  echo "  Activated — Status: $(echo "${activate_response}" | jq -r '.status')"
  echo ""
  echo "=== ${display_name}: deployment complete ==="
  echo "  Definition ID   : ${definition_id}"
  echo "  Name            : $(echo "${activate_response}" | jq -r '.name')"
  echo "  Version         : $(echo "${activate_response}" | jq -r '.version')"
  echo "  Status          : $(echo "${activate_response}" | jq -r '.status')"
  echo "  Browse at       : ${QA_URL}/api/v1/definitions/${definition_id}"
  for alias in "${aliases[@]}"; do
    echo "  Scenario process_id : ${alias} (see test/fixtures/uat/process-definition-aliases/${alias}.yaml)"
  done
}

seed_definition \
  "Loan Origination" \
  "Loan+Origination" \
  "test/fixtures/qa/meridian_loan_origination_process_definition.json" \
  "proc-meridian-loan-origination"

seed_definition \
  "Regulatory Compliance Review" \
  "Regulatory+Compliance+Review" \
  "test/fixtures/qa/meridian_regulatory_compliance_review_process_definition.json" \
  "proc-meridian-regulatory-compliance-review"

echo ""
echo "=== seed_meridian_definition.sh complete ==="
