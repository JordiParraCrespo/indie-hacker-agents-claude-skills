---
name: db-backup-verify
description: Set up and verify encrypted, immutable Postgres backups — pg_dump to Cloudflare R2 with a bucket lock, a weekly Backblaze B2 copy on a second vendor, and a monthly restore drill that proves the dumps actually restore and the escrowed key still opens them. Use this whenever the user mentions backups, pg_dump, restore, disaster recovery, R2, B2, rclone, bucket locks, object lock, backup retention, or asks whether their data is safe or recoverable. Also use it before any risky migration or deploy, since a bad migration is only survivable if a verified restore path already exists, and whenever a backup alert fires or a drill fails.
---

# db-backup-verify

Daily encrypted dumps to R2 under a 30-day bucket lock, a weekly copy to B2 on a
different vendor, and a monthly drill that restores one and checks the data is
really in it.

**A backup is a hypothesis until a restore confirms it.** Everything here exists
to make that confirmation routine rather than heroic.

## Stop and ask the user first

- Skipping or disabling the restore drill.
- Putting an **Admin-tier** R2 token on the server — it can remove the bucket
  lock, which makes the immutability guarantee decorative.
- Storing the age private key on the app server. It belongs offline.
- Reducing retention below 30 days, or dropping the second vendor.

## Architecture

Two containers, and the split is the point:

| | Database access | Internet | Sees |
|---|---|---|---|
| **dump sidecar** | yes (`data`, `internal: true`) | no | plaintext |
| **uploader** | no | yes | ciphertext only |

### Why encryption is load-bearing, not hygiene

Splitting the containers *looks* like it separates capabilities. On its own it
doesn't: the uploader has to read the dump to upload it, and the dump is every
row in the database. Unencrypted, the uploader holds complete customer data plus
egress — precisely the combination the split was meant to prevent, and the same
shape the read-only ops agent exists to avoid.

Encrypting to a public key in the sidecar is what makes the separation real. The
uploader only ever handles ciphertext, and a compromised R2 *or* B2 account
yields blobs rather than your database.

The cost is honest and must be respected: **an unescrowed key turns every backup
into ciphertext nobody can open.** The private key lives offline — password
manager plus a second offline copy — never on the app server, and is supplied to
the drill at run time. The monthly drill is what proves it still works.

### Why publication is atomic

`dump.sh` writes to a staging directory, encrypts, checksums, then **renames**
into the outbox — checksum first, payload second.

Without this, a scheduled uploader can catch a dump mid-write and ship a
truncated object. Under a bucket lock that object is then **immutable for 30
days**, and it is the newest dump — the one the drill tests and the one you'd
reach for in a real incident. Renaming within a filesystem is atomic, so a
reader sees each file either absent or complete.

Moving the checksum first means the payload's presence implies its checksum has
landed, so the uploader keying off `*.age` can never see an unverifiable file.

## Setup

### 1 · Postgres roles — three, not one

| Role | Rights |
|---|---|
| app | non-superuser, owns only its own schema |
| backup | `pg_read_all_data`, nothing else |
| agent | `pg_monitor` / `pg_read_all_stats` — stats only, **cannot read rows** |

The agent role matters more than it looks: `server-health-report` reads logs
containing attacker-controlled strings, so keeping customer data outside its
reach shrinks the blast radius of a prompt injection to "read some statistics".

`references/postgres-roles.md` has the SQL.

### 2 · R2, with both halves of the guarantee

```bash
scripts/check-immutability.sh all
```

R2 has **no write-only token scope**. The tiers are Admin Read & Write, Admin
Read only, Object Read & Write, Object Read only, and only the Object tiers can
be bucket-scoped. So the credential that writes backups can also delete them.

The usual conclusion — "use bucket locks instead of credential scoping" — is
half right and dangerously incomplete. An **Admin** token can edit bucket
configuration, so it can *remove the lock* and then delete everything. The
guarantee holds only when both are true:

1. a bucket lock rule exists, **and**
2. the server's credential is **Object Read & Write, bucket-scoped**, so it can
   delete objects (blocked by the lock) but cannot touch bucket config.

Lock **and** scoping. The script probes the tier by attempting an Admin-only
operation and requiring it to fail.

Three more things that bite in the first hour:

- **Account API token, not User token.** User tokens go inactive when that user
  leaves the account, and backups then fail silently.
- **EU jurisdiction buckets need `https://<accountid>.eu.r2.cloudflarestorage.com`.**
  The default endpoint will not reach them. On a European host an EU bucket is
  likely, and this failure looks like a credentials problem.
- Wrangler's lock flags have moved between versions. Don't hardcode them — read
  `wrangler r2 bucket lock add --help`, then **assert the rule exists** with
  `lock list`. The assertion is the deliverable; flag spelling drifts.

Also worth knowing before you need it: **a bucket cannot be emptied while lock
rules exist.** Teardown must remove them first, deliberately.

### 3 · B2 as the second vendor

Weekly copy, Object Lock 90 days, **different vendor and different account**.

These defend against different things and neither substitutes for the other:
bucket locks protect against a compromised *server*; a second vendor protects
against a compromised *Cloudflare account* — which holds tunnel, WAF, DNS, and
the primary backups all at once. Pair it with hardware-key 2FA on that account.

### 4 · Schedule

| When | What |
|---|---|
| Daily | `dump.sh` then `upload.sh daily` |
| Weekly | `upload.sh weekly` → B2 |
| Monthly | `restore-drill.sh run` |
| Per run | `upload.sh check` — freshness against the **remote**, not the local outbox |

## The restore drill

```bash
AGE_IDENTITY=/path/to/key.txt scripts/restore-drill.sh run
```

Fetches the newest remote dump, verifies its checksum, decrypts it, reads the
**source major version from the dump header**, starts a matching throwaway
Postgres container, restores, and runs `assets/assertions.sql`.

Three things it checks that a naive drill doesn't:

- **Major version match.** Restoring into a *newer* major generally works, which
  is the danger — a drifted drill passes while exercising a code path production
  never takes. It asserts the container's major equals the dump's.
- **The key still opens the backups.** Nothing else in the pipeline would notice
  a rotated or corrupted escrowed key until the moment you need it.
- **The data is actually there.** `pg_restore` exiting 0 means the file parsed.
  Restoring an empty dump into an empty database succeeds perfectly.

### Prove the alarm works

```bash
scripts/restore-drill.sh negative
```

Corrupts a copy and requires the drill to reject it. **An alarm nobody has seen
fire is not an alarm** — run this once at setup and after any change to the
pipeline. A drill that cannot detect a bad backup makes every green run
meaningless.

### A failed drill is the one alert that pages

Everything else in this repo is a report. This one wakes someone up, because a
failing drill means you currently have no recoverable backup and won't find out
otherwise until you need one.

## Two-phase build

The drill needs a schema, and the schema arrives with the deploy pipeline's
migrations — so this ships in two passes:

- **2a, before `deploy-api`:** validate the *mechanism* against a seeded toy
  schema. Everything above works at this stage.
- **2b, after `deploy-api`:** re-point `assets/assertions.sql` at the real tables
  and row counts.

Built in one pass you'd construct a drill against an empty database and discover
it doesn't work the first time it matters.

## Reference files

- `references/postgres-roles.md` — the three roles, with SQL
- `references/storage-setup.md` — rclone config for R2 and B2, endpoints, lock configuration
- `references/key-management.md` — generating, escrowing, and rotating the age key
