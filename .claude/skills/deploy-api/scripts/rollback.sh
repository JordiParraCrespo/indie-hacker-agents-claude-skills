#!/usr/bin/env bash
# rollback.sh — put the previously running image back.
#
#   rollback.sh <staging|prod>
#
# Rolls back the CODE. It does not undo migrations, and pretending otherwise is
# how people lose data: re-running a down migration after new rows have been
# written to the new schema can discard them. See the note at the bottom.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO/infra/lib/common.sh"

MANIFEST="${MANIFEST:-$REPO/deploy.manifest.json}"
STATE_DIR="${STATE_DIR:-$REPO/.deploy-state}"

require_target "${1:-}"
need_cmd jq
SERVICE="$(jq -r '.service' "$MANIFEST")"

remote() { on_target "cd ${REMOTE_DIR:-/srv/app} && $*"; }

PREV_FILE="$STATE_DIR/$TARGET.previous"
[ -f "$PREV_FILE" ] || die "no recorded previous image for '$TARGET'.
     Nothing to roll back to — this was probably the first deploy.
     Recover by checking out the last known-good commit and deploying it."

PREV="$(cat "$PREV_FILE")"
log "rolling $SERVICE back to ${PREV:0:20} on $TARGET"

# Pin the service to the recorded image for this one `up`, rather than editing
# the compose file. The repo keeps describing the intended state; the rollback
# is an explicit, temporary override you can see in the command.
remote "docker compose up -d --no-deps --force-recreate \
        --pull never \
        $(printf 'IMAGE_OVERRIDE=%s ' "$PREV") $SERVICE" \
  || remote "docker tag $PREV ${SERVICE}:rollback && docker compose up -d --no-deps --force-recreate $SERVICE"

# Rollback is a change like any other, and the reason you are rolling back is
# that something was wrong — so verify rather than assume.
PORT="$(jq -r '.listen_port' "$MANIFEST")"
HEALTH_PATH="$(jq -r '.health.path' "$MANIFEST")"
HEALTH_CODE="$(jq -r '.health.expect_status // 200' "$MANIFEST")"

log "verifying the rolled-back version is healthy"
healthy=0
for _ in $(seq 1 30); do
  code="$(remote "docker compose exec -T $SERVICE sh -c 'curl -s -o /dev/null -w %{http_code} http://localhost:$PORT$HEALTH_PATH'" 2>/dev/null || true)"
  [ "$code" = "$HEALTH_CODE" ] && { healthy=1; break; }
  sleep 2
done

[ "$healthy" -eq 1 ] \
  || die "the rolled-back version is ALSO unhealthy — the problem is probably not the application code.
     Check the database (a half-applied migration?), disk space, and whether the
     data network is reachable. You have tailnet access: docker compose logs $SERVICE"

ok "rolled back to ${PREV:0:20} and healthy"

cat >&2 <<'NOTE'

Note on migrations: this rolled back the code, not the schema.

If the failed deploy applied a migration, the database is still on the new
schema. Whether that matters depends on the migration:

  - Additive (new column, new table, new index): the old code ignores it.
    Nothing more to do. This is why expand-contract is worth the discipline.

  - Destructive (dropped or renamed column, changed type): the old code is now
    running against a schema it does not understand. Running the down migration
    may work — but if the new code wrote rows in the meantime, the down path can
    discard them. Read the down migration before running it.

  - Irreversible: restore from backup. That is what the drill exists for, and
    why deploy.sh refuses irreversible migrations without a fresh backup.
NOTE
