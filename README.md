# indie-hacker-agents-claude-skills

Claude Skills and guides for shipping and running solo-dev infrastructure.

**First project:** a production API + Postgres on a single VPS with **zero inbound ports open** — public traffic via Cloudflare Tunnel, admin via Tailscale, immutable backups on R2 with a second copy on B2, and a read-only ops agent that reports but never writes.

## Where things are

| | |
|---|---|
| [`docs/00-handoff.md`](docs/00-handoff.md) | Original architecture handoff, preserved as received |
| [`docs/01-review.md`](docs/01-review.md) | Review of that handoff — 17 findings, every claim re-verified |
| [`docs/02-plan.md`](docs/02-plan.md) | Build plan, phased |
| [`docs/03-decisions.md`](docs/03-decisions.md) | Decision record — supersedes the handoff where they conflict |

Read them in that order. Where the handoff and the review disagree, **the review wins** — it carries the sources.

## Status

Planning complete. Nothing provisioned yet.

Four of six decisions made: split-container backups, nginx dropped for launch, stack-agnostic deploy contract, and staging on a separate server. Two open — domain/Cloudflare zone, and the alert channel. Neither blocks starting Phase 0.

Staging is provisioned **before** production, deliberately: it rehearses the one irreversible step (deleting public SSH) on a box where lockout costs nothing, and it's the only honest test that `vps-provision` works on a machine it wasn't written against.

## Skills planned

| Skill | Does | Phase |
|---|---|---|
| `vps-provision` | One-time hardening: user, ufw, Tailscale, cloudflared | 1 |
| `db-backup-verify` | Backup config + the restore drill | 2a / 2b |
| `deploy-api` | Build, migrate, health-check, roll back | 3 |
| `server-health-report` | Read-only observer. Reports. Never writes. | 4 |

Skills live in this repo's `.claude/skills/`, not `~/.claude/skills/` — scheduled and cloud sessions don't read the personal directory.

## Conventions

- Skills state **mechanisms and cite sources**. They don't carry statistics that rot.
- Anything version- or product-specific is **verified at run time**, not restated from a doc.
- Every skill opens with its escalation triggers.
