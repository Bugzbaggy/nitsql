#!/usr/bin/env python3
"""
test_analyzer.py - pytest unit tests for nitsql static analyzer

Covers:
  - Dialect detection (all 5 dialects + edge cases)
  - Universal rules SA0001-SA0019
  - Dialect-specific rules (MSSQL, PostgreSQL, Oracle, MySQL, SQLite)
  - False-positive fixes (SA0002, SA0014, SA0015)
  - --fix suggestion generation
  - JSON output structure

Usage:
    pytest test_analyzer.py -v
    pytest test_analyzer.py -v -k "test_sa0001"     # single rule
    pytest test_analyzer.py -v -k "dialect"          # dialect tests
"""

import sys
import tempfile
import textwrap
from pathlib import Path

import pytest

# Add analyzer to path
SCRIPTS_DIR = Path(__file__).parent.parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

from analyze_sql import (
    Dialect,
    DialectDetector,
    Severity,
    SQLAnalyzer,
    Violation,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _analyze(sql: str, dialect: str | None = None, filepath: str = "test.sql") -> list[Violation]:
    """Run analyzer on an in-memory SQL string and return violations."""
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".sql", prefix=filepath.replace(".sql", "_"), delete=False, encoding="utf-8"
    ) as f:
        f.write(textwrap.dedent(sql))
        f.flush()
        p = Path(f.name)

    try:
        analyzer = SQLAnalyzer(
            dialect=Dialect(dialect) if dialect else None
        )
        _, violations = analyzer.analyze_file(p)
    finally:
        p.unlink(missing_ok=True)
    return violations


def _has_rule(violations: list[Violation], rule_id: str) -> bool:
    return any(v.rule_id == rule_id for v in violations)


def _count_rule(violations: list[Violation], rule_id: str) -> int:
    return sum(1 for v in violations if v.rule_id == rule_id)


# ===================================================================
# DIALECT DETECTION
# ===================================================================

class TestDialectDetection:
    """Test dialect auto-detection from content and filenames."""

    def test_mssql_from_content(self):
        sql = "SET NOCOUNT ON;\nSELECT @@IDENTITY FROM [dbo].[Users];"
        assert DialectDetector.detect(sql) == Dialect.MSSQL

    def test_postgresql_from_content(self):
        sql = "DO $$ BEGIN RAISE NOTICE 'hello'; END $$;\nSELECT id::int FROM users;"
        assert DialectDetector.detect(sql) == Dialect.POSTGRESQL

    def test_oracle_from_content(self):
        sql = "SELECT SYSDATE FROM dual;\nDBMS_OUTPUT.PUT_LINE('test');"
        assert DialectDetector.detect(sql) == Dialect.ORACLE

    def test_mysql_from_content(self):
        sql = "DELIMITER //\nSELECT * FROM `users` WHERE id = AUTO_INCREMENT;"
        assert DialectDetector.detect(sql) == Dialect.MYSQL

    def test_sqlite_from_content(self):
        sql = "PRAGMA journal_mode=WAL;\nPRAGMA foreign_keys=ON;\nSELECT * FROM sqlite_master;"
        assert DialectDetector.detect(sql) == Dialect.SQLITE

    def test_mssql_from_filename(self):
        sql = "SELECT id, name FROM users;"
        assert DialectDetector.detect(sql, "queries_mssql.sql") == Dialect.MSSQL

    def test_postgresql_from_filename(self):
        sql = "SELECT id, name FROM users;"
        assert DialectDetector.detect(sql, "queries_postgresql.sql") == Dialect.POSTGRESQL

    def test_oracle_from_filename(self):
        sql = "SELECT id, name FROM users;"
        assert DialectDetector.detect(sql, "queries_oracle.sql") == Dialect.ORACLE

    def test_mysql_from_filename(self):
        sql = "SELECT id, name FROM users;"
        assert DialectDetector.detect(sql, "queries_mysql.sql") == Dialect.MYSQL

    def test_sqlite_from_filename(self):
        sql = "SELECT id, name FROM users;"
        assert DialectDetector.detect(sql, "app_sqlite.sql") == Dialect.SQLITE

    def test_sqlite_from_db_extension(self):
        sql = "SELECT id, name FROM users;"
        assert DialectDetector.detect(sql, "mydata.db") == Dialect.SQLITE

    def test_unknown_dialect(self):
        sql = "SELECT 1;"
        assert DialectDetector.detect(sql) == Dialect.UNKNOWN

    def test_content_overrides_ambiguous_filename(self):
        sql = "SET NOCOUNT ON;\nBEGIN TRY\nSELECT @@IDENTITY\nEND TRY\nBEGIN CATCH\nEND CATCH"
        # Strong MSSQL content should detect as MSSQL regardless of generic filename
        assert DialectDetector.detect(sql, "queries.sql") == Dialect.MSSQL


