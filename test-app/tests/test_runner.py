#!/usr/bin/env python3
"""
test_runner.py - Multi-Dialect Automated Test Runner for SQL Valid8 Skill (example)

This script:
1. Analyzes test files across all supported SQL dialects (MSSQL, PostgreSQL, Oracle, MySQL)
2. Detects dialect from filename suffix or file content
3. Compares detected violations against expected violations
4. Reports per-dialect and overall skill accuracy

Usage:
    python test_runner.py                        # Run all tests
    python test_runner.py --dialect postgresql    # Run tests for one dialect
    python test_runner.py --file <path>           # Test specific file
    python test_runner.py --report                # Generate detailed report
    python test_runner.py --json                  # Output as JSON
"""

import os
import sys
import json
import re
import subprocess
from pathlib import Path
from dataclasses import dataclass, asdict
from typing import List, Dict, Set, Optional
from enum import Enum

# Add scripts to path (tests/ -> test-app/ -> repo root -> skills/sql-valid8/scripts)
SCRIPTS_DIR = Path(__file__).parent.parent.parent / "skills" / "sql-valid8" / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))


# ---------------------------------------------------------------------------
# Enums & Data Classes
# ---------------------------------------------------------------------------

class Severity(Enum):
    CRITICAL = "CRITICAL"
    HIGH = "HIGH"
    MEDIUM = "MEDIUM"
    LOW = "LOW"


class Dialect(Enum):
    MSSQL = "mssql"
    POSTGRESQL = "postgresql"
    ORACLE = "oracle"
    MYSQL = "mysql"
    SQLITE = "sqlite"
    UNKNOWN = "unknown"


@dataclass
class ExpectedViolation:
    file: str
    rule_id: str
    severity: str
    line_range: tuple  # (start, end) - approximate line range
    description: str
    dialect: str       # mssql, postgresql, oracle, mysql


# ---------------------------------------------------------------------------
# Dialect Detection
# ---------------------------------------------------------------------------

def detect_dialect_from_filename(filename: str) -> Dialect:
    """Detect SQL dialect from filename suffix."""
    name = Path(filename).stem.lower()
    if name.endswith("_postgresql") or name.endswith("_pg"):
        return Dialect.POSTGRESQL
    elif name.endswith("_oracle") or name.endswith("_ora"):
        return Dialect.ORACLE
    elif name.endswith("_mysql") or name.endswith("_my"):
        return Dialect.MYSQL
    elif name.endswith("_mssql") or name.endswith("_tsql"):
        return Dialect.MSSQL
    return Dialect.UNKNOWN


def detect_dialect_from_content(content: str) -> Dialect:
    """Detect SQL dialect from file content patterns."""
    content_upper = content.upper()

    # PostgreSQL indicators
    pg_patterns = [
        r'\$\$\s*LANGUAGE\s+plpgsql',
        r'RETURNS\s+SETOF',
        r'DO\s+\$\$',
        r'ILIKE',
        r'GENERATED\s+(ALWAYS|BY DEFAULT)\s+AS\s+IDENTITY',
        r'SERIAL\b',
    ]
    pg_score = sum(1 for p in pg_patterns if re.search(p, content, re.IGNORECASE))

    # Oracle indicators
    ora_patterns = [
        r'CREATE\s+OR\s+REPLACE\s+PROCEDURE\b.*\bAS\b',
        r'SYS_REFCURSOR',
        r'DBMS_OUTPUT',
        r'SYSDATE\b',
        r'VARCHAR2\b',
        r'EXECUTE\s+IMMEDIATE\b',
        r'\bEND\s+\w+\s*;\s*/\s*$',
    ]
    ora_score = sum(1 for p in ora_patterns if re.search(p, content, re.IGNORECASE | re.MULTILINE))

    # MySQL indicators
    my_patterns = [
        r'DELIMITER\s+//',
        r'ENGINE\s*=\s*(InnoDB|MyISAM)',
        r'AUTO_INCREMENT\b',
        r'DECLARE\s+CONTINUE\s+HANDLER',
        r'PREPARE\s+stmt\s+FROM\s+@',
    ]
    my_score = sum(1 for p in my_patterns if re.search(p, content, re.IGNORECASE))

    # MSSQL indicators
    ms_patterns = [
        r'\bGO\b\s*$',
        r'SET\s+NOCOUNT\s+ON',
        r'@@IDENTITY\b',
        r'SCOPE_IDENTITY\(\)',
        r'sp_executesql\b',
        r'NVARCHAR\b',
        r'BEGIN\s+TRY',
    ]
    ms_score = sum(1 for p in ms_patterns if re.search(p, content, re.IGNORECASE | re.MULTILINE))

    scores = {
        Dialect.POSTGRESQL: pg_score,
        Dialect.ORACLE: ora_score,
        Dialect.MYSQL: my_score,
        Dialect.MSSQL: ms_score,
    }

    best = max(scores, key=scores.get)
    if scores[best] == 0:
        return Dialect.UNKNOWN
    return best


def detect_dialect(file_path: str) -> Dialect:
    """Detect dialect from filename first, then fall back to content analysis."""
    dialect = detect_dialect_from_filename(file_path)
    if dialect != Dialect.UNKNOWN:
        return dialect

    try:
        with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
        return detect_dialect_from_content(content)
    except Exception:
        return Dialect.UNKNOWN


# ---------------------------------------------------------------------------
# Rule ID Aliases (cross-dialect)
# ---------------------------------------------------------------------------

