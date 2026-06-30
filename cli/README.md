# pg-index-check CLI

A lightweight, read-only PostgreSQL index health checker that wraps the
`pg_index_check.sql` query into a convenient command-line tool.

## Installation

```bash
cd cli/
pip install .
# or, for development:
pip install -e ".[dev]"
```

## Quick Start

```bash
# Human-readable table (default)
pg-index-check check --dsn "******localhost/mydb"

# Only show problem indexes
pg-index-check check --dsn $PG_DSN --issues-only

# JSON output (pipe to jq)
pg-index-check check --dsn $PG_DSN --output json | jq '.[] | select(.recommendation != "OK")'

# CSV output (redirect to file)
pg-index-check check --dsn $PG_DSN --output csv > report.csv
```

You can also set `PG_DSN` as an environment variable to avoid repeating it:

```bash
export PG_DSN="******localhost/mydb"
pg-index-check check
```

## Commands

### `check` – Full index health scan

```
pg-index-check check [OPTIONS]

Options:
  --dsn TEXT               PostgreSQL DSN  [required, or $PG_DSN]
  --schema TEXT            LIKE pattern to restrict schemas  [default: %]
  --min-seq-scan INTEGER   Skip tables with fewer seq_scans  [default: 0]
  --max-index-usage INT    Skip indexes with more idx_scans  [default: 999999]
  --output [table|json|csv] Output format  [default: table]
  --issues-only            Only show rows where recommendation != OK
  --snapshot-id TEXT       Compare against a saved snapshot
```

### `redundant` – Detect overlapping indexes

```
pg-index-check redundant --dsn $PG_DSN [--schema public]
```

Finds indexes whose column list is a prefix of another index on the same
table.  The longer index supersedes the shorter one, making the shorter
one a candidate for removal.

### `snapshot` – Point-in-time comparison

Because `seq_scan` and `idx_scan` are cumulative since the last
`pg_stat_reset()`, comparing two snapshots gives you the *incremental*
activity for a time window — e.g. "this index had zero scans over the
last 7 days".

```bash
# Save a baseline
pg-index-check snapshot save --dsn $PG_DSN --id prod-baseline

# One week later: compare
pg-index-check snapshot compare --dsn $PG_DSN --id prod-baseline

# List all saved snapshots
pg-index-check snapshot list

# Delete a snapshot
pg-index-check snapshot delete --id prod-baseline
```

Snapshots are stored as JSON files in `~/.pg-index-check/snapshots/`.

### `monitor snapshot` – Push to long-term history

For the Scene C monitoring stack (requires the monitoring schema to be
set up first via `sql/monitoring/create_snapshot_schema.sql`):

```bash
pg-index-check monitor snapshot \
  --dsn $MONITORED_DSN \
  --monitoring-dsn $MONITORING_DSN \
  --tag prod-db-1
```

## Required Permissions

The monitoring role only needs read access.  Grant the following:

```sql
GRANT SELECT ON pg_stat_user_tables    TO monitoring_role;
GRANT SELECT ON pg_stat_user_indexes   TO monitoring_role;
GRANT SELECT ON pg_class               TO monitoring_role;
GRANT SELECT ON pg_namespace           TO monitoring_role;
GRANT SELECT ON pg_index               TO monitoring_role;
GRANT SELECT ON pg_attribute           TO monitoring_role;
GRANT SELECT ON pg_database            TO monitoring_role;
GRANT EXECUTE ON FUNCTION pg_relation_size(oid) TO monitoring_role;
GRANT EXECUTE ON FUNCTION pg_size_pretty(bigint) TO monitoring_role;
GRANT EXECUTE ON FUNCTION pg_stat_get_db_stat_reset_time(oid) TO monitoring_role;
```

## Output Columns

| Column | Description |
|--------|-------------|
| `schema_name` | Schema |
| `table_name` | Table |
| `index_name` | Index |
| `table_size` | Pretty-printed heap size |
| `index_size` | Pretty-printed index size |
| `seq_scan_count` | Cumulative full-table scans since stats reset |
| `index_usage_count` | Cumulative index scans since stats reset |
| `dead_tuple_ratio` | % of rows that are dead tuples |
| `dead_tuple_size` | Estimated bloat (approx; use pgstattuple for exact values) |
| `index_table_ratio` | index_size / table_size × 100 |
| `index_over_table_size` | (index_size − table_size) / table_size × 100 |
| `stats_reset_at` | When the pg_stat counters were last reset |
| `recommendation` | Actionable suggestion |
