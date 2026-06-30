"""
pg-index-check – CLI entry point.

Examples
--------
# One-shot health check (human-readable table)
pg-index-check check --dsn ******host/mydb

# Only show problem indexes
pg-index-check check --dsn $DSN --issues-only

# JSON output (pipe to jq)
pg-index-check check --dsn $DSN --output json | jq '.[] | select(.recommendation != "OK")'

# CSV output
pg-index-check check --dsn $DSN --output csv > report.csv

# Filter to a specific schema
pg-index-check check --dsn $DSN --schema myapp

# Threshold tuning
pg-index-check check --dsn $DSN --min-seq-scan 50 --max-index-usage 10

# Redundant index detection
pg-index-check redundant --dsn $DSN

# Snapshot: save current stats
pg-index-check snapshot save --dsn $DSN --id prod-baseline

# Snapshot: compare with saved baseline (shows deltas)
pg-index-check snapshot compare --dsn $DSN --id prod-baseline

# Snapshot: list saved snapshots
pg-index-check snapshot list

# Monitoring: push one snapshot to the history table
pg-index-check monitor snapshot --dsn $MONITORED_DSN --monitoring-dsn $MONITORING_DSN --tag prod-db-1
"""

from __future__ import annotations

import sys

import click

from pg_index_check import __version__
from pg_index_check import checker, formatters, snapshots


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _connect(dsn: str):
    """Return an open psycopg2 connection."""
    try:
        import psycopg2
        import psycopg2.extensions
    except ImportError:
        click.echo(
            "psycopg2 is not installed.  Run:  pip install psycopg2-binary",
            err=True,
        )
        sys.exit(1)
    try:
        return psycopg2.connect(dsn)
    except psycopg2.OperationalError as exc:
        click.echo(f"Connection failed: {exc}", err=True)
        sys.exit(1)
    except psycopg2.DatabaseError as exc:
        click.echo(f"Database error during connect: {exc}", err=True)
        sys.exit(1)


def _emit(text: str, output: str, data: list[dict] | None = None) -> None:
    """Write formatted output to stdout."""
    if output == "json" and data is not None:
        click.echo(formatters.format_json(data))
    elif output == "csv" and data is not None:
        click.echo(formatters.format_csv(data), nl=False)
    else:
        click.echo(text)


# ---------------------------------------------------------------------------
# CLI root
# ---------------------------------------------------------------------------

@click.group()
@click.version_option(__version__, prog_name="pg-index-check")
def main() -> None:
    """Lightweight PostgreSQL index health checker."""


# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------

@main.command()
@click.option("--dsn", required=True, envvar="PG_DSN",
              help="PostgreSQL DSN, e.g. ******host/db")
@click.option("--schema", "schema_filter", default="%", show_default=True,
              help="LIKE pattern to restrict schemas (e.g. 'public').")
@click.option("--min-seq-scan", default=0, show_default=True,
              help="Skip tables with fewer seq_scans than this value.")
@click.option("--max-index-usage", default=999_999, show_default=True,
              help="Skip indexes with more idx_scans than this value.")
@click.option("--output", type=click.Choice(["table", "json", "csv"]),
              default="table", show_default=True,
              help="Output format.")
@click.option("--issues-only", is_flag=True, default=False,
              help="Only show rows where recommendation is not OK.")
@click.option("--snapshot-id", default=None,
              help="If set, compare against this saved snapshot and show deltas.")
def check(
    dsn: str,
    schema_filter: str,
    min_seq_scan: int,
    max_index_usage: int,
    output: str,
    issues_only: bool,
    snapshot_id: str | None,
) -> None:
    """Run a full index health check and print results."""
    conn = _connect(dsn)
    try:
        rows = checker.run_index_check(
            conn,
            schema_filter=schema_filter,
            min_seq_scan=min_seq_scan,
            max_index_usage=max_index_usage,
        )
    finally:
        conn.close()

    # Optional delta comparison against a saved snapshot.
    if snapshot_id:
        try:
            baseline = snapshots.load_snapshot(snapshot_id)
            rows = snapshots.compare_snapshots(baseline, rows)
            click.echo(
                f"  Comparing against snapshot '{snapshot_id}' "
                f"(captured {baseline.get('captured_at', 'unknown')})",
                err=True,
            )
        except FileNotFoundError as exc:
            click.echo(str(exc), err=True)
            sys.exit(1)

    if issues_only:
        filtered = [r for r in rows if r.get("recommendation", "OK") != "OK"]
        display_rows = filtered
    else:
        display_rows = rows

    if output == "table":
        if issues_only:
            _emit(formatters.format_issues_only(rows), output)
        else:
            _emit(formatters.format_summary(display_rows), output)
    else:
        _emit("", output, display_rows)


# ---------------------------------------------------------------------------
# redundant
# ---------------------------------------------------------------------------

@main.command()
@click.option("--dsn", required=True, envvar="PG_DSN",
              help="PostgreSQL DSN.")
@click.option("--schema", "schema_filter", default="%", show_default=True,
              help="LIKE pattern to restrict schemas.")
