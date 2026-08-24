-- assertions.sql — what "the restore worked" means for THIS database.
--
-- Run by restore-drill.sh inside the throwaway container, against the restored
-- copy. Every row must return three columns in this order:
--
--     check_name (text) | passed (boolean) | detail (text)
--
-- The drill fails if any row has passed = false.
--
-- WHY THIS FILE EXISTS
--
-- `pg_restore` exiting 0 means the file parsed, not that your data is there.
-- Restoring an empty dump into an empty database succeeds perfectly. These
-- assertions are what turn "the command ran" into "the business data survived",
-- and they are the part only you can write — nothing can infer which tables
-- matter or what a plausible row count looks like.
--
-- TWO KINDS OF CHECK, BOTH WORTH HAVING
--
--   Volume  — did the rows come back at all?
--   Recency — is this dump from the recent past, or a stale object that has
--             been quietly re-uploaded for weeks while the real data moved on?
--
-- A backup that restores perfectly to last month's state passes every volume
-- check and is still a disaster. The recency check is what catches a dump job
-- that has been silently pointing at the wrong database.
--
-- ---------------------------------------------------------------------------
-- REPLACE EVERYTHING BELOW with checks for your schema. Phase 2a ships with
-- the toy-schema versions; Phase 2b re-points them at real tables.
-- ---------------------------------------------------------------------------

-- 1. The schema exists at all. Cheap, and it fails loudly when the dump came
--    from the wrong database rather than from an empty one.
SELECT
  'public schema has tables',
  count(*) > 0,
  count(*) || ' tables'
FROM information_schema.tables
WHERE table_schema = 'public';

-- 2. Volume. Set the floor to something safely below production but far above
--    zero — the point is catching an empty or truncated restore, not tracking
--    growth. Revisit if it ever gets close.
--
-- SELECT
--   'users table populated',
--   count(*) >= 1,
--   count(*) || ' rows'
-- FROM users;

-- 3. Recency. Adjust the interval to your dump schedule plus a margin; with
--    daily dumps, 48 hours catches "the job stopped running" without alarming
--    over a single missed night.
--
-- SELECT
--   'newest row is recent',
--   max(created_at) > now() - interval '48 hours',
--   'newest: ' || coalesce(max(created_at)::text, 'none')
-- FROM users;

-- 4. Referential sanity. A dump restored with --no-owner can still be complete;
--    orphaned rows usually mean a partial restore or a dump taken mid-migration.
--
-- SELECT
--   'no orphaned order rows',
--   count(*) = 0,
--   count(*) || ' orphans'
-- FROM orders o
-- LEFT JOIN users u ON u.id = o.user_id
-- WHERE u.id IS NULL;
