"""
Database query layer for pg_index_check.

All SQL executed here is read-only.  The only permission required is
SELECT on pg_stat_user_tables, pg_stat_user_indexes, pg_class,
pg_namespace, pg_attribute, pg_index, and pg_database.
"""

from __future__ import annotations

import textwrap
from typing import Any

# ----- SQL: main index health check -----

_INDEX_CHECK_SQL = textwrap.dedent(
    """
    WITH
    params AS (
        SELECT
            %(min_seq_scan)s    AS min_seq_scan,
            %(max_index_usage)s AS max_index_usage,
            %(schema_filter)s   AS schema_filter
    ),
    table_stats AS (
        SELECT
            n.nspname                                        AS schema_name,
            c.relname                                        AS table_name,
            pg_relation_size(c.oid)                          AS table_size_bytes,
            COALESCE(s.seq_scan, 0)                          AS seq_scan_count,
            COALESCE(s.n_live_tup, 0)                        AS n_live_tup,
            COALESCE(s.n_dead_tup, 0)                        AS n_dead_tup,
            COALESCE(
                ROUND(
                    (s.n_dead_tup::numeric
                     / NULLIF(s.n_live_tup + s.n_dead_tup, 0)) * 100, 2
                ), 0
            )                                                AS dead_tuple_ratio,
            pg_stat_get_db_stat_reset_time(
                (SELECT oid FROM pg_database WHERE datname = current_database())
            )                                                AS stats_reset_at
        FROM pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        JOIN pg_stat_user_tables s ON c.oid = s.relid
        CROSS JOIN params
        WHERE c.relkind = 'r'
          AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND n.nspname LIKE params.schema_filter
          AND COALESCE(s.seq_scan, 0) >= params.min_seq_scan
    ),
    table_stats_final AS (
        SELECT *,
            COALESCE(ROUND((dead_tuple_ratio / 100.0) * table_size_bytes), 0)
                AS dead_tuple_size_estimate
        FROM table_stats
    ),
    index_stats AS (
        SELECT
            ui.schemaname                                    AS schema_name,
            ui.relname                                       AS table_name,
            ui.indexrelname                                  AS index_name,
            pg_relation_size(ui.indexrelid)                  AS index_size_bytes,
            COALESCE(ui.idx_scan, 0)                         AS index_usage_count,
            COALESCE(ui.idx_tup_read, 0)                     AS tuples_read,
            COALESCE(ui.idx_tup_fetch, 0)                    AS tuples_fetched
        FROM pg_stat_user_indexes ui
        CROSS JOIN params
        WHERE COALESCE(ui.idx_scan, 0) <= params.max_index_usage
    )
    SELECT
        t.schema_name,
        t.table_name,
        i.index_name,
        pg_size_pretty(t.table_size_bytes)               AS table_size,
        pg_size_pretty(i.index_size_bytes)               AS index_size,
        t.seq_scan_count,
        i.index_usage_count,
        t.dead_tuple_ratio,
        pg_size_pretty(t.dead_tuple_size_estimate)       AS dead_tuple_size,
        COALESCE(
            ROUND((i.index_size_bytes::numeric
                   / NULLIF(t.table_size_bytes, 0)) * 100, 2), 0
        ) AS index_table_ratio,
        COALESCE(
            ROUND(((i.index_size_bytes - t.table_size_bytes)::numeric
                   / NULLIF(t.table_size_bytes, 0)) * 100, 2), 0
        ) AS index_over_table_size,
        t.stats_reset_at,
        CASE
            WHEN i.index_usage_count = 0 AND t.seq_scan_count > 10
                THEN 'REVIEW: index never used but table is heavily seq-scanned'
            WHEN i.index_usage_count = 0
                THEN 'CONSIDER DROP: index has never been used since last stats reset'
            WHEN t.dead_tuple_ratio > 20
                 AND t.dead_tuple_size_estimate > 524288000
                THEN 'ACTION REQUIRED: run VACUUM FULL or REINDEX (bloat > 500 MB)'
            WHEN t.dead_tuple_ratio > 20
                THEN 'RECOMMEND: run VACUUM ANALYZE (dead tuple ratio > 20%%)'
            WHEN COALESCE(
                     ROUND((i.index_size_bytes::numeric
                            / NULLIF(t.table_size_bytes, 0)) * 100, 2), 0
                 ) > 100
                THEN 'WARNING: index larger than its table (over-indexing?)'
            WHEN t.seq_scan_count > 1000 AND i.index_usage_count < 10
                THEN 'WARNING: high seq_scan with low index usage'
            ELSE 'OK'
        END AS recommendation
    FROM table_stats_final t
    JOIN index_stats i
        ON t.schema_name = i.schema_name
       AND t.table_name  = i.table_name
    ORDER BY
        CASE
            WHEN i.index_usage_count = 0 AND t.seq_scan_count > 10 THEN 1
            WHEN i.index_usage_count = 0                           THEN 2
            WHEN t.dead_tuple_ratio > 20                           THEN 3
            ELSE 4
        END,
        COALESCE(
            ROUND((i.index_size_bytes::numeric
                   / NULLIF(t.table_size_bytes, 0)) * 100, 2), 0
        ) DESC,
        t.seq_scan_count DESC,
        t.dead_tuple_ratio DESC,
        t.table_size_bytes DESC;
    """
)