@click.option("--output", type=click.Choice(["table", "json", "csv"]),
              default="table", show_default=True)
def redundant(dsn: str, schema_filter: str, output: str) -> None:
    """Detect redundant (overlapping) indexes."""
    conn = _connect(dsn)
    try:
        rows = checker.run_redundant_check(conn, schema_filter=schema_filter)
    finally:
        conn.close()

    if output == "table":
        _emit(formatters.format_table(rows, title="Redundant Index Report"), output)
    else:
        _emit("", output, rows)


# ---------------------------------------------------------------------------
# snapshot
# ---------------------------------------------------------------------------

@main.group()
def snapshot() -> None:
    """Save and compare index stats snapshots."""


@snapshot.command("save")
@click.option("--dsn", required=True, envvar="PG_DSN")
@click.option("--id", "snapshot_id", required=True,
              help="Unique identifier for this snapshot (e.g. 'prod-baseline').")
@click.option("--schema", "schema_filter", default="%", show_default=True)
@click.option("--force", is_flag=True, default=False,
              help="Overwrite an existing snapshot with the same ID.")
def snapshot_save(dsn: str, snapshot_id: str, schema_filter: str, force: bool) -> None:
    """Capture the current index stats and save them to disk."""
    conn = _connect(dsn)
    try:
        rows = checker.run_index_check(conn, schema_filter=schema_filter)
    finally:
        conn.close()

    path = _snapshot_save_helper(snapshot_id, rows, force)
    click.echo(f"✓ Saved {len(rows)} rows to {path}")


def _snapshot_save_helper(snapshot_id: str, rows: list[dict], force: bool):
    if not force:
        try:
            snapshots.load_snapshot(snapshot_id)
            raise click.UsageError(
                f"Snapshot '{snapshot_id}' already exists.  Use --force to overwrite."
            )
        except FileNotFoundError:
            pass
    return snapshots.save_snapshot(snapshot_id, rows)


@snapshot.command("compare")
@click.option("--dsn", required=True, envvar="PG_DSN")
@click.option("--id", "snapshot_id", required=True,
              help="Snapshot ID to compare against.")
@click.option("--schema", "schema_filter", default="%", show_default=True)
@click.option("--output", type=click.Choice(["table", "json", "csv"]),
              default="table", show_default=True)
def snapshot_compare(dsn: str, snapshot_id: str, schema_filter: str, output: str) -> None:
    """Compare current stats against a saved snapshot (show deltas)."""
    try:
        baseline = snapshots.load_snapshot(snapshot_id)
    except FileNotFoundError as exc:
        click.echo(str(exc), err=True)
        sys.exit(1)

    conn = _connect(dsn)
    try:
        current = checker.run_index_check(conn, schema_filter=schema_filter)
    finally:
        conn.close()

    enriched = snapshots.compare_snapshots(baseline, current)
    click.echo(
        f"  Baseline: snapshot '{snapshot_id}' captured {baseline.get('captured_at', 'unknown')}",
        err=True,
    )

    if output == "table":
        _emit(formatters.format_table(enriched, title="Snapshot Comparison"), output)
    else:
        _emit("", output, enriched)


@snapshot.command("list")
def snapshot_list() -> None:
    """List all saved snapshots."""
    snaps = snapshots.list_snapshots()
    if not snaps:
        click.echo("No snapshots saved yet.")
        return
    _emit(formatters.format_table(snaps, title="Saved Snapshots"), "table")


@snapshot.command("delete")
@click.option("--id", "snapshot_id", required=True)
def snapshot_delete(snapshot_id: str) -> None:
    """Delete a saved snapshot."""
    try:
        snapshots.delete_snapshot(snapshot_id)
        click.echo(f"✓ Deleted snapshot '{snapshot_id}'.")
    except FileNotFoundError as exc:
        click.echo(str(exc), err=True)
        sys.exit(1)


# ---------------------------------------------------------------------------
# monitor
# ---------------------------------------------------------------------------

@main.group()
def monitor() -> None:
    """Long-term monitoring commands (Scene C stack)."""


@monitor.command("snapshot")
@click.option("--dsn", required=True, envvar="PG_DSN",
              help="DSN for the database to monitor.")
@click.option("--monitoring-dsn", required=True, envvar="PG_MONITORING_DSN",
              help="DSN for the database that holds the monitoring history tables.")
@click.option("--tag", "dsn_tag", default="",
              help="Friendly label stored in source_dsn_tag (e.g. 'prod-db-1').")
def monitor_snapshot(dsn: str, monitoring_dsn: str, dsn_tag: str) -> None:
    """Capture one stats snapshot into the monitoring history table."""
    src_conn = _connect(dsn)
    mon_conn = _connect(monitoring_dsn)
    try:
        rows = checker.run_index_check(src_conn, max_index_usage=999_999)
        count = checker.insert_snapshot(mon_conn, dsn_tag=dsn_tag)
        mon_conn.commit()
        click.echo(f"✓ Inserted {count} snapshot rows (tag='{dsn_tag}').")
    finally:
        src_conn.close()
        mon_conn.close()


if __name__ == "__main__":
    main()
