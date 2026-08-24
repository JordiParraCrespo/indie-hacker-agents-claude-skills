# Review of the deployment handoff

**Reviewed:** 2026-08-17 · **Source:** [`00-handoff.md`](00-handoff.md) · **Method:** every product claim re-verified against vendor docs and primary reporting; every architectural claim traced for internal consistency.

**Verdict: the architecture is sound and should be built.** The threat model is coherent, the network design is correct, and several details it gets right are ones most guides get wrong. What follows is 17 findings — 3 that block writing `compose.yml`, 5 that change what goes in a skill file, and the rest corrections and hardening.

---

## What's right (don't relitigate)

These are load-bearing and correct. Listing them so the next agent doesn't "improve" them.

- **Two-plane split** (Tailscale admin / Cloudflare Tunnel public, never overlapping). Correct, and the reasoning is right.
- **`internal: true` on the data network + no host port publishing.** Verified: an internal network gets no gateway, so Postgres has no route out. This genuinely closes an exfiltration path.
- **Three Postgres roles, with the agent role unable to read row data.** Better than most production setups. Keep it.
- **Not adding the ops-agent user to the `docker` group.** Correct — group `docker` is host root. This is the single most commonly botched detail in "read-only agent" designs.
- **Read-only agent, lethal-trifecta reasoning, least-privilege vs least-agency framing.** Correct and worth preserving verbatim in the skill.
- **Restore drill as the one paging alert.** Right priority. A backup is a hypothesis until restored.
- **Two threat models kept distinct:** bucket lock defends a compromised *server*; a second vendor defends a compromised *account*. Many designs conflate these and buy only one.
- **Build order rationale** (backups before deploy pipeline). Right instinct — see F12 for the one wrinkle.

---

## Blocking — resolve before writing `compose.yml`

### F1 · The backup job contradicts the network design 🔴

`data` is `internal: true`, so nothing on it can reach the internet. The daily job is `pg_dump -Fc` → `rclone` → R2, which needs **both** Postgres (on `data`) **and** outbound internet. As specified, this cannot run. The handoff never notices the conflict.

Three ways out:

| Option | Shape | Assessment |
|---|---|---|
| **A** | One backup container on `data` + an egress network | Works, fewest moving parts. But that container can now read every row *and* talk to the internet — precisely the lethal-trifecta shape §7 is careful about elsewhere. |
| **B** | Dump sidecar on `data` writes to a shared volume; separate uploader with internet but no DB access | **Recommended.** No single process holds both capabilities. Costs one extra container and a volume. |
| **C** | `pg_dump` from the host via `docker compose exec`, upload from host | Works, but moves logic out of the compose file into host cron — worse for the "reviewed artifacts" principle. |

Option B preserves the isolation property the design was built around. Whichever is chosen must be written down as a decision, because it is not recoverable from the compose file alone.

### F2 · nginx: the cited CVE is real, but it is the *wrong one to stop at* 🔴

The handoff cites **CVE-2026-42945** ("NGINX Rift", CVSS 9.2, heap buffer overflow in the rewrite module, unauthenticated DoS→RCE). Confirmed real.

What it misses: **CVE-2026-9256** ("nginx-poolslip") is a *second, distinct* heap overflow in the *same* module, disclosed roughly nine days later. Critically — **upgrading to 1.31.0 or 1.30.1 to patch 42945 leaves you exposed to 9256.** An agent following the handoff literally would patch, verify the CVE it was told about, and report itself secure.

9256 has a concrete trigger: a `rewrite` regex with distinct overlapping PCRE captures (e.g. `^/((.*))$`) whose replacement references multiple such captures (e.g. `$1$2`) in a redirect or arguments context. The handoff's "keep rewrite rules simple" is the right instinct but not actionable. Encode the actual pattern as a lint check.

**Action:** pin a version that fixes *both*, verified at build time — not from this document, which will go stale. Add a config lint for the 9256 trigger shape. And see F3, which questions whether nginx should be there at all.

### F3 · "Whether nginx stays" is no longer a neutral open question 🟠

The handoff lists this as an open question with a mild default-on. Two critical RCE-class vulnerabilities in the same nginx module in one quarter changes the arithmetic. Its four stated benefits are mostly available at the edge already:

| Reason to keep nginx | Covered by Cloudflare edge? |
|---|---|
| Per-endpoint rate limiting | Yes — WAF rate limiting rules |
| Request-size caps | Yes — edge upload limits |
| Slow-client buffering | Partly — Cloudflare terminates and buffers |
| Future multi-service routing | No — but `cloudflared` ingress rules route by hostname/path |

