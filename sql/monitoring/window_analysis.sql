-- ============================================================
-- monitoring/window_analysis.sql
-- Time-window delta queries for the long-term monitoring stack.
--
-- These queries compare two snapshots to compute *incremental* activity
-- instead of raw cumulative counters, solving the "stats reset" problem.
--
-- Adjust the interval literals ('7 days', '1 day') to fit your needs.
-- ============================================================

-- ============================================================
-- 1. Per-index activity over a rolling 7-day window
--    Shows idx_scan delta, seq_scan delta, and dead-tuple growth.
-- ============================================================
WITH

-- Most recent snapshot per index
latest AS (
    SELECT DISTINCT ON (source_dsn_tag, schema_name, table_name, index_name)
        source_dsn_tag, schema_name, table_name, index_name,
        snapshot_at     AS latest_at,
        idx_scan        AS latest_idx_scan,
        seq_scan        AS latest_seq_scan,
        n_dead_tup      AS latest_n_dead_tup,
        n_live_tup      AS latest_n_live_tup,
        index_size_bytes,
        table_size_bytes,
        stats_reset_at
    FROM index_stats_monitoring.index_stats_history
    ORDER BY source_dsn_tag, schema_name, table_name, index_name, snapshot_at DESC
),

-- Oldest snapshot within the last 7 days per index (baseline)
baseline AS (
    SELECT DISTINCT ON (source_dsn_tag, schema_name, table_name, index_name)
        source_dsn_tag, schema_name, table_name, index_name,
        snapshot_at     AS baseline_at,
        idx_scan        AS baseline_idx_scan,
        seq_scan        AS baseline_seq_scan,
        n_dead_tup      AS baseline_n_dead_tup
    FROM index_stats_monitoring.index_stats_history
    WHERE snapshot_at >= now() - interval '7 days'
    ORDER BY source_dsn_tag, schema_name, table_name, index_name, snapshot_at ASC
)

SELECT
    l.source_dsn_tag,
    l.schema_name,
    l.table_name,
    l.index_name,
    pg_size_pretty(l.index_size_bytes)                  AS index_size,
    pg_size_pretty(l.table_size_bytes)                  AS table_size,
    -- Guard against counter resets: if latest < baseline the counter was reset.
    CASE WHEN l.latest_idx_scan >= b.baseline_idx_scan
         THEN l.latest_idx_scan - b.baseline_idx_scan
         ELSE l.latest_idx_scan   -- treat reset as starting from zero
    END                                                 AS idx_scan_delta_7d,
    CASE WHEN l.latest_seq_scan >= b.baseline_seq_scan
         THEN l.latest_seq_scan - b.baseline_seq_scan
         ELSE l.latest_seq_scan
    END                                                 AS seq_scan_delta_7d,
    l.latest_n_dead_tup - b.baseline_n_dead_tup         AS dead_tup_growth_7d,
    ROUND(
        (l.latest_n_dead_tup::numeric
         / NULLIF(l.latest_n_live_tup + l.latest_n_dead_tup, 0)) * 100,
        2
    )                                                   AS dead_tuple_ratio_pct,
    b.baseline_at,
    l.latest_at,
    l.stats_reset_at,
    -- Recommendation based on the 7-day window.
    -- Guard all delta expressions against counter resets (latest < baseline).
    CASE
        WHEN CASE WHEN l.latest_idx_scan >= b.baseline_idx_scan
                  THEN l.latest_idx_scan - b.baseline_idx_scan
                  ELSE l.latest_idx_scan END = 0
             AND b.baseline_idx_scan IS NOT NULL
            THEN 'CONSIDER DROP: zero index scans over last 7 days'
        WHEN CASE WHEN l.latest_seq_scan >= b.baseline_seq_scan
                  THEN l.latest_seq_scan - b.baseline_seq_scan
                  ELSE l.latest_seq_scan END > 1000
             AND CASE WHEN l.latest_idx_scan >= b.baseline_idx_scan
                      THEN l.latest_idx_scan - b.baseline_idx_scan
                      ELSE l.latest_idx_scan END < 10
            THEN 'WARNING: high seq_scan rate with very low index usage over last 7 days'
        WHEN (l.latest_n_dead_tup - b.baseline_n_dead_tup) > 100000
            THEN 'RECOMMEND VACUUM: dead tuples growing rapidly over last 7 days'
        ELSE 'OK'
    END                                                 AS recommendation
FROM latest l
JOIN baseline b
    USING (source_dsn_tag, schema_name, table_name, index_name)
ORDER BY
    idx_scan_delta_7d ASC,      -- least-used indexes first
    seq_scan_delta_7d DESC,
    dead_tup_growth_7d DESC;


-- ============================================================
-- 2. Daily seq_scan trend (for Grafana time series panel)
--    Returns the seq_scan increment per day per table.
-- ============================================================
SELECT
    date_trunc('day', h.snapshot_at)    AS day,
    h.source_dsn_tag,
    h.schema_name,
    h.table_name,
    -- delta between consecutive snapshots on the same day
    h.seq_scan - LAG(h.seq_scan) OVER (
        PARTITION BY h.source_dsn_tag, h.schema_name, h.table_name
        ORDER BY h.snapshot_at
    )                                   AS seq_scan_increment
FROM index_stats_monitoring.index_stats_history h
WHERE h.snapshot_at >= now() - interval '30 days'
ORDER BY day, h.source_dsn_tag, h.schema_name, h.table_name;


-- ============================================================
-- 3. Dead-tuple ratio trend (for Grafana time series panel)
-- ============================================================
SELECT
    h.snapshot_at,
    h.source_dsn_tag,
    h.schema_name,
    h.table_name,
    ROUND(
        (h.n_dead_tup::numeric / NULLIF(h.n_live_tup + h.n_dead_tup, 0)) * 100,
        2
    ) AS dead_tuple_ratio_pct
FROM index_stats_monitoring.index_stats_history h
WHERE h.snapshot_at >= now() - interval '30 days'
  -- Pick just one index per table to avoid duplicating table-level stats
  AND h.index_name IN (
      SELECT DISTINCT ON (source_dsn_tag, schema_name, table_name)
          index_name
      FROM index_stats_monitoring.index_stats_history
      ORDER BY source_dsn_tag, schema_name, table_name, index_name
  )
ORDER BY h.snapshot_at, h.source_dsn_tag, h.schema_name, h.table_name;