# Maps canonical SSDT/custom rule IDs to descriptive names
RULE_ALIASES = {
    # Cross-dialect (SA prefix)
    "SA0001": "query-avoid-select-star",
    "SA0002": "query-parameterize",
    "SA0003": "query-sargable",
    "SA0004": "query-avoid-leading-wildcard",
    "SA0005": "query-avoid-count-for-exists",
    "SA0006": "query-insert-column-list",
    "SA0007": "query-avoid-cursors",
    "SA0008": "query-schema-qualify",
    # MSSQL-specific (SR prefix = legacy SSDT rules, maps to SA prefix)
    "SR0001": "query-avoid-select-star",
    "SR0005": "query-avoid-leading-wildcard",
    "SR0008": "tsql-scope-identity",
    "SR0009": "type-appropriate-size",
    "SR0010": "tsql-avoid-deprecated-joins",
    "SR0014": "query-avoid-implicit-conversion",
    "SR0016": "tsql-avoid-sp-prefix",
    # MSSQL-specific (new SA-MS prefix from multi-dialect analyzer)
    "SA-MS001": "tsql-set-nocount",
    "SA-MS002": "tsql-xact-abort",
    "SA-MS003": "tsql-scope-identity",
    "SA-MS004": "tsql-deprecated-join",
    "SA-MS005": "tsql-sp-prefix",
    "SA-MS006": "type-appropriate-size",
    "SA-MS007": "tsql-exec-variable",
    "SA-MS008": "tsql-error-handling",
    "SA-MS009": "tsql-nolock-hint",
    "SA-MS010": "tsql-deprecated-types",
    # Reverse mappings: legacy SSDT → new SA-MS IDs
    "tsql-set-nocount": "SA-MS001",
    "tsql-error-handling": "SA-MS008",
    # PostgreSQL-specific
    "SA-PG001": "pg-use-identity-columns",
    "SA-PG002": "pg-use-text-type",
    "SA-PG004": "pg-security-definer-search-path",
    # Oracle-specific
    "SA-ORA001": "ora-when-others-null",
    "SA-ORA002": "ora-use-varchar2",
    "SA-ORA004": "ora-select-into-exception",
    "SA-ORA005": "ora-avoid-long-type",
    # MySQL-specific
    "SA-MY001": "my-use-innodb",
    "SA-MY002": "my-avoid-float-money",
    "SA-MY004": "my-avoid-enum",
}


# ---------------------------------------------------------------------------
# Expected Violations per Test File
# ---------------------------------------------------------------------------

