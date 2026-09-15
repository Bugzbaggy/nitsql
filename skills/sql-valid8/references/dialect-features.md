# Dialect-Specific Features Reference

Key features unique to each RDBMS. Load the full dialect reference file for complete details.

## Dialect-Specific Features

Brief highlights of unique features per dialect. Load the dialect reference file for full details.

### MSSQL (SQL Server 2019+)
- **Query Store** -- Built-in query performance monitoring and plan forcing. Enable on all production databases.
- **Intelligent Query Processing (IQP)** -- Batch mode on rowstore, table variable deferred compilation, scalar UDF inlining, adaptive joins, memory grant feedback. Requires compat level 150+ (2019) or 160+ (2022).
- **Accelerated Database Recovery (ADR)** -- Instant transaction rollback, aggressive log truncation. Critical for long-running transaction workloads.
- **Ledger Tables** (2022) -- Tamper-evident, cryptographically verifiable data for compliance.
- **OPTIMIZE_FOR_SEQUENTIAL_KEY** (2019+) -- Reduces last-page insert contention on identity-column indexes.
- **Parameter Sensitive Plan Optimization** (2022) -- Multiple plans for parameter-sensitive queries at compat level 160+.
- **Resumable Index Operations** (2019+) -- Pause and resume large index builds without losing progress.
- **Always Encrypted with Secure Enclaves** (2019+) -- Rich computations on encrypted data.
- **Modern T-SQL** (2022): `GENERATE_SERIES()`, `GREATEST()`/`LEAST()`, `DATE_BUCKET()`, `WINDOW` clause, `IS [NOT] DISTINCT FROM`.

### PostgreSQL (13+)
- **EXPLAIN (ANALYZE, BUFFERS)** -- The most informative execution plan output of any RDBMS. Always use ANALYZE for actual vs. estimated row counts.
- **pg_stat_statements** -- Essential extension for tracking query performance statistics across all queries.
- **Partial Indexes** -- Index only rows matching a WHERE condition. Dramatically reduces index size and improves write performance for selective queries.
- **JSONB** -- Binary JSON with GIN indexing, containment operators (`@>`), and path queries. Fastest JSON implementation among major RDBMS.
- **CTEs and Recursive CTEs** -- Fully optimized (CTE inlining since PG 12). Use `MATERIALIZED`/`NOT MATERIALIZED` hints to control.
- **LISTEN/NOTIFY** -- Built-in pub/sub for real-time event notification without polling.
- **Logical Replication** -- Table-level selective replication (PG 10+).
- **Declarative Partitioning** -- `PARTITION BY RANGE/LIST/HASH` with automatic partition pruning (PG 10+, improved each version).
- **UPSERT** -- `INSERT ... ON CONFLICT DO UPDATE/NOTHING` for atomic upsert.
- **Generated Columns** -- `GENERATED ALWAYS AS (expression) STORED` (PG 12+).
- **Multirange Types** (PG 14+), **MERGE** statement (PG 15+), **SQL/JSON path language** improvements (PG 16+).

### Oracle (19c+)
- **AWR (Automatic Workload Repository)** -- Comprehensive performance data collection with historical baselines. Run AWR reports for period-over-period comparison.
- **ASH (Active Session History)** -- Second-by-second sampling of active sessions. Essential for diagnosing transient performance issues.
- **ADDM (Automatic Database Diagnostic Monitor)** -- Automated analysis with actionable recommendations.
- **SQL Plan Baselines** -- Capture and enforce known-good execution plans. Prevents plan regressions during statistics refresh or upgrades.
- **Partitioning** -- Most mature implementation: range, list, hash, interval, reference, composite partitioning.
- **Materialized Views** -- Precomputed result sets with automatic query rewrite. `DBMS_MVIEW.REFRESH` for on-demand refresh.
- **BULK COLLECT and FORALL** -- Essential for high-performance PL/SQL. Process rows in batches (LIMIT 1000) rather than one-by-one.
- **Edition-Based Redefinition** -- Online application upgrades with zero downtime.
- **Result Cache** -- `/*+ RESULT_CACHE */` for caching query results in SGA.
- **Real Application Clusters (RAC)** -- Multi-instance active-active clustering.
- **Autonomous Database** -- Self-tuning, self-patching, self-securing cloud database.
- **JSON Relational Duality Views** (23ai) -- Single JSON document backed by multiple normalized tables.

### MySQL (8.0+)
- **Performance Schema** -- Detailed instrumentation for query analysis, waits, stages, and locks.
- **InnoDB Optimizations** -- Clustered index architecture, buffer pool management, change buffer, doublewrite buffer.
- **Window Functions** (8.0+) -- `ROW_NUMBER()`, `RANK()`, `LAG()`/`LEAD()`, `SUM() OVER()` -- previously unavailable in MySQL.
- **Common Table Expressions** (8.0+) -- Recursive and non-recursive CTEs. Use for hierarchical queries replacing self-joins.
- **Generated Columns** -- `GENERATED ALWAYS AS (expression) STORED/VIRTUAL` for derived data with optional indexing on virtual columns.
- **Descending Indexes** (8.0+) -- True descending index support for optimizing `ORDER BY col1 ASC, col2 DESC`.
- **Invisible Indexes** -- `ALTER TABLE ... ALTER INDEX idx INVISIBLE` to test impact of dropping an index without actually dropping it.
- **Instant ADD COLUMN** -- `ALTER TABLE ... ADD COLUMN ... ALGORITHM=INSTANT` for zero-downtime schema changes (limitations apply).
- **Histograms** -- `ANALYZE TABLE ... UPDATE HISTOGRAM ON col` for better cardinality estimates on skewed data.
- **Clone Plugin** (8.0.17+) -- Efficient local and remote database cloning.
- **Group Replication / InnoDB Cluster** -- Built-in high availability with automatic failover.