# ===================================================================
# UNIVERSAL RULES SA0001-SA0014
# ===================================================================

class TestSA0001SelectStar:
    def test_fires_on_select_star(self):
        v = _analyze("SELECT * FROM users WHERE id = 1;")
        assert _has_rule(v, "SA0001")

    def test_allows_exists_subquery(self):
        """SELECT * inside EXISTS subquery is acceptable (only checks existence, not columns)."""
        v = _analyze("SELECT 1 FROM orders WHERE EXISTS (SELECT * FROM users);")
        # The analyzer correctly ignores SELECT * inside EXISTS subqueries
        assert not _has_rule(v, "SA0001")

    def test_no_fire_on_explicit_columns(self):
        v = _analyze("SELECT id, name, email FROM users WHERE id = 1;")
        assert not _has_rule(v, "SA0001")


class TestSA0002SQLInjection:
    def test_fires_on_exec_variable(self):
        v = _analyze("EXEC(@sql_string);", dialect="mssql")
        assert _has_rule(v, "SA0002")

    def test_fires_on_execute_immediate_concat(self):
        v = _analyze(
            "EXECUTE IMMEDIATE 'SELECT * FROM ' || table_name;",
            dialect="oracle",
        )
        assert _has_rule(v, "SA0002")

    def test_no_fire_on_dbms_output(self):
        """False-positive fix: DBMS_OUTPUT.PUT_LINE with || should NOT fire."""
        v = _analyze(
            "DBMS_OUTPUT.PUT_LINE('Count: ' || v_count || ' rows');",
            dialect="oracle",
        )
        assert not _has_rule(v, "SA0002")

    def test_no_fire_on_raise_application_error(self):
        """False-positive fix: RAISE_APPLICATION_ERROR with || should NOT fire."""
        v = _analyze(
            "RAISE_APPLICATION_ERROR(-20001, 'Error: ' || v_msg || ' failed');",
            dialect="oracle",
        )
        assert not _has_rule(v, "SA0002")

    def test_no_fire_on_raise_notice(self):
        """False-positive fix: RAISE NOTICE with || should NOT fire."""
        v = _analyze(
            "RAISE NOTICE 'Processing % rows', || v_count || ' done';",
            dialect="postgresql",
        )
        assert not _has_rule(v, "SA0002")


class TestSA0003NonSargable:
    def test_fires_on_function_in_where(self):
        v = _analyze("SELECT id FROM users WHERE UPPER(email) = 'TEST@EXAMPLE.COM';")
        assert _has_rule(v, "SA0003")

    def test_no_fire_on_clean_where(self):
        v = _analyze("SELECT id FROM users WHERE email = 'test@example.com';")
        assert not _has_rule(v, "SA0003")


class TestSA0004LeadingWildcard:
    def test_fires_on_leading_percent(self):
        v = _analyze("SELECT * FROM users WHERE name LIKE '%smith';")
        assert _has_rule(v, "SA0004")

    def test_no_fire_on_trailing_wildcard(self):
        v = _analyze("SELECT id FROM users WHERE name LIKE 'smith%';")
        assert not _has_rule(v, "SA0004")


class TestSA0005CountVsExists:
    def test_fires_on_count_for_existence(self):
        v = _analyze("SELECT id FROM users WHERE (SELECT COUNT(*) FROM orders WHERE user_id = users.id) > 0;")
        assert _has_rule(v, "SA0005")


class TestSA0006InsertNoColumns:
    def test_fires_on_insert_without_columns(self):
        v = _analyze("INSERT INTO users VALUES (1, 'Alice', 'alice@example.com');")
        assert _has_rule(v, "SA0006")

    def test_no_fire_with_column_list(self):
        v = _analyze("INSERT INTO users (id, name, email) VALUES (1, 'Alice', 'alice@example.com');")
        assert not _has_rule(v, "SA0006")


class TestSA0007CursorUsage:
    def test_fires_on_declare_cursor(self):
        v = _analyze("DECLARE my_cursor CURSOR FOR SELECT id FROM users;")
        assert _has_rule(v, "SA0007")


