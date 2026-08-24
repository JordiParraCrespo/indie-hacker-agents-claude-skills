#!/usr/bin/env bash
# verify.sh — assert that a provisioned host actually has the properties the
# architecture claims. Runs from your machine, not the server.
#
#   verify.sh <staging|prod>
#
# "Provisioned" is not a feeling. Every guarantee below is checkable, and the
# external scan in particular is the whole point of the exercise: if anything
# answers on the public IP, the design has failed regardless of how tidy
# `ufw status` looks from the inside.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../../../infra/lib/common.sh"

require_target "${1:-}"
load_targets

FAILURES=0
fail() { printf 'fail %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

# Ports that must not answer from the internet. 22 because SSH moved to the
# tailnet, 80/443 because TLS terminates at Cloudflare and traffic arrives
# through an outbound tunnel, 5432 because Postgres publishes nothing at all.
CLOSED_PORTS="${CLOSED_PORTS:-22 80 443 5432 6379 8080}"

public_ip_var="$(printf '%s' "$TARGET" | tr '[:lower:]' '[:upper:]')_PUBLIC_IP"
PUBLIC_IP="${!public_ip_var:-}"
tunnel_var="$(printf '%s' "$TARGET" | tr '[:lower:]' '[:upper:]')_TUNNEL_HOSTNAME"
TUNNEL_HOSTNAME="${!tunnel_var:-}"

port_closed() {
  # A refused or timed-out connection is what we want. Success is failure here.
  ! timeout 4 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}

log "verifying target '$TARGET' ($TARGET_HOST)"

# ---------------------------------------------------- 1. external exposure ---
if [ -n "$PUBLIC_IP" ]; then
  log "external scan of $PUBLIC_IP"
  for p in $CLOSED_PORTS; do
    if port_closed "$PUBLIC_IP" "$p"; then
      ok "port $p closed from the internet"
    else
      fail "port $p is OPEN from the internet — stop and fix before deploying"
    fi
  done
else
  warn "${public_ip_var} unset in $TARGETS_ENV — skipping the external scan, which is the single most important check here"
fi

# --------------------------------------------------------- 2. admin plane ---
if on_target true 2>/dev/null; then
  ok "SSH over the tailnet works"
else
  fail "cannot reach $TARGET_HOST over the tailnet"
fi

# --------------------------------------------------------------- 3. host ----
if on_target 'sudo -n ufw status verbose' 2>/dev/null | grep -Eq '^Default:.*deny \(incoming\)'; then
  ok "ufw default incoming is deny"
else
  fail "ufw default incoming is not deny"
fi

if on_target 'sudo -n iptables -C DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN' 2>/dev/null; then
  ok "DOCKER-USER preserves container egress"
else
  fail "DOCKER-USER is missing the RELATED,ESTABLISHED RETURN rule — cloudflared and the backup uploader will not reach the internet"
fi

# Postgres must not be bound to any host interface. Docker's own proxy would
# show up here too, which is exactly what we want to catch.
if on_target "ss -Hltn '( sport = :5432 )'" 2>/dev/null | grep -q .; then
  fail "something is listening on 5432 on the host — Postgres should publish no ports at all"
else
  ok "nothing listens on 5432 on the host"
fi

# Compose must not publish anything. Checked on the host so it catches drift
# that never went through a reviewed compose file.
published=$(on_target 'docker ps --format "{{.Names}} {{.Ports}}" 2>/dev/null | grep -E "0\.0\.0\.0:|:::" || true' 2>/dev/null || true)
if [ -n "$published" ]; then
  fail "containers are publishing ports to the host:"
  printf '%s\n' "$published" >&2
else
  ok "no container publishes a port to the host"
fi

# -------------------------------------------------------- 4. public plane ---
if [ -n "$TUNNEL_HOSTNAME" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$TUNNEL_HOSTNAME/" || true)
  case "$code" in
    000) fail "tunnel hostname $TUNNEL_HOSTNAME did not respond" ;;
    5*)  fail "tunnel hostname $TUNNEL_HOSTNAME returned $code" ;;
    *)   ok "tunnel hostname $TUNNEL_HOSTNAME responded ($code)" ;;
  esac
else
  warn "${tunnel_var} unset — skipping the public-plane check"
fi

# ------------------------------------------------------------- 5. reboot ----
uptime_s=$(on_target 'cut -d. -f1 /proc/uptime' 2>/dev/null || echo 0)
if [ "$uptime_s" -lt 300 ] 2>/dev/null; then
  ok "host rebooted recently — this run doubles as the post-reboot check"
else
  warn "host has been up $((uptime_s / 86400))d — do one deliberate reboot and re-run before trusting an unattended one"
fi

echo >&2
if [ "$FAILURES" -eq 0 ]; then
  ok "all checks passed for '$TARGET'"
else
  die "$FAILURES check(s) failed for '$TARGET'"
fi
