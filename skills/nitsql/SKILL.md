---
name: nitsql
description: Multi-dialect SQL best practices skill for MSSQL, PostgreSQL, Oracle, MySQL, and SQLite. Analyzes queries, stored procedures, indexing, security, and application database code with 52-rule static analyzer. Use when writing, reviewing, optimizing, or migrating SQL across any supported RDBMS.
metadata:
  author: example
  version: "7.0.0"
  domain: database
  triggers: sql, query, database, stored procedure, index, security, performance, mssql, postgresql, postgres, oracle, mysql, sqlite, plsql, tsql, migration, optimization
  role: specialist
  scope: review
  output-format: code
  related-skills: database-optimizer, postgres-pro, security-reviewer, code-reviewer
  allowed-tools: Read, Grep, Glob, Bash
---

# nitsql - Multi-Dialect SQL Best Practices

**Role:** Specialist with deep expertise across MSSQL (SQL Server 2019+), PostgreSQL 13+, Oracle 19c+, MySQL 8.0+, and SQLite. Analyzes queries, stored procedures, indexing strategies, security configurations, connection patterns, and application database code across all five major RDBMS platforms using a 52-rule static analyzer.

**Supported Platforms:**
- **MSSQL:** SQL Server 2019, SQL Server 2022, Azure SQL Database, Azure SQL Managed Instance
- **PostgreSQL:** PostgreSQL 13, 14, 15, 16, Aurora PostgreSQL, Cloud SQL for PostgreSQL
- **Oracle:** Oracle 19c, 21c, 23ai, Oracle Autonomous Database, Oracle Cloud
- **MySQL:** MySQL 8.0, 8.4, MariaDB 10.6+, Aurora MySQL, Cloud SQL for MySQL
- **SQLite:** SQLite 3.35+ (embedded, mobile, local development, testing)

---

## When to Use This Skill

Activate this skill when:
- Writing new SQL queries, stored procedures, functions, or scripts in any dialect
- Reviewing database code for performance, security, or correctness issues
- Optimizing slow queries across any RDBMS
- Auditing security configurations and access controls
- Migrating SQL code between dialects (e.g., MSSQL to PostgreSQL, Oracle to MySQL)
- Configuring database engine settings for performance or reliability
- Implementing connection pooling, retry logic, or async patterns in application code
- Designing schemas, indexes, partitioning, or data models
- Refactoring legacy SQL to use modern dialect features
- Troubleshooting deadlocks, blocking, or resource contention

---

## Dialect Detection

Before applying any rules, detect the target RDBMS dialect. Use these signals in priority order:

### 1. Explicit User Declaration
If the user states the dialect, use it. No further detection needed.

### 2. File Extensions and Naming Conventions

| Signal | Dialect |
|--------|---------|
| `.sql` files with `tsql` or `mssql` in path/name | MSSQL |
| `.sql` files with `pg`, `postgres`, or `pgsql` in path/name | PostgreSQL |
| `.sql` files with `ora` or `plsql` in path/name | Oracle |
| `.sql` files with `mysql` or `mariadb` in path/name | MySQL |
| `.sql` files with `sqlite` or `lite` in path/name | SQLite |
| `.pgsql` extension | PostgreSQL |
| `.plsql`, `.pks`, `.pkb` extensions | Oracle |
| `.sqlite`, `.db`, `.sqlite3` extensions | SQLite |

### 3. Syntax Markers

Key markers per dialect (full list in `references/dialect-detection.md`):

| Dialect | Top Markers |
|---------|------------|
| MSSQL | `SET NOCOUNT ON`, `@@IDENTITY`, `sp_executesql`, `BEGIN TRY`, `NVARCHAR`, `[brackets]` |
| PostgreSQL | `DO $$`, `::cast`, `RETURNING`, `ILIKE`, `LANGUAGE plpgsql`, `SERIAL` |
| Oracle | `DBMS_*`, `SYSDATE`, `VARCHAR2`, `:=`, trailing `/`, `CONNECT BY` |
| MySQL | `DELIMITER //`, `ENGINE=InnoDB`, backticks, `AUTO_INCREMENT`, `GROUP_CONCAT` |
| SQLite | `PRAGMA`, `AUTOINCREMENT`, `INTEGER PRIMARY KEY`, `WITHOUT ROWID`, `STRICT`, `sqlite_master`, `typeof()`, `GLOB` |

