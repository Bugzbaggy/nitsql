# Pre-Commit Hook & CI Gate

Local SQL validation before each `git commit`, plus a server-side CI gate that cannot be bypassed. Both auto-detect dialect per file (MSSQL / PostgreSQL / Oracle / MySQL / SQLite) — no configuration needed.

> The pre-commit hook ships since v6.0.0. The CI gate, inline suppression pragmas, and the linked-server false-positive demotions ship in v7.0.0+.

- `hooks/pre-commit` — Bash hook that runs the analyzer on staged `*.sql` files
  - CRITICAL findings → **block commit** (exit 1)
  - HIGH/MEDIUM/LOW   → warn but allow commit
  - No SQL staged / analyzer missing / Python missing → skip silently
- `hooks/install.sh` — One-line install; sets `core.hooksPath` so updates arrive via `git pull`

## Install (two modes)

### Global install

One command per developer, covers every git repo on their machine:

```bash
# Clone the marketplace somewhere stable:
git clone https://github.com/example/claude-marketplace ~/claude-marketplace

# Install globally (sets ~/.gitconfig core.hooksPath):
~/claude-marketplace/plugins/sql-valid8/hooks/install.sh --global
```

No per-repo setup after this — the hook runs on every commit in every repo. It gracefully no-ops on non-SQL commits, so it's safe for all repos.

### Local install

Current repo only:

```bash
plugins/sql-valid8/hooks/install.sh
```

### Uninstall

```bash
plugins/sql-valid8/hooks/install.sh --remove           # local
plugins/sql-valid8/hooks/install.sh --remove --global  # global
```

### Bypass a single commit

```bash
git commit --no-verify
```

## CI gate (v7.0.0+)

The local hook protects only developers who install it and don't pass `--no-verify`. For enforcement that runs on every PR regardless, copy the workflow template into a database repo:

```bash
cp plugins/sql-valid8/ci/sql-valid8.yml <db-repo>/.github/workflows/sql-valid8.yml
```

The workflow:

- Runs on `pull_request` and on `push` to `master` for any changed `*.sql`.
- Analyzes only the **changed** SQL files (`git diff --diff-filter=AMR`).
- Prints a `--fix` report and a severity-count table to the job summary.
- **Fails the job on any CRITICAL finding**; HIGH/MEDIUM/LOW are reported but allow merge.

The analyzer must be present in the repo. Two deployment models (documented in the template header):

1. **Vendored (recommended):** copy `scripts/analyze_sql.py` to `.githooks/analyze_sql.py` in the DB repo and re-copy on each sql-valid8 release. Keep CI and the local hook on the same analyzer version. The template's `ANALYZER` env var already points here.
2. **Marketplace checkout:** add a second `actions/checkout` for `example/claude-marketplace` and set `ANALYZER` to `plugins/sql-valid8/scripts/analyze_sql.py`.

## Suppressing false positives (v7.0.0+)

Both the hook and the CI gate honour inline pragmas read from the raw SQL line comment:

```sql
SELECT * FROM dbo.ReportView;   -- sql-valid8:ignore=SA0001
EXEC (@sql) AT [LEGACY_LINK];   -- sql-valid8:ignore=SA-MS007
-- sql-valid8:ignore-file=SA0008
```

Full syntax, the auto-demotion rules for linked-server passthrough (`OPENQUERY` / `OPENROWSET` / `EXEC ... AT`), and guidance on when *not* to suppress are in `references/suppression-pragmas.md`.

## Coexistence with other hook frameworks

The installer sets `core.hooksPath`, which **replaces** the hook directory for every repo in the chosen scope. If another hook framework (husky, pre-commit, lefthook, Overcommit, …) has already set `core.hooksPath`, `install.sh` will **refuse to overwrite** it and ask you to re-run with `--force`:

```bash
# If an existing hook manager is already configured at the chosen scope:
plugins/sql-valid8/hooks/install.sh --global --force    # overwrite with confirmation
```

If you use such a framework and want to keep its hooks, point the framework's own config at `plugins/sql-valid8/hooks/pre-commit` (e.g., add it to your `.husky/` or `.pre-commit-config.yaml`) rather than running `install.sh`. The hook script itself is self-contained and works invoked from any hook manager.

## Analyzer discovery

The hook searches for `analyze_sql.py` in this order:

1. **Relative to the hook script itself** — `$HOOK_DIR/../scripts/analyze_sql.py` (works for global install from a marketplace clone)
2. `$HOOK_DIR/../analyze_sql.py` (flat vendored layout)
3. `$REPO_ROOT/plugins/sql-valid8/scripts/analyze_sql.py` (marketplace layout when working in the marketplace itself)
4. `$REPO_ROOT/.github/sql-valid8/analyze_sql.py` (per-repo vendored layout)
5. `$REPO_ROOT/sql-valid8/analyze_sql.py` (flat per-repo)

Priority 1 means **global install needs no files in consumer repos** — the hook always finds its own analyzer in the marketplace clone.

## Platform support

Works on Windows (Git Bash), macOS, and Linux. Uses `python`, `python3`, or `py` — whichever is in PATH. Repo has `.gitattributes` to force LF line endings on the hook script, required for bash on Windows.

## Testing

Automated bats tests live in `plugins/sql-valid8/hooks/tests/`. Run with:

```bash
bats plugins/sql-valid8/hooks/tests/
```

Install bats: `brew install bats-core` (macOS), `apt install bats` (Debian/Ubuntu), or see [bats-core](https://github.com/bats-core/bats-core).
