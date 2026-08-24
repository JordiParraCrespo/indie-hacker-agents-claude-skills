#!/usr/bin/env bash
# block-destructive.sh — PreToolUse hook. Refuses shell commands that are
# catastrophic and never intentional in this repo.
#
# Registered in .claude/settings.json for Bash. Reads the tool call as JSON on
# stdin; exit 2 blocks the call and shows the reason.
#
# This is layer 4 of the read-only design, and it is deliberately narrow. It is
# not a sandbox and cannot be one — a determined command can always be spelled
# differently. What it catches is the accident and the obvious injection: the
# `rm -rf /` that came from a mangled variable, the `git reset --hard` that
# throws away uncommitted work, the recursive chmod that takes a day to undo.
#
# Narrow on purpose. A hook that fires on ordinary work gets disabled within a
# week, and then protects nothing.

set -uo pipefail

INPUT="$(cat)"

# Prefer jq, fall back to grep so a missing jq degrades to a weaker check rather
# than silently allowing everything.
if command -v jq >/dev/null 2>&1; then
  TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
  CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
else
  TOOL="$(printf '%s' "$INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
  CMD="$(printf '%s' "$INPUT"  | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"'   | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
fi

[ "$TOOL" = "Bash" ] || exit 0
[ -n "$CMD" ] || exit 0

block() {
  printf 'Blocked by .claude/hooks/block-destructive.sh: %s\n\n' "$1" >&2
  printf 'Command: %s\n\n' "$CMD" >&2
  printf 'If this is genuinely intended, run it yourself in a terminal.\n' >&2
  printf 'This hook exists so that an accident or an injected instruction cannot.\n' >&2
  exit 2
}

# Recursive deletion of a root-ish path. The classic form is a mangled variable:
# `rm -rf "$DIR/"` where DIR is empty.
printf '%s' "$CMD" | grep -Eq 'rm[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+)*-?[a-zA-Z]*f?[a-zA-Z]*[[:space:]]+/([[:space:]]|$|\*)' \
  && block 'recursive delete of /'
printf '%s' "$CMD" | grep -Eq 'rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f|rm[[:space:]]+-[a-zA-Z]*f[a-zA-Z]*r' \
  && printf '%s' "$CMD" | grep -Eq '[[:space:]](/|~|\$HOME|/etc|/var|/usr|/boot)([[:space:]]|/?\*|$)' \
  && block 'recursive force-delete of a system or home path'

# Discards uncommitted work with no undo. `git stash` exists for a reason.
printf '%s' "$CMD" | grep -Eq 'git[[:space:]]+reset[[:space:]]+.*--hard' \
  && block 'git reset --hard discards uncommitted work irreversibly (use git stash)'
printf '%s' "$CMD" | grep -Eq 'git[[:space:]]+clean[[:space:]]+-[a-zA-Z]*f.*-[a-zA-Z]*d|git[[:space:]]+clean[[:space:]]+-[a-zA-Z]*d.*-[a-zA-Z]*f' \
  && block 'git clean -fd deletes untracked files irreversibly'
printf '%s' "$CMD" | grep -Eq 'git[[:space:]]+push[[:space:]]+.*(--force([[:space:]]|$)|-f([[:space:]]|$))' \
  && ! printf '%s' "$CMD" | grep -q 'force-with-lease' \
  && block 'force-push without --force-with-lease can discard someone else'"'"'s commits'

# Recursive permission changes across a tree — hard to reverse, easy to mistype.
printf '%s' "$CMD" | grep -Eq '(chmod|chown)[[:space:]]+(-[a-zA-Z]*R[a-zA-Z]*[[:space:]]+)+.*[[:space:]](/|~|\$HOME|/etc|/usr|/var)([[:space:]]|/?\*|$)' \
  && block 'recursive permission change on a system or home path'
printf '%s' "$CMD" | grep -Eq 'chmod[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*777' \
  && block 'chmod 777 — world-writable is essentially never what you want here'

# Overwriting a block device.
printf '%s' "$CMD" | grep -Eq 'dd[[:space:]]+.*of=/dev/(sd|nvme|vd|xvd)' \
  && block 'dd writing directly to a block device'
printf '%s' "$CMD" | grep -Eq 'mkfs(\.[a-z0-9]+)?[[:space:]]' \
  && block 'mkfs formats a filesystem'

# Production data. These are the ones this repo cares about most: the whole
# architecture exists so a bad day is recoverable, and each of these removes the
# thing that makes it recoverable.
printf '%s' "$CMD" | grep -Eq 'docker[[:space:]]+volume[[:space:]]+(rm|prune)' \
  && block 'removing a Docker volume destroys the Postgres data directory'
printf '%s' "$CMD" | grep -Eq 'docker[[:space:]]+system[[:space:]]+prune.*(-a|--all|--volumes)' \
  && block 'docker system prune with volumes destroys database state'
printf '%s' "$CMD" | grep -Eq 'compose.*down.*(-v|--volumes)' \
  && block 'docker compose down -v deletes the database volume'
printf '%s' "$CMD" | grep -Eq 'DROP[[:space:]]+(DATABASE|SCHEMA)|TRUNCATE[[:space:]]+TABLE' \
  && block 'destructive SQL — run migrations through deploy-api so there is a rollback path'

# Backups. Deleting these removes the last line of defence, and the bucket lock
# is meant to make it impossible from the server — a local attempt is a signal.
printf '%s' "$CMD" | grep -Eq 'rclone[[:space:]]+(delete|purge|rmdir)' \
  && block 'rclone delete/purge against backup storage'
printf '%s' "$CMD" | grep -Eq 'wrangler[[:space:]]+r2[[:space:]]+bucket[[:space:]]+lock[[:space:]]+remove' \
  && block 'removing an R2 bucket lock voids backup immutability'

exit 0
