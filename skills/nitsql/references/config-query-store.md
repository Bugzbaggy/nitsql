# config-query-optimization
**Priority:** HIGH
**Category:** Configuration
**Applies to:** MSSQL, PostgreSQL, Oracle, MySQL

## Why It Matters

Every RDBMS provides built-in instrumentation to capture query performance history, identify regressions, and surface tuning opportunities. Without enabling and configuring these tools, you are flying blind: slow queries go unnoticed until users complain, and you cannot prove whether a deployment improved or degraded performance. Proper configuration costs minimal overhead (1-3% CPU) but provides the data needed for every performance investigation.

## Incorrect Code

### MSSQL
```sql
-- Bad: Query Store disabled or misconfigured
ALTER DATABASE [MyDB] SET QUERY_STORE = OFF;

-- Bad: storage too small (fills up, switches to READ_ONLY)
ALTER DATABASE [MyDB] SET QUERY_STORE (MAX_STORAGE_SIZE_MB = 10);

-- Bad: capture mode NONE
ALTER DATABASE [MyDB] SET QUERY_STORE (QUERY_CAPTURE_MODE = NONE);
```

### PostgreSQL
```sql
-- Bad: pg_stat_statements not loaded
-- postgresql.conf has no: shared_preload_libraries = 'pg_stat_statements'

-- Bad: track parameter off
-- pg_stat_statements.track = none
```

### Oracle
```sql
-- Bad: AWR retention too short to compare baselines
EXEC DBMS_WORKLOAD_REPOSITORY.MODIFY_SNAPSHOT_SETTINGS(retention => 1440);
-- Only 1 day of data; cannot compare week-over-week
```

### MySQL
```sql
-- Bad: Performance Schema disabled
-- my.cnf: performance_schema = OFF

-- Bad: slow query log off with no monitoring
SET GLOBAL slow_query_log = 'OFF';
```

## Correct Code

### MSSQL
```sql
-- Enable Query Store with production-ready settings
ALTER DATABASE [MyDB] SET QUERY_STORE = ON;
ALTER DATABASE [MyDB] SET QUERY_STORE (
    OPERATION_MODE = READ_WRITE,
    CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 30),
    DATA_FLUSH_INTERVAL_SECONDS = 900,
    INTERVAL_LENGTH_MINUTES = 60,
    MAX_STORAGE_SIZE_MB = 1024,
    QUERY_CAPTURE_MODE = AUTO,
    SIZE_BASED_CLEANUP_MODE = AUTO,
    MAX_PLANS_PER_QUERY = 200,
    WAIT_STATS_CAPTURE_MODE = ON
);

-- Enable automatic plan correction
ALTER DATABASE [MyDB] SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = ON);

-- Verify configuration
SELECT actual_state_desc, desired_state_desc,
       current_storage_size_mb, max_storage_size_mb,
       query_capture_mode_desc, wait_stats_capture_mode_desc
FROM sys.database_query_store_options;

-- Top resource consumers (last 7 days)
SELECT TOP 20
    q.query_id,
    qt.query_sql_text,
    SUM(rs.count_executions) AS total_executions,
    AVG(rs.avg_duration) / 1000 AS avg_duration_ms,
    SUM(rs.avg_logical_io_reads * rs.count_executions) AS total_logical_reads
FROM sys.query_store_query q
JOIN sys.query_store_query_text qt ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_plan p ON q.query_id = p.query_id
JOIN sys.query_store_runtime_stats rs ON p.plan_id = rs.plan_id
JOIN sys.query_store_runtime_stats_interval rsi ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time > DATEADD(DAY, -7, GETUTCDATE())
GROUP BY q.query_id, qt.query_sql_text
ORDER BY total_logical_reads DESC;

-- Force a known good plan
EXEC sys.sp_query_store_force_plan @query_id = 123, @plan_id = 456;
```

### PostgreSQL
```sql
-- Step 1: Enable pg_stat_statements (requires restart)
-- postgresql.conf:
--   shared_preload_libraries = 'pg_stat_statements, auto_explain'
--   pg_stat_statements.max = 10000
--   pg_stat_statements.track = all
--   pg_stat_statements.track_utility = on
--   pg_stat_statements.track_planning = on

-- Step 2: Create the extension
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Step 3: Enable auto_explain for slow queries (no restart needed)
-- postgresql.conf:
--   auto_explain.log_min_duration = 1000   -- log queries over 1 second
--   auto_explain.log_analyze = on
--   auto_explain.log_buffers = on
--   auto_explain.log_format = json

-- Or at runtime for the session:
LOAD 'auto_explain';
SET auto_explain.log_min_duration = '1s';

-- Top resource consumers
SELECT
    queryid,
    LEFT(query, 100) AS query_preview,
    calls,
    total_exec_time / 1000 AS total_sec,
    mean_exec_time AS avg_ms,
    rows,
    shared_blks_hit + shared_blks_read AS total_blocks
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY total_exec_time DESC
LIMIT 20;

-- Reset statistics periodically (or after a deployment)
SELECT pg_stat_statements_reset();
```