EXPECTED_VIOLATIONS = {
    # ----- MSSQL -----
    "sql/procedures/bad_procedures.sql": [
        ExpectedViolation("sql/procedures/bad_procedures.sql", "SR0001", "HIGH", (36, 36), "SELECT * in GetCustomerOrders", "mssql"),
        ExpectedViolation("sql/procedures/bad_procedures.sql", "tsql-set-nocount", "MEDIUM", (29, 29), "Missing SET NOCOUNT ON in GetCustomerOrders", "mssql"),
        ExpectedViolation("sql/procedures/bad_procedures.sql", "SA0002", "CRITICAL", (54, 60), "SQL injection in SearchProducts", "mssql"),
        ExpectedViolation("sql/procedures/bad_procedures.sql", "SA0007", "HIGH", (75, 75), "Cursor in UpdateOrderStatuses", "mssql"),
        ExpectedViolation("sql/procedures/bad_procedures.sql", "tsql-error-handling", "HIGH", (117, 117), "Transaction without TRY-CATCH in ProcessPayment", "mssql"),
        ExpectedViolation("sql/procedures/bad_procedures.sql", "SA0003", "HIGH", (157, 162), "Non-SARGable predicates in GetReportData", "mssql"),
        ExpectedViolation("sql/procedures/bad_procedures.sql", "SR0008", "MEDIUM", (231, 231), "@@IDENTITY instead of SCOPE_IDENTITY()", "mssql"),
        ExpectedViolation("sql/procedures/bad_procedures.sql", "SR0009", "LOW", (242, 244), "VARCHAR(1)/VARCHAR(2) instead of CHAR", "mssql"),
        ExpectedViolation("sql/procedures/bad_procedures.sql", "SR0010", "MEDIUM", (267, 267), "Deprecated *= join syntax", "mssql"),
        ExpectedViolation("sql/procedures/bad_procedures.sql", "SR0016", "MEDIUM", (306, 306), "sp_ prefix on stored procedure", "mssql"),
        ExpectedViolation("sql/procedures/bad_procedures.sql", "SA0004", "HIGH", (162, 162), "Leading wildcard LIKE '%...'", "mssql"),
        ExpectedViolation("sql/procedures/bad_procedures.sql", "SR0014", "HIGH", (376, 382), "Implicit type conversion data loss", "mssql"),
    ],
    "sql/queries/bad_queries.sql": [
        ExpectedViolation("sql/queries/bad_queries.sql", "SR0001", "HIGH", (13, 13), "SELECT * in Customer Search", "mssql"),
        ExpectedViolation("sql/queries/bad_queries.sql", "SA0003", "HIGH", (15, 15), "UPPER() function on column", "mssql"),
        ExpectedViolation("sql/queries/bad_queries.sql", "SA0004", "HIGH", (15, 15), "Leading wildcard LIKE '%SMITH%'", "mssql"),
        ExpectedViolation("sql/queries/bad_queries.sql", "SA0005", "HIGH", (38, 38), "COUNT(*) > 0 instead of EXISTS", "mssql"),
        ExpectedViolation("sql/queries/bad_queries.sql", "SA0006", "MEDIUM", (143, 143), "INSERT without column list", "mssql"),
    ],

    # ----- PostgreSQL -----
    "sql/procedures/bad_procedures_postgresql.sql": [
        ExpectedViolation("sql/procedures/bad_procedures_postgresql.sql", "SA0001", "HIGH", (62, 62), "SELECT * in get_customer_orders", "postgresql"),
        ExpectedViolation("sql/procedures/bad_procedures_postgresql.sql", "SA0008", "MEDIUM", (62, 62), "No schema qualifier in get_customer_orders", "postgresql"),
        ExpectedViolation("sql/procedures/bad_procedures_postgresql.sql", "SA0002", "CRITICAL", (72, 72), "SQL injection in search_products (EXECUTE without USING)", "postgresql"),
        ExpectedViolation("sql/procedures/bad_procedures_postgresql.sql", "SA0002", "CRITICAL", (86, 86), "SQL injection in search_products_dynamic", "postgresql"),
        ExpectedViolation("sql/procedures/bad_procedures_postgresql.sql", "SA0003", "HIGH", (98, 98), "Non-SARGable EXTRACT(YEAR) in get_orders_by_year", "postgresql"),
        ExpectedViolation("sql/procedures/bad_procedures_postgresql.sql", "SA0004", "HIGH", (111, 111), "Leading wildcard ILIKE in find_customers_by_name", "postgresql"),
        ExpectedViolation("sql/procedures/bad_procedures_postgresql.sql", "SA0005", "HIGH", (122, 125), "COUNT(*) > 0 in customer_has_orders", "postgresql"),
        ExpectedViolation("sql/procedures/bad_procedures_postgresql.sql", "SA0006", "MEDIUM", (136, 136), "INSERT without column list in insert_order_quick", "postgresql"),
        ExpectedViolation("sql/procedures/bad_procedures_postgresql.sql", "SA0007", "HIGH", (146, 165), "Cursor loop in expire_old_orders", "postgresql"),
        ExpectedViolation("sql/procedures/bad_procedures_postgresql.sql", "SA-PG004", "HIGH", (172, 172), "SECURITY DEFINER without search_path", "postgresql"),
        ExpectedViolation("sql/procedures/bad_procedures_postgresql.sql", "SA-PG001", "MEDIUM", (29, 29), "SERIAL instead of GENERATED AS IDENTITY", "postgresql"),
        ExpectedViolation("sql/procedures/bad_procedures_postgresql.sql", "SA-PG002", "MEDIUM", (32, 36), "VARCHAR(255) everywhere instead of TEXT", "postgresql"),
    ],
    "sql/queries/bad_queries_postgresql.sql": [
        ExpectedViolation("sql/queries/bad_queries_postgresql.sql", "SA0001", "HIGH", (12, 12), "SELECT * in Customer Search", "postgresql"),
        ExpectedViolation("sql/queries/bad_queries_postgresql.sql", "SA0003", "HIGH", (14, 14), "Non-SARGable UPPER() on column", "postgresql"),
        ExpectedViolation("sql/queries/bad_queries_postgresql.sql", "SA0003", "HIGH", (23, 24), "Non-SARGable EXTRACT on column", "postgresql"),
        ExpectedViolation("sql/queries/bad_queries_postgresql.sql", "SA0004", "HIGH", (34, 34), "Leading wildcard ILIKE", "postgresql"),
        ExpectedViolation("sql/queries/bad_queries_postgresql.sql", "SA0005", "HIGH", (43, 43), "COUNT(*) > 0 instead of EXISTS", "postgresql"),
        ExpectedViolation("sql/queries/bad_queries_postgresql.sql", "SA0006", "MEDIUM", (108, 108), "INSERT without column list", "postgresql"),
    ],

    # ----- Oracle -----
    "sql/procedures/bad_procedures_oracle.sql": [
        ExpectedViolation("sql/procedures/bad_procedures_oracle.sql", "SA0001", "HIGH", (30, 30), "SELECT * in get_customer_orders", "oracle"),
        ExpectedViolation("sql/procedures/bad_procedures_oracle.sql", "SA-ORA001", "CRITICAL", (33, 33), "WHEN OTHERS THEN NULL in get_customer_orders", "oracle"),
        ExpectedViolation("sql/procedures/bad_procedures_oracle.sql", "SA0002", "CRITICAL", (46, 46), "SQL injection in search_products (EXECUTE IMMEDIATE ||)", "oracle"),
        ExpectedViolation("sql/procedures/bad_procedures_oracle.sql", "SA0003", "HIGH", (59, 59), "Non-SARGable TO_CHAR in get_orders_by_year", "oracle"),
        ExpectedViolation("sql/procedures/bad_procedures_oracle.sql", "SA-ORA004", "HIGH", (73, 77), "SELECT INTO without NO_DATA_FOUND in find_customer_by_email", "oracle"),
        ExpectedViolation("sql/procedures/bad_procedures_oracle.sql", "SA-ORA002", "MEDIUM", (87, 89), "VARCHAR instead of VARCHAR2 in create_customer", "oracle"),
        ExpectedViolation("sql/procedures/bad_procedures_oracle.sql", "SA-ORA005", "MEDIUM", (90, 90), "LONG data type in create_customer", "oracle"),
        ExpectedViolation("sql/procedures/bad_procedures_oracle.sql", "SA0007", "HIGH", (100, 116), "Cursor FOR loop in expire_old_orders", "oracle"),
        ExpectedViolation("sql/procedures/bad_procedures_oracle.sql", "SA0002", "CRITICAL", (127, 127), "SQL injection in dynamic_search", "oracle"),
        ExpectedViolation("sql/procedures/bad_procedures_oracle.sql", "SA0003", "HIGH", (141, 144), "Non-SARGable TO_CHAR/UPPER in get_report_data", "oracle"),
        ExpectedViolation("sql/procedures/bad_procedures_oracle.sql", "SA-ORA001", "CRITICAL", (160, 160), "WHEN OTHERS THEN NULL in process_payment", "oracle"),
        ExpectedViolation("sql/procedures/bad_procedures_oracle.sql", "SA0006", "MEDIUM", (192, 192), "INSERT without column list in insert_order_no_columns", "oracle"),
    ],
    "sql/queries/bad_queries_oracle.sql": [
        ExpectedViolation("sql/queries/bad_queries_oracle.sql", "SA0001", "HIGH", (12, 12), "SELECT * in Customer Search", "oracle"),
        ExpectedViolation("sql/queries/bad_queries_oracle.sql", "SA0003", "HIGH", (14, 14), "Non-SARGable UPPER() on column", "oracle"),
        ExpectedViolation("sql/queries/bad_queries_oracle.sql", "SA0003", "HIGH", (33, 34), "Non-SARGable TO_CHAR on date column", "oracle"),
        ExpectedViolation("sql/queries/bad_queries_oracle.sql", "SA0004", "HIGH", (43, 43), "Leading wildcard LIKE", "oracle"),
        ExpectedViolation("sql/queries/bad_queries_oracle.sql", "SA0005", "HIGH", (52, 52), "COUNT(*) > 0 instead of EXISTS", "oracle"),
        ExpectedViolation("sql/queries/bad_queries_oracle.sql", "SA0006", "MEDIUM", (100, 100), "INSERT without column list", "oracle"),
    ],

    # ----- MySQL -----
    "sql/procedures/bad_procedures_mysql.sql": [
        ExpectedViolation("sql/procedures/bad_procedures_mysql.sql", "SA0001", "HIGH", (65, 65), "SELECT * in get_customer_orders", "mysql"),
        ExpectedViolation("sql/procedures/bad_procedures_mysql.sql", "SA0002", "CRITICAL", (64, 64), "SQL injection CONCAT+PREPARE in get_customer_orders", "mysql"),
        ExpectedViolation("sql/procedures/bad_procedures_mysql.sql", "SA0002", "CRITICAL", (77, 77), "SQL injection CONCAT in search_products", "mysql"),
        ExpectedViolation("sql/procedures/bad_procedures_mysql.sql", "SA0003", "HIGH", (89, 90), "Non-SARGable YEAR()/MONTH() in get_orders_by_year", "mysql"),
        ExpectedViolation("sql/procedures/bad_procedures_mysql.sql", "SA0004", "HIGH", (101, 101), "Leading wildcard LIKE in find_customers_by_name", "mysql"),
        ExpectedViolation("sql/procedures/bad_procedures_mysql.sql", "SA0005", "HIGH", (112, 115), "COUNT(*) > 0 in customer_has_orders", "mysql"),
        ExpectedViolation("sql/procedures/bad_procedures_mysql.sql", "SA0006", "MEDIUM", (128, 128), "INSERT without column list in insert_order_quick", "mysql"),
        ExpectedViolation("sql/procedures/bad_procedures_mysql.sql", "SA0007", "HIGH", (140, 160), "Cursor loop in expire_old_orders", "mysql"),
        ExpectedViolation("sql/procedures/bad_procedures_mysql.sql", "SA-MY001", "MEDIUM", (25, 25), "MyISAM engine instead of InnoDB", "mysql"),
        ExpectedViolation("sql/procedures/bad_procedures_mysql.sql", "SA-MY002", "MEDIUM", (26, 27), "FLOAT for currency values", "mysql"),
        ExpectedViolation("sql/procedures/bad_procedures_mysql.sql", "SA-MY004", "MEDIUM", (24, 24), "ENUM for changeable values", "mysql"),
        ExpectedViolation("sql/procedures/bad_procedures_mysql.sql", "SA0002", "CRITICAL", (201, 201), "SQL injection in dynamic_search", "mysql"),
    ],
    "sql/queries/bad_queries_mysql.sql": [
        ExpectedViolation("sql/queries/bad_queries_mysql.sql", "SA0001", "HIGH", (12, 12), "SELECT * in Customer Search", "mysql"),
        ExpectedViolation("sql/queries/bad_queries_mysql.sql", "SA0003", "HIGH", (14, 14), "Non-SARGable UPPER() on column", "mysql"),
        ExpectedViolation("sql/queries/bad_queries_mysql.sql", "SA0003", "HIGH", (25, 26), "Non-SARGable YEAR()/MONTH() on column", "mysql"),
        ExpectedViolation("sql/queries/bad_queries_mysql.sql", "SA0004", "HIGH", (35, 35), "Leading wildcard LIKE", "mysql"),
        ExpectedViolation("sql/queries/bad_queries_mysql.sql", "SA0005", "HIGH", (44, 44), "COUNT(*) > 0 instead of EXISTS", "mysql"),
        ExpectedViolation("sql/queries/bad_queries_mysql.sql", "SA0006", "MEDIUM", (107, 107), "INSERT without column list", "mysql"),
    ],

    # ----- App code (dialect-agnostic) -----
    "python/bad_app.py": [
        ExpectedViolation("python/bad_app.py", "SA0002", "CRITICAL", (30, 35), "SQL injection in get_user_by_id", "mssql"),
        ExpectedViolation("python/bad_app.py", "SA0001", "CRITICAL", (30, 35), "SELECT * in get_user_by_id", "mssql"),
        ExpectedViolation("python/bad_app.py", "connection-pooling", "HIGH", (30, 35), "No connection pooling in get_user_by_id", "mssql"),
        ExpectedViolation("python/bad_app.py", "SA0002", "CRITICAL", (45, 55), "SQL injection in search_products", "mssql"),
        ExpectedViolation("python/bad_app.py", "SA0002", "CRITICAL", (65, 75), "SQL injection in get_user_orders", "mssql"),
        ExpectedViolation("python/bad_app.py", "connection-retry-logic", "HIGH", (80, 110), "No retry logic in insert_order", "mssql"),
    ],
    "node/bad_app.js": [
        ExpectedViolation("node/bad_app.js", "SA0002", "CRITICAL", (30, 40), "SQL injection in getUserById", "mssql"),
        ExpectedViolation("node/bad_app.js", "connection-pooling", "HIGH", (30, 40), "New pool per request in getUserById", "mssql"),
        ExpectedViolation("node/bad_app.js", "SA0002", "CRITICAL", (50, 65), "SQL injection in searchProducts", "mssql"),
        ExpectedViolation("node/bad_app.js", "SA0002", "CRITICAL", (75, 85), "SQL injection in getUserOrders", "mssql"),
    ],
    "csharp/BadApp.cs": [
        ExpectedViolation("csharp/BadApp.cs", "SA0002", "CRITICAL", (30, 50), "SQL injection in GetUserById", "mssql"),
        ExpectedViolation("csharp/BadApp.cs", "SA0001", "CRITICAL", (30, 50), "SELECT * in GetUserById", "mssql"),
        ExpectedViolation("csharp/BadApp.cs", "connection-pooling", "HIGH", (17, 20), "Pooling=false in connection string", "mssql"),
        ExpectedViolation("csharp/BadApp.cs", "SA0002", "CRITICAL", (60, 80), "SQL injection in SearchProducts", "mssql"),
    ],
}


