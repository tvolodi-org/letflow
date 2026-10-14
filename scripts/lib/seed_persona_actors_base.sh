#!/usr/bin/env bash
# seed_persona_actors_base.sh
#
# Sourced helper for scripts/seed_<tenant>_persona_actors.sh (ISS-0931).
# Functions only -- no top-level side effects. The sourcing script must define
# the ROLES and PERSONAS arrays (see lib/letflow/design/
# iss0931-meridian-vortex-persona-actor-provisioning.md section 3) and
# `set -euo pipefail` itself.
#
# Bodies are a port of scripts/seed_swiftroute_persona_actors.sh helpers, with
# one deliberate hardening: lookup_user_id requires an EXACT username match.
#
# All errors go to stderr and exit 1.

# Verifies QA_AUTH_TOKEN; sets QA_URL (default), API and AUTH_HEADER globals.
persona_require_env() {
  QA_URL="${QA_URL:-https://qa.bizdala.com}"
  API="${QA_URL}/api/v1/identity"

  if [[ -z "${QA_AUTH_TOKEN:-}" ]]; then
    echo "ERROR: QA_AUTH_TOKEN is not set." >&2
    echo "       Set it to a Bearer token for a PLATFORM_ADMIN user in the target tenant." >&2
    exit 1
  fi

  AUTH_HEADER="Authorization: Bearer ${QA_AUTH_TOKEN}"
}

# Look up user by EXACT username; abort if not found (Part A missing).
lookup_user_id() {
  local username="$1"
  local response
  response=$(curl -sf \
    -H "${AUTH_HEADER}" \
    "${API}/users?search=${username}") || {
    echo "ERROR: GET /api/v1/identity/users?search=${username} failed (HTTP error)." >&2
    exit 1
  }
  local user_id
  user_id=$(echo "${response}" | jq -r --arg u "${username}" \
    '[.items[] | select(.username==$u)][0].id // empty')
  if [[ -z "${user_id}" ]]; then
    echo "ERROR: user ${username} not found." >&2
    echo "       Complete Part A (ai-dala-infra Keycloak provisioning) before running this script." >&2
    exit 1
  fi
  echo "${user_id}"
}

# ISS-0932 (Q-932): like lookup_user_id but a persona with no account is NOT
# fatal -- prints an empty string so persona_run can skip-with-warning and still
# seed memberships for every persona that does exist. HTTP errors stay fatal.
lookup_user_id_optional() {
  local username="$1"
  local response
  response=$(curl -sf \
    -H "${AUTH_HEADER}" \
    "${API}/users?search=${username}") || {
    echo "ERROR: GET /api/v1/identity/users?search=${username} failed (HTTP error)." >&2
    exit 1
  }
  echo "${response}" | jq -r --arg u "${username}" \
    '[.items[] | select(.username==$u)][0].id // empty'
}

# Find group ID by exact name; prints empty string if not found.
find_group_id() {
  local name="$1"
  local response
  response=$(curl -sf \
    -H "${AUTH_HEADER}" \
    "${API}/groups") || {
    echo "ERROR: GET /api/v1/identity/groups failed (HTTP error)." >&2
    exit 1
  }
  echo "${response}" | jq -r --arg n "${name}" '.items[] | select(.name==$n) | .id' | head -1
}

# Create or reuse a group by name; prints the group UUID.
ensure_group() {
  local name="$1"
  local display_name="$2"
  local description="$3"

  local existing_id
  existing_id=$(find_group_id "${name}")

  if [[ -n "${existing_id}" ]]; then
    echo "  Group '${name}' already exists -- skipping creation (id: ${existing_id})" >&2
    echo "${existing_id}"
    return
  fi

  local response
  response=$(curl -sf \
    -X POST \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    --data-ascii "{\"name\":\"${name}\",\"display_name\":\"${display_name}\",\"description\":\"${description}\"}" \
    "${API}/groups") || {
    echo "ERROR: POST /api/v1/identity/groups failed for name='${name}'." >&2
    exit 1
  }

  local group_id
  group_id=$(echo "${response}" | jq -r '.id // empty')
  if [[ -z "${group_id}" ]]; then
    echo "ERROR: POST /api/v1/identity/groups returned no id for '${name}'." >&2
    echo "Response: ${response}" >&2
    exit 1
  fi
  echo "  Group '${name}' created (id: ${group_id})" >&2
  echo "${group_id}"
}