### 4. Connection Strings

| Pattern | Dialect |
|---------|---------|
| `Server=...;Database=...;` or `Data Source=...;Initial Catalog=...;` | MSSQL |
| `mssql+pyodbc://`, `jdbc:sqlserver://` | MSSQL |
| `postgresql://`, `postgres://`, `jdbc:postgresql://` | PostgreSQL |
| `host=... dbname=... user=...` (libpq format) | PostgreSQL |
| `oracle://`, `oracle+cx_oracle://`, `jdbc:oracle:thin:@` | Oracle |
| `(DESCRIPTION=(ADDRESS=...)(CONNECT_DATA=...))` (TNS) | Oracle |
| `mysql://`, `mysql+pymysql://`, `jdbc:mysql://` | MySQL |
| `sqlite:///path/to/db`, `file:path?mode=ro`, `:memory:`, `jdbc:sqlite:` | SQLite |

### 5. Framework and Driver Imports

| Import / Package | Dialect |
|-----------------|---------|
| `pyodbc`, `pymssql`, `Microsoft.Data.SqlClient`, `tedious`, `mssql` (Node) | MSSQL |
| `psycopg2`, `psycopg`, `asyncpg`, `Npgsql`, `pg` (Node), `node-postgres` | PostgreSQL |
| `cx_Oracle`, `oracledb`, `Oracle.ManagedDataAccess`, `oracle` (Node) | Oracle |
| `mysql-connector-python`, `pymysql`, `MySqlConnector` (.NET), `mysql2` (Node) | MySQL |
| `sqlite3` (Python built-in), `better-sqlite3` (Node), `Microsoft.Data.Sqlite` (.NET) | SQLite |

### 6. Ambiguous or Unknown Dialect
If dialect cannot be determined, **ask the user**. Do not guess. State: "I detected SQL code but cannot determine the target RDBMS. Which dialect should I use: MSSQL, PostgreSQL, Oracle, MySQL, or SQLite?"

---

## Core Workflow

Follow these steps for every SQL review or generation task:

### Step 1: Detect Dialect
Scan the code context using the signals above. Identify the target RDBMS and version if possible.

**Checkpoint:** Confirm the dialect with the user if there is any ambiguity. State: "Detected dialect: [DIALECT]. Proceeding with [DIALECT]-specific rules." Do not continue until dialect is confirmed or unambiguous.

### Step 2: Analyze Against Dialect-Specific Rules
Load the appropriate dialect reference file (see Reference Guide below). Apply dialect-specific rules to the code. Flag violations with rule IDs, severity, and line references.

### Step 3: Check Universal Issues
Regardless of dialect, check for these cross-dialect problems:
- **SELECT * in production code** -- always expand to explicit column list
- **SQL injection vectors** -- string concatenation in dynamic SQL, unsanitized user input
- **Missing indexes** on columns used in WHERE, JOIN, ORDER BY, GROUP BY
- **No connection pooling** in application code
- **Unbounded queries** -- no LIMIT/TOP/FETCH FIRST/ROWNUM restriction
- **Non-SARGable predicates** -- functions wrapping indexed columns in WHERE clauses
- **Missing error handling** in procedural code
- **Missing transaction management** for multi-statement operations
- **Hardcoded credentials** in connection strings or scripts
- **Missing parameterization** in dynamic SQL

### Step 4: Apply Fixes with Dialect-Correct Syntax
Generate corrected code using the exact syntax for the detected dialect. Never mix syntax from different dialects in the same code block. Include comments explaining why each fix matters.

### Step 5: Validate Fixes
If the multi-dialect analyzer script is available, run it against the corrected code:
```bash
python scripts/analyze_sql.py --dialect [mssql|postgresql|oracle|mysql|sqlite] <file>
```
Confirm zero violations or document accepted exceptions with justification.

---

## Reference Guide

Load the appropriate reference file for detailed, dialect-specific guidance:

| Topic | Reference | Load When |
|-------|-----------|-----------|
| MSSQL / SQL Server | `references/mssql-dialect.md` | T-SQL code, SQL Server configuration, Azure SQL |
| PostgreSQL | `references/postgresql-dialect.md` | PL/pgSQL code, PostgreSQL configuration, Aurora PG |
| Oracle | `references/oracle-dialect.md` | PL/SQL code, Oracle configuration, Oracle Cloud |
| MySQL | `references/mysql-dialect.md` | MySQL/MariaDB code, Aurora MySQL |
| SQLite | `references/sqlite-dialect.md` | SQLite code, PRAGMAs, embedded DB patterns |
| Dialect Comparison | `references/cross-dialect-mapping.md` | Migrating between dialects, portable SQL |
| Connection Patterns | `references/connection-patterns.md` | Application database code, pooling, retry logic |
| Universal Rules | `references/universal-rules.md` | Detailed rule reference with dialect comparison tables |
| Dialect Detection | `references/dialect-detection.md` | Full syntax markers, connection strings, driver imports |
| Dialect Features | `references/dialect-features.md` | Unique capabilities per RDBMS (IQP, AWR, Performance Schema, etc.) |

### Patterns & Security

| Topic | Reference | Load When |
|-------|-----------|-----------|
| Error Handling | `references/error-handling-patterns.md` | TRY/CATCH, EXCEPTION blocks, transaction rollback, retry logic across dialects |
| Security Patterns | `references/security-patterns.md` | SQL injection prevention, least privilege, RLS, encryption, audit logging |
| Advanced Patterns | `references/advanced-patterns.md` | UPSERT, bulk operations, pivot tables, JSON operations, recursive queries |
| Common Pitfalls | `references/common-pitfalls.md` | N+1 queries, implicit type conversion, NULL handling, missing LIMIT, pagination |

### Optimization Guides

| Topic | Reference | Load When |
|-------|-----------|-----------|
| PostgreSQL Tuning | `references/optimization/postgres-optimization-guide.md` | EXPLAIN ANALYZE, index types, autovacuum, PgBouncer, partitioning |
| MySQL Tuning | `references/optimization/mysql-optimization-guide.md` | InnoDB buffer pool, slow query log, Performance Schema, optimizer hints |
| Query Plan Analysis | `references/optimization/query-plan-analysis.md` | Reading EXPLAIN plans across all 5 dialects, anti-patterns, cardinality errors |
| Index Strategy | `references/optimization/index-strategy-checklist.md` | Deciding when/what to index, composite vs covering vs partial indexes |
| Optimization Checklist | `references/optimization/query-optimization-checklist.md` | Step-by-step 6-phase optimization workflow: measure, rewrite, index, schema, config, monitor |

---

## Rule Categories by Priority

| Priority | Category | Impact | Prefix |
|----------|----------|--------|--------|
| 1 | Query Performance | CRITICAL | `query-` |
| 2 | Indexing Strategy | CRITICAL | `index-` |
| 3 | Security & Compliance | HIGH | `security-` |
| 4 | Connection Management | HIGH | `connection-` |
| 5 | Procedural Code Patterns | MEDIUM-HIGH | `proc-` |
| 6 | Static Analysis | MEDIUM-HIGH | `SA****` |
| 7 | Database Configuration | MEDIUM | `config-` |
| 8 | Data Types & Naming | MEDIUM | `type-`, `naming-` |
| 9 | Data Modeling | MEDIUM | `model-` |
| 10 | Monitoring & Diagnostics | LOW-MEDIUM | `monitor-` |

---

## Universal Rules Quick Reference

For the full rule reference with dialect-specific code examples and comparison tables, load: `references/universal-rules.md`

**71 advisory guidance rules across 10 categories** (this is the reference below, distinct from — and partially overlapping with — the **52 rules** the static analyzer in `scripts/analyze_sql.py` enforces automatically; see category 6 for where they overlap):

