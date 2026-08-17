# Build plan

**Depends on:** [`01-review.md`](01-review.md). Findings are referenced as F1–F17.

The handoff's build order is kept — **harden → back up → deploy → observe** — with F12's split applied and F3's simplification folded in. Each phase ends in something committed and verified, so an interrupted session can be resumed from the repo alone.

---

## Phase 0 — Decisions and scaffold

Nothing below can start until the six blocking decisions are made. Four are new or changed by the review; two are carried over from handoff §9.

| # | Decision | Recommendation | From |
|---|---|---|---|
| D1 | Backup topology | **B** — dump sidecar + separate uploader | F1 |
| D2 | nginx in or out | **Out** for launch; config kept unwired | F2, F3 |
| D3 | API language/framework | — user's call | §9 |
| D4 | Staging environment | **No** for launch; revisit at first paying user | §9 |
| D5 | Domain + Cloudflare zone | — user's call | §9 |
| D6 | Drill-failure alert channel | **ntfy** — no SMTP, phone push, 10 min setup | §9 |

**Deliverables**

- `docs/03-decisions.md` — decision record superseding handoff §2, each entry dated with its rationale
- Repo scaffold: `.claude/skills/`, `infra/`, `scripts/`
- `.gitignore` + secret scanning in CI (F8 — ignored ≠ absent)
- A corrected fact sheet the skills cite instead of restating: pinned versions, CVE floor, R2 token tier

**Done when:** D1–D6 are recorded and the repo has a committed structure.

---

## Phase 1 — `vps-provision`

One-time hardening runbook. Mostly dormant after first run, so it must be written for someone who has not read it in eight months.

**Scope:** unprivileged user, SSH keys, ufw, Tailscale, cloudflared, host baseline (`unattended-upgrades` scoped to security origins, `needrestart`, reboot-required alerting).

**Review changes folded in**

- **F7 — the SSH gate.** The destructive step is fenced: add `ufw allow in on tailscale0 to any port 22 proto tcp` → prove **two** independent tailnet sessions → parse `ufw status numbered` and assert no port-22 rule lacks an interface scope → *only then* delete the generic rule. Out-of-band recovery path (provider console) confirmed and written down **before** any of it. Order is never reversed.
- **F6 — `DOCKER-USER` default DROP**, persisted across reboot. ufw alone does not govern a Docker host.
- **F15 — locally-managed tunnel.** `config.yml` in the repo, terminating `http_status:404` catch-all, `cloudflared` on a user-defined network, image pinned ≥ 2026.5.2.
- **F2/F3 — no nginx** if D2 = out. Collapses `edge` + `app` into one network.
- One deliberate reboot, with `systemctl is-enabled` asserted across every stateful unit, before trusting an unattended one.

**Verification:** external port scan returns nothing. Tailscale SSH works. A tunnel hostname serves a placeholder. Reboot survived clean.

**Risk:** highest-consequence phase in the plan — a botched step 7 costs the server. Recovery path first, always.

---

## Phase 2a — `db-backup-verify`, mechanism pass

Per F12: prove the machinery against a **seeded toy schema** before a real schema exists.

**Scope:** three Postgres roles (app / backup / agent, F-per-handoff §4), the dump job, R2 upload, bucket lock, restore drill, alerting.

**Review changes folded in**

- **F1 — split containers.** Dump sidecar on `data` (`internal: true`) writes to a shared volume; uploader holds R2 credentials and internet but no DB access. Neither process holds read-all-rows *and* egress.
- **F4 — token tier is part of the guarantee.** Server credential is **Object Read & Write, bucket-scoped**, never Admin. Assert the tier at setup; an Admin token can remove the lock and silently voids immutability. Account API token, not User (a User token dies with its user).
- **F11 — don't hardcode wrangler flags.** Read `--help`, then assert the rule exists via `wrangler r2 bucket lock list`. The assertion is the deliverable; the flag spelling drifts.
- **F13 — pin Postgres by digest**, and assert the drill container's major version **matches the source**. `pg_restore` into a newer major succeeds, so a drifted drill passes while testing a path production never takes.
- EU jurisdiction endpoint (`<accountid>.eu.r2.cloudflarestorage.com`) checked explicitly — a Hetzner box makes an EU bucket likely, and the default endpoint simply won't reach it.
- Weekly B2 copy, Object Lock 90d, separate vendor and account.
- Drill failure is the **one** alert that pages. Everything else is a report.

**Verification:** drill restores into a throwaway container and asserts row counts and a max timestamp. A deliberately corrupted dump must make the drill **fail loudly** — an untested alarm is not an alarm.

---

## Phase 3 — `deploy-api`

Build, migrate, health-check, roll back. Gated on D3.