class TestSA0008SchemaNotQualified:
    def test_fires_on_bare_table(self):
        v = _analyze("SELECT id FROM users WHERE active = 1;")
        assert _has_rule(v, "SA0008")

    def test_no_fire_on_qualified_table(self):
        v = _analyze("SELECT id FROM dbo.users WHERE active = 1;")
        assert not _has_rule(v, "SA0008")


# ===================================================================
# NEW UNIVERSAL RULES SA0015-SA0019
# ===================================================================

class TestSA0015MissingWhere:
    def test_fires_on_update_without_where(self):
        v = _analyze("UPDATE users SET status = 'inactive';")
        assert _has_rule(v, "SA0015")

    def test_fires_on_delete_without_where(self):
        v = _analyze("DELETE FROM old_records;")
        assert _has_rule(v, "SA0015")

    def test_no_fire_with_where(self):
        v = _analyze("UPDATE users SET status = 'inactive' WHERE last_login < '2020-01-01';")
        assert not _has_rule(v, "SA0015")

    def test_no_fire_on_merge_update(self):
        """False-positive fix: MERGE ... WHEN MATCHED THEN UPDATE should NOT fire."""
        sql = """\
        MERGE INTO users AS target
        USING new_data AS source ON target.id = source.id
        WHEN MATCHED THEN
            UPDATE SET target.name = source.name
        WHEN NOT MATCHED THEN
            INSERT (id, name) VALUES (source.id, source.name);
        """
        v = _analyze(sql, dialect="mssql")
        assert not _has_rule(v, "SA0015")

    def test_no_fire_on_upsert_do_update(self):
        """False-positive fix: ON CONFLICT DO UPDATE should NOT fire."""
        sql = """\
        INSERT INTO users (id, name) VALUES (1, 'Alice')
        ON CONFLICT (id) DO
            UPDATE SET name = EXCLUDED.name;
        """
        v = _analyze(sql, dialect="postgresql")
        assert not _has_rule(v, "SA0015")

    def test_no_fire_on_oracle_update_indexes(self):
        """False-positive fix: ALTER TABLE ... UPDATE INDEXES is DDL, not DML."""
        sql = "ALTER TABLE orders MOVE TABLESPACE data_ts UPDATE INDEXES ONLINE;"
        v = _analyze(sql, dialect="oracle")
        assert not _has_rule(v, "SA0015")

    def test_no_fire_with_join(self):
        sql = """\
        DELETE o
        FROM orders o
        JOIN users u ON o.user_id = u.id
        WHERE u.status = 'deleted';
        """
        v = _analyze(sql, dialect="mssql")
        assert not _has_rule(v, "SA0015")

    def test_no_fire_update_with_subquery_where(self):
        """Parenthesis depth: WHERE inside subquery in SET should not hide outer WHERE."""
        sql = """\
        UPDATE inventory inv
        SET inv.reserved = (
            SELECT SUM(oi.qty)
            FROM order_items oi
            WHERE oi.product_id = inv.product_id
        )
        WHERE inv.product_id IN (SELECT product_id FROM active_orders);
        """
        v = _analyze(sql, dialect="oracle")
        assert not _has_rule(v, "SA0015")


class TestSA0016UnionVsUnionAll:
    def test_fires_on_bare_union(self):
        sql = "SELECT id FROM users UNION SELECT id FROM admins;"
        v = _analyze(sql)
        assert _has_rule(v, "SA0016")

    def test_no_fire_on_union_all(self):
        sql = "SELECT id FROM users UNION ALL SELECT id FROM admins;"
        v = _analyze(sql)
        assert not _has_rule(v, "SA0016")


class TestSA0017OrderByInSubquery:
    def test_fires_on_order_by_in_subquery_without_limit(self):
        sql = "SELECT * FROM (SELECT id, name FROM users ORDER BY name) sub;"
        v = _analyze(sql)
        assert _has_rule(v, "SA0017")

    def test_no_fire_with_limit(self):
        sql = "SELECT * FROM (SELECT id, name FROM users ORDER BY name LIMIT 10) sub;"
        v = _analyze(sql)
        assert not _has_rule(v, "SA0017")

    def test_no_fire_with_top(self):
        sql = "SELECT * FROM (SELECT TOP 10 id, name FROM users ORDER BY name) sub;"
        v = _analyze(sql, dialect="mssql")
        assert not _has_rule(v, "SA0017")


