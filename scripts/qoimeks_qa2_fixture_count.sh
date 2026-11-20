#!/usr/bin/env bash
# qoimeks_qa2_fixture_count.sh
#
# T-2357 (count walk T-2309, QA 3d4a6ec5d): the two environment gaps that BLOCKED
#   qoimeks-count-4 EO-005 (step 6 needs a LOT-tracked item) and
#   qoimeks-count-8 (needs a SECOND active employee E2 in the Responsible picker).
# Run by the OPERATOR, never by the UAT walker. Synthetic QA data only.
#
# Creates on tenant qoimeks-qa2 ONLY, through the public API as the tenant administrator:
#   (a) employee QOI-EMP-2 ("QA Employee 2"), active, in the org unit of QOI-EMP-1;
#   (b) item UAT-LOT-0001 (base unit pcs, kind material, tracking_policy lot) and its lot LOT-A.
# It creates NO stock: count-8 makes its own receipt under E2 through the screens and undoes it by
# reversal, and count-4 EO-005 only needs a lot-tracked item to refuse the count without a lot. So
# the 678 items / 603 balances baseline changes by exactly one item, one lot and one employee.
#
# Idempotent: every record is looked up by its code first (POST /entities/query); a second run
# creates nothing and prints "exists" for each. The write calls also carry fixed idempotency keys.
#
# Slug guard: the tenant slug (TENANT_SLUG, default qoimeks-qa2) must be exactly qoimeks-qa2 and
# the host of QA_URL must be that tenant's host. qoimeks-qa and qoimeks-client1-qa are refused by
# name. The guard runs before anything is read or written.
#
# Prerequisites: curl, jq; QA_AUTH_TOKEN = Bearer token of a TENANT_ADMIN of qoimeks-qa2.
#   POST /api/v1/entities/query                      EntitiesQuery
#   POST /api/v1/modules/org/employees               OrgEmployeesWrite        -> TENANT_ADMIN
#   POST /api/v1/entities/records/catalog_item/import EntitiesRecordsImport    -> TENANT_ADMIN
#   POST /api/v1/modules/catalog_items/lots          CatalogLotsWrite         -> TENANT_ADMIN
#
# Usage:
#   QA_AUTH_TOKEN="<token>" bash scripts/qoimeks_qa2_fixture_count.sh
#   (QA_URL defaults to https://qoimeks-qa2.letflow.qa.bizdala.com)

set -euo pipefail

ALLOWED_SLUG="qoimeks-qa2"
TENANT_SLUG="${TENANT_SLUG:-${ALLOWED_SLUG}}"
QA_URL="${QA_URL:-https://${ALLOWED_SLUG}.letflow.qa.bizdala.com}"

# --- slug guard (before the token is even read) ---------------------------------------------------
case "${TENANT_SLUG}" in
  qoimeks-qa | qoimeks-client1-qa)
    echo "ERROR: refusing tenant ${TENANT_SLUG}: this fixture is for ${ALLOWED_SLUG} only." >&2
    exit 2
    ;;
esac
if [[ "${TENANT_SLUG}" != "${ALLOWED_SLUG}" ]]; then
  echo "ERROR: refusing tenant '${TENANT_SLUG}': this fixture is for ${ALLOWED_SLUG} only." >&2
  exit 2
fi
url_host="${QA_URL#*://}"
url_host="${url_host%%/*}"
url_host="${url_host%%:*}"
if [[ "${url_host}" != "${ALLOWED_SLUG}.letflow.qa.bizdala.com" ]]; then
  echo "ERROR: refusing QA_URL host '${url_host}': it is not the host of ${ALLOWED_SLUG}." >&2
  exit 2
fi

if [[ -z "${QA_AUTH_TOKEN:-}" ]]; then
  echo "ERROR: QA_AUTH_TOKEN is not set (Bearer token of a TENANT_ADMIN of ${ALLOWED_SLUG})." >&2
  exit 1
fi

