# Suppression Pragmas (v7.0.0+)

Inline escape hatches for the sql-valid8 analyzer. They let you silence a
finding that is a false positive or an accepted risk **at the exact line**,
so the rest of the file stays gated. No config file, no CLI flags — the
pragma lives in a SQL line comment and travels with the code in review.

Pragmas are read from the **raw** source line (before comment stripping), so
they work in every dialect that supports `--` line comments: MSSQL,
PostgreSQL, Oracle, MySQL, SQLite.

## Syntax

| Pragma | Scope | Effect |
| ------ | ----- | ------ |
| `-- sql-valid8:ignore` | the line it is on | suppress **all** rules on that line |
| `-- sql-valid8:ignore=SA0002` | the line it is on | suppress rule `SA0002` on that line |
| `-- sql-valid8:ignore=SA0002,SA0008` | the line it is on | suppress several rules (comma-separated) |
| `-- sql-valid8:ignore-file` | whole file | suppress **all** rules in the file |
| `-- sql-valid8:ignore-file=SA0008` | whole file | suppress rule `SA0008` everywhere in the file |

- Rule IDs are the ones shown in analyzer output (`SA0001`…`SA0019`, plus
  dialect rules like `SA-MS007`, `SA-LITE003`). Unknown IDs are simply never
  matched — a typo silently fails open (the finding still fires), so verify
  the ID against the reported finding.
- Matching is case-insensitive on the pragma keyword; rule IDs are matched
  verbatim.
- A line-level pragma only affects findings whose reported line number is the
  pragma's own line. Put it on the offending statement, not a neighbouring one.

## Examples

```sql
-- Accepted: reporting view genuinely needs every column.
SELECT * FROM dbo.DailyMetrics;            -- sql-valid8:ignore=SA0001

-- Legacy passthrough we cannot parameterise; reviewed and allow-listed.
EXEC (@sql) AT [LEGACY_LINK];              -- sql-valid8:ignore=SA-MS007

-- Generated migration file — exempt the whole file from one noisy rule.
-- sql-valid8:ignore-file=SA0008
SELECT col FROM staging_table;
```

MySQL note: MySQL only treats `--` as a comment when followed by whitespace.
Always write `-- sql-valid8:ignore` (with the space), never `--sql-valid8:...`.

## When NOT to suppress

Suppression is for false positives and consciously accepted risk — not for
silencing CRITICAL security findings to get a commit through. The CI gate
(`ci/sql-valid8.yml`) honours the same pragmas, so a suppressed CRITICAL
will pass CI too. Prefer fixing; if you suppress a CRITICAL, leave a reason
in the same comment and get it reviewed.

## Related dialect-specific demotions (automatic, no pragma needed)

Some findings are demoted automatically because the canonical fix is not
available — you do **not** need a pragma for these:

- **`SA0002` (SQL injection) → HIGH** when the offending **statement** is a
  linked-server passthrough (`EXEC (@sql) AT [server]`, `OPENQUERY(...)`,
  `OPENROWSET(...)`). T-SQL has no `sp_executesql` variant that crosses a
  linked-server boundary, so "use a parameterised query" is not actionable for
  that statement. Detection is **statement-scoped**: the passthrough token can
  sit a line or two from the concatenation that trips the rule (multi-line
  dynamic-SQL builds), but the search stops at a `;` statement terminator and
  is capped at ±2 lines — so an ordinary, fixable injection in a *different*
  statement stays CRITICAL (and the CI gate, which fails only on CRITICAL,
  still catches it).
- **`SA-MS007` (`EXEC(@sql)`) → MEDIUM** for the `EXEC(@sql) AT linked_server`
  form, with guidance to validate/allow-list inputs at the boundary.

These keep legacy passthrough code (e.g. the cloud data warehouse via the third-party linked
server) from hard-blocking CI while still surfacing the risk. Use
`-- sql-valid8:ignore=SA-MS007` to silence entirely once reviewed.