class TestSA0018CorrelatedSubquery:
    def test_fires_on_correlated_subquery(self):
        sql = """\
        SELECT u.name,
            (SELECT COUNT(*) FROM orders o WHERE o.user_id = u.id) AS cnt
        FROM users u;
        """
        v = _analyze(sql)
        assert _has_rule(v, "SA0018")


class TestSA0019NestedSubqueries:
    def test_fires_on_deeply_nested(self):
        # SA0019 requires (SELECT on the same line; each nesting level on its own line
        sql = (
            "SELECT c.id FROM\n"
            "(SELECT b.id FROM\n"
            "(SELECT a.id FROM\n"
            "(SELECT id FROM dbo.users) a) b) c;\n"
        )
        v = _analyze(sql)
        assert _has_rule(v, "SA0019")


# ===================================================================
# SA0014 FALSE-POSITIVE FIX
# ===================================================================

class TestSA0014ColumnArithmetic:
    def test_fires_on_column_arithmetic(self):
        v = _analyze("SELECT * FROM orders WHERE price + tax > 100;")
        assert _has_rule(v, "SA0014")

    def test_no_fire_on_current_date_arithmetic(self):
        """False-positive fix: CURRENT_DATE - INTERVAL is constant, not column arithmetic."""
        v = _analyze("SELECT * FROM orders WHERE order_date >= CURRENT_DATE - INTERVAL '90 days';")
        assert not _has_rule(v, "SA0014")

    def test_no_fire_on_sysdate_arithmetic(self):
        v = _analyze("SELECT * FROM orders WHERE created_at > SYSDATE - 30;", dialect="oracle")
        assert not _has_rule(v, "SA0014")

    def test_no_fire_on_getdate_arithmetic(self):
        v = _analyze("SELECT * FROM orders WHERE order_date > GETDATE() - 7;", dialect="mssql")
        assert not _has_rule(v, "SA0014")


# ===================================================================
# SQLITE-SPECIFIC RULES SA-LITE001 through SA-LITE005
# ===================================================================

class TestSQLiteChecks:
    def test_lite001_missing_wal(self):
        sql = "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);\nINSERT INTO users VALUES (1, 'Alice');"
        v = _analyze(sql, dialect="sqlite")
        assert _has_rule(v, "SA-LITE001")

    def test_lite001_no_fire_with_wal(self):
        sql = "PRAGMA journal_mode=WAL;\nCREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);"
        v = _analyze(sql, dialect="sqlite")
        assert not _has_rule(v, "SA-LITE001")

    def test_lite002_missing_foreign_keys_pragma(self):
        sql = "CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id));"
        v = _analyze(sql, dialect="sqlite")
        assert _has_rule(v, "SA-LITE002")

    def test_lite002_no_fire_with_pragma(self):
        sql = "PRAGMA foreign_keys=ON;\nCREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id));"
        v = _analyze(sql, dialect="sqlite")
        assert not _has_rule(v, "SA-LITE002")

    def test_lite003_autoincrement(self):
        sql = "CREATE TABLE logs (id INTEGER PRIMARY KEY AUTOINCREMENT, msg TEXT);"
        v = _analyze(sql, dialect="sqlite")
        assert _has_rule(v, "SA-LITE003")

    def test_lite003_no_fire_without_autoincrement(self):
        sql = "CREATE TABLE logs (id INTEGER PRIMARY KEY, msg TEXT);"
        v = _analyze(sql, dialect="sqlite")
        assert not _has_rule(v, "SA-LITE003")

    def test_lite004_missing_busy_timeout(self):
        sql = "INSERT INTO users (name) VALUES ('Alice');"
        v = _analyze(sql, dialect="sqlite")
        assert _has_rule(v, "SA-LITE004")

    def test_lite004_no_fire_with_pragma(self):
        sql = "PRAGMA busy_timeout=5000;\nINSERT INTO users (name) VALUES ('Alice');"
        v = _analyze(sql, dialect="sqlite")
        assert not _has_rule(v, "SA-LITE004")

    def test_lite005_varchar_with_length(self):
        sql = "CREATE TABLE users (id INTEGER PRIMARY KEY, name VARCHAR(100));"
        v = _analyze(sql, dialect="sqlite")
        assert _has_rule(v, "SA-LITE005")

    def test_lite005_no_fire_with_text(self):
        sql = "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);"
        v = _analyze(sql, dialect="sqlite")
        assert not _has_rule(v, "SA-LITE005")


