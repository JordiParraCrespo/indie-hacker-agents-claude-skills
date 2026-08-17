# indie-hacker-agents-claude-skills

Claude Skills and guides for shipping and running solo-dev infrastructure.

**First project:** a production API + Postgres on a single VPS with **zero inbound ports open** — public traffic via Cloudflare Tunnel, admin via Tailscale, encrypted immutable backups on R2 with a second copy on B2, and a read-only ops agent that reports but never writes.

## The skills

| Skill | Does | Auto-triggers |
|---|---|---|
| [`vps-provision`](.claude/skills/vps-provision/) | One-time hardening: user, ufw, `DOCKER-USER`, Tailscale, gated SSH removal, cloudflared | No — it deletes public SSH |
| [`db-backup-verify`](.claude/skills/db-backup-verify/) | Encrypted dumps → R2 under a bucket lock, weekly B2 copy, restore drill | Yes — high value, low risk |
| [`deploy-api`](.claude/skills/deploy-api/) | Build, migrate, health-check, promote, roll back. Stack-agnostic | No — it deploys to production |
| [`server-health-report`](.claude/skills/server-health-report/) | Read-only observer. Reports. Never writes | No — invoked deliberately |

The three that change production have `disable-model-invocation: true`. Deploying or deleting SSH because a model inferred it was relevant is exactly the agency this architecture rejects — so those run when a human types the command. `db-backup-verify` triggers freely, since taking a backup and verifying a restore is safe to do more often than asked.

## Quick start

```bash
cp infra/targets.env.example infra/targets.env      # fill in hosts, buckets, age public key
cp .claude/skills/deploy-api/assets/deploy.manifest.json deploy.manifest.json

/vps-provision              # staging first, then prod
/db-backup-verify           # mechanism pass, then drill
/deploy-api                 # staging → verify → promote
/server-health-report       # once there is something to observe
```

Staging is provisioned **before** production, deliberately: it rehearses the one irreversible step (removing public SSH) where lockout costs nothing, and it is the only honest test that `vps-provision` works on a machine it wasn't written against.

## What's enforced mechanically

Every guarantee here is checkable, and the ones that matter are checked rather than remembered:

- **No container publishes a port to the host** — `deploy-api` fails the build otherwise. ufw filters INPUT; Docker publishes via NAT/FORWARD, so a published port is internet-reachable regardless of what `ufw status` says.
- **Container egress still works** — the `DOCKER-USER` rules are scoped, not a blanket DROP. A chain-wide drop would cut cloudflared from Cloudflare and the uploader from R2, which in an outbound-only architecture is everything.
- **SSH cutover can't strand you** — two proven tailnet sessions, rules identified by number, deleted while those sessions stay open, and the "no public SSH" check runs as a *post*-condition. It cannot be true beforehand.
- **Backups are immutable** — bucket lock **and** an Object-tier token. An Admin-tier token can remove the lock, so the tier is probed by attempting an Admin-only operation and requiring it to fail.
- **Backups are readable** — the monthly drill decrypts with the escrowed key and asserts real row counts, and a negative test proves the alarm actually fires.
- **The ops agent can't write** — five layers, of which the sudoers whitelist is the only one that holds regardless of what a model decides or a log line says.

## Repo layout

```
.claude/skills/          the four skills — SKILL.md, references/, scripts/, assets/
.claude/hooks/           PreToolUse hook blocking destructive shell patterns
infra/                   compose.yml, cloudflared config, shared shell library
docs/                    the handoff, its review, decisions, and the build plan
```

Skills live in the repo, not `~/.claude/skills/` — scheduled and cloud sessions start fresh and don't read the personal directory, so a personal-only copy reports as "not found" the first time a routine fires.

## Docs

| | |
|---|---|
| [`docs/00-handoff.md`](docs/00-handoff.md) | Original architecture handoff, preserved as received |
| [`docs/01-review.md`](docs/01-review.md) | Review of it — 17 findings, every claim re-verified, sources listed |
| [`docs/02-plan.md`](docs/02-plan.md) | Build plan, phased |
| [`docs/03-decisions.md`](docs/03-decisions.md) | Decision record — supersedes the handoff where they conflict |

Where the handoff and the review disagree, **the review wins** — it carries the sources.

## Conventions

- Skills state **mechanisms and cite sources**. They don't carry statistics that rot.
- Anything version- or product-specific is **verified at run time**, not restated from a doc.
- Assertions check *state*, never a command's exit code. A rule that failed to apply and a rule that applied to the wrong interface both exit 0.
- Every skill opens with its escalation triggers.

## Status

Skills implemented and self-tested. Nothing provisioned yet — no server exists.

Open decisions: domain / Cloudflare zone, and the drill-failure alert channel.
