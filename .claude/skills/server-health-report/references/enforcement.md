# Enforcement — what each layer does, and how to prove it holds

Five layers. They fail in different ways, which is the entire reason there are
five rather than one good one.

## 1 · Instructions in SKILL.md

**Does:** tells the model the skill is read-only and why.

**Fails when:** the model is persuaded otherwise — by a user, or by a log line
engineered to look like an instruction.

Necessary but never sufficient. Everything below exists because a sufficiently
convincing prompt beats a sufficiently clear instruction.

## 2 · `disallowed-tools` frontmatter

```yaml
disallowed-tools: Edit Write NotebookEdit
```

**Does:** removes those tools from the pool while the skill is active. Not "the
model declines" — they aren't available.

**Fails when:** the user sends their next message. **The grant clears then.**
That is documented behaviour, not a bug, and it is the single most important
thing to understand about this layer: it is a per-turn restriction, not a
sandbox. If the report takes two turns, the second turn has write tools back.

Real, and not something to lean on.

## 3 · `disable-model-invocation: true`

**Does:** stops Claude autonomously deciding to run this skill. It runs when
someone types `/server-health-report`.

**Fails when:** someone types `/server-health-report`. That's the intent — this
is about removing autonomous triggering, not about restricting a deliberate
invocation.

Also prevents the skill being preloaded into subagents, which matters: a
subagent inheriting the skill wouldn't inherit the surrounding context that
explains why it's read-only.

## 4 · The PreToolUse hook

`.claude/hooks/block-destructive.sh`, registered in `.claude/settings.json`.

**Does:** inspects every Bash command before it runs and blocks catastrophic
patterns — recursive deletes of system paths, `git reset --hard`, volume
removal, destructive SQL, backup deletion, R2 lock removal.

**Fails when:** the command doesn't match a pattern. It is not a sandbox and
cannot be — any command can be spelled differently, base64'd, or written to a
file and executed.

Deliberately **narrow**. A hook that fires on ordinary work gets disabled within
a week and then protects nothing. What it reliably catches is the accident (a
mangled `$DIR` in `rm -rf "$DIR/"`) and the unsubtle injection.

Test it:

```bash
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' \
  | .claude/hooks/block-destructive.sh; echo "exit=$?"     # expect exit=2

echo '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' \
  | .claude/hooks/block-destructive.sh; echo "exit=$?"     # expect exit=0
```

## 5 · The sudoers whitelist — the one that actually holds

`assets/ops-agent.sudoers` → `/etc/sudoers.d/ops-agent`.

**Does:** the ops-agent user can run exactly the read commands listed and
nothing else. Enforced by the kernel and sudo, not by a model's cooperation.

**Fails when:** someone edits the file. That's it.

This is the only layer that holds regardless of what the model decides, what a
user asks, or what an attacker writes into a log. Layers 1–4 shape behaviour;
this one constrains capability. **Install it before running this skill against
anything real.**

```bash
sudo install -m 0440 -o root -g root assets/ops-agent.sudoers /etc/sudoers.d/ops-agent
sudo visudo -c                                   # validate before trusting it

sudo -u ops-agent sudo -n docker ps              # expect: succeeds
sudo -u ops-agent sudo -n docker restart api     # expect: refused
sudo -u ops-agent sudo -n -l                     # review what is actually granted
```

Run **both** probes. A whitelist that has never refused anything has not been
tested — you have confirmed it permits, not that it denies.

### The `docker` group is not an alternative

Adding the ops-agent user to the `docker` group is the obvious shortcut and it
is equivalent to giving it root:

```bash
docker run -v /:/host -it alpine chroot /host    # any docker group member
```

It is not "read-only access to Docker". It is a root shell with extra steps, and
it silently voids layers 1–4 along with the read-only design itself. If you find
yourself reaching for it because the whitelist is inconvenient, fix the
whitelist.

### The read-only socket proxy alternative

Instead of sudoers, run a container exposing only GET endpoints of the Docker
API (`tecnativa/docker-socket-proxy` or similar) and point the agent at that.

Comparable strength, different tradeoff: an extra moving part, but the allowed
surface is expressed as API endpoints rather than sudoers wildcards — and
sudoers wildcards are genuinely easy to get subtly wrong, since `docker inspect
*` matches more argument shapes than you might expect. Either is defensible.
Pick one and test it.

## What this does not protect against

Worth being honest about the boundary:

- **A compromised host.** If root is compromised, none of this matters. That's
  what the backup bucket lock and the second vendor are for.
- **A malicious operator.** These layers protect against accidents, injections,
  and scope creep — not against someone with legitimate access deciding to do
  damage.
- **Reading things it shouldn't.** The agent can read logs and stats. The
  Postgres agent role (`pg_monitor`, no `SELECT` on user tables) is what bounds
  that, and it belongs to `db-backup-verify`, not here.

The threat model this addresses: an agent that reads attacker-controlled content
and could be talked into doing something with it. Everything above narrows the
"doing something" to nearly nothing.
