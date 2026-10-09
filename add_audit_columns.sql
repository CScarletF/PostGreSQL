-- add_audit_columns.sql -- one-off migration against the LIVE webapp_demo
-- database. Adds nullable created_by / updated_by (FK to app_user) to the
-- six original tables. Existing rows keep NULL: they predate
-- authentication and have no author.
--
-- Must run as the Postgres superuser (the app role cannot ALTER). Normally
-- run through scripts/migrate_audit_columns.sh, which asks for confirmation
-- first. Idempotent: safe to re-run; columns that already exist are skipped.
-- A missing table is skipped with a NOTICE, a missing app_user aborts.
--
-- Not applied by the webapp_postgres role: that role only creates tables
-- that do not exist yet and never alters existing ones.
--
-- Rollback (only if no data should keep attribution):
--   ALTER TABLE <table> DROP COLUMN created_by, DROP COLUMN updated_by;
--   for each of: equipment, assignment, product, sale, sale_item, recipe

DO $$
DECLARE
    t text;
BEGIN
    IF to_regclass('app_user') IS NULL THEN
        RAISE EXCEPTION 'app_user table not found. Create it first (sudo scripts/setup.sh).';
    END IF;

    FOREACH t IN ARRAY ARRAY['equipment', 'assignment', 'product', 'sale', 'sale_item', 'recipe']
    LOOP
        IF to_regclass(t) IS NULL THEN
            RAISE NOTICE 'Skipping %: table not found', t;
            CONTINUE;
        END IF;
        EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS created_by integer REFERENCES app_user(id)', t);
        EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS updated_by integer REFERENCES app_user(id)', t);
        RAISE NOTICE 'Audit columns ensured on %', t;
    END LOOP;
END $$;

-- Verification: every migrated table should list both columns.
SELECT table_name,
       string_agg(column_name, ', ' ORDER BY column_name) AS audit_columns
FROM information_schema.columns
WHERE table_schema = 'public'
  AND column_name IN ('created_by', 'updated_by')
GROUP BY table_name
ORDER BY table_name;
