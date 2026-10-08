#!/usr/bin/env bash
# ssh-cutover.sh — remove public SSH from a server without locking yourself out.
#
# Runs ON the target, standalone (no shared library), so it can be copied to a
# fresh box with scp and nothing else.
#
#   ssh-cutover.sh arm       add the tailscale0-scoped rule for port 22
#   ssh-cutover.sh check     report readiness; exit 0 only if cutover is safe
#   ssh-cutover.sh cutover   re-check, delete the public rules, then verify
#   ssh-cutover.sh verify    post-condition only: no unscoped SSH allow remains
#
# Why the steps are separate: `check` is safe to run as many times as you like,
# and it is the step that tells you whether `cutover` will strand you. The
# ordering matters more than any single command here —
#
#   1. add the scoped rule
#   2. prove two independent tailnet sessions
#   3. identify the public rules by number
#   4. delete them WHILE those sessions stay open
#   5. assert no unscoped SSH allow remains
#
# Step 5 is a POST-condition. It cannot be true before step 4, because the
# public rule is exactly what makes it false — a gate that asserts it first can
# never open. Keeping the sessions open across step 4 is what leaves a repair
# path if the deletion goes wrong: you are still logged in, and can undo.

set -euo pipefail

TS_IFACE="${TS_IFACE:-tailscale0}"
MIN_SESSIONS="${MIN_SESSIONS:-2}"

_c() { if [ -t 2 ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
log()  { printf '%s %s\n' "$(_c '0;36' '::')"   "$*" >&2; }
ok()   { printf '%s %s\n' "$(_c '0;32' 'ok')"   "$*" >&2; }
warn() { printf '%s %s\n' "$(_c '0;33' 'warn')" "$*" >&2; }
die()  { printf '%s %s\n' "$(_c '0;31' 'fail')" "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (ufw needs it)"
command -v ufw >/dev/null || die "ufw not installed"
command -v ss  >/dev/null || die "ss not installed (iproute2)"

# ------------------------------------------------------------ rule parsing ---
# `ufw status numbered` prints, e.g.
#     [ 1] 22/tcp                     ALLOW IN    Anywhere
#     [ 2] 22/tcp on tailscale0       ALLOW IN    Anywhere
#     [ 3] OpenSSH (v6)               ALLOW IN    Anywhere (v6)
#
# Emits one "number<TAB>action<TAB>target" record per rule.
ufw_rules() {
  ufw status numbered 2>/dev/null \
    | sed -n 's/^\[[[:space:]]*\([0-9]\{1,\}\)\][[:space:]]*\(.*\)$/\1\t\2/p' \
    | while IFS=$'\t' read -r num rest; do
        action=$(printf '%s' "$rest" | sed -n 's/.*[[:space:]]\(ALLOW\|DENY\|REJECT\|LIMIT\)[[:space:]]\+\(IN\|OUT\).*/\1 \2/p')
        target=$(printf '%s' "$rest" | sed -E 's/[[:space:]]+(ALLOW|DENY|REJECT|LIMIT)[[:space:]]+(IN|OUT).*$//')
        printf '%s\t%s\t%s\n' "$num" "${action:-?}" "$target"
      done
}

# Does this rule concern SSH? Port 22 is the obvious form, but `ufw allow
# OpenSSH` uses an application profile and renders as the profile name with no
# digits in sight. A gate that only greps for "22" sails straight past it and
# leaves the box wide open — this is the most common way this cutover is
# quietly botched.
is_ssh_target() {
  printf '%s' "$1" | grep -Eqi '(^|[^0-9])22(/(tcp|udp))?([^0-9]|$)|OpenSSH|(^|[[:space:]])ssh([[:space:]]|$)'
}

# Scoped to the tailnet interface specifically. "Has an interface" is not
# enough: `22/tcp on eth0 ALLOW IN` is scoped and still public.
is_tailscale_scoped() {
  printf '%s' "$1" | grep -Eq "[[:space:]]on[[:space:]]+${TS_IFACE}([[:space:]]|$)"
}

is_permissive() { case "$1" in "ALLOW IN"|"LIMIT IN") return 0 ;; *) return 1 ;; esac; }

# Every rule that still lets SSH in from somewhere other than the tailnet.
public_ssh_rules() {
  ufw_rules | while IFS=$'\t' read -r num action target; do
    is_permissive "$action"      || continue
    is_ssh_target "$target"      || continue
    is_tailscale_scoped "$target" && continue
    printf '%s\t%s\t%s\n' "$num" "$action" "$target"
  done
}

tailscale_ssh_rules() {
  ufw_rules | while IFS=$'\t' read -r num action target; do
    is_permissive "$action" || continue
    is_ssh_target "$target" || continue
    is_tailscale_scoped "$target" || continue
    printf '%s\t%s\t%s\n' "$num" "$action" "$target"
  done
}

# --------------------------------------------------------- tailnet checks ---
is_tailnet_addr() {
  case "${1:-}" in
    100.*) local s="${1#100.}"; s="${s%%.*}"
           [ "$s" -ge 64 ] 2>/dev/null && [ "$s" -le 127 ] 2>/dev/null ;;
    *) return 1 ;;
  esac
}

