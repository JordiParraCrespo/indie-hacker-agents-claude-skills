# The first deploy

The first deploy is different in one specific way: **there is no previous
version to roll back to.** The automatic rollback in `deploy.sh` has nowhere to
go, so the safety net you rely on later isn't there yet.

Do it on staging, deliberately, and don't be doing it for the first time on
prod.

## Prerequisites

Confirm before starting, because each of these produces a confusing failure
later rather than an obvious one now:

- `vps-provision` has run and `verify.sh <target>` passes. In particular the
  external scan must come back clean.
- `db-backup-verify` Phase 2a is in place, and the drill has passed once.
- `deploy.manifest.json` exists and is filled in.
- The compose file passes `check-invariants.sh`.

## Bootstrap order

### 1 · Ship the database first, alone

```bash
docker compose up -d db
docker compose exec db pg_isready
```

Then create the three roles (`db-backup-verify/references/postgres-roles.md`)
and verify the separation actually holds with the probe queries in that file.
Grants are easy to get subtly wrong and the failure is silent — everything
works, it's just more permissive than intended.

### 2 · Run migrations against an empty database

The first migration run is the one most likely to reveal that `migrate.up` in
the manifest is wrong. Discovering that here, with no data at risk, is the point
of doing it separately.

```bash
docker compose run --rm api <migrate.up>
```

Then immediately prove the down path works, while it costs nothing:

```bash
docker compose run --rm api <migrate.down>
docker compose run --rm api <migrate.up>
```

A down path that's never been executed is a hypothesis. This is the cheapest
moment you will ever have to test it.

### 3 · Start the API without the tunnel

```bash
docker compose up -d api
docker compose exec api curl -s -o /dev/null -w '%{http_code}' http://localhost:<port>/healthz
```

Health check passing from inside the network, before Cloudflare is involved at
all. If it fails here, the problem is the app. If it passes here and fails
through the tunnel, the problem is routing — and knowing which is most of the
debugging.

### 4 · Add the tunnel

```bash
docker compose up -d cloudflared
docker compose logs -f cloudflared
```

The three failure modes, in the order you'll hit them:

- **No catch-all ingress rule.** `cloudflared` evaluates rules top to bottom and
  requires a terminating `- service: http_status:404`. Without it, unmatched
  requests fail with nothing useful in either log.
- **Service-name DNS not resolving.** `cloudflared` and the API must share a
  *user-defined* network; on the default bridge, name resolution silently fails
  and it looks like the API is down.
- **Egress blocked.** If you applied a chain-wide `DROP` in `DOCKER-USER`
  instead of the scoped rules, `cloudflared` cannot reach Cloudflare at all.
  Pinning ≥ 2026.5.2 gets you a startup pre-check that says so explicitly.

### 5 · Seed the backup assertions

Now that a real schema exists, replace the toy checks in
`db-backup-verify/assets/assertions.sql` with real tables and row counts — this
is Phase 2b. Run the drill once against real data before calling the deploy
done.

## Recording the first rollback point

After the first successful deploy, `deploy.sh` records the running image so
subsequent deploys have somewhere to roll back to. Until then:

```bash
git tag first-deploy-$(date +%Y%m%d)
```

Tag the commit. If something goes wrong before the second deploy, recovery means
checking out that tag and deploying it — slower than an image rollback, but it
exists, which is the important part.

## Promoting to prod

```bash
scripts/deploy.sh prod
```

The promotion gate requires a green staging deploy **of this exact commit**. If
it refuses, that's the gate working — deploy to staging first rather than
reaching for `ALLOW_UNSTAGED=1`, which exists for genuine emergencies and should
feel uncomfortable to type.

Prod's first deploy has the same no-rollback-target property as staging's. The
difference is that staging has now proved the sequence end to end on identical
software, which is the entire reason the second server earns its cost.