# ---------------------------------------------------------------------------
# Analyzers
# ---------------------------------------------------------------------------

def run_tsql_analyzer(file_path: str) -> List[Dict]:
    """Run the T-SQL analyzer and return violations."""
    try:
        from analyze_tsql import TSQLAnalyzer
        analyzer = TSQLAnalyzer()
        violations = analyzer.analyze_file(file_path)
        return [asdict(v) for v in violations]
    except Exception as e:
        print(f"  [warn] T-SQL analyzer error: {e}")
        return []


def run_sql_analyzer(file_path: str, dialect: str) -> List[Dict]:
    """
    Attempt to run the multi-dialect analyze_sql.py script (if it exists),
    otherwise fall back to pattern-based detection.
    """
    analyze_script = SCRIPTS_DIR / "analyze_sql.py"
    if analyze_script.exists():
        try:
            result = subprocess.run(
                [sys.executable, str(analyze_script), "--dialect", dialect, "--json", file_path],
                capture_output=True, text=True, timeout=30
            )
            # Note: analyzer returns non-zero on CRITICAL findings, so don't
            # gate on returncode == 0.  Parse stdout if it looks like JSON.
            if result.stdout.strip():
                data = json.loads(result.stdout)
                if isinstance(data, list):
                    return data
                elif isinstance(data, dict):
                    # JSON structure: { "reports": [ { "violations": [...] } ] }
                    if "reports" in data and data["reports"]:
                        return data["reports"][0].get("violations", [])
                    elif "violations" in data:
                        return data["violations"]
        except Exception as e:
            print(f"  [warn] analyze_sql.py error: {e}")

    # Fall back to pattern-based detection
    return pattern_based_sql_check(file_path, dialect)