**Recommendation: drop nginx for launch.** For a single service, `cloudflared → API` removes an entire RCE-exposed component from a box whose whole design goal is minimal attack surface. Keep the nginx config in the repo, unwired, for when a second service arrives. If it stays, F2's pin and lint are mandatory, not optional.

Note this collapses the `edge`/`app` networks into one and simplifies the compose file considerably.

---

## Changes what goes in a skill file

### F4 · Bucket-lock immutability depends on the *token tier* — the handoff loses this 🟠

The R2 facts are all verified correct: four permission levels; only Object-level can be bucket-scoped; a writing token can also delete. But the conclusion — "therefore use bucket locks, **not** credential scoping" — is a false either/or.

An **Admin**-tier token can *edit bucket configuration*, and therefore **remove the lock**. If the server holds an Admin token, the 30-day guarantee is decorative. The guarantee holds only when both are true:

1. A bucket lock rule exists, **and**
2. the server's credential is **Object Read & Write, bucket-scoped** — it can delete objects (blocked by the lock) but cannot touch bucket config (so cannot remove the lock).

It's lock **AND** scoping, not lock *instead of* scoping. Rewrite that section.

Also newly surfaced from the docs, and operationally important: **a bucket cannot be emptied while any lock rule is configured**, and all lock rules must be removed before emptying. Any cleanup or teardown tooling has to account for that, and it should be a deliberate two-person-rule-style step, not something a script does silently.

### F5 · The read-only agent is missing its cheapest enforcement layer 🟠

§8 says enforce read-only "in the skill's instructions *and* at the OS permission level." Both correct. But skills have native mechanisms sitting between those two, and they're free:

| Layer | Mechanism |
|---|---|
| 1 | `disallowed-tools` in SKILL.md frontmatter — removes tools from the pool while active |
| 2 | `disable-model-invocation: true` — Claude can't autonomously trigger it |
| 3 | `context: fork` — runs the reporter in its own subagent context |
| 4 | `deny` rules in `.claude/settings.json` + a `PreToolUse` hook |
| 5 | OS: sudoers whitelist / read-only Docker socket proxy (as the handoff already specifies) |

Five layers instead of two, at no cost. **One caveat that must be understood:** `allowed-tools` / `disallowed-tools` grants clear at the user's next message — they are per-turn, not a persistent sandbox. They are defence in depth, never the only control. The OS layer stays mandatory.

### F6 · ufw does not fully govern a Docker host 🟠

"ufw denies 100% of inbound" is true here, but *only because* the stack publishes nothing to the host — and that's stated in passing, as if incidental. It's load-bearing.

Docker publishes ports by writing NAT/PREROUTING and FORWARD rules; ufw governs INPUT. Published container ports bypass ufw entirely. This is documented Docker behaviour, not a bug. The moment anyone adds `ports:` to debug something at 2am, ufw silently stops protecting that port and `ufw status` still reads clean.

