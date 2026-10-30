-- add_void_columns.sql -- one-off migration against the LIVE webapp_demo
-- database. Adds nullable voided_at / voided_by (FK to app_user) to sale,
-- for keep-and-tag voiding. Existing rows keep NULL = not voided. That is
-- correct: until now void deleted the sale, so no voided sale exists.
--
-- Must run as the Postgres superuser (the app role cannot ALTER). Normally
-- run through scripts/migrate_void_columns.sh, which asks for confirmation
-- first. Idempotent: safe to re-run; columns that already exist are skipped.
-- A missing sale or app_user table aborts.
--
-- Not applied by the webapp_postgres role: that role only creates tables
-- that do not exist yet and never alters existing ones. Table-level
-- privileges already granted to webapp_app cover the new columns.
--
-- Rollback (discards all void state recorded since; voided sales would
-- then read as active, but their stock was already restored):
--   ALTER TABLE sale DROP COLUMN voided_at, DROP COLUMN voided_by;

DO $$
BEGIN
    IF to_regclass('app_user') IS NULL THEN
        RAISE EXCEPTION 'app_user table not found. Create it first (sudo scripts/setup.sh).';
    END IF;
    IF to_regclass('sale') IS NULL THEN
        RAISE EXCEPTION 'sale table not found. Create it first (sudo scripts/setup.sh).';
    END IF;

    ALTER TABLE sale ADD COLUMN IF NOT EXISTS voided_at timestamptz;
    ALTER TABLE sale ADD COLUMN IF NOT EXISTS voided_by integer REFERENCES app_user(id);
    RAISE NOTICE 'Void columns ensured on sale';
END $$;

-- Verification: sale should list both columns.
SELECT table_name,
       string_agg(column_name, ', ' ORDER BY column_name) AS void_columns
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'sale'
  AND column_name IN ('voided_at', 'voided_by')
GROUP BY table_name;
