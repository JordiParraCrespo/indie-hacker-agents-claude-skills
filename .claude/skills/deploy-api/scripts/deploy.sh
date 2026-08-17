#!/usr/bin/env bash
# deploy.sh — build, migrate, health-check, and roll back on failure.
#
#   deploy.sh staging          deploy to staging
#   deploy.sh prod             deploy to prod (requires a green staging deploy)
#   deploy.sh <target> --skip-migrations
#
# Reads deploy.manifest.json rather than inferring the stack, so the same
# pipeline works for Go, Python, Node, or anything else that builds to a
# container and answers a health check.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO/infra/lib/common.sh"

MANIFEST="${MANIFEST:-$REPO/deploy.manifest.json}"
STATE_DIR="${STATE_DIR:-$REPO/.deploy-state}"
SKIP_MIGRATIONS=0

require_target "${1:-}"; shift || true
for arg in "$@"; do
  case "$arg" in
    --skip-migrations) SKIP_MIGRATIONS=1 ;;
    *) die "unknown option: $arg" ;;
  esac
done

need_cmd jq; need_cmd docker
[ -f "$MANIFEST" ] || die "no deploy manifest at $MANIFEST — copy assets/deploy.manifest.json and fill it in"
mkdir -p "$STATE_DIR"

m() { jq -r "$1 // empty" "$MANIFEST"; }

SERVICE="$(m .service)";        [ -n "$SERVICE" ] || die "manifest is missing .service"
PORT="$(m .listen_port)";       [ -n "$PORT" ]    || die "manifest is missing .listen_port"
HEALTH_PATH="$(m .health.path)"; [ -n "$HEALTH_PATH" ] || die "manifest is missing .health.path"
HEALTH_CODE="$(m .health.expect_status)"; HEALTH_CODE="${HEALTH_CODE:-200}"
HEALTH_TIMEOUT="$(m .health.timeout_seconds)"; HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"
COMPOSE_FILE="$REPO/$(m ".environments.\"$TARGET\".compose_file")"
OVERRIDE="$(m ".environments.\"$TARGET\".compose_override")"

COMPOSE=(docker compose -f "$COMPOSE_FILE")
[ -n "$OVERRIDE" ] && [ -f "$REPO/$OVERRIDE" ] && COMPOSE+=(-f "$REPO/$OVERRIDE")

remote() { on_target "cd ${REMOTE_DIR:-/srv/app} && $*"; }

# ---------------------------------------------------------------- preflight --
log "target: $TARGET ($TARGET_HOST)"

# Invariants first: cheap, local, and a violation here means the firewall
# guarantees do not hold. No point building an image we would refuse to ship.
"$HERE/check-invariants.sh" "$COMPOSE_FILE"

# Promotion gate. Prod deploys are meant to ship an artifact staging already
# proved, not a fresh guess — otherwise the second server is just expense.
if [ "$TARGET" = "prod" ] && [ "${ALLOW_UNSTAGED:-0}" != "1" ]; then
  [ -f "$STATE_DIR/staging.green" ] \
    || die "no green staging deploy recorded — deploy to staging first (ALLOW_UNSTAGED=1 to override, deliberately)"
  staged_sha="$(cat "$STATE_DIR/staging.green")"
  current_sha="$(git -C "$REPO" rev-parse HEAD)"
  [ "$staged_sha" = "$current_sha" ] \
    || die "staging is green for $staged_sha but HEAD is $current_sha — deploy this commit to staging first"
  ok "promoting the commit staging already verified"
fi

