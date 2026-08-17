# HANDOFF — Secure API + Postgres deployment on a single VPS

> **Preserved as received, 2026-08-17.** Reviewed in [`01-review.md`](01-review.md).
> Where the two disagree, the review wins — it carries the sources.

**Status:** Architecture agreed. Nothing built yet. No server provisioned.
**Date:** 2026-08-17
**Audience:** The next agent picking up this work.

---

## 1. What we're building

A production API with a Postgres database on a single VPS, deployed so that **zero inbound ports are open to the internet**. Public traffic arrives via Cloudflare Tunnel; admin access arrives via Tailscale. Backups go to Cloudflare R2 with a second copy on Backblaze B2.

After the infrastructure exists, we build **four Claude Skills** so this becomes repeatable, plus a **read-only ops agent** that reports on server health.

**Deliverables not yet produced:** `compose.yml`, nginx config, ufw/Tailscale/cloudflared setup, backup + drill scripts, the four SKILL.md files.

---

## 2. Decisions locked in

Do not relitigate these without asking the user. Each has a reason recorded in §7.

| Area | Decision |
|---|---|
| Compute | Hetzner VPS, Ubuntu LTS — **but keep everything provider-agnostic** |
| Stack | Docker Compose + Postgres |
| Public ingress | Cloudflare Tunnel (`cloudflared`), outbound-only |
| Admin ingress | Tailscale; public SSH removed entirely |
| Reverse proxy | nginx, **behind** the tunnel (optional but default-on) |
| Edge security | Cloudflare Access on admin routes, WAF + rate limiting |
| Primary backups | Cloudflare R2, bucket lock 30 days |
| Secondary backups | Backblaze B2, Object Lock 90 days, weekly |
| Ops agent autonomy | **Read-only. Reports to the user. No writes, ever.** |
| Deploy model | Reviewed artifacts to prod. **No live agent editing of production.** |

**Provider-agnostic means:** assume only Ubuntu LTS + Docker + ufw, with the host as a variable. Hetzner Cloud Firewall is an optional extra layer, not a dependency. Cloudflare is the fixed part.

---

## 3. Network architecture

Two planes that never overlap:

- **Admin plane — Tailscale.** VPS joins the tailnet. Once verified working, the public SSH rule is *deleted*, not just restricted. Port 22 ceases to exist to the internet.
- **Public plane — Cloudflare Tunnel.** `cloudflared` opens an outbound-only connection to Cloudflare's edge. TLS terminates at Cloudflare. Origin IP is never associated with the domain. DDoS absorbed at the edge.

Net result: ufw denies 100% of inbound, and the server still serves production traffic.

**Rule:** anything that is not the public API — admin panels, dashboards, pgAdmin, monitoring UIs — is either behind Cloudflare Access or Tailscale-only. Never a bare tunnel hostname.

### Compose network topology

Three networks:

- `edge` — `cloudflared` + `nginx` only
- `app` — `nginx` + API
- `data` — API + Postgres, marked **`internal: true`**

Postgres publishes **no ports at all**, not even to `127.0.0.1`. `internal: true` also blocks outbound internet from the DB, which closes an exfiltration path. Reach psql via `docker compose exec` over Tailscale.

The stack publishes nothing to the host.

---

## 4. Security requirements

### nginx

- **Hardcode the upstream.** Never let user input reach `proxy_pass` — that is an SSRF hole.
- **Restore the real client IP.** Set `X-Real-IP` / `X-Forwarded-For` correctly and read them in the app. With a proxy in front, any "localhost is trusted" logic in the application is silently disabled — this exact bug exposed 1,800+ AI-agent instances in 2026.
- `server_tokens off`, `client_max_body_size` capped, `proxy_hide_header` for backend leakage.
- Per-location rate limits. ~5r/s burst=10 for API endpoints is a sane starting point.
- Keep nginx patched; keep rewrite rules simple (CVE-2026-42945, rewrite module heap overflow).

### Secrets

Use Docker secrets, not plain environment variables — env vars are visible in `docker inspect`, in `/proc/<pid>/environ`, and leak into logs.

### Postgres roles — three, not one

1. **App role** — non-superuser, owns only its own schema.
2. **Backup role** — dedicated, minimal.
3. **Agent role** — `pg_read_all_stats`-style. Can see connection counts, table sizes, slow queries. **Cannot read row data.** This keeps customer data outside the agent's blast radius, which matters because the agent also reads logs containing attacker-controlled strings.

### Docker group is root

When creating the unprivileged ops-agent user, **do not add it to the `docker` group** — that is equivalent to host root and silently defeats the read-only design. Instead: a tight `NOPASSWD` sudoers whitelist (`docker ps`, `docker compose logs`, `systemctl status`, `df`, `apt list --upgradable`) or a read-only Docker socket proxy exposing GET endpoints only.

---

## 5. Backups

### Design

- **Daily:** `pg_dump -Fc` → `rclone` → R2. Bucket lock, 30-day retention.
- **Weekly:** copy → B2. Object Lock, 90 days. Different vendor, different account.
- **Monthly (minimum):** restore drill.

### Restore drill — non-negotiable

Pull the newest dump into a throwaway `postgres:18-alpine` container, restore it, assert row counts and a max timestamp. **A failed drill is the one alert that should wake the user up.** A backup system is only as good as its last successful restore.

### R2 specifics — these bit us in research

