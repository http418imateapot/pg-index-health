# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- Nothing yet.

---

## [0.1.0] – 2025-06-01

### Added

#### CLI (`pg-index-check`)
- `check` command: full index health scan against `pg_stat_user_tables` /
  `pg_stat_user_indexes` with seven-tier actionable `recommendation` output.
- `redundant` command: detects overlapping indexes where one column list is a
  prefix of another on the same table.
- `snapshot save / compare / list / delete`: point-in-time comparison of
  cumulative stats counters stored as JSON under `~/.pg-index-check/snapshots/`.
- `monitor snapshot`: pushes a stats row into the long-term
  `index_stats_monitoring.index_stats_history` table (Scene C stack).
- Output formats: `table` (default), `json`, `csv`.
- `--issues-only` flag on `check` to surface only non-OK rows.
- `PG_DSN` / `PG_MONITORING_DSN` environment variable support.
- `--version` flag showing package version.

#### SQL scripts (`sql/`)
- `pg_index_check.sql` – standalone health analysis query.
- `redundant_index_check.sql` – standalone redundant-index detection query.
- `create_test_data.sql` / `cleanup_test_data.sql` – reproducible test fixtures
  under schema `bad_index_test`.
- `monitoring/create_snapshot_schema.sql`, `snapshot_procedure.sql`,
  `window_analysis.sql`, `cleanup_snapshot_schema.sql` – Scene C DB schema.

#### Monitoring stack (`monitoring/`)
- Docker Compose stack: PostgreSQL 16-alpine + Grafana OSS.
- Pre-loaded Grafana dashboard with three panels: Index Health Overview,
  Seq Scan Increment, Dead Tuple Ratio Trend.

#### CI/CD (`pg_index_guard.yml`)
- GitHub Actions workflow that spins up PostgreSQL, applies migrations, runs
  `pg-index-check check` and `redundant`, and posts a report on the PR.

[Unreleased]: https://github.com/http418imateapot/pg-index-health/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/http418imateapot/pg-index-health/releases/tag/v0.1.0
