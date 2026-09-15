"""
SQL Helper Module
=================

Comprehensive utilities for database operations, schema management,
query building, and performance analysis.

Supports: PostgreSQL, MySQL, SQLite, SQL Server (MSSQL), Oracle

Usage Examples:
    >>> from sql_helper import DatabaseHelper
    >>> db = DatabaseHelper('postgresql://user:pass@localhost/mydb')
    >>> tables = db.list_tables()
    >>> db.execute_with_timing("SELECT * FROM users LIMIT 10")

    >>> # SQL Server
    >>> db = DatabaseHelper('mssql+pyodbc:///?odbc_connect=Driver={ODBC Driver 18 for SQL Server};Server=myserver;Database=mydb;Trusted_Connection=yes;')
    >>> db.explain_query("SELECT * FROM dbo.Users WHERE Age > 18")

    >>> # Oracle
    >>> db = DatabaseHelper('oracle+oracledb://user:pass@hostname:1521/ORCL')
    >>> db.health_check()
"""

from typing import Dict, List, Optional, Tuple, Any, Union
from dataclasses import dataclass, field
from datetime import datetime
import time
import json
import re
import logging
from contextlib import contextmanager

logger = logging.getLogger(__name__)

try:
    from sqlalchemy import (
        create_engine, inspect, text, MetaData, Table,
        Column, Integer, String, DateTime, Boolean, Float, event
    )
    from sqlalchemy.engine import Engine, Connection
    from sqlalchemy.pool import NullPool, QueuePool
except ImportError:
    raise ImportError(
        "SQLAlchemy is required. Install with: pip install sqlalchemy"
    )

# ---------------------------------------------------------------------------
# Dialect constants
# ---------------------------------------------------------------------------
DIALECT_POSTGRESQL = 'postgresql'
DIALECT_MYSQL = 'mysql'
DIALECT_SQLITE = 'sqlite'
DIALECT_MSSQL = 'mssql'
DIALECT_ORACLE = 'oracle'

SUPPORTED_DIALECTS = (
    DIALECT_POSTGRESQL,
    DIALECT_MYSQL,
    DIALECT_SQLITE,
    DIALECT_MSSQL,
    DIALECT_ORACLE,
)


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------
@dataclass
class QueryResult:
    """Container for query execution results with metadata."""
    rows: List[Dict[str, Any]]
    execution_time: float
    row_count: int
    column_names: List[str]

    def __str__(self) -> str:
        return (
            f"QueryResult(rows={self.row_count}, "
            f"time={self.execution_time:.3f}s)"
        )


@dataclass
class TableInfo:
    """Information about a database table."""
    name: str
    schema: str
    columns: List[Dict[str, Any]]
    indexes: List[Dict[str, Any]]
    row_count: Optional[int] = None

    def __str__(self) -> str:
        return f"Table({self.schema}.{self.name}, {len(self.columns)} columns)"


@dataclass
class IndexRecommendation:
    """Index recommendation based on query analysis."""
    table: str
    columns: List[str]
    reason: str
    estimated_benefit: str
    create_statement: str


@dataclass
class HealthCheckResult:
    """Result of a database health check."""
    dialect: str
    connected: bool
    server_version: str
    current_database: str
    current_user: str
    uptime_seconds: Optional[int] = None
    active_connections: Optional[int] = None
    details: Dict[str, Any] = field(default_factory=dict)

    def __str__(self) -> str:
        status = "OK" if self.connected else "FAILED"
        return (
            f"HealthCheck({self.dialect}): {status} | "
            f"version={self.server_version} | db={self.current_database}"
        )


