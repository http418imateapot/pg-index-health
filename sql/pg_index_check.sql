-- ============================================================
-- pg_index_check.sql
-- PostgreSQL index health analysis query.
--
-- Configuration knobs (edit these values before running):
--   :min_seq_scan      – minimum seq_scan count to include a table (default 0 = all)
--   :max_index_usage   – maximum idx_scan count to flag as low-usage (default 999999 = all)
--   :schema_filter     – comma-separated schema names to restrict, or '%' for all user schemas
--
-- Production safety notes:
--   • This query is read-only; it only accesses system catalog views.
--   • seq_scan / idx_scan counters are cumulative since the last pg_stat_reset().
--     Always check `stats_reset_at` to understand the time window of the numbers.
--   • dead_tuple_size_estimate is an approximation (ratio × heap size).
--     For precise bloat measurement, enable the pgstattuple extension and use
--     pgstattuple(relid).dead_tuple_len instead.
--   • Grant only SELECT on pg_catalog and pg_stat_* views to the monitoring role.
-- ============================================================

WITH

-- ----- tuneable parameters (override with \set in psql or bind params in app) -----
params AS (
    SELECT
        0       AS min_seq_scan,       -- include tables with seq_scan >= this value
        999999  AS max_index_usage,    -- flag indexes with idx_scan <= this value
        '%'     AS schema_filter       -- LIKE pattern; '%' = all user schemas
),

-- ----- per-table statistics -----
table_stats AS (
    SELECT
        n.nspname                                   AS schema_name,
        c.relname                                   AS table_name,
        pg_size_pretty(pg_relation_size(c.oid))     AS table_size,
        pg_relation_size(c.oid)                     AS table_size_bytes,
        COALESCE(s.seq_scan, 0)                     AS seq_scan_count,
        COALESCE(s.n_live_tup, 0)                   AS n_live_tup,
        COALESCE(s.n_dead_tup, 0)                   AS n_dead_tup,
        -- Dead tuple ratio relative to total visible + dead rows.
        COALESCE(
            ROUND(
                (s.n_dead_tup::numeric / NULLIF(s.n_live_tup + s.n_dead_tup, 0)) * 100,
                2
            ),
            0
        ) AS dead_tuple_ratio,
        -- The time pg_stat counters were last reset for this database.
        -- All seq_scan / idx_scan numbers are cumulative *from this point in time*.
        pg_stat_get_db_stat_reset_time(c.relnamespace) AS stats_reset_at
    FROM pg_class c
    JOIN pg_namespace n ON c.relnamespace = n.oid
    -- Only user tables; excludes pg_catalog, information_schema, pg_toast, etc.
    JOIN pg_stat_user_tables s ON c.oid = s.relid
    CROSS JOIN params
    WHERE c.relkind = 'r'
      AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      AND n.nspname LIKE params.schema_filter
      AND COALESCE(s.seq_scan, 0) >= params.min_seq_scan
),

table_stats_final AS (
    SELECT *,
        -- Approximation: dead_tuple_ratio × heap size.
        -- NOTE: this overstates bloat when TOAST columns hold most of the data,
        -- and understates it when dead rows are concentrated in a few pages.
        -- Use pgstattuple(relid).dead_tuple_len for an exact measurement.
        COALESCE(ROUND((dead_tuple_ratio / 100.0) * table_size_bytes), 0)
            AS dead_tuple_size_estimate
    FROM table_stats
),

-- ----- per-index statistics -----
index_stats AS (
    SELECT
        ui.schemaname                                       AS schema_name,
        ui.relname                                          AS table_name,
        ui.indexrelname                                     AS index_name,
        pg_size_pretty(pg_relation_size(ui.indexrelid))     AS index_size,
        pg_relation_size(ui.indexrelid)                     AS index_size_bytes,
        COALESCE(ui.idx_scan, 0)                            AS index_usage_count,
        COALESCE(ui.idx_tup_read, 0)                        AS tuples_read,
        COALESCE(ui.idx_tup_fetch, 0)                       AS tuples_fetched
    FROM pg_stat_user_indexes ui
    CROSS JOIN params
    WHERE COALESCE(ui.idx_scan, 0) <= params.max_index_usage
)

SELECT
    t.schema_name,
    t.table_name,
    i.index_name,
    t.table_size,
    i.index_size,
    t.seq_scan_count,
    i.index_usage_count,
    t.dead_tuple_ratio,
    pg_size_pretty(t.dead_tuple_size_estimate)  AS dead_tuple_size,
    COALESCE(
        ROUND((i.index_size_bytes::numeric / NULLIF(t.table_size_bytes, 0)) * 100, 2),
        0
    ) AS index_table_ratio,
    COALESCE(
        ROUND(
            ((i.index_size_bytes - t.table_size_bytes)::numeric
             / NULLIF(t.table_size_bytes, 0)) * 100,
            2
        ),
        0
    ) AS index_over_table_size,
    -- Approximate time window the counters cover.
    -- NULL means the stats have never been reset (counters since server start).
    t.stats_reset_at,
    -- ---- actionable recommendation ----
    CASE
        WHEN i.index_usage_count = 0 AND t.seq_scan_count > 10
            THEN 'REVIEW: index never used but table is heavily seq-scanned – check if queries need redesign'
        WHEN i.index_usage_count = 0
            THEN 'CONSIDER DROP: index has never been used since last stats reset'
        WHEN t.dead_tuple_ratio > 20 AND t.dead_tuple_size_estimate > 524288000  -- 500 MB
            THEN 'ACTION REQUIRED: run VACUUM FULL or REINDEX – dead tuple bloat > 500 MB'
        WHEN t.dead_tuple_ratio > 20
            THEN 'RECOMMEND: run VACUUM ANALYZE – dead tuple ratio exceeds 20%'
        WHEN COALESCE(
                ROUND((i.index_size_bytes::numeric / NULLIF(t.table_size_bytes, 0)) * 100, 2),
                0
             ) > 100
            THEN 'WARNING: index is larger than its table – possible over-indexing'
        WHEN t.seq_scan_count > 1000 AND i.index_usage_count < 10
            THEN 'WARNING: high seq_scan rate with low index usage – consider adding a covering index'
        ELSE 'OK'
    END AS recommendation
FROM table_stats_final t
JOIN index_stats i
    ON t.schema_name = i.schema_name
   AND t.table_name  = i.table_name
ORDER BY
    -- Worst problems first
    CASE
        WHEN i.index_usage_count = 0 AND t.seq_scan_count > 10 THEN 1
        WHEN i.index_usage_count = 0                           THEN 2
        WHEN t.dead_tuple_ratio > 20                           THEN 3
        ELSE 4
    END,
    COALESCE(
        ROUND((i.index_size_bytes::numeric / NULLIF(t.table_size_bytes, 0)) * 100, 2),
        0
    ) DESC,
    t.seq_scan_count DESC,
    t.dead_tuple_ratio DESC,
    t.table_size_bytes DESC;
