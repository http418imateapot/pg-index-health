"""
Snapshot management for pg_index_check.

Snapshots are stored as JSON files under ~/.pg-index-check/snapshots/.
Each snapshot file is named <snapshot_id>.json and contains a list of
index stats rows captured at a point in time.

This enables delta analysis between two runs without requiring a
monitoring database.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def _snapshot_dir() -> Path:
    base = Path(os.environ.get("PG_INDEX_CHECK_HOME", Path.home() / ".pg-index-check"))
    snap_dir = base / "snapshots"
    snap_dir.mkdir(parents=True, exist_ok=True)
    return snap_dir


def _snap_path(snapshot_id: str) -> Path:
    # Sanitise to prevent directory traversal: allow only alphanumerics, hyphens, underscores.
    safe_id = "".join(c for c in snapshot_id if c.isalnum() or c in ("-", "_"))
    if not safe_id:
        raise ValueError(f"Invalid snapshot ID: {snapshot_id!r}")
    return _snapshot_dir() / f"{safe_id}.json"


def _serialize(value: Any) -> Any:
    if isinstance(value, datetime):
        return value.isoformat()
    return value


def save_snapshot(snapshot_id: str, rows: list[dict]) -> Path:
    """Persist *rows* to disk under *snapshot_id*.

    Raises FileExistsError if a snapshot with that ID already exists –
    pass ``overwrite=True`` to replace it.
    """
    path = _snap_path(snapshot_id)
    payload = {
        "snapshot_id": snapshot_id,
        "captured_at": datetime.now(tz=timezone.utc).isoformat(),
        "rows": [{k: _serialize(v) for k, v in row.items()} for row in rows],
    }
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
    return path


def load_snapshot(snapshot_id: str) -> dict:
    """Load a previously saved snapshot.  Returns the raw payload dict."""
    path = _snap_path(snapshot_id)
    if not path.exists():
        raise FileNotFoundError(
            f"Snapshot '{snapshot_id}' not found at {path}.\n"
            "Run  pg-index-check snapshot save --id <ID>  first."
        )
    return json.loads(path.read_text(encoding="utf-8"))


def compare_snapshots(
    baseline: dict,
    current_rows: list[dict],
) -> list[dict]:
    """Compute deltas between *baseline* snapshot and *current_rows*.

    Returns a list of dicts with ``_delta_*`` fields added for the
    key counters: ``idx_scan``, ``seq_scan_count``.

    When a counter is lower in the current snapshot than in the baseline
    (indicating a pg_stat_reset), the delta is set to the current value.
    """
    baseline_map: dict[tuple, dict] = {}
    for row in baseline.get("rows", []):
        key = (row.get("schema_name"), row.get("table_name"), row.get("index_name"))
        baseline_map[key] = row

    result = []
    for row in current_rows:
        key = (row.get("schema_name"), row.get("table_name"), row.get("index_name"))
        base = baseline_map.get(key)
        enriched = dict(row)
        if base is not None:
            for counter in ("index_usage_count", "seq_scan_count"):
                cur_val = int(row.get(counter) or 0)
                bas_val = int(base.get(counter) or 0)
                delta = cur_val - bas_val if cur_val >= bas_val else cur_val
                enriched[f"_delta_{counter}"] = delta
            enriched["_baseline_captured_at"] = baseline.get("captured_at")
        result.append(enriched)
    return result


def list_snapshots() -> list[dict]:
    """Return metadata for all saved snapshots."""
    snapshots = []
    for path in sorted(_snapshot_dir().glob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            snapshots.append(
                {
                    "snapshot_id": data.get("snapshot_id", path.stem),
                    "captured_at": data.get("captured_at"),
                    "row_count": len(data.get("rows", [])),
                    "path": str(path),
                }
            )
        except (json.JSONDecodeError, OSError):
            pass
    return snapshots


def delete_snapshot(snapshot_id: str) -> None:
    """Delete a snapshot file."""
    path = _snap_path(snapshot_id)
    if not path.exists():
        raise FileNotFoundError(f"Snapshot '{snapshot_id}' not found at {path}.")
    path.unlink()
