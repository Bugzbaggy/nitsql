# nitsql

A multi-dialect SQL static analyzer: **52 rules** across SQL Server,
PostgreSQL, Oracle, MySQL, and SQLite, with a CLI for CI, a pre-commit hook,
and a [Claude Code](https://claude.com/claude-code) skill.

The CLI analyzer finds SQL injection, non-SARGable predicates, unsafe
`UPDATE`/`DELETE`, and error-handling gaps in `.sql` files. The Claude Code
skill takes the same review further: missing indexes, connection leaks, and
SQL embedded in Python, Node.js, and C#.

[![Python 3.9+](https://img.shields.io/badge/Python-3.9%2B-3776AB)](https://www.python.org/)
[![Dialects](https://img.shields.io/badge/dialects-5-blue)](#dialects)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Quick start

```bash
git clone https://github.com/Bugzbaggy/nitsql.git
cd nitsql
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

The analyzer's 52 rules (`SA0001`–`SA0019` for every dialect, plus
`SA-MS`, `SA-PG`, `SA-ORA`, `SA-MY`, and `SA-LITE` dialect rules) cover:

- **Injection** — string concatenation into dynamic SQL, unparameterised input
- **Performance** — non-SARGable predicates, `SELECT *`, implicit conversions, cursors and other row-by-row patterns
- **Correctness** — `UPDATE`/`DELETE` without `WHERE`, missing error handling, transactions without `XACT_ABORT` or `TRY`/`CATCH`, `NOLOCK` misuse

The skill adds review guidance the analyzer does not automate:

- **Indexing** — missing, unused, and covering indexes
- **Application code** — connection pooling and leak patterns in Python, Node.js, and C#

## Use it in CI

A GitHub Actions template ships in [`ci/nitsql.yml`](ci/nitsql.yml). Copy it
to `.github/workflows/` in your database repo and vendor
`scripts/analyze_sql.py` as `.githooks/analyze_sql.py` (the template's default
`ANALYZER` path). It analyzes the `*.sql` files changed by the pull request or
push. The core step is:

```yaml
- name: nitsql
  run: python .githooks/analyze_sql.py --json sql/
```

The analyzer exits 1 only when it finds a CRITICAL issue, so the build fails on
CRITICAL while HIGH, MEDIUM, and LOW findings still report. Adding
`--severity critical` would hide the lower severities from the output.

## Use it as a pre-commit hook

```bash
./hooks/install.sh --global   # every repo on this machine
./hooks/install.sh            # this clone only
```

Blocks a commit when staged SQL has CRITICAL findings, auto-detecting dialect
per file. Install options are in
[`skills/nitsql/references/pre-commit-hook.md`](skills/nitsql/references/pre-commit-hook.md).
Hook tests are [bats](https://github.com/bats-core/bats-core):

```bash
bats hooks/tests/
```

## Suppressions

When a finding is knowingly accepted — legacy passthrough code, a reviewed
exception — suppress it inline rather than lowering the rule globally:

```sql
-- Reviewed 2026-03: @Region is checked against an allow-list upstream.
SET @SQL = @SQL + N' AND Region = ''' + @Region + '''';  -- nitsql:ignore=SA0002
```

The pragma goes on the line that raises the finding, with `=` before the rule
IDs; keep the reason on the line above.

See [`skills/nitsql/references/suppression-pragmas.md`](skills/nitsql/references/suppression-pragmas.md).

## Use it as a Claude Code skill

Clone the repository and copy the skill into your Claude Code skills folder:

```bash
git clone https://github.com/Bugzbaggy/nitsql.git ~/nitsql
mkdir -p ~/.claude/skills
cp -r ~/nitsql/skills/nitsql ~/.claude/skills/
```

The skill's commands call `scripts/analyze_sql.py`, which stays in the clone
(`~/nitsql/scripts/`); copy it into a project if you want it there, as the CI
template does with `.githooks/analyze_sql.py`.

The skill in [`skills/nitsql/`](skills/nitsql/) carries the rule
reference, dialect-specific optimization notes, connection patterns, and
least-privilege security guidance.

## Companion scripts

`scripts/` also ships operational SQL for SQL Server, PostgreSQL, Oracle, and
MySQL (not SQLite) that you can run directly:

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
