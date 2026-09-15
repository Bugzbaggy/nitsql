#!/usr/bin/env bats
#
# Tests for plugins/sql-valid8/hooks/pre-commit
#
# Run with:  bats plugins/sql-valid8/hooks/tests/test_pre_commit.bats
#
# Covers:
#   - no staged files → exit 0 silently
#   - only non-SQL staged → exit 0
#   - clean SQL staged → exit 0 with "All clean" output
#   - CRITICAL finding staged → exit 1 with "BLOCKED" output
#   - analyzer not discoverable → exit 0 with a skip message
#
# The hook resolves its analyzer relative to its own script directory, so
# when we invoke the real hook from the plugin it finds the real analyzer
# automatically — no setup needed for the happy/critical-path tests.

setup() {
	PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
	HOOK="$PLUGIN_ROOT/hooks/pre-commit"
	ANALYZER="$PLUGIN_ROOT/scripts/analyze_sql.py"

	[ -f "$HOOK" ]      || skip "hook not found at $HOOK"
	[ -f "$ANALYZER" ]  || skip "analyzer not found at $ANALYZER"

	TEST_REPO="$(mktemp -d -t sv8-hook-XXXXXX)"
	cd "$TEST_REPO"
	git init -q
	git config user.email "test@example.com"
	git config user.name  "test"
}

teardown() {
	if [ -n "${TEST_REPO:-}" ] && [ -d "$TEST_REPO" ]; then
		rm -rf "$TEST_REPO"
	fi
	if [ -n "${ISOLATED_DIR:-}" ] && [ -d "$ISOLATED_DIR" ]; then
		rm -rf "$ISOLATED_DIR"
	fi
}

@test "pre-commit exits 0 when nothing is staged" {
	run "$HOOK"
	[ "$status" -eq 0 ]
}

@test "pre-commit exits 0 when only non-SQL files are staged" {
	echo "hello" > note.txt
	git add note.txt
	run "$HOOK"
	[ "$status" -eq 0 ]
}

@test "pre-commit exits 0 and reports clean when staged SQL has no findings" {
	# Explicit column list, no dialect-specific red flags — analyzer should be quiet.
	cat > ok.sql <<'SQL'
SELECT id, name FROM users WHERE id = 1;
SQL
	git add ok.sql
	run "$HOOK"
	[ "$status" -eq 0 ]
	# Either the analyzer found no violations ("All clean") or it reported
	# non-critical suggestions ("WARNING"); both are acceptable for a
	# commit-allowed outcome.
	[[ "$output" == *"All clean"* ]] || [[ "$output" == *"WARNING"* ]]
}

@test "pre-commit blocks the commit on a CRITICAL finding" {
	# Triggers SA-MS013: RESUMABLE = ON inside an explicit transaction — a
	# SQL Server syntax error (error 574) flagged as CRITICAL. The SET
	# XACT_ABORT / GO terminators give the analyzer enough T-SQL signal
	# to auto-detect the MSSQL dialect and apply SA-MS* rules.
	cat > bad.sql <<'SQL'
-- SQL Server / T-SQL migration
SET XACT_ABORT ON;
GO
BEGIN TRANSACTION;
CREATE NONCLUSTERED INDEX [IX_Users_Name] ON [dbo].[Users] ([Name] ASC)
WITH (
    FILLFACTOR = 95,
    ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 5 MINUTES, ABORT_AFTER_WAIT = SELF)),
    RESUMABLE = ON, MAX_DURATION = 60 MINUTES
);
COMMIT TRANSACTION;
GO
SQL
	git add bad.sql
	run "$HOOK"
	[ "$status" -eq 1 ]
	[[ "$output" == *"BLOCKED"* ]]
	[[ "$output" == *"CRITICAL"* ]]
}

@test "pre-commit skips silently when the analyzer is not discoverable" {
	# Copy just the hook script into an isolated dir with no siblings — its
	# discovery loop will fail every candidate path and return early.
	ISOLATED_DIR="$(mktemp -d -t sv8-isolated-XXXXXX)"
	cp "$HOOK" "$ISOLATED_DIR/pre-commit"
	chmod +x "$ISOLATED_DIR/pre-commit"

	echo "SELECT 1;" > any.sql
	git add any.sql

	# Invoke the isolated hook copy — repo root is still $TEST_REPO.
	run "$ISOLATED_DIR/pre-commit"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Analyzer not found"* ]]
}