def pattern_based_sql_check(file_path: str, dialect: str) -> List[Dict]:
    """
    Pattern-based SQL violation detector.  Works across all dialects.
    This is the fallback when the full analyzer is not available.
    """
    violations = []

    with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()
        lines = content.split("\n")

    # ------ Cross-dialect checks ------

    # SA0001: SELECT *
    select_star = re.compile(r'\bSELECT\s+\*', re.IGNORECASE)
    exists_ctx = re.compile(r'\bEXISTS\s*\(\s*SELECT', re.IGNORECASE)
    count_ctx = re.compile(r'\bCOUNT\s*\(\s*\*\s*\)', re.IGNORECASE)
    for i, line in enumerate(lines, 1):
        stripped = line.split("--")[0]  # ignore comments
        if select_star.search(stripped) and not exists_ctx.search(stripped) and not count_ctx.search(stripped):
            violations.append({
                "rule_id": "SA0001", "severity": "HIGH",
                "line_number": i, "description": "SELECT * usage",
            })

    # SA0002: SQL injection patterns
    injection_patterns = {
        "mssql": [
            (r"EXEC\s*\(\s*@?\w+\s*\)", "EXEC with variable (use sp_executesql)"),
            (r"'\s*\+\s*@\w+\s*\+\s*'", "String concatenation in dynamic SQL"),
        ],
        "postgresql": [
            (r"EXECUTE\s+'[^']*'\s*\|\|", "EXECUTE with || concatenation (use USING)"),
            (r"\|\|\s*\w+\s*\|\|.*EXECUTE", "Variable concatenation in EXECUTE"),
        ],
        "oracle": [
            (r"EXECUTE\s+IMMEDIATE\s+.*\|\|", "EXECUTE IMMEDIATE with || concatenation"),
            (r":=\s*'[^']*'\s*\|\|\s*\w+", "Assignment with || concatenation for dynamic SQL"),
        ],
        "mysql": [
            (r"CONCAT\s*\([^)]*\)\s*;\s*$", "CONCAT in PREPARE statement"),
            (r"SET\s+@sql\s*=\s*CONCAT", "CONCAT to build dynamic SQL"),
        ],
    }
    for pattern, desc in injection_patterns.get(dialect, []):
        for i, line in enumerate(lines, 1):
            stripped = line.split("--")[0]
            if re.search(pattern, stripped, re.IGNORECASE):
                violations.append({
                    "rule_id": "SA0002", "severity": "CRITICAL",
                    "line_number": i, "description": f"SQL injection: {desc}",
                })

    # SA0003: Non-SARGable predicates
    nonsarg_patterns = {
        "mssql":      [r'WHERE\s+.*\bYEAR\s*\(', r'WHERE\s+.*\bMONTH\s*\(', r'WHERE\s+.*\bCONVERT\s*\(', r'WHERE\s+.*\bISNULL\s*\('],
        "postgresql": [r'WHERE\s+.*\bEXTRACT\s*\(', r'WHERE\s+.*\bUPPER\s*\(', r'WHERE\s+.*\bdate_trunc\s*\(', r'WHERE\s+.*\bto_char\s*\('],
        "oracle":     [r'WHERE\s+.*\bTO_CHAR\s*\(', r'WHERE\s+.*\bUPPER\s*\(', r'WHERE\s+.*\bTRUNC\s*\(', r'WHERE\s+.*\bNVL\s*\('],
        "mysql":      [r'WHERE\s+.*\bYEAR\s*\(', r'WHERE\s+.*\bMONTH\s*\(', r'WHERE\s+.*\bDATE\s*\(', r'WHERE\s+.*\bUPPER\s*\('],
    }
    for pattern in nonsarg_patterns.get(dialect, []):
        for i, line in enumerate(lines, 1):
            stripped = line.split("--")[0]
            if re.search(pattern, stripped, re.IGNORECASE):
                violations.append({
                    "rule_id": "SA0003", "severity": "HIGH",
                    "line_number": i, "description": "Non-SARGable predicate (function on column in WHERE)",
                })

    # SA0004: Leading wildcard
    for i, line in enumerate(lines, 1):
        stripped = line.split("--")[0]
        if re.search(r"(I?LIKE)\s+['\"]%", stripped, re.IGNORECASE) or \
           re.search(r"(I?LIKE)\s+CONCAT\s*\(\s*'%'", stripped, re.IGNORECASE):
            violations.append({
                "rule_id": "SA0004", "severity": "HIGH",
                "line_number": i, "description": "Leading wildcard in LIKE prevents index usage",
            })

    # SA0005: COUNT(*) > 0 instead of EXISTS
    for i, line in enumerate(lines, 1):
        stripped = line.split("--")[0]
        if re.search(r'\bCOUNT\s*\(\s*\*\s*\)', stripped, re.IGNORECASE):
            # Check nearby lines for > 0 comparison
            context = " ".join(lines[max(0, i - 2):min(len(lines), i + 2)])
            if re.search(r'COUNT\s*\(\s*\*\s*\)\s*>\s*0', context, re.IGNORECASE) or \
               re.search(r'COUNT\s*\(\s*\*\s*\)\s*\)\s*>\s*0', context, re.IGNORECASE):
                violations.append({
                    "rule_id": "SA0005", "severity": "HIGH",
                    "line_number": i, "description": "COUNT(*) > 0 instead of EXISTS",
                })

    # SA0006: INSERT without column list
    for i, line in enumerate(lines, 1):
        stripped = line.split("--")[0]
        if re.search(r'\bINSERT\s+INTO\s+\w+\s+VALUES\b', stripped, re.IGNORECASE):
            violations.append({
                "rule_id": "SA0006", "severity": "MEDIUM",
                "line_number": i, "description": "INSERT without explicit column list",
            })

    # SA0007: Cursor usage
    for i, line in enumerate(lines, 1):
        stripped = line.split("--")[0]
        if re.search(r'\bDECLARE\b.*\bCURSOR\b', stripped, re.IGNORECASE) or \
           re.search(r'\bFOR\s+rec\s+IN\b', stripped, re.IGNORECASE) or \
           re.search(r'\bCURSOR\s+FOR\b', stripped, re.IGNORECASE):
            violations.append({
                "rule_id": "SA0007", "severity": "HIGH",
                "line_number": i, "description": "Cursor usage (prefer set-based operations)",
            })

    # ------ Dialect-specific checks ------

    if dialect == "postgresql":
        # SA-PG001: SERIAL instead of GENERATED AS IDENTITY
        for i, line in enumerate(lines, 1):
            stripped = line.split("--")[0]
            if re.search(r'\bSERIAL\b', stripped, re.IGNORECASE) and \
               not re.search(r'GENERATED', stripped, re.IGNORECASE):
                violations.append({
                    "rule_id": "SA-PG001", "severity": "MEDIUM",
                    "line_number": i, "description": "SERIAL type (use GENERATED AS IDENTITY)",
                })

        # SA-PG002: VARCHAR(255) instead of TEXT
        for i, line in enumerate(lines, 1):
            stripped = line.split("--")[0]
            if re.search(r'\bVARCHAR\s*\(\s*255\s*\)', stripped, re.IGNORECASE):
                violations.append({
                    "rule_id": "SA-PG002", "severity": "MEDIUM",
                    "line_number": i, "description": "VARCHAR(255) (use TEXT in PostgreSQL)",
                })

        # SA-PG004: SECURITY DEFINER without search_path
        if re.search(r'SECURITY\s+DEFINER', content, re.IGNORECASE) and \
           not re.search(r'SET\s+search_path', content, re.IGNORECASE):
            violations.append({
                "rule_id": "SA-PG004", "severity": "HIGH",
                "line_number": 0, "description": "SECURITY DEFINER without SET search_path",
            })

    elif dialect == "oracle":
        # SA-ORA001: WHEN OTHERS THEN NULL
        for i, line in enumerate(lines, 1):
            stripped = line.split("--")[0]
            if re.search(r'WHEN\s+OTHERS\s+THEN\s+NULL', stripped, re.IGNORECASE):
                violations.append({
                    "rule_id": "SA-ORA001", "severity": "CRITICAL",
                    "line_number": i, "description": "WHEN OTHERS THEN NULL (swallows exceptions)",
                })

        # SA-ORA002: VARCHAR instead of VARCHAR2
        for i, line in enumerate(lines, 1):
            stripped = line.split("--")[0]
            if re.search(r'\bVARCHAR\b(?!\s*2)', stripped, re.IGNORECASE) and \
               not re.search(r'\bVARCHAR2\b', stripped, re.IGNORECASE):
                violations.append({
                    "rule_id": "SA-ORA002", "severity": "MEDIUM",
                    "line_number": i, "description": "VARCHAR instead of VARCHAR2",
                })

        # SA-ORA004: SELECT INTO without NO_DATA_FOUND handler
        if re.search(r'\bSELECT\b.*\bINTO\b', content, re.IGNORECASE) and \
           not re.search(r'NO_DATA_FOUND', content, re.IGNORECASE):
            violations.append({
                "rule_id": "SA-ORA004", "severity": "HIGH",
                "line_number": 0, "description": "SELECT INTO without NO_DATA_FOUND handler",
            })

        # SA-ORA005: LONG data type
        for i, line in enumerate(lines, 1):
            stripped = line.split("--")[0]
            if re.search(r'\bLONG\b', stripped, re.IGNORECASE) and \
               not re.search(r'\bLONG\s+RAW\b', stripped, re.IGNORECASE):
                violations.append({
                    "rule_id": "SA-ORA005", "severity": "MEDIUM",
                    "line_number": i, "description": "LONG data type (use CLOB instead)",
                })

    elif dialect == "mysql":
        # SA-MY001: MyISAM engine
        for i, line in enumerate(lines, 1):
            stripped = line.split("--")[0]
            if re.search(r'ENGINE\s*=\s*MyISAM', stripped, re.IGNORECASE):
                violations.append({
                    "rule_id": "SA-MY001", "severity": "MEDIUM",
                    "line_number": i, "description": "MyISAM engine (use InnoDB for transactions/FK support)",
                })

        # SA-MY002: FLOAT for currency
        for i, line in enumerate(lines, 1):
            stripped = line.split("--")[0]
            if re.search(r'\bFLOAT\b', stripped, re.IGNORECASE) and \
               re.search(r'(amount|price|cost|total|tax|discount|money|currency)', stripped, re.IGNORECASE):
                violations.append({
                    "rule_id": "SA-MY002", "severity": "MEDIUM",
                    "line_number": i, "description": "FLOAT for currency (use DECIMAL for money)",
                })

        # SA-MY004: ENUM type
        for i, line in enumerate(lines, 1):
            stripped = line.split("--")[0]
            if re.search(r'\bENUM\s*\(', stripped, re.IGNORECASE):
                violations.append({
                    "rule_id": "SA-MY004", "severity": "MEDIUM",
                    "line_number": i, "description": "ENUM type (use lookup table for changeable values)",
                })

    return violations