# Upsert tenant_role binding (POST /roles is an upsert -- no pre-check needed).
upsert_role() {
  local name="$1"
  local group_id="$2"

  local response
  response=$(curl -sf \
    -X POST \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    --data-ascii "{\"name\":\"${name}\",\"kind\":\"process_routing_role\",\"group_id\":\"${group_id}\"}" \
    "${API}/roles") || {
    echo "ERROR: POST /api/v1/identity/roles failed for name='${name}'." >&2
    exit 1
  }

  local role_id
  role_id=$(echo "${response}" | jq -r '.id // empty')
  if [[ -z "${role_id}" ]]; then
    echo "ERROR: POST /api/v1/identity/roles returned no id for '${name}'." >&2
    echo "Response: ${response}" >&2
    exit 1
  fi
  echo "  Role '${name}' upserted (id: ${role_id})" >&2
}

# Add user to group (naturally idempotent -- 200 or 201 are both success).
add_group_member() {
  local group_id="$1"
  local user_id="$2"
  local label="$3"

  local http_status
  http_status=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    --data-ascii "{\"user_id\":\"${user_id}\"}" \
    "${API}/groups/${group_id}/members")

  case "${http_status}" in
    200) echo "  ${label} -- already a member (200)" ;;
    201) echo "  ${label} -- membership created (201)" ;;
    *)
      echo "ERROR: POST /api/v1/identity/groups/${group_id}/members returned HTTP ${http_status} for ${label}." >&2
      exit 1
      ;;
  esac
}

# Prints the TASK_WORKER group id; aborts if the platform role is not seeded.
resolve_task_worker_group_id() {
  local response
  response=$(curl -sf \
    -H "${AUTH_HEADER}" \
    "${API}/roles") || {
    echo "ERROR: GET /api/v1/identity/roles failed (HTTP error)." >&2
    exit 1
  }

  local group_id
  group_id=$(echo "${response}" | jq -r '.items[] | select(.name=="TASK_WORKER") | .group_id' | head -1)

  if [[ -z "${group_id}" ]]; then
    echo "ERROR: TASK_WORKER platform role not seeded." >&2
    echo "       Run tenant onboarding (RoleRegistry.seed_default_platform_role_groups/1) for the target tenant before running this script." >&2
    exit 1
  fi
  echo "${group_id}"
}

# Derive a display name from a role name: role-credit-manager -> Credit Manager.
persona_role_display_name() {
  local name="${1#role-}"
  echo "${name}" | tr '-' ' ' | awk '{for (i = 1; i <= NF; i++) $i = toupper(substr($i, 1, 1)) substr($i, 2); print}'
}

