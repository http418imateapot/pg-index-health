-- ============================================================
-- redundant_index_check.sql
-- Detects redundant (overlapping) indexes in PostgreSQL.
--
-- An index B is considered redundant when another index A covers
-- the same leading columns as B (A's columns are a superset of B's
-- in the same order from the left).  In such a case B never provides
-- a query plan that A cannot also provide, so B wastes write overhead
-- and storage.
--
-- Outputs one row per redundant index with the index that supersedes it.
--
-- Production safety notes:
--   • Read-only query; no side effects.
--   • Review the output carefully before dropping any index.
--     Some "redundant" indexes may be intentional (e.g. a partial index,
--     an index with a different collation, or a UNIQUE constraint that
--     cannot be dropped without also dropping the constraint).
--   • Indexes marked as PRIMARY KEY or UNIQUE are flagged but should only
--     be dropped after verifying no constraint depends on them.
-- ============================================================

WITH

-- Expand each index into its ordered column list using pg_index and pg_attribute.
index_columns AS (
    SELECT
        n.nspname                                   AS schema_name,
        t.relname                                   AS table_name,
        ix.indexrelid                               AS index_oid,
        ic.relname                                  AS index_name,
        ix.indisunique                              AS is_unique,
        ix.indisprimary                             AS is_primary,
        ix.indpred IS NOT NULL                      AS is_partial,
        -- Ordered array of column names that form the index key.
        array_agg(a.attname ORDER BY col_order.ordinality) AS columns
    FROM pg_index ix
    JOIN pg_class  t  ON t.oid  = ix.indrelid
    JOIN pg_class  ic ON ic.oid = ix.indexrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    -- unnest the indkey array with positional ordering
    JOIN LATERAL unnest(ix.indkey) WITH ORDINALITY AS col_order(attnum, ordinality)
        ON true
    JOIN pg_attribute a
        ON a.attrelid = ix.indrelid
       AND a.attnum   = col_order.attnum
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      AND col_order.attnum > 0   -- skip expression index placeholders (attnum 0)
    GROUP BY n.nspname, t.relname, ix.indexrelid, ic.relname,
             ix.indisunique, ix.indisprimary, ix.indpred
),

-- Find pairs where index B's column list is a prefix of index A's column list.
-- That makes B potentially redundant (A covers everything B covers).
redundant_pairs AS (
    SELECT
        a.schema_name,
        a.table_name,
        -- The "covering" index (superset).
        a.index_name                AS covering_index,
        a.columns                   AS covering_columns,
        a.is_unique                 AS covering_is_unique,
        a.is_primary                AS covering_is_primary,
        a.is_partial                AS covering_is_partial,
        -- The "redundant" index (subset / prefix).
        b.index_name                AS redundant_index,
        b.columns                   AS redundant_columns,
        b.is_unique                 AS redundant_is_unique,
        b.is_primary                AS redundant_is_primary,
        b.is_partial                AS redundant_is_partial,
        -- Usage stats for the redundant index.
        COALESCE(ui.idx_scan, 0)    AS redundant_idx_scan,
        pg_size_pretty(pg_relation_size(b.index_oid)) AS redundant_index_size
    FROM index_columns a
    JOIN index_columns b
        ON  a.schema_name = b.schema_name
        AND a.table_name  = b.table_name
        AND a.index_oid  <> b.index_oid
        -- B's columns must be a strict prefix of A's columns.
        AND b.columns     = a.columns[1:array_length(b.columns, 1)]
        AND array_length(a.columns, 1) > array_length(b.columns, 1)
    LEFT JOIN pg_stat_user_indexes ui
        ON ui.indexrelid = b.index_oid
    -- Exclude the case where both are identical (caught by the strict-prefix check above)
)

SELECT
    schema_name,
    table_name,
    redundant_index,
    redundant_columns,
    redundant_index_size,
    redundant_idx_scan          AS usage_since_stats_reset,
    covering_index,
    covering_columns,
    CASE
        WHEN redundant_is_primary THEN 'SKIP – is PRIMARY KEY; remove the constraint instead'
        WHEN redundant_is_unique  THEN 'CAUTION – is UNIQUE; dropping removes the uniqueness constraint'
        WHEN redundant_is_partial THEN 'REVIEW – is a partial index; covering index may not be equivalent'
        WHEN redundant_idx_scan > 0
            THEN 'REVIEW – index has been used ' || redundant_idx_scan || ' times; verify covering index satisfies all queries'
        ELSE 'SAFE TO DROP – no usage detected and not a constraint'
    END AS recommendation
FROM redundant_pairs
ORDER BY
    schema_name,
    table_name,
    -- Flag the highest-priority items first
    (redundant_is_primary OR redundant_is_unique) ASC,
    redundant_idx_scan ASC,
    redundant_index;