**Scope:** Dockerfile, digest pinning, migration apply, health check, rollback.

**Review changes folded in**

- **F6 — mechanical invariant.** Build fails if any service in `compose.yml` declares `ports:`. The "publishes nothing to the host" property is what makes ufw's guarantee true; it must not depend on memory.
- **F8 — secrets done properly.** `POSTGRES_PASSWORD_FILE` not `POSTGRES_PASSWORD`; host files root-owned `chmod 600`; secrets outside the worktree; CI secret scan.
- **F9 — trusted-proxy handling.** Even without nginx, the app must derive client IP from Cloudflare's forwarded headers and must not grant trust based on the peer address. This is the single bug behind tens of thousands of exposed agent instances; it applies to any localhost-trusting middleware.
- **F2 — if nginx is in** (D2 = keep): version floor covering **both** CVE-2026-42945 and CVE-2026-9256, plus a config lint for 9256's trigger — overlapping PCRE captures with a multi-capture replacement in redirect/args context.
- **Migration rollback plan.** The handoff correctly names this as the thing an agent cannot infer. Every migration ships with its down path, or with an explicit written statement that it is irreversible and why. Expand-contract for anything destructive.

**Verification:** deploy → health check passes → deliberately break a migration → roll back → drill from Phase 2a proves the data survived.

---

## Phase 2b — `db-backup-verify`, real-schema pass

Re-point the drill's assertions at the real schema and real row counts. Small phase; it exists because F12 makes it impossible to do earlier.

---

## Phase 4 — `server-health-report`

The read-only observer. Last, because a reporter needs things to report on.

**Scope** (unchanged from handoff §7): disk, memory, cert expiry, `apt list --upgradable`, reboot-required flag, backup freshness, failed systemd units, container health, base-image digest drift, log error rates. Output is a report or a PR. Never restart, delete, migrate, or deploy.

**Review changes folded in — F5, the five enforcement layers:**

| Layer | Mechanism |
|---|---|
| 1 | SKILL.md instructions (handoff's original) |
| 2 | `disallowed-tools` frontmatter — removes tools from the pool |
| 3 | `disable-model-invocation: true` — no autonomous triggering |
| 4 | `deny` rules in `.claude/settings.json` + `PreToolUse` hook blocking destructive patterns |
| 5 | OS: sudoers whitelist or read-only Docker socket proxy; **never** the `docker` group (handoff's original) |

**Caveat that must be written into the skill:** `allowed-tools` / `disallowed-tools` grants clear at the user's next message. They are per-turn, not a persistent sandbox. Layers 4 and 5 stay mandatory — 2 and 3 are depth, not the floor.

Also: **F14 — this skill must be committed to the repo's `.claude/skills/`.** Scheduled and cloud sessions start fresh and do not read `~/.claude/skills/`; a personal-only skill reports as not found the first time a routine fires. Functional requirement, not preference.

**Verification:** run against the live box; every finding traced to a real state. Then attempt a write through each layer and confirm it's refused at more than one.

---

## Cross-cutting conventions

Applied to all four skills.

**Skill authoring**
- Repo `.claude/skills/<name>/SKILL.md` (F14)
- `description` + `when_to_use` under 1,536 chars — that's where the listing truncates
- Narrow skills, distinct triggers — the handoff's four-not-one call is right
- Long reference material in sibling files, loaded on demand; the body stays short

**Content rules — from F9's failure mode**
- Skills state **mechanisms and cite sources**; they do not carry statistics
- Anything version- or product-specific is **verified at run time**, not restated from a doc written in August 2026
- Every skill opens with its escalation triggers, including the two added in F16:
  - publishing a container port to the host
  - placing an Admin-tier R2 token on the server

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
Phase 0  decisions + scaffold
   │
Phase 1  vps-provision ──────── highest risk (SSH deletion gate)
   │
Phase 2a db-backup-verify ───── mechanism, toy schema
   │
Phase 3  deploy-api ─────────── needs D3
   │
Phase 2b db-backup-verify ───── real schema
   │
Phase 4  server-health-report ─ needs everything above to exist
```

---

## Deferred, deliberately

Recorded so they're choices rather than oversights.

- **Staging environment** (D4) — revisit at first paying user. Changes `deploy-api` materially.
- **pgBackRest** — stay on `pg_dump`. Project was archived April 2026 and revived May 2026 under coalition funding (F10); it's viable again, but `pg_dump` is right until we outgrow it.
- **Remediation agent** — staging-only or behind an explicit human gate, per handoff §7. Not in scope.
- **Backup retention beyond 30/90 days**, and DB-size-driven strategy — needs real data volume.
- **Multi-service routing** — the reason nginx's config stays in the repo despite being unwired (F3).
