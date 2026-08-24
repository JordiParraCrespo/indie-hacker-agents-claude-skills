# Three Postgres roles

One role for everything is the default and it means a SQL injection in the API,
a compromised backup job, and a curious monitoring agent all have identical
reach. Splitting them costs about fifteen minutes.

## App role

Owns its own schema. Not a superuser, no access to other schemas, no ability to
create databases or roles.

```sql
CREATE ROLE app_user LOGIN PASSWORD :'app_password';
CREATE SCHEMA app AUTHORIZATION app_user;

REVOKE ALL ON SCHEMA public FROM PUBLIC;
ALTER ROLE app_user SET search_path = app;

GRANT CONNECT ON DATABASE :dbname TO app_user;
```

The `REVOKE ... FROM PUBLIC` line matters more than it looks. Postgres 15+
tightened the default, but on an upgraded cluster `public` may still be writable
by every role, which quietly undoes the separation below.

## Backup role

Reads everything, changes nothing. `pg_read_all_data` (Postgres 14+) is exactly
this and saves maintaining per-table grants that drift as the schema evolves.

```sql
CREATE ROLE backup_user LOGIN PASSWORD :'backup_password';
GRANT pg_read_all_data TO backup_user;
GRANT CONNECT ON DATABASE :dbname TO backup_user;
```

`pg_dump` needs read on everything it dumps; it does not need to write, create,
or drop. If the dump sidecar is compromised, the attacker gets a reader — and,
because that container has no internet, a reader with nowhere to send anything.

## Agent role

Statistics only. **Cannot read row data.**

```sql
CREATE ROLE agent_user LOGIN PASSWORD :'agent_password';
GRANT pg_monitor TO agent_user;          -- includes pg_read_all_stats
GRANT CONNECT ON DATABASE :dbname TO agent_user;
```

`pg_monitor` gives connection counts, table and index sizes, slow-query
statistics, replication lag, cache hit ratios — everything a health report
needs. It does not grant `SELECT` on user tables.

This is the highest-value of the three. `server-health-report` reads application
logs, and logs contain attacker-controlled strings: a request path, a user
agent, an error message quoting user input. Combine that with database read
access and outbound capability and you have assembled the lethal trifecta —
private data, untrusted content, and a way out — on the machine holding
production data.

Keeping customer rows outside the agent's reach means the worst case for a
successful prompt injection is "leaked some table sizes" rather than "leaked the
users table". That's a large reduction for one `GRANT`.

## Verify the separation actually holds

Grants are easy to get subtly wrong, and the failure is silent — everything
works, it's just more permissive than you think. Check by trying:

```bash
# should FAIL
psql -U agent_user -d "$DB" -c 'SELECT * FROM app.users LIMIT 1'

# should SUCCEED
psql -U agent_user -d "$DB" -c 'SELECT count(*) FROM pg_stat_activity'

# should FAIL
psql -U backup_user -d "$DB" -c 'CREATE TABLE probe(i int)'

# should SUCCEED
psql -U backup_user -d "$DB" -c 'SELECT count(*) FROM app.users'
```

Run these once at setup and after any schema migration that adds a new schema —
a new schema created by the app role is not automatically covered by the
assumptions above, and `pg_read_all_data` picks it up while your hand-written
grants would not.

## Passwords

Delivered as Docker secrets, mounted at `/run/secrets/*`, referenced through the
`*_FILE` convention the official image supports:

```yaml
environment:
  POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
```

Not `POSTGRES_PASSWORD`. Environment variables are visible in `docker inspect`,
readable from `/proc/<pid>/environ`, and leak into logs and crash dumps.

Be clear-eyed about what Compose secrets are outside Swarm, though: a bind mount
of a host file to `/run/secrets/<name>`. Plaintext on disk, no encrypted store.
They deliver the real win above and nothing more, so the host file still needs
to be root-owned `chmod 600`, outside the git worktree, and covered by a secret
scan in CI. "Ignored by git" is not the same as "absent from the repo".
