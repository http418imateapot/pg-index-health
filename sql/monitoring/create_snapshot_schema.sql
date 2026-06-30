-- ============================================================
-- monitoring/create_snapshot_schema.sql
-- Sets up the persistent schema used by the long-term index health
-- monitoring stack (Scene C).
--
-- Run this once on the target database (or the dedicated monitoring DB).
-- The monitoring role only needs INSERT + SELECT on these tables and
-- SELECT on the pg_stat_* views in the monitored databases.
-- ============================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS index_stats_monitoring;

-- ----- raw snapshot table -----
-- One row per index per snapshot.  Append-only; never UPDATE or DELETE.
CREATE TABLE IF NOT EXISTS index_stats_monitoring.index_stats_history (
    id               BIGSERIAL    PRIMARY KEY,
    snapshot_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    -- Identifies the source database / cluster (set by the collector).
    source_dsn_tag   TEXT         NOT NULL DEFAULT '',
    schema_name      TEXT         NOT NULL,
    table_name       TEXT         NOT NULL,
    index_name       TEXT         NOT NULL,
    -- Raw counter values from pg_stat_user_indexes.
    idx_scan         BIGINT       NOT NULL DEFAULT 0,
    idx_tup_read     BIGINT       NOT NULL DEFAULT 0,
    idx_tup_fetch    BIGINT       NOT NULL DEFAULT 0,
    -- Size in bytes at snapshot time.
    index_size_bytes BIGINT       NOT NULL DEFAULT 0,
    table_size_bytes BIGINT       NOT NULL DEFAULT 0,
    -- Dead tuple stats from pg_stat_user_tables.
    n_live_tup       BIGINT       NOT NULL DEFAULT 0,
    n_dead_tup       BIGINT       NOT NULL DEFAULT 0,
    seq_scan         BIGINT       NOT NULL DEFAULT 0,
    -- Time pg_stat counters were last reset in the source DB.
    stats_reset_at   TIMESTAMPTZ
);

-- Index for fast time-range queries and per-index lookups.
CREATE INDEX IF NOT EXISTS idx_history_snapshot_at
    ON index_stats_monitoring.index_stats_history (snapshot_at DESC);

CREATE INDEX IF NOT EXISTS idx_history_index_lookup
    ON index_stats_monitoring.index_stats_history (source_dsn_tag, schema_name, table_name, index_name, snapshot_at DESC);

-- ----- alert thresholds table -----
-- Operators can insert rows here to configure per-table or global thresholds.
CREATE TABLE IF NOT EXISTS index_stats_monitoring.alert_thresholds (
    id                       SERIAL   PRIMARY KEY,
    source_dsn_tag           TEXT     NOT NULL DEFAULT '',  -- '' = applies to all sources
    schema_name              TEXT     NOT NULL DEFAULT '%', -- LIKE pattern
    table_name               TEXT     NOT NULL DEFAULT '%', -- LIKE pattern
    -- Thresholds (NULL = disabled)
    min_idx_scan_per_day     INT,     -- alert if an index gets fewer scans/day than this
    max_dead_tuple_ratio_pct NUMERIC, -- alert if dead_tuple_ratio exceeds this %
    max_seq_scan_per_day     INT,     -- alert if a table's daily seq_scans exceed this
    -- Notification webhook (POST JSON payload to this URL)
    webhook_url              TEXT,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ----- snapshot metadata table -----
-- Tracks each collection run for auditing and gap detection.
CREATE TABLE IF NOT EXISTS index_stats_monitoring.snapshot_runs (
    id             BIGSERIAL   PRIMARY KEY,
    started_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at    TIMESTAMPTZ,
    source_dsn_tag TEXT        NOT NULL DEFAULT '',
    rows_inserted  INT         NOT NULL DEFAULT 0,
    status         TEXT        NOT NULL DEFAULT 'running', -- running | success | error
    error_message  TEXT
);

COMMIT;
