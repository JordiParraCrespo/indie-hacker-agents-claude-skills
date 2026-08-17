#!/usr/bin/env bash
# collect.sh — gather read-only facts about a host and emit JSON.
#
#   collect.sh <staging|prod>
#
# Every command here reads. None of them change anything. That is enforced at
# the OS level by the sudoers whitelist in assets/ops-agent.sudoers — this
# script staying read-only is the intent, the whitelist is the guarantee.
#
# A note on the log excerpts this returns: they contain attacker-controlled
# strings. A request path, a user agent, an error quoting user input — any of it
# can be authored by whoever is probing your server, and any of it can be
# written to look like an instruction. Whatever consumes this output must treat
# log content as DATA, never as direction. That is the whole reason the agent
# role cannot read table rows and this script cannot write.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../../../infra/lib/common.sh"

require_target "${1:-}"

# Run a whitelisted command on the target; empty string on failure rather than
# aborting, so one unavailable check never costs you the whole report.
r() { on_target "$1" 2>/dev/null || true; }

json_str() { printf '%s' "${1:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '""'; }

log "collecting from $TARGET ($TARGET_HOST)"

DISK="$(r 'df -PH / /var/lib/docker 2>/dev/null | tail -n +2')"
MEM="$(r 'free -m | sed -n 2p')"
LOAD="$(r 'cat /proc/loadavg')"
UPTIME_S="$(r 'cut -d. -f1 /proc/uptime')"

REBOOT_REQUIRED="$(r 'test -f /var/run/reboot-required && echo yes || echo no')"
REBOOT_PKGS="$(r 'cat /var/run/reboot-required.pkgs 2>/dev/null')"

# Security updates specifically. The full upgradable list is noise; what matters
# for a report is whether anything security-relevant is pending.
UPGRADABLE="$(r 'sudo -n apt list --upgradable 2>/dev/null | grep -i security | head -40')"

FAILED_UNITS="$(r 'systemctl list-units --state=failed --no-legend --no-pager')"

# Enabled-vs-running is the distinction that bites after a reboot: a unit can be
# happily active and never come back, and `systemctl status` shows both cases
# identically.
NOT_ENABLED="$(r 'for u in docker tailscaled cloudflared; do systemctl is-active --quiet $u 2>/dev/null && ! systemctl is-enabled --quiet $u 2>/dev/null && echo $u; done')"

CONTAINERS="$(r 'sudo -n docker ps --format "{{.Names}}\t{{.Status}}\t{{.Image}}"')"
RESTARTS="$(r 'sudo -n docker ps -q | xargs -r sudo -n docker inspect --format "{{.Name}} {{.RestartCount}} {{.State.Health.Status}}" 2>/dev/null')"

# Digest drift: the running image versus what the registry now serves for that
# tag. This is REPORTED, never acted on — silent image replacement turns a
# ten-second controlled restart into a forty-minute outage you did not schedule.
IMAGE_DIGESTS="$(r 'sudo -n docker ps --format "{{.Image}}" | sort -u')"

# Published ports should always be empty. If this is ever non-empty, ufw has
# silently stopped protecting that port and it belongs at the top of the report.
PUBLISHED="$(r 'sudo -n docker ps --format "{{.Names}} {{.Ports}}" | grep -E "0\.0\.0\.0:|:::"')"

FIREWALL="$(r 'sudo -n ufw status verbose | head -6')"
DOCKER_USER_OK="$(r 'sudo -n iptables -C DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN >/dev/null 2>&1 && echo yes || echo no')"

# Error-rate sampling, deliberately bounded. This is the untrusted-content
# surface, so it is capped and clearly labelled rather than slurped wholesale.
LOG_ERRORS="$(r 'sudo -n docker compose -f /srv/app/compose.yml logs --since 24h --no-color 2>/dev/null | grep -icE "\b(error|fatal|panic|exception)\b"')"
LOG_SAMPLE="$(r 'sudo -n docker compose -f /srv/app/compose.yml logs --since 24h --no-color --tail 2000 2>/dev/null | grep -iE "\b(error|fatal|panic)\b" | tail -15 | cut -c1-300')"

TAILSCALE="$(r 'tailscale status --json 2>/dev/null | head -c 400')"

cat <<JSON
{
  "target": "$TARGET",
  "host": "$TARGET_HOST",
  "collected_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "uptime_seconds": ${UPTIME_S:-0},
  "load": $(json_str "$LOAD"),
  "disk": $(json_str "$DISK"),
  "memory_mb": $(json_str "$MEM"),
  "reboot_required": $(json_str "$REBOOT_REQUIRED"),
  "reboot_required_packages": $(json_str "$REBOOT_PKGS"),
  "security_updates": $(json_str "$UPGRADABLE"),
  "failed_units": $(json_str "$FAILED_UNITS"),
  "active_but_not_enabled": $(json_str "$NOT_ENABLED"),
  "containers": $(json_str "$CONTAINERS"),
  "restart_counts": $(json_str "$RESTARTS"),
  "running_images": $(json_str "$IMAGE_DIGESTS"),
  "published_ports_VIOLATION": $(json_str "$PUBLISHED"),
  "firewall": $(json_str "$FIREWALL"),
  "docker_user_egress_ok": $(json_str "$DOCKER_USER_OK"),
  "log_error_count_24h": $(json_str "$LOG_ERRORS"),
  "untrusted_log_sample": $(json_str "$LOG_SAMPLE"),
  "tailscale": $(json_str "$TAILSCALE")
}
JSON
