-- ============================================================================
-- analyze-slow-queries.sql
-- Multi-dialect script for identifying and diagnosing slow queries.
-- Run the section matching your database platform.
-- ============================================================================


-- ############################################################################
-- POSTGRESQL
-- ############################################################################
-- Requires: CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
-- (shared_preload_libraries = 'pg_stat_statements' in postgresql.conf)

-- ---------------------------------------------------------------------------
-- 1. Top 10 slowest queries by mean execution time
-- ---------------------------------------------------------------------------
SELECT
    queryid,
    substr(query, 1, 200)                              AS query_preview,
    calls,
    round(mean_exec_time::numeric, 2)                  AS avg_ms,
    round(total_exec_time::numeric, 0)                 AS total_ms,
    rows,
    round(stddev_exec_time::numeric, 2)                AS stddev_ms,
    round((100.0 * total_exec_time /
           sum(total_exec_time) OVER ())::numeric, 2)  AS pct_of_total_time
FROM pg_stat_statements
WHERE calls > 5
ORDER BY mean_exec_time DESC
LIMIT 10;

-- ---------------------------------------------------------------------------
-- 2. Top 10 queries by total execution time (most resource-consuming)
-- ---------------------------------------------------------------------------
SELECT
    queryid,
    substr(query, 1, 200)                              AS query_preview,
    calls,
    round(total_exec_time::numeric, 0)                 AS total_ms,
    round(mean_exec_time::numeric, 2)                  AS avg_ms,
    rows,
    shared_blks_hit + shared_blks_read                 AS total_buffers,
    round(100.0 * shared_blks_hit /
          NULLIF(shared_blks_hit + shared_blks_read, 0), 1) AS cache_hit_pct
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;

-- ---------------------------------------------------------------------------
-- 3. Sequential scans on large tables (candidates for indexing)
-- ---------------------------------------------------------------------------
SELECT
    schemaname,
    relname                           AS table_name,
    seq_scan,
    seq_tup_read,
    idx_scan,
    CASE WHEN seq_scan > 0
         THEN seq_tup_read / seq_scan
         ELSE 0
    END                               AS avg_rows_per_seq_scan,
    pg_size_pretty(pg_relation_size(relid)) AS table_size
FROM pg_stat_user_tables
WHERE seq_scan > 100
  AND pg_relation_size(relid) > 10 * 1024 * 1024  -- tables > 10 MB
ORDER BY seq_tup_read DESC
LIMIT 20;

-- ---------------------------------------------------------------------------
-- 4. Tables most in need of vacuum
-- ---------------------------------------------------------------------------
SELECT
    schemaname,
    relname                           AS table_name,
    n_dead_tup,
    n_live_tup,
    CASE WHEN n_live_tup > 0
         THEN round(100.0 * n_dead_tup / n_live_tup, 1)
         ELSE 0
    END                               AS dead_pct,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY n_dead_tup DESC
LIMIT 20;

-- ---------------------------------------------------------------------------
-- 5. Long-running active queries (> 30 seconds)
-- ---------------------------------------------------------------------------
SELECT
    pid,
    usename,
    datname,
    state,
    now() - query_start               AS duration,
    wait_event_type,
    wait_event,
    substr(query, 1, 300)             AS query_preview
FROM pg_stat_activity
WHERE state = 'active'
  AND query_start < now() - interval '30 seconds'
  AND pid != pg_backend_pid()
ORDER BY query_start ASC;

-- ---------------------------------------------------------------------------
-- 6. Lock waits (blocked queries)
-- ---------------------------------------------------------------------------
SELECT
    blocked.pid                       AS blocked_pid,
    blocked.usename                   AS blocked_user,
    substr(blocked.query, 1, 200)     AS blocked_query,
    now() - blocked.query_start       AS blocked_duration,
    blocker.pid                       AS blocker_pid,
    blocker.usename                   AS blocker_user,
    substr(blocker.query, 1, 200)     AS blocker_query
