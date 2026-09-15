# sql-valid8

A multi-dialect SQL static analyzer: **52 rules** across SQL Server,
PostgreSQL, Oracle, MySQL, and SQLite, with a CLI for CI, a pre-commit hook,
and a [Claude Code](https://claude.com/claude-code) skill.

Finds SQL injection, missing indexes, non-SARGable predicates, connection
leaks, and error-handling gaps — in `.sql` files *and* in SQL embedded in
Python, Node.js, and C#.

[![Python 3.9+](https://img.shields.io/badge/Python-3.9%2B-3776AB)](https://www.python.org/)
[![Dialects](https://img.shields.io/badge/dialects-5-blue)](#dialects)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Quick start

```bash
git clone https://github.com/Bugzbaggy/sql-valid8.git
cd sql-valid8
python scripts/analyze_sql.py path/to/your/sql/
```

The dialect is auto-detected from syntax; override it when you need to:

```bash
python scripts/analyze_sql.py --dialect postgresql migrations/
python scripts/analyze_sql.py --severity critical --json .   # CI-friendly
python scripts/analyze_sql.py --fix procedures/              # show fixes
```

Example output:

```
File: procedures/search.sql
Detected Dialect: MSSQL

CRITICAL:
  Line 54: [SA0002] SQL injection risk -- String concatenation with variable in dynamic SQL
    | SET @SQL = N'SELECT * FROM Products WHERE ProductName LIKE ''%' + @SearchTerm + ...
    -> Use parameterised queries (sp_executesql, $1, :bind, ?)
```

## Dialects

| Dialect | Minimum version |
|---|---|
| SQL Server | 2019+ |
| PostgreSQL | 13+ |
| Oracle | 19c+ |
| MySQL | 8.0+ |
| SQLite | 3.x |

## What it checks

- **Injection** — string concatenation into dynamic SQL, unparameterised input
- **Performance** — non-SARGable predicates, `SELECT *`, implicit conversions, missing indexes, row-by-row patterns
- **Correctness** — missing error handling, unbounded transactions, `NOLOCK` misuse
- **Application code** — connection pooling and leak patterns in Python, Node.js, and C#

## Use it in CI

A GitHub Actions template ships in [`ci/sql-valid8.yml`](ci/sql-valid8.yml):

```yaml
- name: SQL Valid8
  run: python scripts/analyze_sql.py --severity critical --json sql/
```

Fail the build only on CRITICAL, and let the rest report.

## Use it as a pre-commit hook

```bash
./hooks/install.sh
```

Blocks a commit when staged SQL has CRITICAL findings, auto-detecting dialect
per file. Hook tests are [bats](https://github.com/bats-core/bats-core):

```bash
bats hooks/tests/
```

## Suppressions

When a finding is knowingly accepted — legacy passthrough code, a reviewed
exception — suppress it inline rather than lowering the rule globally:

```sql
-- sql-valid8:ignore SA0002 -- reviewed 2026-03: parameterised upstream
SET @SQL = @SQL + @Filter;
```

See [`skills/sql-valid8/references/suppression-pragmas.md`](skills/sql-valid8/references/suppression-pragmas.md).

## Use it as a Claude Code skill

```bash
/plugin install sql-valid8@Bugzbaggy
```

The skill in [`skills/sql-valid8/`](skills/sql-valid8/) carries the rule
reference, dialect-specific optimization notes, connection patterns, and
least-privilege security guidance.

## Companion scripts

`scripts/` also ships per-dialect operational SQL you can run directly:

| Script | Purpose |
|---|---|
| `security-audit-*.sql` | Permission and configuration audit |
| `check-indexes-*.sql` | Unused, duplicate, and missing indexes |
| `index-recommendations.sql` | Index candidates from live workload |
| `analyze-slow-queries.sql` | Slow query diagnostics |

## Test fixtures

`test-app/` holds deliberately bad SQL — the analyzer's own regression corpus:

```bash
python scripts/analyze_sql.py test-app/sql/
```

## Contributing

New rules are welcome. A rule needs an ID, a dialect scope, a fixture in
`test-app/`, and a suggested fix. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