- **R2 has no write-only token scope.** Permission levels are Admin Read & Write, Admin Read only, Object Read & Write, Object Read only. Only the two Object-level ones can be bucket-scoped. A token that writes backups can also delete them.
- **Therefore use bucket locks**, not credential scoping, for immutability:
  ```
  npx wrangler r2 bucket lock add my-backups \
    --name pgdump-retention --prefix postgres/ --retention-days 30
  ```
  A fully compromised server holding valid credentials still cannot erase 30 days of dumps.
- **Use an Account API token, not a User token.** User tokens go inactive if that user leaves the account, which silently breaks backups.
- **EU jurisdiction buckets need `https://<accountid>.eu.r2.cloudflarestorage.com`.** The default endpoint will not reach them. Given a Hetzner box, an EU bucket is likely — this is a common first-hour failure.

### Cloudflare account is a single point of compromise

Tunnel + WAF + DNS + backups all live in one account. Mitigations: **hardware-key 2FA** (not TOTP) on that account, and the B2 second copy. Bucket locks protect against a compromised *server*; a second vendor protects against a compromised *account*.

---

## 6. Patching, monitoring, maintenance

- `unattended-upgrades` ships enabled on Ubuntu Server and runs daily. **Scope it to security origins only.** Always `--dry-run` before rolling out.
- `needrestart` (22.04+) handles the case where a patched library is installed but running processes hold the old copy in memory.
- **If auto-reboot is disabled, a reboot-required alert is mandatory.** "No auto-reboot without monitoring" = "never reboot", which is the failure mode.
- Before trusting a 4am reboot, do one deliberate reboot and confirm every stateful service comes back. Check `systemctl is-enabled` on everything that matters.
- **`unattended-upgrades` does not patch containers.** It patches the host. Pin images by digest and make "newer base image digest available" a thing the ops agent *reports*. Do **not** use Watchtower-style auto-pull on production — silent image replacement turns a 10-second outage into a 40-minute one.
- Monitoring UI (Uptime Kuma / Beszel) binds to the Tailscale interface only. Never through the tunnel.

---

## 7. Why the agent is read-only

The user chose read-only. This is the right call and should not be quietly widened.

A monitoring agent reads logs. Logs contain attacker-controlled strings. Combined with database access and any outbound capability, that assembles the "lethal trifecta" — private data access, untrusted content exposure, external communication — on the machine holding production data.

Framing to preserve: *least privilege* asks what an identity can access; *least agency* asks what the agent is allowed to decide. OWASP's Top 10 for Agentic Applications treats Excessive Agency as its own failure category.

**Scope of the ops agent:** disk, memory, cert expiry, `apt list --upgradable`, reboot-required flag, backup freshness, failed systemd units, container health, base-image digest drift, error rates in logs. Output is a report or a PR. It can never restart, delete, migrate, or deploy.

Any remediation agent added later runs against **staging only**, or against prod behind an explicit human gate. Useful precedent: Claude Code Routines defaults to pushing only to `claude/`-prefixed branches so a bad routine can't touch main.

Additional guards regardless of scope: a pre-tool hook blocking destructive shell patterns (`rm -rf /`, `git reset --hard`, mass `chmod`), harness runs as an unprivileged user never root, and a snapshot before any destructive operation.

**Context worth knowing:** this architecture is modelled on Pieter Levels' publicly documented stack (Hetzner + SSH + Tailscale + Cloudflare Tunnels + inbound deny). We deliberately copied his *network* design and rejected his *deploy* stage 3 — Claude Code live-editing production. He himself scopes that to solo builders who own the error budget; teams need staging.

---

## 8. Skills to build

Four narrow skills, not one large one — they have different trust levels and different trigger conditions.

1. **`vps-provision`** — one-time hardening runbook: user creation, SSH keys, ufw, Tailscale, cloudflared, nginx baseline. Mostly dormant after first run.
2. **`deploy-api`** — build, migrate, health-check, roll back. **Must include the migration rollback plan** — that is the thing an agent cannot infer.
3. **`db-backup-verify`** — backup configuration plus the restore drill. High-value, low-risk, so this one can be fairly autonomous.
4. **`server-health-report`** — the read-only observer from §7. No write operations, enforced both in the skill's instructions *and* at the OS permission level.

### Build order

**hardening + tunnel → backups + drill → deploy pipeline → health agent**

Backups come *before* the deploy pipeline because you cannot safely iterate on deploys until a bad migration is recoverable. The health agent goes last because it is a reporter — the timers, containers, and drill jobs must exist before there is anything to observe.

---

## 9. Open questions for the user

- Domain name and Cloudflare zone — not yet named.
- API language/framework — unspecified. Affects the Dockerfile and the health-check endpoint.
- Whether nginx stays. It is optional for a single service (cloudflared can route straight to the API). Kept by default for per-endpoint rate limiting, request-size caps, slow-client buffering, and future multi-service use. Dropping it is defensible and removes a config surface.
- Staging server: yes or no? Currently assumed no (solo). Changes the deploy skill materially if yes.
- Alert channel for the drill-failure alarm (ntfy, email, Slack?).
- Backup retention beyond 30/90 days, and expected DB size.

---

## 10. Verify before relying on

Product details researched August 2026. Re-check if significant time has passed:

- R2 token permission levels and whether a true write-only scope has been added.
- R2 bucket lock syntax in current Wrangler.
- B2 Object Lock configuration.
- Current nginx CVEs.
- pgBackRest maintenance status — there was a scare in May 2026; the project announced it will continue. Only relevant if we outgrow `pg_dump`.

### Escalation triggers — stop and ask the user

- Any request to give the ops agent write access to production.
- Any request to skip the restore drill.
- Any request to expose a hostname through the tunnel without a Cloudflare Access policy.
- Any request to add the agent user to the `docker` group.