# ---------------------------------------------------------------------------
# DatabaseHelper  (the main class)
# ---------------------------------------------------------------------------
class DatabaseHelper:
    """
    Comprehensive database helper for common operations across
    PostgreSQL, MySQL, SQLite, SQL Server (MSSQL), and Oracle.

    Examples:
        >>> # Connect to PostgreSQL
        >>> db = DatabaseHelper('postgresql://user:pass@localhost/mydb')

        >>> # Connect to SQL Server
        >>> db = DatabaseHelper(
        ...     'mssql+pyodbc://user:pass@server/db?driver=ODBC+Driver+18+for+SQL+Server'
        ... )

        >>> # Connect to Oracle (thin mode, no Oracle Client needed)
        >>> db = DatabaseHelper('oracle+oracledb://user:pass@host:1521/ORCL')

        >>> # Connect to SQLite with WAL mode
        >>> db = DatabaseHelper('sqlite:///my.db')

        >>> # List all tables
        >>> tables = db.list_tables()

        >>> # Get table schema
        >>> schema = db.get_table_schema('users')

        >>> # Execute with timing
        >>> result = db.execute_with_timing("SELECT COUNT(*) FROM users")
        >>> print(f"Query took {result.execution_time:.2f}s")

        >>> # Explain a query
        >>> plan = db.explain_query("SELECT * FROM users WHERE age > 18")

        >>> # Health check
        >>> hc = db.health_check()
        >>> print(hc)
    """

    def __init__(
        self,
        connection_string: str,
        echo: bool = False,
        pool_size: int = 5
    ):
        """
        Initialize database helper.

        Args:
            connection_string: SQLAlchemy connection string
                Examples:
                    - PostgreSQL: 'postgresql://user:pass@localhost/dbname'
                    - MySQL:      'mysql+pymysql://user:pass@localhost/dbname'
                    - SQLite:     'sqlite:///path/to/database.db'
                    - MSSQL:      'mssql+pyodbc://user:pass@server/db?driver=ODBC+Driver+18+for+SQL+Server'
                    - Oracle:     'oracle+oracledb://user:pass@host:1521/ORCL'
            echo: If True, log all SQL statements
            pool_size: Connection pool size (ignored for SQLite)
        """
        self._connection_string = connection_string
        self.dialect = self._detect_dialect(connection_string)

        engine_kwargs: Dict[str, Any] = {"echo": echo}

        if self.dialect == DIALECT_SQLITE:
            engine_kwargs["poolclass"] = NullPool
        else:
            engine_kwargs["pool_size"] = pool_size
            engine_kwargs["max_overflow"] = 10
            engine_kwargs["pool_pre_ping"] = True
            engine_kwargs["pool_recycle"] = 3600

        self.engine = create_engine(connection_string, **engine_kwargs)

        # SQLite PRAGMA optimisations applied on every new connection
        if self.dialect == DIALECT_SQLITE:
            @event.listens_for(self.engine, "connect")
            def _set_sqlite_pragmas(dbapi_conn, connection_record):
                cursor = dbapi_conn.cursor()
                cursor.execute("PRAGMA journal_mode=WAL")
                cursor.execute("PRAGMA foreign_keys=ON")
                cursor.execute("PRAGMA busy_timeout=5000")
                cursor.execute("PRAGMA synchronous=NORMAL")
                cursor.execute("PRAGMA cache_size=-64000")  # 64 MB
                cursor.execute("PRAGMA temp_store=MEMORY")
                cursor.close()

        self.metadata = MetaData()

    # ------------------------------------------------------------------
    # Dialect detection
    # ------------------------------------------------------------------
    @staticmethod
    def _detect_dialect(connection_string: str) -> str:
        """Detect database dialect from connection string.

        Recognises standard SQLAlchemy URL prefixes as well as common
        shorthand forms.
        """
        cs = connection_string.lower().strip()
        if cs.startswith('postgresql') or cs.startswith('postgres'):
            return DIALECT_POSTGRESQL
        elif cs.startswith('mysql'):
            return DIALECT_MYSQL
        elif cs.startswith('sqlite'):
            return DIALECT_SQLITE
        elif cs.startswith('mssql') or cs.startswith('mssql+pyodbc'):
            return DIALECT_MSSQL
        elif cs.startswith('oracle'):
            return DIALECT_ORACLE
        else:
            raise ValueError(
                f"Unsupported dialect in connection string: {connection_string}\n"
                f"Supported prefixes: {', '.join(SUPPORTED_DIALECTS)}"
            )

    def _masked_connection_string(self) -> str:
        """Return connection string with password masked for safe logging."""
        import re as _re
        masked = _re.sub(
            r'(://[^:]+:)[^@]+(@)',
            r'\1****\2',
            self._connection_string,
        )
        return masked

    # ------------------------------------------------------------------
    # Connection context manager
    # ------------------------------------------------------------------
    @contextmanager
    def connection(self):
        """
        Context manager for database connections.

        Example:
            >>> with db.connection() as conn:
            ...     result = conn.execute(text("SELECT 1"))
        """
        conn = self.engine.connect()
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    # ------------------------------------------------------------------
    # Raw connection (for driver-level operations)
    # ------------------------------------------------------------------
    @contextmanager
    def raw_connection(self):
        """
        Context manager returning the underlying DBAPI connection.

        Useful for driver-specific operations such as pyodbc
        fast_executemany or oracledb batch operations.

        Example:
            >>> with db.raw_connection() as raw_conn:
            ...     cursor = raw_conn.cursor()
            ...     cursor.execute("SELECT 1")
        """
        raw = self.engine.raw_connection()
        try:
            yield raw
            raw.commit()
        except Exception:
            raw.rollback()
            raise
        finally:
            raw.close()

    # ------------------------------------------------------------------
    # Execute with timing
    # ------------------------------------------------------------------
    def execute_with_timing(
        self,
        query: str,
        params: Optional[Dict[str, Any]] = None
    ) -> QueryResult:
        """
        Execute query and return results with timing information.

        Args:
            query: SQL query to execute
            params: Optional parameters for parameterized queries

        Returns:
            QueryResult with rows, timing, and metadata

        Example:
            >>> result = db.execute_with_timing(
            ...     "SELECT * FROM users WHERE age > :min_age",
            ...     {"min_age": 18}
            ... )
            >>> print(f"Found {result.row_count} users in {result.execution_time:.2f}s")
        """
        start_time = time.time()

        with self.connection() as conn:
            if params:
                result = conn.execute(text(query), params)
            else:
                result = conn.execute(text(query))

            rows = []
            column_names = list(result.keys()) if result.keys() else []

            for row in result:
                rows.append(dict(row._mapping))

        execution_time = time.time() - start_time

        return QueryResult(
            rows=rows,
            execution_time=execution_time,
            row_count=len(rows),
            column_names=column_names
        )

    # ------------------------------------------------------------------
    # list_tables  (dialect-aware)
    # ------------------------------------------------------------------
    def list_tables(self, schema: Optional[str] = None) -> List[str]:
        """
        List all tables in the database.

        Uses dialect-specific system catalog queries when a schema is not
        provided, falling back to SQLAlchemy's inspector as a safety net.

        Args:
            schema: Optional schema name.  Defaults vary by dialect:
                    PostgreSQL = 'public', MSSQL = 'dbo',
                    Oracle = current user, MySQL/SQLite = current database.

        Returns:
            List of table names
        """
        # Fast-path: use native catalog queries for richer control
        try:
            if self.dialect == DIALECT_MSSQL:
                effective_schema = schema or 'dbo'
                result = self.execute_with_timing(
                    "SELECT t.name "
                    "FROM sys.tables t "
                    "INNER JOIN sys.schemas s ON t.schema_id = s.schema_id "
                    "WHERE s.name = :schema "
                    "ORDER BY t.name",
                    {"schema": effective_schema}
                )
                return [row['name'] for row in result.rows]

            elif self.dialect == DIALECT_ORACLE:
                if schema:
                    result = self.execute_with_timing(
                        "SELECT table_name FROM all_tables "
                        "WHERE owner = :owner ORDER BY table_name",
                        {"owner": schema.upper()}
                    )
                else:
                    result = self.execute_with_timing(
                        "SELECT table_name FROM user_tables ORDER BY table_name"
                    )
                return [row['table_name'] for row in result.rows]

            elif self.dialect == DIALECT_SQLITE:
                result = self.execute_with_timing(
                    "SELECT name FROM sqlite_master "
                    "WHERE type = 'table' AND name NOT LIKE 'sqlite_%' "
                    "ORDER BY name"
                )
                return [row['name'] for row in result.rows]

            elif self.dialect == DIALECT_MYSQL:
                if schema:
                    result = self.execute_with_timing(
                        "SELECT table_name FROM information_schema.tables "
                        "WHERE table_schema = :schema AND table_type = 'BASE TABLE' "
                        "ORDER BY table_name",
                        {"schema": schema}
                    )
                    return [row['table_name'] for row in result.rows]
                else:
                    result = self.execute_with_timing(
                        "SELECT table_name FROM information_schema.tables "
                        "WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE' "
                        "ORDER BY table_name"
                    )
                    return [row['table_name'] for row in result.rows]

            elif self.dialect == DIALECT_POSTGRESQL:
                effective_schema = schema or 'public'
                result = self.execute_with_timing(
                    "SELECT tablename FROM pg_catalog.pg_tables "
                    "WHERE schemaname = :schema ORDER BY tablename",
                    {"schema": effective_schema}
                )
                return [row['tablename'] for row in result.rows]

        except Exception as exc:
            logger.debug(
                "Native list_tables failed (%s), falling back to inspector: %s",
                self.dialect, exc
            )

        # Fallback: SQLAlchemy inspector
        inspector = inspect(self.engine)
        return inspector.get_table_names(schema=schema)

    # ------------------------------------------------------------------
    # get_table_schema  (dialect-aware)
    # ------------------------------------------------------------------
    def get_table_schema(
        self,
        table_name: str,
        schema: Optional[str] = None
    ) -> TableInfo:
        """
        Get comprehensive information about a table.

        Uses native system catalog queries per dialect for best fidelity,
        with SQLAlchemy inspector as a fallback.

        Args:
            table_name: Name of the table
            schema: Optional schema name

        Returns:
            TableInfo object with columns, indexes, and metadata
        """
        columns: List[Dict[str, Any]] = []
        indexes: List[Dict[str, Any]] = []

        try:
            if self.dialect == DIALECT_MSSQL:
                columns, indexes = self._schema_mssql(table_name, schema)
            elif self.dialect == DIALECT_ORACLE:
                columns, indexes = self._schema_oracle(table_name, schema)
            elif self.dialect == DIALECT_SQLITE:
                columns, indexes = self._schema_sqlite(table_name)
            else:
                columns, indexes = self._schema_via_inspector(table_name, schema)
        except Exception as exc:
            logger.debug(
                "Native schema introspection failed (%s), using inspector: %s",
                self.dialect, exc
            )
            columns, indexes = self._schema_via_inspector(table_name, schema)

        # Row count (best effort)
        row_count = self._safe_row_count(table_name, schema)

        default_schema_map = {
            DIALECT_POSTGRESQL: 'public',
            DIALECT_MSSQL: 'dbo',
            DIALECT_ORACLE: 'USER',
            DIALECT_MYSQL: 'default',
            DIALECT_SQLITE: 'main',
        }

        return TableInfo(
            name=table_name,
            schema=schema or default_schema_map.get(self.dialect, 'public'),
            columns=columns,
            indexes=indexes,
            row_count=row_count
        )

    # -- MSSQL schema introspection --
    def _schema_mssql(
        self, table_name: str, schema: Optional[str]
    ) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
        effective_schema = schema or 'dbo'

        col_result = self.execute_with_timing(
            "SELECT "
            "  c.name AS column_name, "
            "  TYPE_NAME(c.user_type_id) AS data_type, "
            "  c.max_length, "
            "  c.precision, "
            "  c.scale, "
            "  c.is_nullable, "
            "  c.is_identity, "
            "  dc.definition AS default_value, "
            "  CASE WHEN ic.column_id IS NOT NULL THEN 1 ELSE 0 END AS is_primary_key "
            "FROM sys.columns c "
            "INNER JOIN sys.tables t ON c.object_id = t.object_id "
            "INNER JOIN sys.schemas s ON t.schema_id = s.schema_id "
            "LEFT JOIN sys.default_constraints dc ON c.default_object_id = dc.object_id "
            "LEFT JOIN sys.index_columns ic "
            "  ON ic.object_id = c.object_id "
            "  AND ic.column_id = c.column_id "
            "  AND ic.index_id = ( "
            "      SELECT i.index_id FROM sys.indexes i "
            "      WHERE i.object_id = t.object_id AND i.is_primary_key = 1 "
            "  ) "
            "WHERE t.name = :table AND s.name = :schema "
            "ORDER BY c.column_id",
            {"table": table_name, "schema": effective_schema}
        )
        columns = []
        for r in col_result.rows:
            type_str = r['data_type']
            if r.get('max_length') and r['data_type'] in (
                'varchar', 'nvarchar', 'char', 'nchar', 'varbinary'
            ):
                ml = r['max_length']
                if r['data_type'].startswith('n'):
                    ml = ml // 2  # nvarchar stores 2 bytes per char
                type_str = f"{r['data_type']}({ml if ml > 0 else 'max'})"
            elif r.get('precision') and r['data_type'] in ('decimal', 'numeric'):
                type_str = f"{r['data_type']}({r['precision']},{r['scale']})"
            columns.append({
                'name': r['column_name'],
                'type': type_str,
                'nullable': bool(r['is_nullable']),
                'default': r.get('default_value'),
                'primary_key': bool(r.get('is_primary_key')),
                'is_identity': bool(r.get('is_identity')),
            })

        idx_result = self.execute_with_timing(
            "SELECT "
            "  i.name AS index_name, "
            "  i.is_unique, "
            "  i.is_primary_key, "
            "  i.type_desc, "
            "  STRING_AGG(c.name, ',') WITHIN GROUP (ORDER BY ic.key_ordinal) AS columns "
            "FROM sys.indexes i "
            "INNER JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id "
            "INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id "
            "INNER JOIN sys.tables t ON i.object_id = t.object_id "
            "INNER JOIN sys.schemas s ON t.schema_id = s.schema_id "
            "WHERE t.name = :table AND s.name = :schema AND i.name IS NOT NULL "
            "GROUP BY i.name, i.is_unique, i.is_primary_key, i.type_desc "
            "ORDER BY i.name",
            {"table": table_name, "schema": effective_schema}
        )
        indexes = []
        for r in idx_result.rows:
            indexes.append({
                'name': r['index_name'],
                'columns': r['columns'].split(',') if r.get('columns') else [],
                'unique': bool(r['is_unique']),
                'primary_key': bool(r.get('is_primary_key')),
                'type': r.get('type_desc', ''),
            })

        return columns, indexes

    # -- Oracle schema introspection --
    def _schema_oracle(
        self, table_name: str, schema: Optional[str]
    ) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
        upper_table = table_name.upper()

        if schema:
            owner_filter = "AND atc.owner = :owner"
            col_params: Dict[str, Any] = {
                "table": upper_table, "owner": schema.upper()
            }
        else:
            owner_filter = ""
            col_params = {"table": upper_table}

        col_result = self.execute_with_timing(
            "SELECT "
            "  atc.column_name, "
            "  atc.data_type, "
            "  atc.data_length, "
            "  atc.data_precision, "
            "  atc.data_scale, "
            "  atc.nullable, "
            "  atc.data_default, "
            "  CASE WHEN acc.column_name IS NOT NULL THEN 1 ELSE 0 END AS is_pk "
            "FROM all_tab_columns atc "
            "LEFT JOIN all_constraints ac "
            "  ON ac.table_name = atc.table_name "
            "  AND ac.owner = atc.owner "
            "  AND ac.constraint_type = 'P' "
            "LEFT JOIN all_cons_columns acc "
            "  ON acc.constraint_name = ac.constraint_name "
            "  AND acc.owner = ac.owner "
            "  AND acc.column_name = atc.column_name "
            f"WHERE atc.table_name = :table {owner_filter} "
            "ORDER BY atc.column_id",
            col_params
        )
        columns = []
        for r in col_result.rows:
            dt = r['data_type']
            if dt in ('VARCHAR2', 'CHAR', 'NVARCHAR2', 'NCHAR', 'RAW'):
                dt = f"{dt}({r['data_length']})"
            elif dt == 'NUMBER':
                prec = r.get('data_precision')
                scale = r.get('data_scale')
                if prec is not None:
                    dt = f"NUMBER({prec},{scale or 0})"
            columns.append({
                'name': r['column_name'],
                'type': dt,
                'nullable': r['nullable'] == 'Y',
                'default': r.get('data_default'),
                'primary_key': bool(r.get('is_pk')),
            })

        if schema:
            idx_owner_filter = "AND ai.owner = :owner"
            idx_params: Dict[str, Any] = {
                "table": upper_table, "owner": schema.upper()
            }
        else:
            idx_owner_filter = ""
            idx_params = {"table": upper_table}

        idx_result = self.execute_with_timing(
            "SELECT "
            "  ai.index_name, "
            "  ai.uniqueness, "
            "  ai.index_type, "
            "  LISTAGG(aic.column_name, ',') WITHIN GROUP (ORDER BY aic.column_position) AS columns "
            "FROM all_indexes ai "
            "INNER JOIN all_ind_columns aic "
            "  ON ai.index_name = aic.index_name AND ai.owner = aic.index_owner "
            f"WHERE ai.table_name = :table {idx_owner_filter} "
            "GROUP BY ai.index_name, ai.uniqueness, ai.index_type "
            "ORDER BY ai.index_name",
            idx_params
        )
        indexes = []
        for r in idx_result.rows:
            indexes.append({
                'name': r['index_name'],
                'columns': r['columns'].split(',') if r.get('columns') else [],
                'unique': r['uniqueness'] == 'UNIQUE',
                'type': r.get('index_type', ''),
            })

        return columns, indexes

    # -- SQLite schema introspection --
    def _schema_sqlite(
        self, table_name: str
    ) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
        safe_table = self._quote_identifier(table_name, self.dialect)
        col_result = self.execute_with_timing(
            f"PRAGMA table_info({safe_table})"
        )
        columns = []
        for r in col_result.rows:
            columns.append({
                'name': r['name'],
                'type': r['type'] or 'TEXT',
                'nullable': not bool(r['notnull']),
                'default': r['dflt_value'],
                'primary_key': bool(r['pk']),
            })

        idx_list_result = self.execute_with_timing(
            f"PRAGMA index_list({safe_table})"
        )
        indexes = []
        for idx_row in idx_list_result.rows:
            idx_name = idx_row['name']
            safe_idx = self._quote_identifier(idx_name, self.dialect)
            idx_info = self.execute_with_timing(
                f"PRAGMA index_info({safe_idx})"
            )
            idx_columns = [c['name'] for c in idx_info.rows]
            indexes.append({
                'name': idx_name,
                'columns': idx_columns,
                'unique': bool(idx_row['unique']),
            })

        return columns, indexes

    # -- Fallback via SQLAlchemy inspector (PostgreSQL, MySQL, others) --
    def _schema_via_inspector(
        self, table_name: str, schema: Optional[str]
    ) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
        inspector = inspect(self.engine)

        columns = []
        for col in inspector.get_columns(table_name, schema=schema):
            columns.append({
                'name': col['name'],
                'type': str(col['type']),
                'nullable': col['nullable'],
                'default': col.get('default'),
                'primary_key': col.get('primary_key', False),
            })

        indexes = []
        for idx in inspector.get_indexes(table_name, schema=schema):
            indexes.append({
                'name': idx['name'],
                'columns': idx['column_names'],
                'unique': idx['unique'],
            })

        return columns, indexes

    # -- safe row count helper --
    def _safe_row_count(
        self, table_name: str, schema: Optional[str]
    ) -> Optional[int]:
        try:
            qualified = table_name
            if schema:
                qualified = f"{schema}.{table_name}"
            safe_qualified = self._quote_identifier(qualified, self.dialect)

            result = self.execute_with_timing(
                f"SELECT COUNT(*) AS cnt FROM {safe_qualified}"
            )
            return result.rows[0]['cnt']
        except Exception:
            return None

    # ------------------------------------------------------------------
    # analyze_indexes  (dialect-aware)
    # ------------------------------------------------------------------
    def analyze_indexes(
        self,
        table_name: str,
        schema: Optional[str] = None
    ) -> List[IndexRecommendation]:
        """
        Analyze table and recommend indexes based on common patterns.

        Dialect-aware: uses system catalog queries for MSSQL and Oracle to
        detect missing indexes, unused indexes, and foreign keys without
        supporting indexes.

        Args:
            table_name: Table to analyze
            schema: Optional schema name

        Returns:
            List of index recommendations
        """
        recommendations: List[IndexRecommendation] = []
        table_info = self.get_table_schema(table_name, schema)
        existing_indexes = {
            tuple(idx['columns']) for idx in table_info.indexes
        }

        quote_char = self._identifier_quote_char()

        # ---- Generic heuristics (all dialects) ----
        for col in table_info.columns:
            col_name = col['name']

            # Foreign key pattern (ends with _id)
            if col_name.endswith('_id') and (col_name,) not in existing_indexes:
                recommendations.append(IndexRecommendation(
                    table=table_name,
                    columns=[col_name],
                    reason=f"Foreign key column '{col_name}' should have an index for JOIN performance",
                    estimated_benefit="High - improves JOIN performance",
                    create_statement=(
                        f"CREATE INDEX {quote_char}idx_{table_name}_{col_name}{quote_char} "
                        f"ON {table_name}({col_name});"
                    )
                ))

            # Timestamp / date columns
            if any(kw in col_name.lower() for kw in ('timestamp', 'date', 'created', 'updated')):
                if (col_name,) not in existing_indexes:
                    recommendations.append(IndexRecommendation(
                        table=table_name,
                        columns=[col_name],
                        reason=f"Temporal column '{col_name}' frequently used in WHERE/ORDER BY",
                        estimated_benefit="Medium - improves time-range queries",
                        create_statement=(
                            f"CREATE INDEX {quote_char}idx_{table_name}_{col_name}{quote_char} "
                            f"ON {table_name}({col_name});"
                        )
                    ))

            # Status / type columns (low cardinality, but common filters)
            if any(kw in col_name.lower() for kw in ('status', 'type', 'state', 'category')):
                if (col_name,) not in existing_indexes:
                    recommendations.append(IndexRecommendation(
                        table=table_name,
                        columns=[col_name],
                        reason=f"Filter column '{col_name}' commonly appears in WHERE clauses",
                        estimated_benefit="Medium - consider filtered/partial index if low cardinality",
                        create_statement=(
                            f"CREATE INDEX {quote_char}idx_{table_name}_{col_name}{quote_char} "
                            f"ON {table_name}({col_name});"
                        )
                    ))

        # ---- MSSQL: missing index DMVs ----
        if self.dialect == DIALECT_MSSQL:
            try:
                missing = self.execute_with_timing(
                    "SELECT TOP 5 "
                    "  mid.equality_columns, "
                    "  mid.inequality_columns, "
                    "  mid.included_columns, "
                    "  CAST(migs.avg_user_impact AS DECIMAL(5,2)) AS avg_impact, "
                    "  migs.user_seeks "
                    "FROM sys.dm_db_missing_index_details mid "
                    "INNER JOIN sys.dm_db_missing_index_groups mig "
                    "  ON mid.index_handle = mig.index_handle "
                    "INNER JOIN sys.dm_db_missing_index_group_stats migs "
                    "  ON mig.index_group_handle = migs.group_handle "
                    "WHERE mid.statement LIKE :pattern "
                    "ORDER BY migs.avg_user_impact * migs.user_seeks DESC",
                    {"pattern": f"%{table_name}%"}
                )
                for r in missing.rows:
                    eq_cols = r.get('equality_columns', '') or ''
                    ineq_cols = r.get('inequality_columns', '') or ''
                    incl_cols = r.get('included_columns', '') or ''
                    key_cols = ', '.join(
                        c.strip().strip('[]') for c in
                        f"{eq_cols}, {ineq_cols}".split(',') if c.strip()
                    )
                    include_part = ''
                    if incl_cols:
                        include_part = f" INCLUDE ({incl_cols})"
                    if key_cols:
                        recommendations.append(IndexRecommendation(
                            table=table_name,
                            columns=key_cols.split(', '),
                            reason=(
                                f"SQL Server missing index DMV: avg_impact={r['avg_impact']}%, "
                                f"user_seeks={r['user_seeks']}"
                            ),
                            estimated_benefit=f"High - {r['avg_impact']}% estimated improvement",
                            create_statement=(
                                f"CREATE NONCLUSTERED INDEX [idx_{table_name}_dmv_suggestion] "
                                f"ON {table_name}({key_cols}){include_part};"
                            )
                        ))
            except Exception as exc:
                logger.debug("MSSQL missing index DMV query failed: %s", exc)

        return recommendations

    def _identifier_quote_char(self) -> str:
        """Return the identifier quoting character for the current dialect."""
        if self.dialect == DIALECT_MSSQL:
            return ''  # MSSQL uses [] but we handle manually
        elif self.dialect == DIALECT_MYSQL:
            return '`'
        elif self.dialect == DIALECT_ORACLE:
            return '"'
        else:
            return ''

    @staticmethod
    def _quote_identifier(name: str, dialect: str = "") -> str:
        """Safely quote a SQL identifier to prevent injection.

        Validates that the name contains only safe characters (alphanumeric,
        underscore, dot for schema.table) and raises ValueError otherwise.
        Then wraps it in dialect-appropriate quoting.
        """
        import re as _re
        if not _re.match(r'^[A-Za-z_][A-Za-z0-9_.]*$', name):
            raise ValueError(
                f"Unsafe identifier rejected: {name!r}. "
                "Identifiers must be alphanumeric with underscores/dots only."
            )
        if dialect == DIALECT_MSSQL:
            # Split on dot for schema.table, quote each part
            return ".".join(f"[{part}]" for part in name.split("."))
        elif dialect == DIALECT_MYSQL:
            return ".".join(f"`{part}`" for part in name.split("."))
        elif dialect == DIALECT_ORACLE:
            return ".".join(f'"{part}"' for part in name.split("."))
        else:
            return ".".join(f'"{part}"' for part in name.split("."))

    # ------------------------------------------------------------------
    # explain_query  (dialect-aware)
    # ------------------------------------------------------------------
    def explain_query(self, query: str) -> Dict[str, Any]:
        """
        Get query execution plan for any supported dialect.

        PostgreSQL:  EXPLAIN (FORMAT JSON, ANALYZE, BUFFERS)
        MySQL:       EXPLAIN FORMAT=JSON
        SQLite:      EXPLAIN QUERY PLAN
        MSSQL:       SET SHOWPLAN_XML ON (estimated plan)
        Oracle:      EXPLAIN PLAN FOR + DBMS_XPLAN.DISPLAY

        Args:
            query: SQL query to analyze (SELECT, INSERT, UPDATE, DELETE)

        Returns:
            Dictionary with execution plan details
        """
        if self.dialect == DIALECT_POSTGRESQL:
            return self._explain_postgresql(query)
        elif self.dialect == DIALECT_MYSQL:
            return self._explain_mysql(query)
        elif self.dialect == DIALECT_SQLITE:
            return self._explain_sqlite(query)
        elif self.dialect == DIALECT_MSSQL:
            return self._explain_mssql(query)
        elif self.dialect == DIALECT_ORACLE:
            return self._explain_oracle(query)
        else:
            raise ValueError(f"explain_query not implemented for {self.dialect}")

    def _explain_postgresql(self, query: str) -> Dict[str, Any]:
        result = self.execute_with_timing(f"EXPLAIN (FORMAT JSON) {query}")
        if result.rows:
            first = result.rows[0]
            # PostgreSQL returns the plan in the first column
            plan_key = result.column_names[0] if result.column_names else None
            if plan_key and plan_key in first:
                plan_data = first[plan_key]
                if isinstance(plan_data, str):
                    plan_data = json.loads(plan_data)
                return {"dialect": "postgresql", "plan": plan_data}
            return {"dialect": "postgresql", "plan": first}
        return {"dialect": "postgresql", "plan": None}

    def _explain_mysql(self, query: str) -> Dict[str, Any]:
        try:
            result = self.execute_with_timing(f"EXPLAIN FORMAT=JSON {query}")
            if result.rows:
                first = result.rows[0]
                plan_key = result.column_names[0] if result.column_names else None
                if plan_key and plan_key in first:
                    plan_data = first[plan_key]
                    if isinstance(plan_data, str):
                        plan_data = json.loads(plan_data)
                    return {"dialect": "mysql", "plan": plan_data}
                return {"dialect": "mysql", "plan": first}
        except Exception:
            # Fallback: plain EXPLAIN
            result = self.execute_with_timing(f"EXPLAIN {query}")
            return {"dialect": "mysql", "plan": result.rows}
        return {"dialect": "mysql", "plan": None}

    def _explain_sqlite(self, query: str) -> Dict[str, Any]:
        result = self.execute_with_timing(f"EXPLAIN QUERY PLAN {query}")
        plan_lines = []
        for row in result.rows:
            plan_lines.append({
                'id': row.get('id'),
                'parent': row.get('parent'),
                'detail': row.get('detail'),
            })
        return {"dialect": "sqlite", "plan": plan_lines}

    def _explain_mssql(self, query: str) -> Dict[str, Any]:
        """
        Retrieve the estimated XML execution plan from SQL Server.

        Uses SET SHOWPLAN_XML ON which returns the plan as XML without
        actually executing the query.  We also attempt to collect
        SET STATISTICS IO output when possible.
        """
        plan_xml = None
        io_stats: List[str] = []

        # --- Estimated XML plan ---
        try:
            with self.raw_connection() as raw_conn:
                cursor = raw_conn.cursor()
                cursor.execute("SET SHOWPLAN_XML ON")
                cursor.execute(query)
                row = cursor.fetchone()
                if row:
                    plan_xml = row[0]
                cursor.execute("SET SHOWPLAN_XML OFF")
                cursor.close()
        except Exception as exc:
            logger.debug("SHOWPLAN_XML failed: %s", exc)
            # Fallback: try SET SHOWPLAN_ALL ON
            try:
                with self.raw_connection() as raw_conn:
                    cursor = raw_conn.cursor()
                    cursor.execute("SET SHOWPLAN_ALL ON")
                    cursor.execute(query)
                    rows = cursor.fetchall()
                    plan_xml = "\n".join(str(r) for r in rows) if rows else None
                    cursor.execute("SET SHOWPLAN_ALL OFF")
                    cursor.close()
            except Exception as exc2:
                logger.debug("SHOWPLAN_ALL also failed: %s", exc2)

        # --- IO statistics (runs the query) ---
        try:
            with self.raw_connection() as raw_conn:
                cursor = raw_conn.cursor()
                cursor.execute("SET STATISTICS IO ON")
                cursor.execute(query)
                # Consume result set
                try:
                    cursor.fetchall()
                except Exception:
                    pass
                cursor.execute("SET STATISTICS IO OFF")
                # pyodbc puts messages in cursor.messages or connection.messages
                if hasattr(cursor, 'messages'):
                    for msg in (cursor.messages or []):
                        io_stats.append(str(msg))
                cursor.close()
        except Exception as exc:
            logger.debug("STATISTICS IO failed: %s", exc)

        return {
            "dialect": "mssql",
            "plan_xml": plan_xml,
            "io_statistics": io_stats,
        }

    def _explain_oracle(self, query: str) -> Dict[str, Any]:
        """
        Oracle EXPLAIN PLAN FOR + DBMS_XPLAN.DISPLAY.

        Uses a unique statement_id per call to avoid collisions in
        the shared PLAN_TABLE.
        """
        import hashlib
        stmt_id = "PY_" + hashlib.md5(
            f"{query}{time.time()}".encode()
        ).hexdigest()[:12]

        plan_lines: List[str] = []
        try:
            with self.connection() as conn:
                conn.execute(text(
                    f"EXPLAIN PLAN SET STATEMENT_ID = :sid FOR {query}"
                ), {"sid": stmt_id})

                result = conn.execute(text(
                    "SELECT plan_table_output FROM TABLE("
                    "DBMS_XPLAN.DISPLAY('PLAN_TABLE', :sid, 'ALL'))",
                ), {"sid": stmt_id})

                for row in result:
                    line = row._mapping.get('plan_table_output', '')
                    if line is not None:
                        plan_lines.append(str(line))

                # Clean up
                conn.execute(text(
                    "DELETE FROM plan_table WHERE statement_id = :sid"
                ), {"sid": stmt_id})
        except Exception as exc:
            logger.debug("Oracle EXPLAIN PLAN failed: %s", exc)
            plan_lines = [f"Error: {exc}"]

        return {
            "dialect": "oracle",
            "plan": plan_lines,
        }

    # ------------------------------------------------------------------
    # health_check  (per dialect)
    # ------------------------------------------------------------------
    def health_check(self) -> HealthCheckResult:
        """
        Perform a dialect-specific database health check.

        Returns server version, current database, user, uptime,
        and active connection count (where available).

        Returns:
            HealthCheckResult dataclass
        """
        if self.dialect == DIALECT_POSTGRESQL:
            return self._health_postgresql()
        elif self.dialect == DIALECT_MYSQL:
            return self._health_mysql()
        elif self.dialect == DIALECT_SQLITE:
            return self._health_sqlite()
        elif self.dialect == DIALECT_MSSQL:
            return self._health_mssql()
        elif self.dialect == DIALECT_ORACLE:
            return self._health_oracle()
        else:
            raise ValueError(f"health_check not implemented for {self.dialect}")

    def _health_postgresql(self) -> HealthCheckResult:
        try:
            r = self.execute_with_timing(
                "SELECT "
                "  version() AS server_version, "
                "  current_database() AS current_db, "
                "  current_user AS current_user, "
                "  EXTRACT(EPOCH FROM (now() - pg_postmaster_start_time()))::int AS uptime_seconds, "
                "  (SELECT count(*) FROM pg_stat_activity) AS active_connections"
            )
            row = r.rows[0] if r.rows else {}
            return HealthCheckResult(
                dialect=DIALECT_POSTGRESQL,
                connected=True,
                server_version=row.get('server_version', 'unknown'),
                current_database=row.get('current_db', 'unknown'),
                current_user=row.get('current_user', 'unknown'),
                uptime_seconds=row.get('uptime_seconds'),
                active_connections=row.get('active_connections'),
                details={"execution_time": r.execution_time},
            )
        except Exception as exc:
            return HealthCheckResult(
                dialect=DIALECT_POSTGRESQL, connected=False,
                server_version='', current_database='', current_user='',
                details={"error": str(exc)},
            )

    def _health_mysql(self) -> HealthCheckResult:
        try:
            r = self.execute_with_timing(
                "SELECT "
                "  VERSION() AS server_version, "
                "  DATABASE() AS current_db, "
                "  USER() AS current_user, "
                "  VARIABLE_VALUE AS uptime "
                "FROM performance_schema.global_status "
                "WHERE VARIABLE_NAME = 'Uptime'"
            )
            row = r.rows[0] if r.rows else {}

            conn_result = self.execute_with_timing(
                "SELECT COUNT(*) AS cnt FROM information_schema.processlist"
            )
            active = conn_result.rows[0]['cnt'] if conn_result.rows else None

            return HealthCheckResult(
                dialect=DIALECT_MYSQL,
                connected=True,
                server_version=row.get('server_version', 'unknown'),
                current_database=row.get('current_db', 'unknown'),
                current_user=row.get('current_user', 'unknown'),
                uptime_seconds=int(row.get('uptime', 0)) if row.get('uptime') else None,
                active_connections=active,
                details={"execution_time": r.execution_time},
            )
        except Exception:
            # Fallback: simpler query if performance_schema is not accessible
            try:
                r = self.execute_with_timing(
                    "SELECT VERSION() AS v, DATABASE() AS d, USER() AS u"
                )
                row = r.rows[0] if r.rows else {}
                return HealthCheckResult(
                    dialect=DIALECT_MYSQL, connected=True,
                    server_version=row.get('v', 'unknown'),
                    current_database=row.get('d', 'unknown'),
                    current_user=row.get('u', 'unknown'),
                    details={"execution_time": r.execution_time},
                )
            except Exception as exc:
                return HealthCheckResult(
                    dialect=DIALECT_MYSQL, connected=False,
                    server_version='', current_database='', current_user='',
                    details={"error": str(exc)},
                )

    def _health_sqlite(self) -> HealthCheckResult:
        try:
            r = self.execute_with_timing("SELECT sqlite_version() AS v")
            version = r.rows[0]['v'] if r.rows else 'unknown'

            # Journal mode
            jm = self.execute_with_timing("PRAGMA journal_mode")
            journal = jm.rows[0].get('journal_mode', 'unknown') if jm.rows else 'unknown'

            # Integrity check (quick)
            ic = self.execute_with_timing("PRAGMA quick_check(1)")
            integrity = ic.rows[0] if ic.rows else {}

            return HealthCheckResult(
                dialect=DIALECT_SQLITE,
                connected=True,
                server_version=f"SQLite {version}",
                current_database=self._masked_connection_string(),
                current_user='N/A',
                details={
                    "journal_mode": journal,
                    "integrity_check": integrity,
                    "execution_time": r.execution_time,
                },
            )
        except Exception as exc:
            return HealthCheckResult(
                dialect=DIALECT_SQLITE, connected=False,
                server_version='', current_database='', current_user='',
                details={"error": str(exc)},
            )

    def _health_mssql(self) -> HealthCheckResult:
        try:
            r = self.execute_with_timing(
                "SELECT "
                "  @@VERSION AS server_version, "
                "  DB_NAME() AS current_db, "
                "  SUSER_SNAME() AS current_user, "
                "  DATEDIFF(SECOND, sqlserver_start_time, GETDATE()) AS uptime_seconds, "
                "  (SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE is_user_process = 1) AS active_connections "
                "FROM sys.dm_os_sys_info"
            )
            row = r.rows[0] if r.rows else {}
            # Trim the verbose @@VERSION to the first line
            full_version = row.get('server_version', 'unknown')
            short_version = full_version.split('\n')[0] if isinstance(full_version, str) else str(full_version)
            return HealthCheckResult(
                dialect=DIALECT_MSSQL,
                connected=True,
                server_version=short_version,
                current_database=row.get('current_db', 'unknown'),
                current_user=row.get('current_user', 'unknown'),
                uptime_seconds=row.get('uptime_seconds'),
                active_connections=row.get('active_connections'),
                details={"execution_time": r.execution_time},
            )
        except Exception as exc:
            return HealthCheckResult(
                dialect=DIALECT_MSSQL, connected=False,
                server_version='', current_database='', current_user='',
                details={"error": str(exc)},
            )

    def _health_oracle(self) -> HealthCheckResult:
        try:
            r = self.execute_with_timing(
                "SELECT "
                "  banner AS server_version "
                "FROM v$version WHERE ROWNUM = 1"
            )
            version = r.rows[0]['server_version'] if r.rows else 'unknown'

            db_info = self.execute_with_timing(
                "SELECT "
                "  SYS_CONTEXT('USERENV', 'DB_NAME') AS current_db, "
                "  SYS_CONTEXT('USERENV', 'SESSION_USER') AS current_user "
                "FROM DUAL"
            )
            db_row = db_info.rows[0] if db_info.rows else {}

            uptime_result = self.execute_with_timing(
                "SELECT "
                "  (SYSDATE - startup_time) * 86400 AS uptime_seconds "
                "FROM v$instance"
            )
            uptime = None
            if uptime_result.rows:
                uptime = int(uptime_result.rows[0].get('uptime_seconds', 0))

            session_result = self.execute_with_timing(
                "SELECT COUNT(*) AS cnt FROM v$session WHERE type = 'USER'"
            )
            active = session_result.rows[0]['cnt'] if session_result.rows else None

            return HealthCheckResult(
                dialect=DIALECT_ORACLE,
                connected=True,
                server_version=version,
                current_database=db_row.get('current_db', 'unknown'),
                current_user=db_row.get('current_user', 'unknown'),
                uptime_seconds=uptime,
                active_connections=active,
                details={"execution_time": r.execution_time},
            )
        except Exception as exc:
            return HealthCheckResult(
                dialect=DIALECT_ORACLE, connected=False,
                server_version='', current_database='', current_user='',
                details={"error": str(exc)},
            )

    # ------------------------------------------------------------------
    # bulk_insert  (dialect-optimised)
    # ------------------------------------------------------------------
    def bulk_insert(
        self,
        table_name: str,
        records: List[Dict[str, Any]],
        batch_size: int = 1000
    ) -> int:
        """
        Bulk insert records efficiently using dialect-specific optimisations.

        MSSQL:      pyodbc executemany with fast_executemany=True
        Oracle:     oracledb executemany with batch processing
        PostgreSQL: SQLAlchemy Core execute with multi-row VALUES
        MySQL:      SQLAlchemy Core execute with multi-row VALUES
        SQLite:     SQLAlchemy Core execute in WAL mode

        Args:
            table_name: Target table
            records: List of record dictionaries
            batch_size: Number of records per batch

        Returns:
            Number of records inserted
        """
        if not records:
            return 0

        if self.dialect == DIALECT_MSSQL:
            return self._bulk_insert_mssql(table_name, records, batch_size)
        elif self.dialect == DIALECT_ORACLE:
            return self._bulk_insert_oracle(table_name, records, batch_size)
        else:
            return self._bulk_insert_generic(table_name, records, batch_size)

    def _bulk_insert_generic(
        self, table_name: str, records: List[Dict[str, Any]], batch_size: int
    ) -> int:
        """Generic bulk insert using SQLAlchemy text() with named params."""
        total_inserted = 0
        columns = list(records[0].keys())
        placeholders = ', '.join([f":{col}" for col in columns])
        query = (
            f"INSERT INTO {table_name} ({', '.join(columns)}) "
            f"VALUES ({placeholders})"
        )

        with self.connection() as conn:
            for i in range(0, len(records), batch_size):
                batch = records[i:i + batch_size]
                conn.execute(text(query), batch)
                total_inserted += len(batch)

        return total_inserted

    def _bulk_insert_mssql(
        self, table_name: str, records: List[Dict[str, Any]], batch_size: int
    ) -> int:
        """
        MSSQL-optimised bulk insert using pyodbc fast_executemany.

        This bypasses SQLAlchemy's parameter binding and uses pyodbc's native
        fast_executemany which sends parameter arrays in a single network
        round-trip per batch, significantly improving throughput.
        """
        total_inserted = 0
        columns = list(records[0].keys())
        col_list = ', '.join(columns)
        placeholders = ', '.join(['?' for _ in columns])
        insert_sql = f"INSERT INTO {table_name} ({col_list}) VALUES ({placeholders})"

        with self.raw_connection() as raw_conn:
            cursor = raw_conn.cursor()
            cursor.fast_executemany = True

            for i in range(0, len(records), batch_size):
                batch = records[i:i + batch_size]
                param_rows = [
                    tuple(rec[col] for col in columns) for rec in batch
                ]
                cursor.executemany(insert_sql, param_rows)
                total_inserted += len(batch)

            cursor.close()

        return total_inserted

    def _bulk_insert_oracle(
        self, table_name: str, records: List[Dict[str, Any]], batch_size: int
    ) -> int:
        """
        Oracle-optimised bulk insert using oracledb executemany.

        Uses named bind variables (:col) and batch processing for
        optimal throughput with the python-oracledb driver.
        """
        total_inserted = 0
        columns = list(records[0].keys())
        col_list = ', '.join(columns)
        placeholders = ', '.join([f":{col}" for col in columns])
        insert_sql = f"INSERT INTO {table_name} ({col_list}) VALUES ({placeholders})"

        with self.raw_connection() as raw_conn:
            cursor = raw_conn.cursor()

            for i in range(0, len(records), batch_size):
                batch = records[i:i + batch_size]
                # oracledb executemany expects list of dicts or list of sequences
                param_rows = [
                    {col: rec[col] for col in columns} for rec in batch
                ]
                cursor.executemany(insert_sql, param_rows)
                total_inserted += len(batch)

            cursor.close()

        return total_inserted

    # ------------------------------------------------------------------
    # create_table_from_dict  (dialect-aware)
    # ------------------------------------------------------------------
    def create_table_from_dict(
        self,
        table_name: str,
        sample_data: Dict[str, Any],
        primary_key: str = 'id'
    ) -> str:
        """
        Generate CREATE TABLE statement from sample data.

        Dialect-aware auto-increment and type mappings.

        Args:
            table_name: Name for the new table
            sample_data: Dictionary representing a sample row
            primary_key: Column name for primary key

        Returns:
            CREATE TABLE SQL statement
        """
        type_maps = {
            DIALECT_POSTGRESQL: {
                str: 'VARCHAR(255)',
                int: 'INTEGER',
                float: 'DOUBLE PRECISION',
                bool: 'BOOLEAN',
                datetime: 'TIMESTAMP',
            },
            DIALECT_MYSQL: {
                str: 'VARCHAR(255)',
                int: 'INT',
                float: 'DOUBLE',
                bool: 'TINYINT(1)',
                datetime: 'DATETIME',
            },
            DIALECT_SQLITE: {
                str: 'TEXT',
                int: 'INTEGER',
                float: 'REAL',
                bool: 'INTEGER',
                datetime: 'TEXT',
            },
            DIALECT_MSSQL: {
                str: 'NVARCHAR(255)',
                int: 'INT',
                float: 'FLOAT',
                bool: 'BIT',
                datetime: 'DATETIME2',
            },
            DIALECT_ORACLE: {
                str: 'VARCHAR2(255)',
                int: 'NUMBER(10)',
                float: 'NUMBER(18,4)',
                bool: 'NUMBER(1)',
                datetime: 'TIMESTAMP',
            },
        }

        type_mapping = type_maps.get(self.dialect, type_maps[DIALECT_POSTGRESQL])
        columns = []

        # Auto-increment primary key if not present in sample data
        if primary_key not in sample_data:
            pk_defs = {
                DIALECT_POSTGRESQL: f"{primary_key} SERIAL PRIMARY KEY",
                DIALECT_MYSQL: f"{primary_key} INT AUTO_INCREMENT PRIMARY KEY",
                DIALECT_SQLITE: f"{primary_key} INTEGER PRIMARY KEY AUTOINCREMENT",
                DIALECT_MSSQL: f"{primary_key} INT IDENTITY(1,1) PRIMARY KEY",
                DIALECT_ORACLE: f"{primary_key} NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY",
            }
            columns.append(pk_defs.get(self.dialect, pk_defs[DIALECT_POSTGRESQL]))

        for key, value in sample_data.items():
            col_type = type_mapping.get(type(value), 'TEXT' if self.dialect != DIALECT_ORACLE else 'CLOB')
            nullable = "NULL" if value is None else "NOT NULL"

            if key == primary_key:
                columns.append(f"{key} {col_type} PRIMARY KEY")
            else:
                columns.append(f"{key} {col_type} {nullable}")

        columns_str = ',\n    '.join(columns)
        create_statement = f"CREATE TABLE {table_name} (\n    {columns_str}\n);"

        return create_statement


