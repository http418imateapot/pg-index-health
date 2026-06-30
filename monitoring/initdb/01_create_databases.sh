#!/bin/bash
# Creates the two databases used by the monitoring stack.
# Called automatically by the postgres container on first start.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    SELECT 'CREATE DATABASE appdb'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'appdb')\gexec

    SELECT 'CREATE DATABASE monitoring'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'monitoring')\gexec
EOSQL

# Set up the monitoring schema in the monitoring database.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname monitoring \
    -f /sql/monitoring/create_snapshot_schema.sql