# ===================================================================
# MSSQL-SPECIFIC RULES (spot checks)
# ===================================================================

class TestMSSQLChecks:
    def test_ms001_missing_nocount(self):
        sql = """\
        CREATE PROCEDURE dbo.GetUsers
        AS
        BEGIN
            SELECT * FROM users;
        END;
        """
        v = _analyze(sql, dialect="mssql")
        assert _has_rule(v, "SA-MS001")

    def test_ms003_at_identity(self):
        sql = "SELECT @@IDENTITY;"
        v = _analyze(sql, dialect="mssql")
        assert _has_rule(v, "SA-MS003")

    def test_ms010_deprecated_types(self):
        sql = "CREATE TABLE docs (id INT, content TEXT, photo IMAGE);"
        v = _analyze(sql, dialect="mssql")
        assert _has_rule(v, "SA-MS010")

    def test_ms011_resumable_in_add_constraint(self):
        sql = """
        ALTER TABLE [dbo].[Orders]
        ADD CONSTRAINT [PK_Orders] PRIMARY KEY CLUSTERED ([OrderID] ASC)
        WITH (
            FILLFACTOR = 90,
            ONLINE = ON,
            RESUMABLE = ON, MAX_DURATION = 60 MINUTES
        );
        """
        v = _analyze(sql, dialect="mssql")
        assert _has_rule(v, "SA-MS011")

    def test_ms012_wait_low_priority_in_add_constraint(self):
        sql = """
        ALTER TABLE [dbo].[Orders]
        ADD CONSTRAINT [UQ_Orders_Ref] UNIQUE NONCLUSTERED ([ExternalRef] ASC)
        WITH (
            FILLFACTOR = 95,
            ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 5 MINUTES, ABORT_AFTER_WAIT = SELF))
        );
        """
        v = _analyze(sql, dialect="mssql")
        assert _has_rule(v, "SA-MS012")

    def test_ms013_resumable_in_user_transaction(self):
        sql = """
        BEGIN TRANSACTION;
        CREATE NONCLUSTERED INDEX [IX_Customers_Name] ON [dbo].[Customers] ([Name] ASC)
        WITH (
            FILLFACTOR = 95,
            ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 5 MINUTES, ABORT_AFTER_WAIT = SELF)),
            RESUMABLE = ON, MAX_DURATION = 60 MINUTES
        );
        COMMIT TRANSACTION;
        """
        v = _analyze(sql, dialect="mssql")
        assert _has_rule(v, "SA-MS013")

    def test_ms013_resumable_ok_outside_transaction(self):
        """RESUMABLE on CREATE INDEX with no BEGIN TRAN is valid -- should not fire SA-MS013."""
        sql = """
        CREATE NONCLUSTERED INDEX [IX_Orders_CustomerID] ON [dbo].[Orders] ([CustomerID] ASC)
        WITH (
            FILLFACTOR = 95,
            ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 5 MINUTES, ABORT_AFTER_WAIT = SELF)),
            RESUMABLE = ON, MAX_DURATION = 60 MINUTES
        );
        """
        v = _analyze(sql, dialect="mssql")
        assert not _has_rule(v, "SA-MS013")
        assert not _has_rule(v, "SA-MS011")
        assert not _has_rule(v, "SA-MS012")

    def test_ms013_flyway_marker_triggers_without_begin_tran(self):
        """SA-MS013 should fire on RESUMABLE when a Flyway/Liquibase comment
        marker is present, even without an explicit BEGIN TRAN."""
        sql = """
        -- flyway:placeholderReplacement=false
        CREATE NONCLUSTERED INDEX [IX_Customers_Email] ON [dbo].[Customers] ([Email] ASC)
        WITH (
            FILLFACTOR = 95,
            ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 5 MINUTES, ABORT_AFTER_WAIT = SELF)),
            RESUMABLE = ON, MAX_DURATION = 60 MINUTES
        );
        """
        v = _analyze(sql, dialect="mssql")
        assert _has_rule(v, "SA-MS013")

    def test_ms013_dedups_against_ms011_in_add_constraint(self):
        """When RESUMABLE = ON appears inside ALTER TABLE ADD CONSTRAINT
        within a transaction, only SA-MS011 should fire on that line --
        SA-MS013 must skip it to avoid double-reporting."""
        sql = """
        BEGIN TRANSACTION;
        ALTER TABLE [dbo].[Orders]
        ADD CONSTRAINT [PK_Orders] PRIMARY KEY CLUSTERED ([OrderID] ASC)
        WITH (
            FILLFACTOR = 90,
            ONLINE = ON,
            RESUMABLE = ON, MAX_DURATION = 60 MINUTES
        );
        COMMIT TRANSACTION;
        """
        v = _analyze(sql, dialect="mssql")
        ms011_lines = {x.line_number for x in v if x.rule_id == "SA-MS011"}
        ms013_lines = {x.line_number for x in v if x.rule_id == "SA-MS013"}
        assert ms011_lines, "SA-MS011 should fire on the RESUMABLE line"
        # No SA-MS013 should be reported on the same line as SA-MS011
        assert ms011_lines.isdisjoint(ms013_lines), (
            f"SA-MS013 should not double-report on SA-MS011 lines "
            f"(ms011={ms011_lines}, ms013={ms013_lines})"
        )


