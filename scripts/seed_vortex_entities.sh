#!/usr/bin/env bash
# seed_vortex_entities.sh
#
# Seeds the Vortex tenant's entity subsystem for the
# `vortex/entity-list-filter-and-page` UAT scenario
# (test/fixtures/uat/scenarios/vortex/entity-list-filter-and-page.yaml),
# closing ISS-0935 / GH-2069's D6 precondition gap. In order:
#   1. Creates + activates the two entity-type definitions:
#        production_batch     (test/fixtures/qa/vortex_production_batch_entity_definition.json)
#        shipment_manifest    (test/fixtures/qa/vortex_shipment_manifest_entity_definition.json)
#   2. Seeds the field-/type-level restriction rows via the new
#      `POST /entities/restrictions/import` route:
#        - entity_field_restrictions: production_batch.cost_figure restricted
#        - user_entity_grants: actor-vortex-anna (cost_approver) restored
#        - entity_type_restrictions: shipment_manifest restricted tenant-wide
#        - (no user_entity_type_grants row for actor-vortex-karl -- his
#          denial is the absence of that row, design §2.2)
#        - GH #2784: the SEEDING account (SEED_ACTOR_USERNAME) is granted both
#          production_batch.cost_figure and shipment_manifest, because the record
#          write routes now apply type access and field restrictions to the caller
#          (without the grants step 3 would 404 for shipment_manifest and silently
#          refuse every production_batch row naming cost_figure)
#   3. Imports the sample record sets via the existing bulk-import route
#      (`POST /entities/records/:entity_type/import`):
#        production_batch     (test/fixtures/qa/vortex_production_batch_records.json, 83 rows)
#        shipment_manifest    (test/fixtures/qa/vortex_shipment_manifest_records.json, 10 rows)
#
# Design source: lib/letflow/design/iss0935-vortex-entity-seed.md
# Issue: ISS-0935 (GH-2069)
#
# IDEMPOTENCY
#   Definitions (§4.1): a GET by name that returns 200 means "already
#   seeded" -- this script skips unconditionally, it never attempts to
#   update an existing definition in place (no such route exists -- design
#   §4.1 OQ-4). A 409 on create means the (tenant, name) pair already
#   exists in a non-active state; this script does not attempt to recover
#   from that automatically (same posture as seed_vortex_definition.sh).
#   Restrictions (§4.2): POST /entities/restrictions/import is itself
#   idempotent server-side (on_conflict: :nothing) -- a second run reports
#   all-zero inserted counts, never an error or a duplicate row.
#   Records (§3.3/§4.3): the bulk import route does NOT honor a
#   caller-supplied per-item idempotency_key (it mints its own, scoped to
#   one HTTP call, discarding any `idempotency_key` an entry carries --
#   confirmed in lib/letflow/routers/entities.ex's `import_one_entry/5`).
#   So THIS script does its own pre-check: it queries for every record
#   already present by its business key (batch_ref / manifest_ref) via
#   `POST /entities/query`, and imports only the fixture rows not already
#   present -- re-running this script against an already-seeded QA
#   instance imports zero additional rows.
#
# Prerequisites:
#   - curl and jq installed
#   - QA_AUTH_TOKEN: Bearer token for a user in the vortex tenant holding
#       ALL THREE of:
#         EntitiesDefinitionsWrite   (create + activate both definitions)
#         EntitiesRecordsImport      (bulk-import both record sets)
#         EntitiesRestrictionsManage (POST /entities/restrictions/import)
#       plus whatever identity-read permission `GET /api/v1/identity/users`
#       requires, to resolve actor-vortex-anna's and actor-vortex-karl's
#       user ids (same requirement seed_swiftroute_persona_actors.sh already
#       states for its own user lookups).
#   - SEED_ACTOR_USERNAME (REQUIRED, GH #2784): the username of the account QA_AUTH_TOKEN
#       belongs to. It MUST be a DEDICATED non-persona account (a service/seeder user),
#       never actor-vortex-anna, actor-vortex-karl or an admin persona the UAT
#       redaction/denial scenarios depend on: it is granted the restricted field and
#       type below, which would defeat those scenarios for a persona. The script refuses
#       to run when the token does not belong to this account.
#   - QA_URL: base URL of the QA instance (default: https://qa.bizdala.com)
#
# Usage:
#   export QA_AUTH_TOKEN="<bearer-token>"
#   export SEED_ACTOR_USERNAME="<the token owner's username>"
#   bash scripts/seed_vortex_entities.sh
#
#   # Or override the base URL:
#   QA_URL=https://qa.bizdala.com QA_AUTH_TOKEN="<token>" SEED_ACTOR_USERNAME="<user>" \
#     bash scripts/seed_vortex_entities.sh
#
# NOT RUN by ELIXIR-DEV against live QA (no credentials in the build
# sandbox, same documented posture as ISS-0897/ISS-0886/ISS-0892's own
# seed scripts) -- this is a documented operational follow-up for whichever
# agent/operator holds QA_AUTH_TOKEN. This script has been syntax-checked
# (`bash -n`) only.

