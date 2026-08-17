#!/usr/bin/env bash
# Shared helpers for the infrastructure skills.
#
# Source this, don't execute it:
#     . "$(dirname "$0")/../../infra/lib/common.sh"
#
# Everything here is provider-agnostic. The only assumptions are Ubuntu LTS,
# Docker, ufw, and a POSIX shell. The host is always a variable.

set -euo pipefail

# ---------------------------------------------------------------- output ----
# Diagnostics go to stderr so a script's stdout stays machine-readable.

_c() { if [ -t 2 ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }

log()  { printf '%s %s\n' "$(_c '0;36' '::')" "$*" >&2; }
ok()   { printf '%s %s\n' "$(_c '0;32' 'ok')" "$*" >&2; }
warn() { printf '%s %s\n' "$(_c '0;33' 'warn')" "$*" >&2; }
die()  { printf '%s %s\n' "$(_c '0;31' 'fail')" "$*" >&2; exit 1; }

# assert <description> <command...>
# Runs the command, reports, and aborts on failure. Assertions are the point of
# these scripts: a command that "succeeded" is not evidence that the system is
# in the state you wanted. Check the state, not the exit code of the change.
assert() {
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then
    ok "$what"
  else
    die "assertion failed: $what"
  fi
}

# refute <description> <command...>  — the assertion's negative twin.
refute() {
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then
    die "assertion failed (expected NOT to hold): $what"
  else
    ok "$what"
  fi
}

# --------------------------------------------------------------- targets ----
# Targets are named (staging / prod), never raw IPs in a command line. Naming
# them means a script can refuse to run the dangerous variant against prod
# without a human saying so out loud.

TARGETS_ENV="${TARGETS_ENV:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/targets.env}"

load_targets() {
  [ -f "$TARGETS_ENV" ] || die "no targets file at $TARGETS_ENV — copy infra/targets.env.example and fill it in"
  # shellcheck disable=SC1090
  . "$TARGETS_ENV"
}

# resolve_host <staging|prod> -> prints the Tailscale hostname
resolve_host() {
  load_targets
  case "${1:-}" in
    staging) printf '%s' "${STAGING_HOST:?STAGING_HOST unset in $TARGETS_ENV}" ;;
    prod)    printf '%s' "${PROD_HOST:?PROD_HOST unset in $TARGETS_ENV}" ;;
    *)       die "unknown target '${1:-}' — expected 'staging' or 'prod'" ;;
  esac
}

# require_target — validates $1 and exports TARGET / TARGET_HOST.
require_target() {
  TARGET="${1:-}"
  [ -n "$TARGET" ] || die "usage: $(basename "$0") <staging|prod> [...]"
  TARGET_HOST="$(resolve_host "$TARGET")"
  export TARGET TARGET_HOST
}

# confirm_prod — a deliberate speed bump, not security theatre.
#
# Anything irreversible against prod should cost a sentence of typing. The
# phrase is the target name so muscle memory from staging doesn't carry over.
confirm_prod() {
  [ "${TARGET:-}" = "prod" ] || return 0
  [ "${ASSUME_YES:-}" = "1" ] && { warn "ASSUME_YES=1 — skipping prod confirmation"; return 0; }
  [ -t 0 ] || die "refusing an irreversible prod action from a non-interactive shell (set ASSUME_YES=1 only if you mean it)"
  printf 'About to run an irreversible action against PROD (%s).\nType the word prod to continue: ' "$TARGET_HOST" >&2
  local answer; read -r answer
  [ "$answer" = "prod" ] || die "aborted"
}

# ------------------------------------------------------------------- ssh ----
# Admin access is Tailscale-only. BatchMode makes a missing key an immediate
# error rather than an interactive password prompt that hangs a script.

SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new}"

# on_target <command...> — run a command on the target over the tailnet.
on_target() {
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$TARGET_HOST" "$@"
}

# push_script <local-path> — copy a script to the target and print its path.
push_script() {
  local src="$1" dst
  dst="/tmp/$(basename "$src").$$"
  # shellcheck disable=SC2086
  scp $SSH_OPTS -q "$src" "$TARGET_HOST:$dst"
  on_target "chmod +x $dst"
  printf '%s' "$dst"
}

# --------------------------------------------------------------- tailnet ----
# Tailscale hands out addresses in 100.64.0.0/10 (the CGNAT range). Recognising
# that range is how a script tells an admin-plane connection from a public one.

is_tailnet_addr() {
  case "${1:-}" in
    100.*) local second="${1#100.}"; second="${second%%.*}"
           [ "$second" -ge 64 ] 2>/dev/null && [ "$second" -le 127 ] 2>/dev/null ;;
    *)     return 1 ;;
  esac
}

# count_tailnet_ssh_sessions — established inbound SSH connections whose peer is
# on the tailnet. Used to prove admin access works *before* removing public SSH.
count_tailnet_ssh_sessions() {
  local n=0 peer addr
  while read -r peer; do
    addr="${peer%:*}"; addr="${addr#[}"; addr="${addr%]}"
    is_tailnet_addr "$addr" && n=$((n + 1))
  done < <(ss -Htn state established '( sport = :22 )' 2>/dev/null | awk '{print $5}')
  printf '%d' "$n"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