API="${QA_URL}/api/v1"
AUTH_HEADER="Authorization: Bearer ${QA_AUTH_TOKEN}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/seed_token_check.sh
source "${SCRIPT_DIR}/lib/seed_token_check.sh"

EMP1_CODE="QOI-EMP-1"
EMP2_CODE="QOI-EMP-2"
ITEM_CODE="UAT-LOT-0001"
LOT_CODE="LOT-A"
UOM_CODE="pcs"
EXT_SYSTEM="t2357-qa2-fixture"

echo "=== qoimeks_qa2_fixture_count.sh ==="
echo "tenant: ${TENANT_SLUG}  url: ${QA_URL}"

seed_require_permissions TENANT_ADMIN EntitiesQuery OrgEmployeesWrite EntitiesRecordsImport CatalogLotsWrite

# post_json <path> <body>: prints the response body; exits 1 with the status on an HTTP error.
post_json() {
  local path="$1" body="$2" out
  out=$(printf '%s' "${body}" | curl -sS -X POST -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
    --data-binary @- "${API}${path}") || {
    echo "ERROR: POST ${path} failed." >&2
    exit 1
  }
  printf '%s' "${out}"
}

# query_all <entity_type>: prints a JSON array of every item (all pages) of the type.
query_all() {
  local type="$1" cursor="null" all="[]" body resp
  while :; do
    if [[ "${cursor}" == "null" ]]; then
      body=$(jq -n --arg et "${type}" '{entity_type: $et, page_size: 200}')
    else
      body=$(jq -n --arg et "${type}" --argjson c "${cursor}" '{entity_type: $et, page_size: 200, cursor: $c}')
    fi
    resp=$(post_json "/entities/query" "${body}")
    echo "${resp}" | jq -e '.items' >/dev/null || {
      echo "ERROR: query of ${type} gave no items." >&2
      exit 1
    }
    all=$({ printf '%s\n' "${all}"; printf '%s\n' "${resp}"; } | jq -c -s '.[0] + .[1].items')
    cursor=$(echo "${resp}" | jq -c '.next_cursor')
    [[ "${cursor}" == "null" ]] && break
  done
  printf '%s' "${all}"
}

# find_by_code <items-json> <code>: the first item whose field_values.code equals <code>, or empty.
find_by_code() {
  printf '%s' "$1" | jq -c --arg c "$2" '[.[] | select(.field_values.code == $c)] | first // empty'
}

record_id_of() { printf '%s' "$1" | jq -r '.record_id // .id'; }

created=0

# --- (a) employee QOI-EMP-2 -----------------------------------------------------------------------
employees=$(query_all org_employee)
emp2=$(find_by_code "${employees}" "${EMP2_CODE}")
if [[ -n "${emp2}" ]]; then
  echo "exists:  employee ${EMP2_CODE}"
else
  emp1=$(find_by_code "${employees}" "${EMP1_CODE}")
  if [[ -z "${emp1}" ]]; then
    echo "ERROR: employee ${EMP1_CODE} not found; cannot take its org unit. Nothing created." >&2
    exit 1
  fi
  unit_id=$(printf '%s' "${emp1}" | jq -r '.field_values.org_unit_id // empty')
  if [[ -z "${unit_id}" ]]; then
    echo "ERROR: ${EMP1_CODE} has no org_unit_id. Nothing created." >&2
    exit 1
  fi
  body=$(jq -n --arg code "${EMP2_CODE}" --arg unit "${unit_id}" \
    '{code: $code, full_name: "QA Employee 2", org_unit_id: $unit, idempotency_key: "t2357-employee-QOI-EMP-2"}')
  resp=$(post_json "/modules/org/employees" "${body}")
  echo "${resp}" | jq -e '.record_id // .id' >/dev/null || {
    echo "ERROR: employee ${EMP2_CODE} refused: $(echo "${resp}" | jq -c '.' 2>/dev/null | cut -c1-300)" >&2
    exit 1
  }
  echo "created: employee ${EMP2_CODE} (org unit of ${EMP1_CODE})"
  created=$((created + 1))
fi