set -euo pipefail

QA_URL="${QA_URL:-https://qa.bizdala.com}"
API="${QA_URL}/api/v1"

if [[ -z "${QA_AUTH_TOKEN:-}" ]]; then
  echo "ERROR: QA_AUTH_TOKEN is not set." >&2
  echo "       Set it to a Bearer token for a user in the vortex tenant holding" >&2
  echo "       EntitiesDefinitionsWrite + EntitiesRecordsImport + EntitiesRestrictionsManage." >&2
  exit 1
fi

if [[ -z "${SEED_ACTOR_USERNAME:-}" ]]; then
  echo "ERROR: SEED_ACTOR_USERNAME is not set." >&2
  echo "       Set it to the username of the DEDICATED (non-persona) account QA_AUTH_TOKEN belongs to;" >&2
  echo "       the record write routes apply type access and field restrictions to that account (GH #2784)." >&2
  exit 1
fi

AUTH_HEADER="Authorization: Bearer ${QA_AUTH_TOKEN}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."

echo "=== seed_vortex_entities.sh ==="
echo "QA_URL: ${QA_URL}"

# ---------------------------------------------------------------------------
# Step 1: entity-type definitions (§4.1) -- exists by name -> skip,
# never update (design §4.1 OQ-4).
# ---------------------------------------------------------------------------