**Action:** two guards, both cheap.
- `vps-provision` installs a default-DROP rule in the `DOCKER-USER` chain (evaluated before Docker's own rules), persisted across reboot.
- `deploy-api` fails the build if any service in `compose.yml` has a `ports:` key. Make the invariant mechanical, not remembered.

### F7 · The SSH-deletion step needs a hard gate, not a sentence 🟠

"Once verified working, the public SSH rule is *deleted*" is the correct destination and the single highest-risk step in the whole runbook — get it wrong and the box is unreachable. The handoff doesn't encode the verification.

Tailscale's own ufw guidance and the common lockout reports converge on one non-obvious trap: **a generic `22/tcp ALLOW IN Anywhere` rule silently defeats an interface-scoped rule.** Allowing `in on tailscale0 to any port 22` while a generic allow still exists means you've changed nothing; deleting the generic one while the interface rule is malformed means lockout.

`vps-provision` must gate the destructive step on:
1. Two independent sessions proven live over the tailnet, not one.
2. `ufw status numbered` parsed, asserting no port-22 rule lacks an interface scope.
3. An out-of-band recovery path confirmed *first* (provider console / rescue mode) and written into the skill — the whole point of provider-agnostic is that this differs per host.

Order matters: add the tailscale0 rule → verify → *then* delete the generic rule. Never the reverse.

### F8 · "Docker secrets" claims more than Compose delivers 🟡

Outside Swarm, a Compose `secrets:` entry is a **bind mount of a host file** to `/run/secrets/<name>`. Plaintext on disk, no encrypted store.

The stated benefit is still entirely real — the value stays out of `docker inspect`, out of `/proc/<pid>/environ`, and out of logs, which is exactly what the handoff wanted. Keep the decision. But the skill must specify what actually protects the file, or "we use Docker secrets" will read as stronger than it is:

- Host secret files root-owned, `chmod 600`.
- Secrets directory outside the git worktree (or `.gitignore`d *and* secret-scanned in CI — ignored is not the same as absent).
- `POSTGRES_PASSWORD_FILE`, not `POSTGRES_PASSWORD` — the official image supports the `_FILE` convention.

---

## Corrections

### F9 · The "1,800+ instances" figure is wrong — and it's the kind of wrong that propagates 🟡

The **mechanism** the handoff describes is exactly right and well-documented: an app that trusts localhost, placed behind a reverse proxy that forwards from 127.0.0.1, grants unauthenticated admin access to the internet. This is a genuinely excellent thing to have caught and it justifies the `X-Real-IP`/`X-Forwarded-For` requirement.

The number does not survive checking. Bitsight's scans (27 Jan – 8 Feb 2026) found **more than 30,000** distinct exposed instances; other write-ups say "hundreds." "1,800+" matches nothing.

This matters more than a normal typo because it's destined for a skill file — a wrong figure in a SKILL.md gets restated confidently by every agent that loads it. **Keep the mechanism, cite the source, drop the number.** General rule for this repo: skills state mechanisms and cite sources; they don't carry statistics that rot.

### F10 · pgBackRest — closer to the line than "a scare" 🟡

Handoff: "there was a scare in May 2026; the project announced it will continue."

Actually: the sole maintainer **archived the project on 27 April 2026** citing lack of funding. It was **revived on 18 May 2026** by a sponsor coalition (AWS and Percona among them), deliberately structured so no single sponsor's exit can repeat it, with a stated intent to add a second maintainer.

Conclusion is unchanged — stay on `pg_dump`, revisit only if we outgrow it. But "archived, then rescued" is the fact, and it's a better argument for the second-vendor B2 copy than "a scare" is.

### F11 · Don't hardcode the wrangler bucket-lock command 🟡

Current docs show `wrangler r2 bucket lock add <BUCKET_NAME> [OPTIONS]`, and secondary sources show `[BUCKET] [NAME] [PREFIX]` as positionals — i.e. the handoff's `--name` / `--prefix` flags may or may not match the installed Wrangler.

`db-backup-verify` should read `wrangler r2 bucket lock add --help` at run time and then **assert the result** via `wrangler r2 bucket lock list`. Verifying the rule exists is what matters; the flag spelling is incidental and will drift.

### F12 · Build order has a chicken-and-egg 🟡

"Backups before deploy pipeline" is correct reasoning — you can't safely iterate on deploys until a bad migration is recoverable. But the restore drill needs a database with a schema, and the schema arrives via the deploy pipeline's migrations. Built literally, you'd construct a drill against an empty database and discover it doesn't work the first time it matters.

**Fix — split `db-backup-verify` into two passes:**
- **2a (before deploy):** build and validate the *mechanism* — dump → R2 → restore into a throwaway container → assert — against a seeded toy schema.
- **2b (after deploy):** re-point the assertions at the real schema and real row counts.

Preserves the ordering rationale, removes the impossibility.

### F13 · Postgres pinning 🟡

`postgres:18-alpine` is current and correct (18.6, released 13 Aug 2026). Two notes:

- PG 19 typically lands around September 2026. The handoff already mandates digest pinning for containers — apply it here too, or `18-alpine` will silently become something else.
- The drill container's major version must **match the source**, asserted, not assumed. `pg_restore` tolerates restoring into a newer major, so a drifted drill will pass while testing a path production doesn't use. That's a drill that lies.

### F14 · Skills must live in the repo, not `~/.claude/skills/` 🟡

If the ops agent ever runs on a schedule — which "reports to the user" implies — this is decisive. Scheduled and cloud sessions start as fresh remote sessions and **do not read `~/.claude/skills/`** on your machine; a skill that lives only there reports as not found. Cloud sessions do load project skills committed to the repo's `.claude/skills/`.

**Action:** all four skills go in this repo's `.claude/skills/`, committed. Not a preference — a functional requirement for `server-health-report`.

### F15 · cloudflared: remote-managed vs local config is an unmade decision 🟡

The 2026 default steers toward **remotely-managed** tunnels — ingress config lives in the Cloudflare dashboard, the local `cloudflared` holds only a token. That quietly conflicts with the locked-in "reviewed artifacts to prod, no live editing" principle: dashboard-managed ingress is production config living outside the repo and outside review, changeable by anyone with dashboard access.

**Recommend locally-managed** (`config.yml` in the repo) for exactly the reason the handoff already argues elsewhere. Three details for the skill:

- The ingress list **requires a terminating `- service: http_status:404`** catch-all. Without it, unmatched requests fail in a way that is miserable to debug.
- `cloudflared` and its target must share a **user-defined** network — service-name DNS doesn't resolve on the default bridge.
- Pin the image; 2026.5.2+ adds startup connectivity pre-checks that diagnose blocked egress for you.

### F16 · Two missing escalation triggers 🟡

§10's list is good. Add:

- **Any request to publish a container port to the host** (per F6 — this is the moment ufw stops meaning what everyone thinks it means).
- **Any request to place an Admin-tier R2 token on the server** (per F4 — this makes the bucket lock removable and silently voids the backup guarantee).

### F17 · Unverified claims flagged, not resolved 🟢

Two things stated in the handoff that I did not independently confirm and that nothing depends on: the OWASP Top 10 for Agentic Applications "Excessive Agency" categorisation, and the characterisation of Pieter Levels' stack. Both are used as framing rather than as load-bearing technical decisions, so neither blocks anything. Flagged only so they aren't mistaken for verified.

---

## Severity summary

| | Finding | Effect if ignored |
|---|---|---|
| 🔴 | F1 backup vs `internal: true` | Backups don't run at all |
| 🔴 | F2 second nginx CVE | Patch, verify, still vulnerable |
| 🟠 | F3 nginx worth dropping | Avoidable RCE surface |
| 🟠 | F4 Admin token removes lock | Backup immutability is decorative |
| 🟠 | F5 skill-level enforcement | Weaker read-only guarantee than available |
| 🟠 | F6 Docker bypasses ufw | Silent exposure on first `ports:` |
| 🟠 | F7 SSH deletion gate | Locked out of the server |
| 🟡 | F8–F16 | Corrections, drift, and rot |
| 🟢 | F17 | Noted only |

---

## Sources

nginx: [Akamai — CVE-2026-42945](https://www.akamai.com/blog/security-research/nginx-critical-heap-buffer-overflow-cve-2026-42945) · [F5 — CVE-2026-9256](https://my.f5.com/manage/s/article/K000161377) · [oss-security disclosure](https://www.openwall.com/lists/oss-security/2026/05/22/14) · [The Hacker News](https://thehackernews.com/2026/05/18-year-old-nginx-rewrite-module-flaw.html)

Exposed agents: [Bitsight](https://www.bitsight.com/blog/openclaw-ai-security-risks-exposed-instances) · [OpenClaw trusted-proxy docs](https://docs.openclaw.ai/gateway/trusted-proxy-auth)

R2: [Authentication / token tiers](https://developers.cloudflare.com/r2/api/tokens/) · [Bucket locks](https://developers.cloudflare.com/r2/buckets/bucket-locks/) · [Wrangler R2 commands](https://developers.cloudflare.com/r2/reference/wrangler-commands/)

Docker & ufw: [Docker — packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/) · [ufw-docker](https://github.com/chaifeng/ufw-docker) · [Compose secrets](https://docs.docker.com/compose/how-tos/use-secrets/)

Tailscale: [Lock down Ubuntu with ufw](https://tailscale.com/docs/how-to/secure-ubuntu-server-with-ufw)

Postgres: [PG 18 release](https://www.postgresql.org/about/news/postgresql-18-released-3142/) · [Versioning policy](https://www.postgresql.org/support/versioning/)

pgBackRest: [The Register](https://www.theregister.com/databases/2026/05/20/postgresql-backup-tool-gets-some-backup-of-its-own-after-sole-maintainer-sounds-alarm/5242822) · [Percona — Backrest's back](https://percona.community/blog/2026/05/19/backrests-back-alright/) · [pgBackRest news](https://pgbackrest.org/news.html)

Skills: [Claude Code — Skills](https://code.claude.com/docs/en/skills)
