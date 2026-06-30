-- ============================================================
-- monitoring/snapshot_procedure.sql
-- Stored procedure that collects one snapshot of index stats from
-- the *current* database and inserts it into the history table.
--
-- Usage (call from a cron job or pg_cron):
--   CALL index_stats_monitoring.take_snapshot('prod-db-1');
--
-- The procedure is intentionally simple: no dynamic SQL across DBs.
-- The Python collector (cli/pg_index_check) handles multi-database
-- collection and calls this procedure (or the equivalent INSERT) via
-- separate connections.
-- ============================================================

CREATE OR REPLACE PROCEDURE index_stats_monitoring.take_snapshot(
    p_source_dsn_tag TEXT DEFAULT ''
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_run_id       BIGINT;
    v_rows         INT := 0;
    v_reset_at     TIMESTAMPTZ;
BEGIN
    -- Record the run start.
    INSERT INTO index_stats_monitoring.snapshot_runs (source_dsn_tag, status)
    VALUES (p_source_dsn_tag, 'running')
    RETURNING id INTO v_run_id;

    -- Capture the stats-reset time for this database.
    SELECT pg_stat_get_db_stat_reset_time(oid)
    INTO   v_reset_at
    FROM   pg_database
    WHERE  datname = current_database();

    -- Insert one row per index.
    INSERT INTO index_stats_monitoring.index_stats_history (
        snapshot_at,
        source_dsn_tag,
        schema_name,
        table_name,
        index_name,
        idx_scan,
        idx_tup_read,
        idx_tup_fetch,
        index_size_bytes,
        table_size_bytes,
        n_live_tup,
        n_dead_tup,
        seq_scan,
        stats_reset_at
    )
    SELECT
        now(),
        p_source_dsn_tag,
        ui.schemaname,
        ui.relname,
        ui.indexrelname,
        COALESCE(ui.idx_scan, 0),
        COALESCE(ui.idx_tup_read, 0),
        COALESCE(ui.idx_tup_fetch, 0),
        pg_relation_size(ui.indexrelid),
        pg_relation_size(ui.relid),
        COALESCE(st.n_live_tup, 0),
        COALESCE(st.n_dead_tup, 0),
        COALESCE(st.seq_scan, 0),
        v_reset_at
    FROM pg_stat_user_indexes ui
    LEFT JOIN pg_stat_user_tables st
        ON  st.schemaname = ui.schemaname
        AND st.relname    = ui.relname
    WHERE ui.schemaname NOT IN ('pg_catalog', 'information_schema', 'pg_toast');

    GET DIAGNOSTICS v_rows = ROW_COUNT;

    -- Mark run as successful.
    UPDATE index_stats_monitoring.snapshot_runs
    SET    finished_at   = now(),
           rows_inserted = v_rows,
           status        = 'success'
    WHERE  id = v_run_id;

EXCEPTION WHEN OTHERS THEN
    UPDATE index_stats_monitoring.snapshot_runs
    SET    finished_at  = now(),
           status       = 'error',
           error_message = SQLERRM
    WHERE  id = v_run_id;
    RAISE;
END;
$$;
