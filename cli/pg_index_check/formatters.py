"""Output formatters for pg_index_check results."""

from __future__ import annotations

import csv
import io
import json
from datetime import datetime, timezone
from typing import Any


def _serialize(value: Any) -> Any:
    """Make a value JSON-serialisable."""
    if isinstance(value, datetime):
        return value.isoformat()
    return value


def format_json(rows: list[dict]) -> str:
    """Serialise rows as a pretty-printed JSON array."""
    return json.dumps(
        [{k: _serialize(v) for k, v in row.items()} for row in rows],
        indent=2,
        ensure_ascii=False,
    )


def format_csv(rows: list[dict]) -> str:
    """Serialise rows as CSV (with header row)."""
    if not rows:
        return ""
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=list(rows[0].keys()))
    writer.writeheader()
    for row in rows:
        writer.writerow({k: _serialize(v) for k, v in row.items()})
    return buf.getvalue()


def format_table(rows: list[dict], title: str = "") -> str:
    """Serialise rows as a human-readable ASCII table using tabulate."""
    try:
        from tabulate import tabulate
    except ImportError:
        return format_csv(rows)

    if not rows:
        return f"{title}\n(no results)\n" if title else "(no results)\n"

    # Replace None with empty string for display.
    clean = [{k: ("" if v is None else _serialize(v)) for k, v in r.items()} for r in rows]
    table = tabulate(clean, headers="keys", tablefmt="psql", maxcolwidths=40)

    if title:
        return f"\n{'=' * len(title)}\n{title}\n{'=' * len(title)}\n{table}\n"
    return table + "\n"


# Columns displayed in the default terminal output (subset of all columns).
_SUMMARY_COLUMNS = [
    "schema_name",
    "table_name",
    "index_name",
    "index_size",
    "seq_scan_count",
    "index_usage_count",
    "dead_tuple_ratio",
    "index_table_ratio",
    "recommendation",
]


def format_summary(rows: list[dict]) -> str:
    """Return a condensed table with the most actionable columns."""
    trimmed = [{k: r.get(k) for k in _SUMMARY_COLUMNS if k in r} for r in rows]
    return format_table(trimmed, title="Index Health Summary")


def format_issues_only(rows: list[dict]) -> str:
    """Return only rows whose recommendation is not 'OK'."""
    issues = [r for r in rows if r.get("recommendation", "OK") != "OK"]
    if not issues:
        return "\n✓ No index issues detected.\n"
    return format_summary(issues)