### Oracle
```sql
-- AWR (Automatic Workload Repository) -- enabled by default in Enterprise Edition
-- Set retention to 30 days and snapshot interval to 30 minutes
EXEC DBMS_WORKLOAD_REPOSITORY.MODIFY_SNAPSHOT_SETTINGS(
    retention => 43200,    -- 30 days in minutes
    interval  => 30        -- snapshot every 30 minutes
);

-- Generate AWR report for the last hour
-- Find snap_id range:
SELECT snap_id, begin_interval_time
FROM dba_hist_snapshot
ORDER BY snap_id DESC
FETCH FIRST 5 ROWS ONLY;

-- Generate HTML report:
SELECT output FROM TABLE(
    DBMS_WORKLOAD_REPOSITORY.AWR_REPORT_HTML(
        l_dbid     => (SELECT dbid FROM v$database),
        l_inst_num => 1,
        l_bid      => :begin_snap_id,
        l_eid      => :end_snap_id
    )
);

-- ADDM (Automatic Database Diagnostic Monitor) -- runs automatically after each AWR snapshot
-- View recommendations:
SELECT finding_name, type, impact, message
FROM dba_advisor_findings
WHERE task_name LIKE 'ADDM%'
ORDER BY impact DESC
FETCH FIRST 20 ROWS ONLY;

-- SQL Plan Baselines -- lock known-good plans
DECLARE
    v_plans PLS_INTEGER;
BEGIN
    v_plans := DBMS_SPM.LOAD_PLANS_FROM_CURSOR_CACHE(
        sql_id      => 'abc123def456',
        plan_hash_value => 987654321,
        fixed       => 'YES'
    );
    DBMS_OUTPUT.PUT_LINE('Loaded ' || v_plans || ' plan(s)');
END;
/

-- Top SQL by elapsed time
SELECT sql_id, sql_text, executions,
       elapsed_time / 1000000 AS elapsed_sec,
       cpu_time / 1000000 AS cpu_sec,
       buffer_gets
FROM v$sql
ORDER BY elapsed_time DESC
FETCH FIRST 20 ROWS ONLY;
```

### MySQL
```sql
-- Step 1: Enable Performance Schema (enabled by default in MySQL 8.0+)
-- my.cnf:
--   performance_schema = ON
--   performance_schema_max_digest_length = 4096

-- Step 2: Enable slow query log
SET GLOBAL slow_query_log = 'ON';
SET GLOBAL long_query_time = 1;          -- queries over 1 second
SET GLOBAL log_queries_not_using_indexes = 'ON';
SET GLOBAL slow_query_log_file = '/var/log/mysql/slow.log';

-- Step 3: Install sys schema (included by default in MySQL 8.0+)
-- Provides human-readable views over Performance Schema

-- Top queries by total execution time (sys schema)
SELECT DIGEST_TEXT,
       COUNT_STAR AS calls,
       SUM_TIMER_WAIT / 1000000000000 AS total_sec,
       AVG_TIMER_WAIT / 1000000000 AS avg_ms,
       SUM_ROWS_EXAMINED,
       SUM_ROWS_SENT
FROM performance_schema.events_statements_summary_by_digest
WHERE SCHEMA_NAME = 'mydb'
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 20;

-- Using sys schema for easier reading
SELECT query, exec_count, avg_latency, rows_examined_avg
FROM sys.statements_with_runtimes_in_95th_percentile
LIMIT 20;

-- Find queries not using indexes
SELECT DIGEST_TEXT, COUNT_STAR, SUM_NO_INDEX_USED
FROM performance_schema.events_statements_summary_by_digest
WHERE SUM_NO_INDEX_USED > 0
ORDER BY COUNT_STAR DESC
LIMIT 20;

-- Reset statistics
TRUNCATE TABLE performance_schema.events_statements_summary_by_digest;
```

## Configuration Comparison