# ISS-0931 (Q-931): the activate endpoint requires a non-blank `rationale`
# (422 "rationale: field is required" otherwise). Prints nothing on success;
# on failure echoes the HTTP status and body, then exits.
activate_definition() {
  local name="$1"
  local body_file http_code
  body_file=$(mktemp)
  http_code=$(curl -s -o "${body_file}" -w '%{http_code}' \
    -X POST \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    -d "{\"rationale\":\"UAT seed: activate ${name} entity definition (seed_vortex_entities.sh)\"}" \
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

seed_entity_definition() {
  local name="$1"
  local fixture_path="$2"
  # GH #2784 follow-up: a per-call temp file (was a fixed /tmp path shared by concurrent runs/tests).
  local def_check_file
  def_check_file=$(mktemp)

  echo ""
  echo "--- entity type '${name}': checking for an existing definition ---"

  local status
  status=$(curl -s -o "${def_check_file}" -w '%{http_code}' \
    -H "${AUTH_HEADER}" \
    "${API}/entities/definitions/by-name/${name}") || {
    echo "ERROR: GET /api/v1/entities/definitions/by-name/${name} failed (network error)." >&2
    exit 1
  }

  if [[ "${status}" == "200" ]]; then
    echo "  Already exists -- skipping creation (this script never updates an existing definition in place)."
    local existing_id existing_status
    existing_id=$(jq -r '.id' "${def_check_file}")
    existing_status=$(jq -r '.status // empty' "${def_check_file}")
    echo "  Definition ID: ${existing_id} (status: ${existing_status:-unknown})"
    rm -f "${def_check_file}"
    # ISS-0931: resume a draft left inactive by an earlier aborted run.
    if [[ "${existing_status}" == "inactive" ]]; then
      echo "--- entity type '${name}': inactive draft found -- activating ---"
      activate_definition "${name}"
    fi
    return 0
  fi

  if [[ "${status}" != "404" ]]; then
    echo "ERROR: GET /api/v1/entities/definitions/by-name/${name} returned unexpected HTTP ${status}." >&2
    cat "${def_check_file}" >&2
    rm -f "${def_check_file}"
    exit 1
  fi

  rm -f "${def_check_file}"
  echo "--- entity type '${name}': creating (DRAFT) ---"
  local create_response
  create_response=$(curl -sf \
    -X POST \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    -d "@${REPO_ROOT}/${fixture_path}" \
    "${API}/entities/definitions") || {
    echo "ERROR: POST /api/v1/entities/definitions failed for '${name}'." >&2
    echo "       A 409 means '${name}' already exists in a non-active state -- this script" >&2
    echo "       does not attempt automatic recovery (design §4.1)." >&2
    exit 1
  }

  local definition_id
  definition_id=$(echo "${create_response}" | jq -r '.id // empty')
  if [[ -z "${definition_id}" ]]; then
    echo "ERROR: POST /api/v1/entities/definitions returned no id for '${name}'." >&2
    echo "Response: ${create_response}" >&2
    exit 1
  fi
  echo "  Created (DRAFT) -- ID: ${definition_id}"

  echo "--- entity type '${name}': activating ---"
  activate_definition "${name}"
  echo "  Browse at: ${QA_URL}/api/v1/entities/definitions/${definition_id}"
}

seed_entity_definition "production_batch" "test/fixtures/qa/vortex_production_batch_entity_definition.json"
seed_entity_definition "shipment_manifest" "test/fixtures/qa/vortex_shipment_manifest_entity_definition.json"

# ---------------------------------------------------------------------------
# Step 2: field-/type-level restriction rows (§4.2), via the new
# POST /entities/restrictions/import route.
# ---------------------------------------------------------------------------

lookup_user_id() {
  local username="$1"
  local response
  response=$(curl -sf \
    -H "${AUTH_HEADER}" \
    "${QA_URL}/api/v1/identity/users?search=${username}") || {
    echo "ERROR: GET /api/v1/identity/users?search=${username} failed (HTTP error)." >&2
    exit 1
  }
  # GH #2784: the search is fuzzy, so pick the item whose username matches EXACTLY (never items[0]):
  # a grant must not go to a similarly named account.
  local user_id
  user_id=$(echo "${response}" | jq -r --arg u "${username}" \
    '[.items[]? | select(.username == $u)][0].id // empty')
  if [[ -z "${user_id}" ]]; then
    echo "ERROR: user ${username} not found (exact username match) in the vortex tenant." >&2
    exit 1
  fi
  echo "${user_id}"
}

echo ""
echo "--- Resolving actor user ids ---"
ANNA_ID=$(lookup_user_id "actor-vortex-anna")
echo "  actor-vortex-anna (cost_approver)   : ${ANNA_ID}"
KARL_ID=$(lookup_user_id "actor-vortex-karl")
echo "  actor-vortex-karl (quality_manager) : ${KARL_ID} (no grant row seeded for Karl -- design §2.2)"
SEED_ID=$(lookup_user_id "${SEED_ACTOR_USERNAME}")
echo "  ${SEED_ACTOR_USERNAME} (seeding account)       : ${SEED_ID}"
if [[ "${SEED_ID}" == "${ANNA_ID}" || "${SEED_ID}" == "${KARL_ID}" ]]; then
  echo "ERROR: SEED_ACTOR_USERNAME must be a DEDICATED account, not a persona (actor-vortex-anna / actor-vortex-karl)." >&2
  exit 1
fi

echo ""
echo "--- Seeding restriction/grant rows via POST /entities/restrictions/import ---"

restrictions_payload=$(jq -n --arg anna "${ANNA_ID}" --arg seed "${SEED_ID}" '{
  field_restrictions: [
    {entity_type: "production_batch", field_name: "cost_figure"}
  ],
  field_grants: [
    {user_id: $anna, entity_type: "production_batch", field_name: "cost_figure"},
    {user_id: $seed, entity_type: "production_batch", field_name: "cost_figure"}
  ],
  type_restrictions: [
    {entity_type: "shipment_manifest"}
  ],
  type_grants: [
    {user_id: $seed, entity_type: "shipment_manifest"}
  ]
}')

restrictions_response=$(printf '%s' "${restrictions_payload}" | curl -sf \
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

# GH #2784: the grants above went to SEED_ACTOR_USERNAME, but the record import below runs as the
# QA_AUTH_TOKEN user. The type gate answers GET /entities/definitions/by-name/<type> with 200 only
# to a caller holding the type grant (404 otherwise), and the only type grant just seeded is the
# seeding account's: so a 200 here proves the token belongs to that account. A 404 means the grant
# silently does nothing for this token -- refuse to import. (No route returns the token owner's own
# user id, so the check goes through the gate itself. It cannot run BEFORE the grants are written:
# on a first run the restriction row does not exist yet, so the GET would be 200 for any token and
# prove nothing. It proves a type grant, not identity; the persona guard above and the per-entry
# status "error" scan below close most of the remaining gap.)
owner_check_status=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "${AUTH_HEADER}" \
  "${API}/entities/definitions/by-name/shipment_manifest") || owner_check_status="network-error"
if [[ "${owner_check_status}" != "200" ]]; then
  echo "ERROR: QA_AUTH_TOKEN does not belong to SEED_ACTOR_USERNAME (${SEED_ACTOR_USERNAME}):" >&2
  echo "       GET /api/v1/entities/definitions/by-name/shipment_manifest returned ${owner_check_status}, not 200." >&2
  echo "       The type and field grants were seeded for ${SEED_ACTOR_USERNAME}; the import would be refused." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 3: sample records (§4.3) -- idempotent via this script's own
# pre-check query, since the bulk-import route mints its own ephemeral
# idempotency_key per call rather than honoring a per-item one (§3.3).
# ---------------------------------------------------------------------------

# Collects every existing value of `key_field` for `entity_type`, across all
# pages, into a JSON array -- so the import below can exclude fixture rows
# already present.
existing_keys_for() {
  local entity_type="$1"
  local key_field="$2"
  local keys="[]"
  local cursor="null"

  while :; do
    local query_body
    if [[ "${cursor}" == "null" ]]; then
      query_body=$(jq -n --arg et "${entity_type}" '{entity_type: $et, page_size: 200}')
    else
      query_body=$(jq -n --arg et "${entity_type}" --argjson cursor "${cursor}" \
        '{entity_type: $et, page_size: 200, cursor: $cursor}')
    fi

    local resp
    resp=$(printf '%s' "${query_body}" | curl -sf \
      -X POST \
      -H "${AUTH_HEADER}" \
      -H "Content-Type: application/json" \
      --data-binary @- \
      "${API}/entities/query") || {
      echo "ERROR: POST /api/v1/entities/query failed while checking existing ${entity_type} records." >&2
      exit 1
    }

    keys=$(jq -n --argjson acc "${keys}" --argjson page "${resp}" --arg kf "${key_field}" \
      '$acc + [$page.items[].field_values[$kf]]')

    cursor=$(echo "${resp}" | jq -c '.next_cursor')
    if [[ "${cursor}" == "null" ]]; then
      break
    fi
  done

  echo "${keys}"
}

import_records_if_missing() {
  local entity_type="$1"
  local key_field="$2"
  local fixture_path="$3"
  local fixture_full_path="${REPO_ROOT}/${fixture_path}"

  echo ""
  echo "--- ${entity_type}: checking which sample records already exist ---"

  local existing_keys
  existing_keys=$(existing_keys_for "${entity_type}" "${key_field}")

  local remaining_payload
  remaining_payload=$(jq --argjson existing "${existing_keys}" --arg kf "${key_field}" \
    '.records |= map(select((.field_values[$kf] as $k | $existing | index($k)) == null))' \
    "${fixture_full_path}")

  local total remaining
  total=$(jq '.records | length' "${fixture_full_path}")
  remaining=$(echo "${remaining_payload}" | jq '.records | length')

  echo "  ${remaining} of ${total} ${entity_type} record(s) are new."

  if [[ "${remaining}" -eq 0 ]]; then
    echo "  Already fully seeded -- skipping import."
    return 0
  fi

  # Chunk at <=200 per call (§3.3/§4.3) -- not needed at today's 83/10
  # counts, but stated so a future fixture growth doesn't silently break
  # the import route's 200-record cap.
  local chunk_size=200
  local chunk_count=$(((remaining + chunk_size - 1) / chunk_size))
  local chunk_index=0

  while [[ "${chunk_index}" -lt "${chunk_count}" ]]; do
    local start=$((chunk_index * chunk_size))
    local chunk_payload
    chunk_payload=$(echo "${remaining_payload}" | jq --argjson start "${start}" --argjson size "${chunk_size}" \
      '.records |= .[$start:($start + $size)]')

    local import_response
    import_response=$(printf '%s' "${chunk_payload}" | curl -sf \
      -X POST \
      -H "${AUTH_HEADER}" \
      -H "Content-Type: application/json" \
      --data-binary @- \
      "${API}/entities/records/${entity_type}/import") || {
      echo "ERROR: POST /api/v1/entities/records/${entity_type}/import failed (chunk $((chunk_index + 1))/${chunk_count})." >&2
      exit 1
    }

    # GH #2784: the route answers 200 with a per-entry report; an entry refused (for example
    # `field_restricted`) is a status "error" entry, never an HTTP error. Fail loudly on any.
    local failed_entries
    failed_entries=$(echo "${import_response}" | jq '[.results[]? | select(.status == "error")] | length')
    if [[ "${failed_entries}" != "0" ]]; then
      echo "ERROR: ${failed_entries} ${entity_type} entry(ies) were refused in chunk $((chunk_index + 1))/${chunk_count}:" >&2
      echo "${import_response}" | jq -c '[.results[] | select(.status == "error") | .reason]' >&2
      exit 1
    fi

    chunk_index=$((chunk_index + 1))
  done

  echo "  Imported ${remaining} new ${entity_type} record(s)."
}

import_records_if_missing "production_batch" "batch_ref" "test/fixtures/qa/vortex_production_batch_records.json"
import_records_if_missing "shipment_manifest" "manifest_ref" "test/fixtures/qa/vortex_shipment_manifest_records.json"

echo ""
echo "=== seed_vortex_entities.sh complete ==="
echo "  production_batch   : $(jq '.records | length' "${REPO_ROOT}/test/fixtures/qa/vortex_production_batch_records.json") sample record(s) in fixture"
echo "  shipment_manifest  : $(jq '.records | length' "${REPO_ROOT}/test/fixtures/qa/vortex_shipment_manifest_records.json") sample record(s) in fixture"
echo "  Browse definitions at: ${QA_URL}/api/v1/entities/definitions"