# ----- SQL: redundant index detection -----

_REDUNDANT_INDEX_SQL = textwrap.dedent(
    """
    WITH index_columns AS (
        SELECT
            n.nspname                                          AS schema_name,
            t.relname                                          AS table_name,
            ix.indexrelid                                      AS index_oid,
            ic.relname                                         AS index_name,
            ix.indisunique                                     AS is_unique,
            ix.indisprimary                                    AS is_primary,
            ix.indpred IS NOT NULL                             AS is_partial,
            array_agg(a.attname ORDER BY col_order.ordinality) AS columns
        FROM pg_index ix
        JOIN pg_class  t  ON t.oid  = ix.indrelid
        JOIN pg_class  ic ON ic.oid = ix.indexrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN LATERAL unnest(ix.indkey) WITH ORDINALITY
             AS col_order(attnum, ordinality) ON true
        JOIN pg_attribute a
            ON a.attrelid = ix.indrelid AND a.attnum = col_order.attnum
        WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND n.nspname LIKE %(schema_filter)s
          AND col_order.attnum > 0
        GROUP BY n.nspname, t.relname, ix.indexrelid, ic.relname,
                 ix.indisunique, ix.indisprimary, ix.indpred
    ),
    redundant_pairs AS (
        SELECT
            a.schema_name,
            a.table_name,
            a.index_name                                       AS covering_index,
            a.columns                                          AS covering_columns,
            b.index_name                                       AS redundant_index,
            b.columns                                          AS redundant_columns,
            b.is_unique                                        AS redundant_is_unique,
            b.is_primary                                       AS redundant_is_primary,
            b.is_partial                                       AS redundant_is_partial,
            COALESCE(ui.idx_scan, 0)                           AS redundant_idx_scan,
            pg_size_pretty(pg_relation_size(b.index_oid))      AS redundant_index_size
        FROM index_columns a
        JOIN index_columns b
            ON  a.schema_name = b.schema_name
            AND a.table_name  = b.table_name
            AND a.index_oid  <> b.index_oid
            AND b.columns     = a.columns[1:array_length(b.columns, 1)]
            AND array_length(a.columns, 1) > array_length(b.columns, 1)
        LEFT JOIN pg_stat_user_indexes ui ON ui.indexrelid = b.index_oid
    )
    SELECT
        schema_name,
        table_name,
        redundant_index,
        array_to_string(redundant_columns, ', ')  AS redundant_columns,
        redundant_index_size,
        redundant_idx_scan,
        covering_index,
        array_to_string(covering_columns, ', ')   AS covering_columns,
        CASE
            WHEN redundant_is_primary THEN 'SKIP – is PRIMARY KEY'
            WHEN redundant_is_unique  THEN 'CAUTION – is UNIQUE constraint'
            WHEN redundant_is_partial THEN 'REVIEW – partial index'
            WHEN redundant_idx_scan > 0
                THEN 'REVIEW – used ' || redundant_idx_scan || ' times'
            ELSE 'SAFE TO DROP'
        END AS recommendation
    FROM redundant_pairs
    ORDER BY schema_name, table_name, redundant_idx_scan ASC;
    """
)

