# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.1.x   | ✅ Yes    |

Older versions will receive security fixes only while they are the **latest**
release. Once a new minor version is published the previous one is no longer
supported.

---

## Reporting a Vulnerability

**Please do NOT open a public GitHub Issue for security vulnerabilities.**

Instead, report them through **GitHub's private vulnerability reporting**:

1. Navigate to the [Security tab](https://github.com/http418imateapot/pg-index-health/security) of this repository.
2. Click **"Report a vulnerability"**.
3. Fill in the details (description, reproduction steps, impact assessment, and
   any suggested fix if you have one).

You can also e-mail the maintainer directly if you are unable to use the GitHub
UI. Check the repository owner's GitHub profile for contact information.

---

## Response Timeline

| Stage | Target |
|-------|--------|
| Acknowledgement | Within **3 business days** |
| Initial assessment | Within **7 business days** |
| Fix / patch released | Within **30 days** for critical / high severity |
| Public disclosure | After a fix is released, or after 90 days (coordinated) |

---

## Scope

This tool is **read-only** against the monitored PostgreSQL database (only
`SELECT` on system catalogs and `pg_monitor` role are required). Security
issues relevant to this project include:

- **DSN / credential leakage** in CLI output, snapshot files, or log messages.
- **SQL injection** in any query parameter passed to `checker.py`.
- **Path traversal** in snapshot file names (`--id` parameter).
- **Dependency vulnerabilities** in `psycopg2-binary`, `click`, or `tabulate`.
- **Insecure defaults** in the Docker Compose monitoring stack.

Issues that are **out of scope**:
- Vulnerabilities in the PostgreSQL server itself.
- Security of the target database infrastructure (misconfigurations, etc.).
- Theoretical attacks that require direct filesystem or database access already
  equivalent to full system compromise.

---

## Security Best Practices for Users

- Store the database DSN in environment variables (`PG_DSN`), **never** on the
  command line where it appears in process listings.
- Use a dedicated, least-privilege `monitoring_role` (see `README.md`).
- For the Docker Compose stack, change the default Grafana `admin/admin`
  credentials immediately and never expose port 3000 to the public internet.
- Snapshot files under `~/.pg-index-check/snapshots/` may contain table and
  index names. Protect them with appropriate filesystem permissions (`chmod 700
  ~/.pg-index-check`).