1. **Query Performance** (12 rules, CRITICAL): SELECT *, parameterization, SARGable predicates, EXISTS vs COUNT, cursors, batching, result limits, implicit conversion, leading wildcards, UNION ALL, NOLOCK (MSSQL), OR anti-pattern
2. **Indexing Strategy** (7 rules, CRITICAL): covering indexes, key order, unused indexes, missing indexes, CONCURRENTLY (PG), partial/filtered indexes, statistics maintenance
3. **Security & Compliance** (9 rules, HIGH): parameterized dynamic SQL, least privilege, no admin accounts, encrypted connections, RLS, encryption at rest, search_path (PG), bind variables (Oracle), audit logging
4. **Connection Management** (6 rules, HIGH): pooling, retry logic, close/dispose, async, timeouts, read replicas
5. **Procedural Code** (5 rules, MEDIUM-HIGH): error handling, transaction handling, set-based over row-by-row, avoid dynamic SQL, schema qualification
6. **Static Analysis** (13 rules, MEDIUM-HIGH / CRITICAL): SA0001, SA0004-SA0012, SA0014-SA0016 — the cross-dialect subset of the analyzer's rule IDs that `references/universal-rules.md` documents for guidance (13 of the analyzer's 52 implemented rules; the other 39, including MSSQL-only `SA-MS011`-`SA-MS013`, are not repeated in this reference — see `references/mssql-dialect.md` → *Index Options — Valid Syntax by Statement Type* for those).
7. **Configuration** (5 rules, MEDIUM): query analysis tools, memory, parallelism, auto-maintenance, logging/recovery
8. **Data Types & Naming** (5 rules, MEDIUM): appropriate types, deprecated types, utf8mb4 (MySQL), strict mode, naming conventions
9. **Data Modeling** (4 rules, MEDIUM): constraints, temporal tables, partitioning, JSON storage
10. **Monitoring** (5 rules, LOW-MEDIUM): execution plans, wait stats, slow queries, deadlocks, index health

See `references/universal-rules.md` for incorrect/correct code examples per dialect.

## Dialect-Specific Features

Load `references/dialect-features.md` for full details. Key highlights per dialect:

| Dialect | Standout Features |
|---------|------------------|
| **MSSQL** | Query Store, IQP (compat 150+/160+), ADR, Ledger Tables, OPTIMIZE_FOR_SEQUENTIAL_KEY, resumable index ops |
| **PostgreSQL** | EXPLAIN ANALYZE, pg_stat_statements, partial indexes, JSONB + GIN, LISTEN/NOTIFY, declarative partitioning |
| **Oracle** | AWR/ASH/ADDM, SQL Plan Baselines, BULK COLLECT + FORALL, materialized views, RAC, JSON duality views (23ai) |
| **MySQL** | Performance Schema, InnoDB clustered indexes, window functions (8.0+), invisible indexes, instant ADD COLUMN, histograms |

---

## Constraints

### MUST DO
- Always detect and confirm the target dialect before applying any rules
- Use dialect-correct syntax in all code examples -- verified against the target RDBMS version
- Parameterize ALL dynamic SQL with no exceptions in any dialect
- Test fixes against the target RDBMS version -- do not assume cross-dialect compatibility
- Load the dialect-specific reference file when giving detailed guidance
- Include error handling in all procedural code examples
- Qualify all object references with schema/database name
- Note when a feature requires a specific edition (e.g., Oracle Enterprise, SQL Server Enterprise)
- Provide migration-safe alternatives when a feature is not available in the target dialect

### MUST NOT DO
- Apply MSSQL-specific syntax (e.g., `SET NOCOUNT ON`, `TOP`, `@@IDENTITY`) to PostgreSQL, Oracle, or MySQL
- Apply PostgreSQL-specific syntax (e.g., `::` cast, `RETURNING`, `ILIKE`) to MSSQL, Oracle, or MySQL
- Apply Oracle-specific syntax (e.g., `CONNECT BY`, `ROWNUM`, `NVL()`) to MSSQL, PostgreSQL, or MySQL
- Apply MySQL-specific syntax (e.g., backtick quoting, `LIMIT x,n`, `ON DUPLICATE KEY`) to MSSQL, PostgreSQL, or Oracle
- Mix dialect syntax in the same code example
- Assume a feature exists across all dialects without verifying in the cross-dialect mapping
- Recommend deprecated features for any dialect (e.g., `TEXT` in MSSQL, `LONG` in Oracle, `SERIAL` as preferred in PostgreSQL)
- Use vendor-specific functions without noting portability impact
- Provide performance advice without specifying which dialect it applies to
- Ignore transaction isolation level differences between dialects

---

## Scripts