| Feature | MSSQL | PostgreSQL | Oracle | MySQL |
|---|---|---|---|---|
| Query history | Query Store | pg_stat_statements | AWR + V$SQL | Performance Schema |
| Slow query log | Extended Events | auto_explain / log_min_duration_statement | AWR SQL report | slow_query_log |
| Plan management | Query Store Force Plan | N/A (use pg_hint_plan) | SQL Plan Baselines | N/A (use optimizer hints) |
| Auto-tuning | Automatic Plan Correction | N/A | ADDM recommendations | N/A |
| Wait analysis | Query Store Wait Stats | pg_stat_activity.wait_event | ASH / V$SESSION_WAIT | Performance Schema waits |

## Application Code Detection

### Python

```python
# All dialects: log slow queries from the application side as a safety net
import time
import logging

logger = logging.getLogger("db")

def execute_with_timing(cursor, query, params=None, slow_threshold_ms=500):
    start = time.monotonic()
    cursor.execute(query, params or ())
    elapsed_ms = (time.monotonic() - start) * 1000
    if elapsed_ms > slow_threshold_ms:
        logger.warning("Slow query (%.1f ms): %s", elapsed_ms, query[:200])
    return cursor
```

### Node.js

```javascript
// All dialects: middleware to log slow queries
async function timedQuery(pool, query, params, slowMs = 500) {
    const start = Date.now();
    const result = await pool.query(query, params);
    const elapsed = Date.now() - start;
    if (elapsed > slowMs) {
        console.warn(`Slow query (${elapsed}ms): ${query.substring(0, 200)}`);
    }
    return result;
}
```

### C#

```csharp
// All dialects: log slow queries via DbCommandInterceptor (EF Core)
public class SlowQueryInterceptor : DbCommandInterceptor
{
    public override ValueTask<DbDataReader> ReaderExecutedAsync(
        DbCommand command, CommandExecutedEventData data, DbDataReader result,
        CancellationToken ct)
    {
        if (data.Duration.TotalMilliseconds > 500)
        {
            Log.Warning("Slow query ({Duration}ms): {Sql}",
                data.Duration.TotalMilliseconds, command.CommandText[..200]);
        }
        return new ValueTask<DbDataReader>(result);
    }
}
```

## Key Metrics to Monitor (All Dialects)

Regardless of dialect, these are the metrics to track and alert on:

| Metric | Why | Alert Threshold |
|--------|-----|-----------------|
| **Top queries by elapsed time** | Find the worst offenders | Top 10 queries consuming >50% of total time |
| **Plan regressions** | Query suddenly slower after stats refresh or code deploy | Execution time >2x baseline |
| **Full table scans on large tables** | Missing indexes or non-SARGable predicates | Any scan on table >100K rows in OLTP |
| **Lock waits / deadlocks** | Contention issues | Any deadlock; lock waits >5 seconds |
| **Connection pool exhaustion** | Pool too small or connections leaked | Active connections >80% of max |
| **Buffer/cache hit ratio** | Insufficient memory | <95% (MSSQL/MySQL), <99% (PG/Oracle) |
| **Replication lag** | Reads from replica returning stale data | Lag >1 second for OLTP |

## Exceptions

- **Development databases** may disable Performance Schema or AWR to reduce overhead. Never disable these in staging or production.
- **Oracle Standard Edition** does not include AWR/ADDM/ASH. Use `V$SQL` and `V$SESSION` directly, or the free Statspack utility.
- **MySQL on very small instances** (< 1 GB RAM): Performance Schema overhead may be noticeable. Reduce the number of enabled consumers/instruments.

## How to Detect

### MSSQL
```sql
-- Check Query Store state
SELECT actual_state_desc, readonly_reason,
       current_storage_size_mb, max_storage_size_mb
FROM sys.database_query_store_options;
-- If actual_state_desc != 'READ_WRITE', Query Store is not actively capturing.
```

### PostgreSQL
```sql
-- Check if pg_stat_statements is loaded
SELECT * FROM pg_extension WHERE extname = 'pg_stat_statements';
-- Empty result = not installed. Run: CREATE EXTENSION pg_stat_statements;
```

### Oracle
```sql
-- Check AWR retention and interval
SELECT snap_interval, retention
FROM dba_hist_wr_control;
```

### MySQL
```sql
-- Check if Performance Schema is enabled
SHOW VARIABLES LIKE 'performance_schema';
-- Check slow query log status
SHOW VARIABLES LIKE 'slow_query_log';
SHOW VARIABLES LIKE 'long_query_time';
```