# ---------------------------------------------------------------------------
# QueryBuilder  (dialect-aware)
# ---------------------------------------------------------------------------
class QueryBuilder:
    """
    Fluent query builder with dialect-specific syntax support.

    Handles differences between dialects for:
      - LIMIT/OFFSET vs TOP vs FETCH FIRST vs ROWNUM
      - Parameter placeholders (?, %s, :name)
      - String concatenation (||, +, CONCAT())

    Example:
        >>> qb = QueryBuilder('users')
        >>> query, params = qb.select(['name', 'email']) \\
        ...                     .where('age > :min_age') \\
        ...                     .order_by('created_at DESC') \\
        ...                     .limit(10) \\
        ...                     .build(min_age=18)
        >>> print(query)

        >>> # Dialect-specific
        >>> qb = QueryBuilder('users', dialect='mssql')
        >>> query, params = qb.select(['name']).limit(10).build()
        >>> print(query)
        SELECT TOP 10 name FROM users
    """

    def __init__(self, table: str, dialect: str = DIALECT_POSTGRESQL):
        """
        Initialize query builder for a table.

        Args:
            table: Table name (or schema.table)
            dialect: One of 'postgresql', 'mysql', 'sqlite', 'mssql', 'oracle'
        """
        self.table = table
        self.dialect = dialect
        self._select_columns: List[str] = ['*']
        self._where_clauses: List[str] = []
        self._joins: List[str] = []
        self._order_by: Optional[str] = None
        self._limit: Optional[int] = None
        self._offset: Optional[int] = None
        self._group_by: Optional[str] = None
        self._having: Optional[str] = None

    def select(self, columns: List[str]) -> 'QueryBuilder':
        """Specify columns to select."""
        self._select_columns = columns
        return self

    def where(self, condition: str) -> 'QueryBuilder':
        """Add WHERE condition."""
        self._where_clauses.append(condition)
        return self

    def join(
        self,
        table: str,
        on: str,
        join_type: str = 'INNER'
    ) -> 'QueryBuilder':
        """Add JOIN clause."""
        self._joins.append(f"{join_type} JOIN {table} ON {on}")
        return self

    def order_by(self, order: str) -> 'QueryBuilder':
        """Add ORDER BY clause."""
        self._order_by = order
        return self

    def group_by(self, columns: str) -> 'QueryBuilder':
        """Add GROUP BY clause."""
        self._group_by = columns
        return self

    def having(self, condition: str) -> 'QueryBuilder':
        """Add HAVING clause."""
        self._having = condition
        return self

    def limit(self, limit: int) -> 'QueryBuilder':
        """Add LIMIT clause."""
        self._limit = limit
        return self

    def offset(self, offset: int) -> 'QueryBuilder':
        """Add OFFSET clause."""
        self._offset = offset
        return self

    def build(self, **params) -> Tuple[str, Dict[str, Any]]:
        """
        Build the final query with dialect-specific syntax.

        Args:
            **params: Parameters for parameterized queries

        Returns:
            Tuple of (query_string, parameters_dict)

        Dialect behaviour:
            PostgreSQL/MySQL/SQLite: ... LIMIT n OFFSET m
            MSSQL (no ORDER BY):     SELECT TOP n ... (offset not supported without ORDER BY)
            MSSQL (with ORDER BY):   ... ORDER BY x OFFSET m ROWS FETCH NEXT n ROWS ONLY
            Oracle (12c+):           ... OFFSET m ROWS FETCH NEXT n ROWS ONLY
            Oracle (legacy):         wrapped in ROWNUM subquery
        """
        if self.dialect == DIALECT_MSSQL:
            return self._build_mssql(**params)
        elif self.dialect == DIALECT_ORACLE:
            return self._build_oracle(**params)
        else:
            return self._build_standard(**params)

    def _build_standard(self, **params) -> Tuple[str, Dict[str, Any]]:
        """Standard SQL build for PostgreSQL, MySQL, SQLite."""
        query_parts = [
            f"SELECT {', '.join(self._select_columns)}",
            f"FROM {self.table}"
        ]

        if self._joins:
            query_parts.extend(self._joins)

        if self._where_clauses:
            query_parts.append(f"WHERE {' AND '.join(self._where_clauses)}")

        if self._group_by:
            query_parts.append(f"GROUP BY {self._group_by}")

        if self._having:
            query_parts.append(f"HAVING {self._having}")

        if self._order_by:
            query_parts.append(f"ORDER BY {self._order_by}")

        if self._limit is not None:
            query_parts.append(f"LIMIT {self._limit}")

        if self._offset is not None:
            query_parts.append(f"OFFSET {self._offset}")

        query = '\n'.join(query_parts)
        return query, params

    def _build_mssql(self, **params) -> Tuple[str, Dict[str, Any]]:
        """
        MSSQL-specific build.

        - Without ORDER BY: uses SELECT TOP n
        - With ORDER BY and OFFSET: uses OFFSET/FETCH (SQL Server 2012+)
        - With ORDER BY and no OFFSET: still uses OFFSET 0 ROWS FETCH NEXT n ROWS ONLY
        """
        cols = ', '.join(self._select_columns)

        # Determine if we need TOP or OFFSET/FETCH
        use_top = (
            self._limit is not None
            and self._offset is None
            and self._order_by is None
        )

        if use_top:
            select_clause = f"SELECT TOP {self._limit} {cols}"
        else:
            select_clause = f"SELECT {cols}"

        query_parts = [select_clause, f"FROM {self.table}"]

        if self._joins:
            query_parts.extend(self._joins)

        if self._where_clauses:
            query_parts.append(f"WHERE {' AND '.join(self._where_clauses)}")

        if self._group_by:
            query_parts.append(f"GROUP BY {self._group_by}")

        if self._having:
            query_parts.append(f"HAVING {self._having}")

        if self._order_by:
            query_parts.append(f"ORDER BY {self._order_by}")

            # OFFSET/FETCH requires ORDER BY in MSSQL
            if self._limit is not None or self._offset is not None:
                offset_val = self._offset if self._offset is not None else 0
                query_parts.append(f"OFFSET {offset_val} ROWS")
                if self._limit is not None:
                    query_parts.append(f"FETCH NEXT {self._limit} ROWS ONLY")

        query = '\n'.join(query_parts)
        return query, params

    def _build_oracle(self, **params) -> Tuple[str, Dict[str, Any]]:
        """
        Oracle-specific build.

        Uses OFFSET/FETCH syntax (Oracle 12c+).  If neither limit nor
        offset is set, produces standard SQL.  For pre-12c compatibility,
        callers can use the legacy_rownum_wrap() helper instead.
        """
        query_parts = [
            f"SELECT {', '.join(self._select_columns)}",
            f"FROM {self.table}"
        ]

        if self._joins:
            query_parts.extend(self._joins)

        if self._where_clauses:
            query_parts.append(f"WHERE {' AND '.join(self._where_clauses)}")

        if self._group_by:
            query_parts.append(f"GROUP BY {self._group_by}")

        if self._having:
            query_parts.append(f"HAVING {self._having}")

        if self._order_by:
            query_parts.append(f"ORDER BY {self._order_by}")

        # Oracle 12c+ row limiting clause
        if self._offset is not None or self._limit is not None:
            if self._offset is not None:
                query_parts.append(f"OFFSET {self._offset} ROWS")
            if self._limit is not None:
                query_parts.append(f"FETCH NEXT {self._limit} ROWS ONLY")

        query = '\n'.join(query_parts)
        return query, params

    # ------------------------------------------------------------------
    # Utility class methods for cross-dialect helpers
    # ------------------------------------------------------------------
    @staticmethod
    def concat(*expressions: str, dialect: str = DIALECT_POSTGRESQL) -> str:
        """
        Generate a string concatenation expression for the target dialect.

        Args:
            *expressions: Column names or string literals to concatenate
            dialect: Target SQL dialect

        Returns:
            SQL concatenation expression

        Examples:
            >>> QueryBuilder.concat('first_name', "' '", 'last_name', dialect='postgresql')
            "first_name || ' ' || last_name"
            >>> QueryBuilder.concat('first_name', "' '", 'last_name', dialect='mssql')
            "first_name + ' ' + last_name"
            >>> QueryBuilder.concat('first_name', "' '", 'last_name', dialect='mysql')
            "CONCAT(first_name, ' ', last_name)"
        """
        if dialect == DIALECT_MYSQL:
            return f"CONCAT({', '.join(expressions)})"
        elif dialect == DIALECT_MSSQL:
            return ' + '.join(expressions)
        else:
            # PostgreSQL, SQLite, Oracle all use ||
            return ' || '.join(expressions)

    @staticmethod
    def placeholder(name: str, dialect: str = DIALECT_POSTGRESQL) -> str:
        """
        Return the parameter placeholder syntax for a given dialect.

        Args:
            name: Parameter name
            dialect: Target SQL dialect

        Returns:
            Placeholder string

        Notes:
            When using SQLAlchemy text(), always use :name style regardless
            of dialect, as SQLAlchemy handles translation.  This method is
            for raw DBAPI cursor usage.

        Examples:
            >>> QueryBuilder.placeholder('user_id', dialect='postgresql')
            '%s'
            >>> QueryBuilder.placeholder('user_id', dialect='mssql')
            '?'
            >>> QueryBuilder.placeholder('user_id', dialect='oracle')
            ':user_id'
        """
        if dialect in (DIALECT_POSTGRESQL, DIALECT_MYSQL):
            return '%s'
        elif dialect in (DIALECT_MSSQL, DIALECT_SQLITE):
            return '?'
        elif dialect == DIALECT_ORACLE:
            return f':{name}'
        else:
            return f':{name}'

    @staticmethod
    def legacy_rownum_wrap(
        inner_query: str,
        limit: int,
        offset: int = 0
    ) -> str:
        """
        Wrap a query with Oracle ROWNUM pagination (pre-12c compatibility).

        Args:
            inner_query: The base SELECT query
            limit: Maximum rows to return
            offset: Number of rows to skip

        Returns:
            ROWNUM-wrapped query string
        """
        upper = offset + limit
        return (
            f"SELECT * FROM ("
            f"  SELECT inner_.*, ROWNUM AS rnum_ FROM ({inner_query}) inner_"
            f"  WHERE ROWNUM <= {upper}"
            f") WHERE rnum_ > {offset}"
        )


