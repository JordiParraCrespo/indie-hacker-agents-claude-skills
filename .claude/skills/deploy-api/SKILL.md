---
name: deploy-api
description: Build, migrate, health-check, promote, and roll back a containerised API on a zero-inbound VPS — stack-agnostic, driven by a declared deploy manifest rather than by guessing the framework. Use this whenever the user wants to deploy, ship, release, promote, or roll back their API or service, run database migrations against a server, or set up a deploy pipeline, and whenever they ask why a deploy failed or how to undo one. Also use it when reviewing a compose file for the no-published-ports and digest-pinning invariants that the firewall guarantees depend on.
disable-model-invocation: true
---

# deploy-api

Deploy to staging, verify, promote the same commit to production, and roll back
automatically if the health check doesn't pass.

Stack-agnostic: the pipeline reads `deploy.manifest.json` instead of inferring
your framework, so the same code path ships a Go binary and a Django app.

## Stop and ask the user first

- Publishing a container port to the host, even temporarily for debugging.
- Deploying to prod a commit that staging hasn't verified.
- Running a migration marked irreversible without a fresh, verified backup.
- Removing the down path from a migration to "just get it shipped".

## The contract

Copy `assets/deploy.manifest.json` to the repo root and fill it in.

| Field | Why the skill can't work it out itself |
|---|---|
| `service` | Which compose service is the API |
| `listen_port` | Container-internal; nothing is published to the host |
| `health.path` | Every framework spells it differently |
| `readiness` | "Started" and "serving" are different moments |
| `migrate.up` / `migrate.down` | **The one thing an agent genuinely cannot infer** |
| `rollback.strategy` | What "the previous version" means here |

### The down path is the deliverable

A migration's reverse is not a formality — it's the thing you need most at the
moment you're least able to work it out. So the manifest demands one of two
answers, and `deploy.sh` refuses to proceed without either:

- a `migrate.down` command, or
- `irreversible: true` **with a stated reason**

When a migration is irreversible, the restore drill *is* the rollback path, and
the pipeline verifies backup freshness before letting it run.

Prefer **expand-contract** for anything destructive: add the new column,
backfill, switch reads, deploy, and drop the old column only in a later release
once the previous version is no longer running. Each step is individually
reversible, which is what makes the sequence safe.

### Health checks must not require a writable database

A health check that writes turns a full disk into a failed deploy and an
automatic rollback — the opposite of useful during an incident. Check that the
process is up and can read.

## Pipeline

```bash
scripts/deploy.sh staging      # build, migrate, health-check, record green
scripts/deploy.sh prod         # promote the same commit
scripts/rollback.sh prod       # put the previous image back
```

Order of operations, and why each step is where it is:

1. **Invariants** (`check-invariants.sh`) — local and cheap. A violation means
   the firewall guarantees don't hold, so there's no point building.
2. **Promotion gate** — prod requires a recorded green staging deploy *of this
   exact commit*. Otherwise the second server is just an expense.
3. **Migration reversibility** — settled *before* anything runs. Once a
   destructive migration has executed, the conversation about undoing it is over.
4. **Build**, then **record the currently running image** — rollback needs
   somewhere to go back to, and nothing else captures it.
5. **Migrate**, with the declared down path attempted automatically on failure.
6. **Deploy**, then **health-check from inside the network** — polling through
   the tunnel conflates "the app is broken" with "Cloudflare is having a moment".
7. **Roll back automatically** if health doesn't pass.

## The compose invariants

```bash
scripts/check-invariants.sh infra/compose.yml
```

Six properties, checked against `docker compose config` — the *resolved* file,
after overrides, since that's where drift actually enters:

| Invariant | Why it's mechanical rather than remembered |
|---|---|
| No service publishes ports | ufw filters INPUT; Docker publishes via NAT/FORWARD. A published port is internet-reachable no matter what `ufw status` says. |
| Images pinned by digest | `unattended-upgrades` patches the host, never containers. A moving tag ships an unreviewed binary at a time you didn't choose. |
| `data` network is `internal: true` | Denies the database a route out — the exfiltration path this design closes. |
| No secrets in `environment` | Env vars appear in `docker inspect`, `/proc/<pid>/environ`, logs, and crash dumps. Use `*_FILE`. |
| Postgres only on `data` | Attaching it elsewhere defeats `internal: true` without changing it. |
| cloudflared on a user-defined network | Service-name DNS doesn't resolve on the default bridge, and the failure looks like the app being down. |

The first one is the load-bearing one. "The stack publishes nothing" is what
makes ufw's deny-all meaningful, and it's exactly the sort of thing that gets
broken at 2am for a debugging session and never reverted.

## Trusted proxy handling — even without nginx

nginx is dropped for launch, but this still applies, because it's about the
application, not the proxy.

Traffic arrives via `cloudflared`, so **every request reaches your app from a
local address.** Any logic of the form "requests from localhost are trusted" is
therefore silently disabled — or rather, silently granted to the entire
internet.

This is not hypothetical. It's the single mechanism behind tens of thousands of
exposed AI-agent instances found by internet-wide scans in early 2026: an app
that auto-approved localhost connections, placed behind a reverse proxy that
forwarded from 127.0.0.1, handed unauthenticated admin access to anyone who
found it.

Two rules:

- Derive the client IP from Cloudflare's forwarded headers (`CF-Connecting-IP`,
  or `X-Forwarded-For` with the proxy configured as trusted), never from the
  peer address.
- Never grant authorisation based on the peer address at all. Authenticate.

If you reintroduce nginx later, add: hardcode `proxy_pass` upstreams so user
input can never reach them, `server_tokens off`, a `client_max_body_size` cap,
and a version floor covering **both** CVE-2026-42945 and CVE-2026-9256 — the
versions that fix the first are still vulnerable to the second.

## Secrets

Docker secrets, mounted at `/run/secrets/`, referenced through `*_FILE`.

Be accurate about what that buys, though: outside Swarm, a Compose `secrets:`
entry is a **bind mount of a host file**. Plaintext on disk, no encrypted store.
It delivers exactly the intended win — the value stays out of `docker inspect`,
`/proc/<pid>/environ`, and logs — and nothing beyond it. So the host file still
needs to be root-owned `chmod 600`, live outside the git worktree, and be
covered by a secret scan in CI. Git-ignored is not the same as absent.

## Reference files

- `references/migrations.md` — expand-contract, writing reversible migrations, what rollback can't undo
- `references/first-deploy.md` — bootstrapping when there's no previous version to roll back to
