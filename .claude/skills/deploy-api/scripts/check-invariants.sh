#!/usr/bin/env bash
# check-invariants.sh — fail the build if the compose file breaks a property the
# rest of the architecture depends on.
#
#   check-invariants.sh [path/to/compose.yml]
#
# These are the guarantees that are true today because somebody remembered, and
# whose violation is silent. "The stack publishes nothing to the host" is what
# makes ufw's deny-all meaningful; the moment a `ports:` line is added to debug
# something at 2am, ufw stops protecting that port and `ufw status` still looks
# perfect. Checking it mechanically is the difference between an invariant and
# an intention.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../../../infra/lib/common.sh"

COMPOSE_FILE="${1:-infra/compose.yml}"
[ -f "$COMPOSE_FILE" ] || die "no compose file at $COMPOSE_FILE"
need_cmd jq; need_cmd docker

# Resolve the file the way Docker will — after variable substitution, extends,
# and overrides. Checking the raw YAML would miss a port injected by an override
# file, which is precisely how this drifts in practice.
CONFIG="$(docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null)" \
  || die "docker compose could not parse $COMPOSE_FILE"

FAILURES=0
fail() { printf 'fail %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

# --- 1. nothing published to the host -------------------------------------
# The load-bearing one. ufw filters INPUT; Docker publishes through NAT and
# FORWARD, so a published port is reachable from the internet no matter what
# ufw says.
published="$(jq -r '
  .services | to_entries[]
  | select((.value.ports // []) | length > 0)
  | "\(.key): \((.value.ports // []) | map(tostring) | join(", "))"
' <<< "$CONFIG")"

if [ -n "$published" ]; then
  fail "services publish ports to the host — ufw does not filter these:"
  printf '%s\n' "$published" | sed 's/^/       /' >&2
  printf '       Reach services over the tailnet with `docker compose exec` instead.\n' >&2
else
  ok "no service publishes a port to the host"
fi

# --- 2. images pinned by digest -------------------------------------------
# A moving tag means an unreviewed binary arrives on the next restart, at a time
# you did not choose. unattended-upgrades patches the host, never containers —
# base images are updated deliberately or not at all.
unpinned="$(jq -r '
  .services | to_entries[]
  | select(.value.image != null)
  | select((.value.image | test("@sha256:[0-9a-f]{64}$")) | not)
  | "\(.key): \(.value.image)"
' <<< "$CONFIG")"

if [ -n "$unpinned" ]; then
  fail "images are not pinned by digest:"
  printf '%s\n' "$unpinned" | sed 's/^/       /' >&2
  printf '       Pin with: docker buildx imagetools inspect <image> --format "{{.Manifest.Digest}}"\n' >&2
else
  ok "all images are pinned by digest"
fi

# --- 3. the data network stays isolated ------------------------------------
# `internal: true` denies the database a route to the internet, which closes an
# exfiltration path. It is also why the backup job is split in two.
if jq -e '.networks.data.internal == true' >/dev/null 2>&1 <<< "$CONFIG"; then
  ok "the data network is internal"
else
  fail "network 'data' is not marked internal: true — Postgres would have a route to the internet"
fi

# --- 4. secrets are not environment variables ------------------------------
# Env vars show up in `docker inspect`, in /proc/<pid>/environ, and in logs and
# crash dumps. The official images support a *_FILE convention for exactly this.
inline_secrets="$(jq -r '
  .services | to_entries[] as $s
  | ($s.value.environment // {}) | to_entries[]
  | select(.key | test("PASSWORD|SECRET|TOKEN|APIKEY|API_KEY|PRIVATE_KEY"; "i"))
  | select((.key | test("_FILE$")) | not)
  | select(.value != null and (.value | tostring | length) > 0)
  | "\($s.key): \(.key)"
' <<< "$CONFIG")"

if [ -n "$inline_secrets" ]; then
  fail "secret-looking values passed as environment variables:"
  printf '%s\n' "$inline_secrets" | sed 's/^/       /' >&2
  printf '       Use Docker secrets and the *_FILE convention (POSTGRES_PASSWORD_FILE, etc).\n' >&2
else
  ok "no secrets passed inline via environment"
fi

# --- 5. Postgres is only on the data network -------------------------------
# A database attached to an internet-facing network defeats (3) without changing
# it, which makes this easy to miss in review.
pg_service="$(jq -r '.services | to_entries[] | select(.value.image // "" | test("postgres")) | .key' <<< "$CONFIG" | head -1)"
if [ -n "$pg_service" ]; then
  nets="$(jq -r --arg s "$pg_service" '.services[$s].networks | if type=="object" then keys else (. // []) end | join(",")' <<< "$CONFIG")"
  if [ "$nets" = "data" ]; then
    ok "postgres ('$pg_service') is only on the data network"
  else
    fail "postgres ('$pg_service') is attached to: ${nets:-<default>} — expected 'data' only"
  fi
fi

# --- 6. cloudflared shares a user-defined network with its target ----------
# Service-name DNS does not resolve on the default bridge, and the failure looks
# like the app being down rather than a networking mistake.
cf_service="$(jq -r '.services | to_entries[] | select(.value.image // "" | test("cloudflared")) | .key' <<< "$CONFIG" | head -1)"
if [ -n "$cf_service" ]; then
  cf_nets="$(jq -r --arg s "$cf_service" '.services[$s].networks | if type=="object" then keys else (. // []) end | length' <<< "$CONFIG")"
  if [ "$cf_nets" -gt 0 ] 2>/dev/null; then
    ok "cloudflared ('$cf_service') is on a user-defined network"
  else
    fail "cloudflared ('$cf_service') is on the default bridge — service-name DNS will not resolve"
  fi
fi

echo >&2
if [ "$FAILURES" -eq 0 ]; then
  ok "all compose invariants hold"
else
  die "$FAILURES invariant(s) violated — refusing to deploy"
fi