FROM pg_stat_activity blocked
JOIN pg_locks bl ON bl.pid = blocked.pid AND NOT bl.granted
JOIN pg_locks gl ON gl.locktype = bl.locktype
                AND gl.database IS NOT DISTINCT FROM bl.database
                AND gl.relation IS NOT DISTINCT FROM bl.relation
                AND gl.page IS NOT DISTINCT FROM bl.page
                AND gl.tuple IS NOT DISTINCT FROM bl.tuple
                AND gl.virtualxid IS NOT DISTINCT FROM bl.virtualxid
                AND gl.transactionid IS NOT DISTINCT FROM bl.transactionid
                AND gl.classid IS NOT DISTINCT FROM bl.classid
                AND gl.objid IS NOT DISTINCT FROM bl.objid
                AND gl.objsubid IS NOT DISTINCT FROM bl.objsubid
                AND gl.pid != bl.pid
                AND gl.granted
JOIN pg_stat_activity blocker ON blocker.pid = gl.pid
WHERE blocked.wait_event_type = 'Lock'
ORDER BY blocked_duration DESC;

-- ---------------------------------------------------------------------------
-- 7. I/O-intensive queries (high buffer reads from disk)
-- ---------------------------------------------------------------------------
SELECT
    queryid,
    substr(query, 1, 200)             AS query_preview,
    calls,
    shared_blks_read                  AS disk_reads,
    shared_blks_hit                   AS cache_hits,
    round(100.0 * shared_blks_hit /
          NULLIF(shared_blks_hit + shared_blks_read, 0), 1) AS cache_hit_pct,
    temp_blks_read + temp_blks_written AS temp_io
FROM pg_stat_statements
WHERE shared_blks_read > 1000
ORDER BY shared_blks_read DESC
LIMIT 10;


-- ############################################################################
-- MYSQL
-- ############################################################################

-- ---------------------------------------------------------------------------
-- 1. Top 10 slowest queries by average latency (Performance Schema)
-- ---------------------------------------------------------------------------
SELECT
    LEFT(DIGEST_TEXT, 200)             AS query_preview,
    DIGEST                             AS query_digest,
    COUNT_STAR                         AS exec_count,
    ROUND(AVG_TIMER_WAIT / 1e9, 2)    AS avg_latency_ms,
    ROUND(SUM_TIMER_WAIT / 1e9, 0)    AS total_latency_ms,
    SUM_ROWS_EXAMINED,
    SUM_ROWS_SENT,
    ROUND(SUM_ROWS_EXAMINED / NULLIF(SUM_ROWS_SENT, 0), 0) AS examine_per_sent
FROM performance_schema.events_statements_summary_by_digest
WHERE SCHEMA_NAME IS NOT NULL
  AND COUNT_STAR > 5
ORDER BY AVG_TIMER_WAIT DESC
LIMIT 10;

-- ---------------------------------------------------------------------------
-- 2. Top 10 queries by total latency (highest resource consumers)
-- ---------------------------------------------------------------------------
SELECT
    LEFT(DIGEST_TEXT, 200)             AS query_preview,
    COUNT_STAR                         AS exec_count,
    ROUND(SUM_TIMER_WAIT / 1e9, 0)    AS total_latency_ms,
    ROUND(AVG_TIMER_WAIT / 1e9, 2)    AS avg_latency_ms,
    SUM_ROWS_EXAMINED,
    SUM_CREATED_TMP_DISK_TABLES       AS disk_tmp_tables,
    SUM_NO_INDEX_USED                  AS full_scans
FROM performance_schema.events_statements_summary_by_digest
WHERE SCHEMA_NAME IS NOT NULL
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 10;