def check_file_for_patterns(file_path: str) -> List[Dict]:
    """
    Pattern matcher for Python/Node/C# application files.
    In practice, the AI agent would do this analysis.
    """
    violations = []

    with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()
        lines = content.split("\n")

    ext = Path(file_path).suffix

    # Check for SQL injection patterns
    sql_injection_patterns = [
        (r'f".*SELECT.*\{', "f-string SQL"),
        (r'f".*INSERT.*\{', "f-string SQL"),
        (r'f".*UPDATE.*\{', "f-string SQL"),
        (r'f".*DELETE.*\{', "f-string SQL"),
        (r'\+ *@?\w+ *\+.*SELECT', "concatenation SQL"),
        (r'`SELECT.*\$\{', "template literal SQL"),
        (r'\$".*SELECT.*\{', "interpolated string SQL"),
    ]

    for i, line in enumerate(lines, 1):
        for pattern, desc in sql_injection_patterns:
            if re.search(pattern, line, re.IGNORECASE):
                violations.append({
                    "rule_id": "SA0002",
                    "severity": "CRITICAL",
                    "line_number": i,
                    "description": f"Potential SQL injection: {desc}",
                })

    # Check for SELECT *
    select_star_pattern = r"SELECT\s+\*\s+FROM"
    for i, line in enumerate(lines, 1):
        if re.search(select_star_pattern, line, re.IGNORECASE):
            violations.append({
                "rule_id": "SA0001",
                "severity": "CRITICAL",
                "line_number": i,
                "description": "SELECT * usage",
            })

    # Check for connection per request
    if ext in [".py", ".js", ".cs"]:
        pool_patterns = [
            r"sql\.connect\(",
            r"pyodbc\.connect\(",
            r"new SqlConnection",
        ]
        for i, line in enumerate(lines, 1):
            for pattern in pool_patterns:
                if re.search(pattern, line):
                    violations.append({
                        "rule_id": "connection-pooling",
                        "severity": "HIGH",
                        "line_number": i,
                        "description": "New connection may indicate missing pooling",
                    })

    # Check for missing retry logic
    if ext in [".py", ".js", ".cs"]:
        retry_code_patterns = [
            r"max_retries\s*=",
            r"retryCount\s*[=<>]",
            r"RetryPolicy",
            r"tenacity",
            r"@retry",
            r"exponential_backoff",
            r"for.*retry.*in\s+range",
            r"while.*retry",
        ]
        has_retry_code = any(
            re.search(p, content, re.IGNORECASE) for p in retry_code_patterns
        )
        has_db_connect = bool(
            re.search(r"pyodbc\.connect|sql\.connect|SqlConnection", content)
        )
        if has_db_connect and not has_retry_code:
            violations.append({
                "rule_id": "connection-retry-logic",
                "severity": "HIGH",
                "line_number": 0,
                "description": "No retry logic for transient database failures",
            })

    return violations


