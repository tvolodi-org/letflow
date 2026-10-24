#!/usr/bin/env bash
# seed_meridian_persona_actors.sh
#
# Provisions the letflow-side (Part B) of the Meridian persona actors (ISS-0931):
#   - Creates process-routing role groups + tenant_role bindings for every role
#     referenced by the Meridian QA definitions (9 roles; role-committee-member dropped by ISS-1024, role-credit-approver-l1 added by ISS-1028 for l1-approval, role-loan-ops-lead added by Q-1048 / GH #2390 for the disbursement escalation, the three committee votes now route to role-cro / role-credit-director / role-ceo)
#   - Adds each persona actor to TASK_WORKER (implicit) and to its role groups
#
# Prerequisites:
#   - curl and jq installed
#   - Part A done: Keycloak accounts actor-meridian-* exist and have synced into
#     letflow's users table (ai-dala-infra). Missing actor => abort naming it.
#   - QA_AUTH_TOKEN: Bearer token for a TENANT_ADMIN user in the meridian tenant.
#       Least role per call (REQ-454; derived from Letflow.Api.Authorization):
#         GET /api/v1/me/access            any token (start-up check, REQ-449)
#         GET /api/v1/identity/roles       RolesManage                  -> TENANT_ADMIN
#         POST /api/v1/identity/roles      RolesManage                  -> TENANT_ADMIN
#         GET /api/v1/identity/users       UsersManage                  -> TENANT_ADMIN
#         GET/POST /api/v1/identity/groups GroupsManage                 -> TENANT_ADMIN
#         POST .../groups/:id/members      GroupsManage                 -> TENANT_ADMIN
#       The start-up check requires UsersGroupsRolesManage and RolesManage and exits 1
#       naming a missing one before anything is written. No platform account is needed.
#   - QA_URL: base URL (default: https://qa.bizdala.com)
#   - Run AFTER scripts/seed_meridian_definition.sh.
#
# Usage:
#   QA_AUTH_TOKEN="<token>" bash scripts/seed_meridian_persona_actors.sh
#
# Assumption: the persona -> role mapping comes from the scenario `actors:` blocks
# (test/fixtures/uat/scenarios/meridian/*.yaml) and
# test/fixtures/simulation/meridian/org_structure.yaml; thomas -> role-cro and
# eva -> role-ceo are inferred from org structure, not stated verbatim. Role groups
# are the authoritative part; a BA may amend the PERSONAS table only.
# TASK_WORKER is implicit for every persona and never listed below.
#
# Design: lib/letflow/design/iss0931-meridian-vortex-persona-actor-provisioning.md

set -euo pipefail

ROLES=(
  "role-credit-manager"
  "role-credit-approver-l1"
  "role-risk-manager"
  "role-compliance-officer"
  "role-credit-director"
  "role-loan-ops"
  "role-loan-ops-lead"
  "role-cro"
  "role-ceo"
)
PERSONAS=(
  "actor-meridian-ben|role-credit-manager"
  "actor-meridian-miriam|role-risk-manager"
  "actor-meridian-claudia|role-compliance-officer"
  "actor-meridian-julia|role-credit-director"
  "actor-meridian-thomas|role-cro"
  "actor-meridian-eva|role-ceo"
  "actor-meridian-marcus|role-loan-ops"
  "actor-meridian-lars|role-credit-approver-l1"
  "actor-meridian-sophie|"
  "actor-meridian-oliver|"
  "actor-meridian-hannah|role-loan-ops-lead"
)

source "$(dirname "${BASH_SOURCE[0]}")/lib/seed_persona_actors_base.sh"

persona_require_env
persona_run meridian

# GH #3077: the refusal scenario's step 8 needs borrower records to refuse. The entity seed
# needs a dedicated seeding account (SEED_ACTOR_USERNAME); without one it is skipped, loudly.
if [[ -n "${SEED_ACTOR_USERNAME:-}" ]]; then
  bash "$(dirname "${BASH_SOURCE[0]}")/seed_meridian_entities.sh"
else
  echo "NOTE: SEED_ACTOR_USERNAME is not set -- skipping scripts/seed_meridian_entities.sh." >&2
  echo "      The meridian refusal scenario's borrower export step has no data until it is run." >&2
fi
