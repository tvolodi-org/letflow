#!/usr/bin/env bash
# qoimeks_qa2_fixture_ledger3.sh
#
# T-2394 (Qoimeks ledger-3 part B, scenario steps 17-24): prepare ONE posting task whose
# content differs from the issued receipt. Completing that task must answer 409
# record_version_conflict; the genuine, unchanged posting task must still post normally.
# Run by the OPERATOR, never by the UAT walker. Synthetic QA data only.
#
# Creates on tenant qoimeks-qa2 ONLY, through the public API as the tenant administrator:
#   one extra stock_receipt instance for an issued receipt D, using the variables of D's genuine
#   pending posting instance except that the first line quantity is raised by one unit.
# It writes NO stock and NO document. The extra instance carries correlation key uat-ledger3-<D>
# and a fixed idempotency key, so a repeat prints the existing manifest instead of starting another.
# --cleanup <instance id> cancels only an instance whose correlation key is uat-ledger3-<document id>
# for its own document variable. Cancelling the instance withdraws its task; no stock is involved.
#
# Slug guard: TENANT_SLUG (default qoimeks-qa2) must be exactly qoimeks-qa2 and the host of QA_URL
# must be that tenant's host. qoimeks-qa and qoimeks-client1-qa are refused by name, before the token
# is read or any API call is made.
#
# Prerequisites: curl, jq; QA_AUTH_TOKEN = Bearer token of a TENANT_ADMIN of qoimeks-qa2.
#   GET  /api/v1/modules/stock/documents/:id       StockRead
#   GET  /api/v1/tasks                             TasksRead
#   GET  /api/v1/instances, /instances/:id         InstancesRead
#   POST /api/v1/instances                         InstancesStart
#   POST /api/v1/instances/:id/cancel              InstancesCancel
#
# Usage:
#   QA_AUTH_TOKEN="<token>" bash scripts/qoimeks_qa2_fixture_ledger3.sh <issued-receipt-id>
#   QA_AUTH_TOKEN="<token>" bash scripts/qoimeks_qa2_fixture_ledger3.sh --cleanup <instance-id>
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

usage() {
  echo "Usage: bash scripts/qoimeks_qa2_fixture_ledger3.sh <issued-receipt-id>" >&2
  echo "       bash scripts/qoimeks_qa2_fixture_ledger3.sh --cleanup <instance-id>" >&2
  exit 2
}