# ---------------------------------------------------------------------------
# Test Runner
# ---------------------------------------------------------------------------

def run_tests(file_filter: str = None, dialect_filter: str = None) -> Dict:
    """
    Run all tests and return results.
    Optionally filter to a single file or a single dialect.
    """
    results = {
        "total_files": 0,
        "files_with_violations": 0,
        "total_expected": 0,
        "total_detected": 0,
        "true_positives": 0,
        "false_negatives": 0,
        "by_dialect": {},
        "by_file": {},
    }

    test_app_dir = Path(__file__).parent.parent  # tests/ -> test-app/

    for rel_path, expected_list in EXPECTED_VIOLATIONS.items():
        # Dialect filter
        if dialect_filter:
            file_dialects = set(e.dialect for e in expected_list)
            if dialect_filter not in file_dialects:
                continue

        # File filter
        if file_filter:
            filter_path = Path(file_filter).resolve()
            candidate = (test_app_dir / rel_path).resolve()
            if filter_path != candidate:
                continue

        file_path = test_app_dir / rel_path

        if not file_path.exists():
            print(f"  [skip] File not found: {file_path}")
            continue

        results["total_files"] += 1
        results["total_expected"] += len(expected_list)

        # Detect dialect and run appropriate analyzer
        dialect = detect_dialect(str(file_path))
        dialect_name = dialect.value if dialect != Dialect.UNKNOWN else "mssql"

        if file_path.suffix == ".sql":
            # Prefer the new multi-dialect analyzer for all dialects
            detected = run_sql_analyzer(str(file_path), dialect_name)
            # Fall back to legacy T-SQL analyzer only if the new one returned nothing
            if not detected and dialect_name == "mssql":
                detected = run_tsql_analyzer(str(file_path))
        else:
            detected = check_file_for_patterns(str(file_path))

        results["total_detected"] += len(detected)

        # Compare detected vs expected
        detected_rules = set(v["rule_id"] for v in detected)
        expected_rules = set(e.rule_id for e in expected_list)

        # Direct equivalence map: old SSDT rules → new SA rules
        EQUIV_MAP = {
            "SR0001": "SA0001", "SA0001": "SR0001",
            "SR0005": "SA0004", "SA0004": "SR0005",
            "SR0008": "SA-MS003", "SA-MS003": "SR0008",
            "SR0009": "SA-MS006", "SA-MS006": "SR0009",
            "SR0010": "SA-MS004", "SA-MS004": "SR0010",
            "SR0014": "SA0013", "SA0013": "SR0014",
            "SR0016": "SA-MS005", "SA-MS005": "SR0016",
            "tsql-set-nocount": "SA-MS001", "SA-MS001": "tsql-set-nocount",
            "tsql-error-handling": "SA-MS008", "SA-MS008": "tsql-error-handling",
        }

        # Build full alias expansion for detected rules
        expanded_detected = set(detected_rules)
        for rule in list(detected_rules):
            if rule in RULE_ALIASES:
                expanded_detected.add(RULE_ALIASES[rule])
            if rule in EQUIV_MAP:
                expanded_detected.add(EQUIV_MAP[rule])
            # Also add reverse lookups from aliases
            for k, v in RULE_ALIASES.items():
                if v == rule:
                    expanded_detected.add(k)

        # Second pass: expand equivalences of aliases too
        for rule in list(expanded_detected):
            if rule in EQUIV_MAP:
                expanded_detected.add(EQUIV_MAP[rule])

        matched = expected_rules & expanded_detected
        missed = expected_rules - expanded_detected

        results["true_positives"] += len(matched)
        results["false_negatives"] += len(missed)

        if detected:
            results["files_with_violations"] += 1

        # Track per-dialect stats
        for exp in expected_list:
            d = exp.dialect
            if d not in results["by_dialect"]:
                results["by_dialect"][d] = {
                    "expected": 0, "detected": 0, "matched": 0, "missed": 0
                }
            results["by_dialect"][d]["expected"] += 1

        for d_name in results["by_dialect"]:
            d_expected = [e for e in expected_list if e.dialect == d_name]
            d_expected_rules = set(e.rule_id for e in d_expected)
            d_matched = d_expected_rules & expanded_detected
            d_missed = d_expected_rules - expanded_detected
            results["by_dialect"][d_name]["matched"] += len(d_matched)
            results["by_dialect"][d_name]["missed"] += len(d_missed)

        results["by_file"][rel_path] = {
            "dialect": dialect_name,
            "expected": len(expected_list),
            "detected": len(detected),
            "matched_rules": sorted(matched),
            "missed_rules": sorted(missed),
            "violations": detected,
        }

    return results