# Migration reversibility. Establishing this BEFORE touching anything is the
# point: once a destructive migration has run, the conversation about whether
# you can undo it is over.
if [ "$SKIP_MIGRATIONS" -eq 0 ]; then
  if [ "$(m .migrate.irreversible)" = "true" ]; then
    warn "this migration is marked IRREVERSIBLE: $(m .migrate.irreversible_reason)"
    warn "the restore drill IS your rollback path here — verifying backup freshness"
    "$REPO/.claude/skills/db-backup-verify/scripts/upload.sh" check \
      || die "backups are not fresh, and an irreversible migration with no recent backup is unrecoverable"
    confirm_prod
  else
    [ -n "$(m .migrate.down)" ] \
      || die "manifest declares a reversible migration but provides no .migrate.down — declare the down path or mark it irreversible"
  fi
fi

confirm_prod

# ------------------------------------------------------------------- build ---
GIT_SHA="$(git -C "$REPO" rev-parse --short HEAD)"
log "building $SERVICE at $GIT_SHA"
"${COMPOSE[@]}" build "$SERVICE"

# Record what is running now, so rollback has somewhere to go back TO. Doing
# this after the build and before the swap is deliberate — it captures the last
# known-good state.
PREV_DIGEST="$(remote "docker inspect --format '{{.Image}}' \$(docker compose ps -q $SERVICE) 2>/dev/null" || true)"
if [ -n "$PREV_DIGEST" ]; then
  printf '%s' "$PREV_DIGEST" > "$STATE_DIR/$TARGET.previous"
  ok "recorded previous image for rollback: ${PREV_DIGEST:0:20}"
else
  warn "no previously running container — first deploy, so there is nothing to roll back to"
fi

# --------------------------------------------------------------- migrate ----
if [ "$SKIP_MIGRATIONS" -eq 0 ] && [ -n "$(m .migrate.up)" ]; then
  log "applying migrations"
  if ! remote "docker compose run --rm $SERVICE $(m .migrate.up)"; then
    warn "migration failed — attempting the declared down path"
    if [ "$(m .migrate.irreversible)" != "true" ] && [ -n "$(m .migrate.down)" ]; then
      remote "docker compose run --rm $SERVICE $(m .migrate.down)" \
        && die "migration failed and was rolled back — nothing was deployed" \
        || die "migration failed AND the down path failed. Restore from backup: restore-drill.sh documents the procedure."
    fi
    die "migration failed and is marked irreversible — restore from backup"
  fi
  ok "migrations applied"
fi

# ------------------------------------------------------------------ deploy ---
log "starting $SERVICE"
remote "docker compose up -d --no-deps $SERVICE"

# --------------------------------------------------------------- health -----
# Poll from inside the network. Going via the tunnel would conflate "the app is
# broken" with "Cloudflare is having a moment", and during a deploy you need to
# know which.
log "waiting for health (${HEALTH_TIMEOUT}s budget)"
deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
healthy=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  code="$(remote "docker compose exec -T $SERVICE sh -c 'command -v curl >/dev/null && curl -s -o /dev/null -w %{http_code} http://localhost:$PORT$HEALTH_PATH || wget -q -O /dev/null -S http://localhost:$PORT$HEALTH_PATH 2>&1 | sed -n \"s/.*HTTP\\/[0-9.]* \\([0-9]*\\).*/\\1/p\" | head -1'" 2>/dev/null || true)"
  if [ "$code" = "$HEALTH_CODE" ]; then healthy=1; break; fi
  sleep "$(m .health.interval_seconds || echo 2)"
done

if [ "$healthy" -ne 1 ]; then
  warn "health check did not pass — rolling back"
  "$HERE/rollback.sh" "$TARGET" || die "rollback ALSO failed — intervene manually over the tailnet"
  die "deploy failed health check and was rolled back"
fi
ok "health check passed"

# ------------------------------------------------------------------ record ---
if [ "$TARGET" = "staging" ]; then
  git -C "$REPO" rev-parse HEAD > "$STATE_DIR/staging.green"
  ok "staging green for $(git -C "$REPO" rev-parse --short HEAD) — this commit may now be promoted to prod"
fi

ok "deployed $SERVICE to $TARGET"
warn "the tunnel serves the new version now — check it end to end before walking away"