# ===================================================================
# FIX SUGGESTION GENERATION
# ===================================================================

class TestFixSuggestions:
    def test_violations_have_fix_text(self):
        v = _analyze("SELECT * FROM users;")
        sa0001 = [x for x in v if x.rule_id == "SA0001"]
        assert sa0001, "SA0001 should fire on SELECT *"
        assert sa0001[0].fix_text is not None
        assert len(sa0001[0].fix_text) > 0

    def test_all_violations_have_suggestions(self):
        """Every violation should have a non-empty suggestion field."""
        v = _analyze("SELECT * FROM users;\nINSERT INTO orders VALUES (1, 2, 3);")
        for violation in v:
            assert violation.suggestion, f"{violation.rule_id} missing suggestion"

    def test_violation_to_dict(self):
        v = _analyze("SELECT * FROM users;")
        if v:
            d = v[0].to_dict()
            assert "rule_id" in d
            assert "severity" in d
            assert "message" in d
            assert "suggestion" in d
            assert "line_number" in d


# ===================================================================
# INTEGRATION: ANALYZE REAL TEST FILES
# ===================================================================

class TestRealFiles:
    """Run analyzer on actual test-app files and verify results are sensible."""

    TEST_DIR = Path(__file__).parent.parent / "sql"

    @pytest.mark.parametrize("filename,expected_dialect", [
        ("queries/bad_queries.sql", Dialect.MSSQL),
        ("queries/bad_queries_postgresql.sql", Dialect.POSTGRESQL),
        ("queries/bad_queries_oracle.sql", Dialect.ORACLE),
        ("queries/bad_queries_mysql.sql", Dialect.MYSQL),
    ])
    def test_dialect_detection_on_test_files(self, filename, expected_dialect):
        filepath = self.TEST_DIR / filename
        if not filepath.exists():
            pytest.skip(f"Test file not found: {filepath}")
        with open(filepath, "r", encoding="utf-8") as f:
            content = f.read()
        detected = DialectDetector.detect(content, str(filepath))
        assert detected == expected_dialect

    @pytest.mark.parametrize("filename", [
        "queries/bad_queries.sql",
        "queries/bad_queries_postgresql.sql",
        "queries/bad_queries_oracle.sql",
        "queries/bad_queries_mysql.sql",
    ])
    def test_bad_queries_produce_violations(self, filename):
        filepath = self.TEST_DIR / filename
        if not filepath.exists():
            pytest.skip(f"Test file not found: {filepath}")
        analyzer = SQLAnalyzer()
        _, violations = analyzer.analyze_file(filepath)
        assert len(violations) > 0, f"Expected violations in {filename}"

    @pytest.mark.parametrize("filename", [
        "examples/oracle_examples.sql",
        "examples/mssql_examples.sql",
    ])
    def test_example_files_no_critical(self, filename):
        filepath = self.TEST_DIR / filename
        if not filepath.exists():
            pytest.skip(f"Test file not found: {filepath}")
        analyzer = SQLAnalyzer()
        _, violations = analyzer.analyze_file(filepath)
        critical = [v for v in violations if v.severity == Severity.CRITICAL]
        assert len(critical) == 0, f"Unexpected CRITICAL in {filename}: {[v.rule_id for v in critical]}"

    def test_sqlite_examples_trigger_lite_checks(self):
        filepath = self.TEST_DIR / "examples" / "sqlite_examples.sql"
        if not filepath.exists():
            pytest.skip("sqlite_examples.sql not found")
        analyzer = SQLAnalyzer(dialect=Dialect.SQLITE)
        _, violations = analyzer.analyze_file(filepath)
        lite_rules = {v.rule_id for v in violations if v.rule_id.startswith("SA-LITE")}
        expected = {"SA-LITE001", "SA-LITE002", "SA-LITE003", "SA-LITE004", "SA-LITE005"}
        assert expected.issubset(lite_rules), f"Missing SQLite checks: {expected - lite_rules}"


