-- ============================================================
-- create_test_data.sql
-- Creates a reproducible test environment for index health analysis.
--
-- All DDL and DML run inside an explicit transaction so that partial
-- failures do not leave the database in an inconsistent state.
-- autovacuum is disabled on the test table so that dead tuples
-- created by DELETE / UPDATE remain visible to pg_stat_user_tables.
-- ============================================================

BEGIN;

-- Create schema if it does not already exist.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'bad_index_test') THEN
        EXECUTE 'CREATE SCHEMA bad_index_test';
    END IF;
END $$;

-- Restrict the search path only for this transaction to avoid
-- accidentally affecting other sessions sharing the connection
-- (e.g. when running through PgBouncer in transaction mode).
SET LOCAL search_path TO bad_index_test;

-- Create test table
CREATE TABLE test_orders (
    id           SERIAL PRIMARY KEY,
    user_id      INT          NOT NULL,
    order_date   TIMESTAMP    DEFAULT now(),
    amount       DECIMAL(10, 2) NOT NULL,
    status       TEXT         CHECK (status IN ('pending', 'shipped', 'delivered', 'cancelled')),
    random_value TEXT
);

-- Disable autovacuum on this table so that dead tuples created below
-- remain in pg_stat_user_tables for the duration of the demo.
-- Remember to re-enable (or DROP the table) after testing.
ALTER TABLE test_orders SET (autovacuum_enabled = false);

-- Insert 200 000 rows to produce a realistic data volume.
INSERT INTO test_orders (user_id, order_date, amount, status, random_value)
SELECT
    (random() * 1000)::INT,
    now() - (random() * interval '365 days'),
    (random() * 1000)::DECIMAL(10, 2),
    CASE
        WHEN random() < 0.1 THEN 'cancelled'
        WHEN random() < 0.4 THEN 'shipped'
        WHEN random() < 0.7 THEN 'delivered'
        ELSE 'pending'
    END,
    md5(random()::TEXT)   -- random_value simulates a column that gets a useless index
FROM generate_series(1, 200000);

-- Create indexes (mix of useful and problematic).
CREATE INDEX idx_order_date ON test_orders (order_date);
CREATE INDEX idx_user_id    ON test_orders (user_id);
CREATE INDEX idx_random     ON test_orders (random_value);  -- potentially useless
CREATE INDEX idx_status     ON test_orders (status);        -- low-cardinality, often not helpful
CREATE INDEX idx_amount     ON test_orders (amount);        -- over-indexing example

-- Delete ~20 % of rows to introduce dead tuples.
DELETE FROM test_orders WHERE id % 5 = 0;

-- Update another ~14 % of rows; each UPDATE leaves a dead version of the row.
UPDATE test_orders SET amount = amount * 1.1 WHERE id % 7 = 0;

-- Refresh the planner statistics without running VACUUM so that dead tuples
-- remain countable in pg_stat_user_tables.
ANALYZE test_orders;

-- ---- sample queries to populate pg_stat_user_indexes ----

-- Uses idx_order_date
SELECT * FROM test_orders WHERE order_date > now() - interval '30 days';

-- Uses idx_user_id
SELECT * FROM test_orders WHERE user_id = 500;

-- idx_random: LIKE 'a%' can use a B-tree index only with C locale or text_pattern_ops.
-- In most installations this will fall back to a seq-scan, which is the intended demo.
SELECT * FROM test_orders WHERE random_value LIKE 'a%';
SELECT * FROM test_orders WHERE random_value LIKE 'b%';

-- idx_status: low-cardinality column – planner often prefers seq-scan.
SELECT * FROM test_orders WHERE status = 'shipped';
SELECT * FROM test_orders WHERE status = 'pending';

-- idx_amount: over-indexing demo
SELECT * FROM test_orders WHERE amount > 500;
SELECT * FROM test_orders WHERE amount < 100;
SELECT * FROM test_orders WHERE amount BETWEEN 200 AND 300;

-- Additional idx_user_id and idx_order_date hits
SELECT * FROM test_orders WHERE user_id = 750;
SELECT * FROM test_orders WHERE order_date BETWEEN now() - interval '60 days' AND now() - interval '30 days';

COMMIT;
