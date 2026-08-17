# indie-hacker-agents-claude-skills

Claude Skills and guides for shipping and running solo-dev infrastructure.

**First project:** a production API + Postgres on a single VPS with **zero inbound ports open** — public traffic via Cloudflare Tunnel, admin via Tailscale, immutable backups on R2 with a second copy on B2, and a read-only ops agent that reports but never writes.

## Where things are

| | |
|---|---|
| [`docs/00-handoff.md`](docs/00-handoff.md) | Original architecture handoff, preserved as received |
| [`docs/01-review.md`](docs/01-review.md) | Review of that handoff — 17 findings, every claim re-verified |
| [`docs/02-plan.md`](docs/02-plan.md) | Build plan, phased |

Read them in that order. Where the handoff and the review disagree, **the review wins** — it carries the sources.

## Status

Planning complete. Nothing provisioned. Blocked on six decisions in [`02-plan.md` Phase 0](docs/02-plan.md#phase-0--decisions-and-scaffold).

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
