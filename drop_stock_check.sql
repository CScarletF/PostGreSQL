DO $$
DECLARE
    cname text;
BEGIN
    SELECT conname INTO cname
    FROM pg_constraint
    WHERE conrelid = 'product'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%stock_quantity%';

    IF cname IS NOT NULL THEN
        EXECUTE format('ALTER TABLE product DROP CONSTRAINT %I', cname);
        RAISE NOTICE 'Dropped constraint %', cname;
    ELSE
        RAISE NOTICE 'No stock_quantity CHECK constraint found -- already dropped?';
    END IF;
END $$;