# Driver. Reads the caller's ROLES and PERSONAS arrays.
#   persona_run <tenant_label>
persona_run() {
  local tenant_label="$1"

  echo "=== seed_${tenant_label}_persona_actors.sh ==="
  echo "QA_URL: ${QA_URL}"
  echo ""

  echo "--- Step 1: Resolve TASK_WORKER group ---"
  local task_worker_gid
  task_worker_gid=$(resolve_task_worker_group_id)
  echo "  TASK_WORKER group_id: ${task_worker_gid}"

  echo ""
  echo "--- Step 2: Ensure process-routing role groups and tenant_roles ---"
  # Parallel arrays (bash 3.2-safe; no associative arrays): role name -> group id.
  local role_names=() role_gids=()
  local role gid display
  for role in "${ROLES[@]}"; do
    display=$(persona_role_display_name "${role}")
    gid=$(ensure_group "${role}" "${display}" "Process-routing role ${role} (${tenant_label}).")
    upsert_role "${role}" "${gid}"
    role_names+=("${role}")
    role_gids+=("${gid}")
  done

  echo ""
  echo "--- Step 3: Resolve persona actor user IDs ---"
  local persona username uid
  local persona_uids=() missing_personas=()
  for persona in "${PERSONAS[@]}"; do
    username="${persona%%|*}"
    uid=$(lookup_user_id_optional "${username}")
    if [[ -z "${uid}" ]]; then
      echo "  WARNING: ${username} has no account (Part A missing) -- skipping its memberships." >&2
      echo "           letflow creates a user on that person's first authenticated request: sign in as ${username}" >&2
      echo "           once (or send one authenticated GET ${QA_URL}/api/v1/me/memberships with its token), then re-run." >&2
      missing_personas+=("${username}")
    else
      echo "  ${username} : ${uid}"
    fi
    persona_uids+=("${uid}")
  done

  echo ""
  echo "--- Step 4: Add group memberships ---"
  local idx=0 roles_field r i role_list
  for persona in "${PERSONAS[@]}"; do
    username="${persona%%|*}"
    roles_field="${persona#*|}"
    uid="${persona_uids[$idx]}"
    if [[ -z "${uid}" ]]; then
      idx=$((idx + 1))
      continue
    fi
    add_group_member "${task_worker_gid}" "${uid}" "${username} -> TASK_WORKER"
    if [[ -n "${roles_field}" ]]; then
      IFS=',' read -ra role_list <<< "${roles_field}"
      for r in "${role_list[@]}"; do
        gid=""
        for i in "${!role_names[@]}"; do
          if [[ "${role_names[$i]}" == "${r}" ]]; then
            gid="${role_gids[$i]}"
          fi
        done
        if [[ -z "${gid}" ]]; then
          echo "ERROR: persona ${username} references role ${r} which is not in ROLES." >&2
          exit 1
        fi
        add_group_member "${gid}" "${uid}" "${username} -> ${r}"
      done
    fi
    idx=$((idx + 1))
  done

  echo ""
  echo "=== Provisioning complete (${tenant_label}) ==="
  echo "  TASK_WORKER group_id : ${task_worker_gid}"
  for i in "${!role_names[@]}"; do
    echo "  ${role_names[$i]} group_id : ${role_gids[$i]}"
  done
  echo ""
  echo "--- Verification ---"
  echo "# 1. Confirm process_routing_role rows exist (expected: ${#ROLES[@]} items):"
  echo "curl -sf -H \"Authorization: Bearer \$QA_AUTH_TOKEN\" \\"
  echo "  \"${QA_URL}/api/v1/identity/roles\" | \\"
  echo "  jq '[.items[] | select(.kind == \"process_routing_role\")] | length'"
  echo ""
  echo "# 2. Confirm persona membership of a role group (replace <group_id>):"
  echo "curl -sf -H \"Authorization: Bearer \$QA_AUTH_TOKEN\" \\"
  echo "  \"${QA_URL}/api/v1/identity/groups/<group_id>/members\" | jq '[.items[].username]'"
  echo ""
  echo "# 3. Confirm all ${#PERSONAS[@]} personas are TASK_WORKER members:"
  echo "curl -sf -H \"Authorization: Bearer \$QA_AUTH_TOKEN\" \\"
  echo "  \"${QA_URL}/api/v1/identity/groups/${task_worker_gid}/members\" | \\"
  echo "  jq '[.items[] | select(.username | startswith(\"actor-${tenant_label}-\"))] | length'"
  echo "# Expected: ${#PERSONAS[@]}"

  # ISS-0932: report skipped personas and exit non-zero, AFTER every other
  # persona's memberships have been seeded.
  if [[ ${#missing_personas[@]} -gt 0 ]]; then
    echo "" >&2
    echo "ERROR: ${#missing_personas[@]} persona(s) had no account and were skipped: ${missing_personas[*]}" >&2
    echo "       Memberships were seeded for all other personas. Complete Part A for the missing ones and re-run." >&2
    echo "       Part A = the Keycloak account (ai-dala-infra/scripts/qa-login.sh). letflow only creates the user when that" >&2
    echo "       account makes its first authenticated request: sign in as it once, or send one authenticated" >&2
    echo "       GET ${QA_URL}/api/v1/me/memberships with its token." >&2
    echo "       Then re-run: QA_AUTH_TOKEN=<token> bash scripts/seed_${tenant_label}_persona_actors.sh" >&2
    echo "       (safe to repeat: memberships that already exist answer 200 and are left alone)." >&2
    return 1
  fi
}
