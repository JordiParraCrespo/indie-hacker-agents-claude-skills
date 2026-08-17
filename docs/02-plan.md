# Build plan

**Depends on:** [`01-review.md`](01-review.md) (findings referenced as F1–F17) and [`03-decisions.md`](03-decisions.md) (D1–D6).

The handoff's build order is kept — **harden → back up → deploy → observe** — with F12's split applied, D2's nginx removal folded in, and D4's staging server reordering Phase 1. Each phase ends in something committed and verified, so an interrupted session resumes from the repo alone.

---

## Phase 0 — Scaffold

Four of the six decisions are made. Two remain open and block only the steps that need them.

| # | Decision | Status |
|---|---|---|
| D1 | Backup topology | ✅ Split containers — dump sidecar + separate uploader |
| D2 | nginx | ✅ Dropped for launch; config kept unwired |
| D3 | API stack | ✅ Agnostic, via a declared contract |
| D4 | Staging | ✅ Yes, separate server — and it's the test of `vps-provision` |
| D5 | Domain + Cloudflare zone | ⏳ Blocks the tunnel step in Phase 1 |
| D6 | Alert channel | ⏳ ntfy proposed; blocks Phase 2a's alarm only |

**Deliverables**

- Repo scaffold: `.claude/skills/`, `infra/`, `scripts/`
- `.gitignore` + secret scanning in CI (F8 — ignored ≠ absent)
- A pinned fact sheet the skills cite instead of restating: versions, CVE floor, R2 token tier

---

## Phase 1 — `vps-provision`

One-time hardening runbook, written for someone who hasn't read it in eight months.

**Runs twice: staging first, then production.** That ordering is the whole reason D4 is worth its cost — see below.

**Scope:** unprivileged user, SSH keys, ufw, Tailscale, cloudflared, host baseline (`unattended-upgrades` scoped to security origins, `needrestart`, reboot-required alerting).

### Review changes folded in

- **F7 — the SSH gate.** The destructive step is fenced: add `ufw allow in on tailscale0 to any port 22 proto tcp` → prove **two** independent tailnet sessions → parse `ufw status numbered` and assert no port-22 rule lacks an interface scope → *only then* delete the generic rule. The out-of-band recovery path (provider console) is confirmed and written down **before** any of it. Order is never reversed.

  A generic `22/tcp ALLOW IN Anywhere` silently defeats an interface-scoped rule — that's the trap, and it's why the assertion parses the rule list rather than trusting that the allow succeeded.

- **F6 — `DOCKER-USER` default DROP**, persisted across reboot. ufw governs INPUT; Docker publishes via NAT/FORWARD. ufw alone does not govern a Docker host.
- **F15 — locally-managed tunnel.** `config.yml` in the repo, terminating `- service: http_status:404` catch-all, `cloudflared` on a user-defined network, image pinned ≥ 2026.5.2 for its startup connectivity pre-checks.
- **D2 — no nginx.** `edge` and `app` collapse into one network. Two networks, not three.
- One deliberate reboot with `systemctl is-enabled` asserted across every stateful unit, before trusting an unattended one.

### Why staging goes first

F7 is the highest-consequence step in the plan — get it wrong and the box is unreachable. Rehearsing the full gate on a server where lockout costs nothing, before touching the one that matters, converts the plan's biggest risk into a dry run. The prod pass then executes a sequence that has already been proven end to end on identical software.

It also answers the question a provisioning *skill* exists to answer: does this work on a machine it wasn't written against? If staging doesn't come up clean from the skill alone, the skill isn't done — and that's far better discovered on box two than on box one.

**Verification:** external port scan returns nothing. Tailscale SSH works. A tunnel hostname serves a placeholder. Reboot survived clean. **Then repeat, unassisted, on prod.**

---

## Phase 2a — `db-backup-verify`, mechanism pass

Per F12: prove the machinery against a **seeded toy schema**, before a real schema exists. Runs against staging first.

**Scope:** three Postgres roles (app / backup / agent), the dump job, R2 upload, bucket lock, restore drill, alerting.

### Review changes folded in

- **D1 / F1 — split containers.** Dump sidecar on `data` (`internal: true`) writes to a shared volume; uploader holds R2 credentials and internet but no DB access. Neither process holds read-all-rows *and* egress.
- **F4 — token tier is part of the guarantee.** Server credential is **Object Read & Write, bucket-scoped** — never Admin. An Admin token can edit bucket config and therefore *remove the lock*, which makes the 30-day immutability decorative. Assert the tier at setup. Account API token, not User — a User token dies with its user and takes backups down silently.
- **F11 — don't hardcode wrangler flags.** Read `--help`, then assert the rule exists via `wrangler r2 bucket lock list`. The assertion is the deliverable; flag spelling drifts.
- **F13 — pin Postgres by digest**, and assert the drill container's major version **matches the source**. `pg_restore` into a newer major succeeds, so a drifted drill passes while testing a path production never takes. A drill that lies is worse than no drill.
- **EU jurisdiction endpoint** (`<accountid>.eu.r2.cloudflarestorage.com`) checked explicitly. A Hetzner box makes an EU bucket likely and the default endpoint simply won't reach it.
- Weekly B2 copy, Object Lock 90d, separate vendor *and* separate account.
- Drill failure is the **one** alert that pages (D6). Everything else is a report.
- Teardown tooling accounts for F4's second finding: **a bucket cannot be emptied while any lock rule exists.** Locks must be removed first — a deliberate step, never something a script does quietly.

**Verification:** the drill restores into a throwaway container and asserts row counts and a max timestamp. Then feed it a **deliberately corrupted dump** and confirm it fails loudly. An untested alarm is not an alarm.

---

