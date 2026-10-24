#!/usr/bin/env bash
# seed_meridian_entities.sh
#
# Seeds the Meridian tenant's entity subsystem for the refusal scenario
# `meridian-loan-origination-refusal-wrong-person`
# (test/fixtures/uat/scenarios/meridian/refusal-loan-approval-and-disbursement.yaml, step 8,
# GH #3077): before this seed the meridian tenant had no entity definitions, so the risk
# manager's refused export of borrower records had no data behind it. In order:
#   1. Creates + activates the `borrower` entity type
#        (test/fixtures/qa/meridian_borrower_entity_definition.json).
#   2. Restricts the personal-data fields national_id, date_of_birth and contact_email via
#      `POST /entities/restrictions/import`, and grants all three to the SEEDING account only
#      (the record import runs as that account; no persona holds a grant, so a persona's
#      unredacted export is refused and a default export shows the fields masked).
#   3. Imports the sample borrowers via `POST /entities/records/borrower/import`
#        (test/fixtures/qa/meridian_borrower_records.json, 3 rows; borrower-corp-002 is the
#        applicant of the refusal scenario's loan).
#
# IDEMPOTENCY: same posture as scripts/seed_vortex_entities.sh. A definition that exists by
# name is skipped (an inactive draft is activated); the restrictions route is idempotent
# server-side; records already present by borrower_ref (POST /entities/query) are not imported
# again.
#
# Prerequisites:
#   - curl and jq installed
#   - QA_AUTH_TOKEN: Bearer token for a TENANT_ADMIN user in the meridian tenant.
#       Least role per call (derived from Letflow.Api.Authorization):
#         GET  /api/v1/entities/definitions/by-name/:name   EntitiesDefinitionsRead
#         POST /api/v1/entities/definitions                 EntitiesDefinitionsWrite -> TENANT_ADMIN
#         POST /api/v1/entities/definitions/:name/activate  EntitiesDefinitionsWrite -> TENANT_ADMIN
#         POST /api/v1/entities/restrictions/import         EntitiesRestrictionsManage -> TENANT_ADMIN
#         POST /api/v1/entities/records/borrower/import     EntitiesRecordsImport    -> TENANT_ADMIN
#         GET  /api/v1/identity/users                       UsersManage              -> TENANT_ADMIN
#       The start-up check exits 1 naming a missing permission before anything is written.
#   - SEED_ACTOR_USERNAME (REQUIRED): the username of the account QA_AUTH_TOKEN belongs to. It
#       MUST be a DEDICATED non-persona account (never an actor-meridian-* persona): it is
#       granted the restricted fields, which would defeat the refusal scenario for a persona.
#   - QA_URL: base URL of the QA instance (default: https://qa.bizdala.com)
#   - Run AFTER scripts/seed_meridian_persona_actors.sh (which calls this script itself when
#     SEED_ACTOR_USERNAME is set).
#
# Usage:
#   QA_AUTH_TOKEN="<token>" SEED_ACTOR_USERNAME="<token owner>" bash scripts/seed_meridian_entities.sh

set -euo pipefail

QA_URL="${QA_URL:-https://qa.bizdala.com}"
API="${QA_URL}/api/v1"

if [[ -z "${QA_AUTH_TOKEN:-}" ]]; then
  echo "ERROR: QA_AUTH_TOKEN is not set." >&2
  echo "       Set it to a Bearer token for a TENANT_ADMIN user in the meridian tenant." >&2
  exit 1
fi

if [[ -z "${SEED_ACTOR_USERNAME:-}" ]]; then
  echo "ERROR: SEED_ACTOR_USERNAME is not set." >&2
  echo "       Set it to the username of the DEDICATED (non-persona) account QA_AUTH_TOKEN belongs to;" >&2
  echo "       the record import applies field restrictions to that account." >&2
  exit 1
fi

if [[ "${SEED_ACTOR_USERNAME}" == actor-meridian-* ]]; then
  echo "ERROR: SEED_ACTOR_USERNAME must be a DEDICATED account, not a persona (${SEED_ACTOR_USERNAME})." >&2
  exit 1
fi

AUTH_HEADER="Authorization: Bearer ${QA_AUTH_TOKEN}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
# shellcheck source=lib/seed_token_check.sh
source "${SCRIPT_DIR}/lib/seed_token_check.sh"

ENTITY_TYPE="borrower"
DEFINITION_FIXTURE="${REPO_ROOT}/test/fixtures/qa/meridian_borrower_entity_definition.json"
RECORDS_FIXTURE="${REPO_ROOT}/test/fixtures/qa/meridian_borrower_records.json"