MODE="create"
DOCUMENT_ID=""
CLEANUP_INSTANCE_ID=""
if [[ $# -eq 1 && "$1" != --* ]]; then
  DOCUMENT_ID="$1"
elif [[ $# -eq 2 && "$1" == "--cleanup" ]]; then
  MODE="cleanup"
  CLEANUP_INSTANCE_ID="$2"
else
  usage
fi

uuid_re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
if [[ "${MODE}" == "create" && ! "${DOCUMENT_ID}" =~ ${uuid_re} ]]; then
  echo "ERROR: the receipt identifier is not a UUID." >&2
  exit 2
fi
if [[ "${MODE}" == "cleanup" && ! "${CLEANUP_INSTANCE_ID}" =~ ${uuid_re} ]]; then
  echo "ERROR: the cleanup instance identifier is not a UUID." >&2
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

echo "=== qoimeks_qa2_fixture_ledger3.sh ==="
echo "tenant: ${TENANT_SLUG}  url: ${QA_URL}"

seed_require_permissions TENANT_ADMIN StockRead TasksRead InstancesRead InstancesStart InstancesCancel

# get_json <path>: prints the response body; exits 1 on transport or HTTP error.
get_json() {
  local path="$1"
  curl -sfS -H "${AUTH_HEADER}" "${API}${path}" || {
    echo "ERROR: GET ${path} failed." >&2
    exit 1
  }
}

# post_json <path> <body> <idempotency-key>: prints the response body; never prints the token.
post_json() {
  local path="$1" body="$2" key="$3"
  printf '%s' "${body}" | curl -sfS -X POST -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" -H "Idempotency-Key: ${key}" \
    --data-binary @- "${API}${path}" || {
    echo "ERROR: POST ${path} failed." >&2
    exit 1
  }
}

urlencode() { printf '%s' "$1" | jq -sRr @uri; }

# tasks_all <query-without-leading-question-mark>: all matching tasks, across cursor pages.
tasks_all() {
  local filters="$1" cursor="" path resp all="[]"
  while :; do
    path="/tasks?${filters}&page_size=200"
    if [[ -n "${cursor}" ]]; then
      path="${path}&cursor=$(urlencode "${cursor}")"
    fi
    resp=$(get_json "${path}")
    if ! printf '%s' "${resp}" | jq -e '.items | type == "array"' >/dev/null; then
      echo "ERROR: task query returned no items array." >&2
      exit 1
    fi
    all=$({ printf '%s\n' "${all}"; printf '%s\n' "${resp}"; } | jq -c -s '.[0] + .[1].items')
    cursor=$(printf '%s' "${resp}" | jq -r '.next_cursor // empty')
    [[ -z "${cursor}" ]] && break
  done
  printf '%s' "${all}"
}

# manifest <instance-id> <document-id>: resolve the post task and print only non-secret identifiers.
manifest() {
  local instance_id="$1" document_id="$2" tasks task task_id
  tasks=$(tasks_all "instance_id=${instance_id}")
  task=$(printf '%s' "${tasks}" | jq -c '[.[] | select(.node_id == "post")] | first // empty')
  if [[ -z "${task}" ]]; then
    echo "ERROR: instance ${instance_id} has no posting task; no manifest can be printed." >&2
    exit 1
  fi
  task_id=$(printf '%s' "${task}" | jq -r '.id // empty')
  if [[ -z "${task_id}" ]]; then
    echo "ERROR: the posting task response has no id." >&2
    exit 1
  fi
  echo "manifest:"
  echo "  instance_id=${instance_id}"
  echo "  task_id=${task_id}"
  echo "  document_id=${document_id}"
}

if [[ "${MODE}" == "cleanup" ]]; then
  instance=$(get_json "/instances/${CLEANUP_INSTANCE_ID}")
  if ! printf '%s' "${instance}" | jq -e '
      (.correlation_key | type == "string") and
      (.variables.document_id | type == "string") and
      (.correlation_key == ("uat-ledger3-" + .variables.document_id))
    ' >/dev/null; then
    echo "ERROR: instance ${CLEANUP_INSTANCE_ID} is not a qoimeks ledger-3 fixture instance; refusing cleanup." >&2
    exit 1
  fi
  document_id=$(printf '%s' "${instance}" | jq -r '.variables.document_id')
  status=$(printf '%s' "${instance}" | jq -r '.status // empty')
  if [[ "${status}" == "CANCELLED" ]]; then
    echo "already cancelled: instance_id=${CLEANUP_INSTANCE_ID}"
    echo "  document_id=${document_id}"
    exit 0
  fi
  if [[ "${status}" != "ACTIVE" && "${status}" != "ERROR" ]]; then
    echo "ERROR: fixture instance ${CLEANUP_INSTANCE_ID} has status ${status}; it cannot be cancelled." >&2
    exit 1
  fi
  resp=$(post_json "/instances/${CLEANUP_INSTANCE_ID}/cancel" '{}' \
    "uat-ledger3-cleanup-${CLEANUP_INSTANCE_ID}")
  if ! printf '%s' "${resp}" | jq -e --arg id "${CLEANUP_INSTANCE_ID}" \
    '.instance_id == $id and .status == "CANCELLED"' >/dev/null; then
    echo "ERROR: cleanup of ${CLEANUP_INSTANCE_ID} did not confirm CANCELLED." >&2
    exit 1
  fi
  echo "cancelled: instance_id=${CLEANUP_INSTANCE_ID}"
  echo "  document_id=${document_id}"
  echo "No stock or document was written."
  exit 0
fi

CORRELATION_KEY="uat-ledger3-${DOCUMENT_ID}"
IDEMPOTENCY_KEY="${CORRELATION_KEY}"

# A repeat is resolved by the run-owned correlation key before validating or starting anything.
encoded_key=$(urlencode "${CORRELATION_KEY}")
existing_page=$(get_json "/instances?correlation_key=${encoded_key}&page_size=200")
existing_count=$(printf '%s' "${existing_page}" | jq -r '.items | length')
if [[ "${existing_count}" == "1" ]]; then
  instance_id=$(printf '%s' "${existing_page}" | jq -r '.items[0].instance_id')
  echo "exists: changed posting fixture (${CORRELATION_KEY})"
  manifest "${instance_id}" "${DOCUMENT_ID}"
  exit 0
fi
if [[ "${existing_count}" != "0" ]]; then
  echo "ERROR: correlation key ${CORRELATION_KEY} names ${existing_count} instances; refusing to choose one." >&2
  exit 1
fi

# D must be the issued receipt of this walk. A posted, cancelled, draft or other-kind document is
# never used as the basis of an extra posting instance.
document=$(get_json "/modules/stock/documents/${DOCUMENT_ID}")
if ! printf '%s' "${document}" | jq -e '.kind == "receipt" and .state == "issued"' >/dev/null; then
  echo "ERROR: ${DOCUMENT_ID} is not an issued receipt. Nothing was started." >&2
  exit 1
fi

# The public task list has no document-id filter. Inspect only the instances of pending post tasks
# and select the genuine one: its variables name D and it has no correlation key. Other runs and the
# fixture's own correlated instance cannot be mistaken for it.
pending_tasks=$(tasks_all "status=PENDING")
genuine_instance_id=""
genuine_variables=""
while IFS= read -r candidate_id; do
  [[ -z "${candidate_id}" ]] && continue
  candidate=$(get_json "/instances/${candidate_id}")
  if printf '%s' "${candidate}" | jq -e --arg d "${DOCUMENT_ID}" '
      .correlation_key == null and
      .variables.document_id == $d and
      .variables.posting.document_id == $d
    ' >/dev/null; then
    if [[ -n "${genuine_instance_id}" ]]; then
      echo "ERROR: more than one genuine pending posting instance names ${DOCUMENT_ID}; refusing to choose." >&2
      exit 1
    fi
    genuine_instance_id="${candidate_id}"
    genuine_variables=$(printf '%s' "${candidate}" | jq -c '.variables')
  fi
done < <(printf '%s' "${pending_tasks}" | jq -r '.[] | select(.node_id == "post") | .instance_id' | sort -u)

if [[ -z "${genuine_instance_id}" ]]; then
  echo "ERROR: issued receipt ${DOCUMENT_ID} has no genuine pending posting task. Nothing was started." >&2
  exit 1
fi
if ! printf '%s' "${pending_tasks}" | jq -e --arg id "${genuine_instance_id}" \
  '[.[] | select(.instance_id == $id and .node_id == "post")] | length == 1' >/dev/null; then
  echo "ERROR: the genuine posting instance does not have exactly one pending post task." >&2
  exit 1
fi

if ! printf '%s' "${genuine_variables}" | jq -e '
    (.posting.lines | type == "array" and length > 0) and
    (.posting.lines[0].quantity | type == "number" or type == "string")
  ' >/dev/null; then
  echo "ERROR: the genuine posting has no first-line quantity to change. Nothing was started." >&2
  exit 1
fi
changed_variables=$(printf '%s' "${genuine_variables}" | jq -c '
  .posting.lines[0].quantity |= (
    if type == "number" then . + 1
    elif type == "string" then ((tonumber + 1) | tostring)
    else error("quantity is not numeric")
    end)
') || {
  echo "ERROR: the first-line quantity is not numeric. Nothing was started." >&2
  exit 1
}

body=$(jq -n --arg key "${CORRELATION_KEY}" --argjson vars "${changed_variables}" '{
  definition_name: "stock_receipt",
  correlation_key: $key,
  initial_variables: $vars
}')
resp=$(post_json "/instances" "${body}" "${IDEMPOTENCY_KEY}")
instance_id=$(printf '%s' "${resp}" | jq -r '.instance_id // empty')
if [[ -z "${instance_id}" ]]; then
  echo "ERROR: the instance start returned no instance_id." >&2
  exit 1
fi

echo "created: changed posting fixture (${CORRELATION_KEY})"
manifest "${instance_id}" "${DOCUMENT_ID}"
echo "The first posting quantity was raised by one unit. No stock or document was written."
