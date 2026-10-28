# Pre-Commit Hook & CI Gate

Local SQL validation before each `git commit`, plus a server-side CI gate that cannot be bypassed. Both auto-detect dialect per file (MSSQL / PostgreSQL / Oracle / MySQL / SQLite) — no configuration needed.

> The pre-commit hook ships since v6.0.0. The CI gate, inline suppression pragmas, and the linked-server false-positive demotions ship in v7.0.0+.

- `hooks/pre-commit` — Bash hook that runs the analyzer on staged `*.sql` files
  - CRITICAL findings → **block commit** (exit 1)
  - HIGH/MEDIUM/LOW   → warn but allow commit
  - No SQL staged → skip silently; analyzer or Python missing → print a one-line notice and skip
- `hooks/install.sh` — One-line install; sets `core.hooksPath` so updates arrive via `git pull`

## Install (two modes)

### Global install

One command per developer, covers every git repo on their machine:

```bash
# Clone nitsql somewhere stable:
git clone https://github.com/Bugzbaggy/nitsql.git ~/nitsql

# Install globally (sets ~/.gitconfig core.hooksPath):
~/nitsql/hooks/install.sh --global
```

No per-repo setup after this — the hook runs on every commit in every repo. It gracefully no-ops on non-SQL commits, so it's safe for all repos.

### Local install

For a single repo, run the installer that lives inside that repo (for example this repo, or a database repo you have vendored the hook into):

```bash
./hooks/install.sh
```

A local install writes `core.hooksPath` relative to the repo that holds `install.sh`, so running an installer from a different clone does not work for the current repo; use `--global` for that case.

### Uninstall

```bash
./hooks/install.sh --remove           # local
./hooks/install.sh --remove --global  # global
```

### Bypass a single commit

```bash
git commit --no-verify
```

## CI gate (v7.0.0+)

The local hook protects only developers who install it and don't pass `--no-verify`. For enforcement that runs on every PR regardless, copy the workflow template into a database repo:

```bash
cp ci/nitsql.yml <db-repo>/.github/workflows/nitsql.yml
```

The workflow:

- Runs on `pull_request` and on `push` to `master` for any changed `*.sql`, and on manual `workflow_dispatch`.
- Analyzes only the **changed** SQL files (`git diff --diff-filter=AMR`).
- Prints a `--fix` report to the job log and writes a severity-count table to the job summary.
- **Fails the job on any CRITICAL finding**; HIGH/MEDIUM/LOW are reported but allow merge.

The analyzer must be present in the repo. Two deployment models (documented in the template header):

1. **Vendored (recommended):** copy `scripts/analyze_sql.py` to `.githooks/analyze_sql.py` in the DB repo and re-copy on each nitsql release. Keep CI and the local hook on the same analyzer version. The template's `ANALYZER` env var already points here.
2. **Marketplace checkout:** add a second `actions/checkout` of `Bugzbaggy/nitsql` (for example with `path: nitsql`) and set `ANALYZER` to `nitsql/scripts/analyze_sql.py`.

## Suppressing false positives (v7.0.0+)

Both the hook and the CI gate honour inline pragmas read from the raw SQL line comment:

```sql
SELECT * FROM dbo.ReportView;   -- nitsql:ignore=SA0001
EXEC (@sql) AT [LEGACY_LINK];   -- nitsql:ignore=SA-MS007
-- nitsql:ignore-file=SA0008
```

Full syntax, the auto-demotion rules for linked-server passthrough (`OPENQUERY` / `OPENROWSET` / `EXEC ... AT`), and guidance on when *not* to suppress are in `references/suppression-pragmas.md`.

## Coexistence with other hook frameworks

The installer sets `core.hooksPath`, which **replaces** the hook directory for every repo in the chosen scope. If another hook framework (husky, pre-commit, lefthook, Overcommit, …) has already set `core.hooksPath`, `install.sh` will **refuse to overwrite** it and ask you to re-run with `--force`:

```bash
# If an existing hook manager is already configured at the chosen scope:
./hooks/install.sh --global --force    # replace the existing core.hooksPath (no prompt)
```

If you use such a framework and want to keep its hooks, point the framework's own config at `hooks/pre-commit` in your nitsql clone (e.g., add it to your `.husky/` or `.pre-commit-config.yaml`) rather than running `install.sh`. The hook script itself is self-contained and works invoked from any hook manager.

## Analyzer discovery

The hook searches for `analyze_sql.py` in this order:

1. **Relative to the hook script itself** — `$HOOK_DIR/../scripts/analyze_sql.py` (works for a global install from a clone of this repo)
2. `$HOOK_DIR/../analyze_sql.py` (flat vendored layout)
3. `$REPO_ROOT/plugins/nitsql/scripts/analyze_sql.py` (marketplace layout when working in the marketplace itself)
4. `$REPO_ROOT/.github/nitsql/analyze_sql.py` (per-repo vendored layout)
5. `$REPO_ROOT/nitsql/analyze_sql.py` (flat per-repo)

Priority 1 means **global install needs no files in consumer repos** — the hook always finds its own analyzer in the nitsql clone.

## Platform support

Works on Windows (Git Bash), macOS, and Linux. Uses `python`, `python3`, or `py` — whichever is in PATH. Repo has `.gitattributes` to force LF line endings on the hook script, required for bash on Windows.

## Testing

Automated bats tests live in `hooks/tests/`. Run with:

```bash
bats hooks/tests/
```

Install bats: `brew install bats-core` (macOS), `apt install bats` (Debian/Ubuntu), or see [bats-core](https://github.com/bats-core/bats-core).