# ===================================================================
# v7.0.0 ENHANCEMENTS
# ===================================================================

def _rules(violations, rule_id):
    return [v for v in violations if v.rule_id == rule_id]


class TestIgnorePragmas:
    """Line- and file-level `-- nitsql:ignore` escape hatches (all dialects)."""

    def test_baseline_select_star_fires(self):
        v = _analyze("SELECT * FROM dbo.Orders;")
        assert _has_rule(v, "SA0001")

    def test_line_ignore_all_suppresses(self):
        v = _analyze("SELECT * FROM dbo.Orders;  -- nitsql:ignore")
        assert not _has_rule(v, "SA0001")

    def test_line_ignore_specific_rule_suppresses(self):
        v = _analyze("SELECT * FROM dbo.Orders;  -- nitsql:ignore=SA0001")
        assert not _has_rule(v, "SA0001")

    def test_line_ignore_other_rule_still_fires(self):
        v = _analyze("SELECT * FROM dbo.Orders;  -- nitsql:ignore=SA9999")
        assert _has_rule(v, "SA0001")

    def test_file_ignore_suppresses_everywhere(self):
        sql = """
        -- nitsql:ignore-file
        SELECT * FROM dbo.Orders;
        SELECT * FROM dbo.Customers;
        """
        v = _analyze(sql)
        assert not _has_rule(v, "SA0001")

    def test_file_ignore_specific_rule(self):
        sql = """
        -- nitsql:ignore-file=SA0001
        SELECT * FROM dbo.Orders;
        """
        v = _analyze(sql)
        assert not _has_rule(v, "SA0001")


class TestLinkedServerDemotion:
    """SA0002 demotion is LINE-scoped: only the offending linked-server passthrough
    line drops to HIGH; ordinary parameterizable injections stay CRITICAL even when
    an unrelated OPENQUERY/EXEC..AT appears elsewhere in the same file (MSSQL)."""

    CONCAT = "SET @q = 'SELECT * FROM t WHERE x = ' + @input + ' end';"

    def test_concat_is_critical_without_linked_server(self):
        v = _analyze(self.CONCAT, dialect="mssql")
        sa = _rules(v, "SA0002")
        assert sa and any(x.severity == Severity.CRITICAL for x in sa)

    def test_exec_at_linked_server_line_is_demoted_to_high(self):
        # The offending line IS a linked-server passthrough -> sp_executesql
        # can't fix it, so demote that line to HIGH.
        v = _analyze("EXEC (@sql) AT [LEGACY_LINK];", dialect="mssql")
        sa = _rules(v, "SA0002")
        assert sa and all(x.severity == Severity.HIGH for x in sa)

    def test_unrelated_injection_stays_critical(self):
        # Reviewer repro: a plain, fixable injection on line 1 must NOT be
        # masked by an unrelated linked-server EXEC on line 2.
        sql = (
            "SET @q = 'SELECT * FROM t WHERE x = ' + @userInput + ' end';\n"
            "EXEC (@x) AT [LEGACY_LINK];\n"
        )
        v = _analyze(sql, dialect="mssql")
        line1 = [x for x in _rules(v, "SA0002") if x.line_number == 1]
        line2 = [x for x in _rules(v, "SA0002") if x.line_number == 2]
        assert line1 and all(x.severity == Severity.CRITICAL for x in line1)
        assert line2 and all(x.severity == Severity.HIGH for x in line2)

    def test_multiline_passthrough_build_demoted(self):
        # OPENQUERY token on line 1, the concatenation that trips SA0002 on
        # line 2 of the SAME (unterminated) statement build -> demote to HIGH.
        sql = (
            "SET @sql = 'SELECT * FROM OPENQUERY(LNK, ''base'')'\n"
            "SET @sql = @sql + 'WHERE c = ' + @userInput + ''\n"
        )
        v = _analyze(sql, dialect="mssql")
        line2 = [x for x in _rules(v, "SA0002") if x.line_number == 2]
        assert line2 and all(x.severity == Severity.HIGH for x in line2)

    def test_semicolon_boundary_stops_demotion(self):
        # OPENQUERY statement on line 1 is terminated with `;`; the plain
        # injection on line 2 is a separate statement and stays CRITICAL.
        sql = (
            "SET @sql = 'SELECT * FROM OPENQUERY(LNK, ''base'')';\n"
            "SET @q = 'SELECT ' + @userInput + ' FROM t';\n"
        )
        v = _analyze(sql, dialect="mssql")
        line2 = [x for x in _rules(v, "SA0002") if x.line_number == 2]
        assert line2 and all(x.severity == Severity.CRITICAL for x in line2)

    def test_comment_mentioning_openquery_does_not_demote(self):
        # A -- comment that merely mentions OPENQUERY( must NOT demote a real,
        # parameterizable injection on the following line.
        sql = (
            "-- TODO: replace with OPENQUERY(LINKED_SRV, 'SELECT ...')\n"
            "SET @sql = 'SELECT * FROM orders WHERE id = ' + @userInput + ''\n"
        )
        v = _analyze(sql, dialect="mssql")
        line2 = [x for x in _rules(v, "SA0002") if x.line_number == 2]
        assert line2 and all(x.severity == Severity.CRITICAL for x in line2)

    def test_trailing_comment_after_string_openquery_still_demotes(self):
        # OPENQUERY inside the string literal (real passthrough) is still
        # detected even when a -- comment trails the statement.
        sql = "SET @sql = 'SELECT FROM OPENQUERY(LNK, ''x'')' + @q + ''  -- build\n"
        v = _analyze(sql, dialect="mssql")
        sa = _rules(v, "SA0002")
        assert sa and all(x.severity == Severity.HIGH for x in sa)

    def test_window_cap_keeps_distant_injection_critical(self):
        # OPENQUERY is >2 lines away from the injection (no `;` to stop on);
        # the window cap must keep the distant injection CRITICAL.
        sql = (
            "SELECT * FROM OPENQUERY(LNK, 'base')\n"
            "GO\n"
            "DECLARE @x INT\n"
            "SET @q = 'a' + @userInput + 'b'\n"
        )
        v = _analyze(sql, dialect="mssql")
        line4 = [x for x in _rules(v, "SA0002") if x.line_number == 4]
        assert line4 and all(x.severity == Severity.CRITICAL for x in line4)


