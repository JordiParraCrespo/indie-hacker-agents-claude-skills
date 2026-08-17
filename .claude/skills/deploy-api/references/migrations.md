# Migrations

## What a rollback can and cannot undo

`rollback.sh` restores the previous **image**. The database keeps whatever schema
the migration left it in. Conflating the two is how people lose data during an
incident, so it's worth being precise:

| Migration | After rolling back the code |
|---|---|
| Additive — new column, table, index | Old code ignores it. Nothing to do. |
| Destructive — dropped/renamed column, changed type | Old code is running against a schema it doesn't understand. The down path *may* work, but read it first. |
| Irreversible | Restore from backup. |

The middle row is where the real danger lives. If the new code wrote rows before
you rolled back, running the down migration can discard them — the down path was
written assuming nothing had used the new schema yet. Read it before running it.

## Expand-contract

The technique that makes the middle row disappear. Instead of one destructive
migration, split into steps that are each individually reversible:

**Renaming `users.name` to `users.full_name`:**

1. **Expand** — add `full_name`, nullable. Old code unaffected.
2. **Backfill** — copy `name` into `full_name`. Still reversible; you're only
   adding data.
3. **Dual-write** — deploy code writing both columns, reading `name`.
4. **Switch reads** — deploy code reading `full_name`. Roll back freely; both
   columns are populated and current.
5. **Contract** — drop `name`, in a later release, once no running version
   references it.

Five deploys instead of one. What you buy is that at no point is there a version
of the code that can't run against the current schema — so rollback stays a
non-event throughout. The only irreversible step is the last, and by then the
column has been unused for a release cycle.

For a solo operator shipping several times a day this feels like ceremony. It
earns its keep the first time you need to roll back at 11pm.

## Writing a usable down path

The down migration is the deliverable, not paperwork. Some things that make one
actually work when needed:

- **Test it in the same run.** Apply up, apply down, apply up again. A down path
  that's never been executed is a hypothesis.
- **Down should be safe to run twice.** `DROP COLUMN IF EXISTS`, not `DROP
  COLUMN`. During an incident you will lose track of what you've already run.
- **Don't drop data in a down path if you can avoid it.** Renaming a column back
  is recoverable; dropping the new one loses whatever was written to it.
- **Say what it can't restore.** If down drops a column the new code populated,
  put that in a comment. The person reading it under pressure may be you at 3am,
  or nobody in particular in eight months.

## When irreversible is the honest answer

Some migrations genuinely can't be reversed:

- Dropping a column and its data
- A destructive backfill that overwrites the original values
- Type changes that lose precision — `timestamptz` to `date`

Mark these honestly rather than inventing a down path that silently doesn't
restore the data:

```json
"migrate": {
  "up": "npm run migrate:up",
  "down": null,
  "irreversible": true,
  "irreversible_reason": "drops users.legacy_address after backfill; the original values are not recoverable"
}
```

`deploy.sh` then verifies backup freshness before running it, because the
restore *is* the rollback path at that point. A fabricated down path is worse
than an honest `irreversible: true` — it produces a rollback that appears to
succeed while quietly leaving the data gone.

## Long-running migrations

An `ALTER TABLE` that rewrites a large table takes a lock, and everything queues
behind it. On a single-VPS setup with no read replica, that's a full outage for
the duration.

- Use `CREATE INDEX CONCURRENTLY` — it doesn't block writes. Note it can't run
  inside a transaction, so most migration tools need an escape hatch for it.
- Add columns as nullable with no default. In modern Postgres, adding a column
  with a constant default is fast, but a *volatile* default still rewrites the
  table.
- Backfill in batches with a `WHERE` clause and a sleep, not one statement.
- Set `lock_timeout` so a blocked migration fails fast instead of stacking up
  every subsequent query behind it. A migration that fails in 5 seconds is an
  inconvenience; one that holds a lock for 5 minutes is an outage.

```sql
SET lock_timeout = '5s';
SET statement_timeout = '5min';
```

## Before a risky migration

Take a dump and verify it — don't rely on last night's:

```bash
.claude/skills/db-backup-verify/scripts/dump.sh
.claude/skills/db-backup-verify/scripts/upload.sh daily
AGE_IDENTITY=... .claude/skills/db-backup-verify/scripts/restore-drill.sh run
```

Ten minutes, and it converts "we have backups" from a belief into an
observation. This is the ordering reason backups are built before the deploy
pipeline: you cannot safely iterate on deploys until a bad migration is
survivable.