# ----- SQL: insert snapshot -----

_INSERT_SNAPSHOT_SQL = textwrap.dedent(
    """
    INSERT INTO index_stats_monitoring.index_stats_history (
        snapshot_at, source_dsn_tag,
        schema_name, table_name, index_name,
        idx_scan, idx_tup_read, idx_tup_fetch,
        index_size_bytes, table_size_bytes,
        n_live_tup, n_dead_tup, seq_scan, stats_reset_at
    )
    SELECT
        now(), %(dsn_tag)s,
        ui.schemaname, ui.relname, ui.indexrelname,
        COALESCE(ui.idx_scan, 0),
        COALESCE(ui.idx_tup_read, 0),
        COALESCE(ui.idx_tup_fetch, 0),
        pg_relation_size(ui.indexrelid),
        pg_relation_size(ui.relid),
        COALESCE(st.n_live_tup, 0),
        COALESCE(st.n_dead_tup, 0),
        COALESCE(st.seq_scan, 0),
        pg_stat_get_db_stat_reset_time(
            (SELECT oid FROM pg_database WHERE datname = current_database())
        )
    FROM pg_stat_user_indexes ui
    LEFT JOIN pg_stat_user_tables st
        ON st.schemaname = ui.schemaname AND st.relname = ui.relname
    WHERE ui.schemaname NOT IN ('pg_catalog', 'information_schema', 'pg_toast');
    """
)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def run_index_check(
    conn: Any,
    *,
    schema_filter: str = "%",
    min_seq_scan: int = 0,
    max_index_usage: int = 999_999,
) -> list[dict]:
    """Return index health rows for the connected database.

    Parameters
    ----------
    conn:
        An open psycopg2 connection.
    schema_filter:
        LIKE pattern to restrict schemas, e.g. ``'public'`` or ``'%'``.
    min_seq_scan:
        Exclude tables whose seq_scan count is below this threshold.
    max_index_usage:
        Exclude indexes whose idx_scan count exceeds this threshold.
    """
    with conn.cursor() as cur:
        cur.execute(
            _INDEX_CHECK_SQL,
            {
                "schema_filter": schema_filter,
                "min_seq_scan": min_seq_scan,
                "max_index_usage": max_index_usage,
            },
        )
        cols = [d[0] for d in cur.description]
        return [dict(zip(cols, row)) for row in cur.fetchall()]


def run_redundant_check(
    conn: Any,
    *,
    schema_filter: str = "%",
) -> list[dict]:
    """Return redundant index pairs for the connected database."""
    with conn.cursor() as cur:
        cur.execute(_REDUNDANT_INDEX_SQL, {"schema_filter": schema_filter})
        cols = [d[0] for d in cur.description]
        return [dict(zip(cols, row)) for row in cur.fetchall()]


def insert_snapshot(conn: Any, *, dsn_tag: str = "") -> int:
    """Insert a stats snapshot into the monitoring history table.

    Returns the number of rows inserted.
    """
    with conn.cursor() as cur:
        cur.execute(_INSERT_SNAPSHOT_SQL, {"dsn_tag": dsn_tag})
        return cur.rowcount