def print_report(results: Dict):
    """Print formatted test results."""
    print("\n" + "=" * 80)
    print("SQL VALID8 SKILL - MULTI-DIALECT TEST REPORT")
    print("=" * 80)

    print(f"\nSummary:")
    print(f"   Files analyzed: {results['total_files']}")
    print(f"   Files with violations: {results['files_with_violations']}")
    print(f"   Expected violations: {results['total_expected']}")
    print(f"   Detected violations: {results['total_detected']}")

    total_unique_rules = results["true_positives"] + results["false_negatives"]
    if total_unique_rules > 0:
        accuracy = results["true_positives"] / total_unique_rules * 100
        print(f"   Unique rules expected: {total_unique_rules}")
        print(f"   Rules detected: {results['true_positives']}")
        print(f"   Rules missed: {results['false_negatives']}")
        print(f"   Detection accuracy: {accuracy:.1f}%")

    # Per-dialect breakdown
    if results["by_dialect"]:
        print("\nBy Dialect:")
        for dialect, stats in sorted(results["by_dialect"].items()):
            total = stats["matched"] + stats["missed"]
            pct = (stats["matched"] / total * 100) if total > 0 else 0
            status = "[PASS]" if stats["missed"] == 0 else "[FAIL]"
            print(f"   {status} {dialect:12s}  expected={stats['expected']}  "
                  f"matched={stats['matched']}  missed={stats['missed']}  "
                  f"accuracy={pct:.0f}%")

    # Per-file breakdown
    print("\nBy File:")
    for file_path, file_results in sorted(results["by_file"].items()):
        status = "[PASS]" if not file_results["missed_rules"] else "[FAIL]"
        dialect_tag = f"[{file_results['dialect']}]"
        print(f"\n   {status} {file_path} {dialect_tag}")
        print(f"      Expected: {file_results['expected']}, Detected: {file_results['detected']}")

        if file_results["matched_rules"]:
            print(f"      Matched: {', '.join(file_results['matched_rules'])}")

        if file_results["missed_rules"]:
            print(f"      Missed:  {', '.join(file_results['missed_rules'])}")

    print("\n" + "=" * 80)

    if results["false_negatives"] == 0:
        print("ALL EXPECTED VIOLATIONS DETECTED!")
    else:
        print(f"{results['false_negatives']} violation(s) not detected. Review detection rules.")

    print("=" * 80 + "\n")


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Multi-Dialect Test Runner for SQL Valid8 Skill")
    parser.add_argument("--file", type=str, help="Test specific file")
    parser.add_argument("--dialect", type=str, choices=["mssql", "postgresql", "oracle", "mysql"],
                        help="Run tests for one dialect only")
    parser.add_argument("--report", action="store_true", help="Generate detailed report")
    parser.add_argument("--json", action="store_true", help="Output as JSON")

    args = parser.parse_args()

    results = run_tests(file_filter=args.file, dialect_filter=args.dialect)

    if args.json:
        def make_serializable(obj):
            if isinstance(obj, dict):
                return {k: make_serializable(v) for k, v in obj.items()}
            elif isinstance(obj, list):
                return [make_serializable(item) for item in obj]
            elif isinstance(obj, Enum):
                return obj.value
            return obj

        print(json.dumps(make_serializable(results), indent=2))
    else:
        print_report(results)

    # Exit with error if violations missed
    sys.exit(0 if results["false_negatives"] == 0 else 1)


if __name__ == "__main__":
    main()
