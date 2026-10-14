#!/usr/bin/env bash
# Redeploy letflow to the QA environment on ubuntu-16gb-nbg1-1 (qa.bizdala.com).
# Run as the QA deploy account (or root), on the host:
#   bash /opt/apps/letflow-qa/deploy/redeploy-qa.sh
#
# Relationship to deploy/redeploy-test.sh: this is a SIBLING script, not a
# replacement. redeploy-test.sh targets a different host/path/Compose
# project (/opt/apps/letflow-test on hetzner-prod, Compose project
# letflow-test) and is untouched by REQ-367 -- it still exists to serve its
# own (currently unwired) target. This script targets the real QA
# deployment: /opt/apps/letflow-qa on ubuntu-16gb-nbg1-1, Compose project
# letflow-qa, serving qa.bizdala.com. The two are independent -- deploying
# QA never touches letflow-test and vice versa.
#
# Unlike redeploy-test.sh (backend-only), a QA redeploy has TWO artefacts:
# the backend Docker image and a separately-built frontend static bundle
# (no Node installed on the host -- built in a throwaway node:22 container
# and atomically swapped into place). See steps 4-5 below.
#
# Invoked two ways, mirroring redeploy-test.sh's own precedent
# (ai-dala-infra's T-0111):
#   1. Manually, per ai-dala-infra's deploy-app workflow.
#   2. Automatically, by .github/workflows/cd.yml over a restricted SSH
#      deploy key after CI passes on a push to main. The command=
#      restriction on that key invokes this exact script -- nothing else.
set -euo pipefail

APP_DIR=/opt/apps/letflow-qa
WEB_DIST_DIR="$APP_DIR/web-dist"
COMPOSE="docker compose --project-directory $APP_DIR -f $APP_DIR/deploy/docker-compose.qa.yml"
DATE=$(date +%Y%m%d)
# Sub-day timestamp for the web-dist backup specifically (step 5) -- a
# same-day redeploy must not clobber an earlier same-day backup, unlike
# redeploy-test.sh's day-granularity $DATE, which is precise enough for its
# own single (image-tag) use.
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

echo "=== letflow QA redeploy: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# 1. Pull latest code (public repo -- no credential injection needed)
cd "$APP_DIR"
git pull
CURRENT_REF=$(git rev-parse --short HEAD)
echo "Git ref: $CURRENT_REF"

# 2. Tag rollback image (best-effort -- ignore if it doesn't exist yet, e.g. first run)
docker tag letflow-qa:latest "letflow-qa:rollback-${DATE}" 2>/dev/null || true

# 3. Build backend image (same shared deploy Dockerfile redeploy-test.sh builds from)
echo "--- Building backend image ---"
# GIT_SHA (full 40-char commit) is baked into the image as LETFLOW_BUILD_SHA and
# reported by GET /health as `sha` (ISS-1043), so the WF-05 preflight can tell
# which build is deployed.
docker build -f deploy/Dockerfile --build-arg GIT_SHA="$(git rev-parse HEAD)" -t letflow-qa:latest .

# 4. Start/restart db first so it's healthy before app boots (app's compose
#    depends_on already enforces this, but an explicit up here keeps the
#    db container from being torn down and recreated on every redeploy).
echo "--- Ensuring db is up ---"
$COMPOSE up -d db

# 5. Restart app container (Ecto migrations run automatically on boot via
#    Ecto.Migrator in the supervision tree -- see lib/letflow/application.ex)
echo "--- Restarting backend app ---"
$COMPOSE up -d --force-recreate app

# 6. Frontend: throwaway-container rebuild.
#    No Node installed on the host -- matches the minimal-footprint
#    precedent and ci.yml's own frontend job pinning Node 22.
#
#    Real VITE_OIDC_AUTHORITY/VITE_OIDC_CLIENT_ID build args are sourced
#    from a host-local env file, $APP_DIR/qa.env, rather than hardcoded
#    here or passed as new GitHub Actions secrets -- this convention
#    mirrors the manual QA-deploy precedent (ai-dala-infra T-0125/T-0128/
#    T-0129/T-0131) of a host-local env file holding QA's real values.
#    Confirm the exact file name/path against actual host state; adjust
#    this sourcing line if the host uses a different name.
# shellcheck disable=SC1091
source "$APP_DIR/qa.env"
: "${VITE_OIDC_AUTHORITY:?VITE_OIDC_AUTHORITY must be set in $APP_DIR/qa.env}"
: "${VITE_OIDC_CLIENT_ID:?VITE_OIDC_CLIENT_ID must be set in $APP_DIR/qa.env}"
# Backend health-check port: also sourced from qa.env rather than assumed
# to carry over from redeploy-test.sh's 3113 (open question -- the QA
# host's actual published backend port was not confirmed at design time;
# see lib/letflow/design/req367-cd-qa-deploy.md §7 item 4). Defaults to
# 3113 only if qa.env doesn't set it, matching redeploy-test.sh's value as
# the most plausible starting point -- confirm against the host's real
# docker-compose.qa.yml port mapping and correct qa.env if it differs.
BACKEND_PORT="${QA_BACKEND_PORT:-3113}"

