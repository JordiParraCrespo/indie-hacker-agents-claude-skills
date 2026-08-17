#!/usr/bin/env bash
# restore-drill.sh — prove the backups can actually be restored.
#
# Runs from your machine (or a scheduled admin host), because this is the one
# place the age PRIVATE key is used. It never touches the app server.
#
#   restore-drill.sh run          full drill against the newest remote dump
#   restore-drill.sh negative     feed it a corrupted dump; the drill MUST fail
#
# A backup system is a hypothesis until a restore confirms it. This script is
# the experiment, and its failure is the one alert worth waking someone for.
#
# It also proves something people forget to test: that the decryption key still
# opens the backups. An escrowed key that has quietly rotated or corrupted turns
# every stored dump into noise, and nothing else in the pipeline would notice.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../../../infra/lib/common.sh"

R2_REMOTE="${R2_REMOTE:-r2}"
R2_BUCKET="${R2_BUCKET:?set R2_BUCKET}"
R2_PREFIX="${R2_PREFIX:-postgres/}"
AGE_IDENTITY="${AGE_IDENTITY:?set AGE_IDENTITY to the private key file — supplied at run time, never stored on the app server}"
ASSERTIONS="${ASSERTIONS:-$HERE/../assets/assertions.sql}"
DRILL_PASSWORD="drill-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"

need_cmd rclone; need_cmd age; need_cmd docker

WORK="$(mktemp -d)"; CONTAINER="pgdrill-$$"
cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------ fetch ---
fetch_newest() {
  local name
  name="$(rclone lsf --files-only "$R2_REMOTE:$R2_BUCKET/$R2_PREFIX" 2>/dev/null \
          | grep '\.pgc\.age$' | sort | tail -1 || true)"
  [ -n "$name" ] || die "no dump found in $R2_REMOTE:$R2_BUCKET/$R2_PREFIX"
  log "newest remote dump: $name"
  rclone copyto "$R2_REMOTE:$R2_BUCKET/$R2_PREFIX$name" "$WORK/$name"
  rclone copyto "$R2_REMOTE:$R2_BUCKET/$R2_PREFIX$name.sha256" "$WORK/$name.sha256" 2>/dev/null || true
  printf '%s' "$name"
}

verify_checksum() {
  local name="$1"
  if [ -f "$WORK/$name.sha256" ]; then
    ( cd "$WORK" && sha256sum -c "$name.sha256" >/dev/null 2>&1 ) \
      && ok "checksum matches — the object survived the round trip intact" \
      || die "checksum mismatch on the downloaded dump"
  else
    warn "no .sha256 alongside the dump — cannot verify transfer integrity"
  fi
}

decrypt() {
  local name="$1"
  age -d -i "$AGE_IDENTITY" -o "$WORK/dump.pgc" "$WORK/$name" 2>/dev/null \
    || die "decryption failed — the escrowed key does not open this dump. Every backup is unreadable until this is resolved."
  ok "decrypted with the escrowed key"
}

# Restoring into a NEWER major generally works, which is exactly the danger: a
# drill that has drifted to a newer Postgres than production passes happily
# while testing a code path production never takes. Match the source major, or
# the drill is telling you about a system you don't run.
source_major() {
  local v
  v="$(pg_restore -l "$WORK/dump.pgc" 2>/dev/null \
        | sed -n 's/^;[[:space:]]*Dumped from database version:[[:space:]]*\([0-9]\{1,\}\).*/\1/p' | head -1)"
  [ -n "$v" ] || die "could not read the source Postgres major version from the dump header"
  printf '%s' "$v"
}

# -------------------------------------------------------------- the drill ---
cmd_run() {
  local name major image
  name="$(fetch_newest)"
  verify_checksum "$name"
  decrypt "$name"

  major="$(source_major)"
  image="${DRILL_IMAGE:-postgres:${major}-alpine}"
  log "source was Postgres $major — restoring into $image"

  docker run -d --rm --name "$CONTAINER" \
    -e POSTGRES_PASSWORD="$DRILL_PASSWORD" \
    -e POSTGRES_DB=drill \
    "$image" >/dev/null || die "could not start $image"

  log "waiting for the throwaway instance"
  for _ in $(seq 1 60); do
    docker exec "$CONTAINER" pg_isready -q -U postgres >/dev/null 2>&1 && break
    sleep 1
  done
  docker exec "$CONTAINER" pg_isready -q -U postgres >/dev/null 2>&1 \
    || die "throwaway Postgres never became ready"

  # Assert the container really is the major we asked for, in case the tag
  # moved underneath us.
  local got
  got="$(docker exec "$CONTAINER" psql -U postgres -tAc 'SHOW server_version' | cut -d. -f1)"
  [ "$got" = "$major" ] \
    || die "drill container is Postgres $got but the dump came from $major — this drill would not test production's code path"
  ok "drill container major version matches the source ($major)"

  log "restoring"
  docker cp "$WORK/dump.pgc" "$CONTAINER:/tmp/dump.pgc"
  docker exec "$CONTAINER" pg_restore -U postgres -d drill --no-owner --no-privileges /tmp/dump.pgc \
    || die "pg_restore failed — this backup is not restorable"
  ok "restore completed"

  # ------------------------------------------------------------ assertions --
  # A restore that "succeeds" into an empty database is the classic false pass.
  # The assertions are what turn "pg_restore exited 0" into "the data is there".
  [ -f "$ASSERTIONS" ] || die "no assertions file at $ASSERTIONS — a drill without assertions proves only that pg_restore ran"

  docker cp "$ASSERTIONS" "$CONTAINER:/tmp/assertions.sql"
  local out
  out="$(docker exec "$CONTAINER" psql -U postgres -d drill -tA -F'|' -f /tmp/assertions.sql)" \
    || die "assertions query failed to run"

  local failed=0
  while IFS='|' read -r check passed detail; do
    [ -n "${check:-}" ] || continue
    case "$passed" in
      t|true|1) ok    "assertion: $check ${detail:+($detail)}" ;;
      *)        warn  "assertion FAILED: $check ${detail:+($detail)}"; failed=1 ;;
    esac
  done <<< "$out"
  [ "$failed" -eq 0 ] || die "restored data did not satisfy the assertions"

  ok "DRILL PASSED — $name restores, decrypts, and contains what it should"
}

# The alarm nobody has ever seen fire is not an alarm. This corrupts a copy of a
# real dump and requires the drill to reject it, which tests the failure path
# rather than the happy one.
cmd_negative() {
  local name
  name="$(fetch_newest)"
  log "corrupting a copy to confirm the drill rejects it"
  dd if=/dev/urandom of="$WORK/$name" bs=1 seek=64 count=512 conv=notrunc status=none

  if age -d -i "$AGE_IDENTITY" -o "$WORK/dump.pgc" "$WORK/$name" 2>/dev/null \
     && pg_restore -l "$WORK/dump.pgc" >/dev/null 2>&1; then
    die "NEGATIVE TEST FAILED — a corrupted dump was accepted. The drill cannot detect a bad backup, so a green drill means nothing."
  fi
  ok "negative test passed — corruption is detected and would fail the drill"
}

case "${1:-run}" in
  run)      cmd_run ;;
  negative) cmd_negative ;;
  *) printf 'usage: %s {run|negative}\n' "$(basename "$0")" >&2; exit 2 ;;
esac