# --- (b) lot-tracked item UAT-LOT-0001 and lot LOT-A -----------------------------------------------
items=$(query_all catalog_item)
item=$(find_by_code "${items}" "${ITEM_CODE}")
if [[ -n "${item}" ]]; then
  echo "exists:  item ${ITEM_CODE}"
else
  uoms=$(query_all catalog_uom)
  uom=$(find_by_code "${uoms}" "${UOM_CODE}")
  if [[ -z "${uom}" ]]; then
    echo "ERROR: unit '${UOM_CODE}' not found in ${TENANT_SLUG}. Nothing more created." >&2
    exit 1
  fi
  uom_sys=$(printf '%s' "${uom}" | jq -r '.field_values.external_ref_system // empty')
  uom_ext=$(printf '%s' "${uom}" | jq -r '.field_values.external_ref_id // empty')
  if [[ -z "${uom_sys}" || -z "${uom_ext}" ]]; then
    echo "ERROR: unit '${UOM_CODE}' has no external reference; the import cannot name it. Nothing more created." >&2
    exit 1
  fi
  # The item reference to its unit resolves under the SAME external-ref system as the row.
  body=$(jq -n --arg sys "${uom_sys}" --arg uom "${uom_ext}" --arg code "${ITEM_CODE}" '{
    record_export_schema_version: "entities/record-export/v1",
    entity_type: "catalog_item",
    upsert_by: "external_ref",
    records: [{
      external_ref: {system: $sys, id: $code},
      field_values: {code: $code, name: "UAT lot-tracked item", base_uom_id: $uom,
                     kind: "material", tracking_policy: "lot", active: true}
    }]}')
  resp=$(printf '%s' "${body}" | curl -sS -X POST -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
    --data-binary @- "${API}/entities/records/catalog_item/import?upsert_by=external_ref") || {
    echo "ERROR: item import failed." >&2
    exit 1
  }
  bad=$(echo "${resp}" | jq '[.results[]? | select(.status == "error" or .reason != null)] | length' 2>/dev/null || echo 1)
  if [[ "${bad}" != "0" ]]; then
    echo "ERROR: item ${ITEM_CODE} refused: $(echo "${resp}" | jq -c '[.results[]? | .reason]' 2>/dev/null | cut -c1-300)" >&2
    exit 1
  fi
  echo "created: item ${ITEM_CODE} (unit ${UOM_CODE}, tracking lot)"
  created=$((created + 1))
  items=$(query_all catalog_item)
  item=$(find_by_code "${items}" "${ITEM_CODE}")
  if [[ -z "${item}" ]]; then
    echo "ERROR: item ${ITEM_CODE} not found after import." >&2
    exit 1
  fi
fi
item_id=$(record_id_of "${item}")

lots=$(query_all catalog_lot)
lot=$(printf '%s' "${lots}" | jq -c --arg c "${LOT_CODE}" --arg i "${item_id}" \
  '[.[] | select(.field_values.code == $c and .field_values.item_id == $i)] | first // empty')
if [[ -n "${lot}" ]]; then
  echo "exists:  lot ${LOT_CODE} of ${ITEM_CODE}"
else
  body=$(jq -n --arg i "${item_id}" --arg c "${LOT_CODE}" \
    '{item_id: $i, code: $c, idempotency_key: "t2357-lot-UAT-LOT-0001-LOT-A"}')
  resp=$(post_json "/modules/catalog_items/lots" "${body}")
  echo "${resp}" | jq -e '.record_id // .id' >/dev/null || {
    echo "ERROR: lot ${LOT_CODE} refused: $(echo "${resp}" | jq -c '.' 2>/dev/null | cut -c1-300)" >&2
    exit 1
  }
  echo "created: lot ${LOT_CODE} of ${ITEM_CODE}"
  created=$((created + 1))
fi

echo "=== done: ${created} record(s) created (stock: none created, by design) ==="
echo "Operator: note QOI-EMP-2, UAT-LOT-0001 and LOT-A in project/qoimeks-seed-facts.json notes."