- `scripts/analyze_sql.py` -- Multi-dialect CLI analyzer (52 checks across 5 dialects). Use `--dialect`, `--json`, `--severity`, `--all`, `--fix`.
- `scripts/sql_helper.py` -- Multi-dialect DB utility (schema introspection, query building, index analysis, health checks)
- `scripts/analyze-slow-queries.sql` -- Slow query diagnostics (MSSQL, PostgreSQL, Oracle, MySQL)
- `scripts/index-recommendations.sql` -- Missing/unused/duplicate index detection (MSSQL, PostgreSQL, Oracle, MySQL)
- `scripts/check-indexes-{mssql,postgresql,oracle,mysql}.sql` -- Index health per dialect
- `scripts/security-audit-{mssql,postgresql,oracle,mysql}.sql` -- Security audit per dialect

## Pre-Commit Hook (v6.0.0+)

Local SQL validation before each `git commit`. Auto-detects dialect per file (MSSQL / PostgreSQL / Oracle / MySQL / SQLite) — no configuration needed.

- CRITICAL findings → **block commit** (exit 1)
- HIGH/MEDIUM/LOW → warn but allow commit
- No SQL staged / analyzer missing / Python missing → skip silently

**Global install** (one-time per developer, covers all repos):

```bash
git clone https://github.com/example/claude-marketplace ~/claude-marketplace
~/claude-marketplace/plugins/nitsql/hooks/install.sh --global
```

**Local install** (current repo only): `plugins/nitsql/hooks/install.sh`

**Bypass a commit:** `git commit --no-verify`

Full install/uninstall options, coexistence notes for husky/pre-commit/lefthook/Overcommit, analyzer-discovery search order, platform support, and bats test instructions are in `references/pre-commit-hook.md`.

## CI Gate (v7.0.0+)

The local hook can be skipped (`--no-verify`) or never installed. For an enforcement that runs server-side on every PR, copy `ci/nitsql.yml` to a database repo's `.github/workflows/`. It analyzes the `*.sql` files changed in the PR, posts a severity summary, and fails the job on any CRITICAL finding. Auto-detects dialect, so one workflow covers all five platforms. See `references/pre-commit-hook.md` → *CI gate*.

## Suppressing False Positives (v7.0.0+)

Silence an accepted finding inline — works in all dialects, no config file:

```sql
SELECT * FROM dbo.ReportView;     -- nitsql:ignore=SA0001
-- nitsql:ignore-file=SA0008  (whole-file, put near the top)
```

`-- nitsql:ignore` (all rules on the line), `-- nitsql:ignore=SA0002,SA0008` (specific rules), and `-- nitsql:ignore-file[=IDs]` (whole file) are honoured by both the local hook and the CI gate. Some findings auto-demote when the canonical fix is unavailable (e.g. `SA0002` → HIGH and `SA-MS007` → MEDIUM for `EXEC(@sql) AT linked_server`, `OPENQUERY`, `OPENROWSET`). Full reference: `references/suppression-pragmas.md`.

## Full Compiled Document

`references/agents-guide.md` -- Complete 1900-line agent guide with all rules expanded across all dialects.

---

## External References

- **MSSQL:** [SQL Assessment API](https://learn.microsoft.com/en-us/sql/tools/sql-assessment-api/sql-assessment-api-overview) | [IQP](https://learn.microsoft.com/en-us/sql/relational-databases/performance/intelligent-query-processing) | [Query Store](https://learn.microsoft.com/en-us/sql/relational-databases/performance/best-practice-with-the-query-store)
- **PostgreSQL:** [Docs](https://www.postgresql.org/docs/current/) | [pg_stat_statements](https://www.postgresql.org/docs/current/pgstatstatements.html) | [Performance Wiki](https://wiki.postgresql.org/wiki/Performance_Optimization)
- **Oracle:** [Docs](https://docs.oracle.com/en/database/) | [SQL Tuning Guide](https://docs.oracle.com/en/database/oracle/oracle-database/19/tgsql/) | [PL/SQL](https://docs.oracle.com/en/database/oracle/oracle-database/19/lnpls/)
- **MySQL:** [Reference Manual](https://dev.mysql.com/doc/refman/8.0/en/) | [Performance Schema](https://dev.mysql.com/doc/refman/8.0/en/performance-schema.html) | [InnoDB](https://dev.mysql.com/doc/refman/8.0/en/innodb-storage-engine.html)
- **SQLite:** [Docs](https://www.sqlite.org/docs.html) | [PRAGMA Reference](https://www.sqlite.org/pragma.html) | [Query Planning](https://www.sqlite.org/queryplanner.html) | [WAL Mode](https://www.sqlite.org/wal.html)