echo "=== seed_meridian_entities.sh ==="
echo "QA_URL: ${QA_URL}"

seed_require_permissions TENANT_ADMIN EntitiesDefinitionsWrite EntitiesRecordsImport \
  EntitiesRestrictionsManage UsersGroupsRolesManage

# ---------------------------------------------------------------------------
# Step 1: the borrower entity type (exists by name -> skip, never update).
# ---------------------------------------------------------------------------

activate_definition() {
  local name="$1"
  local body_file http_code
  body_file=$(mktemp)
  http_code=$(jq -n --arg n "${name}" \
    '{rationale: ("UAT seed: activate " + $n + " entity definition (seed_meridian_entities.sh)")}' |
    curl -s -o "${body_file}" -w '%{http_code}' \
      -X POST \
      -H "${AUTH_HEADER}" \
      -H "Content-Type: application/json" \
      --data-binary @- \
      "${API}/entities/definitions/${name}/activate") || {
    echo "ERROR: POST /api/v1/entities/definitions/${name}/activate failed (network error)." >&2
    rm -f "${body_file}"
    exit 1
  }
  if [[ "${http_code}" != "200" && "${http_code}" != "201" ]]; then
    echo "ERROR: POST /api/v1/entities/definitions/${name}/activate returned HTTP ${http_code}." >&2
    cat "${body_file}" >&2
    rm -f "${body_file}"
    exit 1
  fi
  echo "  Activated -- status: $(jq -r '.status // "ok"' "${body_file}")"
  rm -f "${body_file}"
}

echo ""
echo "--- entity type '${ENTITY_TYPE}': checking for an existing definition ---"
def_check_file=$(mktemp)
status=$(curl -s -o "${def_check_file}" -w '%{http_code}' \
  -H "${AUTH_HEADER}" \
  "${API}/entities/definitions/by-name/${ENTITY_TYPE}") || {
  echo "ERROR: GET /api/v1/entities/definitions/by-name/${ENTITY_TYPE} failed (network error)." >&2
  rm -f "${def_check_file}"
  exit 1
}

if [[ "${status}" == "200" ]]; then
  existing_status=$(jq -r '.status // empty' "${def_check_file}")
  echo "  Already exists (status: ${existing_status:-unknown}) -- skipping creation."
  rm -f "${def_check_file}"
  if [[ "${existing_status}" == "inactive" ]]; then
    echo "--- entity type '${ENTITY_TYPE}': inactive draft found -- activating ---"
    activate_definition "${ENTITY_TYPE}"
  fi
elif [[ "${status}" == "404" ]]; then
  rm -f "${def_check_file}"
  echo "--- entity type '${ENTITY_TYPE}': creating (DRAFT) ---"
  create_response=$(jq -c . "${DEFINITION_FIXTURE}" | curl -sf \
    -X POST \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    --data-binary @- \
    "${API}/entities/definitions") || {
    echo "ERROR: POST /api/v1/entities/definitions failed for '${ENTITY_TYPE}'." >&2
    echo "       A 409 means it already exists in a non-active state; no automatic recovery." >&2
    exit 1
  }
  definition_id=$(echo "${create_response}" | jq -r '.id // empty')
  if [[ -z "${definition_id}" ]]; then
    echo "ERROR: POST /api/v1/entities/definitions returned no id for '${ENTITY_TYPE}'." >&2
    echo "Response: ${create_response}" >&2
    exit 1
  fi
  echo "  Created (DRAFT) -- ID: ${definition_id}"
  echo "--- entity type '${ENTITY_TYPE}': activating ---"
  activate_definition "${ENTITY_TYPE}"
else
  echo "ERROR: GET /api/v1/entities/definitions/by-name/${ENTITY_TYPE} returned unexpected HTTP ${status}." >&2
  cat "${def_check_file}" >&2
  rm -f "${def_check_file}"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: restrict the personal-data fields; grant them to the seeding account only.
# ---------------------------------------------------------------------------

echo ""
echo "--- Resolving the seeding account's user id ---"
users_response=$(curl -sf \
  -H "${AUTH_HEADER}" \
  "${API}/identity/users?search=${SEED_ACTOR_USERNAME}") || {
  echo "ERROR: GET /api/v1/identity/users?search=${SEED_ACTOR_USERNAME} failed (HTTP error)." >&2
  exit 1
}
# The search is fuzzy: take the item whose username matches EXACTLY, never items[0].
SEED_ID=$(echo "${users_response}" | jq -r --arg u "${SEED_ACTOR_USERNAME}" \
  '[.items[]? | select(.username == $u)][0].id // empty')