# ---------------------------------------------------------------------------
# SampleDataGenerator  (unchanged)
# ---------------------------------------------------------------------------
class SampleDataGenerator:
    """
    Generate sample data for testing.

    Example:
        >>> gen = SampleDataGenerator()
        >>> users = gen.generate_users(100)
        >>> orders = gen.generate_orders(500, user_ids=[u['id'] for u in users])
    """

    @staticmethod
    def generate_users(count: int) -> List[Dict[str, Any]]:
        """
        Generate sample user records.

        Args:
            count: Number of users to generate

        Returns:
            List of user dictionaries
        """
        import random
        from datetime import timedelta

        first_names = ['Alice', 'Bob', 'Charlie', 'Diana', 'Eve', 'Frank']
        last_names = ['Smith', 'Johnson', 'Williams', 'Brown', 'Jones']

        users = []
        base_date = datetime.now()

        for i in range(count):
            users.append({
                'id': i + 1,
                'username': f"user{i + 1}",
                'email': f"user{i + 1}@example.com",
                'first_name': random.choice(first_names),
                'last_name': random.choice(last_names),
                'age': random.randint(18, 80),
                'active': random.choice([True, False]),
                'created_at': base_date - timedelta(days=random.randint(0, 365))
            })

        return users

    @staticmethod
    def generate_orders(
        count: int,
        user_ids: List[int]
    ) -> List[Dict[str, Any]]:
        """
        Generate sample order records.

        Args:
            count: Number of orders to generate
            user_ids: List of valid user IDs

        Returns:
            List of order dictionaries
        """
        import random
        from datetime import timedelta

        statuses = ['pending', 'processing', 'shipped', 'delivered', 'cancelled']
        orders = []
        base_date = datetime.now()

        for i in range(count):
            orders.append({
                'id': i + 1,
                'user_id': random.choice(user_ids),
                'total_amount': round(random.uniform(10.0, 500.0), 2),
                'status': random.choice(statuses),
                'created_at': base_date - timedelta(days=random.randint(0, 90))
            })

        return orders


