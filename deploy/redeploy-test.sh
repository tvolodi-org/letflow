#!/usr/bin/env bash
# Redeploy letflow to the test environment on hetzner-prod.
# Run as root (or the CD deploy account) on the host:
#   bash /opt/apps/letflow-test/deploy/redeploy-test.sh
#
# Invoked two ways, mirroring the sibling letflow-queue repo's precedent
# (ai-dala-infra's T-0108):
#   1. Manually, per ai-dala-infra's deploy-app workflow.
#   2. Automatically, by .github/workflows/cd.yml over a restricted SSH
#      deploy key after CI passes on a push to master. The command=
#      restriction on that key invokes this exact script — nothing else.
set -euo pipefail

APP_DIR=/opt/apps/letflow-test
COMPOSE="docker compose --project-directory $APP_DIR -f $APP_DIR/deploy/docker-compose.test.yml"
DATE=$(date +%Y%m%d)

echo "=== letflow test redeploy: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# 1. Pull latest code (public repo — no credential injection needed)
cd "$APP_DIR"
git pull
CURRENT_REF=$(git rev-parse --short HEAD)
echo "Git ref: $CURRENT_REF"

# 2. Tag rollback image (best-effort — ignore if it doesn't exist yet, e.g. first run)
docker tag letflow-test:latest "letflow-test:rollback-${DATE}" 2>/dev/null || true

# 3. Build image
echo "--- Building image ---"
# GIT_SHA (full 40-char commit) is baked into the image as LETFLOW_BUILD_SHA and
# reported by GET /health as `sha` (ISS-1043).
docker build -f deploy/Dockerfile --build-arg GIT_SHA="$(git rev-parse HEAD)" -t letflow-test:latest .

# 4. Start/restart db first so it's healthy before app boots (app's compose
#    depends_on already enforces this, but an explicit up here keeps the
#    db container from being torn down and recreated on every redeploy).
echo "--- Ensuring db is up ---"
$COMPOSE up -d db

# 5. Restart app container (Ecto migrations run automatically on boot via
#    Ecto.Migrator in the supervision tree — see lib/letflow/application.ex)
echo "--- Restarting app ---"
$COMPOSE up -d --force-recreate app

# 6. Health check (retry for up to 30 s)
echo "--- Health check ---"
for i in $(seq 1 10); do
  STATUS=$(curl -sf http://127.0.0.1:3113/health | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)
  if [[ "$STATUS" == "ok" ]]; then
    echo "Health check passed (attempt $i)"
    break
  fi
  if [[ $i -eq 10 ]]; then
    echo "ERROR: health check did not pass after 10 attempts" >&2
    exit 1
  fi
  echo "Waiting... ($i/10)"
  sleep 3
done

echo "=== Done. Deployed ref: $CURRENT_REF ==="