STAGING_DIR="$APP_DIR/web-dist-staging-${TIMESTAMP}"

echo "--- Building frontend bundle (throwaway node:22 container) ---"
docker run --rm \
  -v "$APP_DIR/web:/work" \
  -w /work \
  -e VITE_OIDC_AUTHORITY="$VITE_OIDC_AUTHORITY" \
  -e VITE_OIDC_CLIENT_ID="$VITE_OIDC_CLIENT_ID" \
  node:22 \
  sh -c "npm ci && npm run build"

# Build output written to a fresh staging directory outside the live
# web-dist directory -- never building directly into the path nginx is
# currently serving from. This separation is what the atomic swap below
# depends on.
mkdir -p "$STAGING_DIR"
cp -r "$APP_DIR/web/dist/." "$STAGING_DIR/"

# 7. Frontend: atomic swap with backup.
#    Back up the current live bundle before replacing it.
echo "--- Swapping frontend bundle into place ---"
if [[ -d "$WEB_DIST_DIR" ]]; then
  mv "$WEB_DIST_DIR" "${WEB_DIST_DIR}-backup-${TIMESTAMP}"
fi
# Single rename on the same filesystem so it completes atomically -- nginx
# never observes a partially-populated directory. No nginx reload/restart:
# nginx serves this directory path directly, and the rename is transparent
# to new requests once it completes.
mv "$STAGING_DIR" "$WEB_DIST_DIR"

# 8. Health check: backend (retry for up to 30 s, same shape as redeploy-test.sh)
echo "--- Health check: backend ---"
for i in $(seq 1 10); do
  STATUS=$(curl -sf "http://127.0.0.1:${BACKEND_PORT}/health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)
  if [[ "$STATUS" == "ok" ]]; then
    echo "Backend health check passed (attempt $i)"
    break
  fi
  if [[ $i -eq 10 ]]; then
    echo "ERROR: backend health check did not pass after 10 attempts" >&2
    exit 1
  fi
  echo "Waiting... ($i/10)"
  sleep 3
done

# 9. Health check: frontend. New check, not present in redeploy-test.sh
#    (that script has no separate frontend artefact). A single HTTPS
#    request to the public QA site's root URL -- through nginx and TLS,
#    not a local port -- since there is no frontend container/process to
#    health-check directly; this checks the served shell.
echo "--- Health check: frontend ---"
if ! curl -sf -o /dev/null "https://qa.bizdala.com/"; then
  echo "ERROR: frontend health check (https://qa.bizdala.com/) failed" >&2
  exit 1
fi
echo "Frontend health check passed"

# 10. Retention for the web-dist backups made in step 7 (GH 2352). Last on purpose: a deploy
#     that fails a health check exits before this, so every backup stays available for a
#     rollback until the next successful deploy. Keep-last-N, N from WEB_DIST_BACKUP_KEEP
#     (qa.env or the environment), default 20 (infra T-0179). A prune problem, or a missing
#     helper, is a warning only and never fails the deploy.
WEB_DIST_BACKUP_KEEP="${WEB_DIST_BACKUP_KEEP:-20}"
if [[ -r "$APP_DIR/deploy/lib/prune_web_dist_backups.sh" ]]; then
  # shellcheck disable=SC1091
  source "$APP_DIR/deploy/lib/prune_web_dist_backups.sh"
  prune_web_dist_backups "$APP_DIR" "$WEB_DIST_BACKUP_KEEP" || echo "WARN: web-dist-backup prune failed (ignored)" >&2
else
  echo "WARN: deploy/lib/prune_web_dist_backups.sh not found; web-dist backups not pruned" >&2
fi

echo "=== Done. Deployed ref: $CURRENT_REF ==="
