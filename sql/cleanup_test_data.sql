-- ============================================================
-- cleanup_test_data.sql
-- Removes all objects created by create_test_data.sql.
-- Dropping the schema CASCADE removes all tables and indexes inside it.
-- ============================================================

BEGIN;

SET LOCAL search_path TO bad_index_test;

-- Drop indexes individually first (harmless if schema CASCADE already handles it,
-- but explicit drops make the intent clear during partial cleanups).
DROP INDEX IF EXISTS idx_order_date;
DROP INDEX IF EXISTS idx_user_id;
DROP INDEX IF EXISTS idx_random;
DROP INDEX IF EXISTS idx_useless;
DROP INDEX IF EXISTS idx_status;
DROP INDEX IF EXISTS idx_amount;

-- Drop table
DROP TABLE IF EXISTS test_orders;

COMMIT;

-- Drop schema (outside transaction so CASCADE is not accidentally rolled back)
DROP SCHEMA IF EXISTS bad_index_test CASCADE;