-- ---------------------------------------------------------------------------
-- 3. InnoDB buffer pool hit ratio
-- ---------------------------------------------------------------------------
SELECT
    FORMAT(
        (1 - (
            (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads')
            /
            NULLIF((SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests'), 0)
        )) * 100, 2
    ) AS buffer_pool_hit_ratio_pct;

-- ---------------------------------------------------------------------------
-- 4. Queries creating disk-based temporary tables (expensive)
-- ---------------------------------------------------------------------------
SELECT
    LEFT(DIGEST_TEXT, 200)             AS query_preview,
    COUNT_STAR                         AS exec_count,
    SUM_CREATED_TMP_DISK_TABLES       AS disk_tmp_tables,
    SUM_CREATED_TMP_TABLES            AS mem_tmp_tables,
    ROUND(AVG_TIMER_WAIT / 1e9, 2)    AS avg_latency_ms
FROM performance_schema.events_statements_summary_by_digest
WHERE SUM_CREATED_TMP_DISK_TABLES > 0
ORDER BY SUM_CREATED_TMP_DISK_TABLES DESC
LIMIT 10;

-- ---------------------------------------------------------------------------
-- 5. Queries doing full table scans
-- ---------------------------------------------------------------------------
SELECT
    LEFT(DIGEST_TEXT, 200)             AS query_preview,
    COUNT_STAR                         AS exec_count,
    SUM_NO_INDEX_USED                  AS no_index_count,
    SUM_NO_GOOD_INDEX_USED            AS no_good_index_count,
    SUM_ROWS_EXAMINED,
    ROUND(AVG_TIMER_WAIT / 1e9, 2)    AS avg_latency_ms
FROM performance_schema.events_statements_summary_by_digest
WHERE SUM_NO_INDEX_USED > 0
  AND COUNT_STAR > 10
ORDER BY SUM_ROWS_EXAMINED DESC
LIMIT 10;

-- ---------------------------------------------------------------------------
-- 6. Table lock waits
-- ---------------------------------------------------------------------------
SELECT
    OBJECT_SCHEMA,
    OBJECT_NAME,
    COUNT_STAR                         AS lock_wait_count,
    ROUND(SUM_TIMER_WAIT / 1e9, 0)    AS total_wait_ms,
    ROUND(AVG_TIMER_WAIT / 1e9, 2)    AS avg_wait_ms
FROM performance_schema.table_lock_waits_summary_by_table
WHERE COUNT_STAR > 0
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 10;

-- ---------------------------------------------------------------------------
-- 7. Currently running queries (long-running)
-- ---------------------------------------------------------------------------
SELECT
    ID                                 AS process_id,
    USER,
    HOST,
    DB,
    COMMAND,
    TIME                               AS seconds_running,
    STATE,
    LEFT(INFO, 300)                    AS query_preview
FROM information_schema.PROCESSLIST
WHERE COMMAND != 'Sleep'
  AND TIME > 5
  AND ID != CONNECTION_ID()
ORDER BY TIME DESC;

-- ---------------------------------------------------------------------------
-- 8. Recent deadlock information
-- ---------------------------------------------------------------------------
-- Run: SHOW ENGINE INNODB STATUS\G
-- Look for the "LATEST DETECTED DEADLOCK" section.
-- Alternatively, if innodb_print_all_deadlocks = ON, check the error log.


-- ############################################################################
-- SQL SERVER
-- ############################################################################

-- ---------------------------------------------------------------------------
-- 1. Top 10 queries from Query Store by average duration
-- ---------------------------------------------------------------------------
SELECT TOP 10
    qt.query_sql_text,
    q.query_id,
    p.plan_id,
    rs.count_executions,
    rs.avg_duration / 1000.0           AS avg_duration_ms,
    rs.avg_cpu_time / 1000.0           AS avg_cpu_ms,
    rs.avg_logical_io_reads,
    rs.avg_physical_io_reads,
    rs.avg_rowcount,
    rs.last_execution_time
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_plan p ON rs.plan_id = p.plan_id
JOIN sys.query_store_query q ON p.query_id = q.query_id
JOIN sys.query_store_query_text qt ON q.query_text_id = qt.query_text_id
WHERE rs.last_execution_time > DATEADD(DAY, -1, GETUTCDATE())
ORDER BY rs.avg_duration DESC;

-- ---------------------------------------------------------------------------
-- 2. Top 10 queries from sys.dm_exec_query_stats (cumulative cache stats)
-- ---------------------------------------------------------------------------
SELECT TOP 10
    SUBSTRING(st.text,
              (qs.statement_start_offset / 2) + 1,
              CASE qs.statement_end_offset
                   WHEN -1 THEN DATALENGTH(st.text)
                   ELSE (qs.statement_end_offset - qs.statement_start_offset) / 2
              END + 1)                 AS query_text,
    qs.execution_count,
    qs.total_elapsed_time / 1000.0     AS total_elapsed_ms,
    qs.total_elapsed_time / NULLIF(qs.execution_count, 0) / 1000.0 AS avg_elapsed_ms,
    qs.total_logical_reads,
    qs.total_logical_reads / NULLIF(qs.execution_count, 0) AS avg_logical_reads,
    qs.total_worker_time / 1000.0      AS total_cpu_ms,
    qs.plan_generation_num,
    qs.last_execution_time
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
WHERE qs.execution_count > 5
ORDER BY qs.total_elapsed_time / NULLIF(qs.execution_count, 0) DESC;

-- ---------------------------------------------------------------------------
-- 3. Currently running expensive queries
-- ---------------------------------------------------------------------------
SELECT
    r.session_id,
    r.status,
    r.command,
    r.cpu_time,
    r.total_elapsed_time / 1000.0      AS elapsed_ms,
    r.logical_reads,
    r.reads                            AS physical_reads,
    r.writes,
    r.wait_type,
    r.wait_time,
    SUBSTRING(st.text,
              (r.statement_start_offset / 2) + 1,
              CASE r.statement_end_offset
                   WHEN -1 THEN DATALENGTH(st.text)
                   ELSE (r.statement_end_offset - r.statement_start_offset) / 2
              END + 1)                 AS current_statement,
    qp.query_plan
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) st
CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) qp
WHERE r.session_id != @@SPID
  AND r.status = 'running'
ORDER BY r.total_elapsed_time DESC;

-- ---------------------------------------------------------------------------
-- 4. Missing indexes from DMVs (with estimated improvement)
-- ---------------------------------------------------------------------------
SELECT TOP 20
    d.statement                        AS table_name,
    d.equality_columns,
    d.inequality_columns,
    d.included_columns,
    gs.unique_compiles,
    gs.user_seeks,
    gs.user_scans,
    gs.avg_total_user_cost             AS avg_query_cost,
    gs.avg_user_impact                 AS avg_pct_improvement,
    ROUND(gs.avg_total_user_cost * gs.avg_user_impact *
          (gs.user_seeks + gs.user_scans), 0) AS improvement_score,
    'CREATE NONCLUSTERED INDEX [IX_' +
        REPLACE(REPLACE(REPLACE(d.statement, '[', ''), ']', ''), '.', '_') +
        '_missing] ON ' + d.statement + ' (' +
        ISNULL(d.equality_columns, '') +
        CASE WHEN d.equality_columns IS NOT NULL AND d.inequality_columns IS NOT NULL
             THEN ', ' ELSE '' END +
        ISNULL(d.inequality_columns, '') +
        ')' +
        CASE WHEN d.included_columns IS NOT NULL
             THEN ' INCLUDE (' + d.included_columns + ')'
             ELSE '' END               AS suggested_index_ddl
FROM sys.dm_db_missing_index_details d
JOIN sys.dm_db_missing_index_groups g ON d.index_handle = g.index_handle
JOIN sys.dm_db_missing_index_group_stats gs ON g.index_group_handle = gs.group_handle
WHERE d.database_id = DB_ID()
ORDER BY improvement_score DESC;

-- ---------------------------------------------------------------------------
-- 5. Blocking chains
-- ---------------------------------------------------------------------------
SELECT
    blocked.session_id                 AS blocked_session,
    blocked.wait_type,
    blocked.wait_time / 1000.0         AS wait_seconds,
    blocker.session_id                 AS blocker_session,
    SUBSTRING(st_blocked.text, 1, 200) AS blocked_query,
    SUBSTRING(st_blocker.text, 1, 200) AS blocker_query
FROM sys.dm_exec_requests blocked
JOIN sys.dm_exec_sessions blocker ON blocked.blocking_session_id = blocker.session_id
CROSS APPLY sys.dm_exec_sql_text(blocked.sql_handle) st_blocked
OUTER APPLY sys.dm_exec_sql_text(blocker.most_recent_sql_handle) st_blocker
WHERE blocked.blocking_session_id != 0
ORDER BY blocked.wait_time DESC;

-- ---------------------------------------------------------------------------
-- 6. Wait statistics (what is SQL Server waiting on most)
-- ---------------------------------------------------------------------------
SELECT TOP 20
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    signal_wait_time_ms,
    wait_time_ms - signal_wait_time_ms AS resource_wait_ms,
    ROUND(100.0 * wait_time_ms / SUM(wait_time_ms) OVER (), 2) AS pct_of_total
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN (
    'CLR_SEMAPHORE', 'LAZYWRITER_SLEEP', 'RESOURCE_QUEUE',
    'SLEEP_TASK', 'SLEEP_SYSTEMTASK', 'SQLTRACE_BUFFER_FLUSH',
    'WAITFOR', 'LOGMGR_QUEUE', 'CHECKPOINT_QUEUE',
    'REQUEST_FOR_DEADLOCK_SEARCH', 'XE_TIMER_EVENT',
    'BROKER_TO_FLUSH', 'BROKER_TASK_STOP', 'CLR_MANUAL_EVENT',
    'DISPATCHER_QUEUE_SEMAPHORE', 'FT_IFTS_SCHEDULER_IDLE_WAIT',
    'XE_DISPATCHER_WAIT', 'DIRTY_PAGE_POLL', 'HADR_FILESTREAM_IOMGR_IOCOMPLETION'
)
  AND waiting_tasks_count > 0
ORDER BY wait_time_ms DESC;


-- ############################################################################
-- ORACLE
-- ############################################################################

-- ---------------------------------------------------------------------------
-- 1. Top 10 SQL by average elapsed time from V$SQL
-- ---------------------------------------------------------------------------
SELECT *
FROM (
    SELECT
        sql_id,
        SUBSTR(sql_text, 1, 200)       AS query_preview,
        executions,
        ROUND(elapsed_time / NULLIF(executions, 0) / 1e6, 2) AS avg_elapsed_sec,
        ROUND(elapsed_time / 1e6, 0)   AS total_elapsed_sec,
        ROUND(cpu_time / 1e6, 0)       AS total_cpu_sec,
        buffer_gets,
        disk_reads,
        rows_processed
    FROM v$sql
    WHERE executions > 5
      AND parsing_schema_name NOT IN ('SYS', 'SYSTEM')
    ORDER BY elapsed_time / NULLIF(executions, 0) DESC
)
WHERE ROWNUM <= 10;

-- ---------------------------------------------------------------------------
-- 2. Top SQL by total elapsed time (most resource-consuming overall)
-- ---------------------------------------------------------------------------
SELECT *
FROM (
    SELECT
        sql_id,
        SUBSTR(sql_text, 1, 200)       AS query_preview,
        executions,
        ROUND(elapsed_time / 1e6, 0)   AS total_elapsed_sec,
        ROUND(cpu_time / 1e6, 0)       AS total_cpu_sec,
        buffer_gets,
        disk_reads,
        rows_processed,
        ROUND(buffer_gets / NULLIF(executions, 0), 0) AS avg_buffer_gets
    FROM v$sql
    WHERE parsing_schema_name NOT IN ('SYS', 'SYSTEM')
    ORDER BY elapsed_time DESC
)
WHERE ROWNUM <= 10;

-- ---------------------------------------------------------------------------
-- 3. Active Session History (ASH) - top SQL in the last hour
-- ---------------------------------------------------------------------------
SELECT
    sql_id,
    COUNT(*)                           AS sample_count,
    ROUND(COUNT(*) * 10 / 60.0, 1)    AS est_active_minutes,
    MAX(event)                         AS top_wait_event,
    MAX(session_state)                 AS session_state
FROM v$active_session_history
WHERE sample_time > SYSTIMESTAMP - INTERVAL '1' HOUR
  AND sql_id IS NOT NULL
GROUP BY sql_id
ORDER BY sample_count DESC
FETCH FIRST 10 ROWS ONLY;

-- ---------------------------------------------------------------------------
-- 4. Top SQL from AWR (DBA_HIST_SQLSTAT) - last 24 hours
-- Requires Diagnostics Pack license.
-- ---------------------------------------------------------------------------
SELECT *
FROM (
    SELECT
        s.sql_id,
        SUBSTR(t.sql_text, 1, 200)    AS query_preview,
        SUM(s.executions_delta)        AS total_executions,
        ROUND(SUM(s.elapsed_time_delta) / NULLIF(SUM(s.executions_delta), 0) / 1e6, 2) AS avg_elapsed_sec,
        ROUND(SUM(s.elapsed_time_delta) / 1e6, 0) AS total_elapsed_sec,
        SUM(s.buffer_gets_delta)       AS total_buffer_gets,
        SUM(s.disk_reads_delta)        AS total_disk_reads
    FROM dba_hist_sqlstat s
    JOIN dba_hist_sqltext t ON s.sql_id = t.sql_id AND s.dbid = t.dbid
    JOIN dba_hist_snapshot sn ON s.snap_id = sn.snap_id AND s.dbid = sn.dbid AND s.instance_number = sn.instance_number
    WHERE sn.begin_interval_time > SYSTIMESTAMP - INTERVAL '24' HOUR
    GROUP BY s.sql_id, SUBSTR(t.sql_text, 1, 200)
    ORDER BY SUM(s.elapsed_time_delta) DESC
)
WHERE ROWNUM <= 10;

-- ---------------------------------------------------------------------------
-- 5. SQL Plan Baselines - check for plans with poor performance
-- ---------------------------------------------------------------------------
SELECT
    sql_handle,
    plan_name,
    origin,
    enabled,
    accepted,
    fixed,
    ROUND(elapsed_time / NULLIF(executions, 0) / 1e6, 2) AS avg_elapsed_sec,
    executions,
    buffer_gets
FROM dba_sql_plan_baselines
WHERE accepted = 'YES'
  AND executions > 0
ORDER BY elapsed_time / NULLIF(executions, 0) DESC
FETCH FIRST 20 ROWS ONLY;

-- ---------------------------------------------------------------------------
-- 6. Long-running active sessions
-- ---------------------------------------------------------------------------
SELECT
    s.sid,
    s.serial#,
    s.username,
    s.status,
    s.sql_id,
    SUBSTR(q.sql_text, 1, 200)        AS query_preview,
    s.last_call_et                     AS seconds_active,
    s.event                            AS current_wait,
    s.blocking_session
FROM v$session s
LEFT JOIN v$sql q ON s.sql_id = q.sql_id AND s.sql_child_number = q.child_number
WHERE s.status = 'ACTIVE'
  AND s.type = 'USER'
  AND s.last_call_et > 30
ORDER BY s.last_call_et DESC;

-- ---------------------------------------------------------------------------
-- 7. Lock contention
-- ---------------------------------------------------------------------------
SELECT
    s1.sid                             AS blocker_sid,
    s1.username                        AS blocker_user,
    SUBSTR(q1.sql_text, 1, 100)       AS blocker_query,
    s2.sid                             AS waiter_sid,
    s2.username                        AS waiter_user,
    SUBSTR(q2.sql_text, 1, 100)       AS waiter_query,
    l.type                             AS lock_type,
    DECODE(l.lmode,
           0, 'None', 1, 'Null', 2, 'Row-S',
           3, 'Row-X', 4, 'Share', 5, 'S/Row-X',
           6, 'Exclusive')             AS lock_mode,
    s2.seconds_in_wait
FROM v$lock l
JOIN v$session s1 ON l.sid = s1.sid AND l.block = 1
JOIN v$session s2 ON s2.blocking_session = s1.sid
LEFT JOIN v$sql q1 ON s1.sql_id = q1.sql_id AND s1.sql_child_number = q1.child_number
LEFT JOIN v$sql q2 ON s2.sql_id = q2.sql_id AND s2.sql_child_number = q2.child_number
ORDER BY s2.seconds_in_wait DESC;