# Distinct peers, not raw connection count — one client opening three channels
# is still one way back in. The point of requiring two is that they are
# independent: if one dies mid-cutover the other is your repair path. Two
# sessions from the same laptop therefore count once: open the second from
# another tailnet device (a phone SSH app is enough).
#
# With a `state` filter, `ss` drops its State column, so the peer is field 4
# (Recv-Q Send-Q Local Peer), not 5. Reading field 5 yields an empty string,
# every session is discarded, and the gate reports 0 forever.
count_tailnet_ssh_peers() {
  local n=0 addr
  while read -r peer; do
    addr="${peer%:*}"; addr="${addr#[}"; addr="${addr%]}"
    is_tailnet_addr "$addr" && n=$((n + 1))
  done < <(ss -Htn state established '( sport = :22 )' 2>/dev/null \
            | awk '{print $4}' | sed 's/:[0-9]*$//' | sort -u)
  printf '%d' "$n"
}

# -------------------------------------------------------------- commands ----
cmd_arm() {
  log "adding ${TS_IFACE}-scoped rule for port 22"
  ufw allow in on "$TS_IFACE" to any port 22 proto tcp
  ok "rule added — now open a SECOND ssh session over the tailnet, then run: $0 check"
}

cmd_check() {
  local failed=0

  ufw status 2>/dev/null | grep -q '^Status: active' \
    && ok "ufw is active" \
    || { warn "ufw is NOT active — enabling it later can strand you; enable and re-check"; failed=1; }

  if ufw status verbose 2>/dev/null | grep -Eq '^Default:.*deny \(incoming\)'; then
    ok "default incoming policy is deny"
  else
    warn "default incoming policy is not deny — fix before cutting over"; failed=1
  fi

  if command -v tailscale >/dev/null && tailscale status >/dev/null 2>&1; then
    ok "tailscale is up"
  else
    warn "tailscale is not reporting healthy"; failed=1
  fi

  local ts_count; ts_count=$(tailscale_ssh_rules | wc -l | tr -d ' ')
  if [ "$ts_count" -ge 1 ]; then
    ok "found ${ts_count} SSH rule(s) scoped to ${TS_IFACE}"
  else
    warn "no SSH rule scoped to ${TS_IFACE} — run '$0 arm' first"; failed=1
  fi

  local peers; peers=$(count_tailnet_ssh_peers)
  if [ "$peers" -ge "$MIN_SESSIONS" ]; then
    ok "${peers} independent tailnet SSH session(s) live (need ${MIN_SESSIONS})"
  else
    warn "only ${peers} independent tailnet SSH session(s) live, need ${MIN_SESSIONS} — sessions from one machine count once; open one from another tailnet device and re-check"
    failed=1
  fi

  local pub; pub=$(public_ssh_rules || true)
  if [ -n "$pub" ]; then
    log "public SSH rules that WILL BE DELETED by 'cutover':"
    printf '%s\n' "$pub" | while IFS=$'\t' read -r num action target; do
      printf '     [%s] %s  %s\n' "$num" "$target" "$action" >&2
    done
  else
    ok "no public SSH rules remain — cutover already done"
  fi

  [ "$failed" -eq 0 ] || die "not safe to cut over yet"
  ok "safe to cut over — run: $0 cutover"
}

cmd_cutover() {
  cmd_check

  local nums
  nums=$(public_ssh_rules | cut -f1 | sort -rn)
  if [ -z "$nums" ]; then ok "nothing to delete"; cmd_verify; return; fi

  # Descending order: ufw renumbers remaining rules after every delete, so
  # deleting low-to-high makes each subsequent number point at the wrong rule.
  log "deleting public SSH rules (highest number first) — keep your sessions open"
  for n in $nums; do
    log "  ufw delete $n"
    ufw --force delete "$n"
  done

  cmd_verify
}

cmd_verify() {
  local pub; pub=$(public_ssh_rules || true)
  if [ -n "$pub" ]; then
    printf '%s\n' "$pub" >&2
    die "post-condition FAILED: SSH is still reachable from outside the tailnet"
  fi
  ok "post-condition holds: no unscoped SSH allow rule remains"

  tailscale_ssh_rules | grep -q . \
    || die "post-condition FAILED: no ${TS_IFACE} SSH rule left either — you are about to be locked out, re-add it NOW: ufw allow in on ${TS_IFACE} to any port 22 proto tcp"
  ok "tailnet SSH rule still present"

  warn "do not close your sessions yet — open a fresh tailnet ssh connection and confirm it works first"
}

case "${1:-}" in
  arm)     cmd_arm ;;
  check)   cmd_check ;;
  cutover) cmd_cutover ;;
  verify)  cmd_verify ;;
  *) printf 'usage: %s {arm|check|cutover|verify}\n' "$(basename "$0")" >&2; exit 2 ;;
esac