# ---------------------------------------------------------------------------
# Convenience functions  (backward compatible)
# ---------------------------------------------------------------------------
def connect(connection_string: str, **kwargs) -> DatabaseHelper:
    """
    Create a database helper instance.

    Args:
        connection_string: Database connection string
        **kwargs: Additional arguments for DatabaseHelper

    Returns:
        DatabaseHelper instance

    Example:
        >>> db = connect('postgresql://user:pass@localhost/mydb')
        >>> db = connect('mssql+pyodbc:///?odbc_connect=...')
        >>> db = connect('oracle+oracledb://user:pass@host:1521/ORCL')
        >>> tables = db.list_tables()
    """
    return DatabaseHelper(connection_string, **kwargs)


# ---------------------------------------------------------------------------
# __main__
# ---------------------------------------------------------------------------
if __name__ == '__main__':
    print("SQL Helper Module - Multi-Dialect Example Usage")
    print("=" * 55)
    print(f"Supported dialects: {', '.join(SUPPORTED_DIALECTS)}")

    # SQLite example (no external dependencies)
    db = DatabaseHelper('sqlite:///example.db')

    print(f"\nDetected dialect: {db.dialect}")

    print("\n1. Creating sample table...")
    sample_data = {
        'name': 'Alice',
        'age': 30,
        'email': 'alice@example.com'
    }
    create_sql = db.create_table_from_dict('users', sample_data)
    print(create_sql)

    print("\n2. Generating sample data...")
    gen = SampleDataGenerator()
    users = gen.generate_users(5)
    for user in users:
        print(f"  {user['username']}: {user['email']}")

    print("\n3. Building queries (standard / PostgreSQL)...")
    qb = QueryBuilder('users')
    query, params = qb.select(['name', 'email']) \
                       .where('age > :min_age') \
                       .order_by('name') \
                       .limit(10) \
                       .build(min_age=18)
    print(query)
    print(f"Parameters: {params}")

    print("\n4. Building queries (MSSQL with TOP)...")
    qb_mssql = QueryBuilder('dbo.users', dialect=DIALECT_MSSQL)
    query, params = qb_mssql.select(['name', 'email']) \
                             .where('age > :min_age') \
                             .limit(10) \
                             .build(min_age=18)
    print(query)
    print(f"Parameters: {params}")

    print("\n5. Building queries (MSSQL with OFFSET/FETCH)...")
    qb_mssql2 = QueryBuilder('dbo.users', dialect=DIALECT_MSSQL)
    query, params = qb_mssql2.select(['name', 'email']) \
                              .where('age > :min_age') \
                              .order_by('name') \
                              .limit(10) \
                              .offset(20) \
                              .build(min_age=18)
    print(query)
    print(f"Parameters: {params}")

    print("\n6. Building queries (Oracle 12c+)...")
    qb_ora = QueryBuilder('app_schema.users', dialect=DIALECT_ORACLE)
    query, params = qb_ora.select(['name', 'email']) \
                          .where('age > :min_age') \
                          .order_by('name') \
                          .limit(10) \
                          .offset(20) \
                          .build(min_age=18)
    print(query)
    print(f"Parameters: {params}")

    print("\n7. String concatenation examples...")
    for d in SUPPORTED_DIALECTS:
        expr = QueryBuilder.concat('first_name', "' '", 'last_name', dialect=d)
        print(f"  {d:12s}: {expr}")

    print("\n8. Parameter placeholder examples...")
    for d in SUPPORTED_DIALECTS:
        ph = QueryBuilder.placeholder('user_id', dialect=d)
        print(f"  {d:12s}: {ph}")

    print("\n9. Health check (SQLite)...")
    hc = db.health_check()
    print(hc)

    print("\nDone.")
