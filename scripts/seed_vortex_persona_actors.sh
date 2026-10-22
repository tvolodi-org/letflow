#!/usr/bin/env bash
# seed_vortex_persona_actors.sh
#
# Provisions the letflow-side (Part B) of the Vortex persona actors (ISS-0931):
#   - Creates process-routing role groups + tenant_role bindings for every role
#     referenced by the Vortex QA definitions (6 roles)
#   - Adds each persona actor to TASK_WORKER (implicit) and to its role groups
#
# Prerequisites:
#   - curl and jq installed
#   - Part A done: Keycloak accounts actor-vortex-* exist and have synced into
#     letflow's users table (ai-dala-infra). Missing actor => abort naming it.
#   - QA_AUTH_TOKEN: Bearer token for a TENANT_ADMIN user in the vortex tenant.
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
#   - Run AFTER scripts/seed_vortex_definition.sh.
#
# Usage:
#   QA_AUTH_TOKEN="<token>" bash scripts/seed_vortex_persona_actors.sh
#
# Assumption: the persona -> role mapping comes from the scenario `actors:` blocks
# (test/fixtures/uat/scenarios/vortex/*.yaml) and
# test/fixtures/simulation/vortex/org_structure.yaml; greta -> role-finance-director (REQ-471, name proposed, BA-VORTEX confirms) and dirk -> role-ceo are inferred
# from org structure, not stated verbatim. Role groups are the authoritative part;
# a BA may amend the PERSONAS table only.
# TASK_WORKER is implicit for every persona and never listed below.
#
# role-procurement-manager is seeded because the 8D Corrective Action child
# definition (ISS-0929) routes its HUMAN_TASK to it.
#
# Design: lib/letflow/design/iss0931-meridian-vortex-persona-actor-provisioning.md

set -euo pipefail

ROLES=(
  "role-production-manager"
  "role-controller"
  "role-quality-manager"
  "role-ceo"
  "role-procurement-manager"
  "role-finance-director"
)
PERSONAS=(
  "actor-vortex-sabine|role-production-manager"
  "actor-vortex-stefan|role-controller"
  "actor-vortex-karl|role-quality-manager"
  "actor-vortex-dirk|role-ceo"
  "actor-vortex-greta|role-finance-director"
  "actor-vortex-anna|"
  "actor-vortex-nina|"
  "actor-vortex-felix|role-procurement-manager"
  "actor-vortex-max|"
  "actor-vortex-claudia|"
)

source "$(dirname "${BASH_SOURCE[0]}")/lib/seed_persona_actors_base.sh"

persona_require_env
persona_run vortex
