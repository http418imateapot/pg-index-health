# Contributing to pg-index-health

Thank you for taking the time to contribute! 🎉

This document describes how to set up a development environment, run tests, and
submit changes.

---

## Table of Contents

1. [Code of Conduct](#code-of-conduct)
2. [How to Report Bugs](#how-to-report-bugs)
3. [How to Request Features](#how-to-request-features)
4. [Development Setup](#development-setup)
5. [Running Tests](#running-tests)
6. [Coding Standards](#coding-standards)
7. [Submitting a Pull Request](#submitting-a-pull-request)
8. [Project Structure](#project-structure)

---

## Code of Conduct

Be respectful and constructive. We follow the spirit of the
[Contributor Covenant](https://www.contributor-covenant.org/version/2/1/code_of_conduct/).

---

## How to Report Bugs

1. Search existing [issues](https://github.com/http418imateapot/pg-index-health/issues)
   to avoid duplicates.
2. Open a new issue using the **Bug Report** template.
3. Include: pg-index-check version (`pg-index-check --version`), Python version,
   PostgreSQL version, and the exact command you ran (with DSN redacted).

---

## How to Request Features

Open an issue using the **Feature Request** template.  Describe the use case and
the problem you are trying to solve rather than a specific implementation.

---

## Development Setup

### Prerequisites

- Python ≥ 3.9
- PostgreSQL 14+ (for integration tests; local install or Docker)
- `git`

### Clone and install

```bash
git clone https://github.com/http418imateapot/pg-index-health.git
cd pg-index-health/cli
python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -e ".[dev]"
```

This installs `pg-index-check` in editable mode together with `pytest`,
`pytest-mock`, and `ruff`.

### Monitoring stack (optional)

```bash
cd monitoring/
docker compose up -d
```

Opens PostgreSQL on `localhost:5432` and Grafana on `localhost:3000`.

---

## Running Tests

```bash
cd cli/
pytest
```

### Integration tests (requires a live PostgreSQL instance)

Set `PG_DSN` to a writable test database before running pytest:

```bash
export PG_DSN="******localhost/testdb"
pytest -m integration
```

> ⚠️  Integration tests create and drop the schema `bad_index_test`.
> Do **not** point them at a production database.

---

## Coding Standards

- **Python 3.9+** – use `from __future__ import annotations` in every module.
- **Line length**: 100 characters (`ruff` enforces this).
- **Linting / formatting**: run `ruff check .` and `ruff format .` before
  committing.
- **SQL**: keep all SQL in `checker.py` as module-level constants named
  `_UPPER_SNAKE_SQL`, using `textwrap.dedent()`.
- **CLI errors**: write to `stderr` with `click.echo(..., err=True)` then
  `sys.exit(1)`.
- **No secrets in commits**: DSNs, passwords, and tokens must never appear in
  source files (use environment variables or `${{ secrets.* }}`).

---

## Submitting a Pull Request

1. **Fork** the repository and create a feature branch:
   ```bash
   git checkout -b feat/my-improvement
   ```
2. Make your changes with small, focused commits.
3. Add or update tests to cover your changes.
4. Run tests and linting locally:
   ```bash
   cd cli/
   ruff check .
   pytest
   ```
5. Update `CHANGELOG.md` – add a bullet under `[Unreleased]`.
6. Open a PR against `main` and fill in the pull request template.
7. A maintainer will review and may request changes.

### Commit message style

Use the [Conventional Commits](https://www.conventionalcommits.org/) format:

```
<type>(<scope>): <short summary>

[optional body]
[optional footer]
```

Common types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `ci`.

---

## Project Structure

```
pg-index-health/
├── cli/                     # Python package (pg-index-check)
│   ├── pg_index_check/
│   │   ├── __init__.py      # __version__
│   │   ├── __main__.py      # Click CLI entry point
│   │   ├── checker.py       # SQL query layer (read-only)
│   │   ├── formatters.py    # Output rendering (table/json/csv)
│   │   └── snapshots.py     # Snapshot save/compare
│   └── pyproject.toml
├── sql/                     # Standalone SQL scripts
├── monitoring/              # Docker Compose + Grafana stack
├── .github/workflows/       # CI/CD workflows
├── CHANGELOG.md
├── CONTRIBUTING.md          # This file
├── LICENSE
├── README.md
└── SECURITY.md
```