if [[ -z "${SEED_ID}" ]]; then
  echo "ERROR: user ${SEED_ACTOR_USERNAME} not found (exact username match) in the meridian tenant." >&2
  exit 1
fi
echo "  ${SEED_ACTOR_USERNAME} (seeding account): ${SEED_ID}"

echo ""
echo "--- Seeding restriction/grant rows via POST /entities/restrictions/import ---"
restrictions_response=$(jq -n --arg seed "${SEED_ID}" --arg et "${ENTITY_TYPE}" '
  ["national_id", "date_of_birth", "contact_email"] as $fields
  | {
      field_restrictions: [$fields[] | {entity_type: $et, field_name: .}],
      field_grants: [$fields[] | {user_id: $seed, entity_type: $et, field_name: .}]
    }' | curl -sf \
  -X POST \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  --data-binary @- \
  "${API}/entities/restrictions/import") || {
  echo "ERROR: POST /api/v1/entities/restrictions/import failed." >&2
  echo "       Confirm QA_AUTH_TOKEN's user holds EntitiesRestrictionsManage." >&2
  exit 1
}
echo "  Inserted counts: $(echo "${restrictions_response}" | jq -c '.inserted')"
echo "  (all-zero on a re-run is expected and correct -- the route is idempotent)"

# ---------------------------------------------------------------------------
# Step 3: sample records, skipping those already present by borrower_ref.
# ---------------------------------------------------------------------------

echo ""
echo "--- ${ENTITY_TYPE}: checking which sample records already exist ---"
existing_keys="[]"
cursor="null"
while :; do
  if [[ "${cursor}" == "null" ]]; then
    query_body=$(jq -n --arg et "${ENTITY_TYPE}" '{entity_type: $et, page_size: 200}')
  else
    query_body=$(jq -n --arg et "${ENTITY_TYPE}" --argjson cursor "${cursor}" \
      '{entity_type: $et, page_size: 200, cursor: $cursor}')
  fi
  resp=$(printf '%s' "${query_body}" | curl -sf \
    -X POST \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    --data-binary @- \
    "${API}/entities/query") || {
    echo "ERROR: POST /api/v1/entities/query failed while checking existing ${ENTITY_TYPE} records." >&2
    exit 1
  }
  # GH #3078: stdin, not --argjson (a large page overflows the OS argument-size limit).
  existing_keys=$({ printf '%s\n' "${existing_keys}"; printf '%s\n' "${resp}"; } |
    jq -c -s '.[0] + [.[1].items[].field_values.borrower_ref]')
  cursor=$(echo "${resp}" | jq -c '.next_cursor')
  if [[ "${cursor}" == "null" ]]; then
    break
  fi
done

remaining_payload=$({ printf '%s\n' "${existing_keys}"; cat "${RECORDS_FIXTURE}"; } |
  jq -s '.[0] as $existing | .[1] | .records |= map(select((.field_values.borrower_ref as $k | $existing | index($k)) == null))')
total=$(jq '.records | length' "${RECORDS_FIXTURE}")
remaining=$(echo "${remaining_payload}" | jq '.records | length')
echo "  ${remaining} of ${total} ${ENTITY_TYPE} record(s) are new."

if [[ "${remaining}" -eq 0 ]]; then
  echo "  Already fully seeded -- skipping import."
else
  import_response=$(printf '%s' "${remaining_payload}" | curl -sf \
    -X POST \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    --data-binary @- \
    "${API}/entities/records/${ENTITY_TYPE}/import") || {
    echo "ERROR: POST /api/v1/entities/records/${ENTITY_TYPE}/import failed." >&2
    exit 1
  }
  # The route answers 200 with a per-entry report; a refused entry is a status "error" entry.
  failed_entries=$(echo "${import_response}" | jq '[.results[]? | select(.status == "error")] | length')
  if [[ "${failed_entries}" != "0" ]]; then
    echo "ERROR: ${failed_entries} ${ENTITY_TYPE} entry(ies) were refused:" >&2
    echo "${import_response}" | jq -c '[.results[] | select(.status == "error") | .reason]' >&2
    exit 1
  fi
  echo "  Imported ${remaining} new ${ENTITY_TYPE} record(s)."
fi

echo ""
echo "=== seed_meridian_entities.sh complete ==="
echo "  ${ENTITY_TYPE}: ${total} sample record(s) in fixture"
