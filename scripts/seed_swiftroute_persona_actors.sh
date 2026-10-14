#!/usr/bin/env bash
# seed_swiftroute_persona_actors.sh
#
# Provisions the letflow-side (Part B) of the SwiftRoute persona actors:
#   - Creates process-routing role groups + tenant_role bindings for every role
#     referenced by the SwiftRoute QA definitions (3 roles: role-ops-manager,
#     role-ceo, role-accountant -- the last added by ISS-1011 / Q-993)
#   - Adds each persona actor to TASK_WORKER (implicit) and to its role groups
#
# Migrated (ISS-1011 / Q-993) from the old standalone style to the shared
# scripts/lib/seed_persona_actors_base.sh used by the meridian and vortex scripts.
#
# PREREQUISITE (OQ-1): Part A must be completed first.
#   ai-dala-infra/scripts/qa-login.sh must have already created Keycloak accounts
#   for actor-swiftroute-lena, -marco, -alice, -hans and -tobias in the swiftroute
#   realm, and those accounts must have synced into letflow's users table before
#   this script runs. A persona with no account is skipped with a warning naming
#   it, every other persona is still seeded, and the script then exits non-zero
#   naming the missing actors (Part A guard). letflow creates a user on that account's
#   first authenticated request, so a Keycloak account that has never signed in counts as
#   missing: sign in as it once (or send one authenticated GET /api/v1/me/memberships with
#   its token), then re-run this script. Re-running is safe (GH 2345).
#
# Persona -> group mapping (§4 of the design doc; TASK_WORKER is implicit for all):
#   actor-swiftroute-lena   (Dispatcher)  -> TASK_WORKER only
#   actor-swiftroute-tobias (Dispatcher)  -> TASK_WORKER only (timeout scenario dispatcher;
#       dept-dispatch with lena in test/fixtures/simulation/swiftroute/org_structure.yaml;
#       no scenario or org file gives him a routing role, so none is granted)
#   actor-swiftroute-marco  (Ops Manager) -> TASK_WORKER + role-ops-manager
#   actor-swiftroute-alice  (CEO)         -> TASK_WORKER + role-ceo
#   actor-swiftroute-hans   (Accountant)  -> TASK_WORKER + role-accountant
#       (dept-finance; the finance-estimate task of the Driver Incident Report routes
#       to role-accountant, scenario swiftroute/driver-incident-assess-and-estimate.yaml)
#
# Prerequisites:
#   - curl and jq installed
#   - QA_AUTH_TOKEN: Bearer token for a PLATFORM_ADMIN user in the swiftroute tenant.
#       Must grant GroupsManage + RolesManage + UsersManage.
#   - QA_URL: base URL of the QA instance (default: https://qa.bizdala.com)
#
# Usage:
#   export QA_AUTH_TOKEN="<bearer-token>"
#   bash scripts/seed_swiftroute_persona_actors.sh
#
#   # Or override base URL:
#   QA_URL=https://qa.bizdala.com QA_AUTH_TOKEN="<token>" bash scripts/seed_swiftroute_persona_actors.sh
#
# Design source: lib/letflow/design/iss-0761-swiftroute-persona-actor-provisioning.md
# Issue: ISS-0739 / ISS-0761 / ISS-1011

set -euo pipefail

ROLES=(
  "role-ops-manager"
  "role-ceo"
  "role-accountant"
)
PERSONAS=(
  "actor-swiftroute-lena|"
  "actor-swiftroute-tobias|"
  "actor-swiftroute-marco|role-ops-manager"
  "actor-swiftroute-alice|role-ceo"
  "actor-swiftroute-hans|role-accountant"
)

source "$(dirname "${BASH_SOURCE[0]}")/lib/seed_persona_actors_base.sh"

persona_require_env
persona_run swiftroute
