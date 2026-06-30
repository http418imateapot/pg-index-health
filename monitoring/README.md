# PostgreSQL Index Health – Monitoring Stack

Self-hosted monitoring stack for long-term index health trends.

## Components

| Service | Port | Description |
|---------|------|-------------|
| PostgreSQL 16 | 5432 | Target DB (`appdb`) + monitoring history (`monitoring`) |
| Grafana OSS | 3000 | Pre-loaded dashboard |

## Quick Start

```bash
cd monitoring/
docker compose up -d
```

Then open **http://localhost:3000** (user: `admin`, password: `admin`).

### Set up the monitoring schema (first run only)

```bash
docker compose exec postgres \
  psql -U postgres -d monitoring \
  -f /sql/monitoring/create_snapshot_schema.sql
```

### Collect your first snapshot

```bash
# From inside the container
docker compose exec postgres \
  psql -U postgres -d appdb \
  -c "CALL index_stats_monitoring.take_snapshot('docker-appdb');"

# Or with the CLI from outside the container
export PG_DSN="******localhost/appdb"
export PG_MONITORING_DSN="******localhost/monitoring"
pg-index-check monitor snapshot --tag docker-appdb
```

### Automate snapshots with pg_cron

Install [pg_cron](https://github.com/citusdata/pg_cron) in your PostgreSQL instance and run:

```sql
-- Collect a snapshot every hour
SELECT cron.schedule(
    'pg-index-snapshot',
    '0 * * * *',
    $$CALL index_stats_monitoring.take_snapshot('prod-db-1');$$
);
```

Or use a cron job that runs `pg-index-check monitor snapshot`:

```cron
0 * * * * pg-index-check monitor snapshot \
    --dsn $PG_DSN --monitoring-dsn $PG_MONITORING_DSN --tag prod-db-1
```

## Dashboard Panels

- **Index Health Overview** – latest snapshot, colour-coded by recommendation.
- **Seq Scan Increment** – time-series of per-interval seq_scan growth per table.
- **Dead Tuple Ratio Trend** – dead tuple % over time per table.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `POSTGRES_PASSWORD` | `postgres` | PostgreSQL superuser password |
| `GRAFANA_ADMIN_PASS` | `admin` | Grafana admin password |

## Production Notes

- Separate the monitoring database onto a dedicated instance to avoid impacting
  the target workload.
- Use a read-only monitoring role; only the snapshot INSERT needs write access
  on the `index_stats_monitoring` schema.
- Retain history for 30–90 days; prune older rows with a scheduled job:
  ```sql
  DELETE FROM index_stats_monitoring.index_stats_history
  WHERE snapshot_at < now() - interval '90 days';
  ```