class TestDoubledQuoteStringMasking:
    """Doubled-quote ('') escapes must be consumed so embedded SQL is masked."""

    def test_embedded_select_star_in_dynamic_string_not_flagged(self):
        sql = "SET @sql = N'SELECT * FROM OPENQUERY(SRV, ''SELECT * FROM remote'')';"
        v = _analyze(sql, dialect="mssql")
        # The inner SELECT * lives inside a string literal -> must not raise SA0001.
        assert not _has_rule(v, "SA0001")


class TestExecAtLinkedServerDemotion:
    """SA-MS007 demoted to MEDIUM for EXEC(@sql) AT linked_server (no sp_executesql AT variant)."""

    def test_exec_at_linked_server_is_medium(self):
        v = _analyze("EXEC(@sql) AT [REMOTE_SRV];", dialect="mssql")
        ms = _rules(v, "SA-MS007")
        assert ms and all(x.severity == Severity.MEDIUM for x in ms)

    def test_plain_exec_variable_is_high(self):
        v = _analyze("EXEC(@sql);", dialect="mssql")
        ms = _rules(v, "SA-MS007")
        assert ms and any(x.severity == Severity.HIGH for x in ms)


class TestCTEAwareSchemaQualify:
    """SA0008 must not flag CTE names or trigger pseudo-tables referenced in FROM/JOIN."""

    def test_cte_reference_not_flagged(self):
        sql = """
        WITH recent AS (
            SELECT id FROM dbo.Orders
        )
        SELECT id FROM recent;
        """
        v = _analyze(sql, dialect="mssql")
        sa = _rules(v, "SA0008")
        assert not any("recent" in (x.line_text or "").lower() for x in sa)

    def test_trigger_pseudo_table_not_flagged(self):
        v = _analyze("SELECT col FROM inserted;", dialect="mssql")
        sa = _rules(v, "SA0008")
        assert not any("inserted" in (x.line_text or "").lower() for x in sa)

    def test_bare_table_still_flagged(self):
        v = _analyze("SELECT col FROM Orders;", dialect="mssql")
        assert _has_rule(v, "SA0008")
