#!/usr/bin/env bash
# docker-firewall.sh — close inbound forwarding to containers without cutting
# off their outbound connections.
#
# Runs ON the target, standalone.
#
#   docker-firewall.sh apply    install the DOCKER-USER rules and persist them
#   docker-firewall.sh verify   assert both properties still hold
#   docker-firewall.sh show     print the current DOCKER-USER chain
#
# WHY THIS EXISTS
#
# ufw filters the INPUT chain — traffic addressed to the host. Docker publishes
# ports by writing NAT and FORWARD rules, and forwarded packets never touch
# INPUT. So a published port is reachable from the internet no matter what
# `ufw status` says. That is documented Docker behaviour, not a bug. The stack
# is meant to publish nothing at all, which makes this belt-and-braces — but the
# moment somebody adds `ports:` to debug something, ufw silently stops being the
# thing protecting that port.
#
# WHY NOT A BLANKET DROP
#
# DOCKER-USER hangs off FORWARD, and container-*originated* traffic traverses
# FORWARD too. A chain-wide `-j DROP` therefore kills cloudflared's connection
# to Cloudflare's edge and the backup uploader's reach to R2 and B2 — the whole
# architecture is outbound-only, so that is everything. The rules below are
# scoped: return traffic is released first, then new inbound arriving on the
# public interface is dropped. Container egress is untouched.
#
# Rule order is load-bearing. Return packets for a container-initiated
# connection arrive ON the public interface, so if the DROP came first it would
# eat them and every outbound connection would hang. RELATED,ESTABLISHED must be
# evaluated before the interface DROP.

set -euo pipefail

_c() { if [ -t 2 ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
log()  { printf '%s %s\n' "$(_c '0;36' '::')"   "$*" >&2; }
ok()   { printf '%s %s\n' "$(_c '0;32' 'ok')"   "$*" >&2; }
warn() { printf '%s %s\n' "$(_c '0;33' 'warn')" "$*" >&2; }
die()  { printf '%s %s\n' "$(_c '0;31' 'fail')" "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
command -v iptables >/dev/null || die "iptables not installed"

# Public interfaces = whatever carries the default route, minus the tailnet and
# Docker's own bridges. Derived rather than hardcoded, because "provider-
# agnostic" means the NIC is called eth0 on one host and ens3 on the next.
public_ifaces() {
  ip route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' \
    | sort -u | grep -Ev '^(tailscale[0-9]*|docker[0-9]*|br-|lo$)' || true
}

ipt_all() {
  iptables "$@"
  if command -v ip6tables >/dev/null && ip6tables -L DOCKER-USER >/dev/null 2>&1; then
    ip6tables "$@" || warn "ip6tables: $* (ignored)"
  fi
}

ensure_chain() {
  iptables -L DOCKER-USER >/dev/null 2>&1 \
    || die "DOCKER-USER chain missing — is Docker installed and running?"
}

# Idempotent: drop any prior copy of the rule, then insert at position 1.
# Inserting the DROP first and the conntrack rule second leaves the conntrack
# rule on top, which is the order we need.
reinsert() {
  while iptables -C DOCKER-USER "$@" 2>/dev/null; do iptables -D DOCKER-USER "$@"; done
  iptables -I DOCKER-USER 1 "$@"
  if command -v ip6tables >/dev/null && ip6tables -L DOCKER-USER >/dev/null 2>&1; then
    while ip6tables -C DOCKER-USER "$@" 2>/dev/null; do ip6tables -D DOCKER-USER "$@"; done
    ip6tables -I DOCKER-USER 1 "$@" || warn "ip6tables insert failed (ignored)"
  fi
}

cmd_apply() {
  ensure_chain
  local ifaces; ifaces=$(public_ifaces)
  [ -n "$ifaces" ] || die "could not determine the public interface from the default route"

  # Inserted in reverse of the desired final order.
  for i in $ifaces; do
    log "dropping new inbound forwarded traffic on $i"
    reinsert -i "$i" -j DROP
  done

  log "releasing RELATED,ESTABLISHED return traffic ahead of the drop"
  reinsert -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN

  persist
  cmd_verify
}

persist() {
  if command -v netfilter-persistent >/dev/null; then
    netfilter-persistent save >/dev/null && ok "rules persisted via netfilter-persistent"
  else
    warn "iptables-persistent not installed — rules will NOT survive reboot"
    warn "install it with: DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent"
    warn "then re-run: $0 apply"
  fi
}

cmd_verify() {
  ensure_chain
  local ifaces; ifaces=$(public_ifaces)

  # Property 1 — nothing new reaches a container from outside.
  for i in $ifaces; do
    iptables -C DOCKER-USER -i "$i" -j DROP 2>/dev/null \
      && ok "inbound drop present for $i" \
      || die "missing inbound DROP for $i"
  done

  # Property 2 — containers can still talk out. This is the assertion that
  # would have caught a blanket DROP, so it is not optional.
  iptables -C DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN 2>/dev/null \
    && ok "return traffic is released (container egress preserved)" \
    || die "missing RELATED,ESTABLISHED RETURN — container egress is broken, cloudflared will not connect"

  # ...and it must be evaluated first, or it never runs.
  local first; first=$(iptables -S DOCKER-USER | sed -n '2p')
  case "$first" in
    *"RELATED,ESTABLISHED"*) ok "conntrack rule is evaluated first" ;;
    *) die "rule order wrong — RELATED,ESTABLISHED must precede the interface DROP, got: $first" ;;
  esac

  if [ "${EGRESS_TEST:-0}" = "1" ]; then
    log "live egress test (pulls busybox once)"
    if docker run --rm busybox:1.37 wget -q -T 8 -O /dev/null https://cloudflare.com 2>/dev/null; then
      ok "a container reached the internet"
    else
      die "a container could NOT reach the internet — egress is broken"
    fi
  else
    warn "set EGRESS_TEST=1 to additionally prove egress with a real container"
  fi
}

cmd_show() { iptables -S DOCKER-USER; }

case "${1:-}" in
  apply)  cmd_apply ;;
  verify) cmd_verify ;;
  show)   cmd_show ;;
  *) printf 'usage: %s {apply|verify|show}\n' "$(basename "$0")" >&2; exit 2 ;;
esac
