-- ============================================================
-- monitoring/cleanup_snapshot_schema.sql
-- Removes all objects created by create_snapshot_schema.sql.
-- WARNING: this permanently deletes all historical snapshot data.
-- ============================================================

DROP SCHEMA IF EXISTS index_stats_monitoring CASCADE;
