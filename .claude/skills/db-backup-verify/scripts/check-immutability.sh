#!/usr/bin/env bash
# check-immutability.sh — verify that the backups are actually immutable, rather
# than merely configured to look that way.
#
#   check-immutability.sh token     probe the server's R2 credential's tier
#   check-immutability.sh lock      assert a bucket lock rule exists
#   check-immutability.sh all       both
#
# WHY BOTH CHECKS ARE NEEDED
#
# R2 has no write-only token scope. The four tiers are Admin Read & Write, Admin
# Read only, Object Read & Write, Object Read only, and only the two Object
# tiers can be scoped to specific buckets. So the credential that writes your
# backups can also delete them — there is no way to hand out append-only access.
#
# The usual conclusion is "use bucket locks instead of credential scoping". That
# is half right and dangerously incomplete: an **Admin**-tier token can edit
# bucket configuration, which means it can REMOVE THE LOCK and then delete
# everything. The 30-day guarantee only holds when both are true:
#
#   1. a bucket lock rule exists, AND
#   2. the server's credential is Object-tier, so it cannot touch bucket config
#
# Lock AND scoping, never lock instead of scoping. This script checks both,
# because checking either one alone gives false confidence.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../../../infra/lib/common.sh"

R2_REMOTE="${R2_REMOTE:-r2}"
R2_BUCKET="${R2_BUCKET:?set R2_BUCKET}"
R2_PREFIX="${R2_PREFIX:-postgres/}"

# Creating a bucket is an Admin-only operation. An Object-tier token gets
# AccessDenied. So: try it, and require failure. If it succeeds, the token on
# the server is far too powerful and the bucket lock it relies on is removable —
# we clean up the probe bucket and fail loudly.
cmd_token() {
  need_cmd rclone
  local probe="tier-probe-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"

  log "probing credential tier by attempting an Admin-only operation"
  if rclone mkdir "$R2_REMOTE:$probe" >/dev/null 2>&1; then
    rclone rmdir "$R2_REMOTE:$probe" >/dev/null 2>&1 || \
      warn "could not clean up probe bucket '$probe' — delete it manually"
    die "the configured R2 credential can CREATE BUCKETS, so it is Admin-tier.
     An Admin token can edit bucket configuration and therefore remove the
     bucket lock, which makes your 30-day immutability decorative.
     Replace it with an Object Read & Write token scoped to '$R2_BUCKET'."
  fi
  ok "credential cannot create buckets — consistent with Object-tier"

  # It must still be able to do its actual job.
  rclone lsf --max-depth 1 "$R2_REMOTE:$R2_BUCKET/" >/dev/null 2>&1 \
    || die "credential cannot list $R2_BUCKET — check the bucket scope"
  ok "credential can read the backup bucket"

  warn "also confirm in the dashboard that this is an ACCOUNT API token, not a User token"
  warn "User tokens go inactive when that user leaves the account, and backups fail silently"
}

# Wrangler's flag spelling for bucket locks has moved between versions, so
# nothing here hardcodes it. What matters is that a rule EXISTS covering the
# backup prefix — that is the property, and `list` is how you observe it.
cmd_lock() {
  need_cmd npx

  log "listing bucket lock rules on $R2_BUCKET"
  local out
  if ! out="$(npx --yes wrangler r2 bucket lock list "$R2_BUCKET" 2>&1)"; then
    printf '%s\n' "$out" >&2
    warn "could not list lock rules. Current syntax for adding one:"
    npx --yes wrangler r2 bucket lock add --help 2>&1 | sed 's/^/    /' >&2 || true
    die "no verifiable bucket lock on $R2_BUCKET"
  fi

  printf '%s\n' "$out" | sed 's/^/    /' >&2

  if printf '%s' "$out" | grep -qiE 'no .*rules|^\s*$'; then
    warn "no lock rules configured. Add one, then re-run this check. Roughly:"
    warn "  npx wrangler r2 bucket lock add $R2_BUCKET   # see --help for current flags"
    die "bucket lock missing — a compromised server could erase every backup"
  fi

  # The rule has to actually cover where the dumps go. A lock scoped to a
  # different prefix is a lock on nothing.
  if printf '%s' "$out" | grep -q "$R2_PREFIX"; then
    ok "a lock rule references the backup prefix '$R2_PREFIX'"
  else
    warn "no rule visibly mentions '$R2_PREFIX' — confirm the rule's prefix covers the dumps, or it protects nothing"
  fi

  ok "bucket lock rules present on $R2_BUCKET"
  warn "reminder: a bucket cannot be EMPTIED while lock rules exist — teardown must remove the rules first, deliberately"
}

case "${1:-all}" in
  token) cmd_token ;;
  lock)  cmd_lock ;;
  all)   cmd_token; echo >&2; cmd_lock ;;
  *) printf 'usage: %s {token|lock|all}\n' "$(basename "$0")" >&2; exit 2 ;;
esac