## Phase 3 — `deploy-api`

Build, migrate, health-check, roll back. **No longer blocked on a stack choice** (D3).

### The contract

The skill reads a project manifest rather than inferring the stack:

| | |
|---|---|
| Health endpoint | Path + expected status. Must not depend on the DB being writable. |
| Migration command | Apply, **and** the down path — or an explicit statement that it's irreversible, and why |
| Listen port | Container-internal only |
| Build | Dockerfile path, digest-pinned base |
| Readiness | How to distinguish "started" from "serving" |

Ships with two or three worked reference implementations to prove the contract holds across stacks.

### Review changes folded in

- **F6 — mechanical invariant.** The build fails if any service in `compose.yml` declares `ports:`. "Publishes nothing to the host" is what makes ufw's guarantee true; it must not depend on anyone remembering it at 2am.
- **F8 — secrets done properly.** `POSTGRES_PASSWORD_FILE`, not `POSTGRES_PASSWORD`. Host files root-owned `chmod 600`, outside the worktree, plus a CI secret scan. Compose secrets outside Swarm are bind-mounted plaintext — they deliver the real win (out of `docker inspect`, `/proc/<pid>/environ`, and logs) but nothing more, and the skill must say so.
- **F9 — trusted-proxy handling.** Even without nginx, the app derives client IP from Cloudflare's forwarded headers and must not grant trust based on peer address. This is the single bug behind tens of thousands of exposed agent instances in early 2026; it applies to any localhost-trusting middleware, proxy or no proxy.
- **D4 — environment promotion.** Staging deploy → verify → prod deploy. Same artifact, different target.
- **Migration rollback plan.** Handoff §8 correctly names this as the thing an agent cannot infer. Every migration ships its down path or an explicit irreversibility statement. Expand-contract for anything destructive.

**Verification:** deploy to staging → health check passes → deliberately break a migration → roll back → the Phase 2a drill proves the data survived. Only then promote to prod.

---

## Phase 2b — `db-backup-verify`, real-schema pass

Re-point the drill's assertions at the real schema and real row counts. Small phase; it exists only because F12 makes it impossible to do earlier.

---

## Phase 4 — `server-health-report`

The read-only observer. Last, because a reporter needs things to report on.

**Scope** (unchanged from handoff §7): disk, memory, cert expiry, `apt list --upgradable`, reboot-required flag, backup freshness, failed systemd units, container health, base-image digest drift, log error rates. Output is a report or a PR. Never restart, delete, migrate, or deploy.

### F5 — five enforcement layers, not two

| Layer | Mechanism |
|---|---|
| 1 | SKILL.md instructions (handoff's original) |
| 2 | `disallowed-tools` frontmatter — removes tools from the pool while active |
| 3 | `disable-model-invocation: true` — no autonomous triggering |
| 4 | `deny` rules in `.claude/settings.json` + `PreToolUse` hook blocking destructive patterns |
| 5 | OS: sudoers whitelist or read-only Docker socket proxy; **never** the `docker` group (handoff's original) |

**Caveat that must be written into the skill:** `allowed-tools` / `disallowed-tools` grants clear at the user's next message. They are per-turn, not a persistent sandbox. Layers 4 and 5 stay mandatory — 2 and 3 are depth, not the floor.

**F14 — this skill must be committed to the repo's `.claude/skills/`.** Scheduled and cloud sessions start fresh and do not read `~/.claude/skills/`; a personal-only skill reports as not found the first time a routine fires. Functional requirement, not preference.

**Verification:** run against both live boxes; every finding traced to real state. Then attempt a write through each layer and confirm refusal at more than one.

---

## Cross-cutting conventions

**Skill authoring**
- Repo `.claude/skills/<name>/SKILL.md` (F14)
- `description` + `when_to_use` under 1,536 chars — that's where the listing truncates
- Narrow skills with distinct triggers; the handoff's four-not-one call is right
- Long reference material in sibling files loaded on demand; the body stays short

**Content rules — from F9's failure mode**
- Skills state **mechanisms and cite sources**. They do not carry statistics. A wrong figure in a SKILL.md gets restated confidently by every agent that loads it.
- Anything version- or product-specific is **verified at run time**, not restated from a document written in August 2026
- Every skill opens with its escalation triggers

**Escalation triggers, consolidated** — stop and ask:

1. Give the ops agent write access to production
2. Skip the restore drill
3. Expose a tunnel hostname without a Cloudflare Access policy
4. Add the agent user to the `docker` group
5. Publish a container port to the host *(new, F16)*
6. Place an Admin-tier R2 token on the server *(new, F16)*

---

## Sequence

```
Phase 0   scaffold
    │
Phase 1   vps-provision → STAGING ──── rehearses F7 where lockout is free
    │                    ↓
          vps-provision → PROD ─────── proven sequence, second run
    │
Phase 2a  db-backup-verify ─────────── mechanism, toy schema
    │
Phase 3   deploy-api ──────────────── staging → verify → promote to prod
    │
Phase 2b  db-backup-verify ─────────── real schema
    │
Phase 4   server-health-report ─────── needs everything above to exist
```

---

## Deferred, deliberately

Recorded so they're choices rather than oversights.

- **pgBackRest** — stay on `pg_dump`. Archived April 2026, revived May 2026 under coalition funding (F10). Viable again, but `pg_dump` is right until we outgrow it.
- **Remediation agent** — staging-only or behind an explicit human gate, per handoff §7. D4 now gives it a legitimate home, but it is not in scope.
- **Backup retention beyond 30/90 days** and DB-size-driven strategy — needs real data volume.
- **nginx / multi-service routing** — the reason its config stays in the repo unwired (D2). Reversal condition: a second service within ~2 months.
