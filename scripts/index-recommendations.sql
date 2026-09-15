-- ============================================================================
-- index-recommendations.sql
-- Multi-dialect script for identifying missing, unused, duplicate, and
-- bloated indexes. Run the section matching your database platform.
-- ============================================================================


-- ############################################################################
-- POSTGRESQL
-- ############################################################################

-- ---------------------------------------------------------------------------
-- 1. Tables with high sequential scan ratio (likely missing indexes)
-- ---------------------------------------------------------------------------
SELECT
    schemaname,
    relname                            AS table_name,
    seq_scan,
    idx_scan,
    CASE WHEN (seq_scan + idx_scan) > 0
         THEN round(100.0 * seq_scan / (seq_scan + idx_scan), 1)
         ELSE 0
    END                                AS seq_scan_pct,
    seq_tup_read,
    CASE WHEN seq_scan > 0
         THEN seq_tup_read / seq_scan
         ELSE 0
    END                                AS avg_rows_per_seq_scan,
    pg_size_pretty(pg_relation_size(relid)) AS table_size,
    n_live_tup                         AS estimated_rows
FROM pg_stat_user_tables
WHERE seq_scan > 50
  AND pg_relation_size(relid) > 10 * 1024 * 1024  -- only tables > 10 MB
  AND (seq_scan + idx_scan) > 0
  AND round(100.0 * seq_scan / (seq_scan + idx_scan), 1) > 50
ORDER BY seq_tup_read DESC
LIMIT 20;

-- ---------------------------------------------------------------------------
-- 2. Unused indexes (candidates for removal)
--    Indexes with zero scans since the last stats reset.
--    Always check pg_stat_reset() timing before dropping!
-- ---------------------------------------------------------------------------
SELECT
    s.schemaname,
    s.relname                          AS table_name,
    s.indexrelname                     AS index_name,
    s.idx_scan                         AS times_used,
    pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size,
    pg_size_pretty(pg_relation_size(s.relid))      AS table_size,
    i.indexdef
FROM pg_stat_user_indexes s
JOIN pg_indexes i ON i.schemaname = s.schemaname
                  AND i.tablename = s.relname
                  AND i.indexname = s.indexrelname
WHERE s.idx_scan = 0
  AND s.schemaname NOT IN ('pg_catalog', 'information_schema')
  -- Exclude primary keys and unique constraints (they enforce integrity)
  AND NOT EXISTS (
      SELECT 1 FROM pg_constraint c
      WHERE c.conindid = s.indexrelid
        AND c.contype IN ('p', 'u')
  )
ORDER BY pg_relation_size(s.indexrelid) DESC
LIMIT 30;

-- ---------------------------------------------------------------------------
-- 3. Duplicate indexes (indexes on the same columns in the same order)
-- ---------------------------------------------------------------------------
SELECT
    a.indrelid::regclass               AS table_name,
    a.indexrelid::regclass             AS index_a,
    b.indexrelid::regclass             AS index_b,
    pg_size_pretty(pg_relation_size(a.indexrelid)) AS index_a_size,
    pg_size_pretty(pg_relation_size(b.indexrelid)) AS index_b_size,
    array_to_string(ARRAY(
        SELECT attname FROM pg_attribute
        WHERE attrelid = a.indrelid AND attnum = ANY(a.indkey)
        ORDER BY array_position(a.indkey, attnum)
    ), ', ')                           AS columns
FROM pg_index a
JOIN pg_index b ON a.indrelid = b.indrelid
               AND a.indexrelid != b.indexrelid
               AND a.indkey = b.indkey
               AND a.indclass = b.indclass
WHERE a.indexrelid < b.indexrelid  -- avoid duplicate pairs
  AND a.indrelid::regclass::text NOT LIKE 'pg_%'
ORDER BY pg_relation_size(a.indexrelid) DESC;

-- ---------------------------------------------------------------------------
-- 4. Overlapping indexes (one index is a prefix of another)
-- ---------------------------------------------------------------------------
SELECT
    a.indrelid::regclass               AS table_name,
    a.indexrelid::regclass             AS shorter_index,
    b.indexrelid::regclass             AS longer_index,
    pg_size_pretty(pg_relation_size(a.indexrelid)) AS shorter_index_size,
    array_to_string(ARRAY(
        SELECT attname FROM pg_attribute
        WHERE attrelid = a.indrelid AND attnum = ANY(a.indkey)
        ORDER BY array_position(a.indkey, attnum)
    ), ', ')                           AS shorter_columns,
    array_to_string(ARRAY(
        SELECT attname FROM pg_attribute
        WHERE attrelid = b.indrelid AND attnum = ANY(b.indkey)
        ORDER BY array_position(b.indkey, attnum)
    ), ', ')                           AS longer_columns
FROM pg_index a
JOIN pg_index b ON a.indrelid = b.indrelid
               AND a.indexrelid != b.indexrelid
               AND a.indkey != b.indkey
WHERE a.indrelid::regclass::text NOT LIKE 'pg_%'
  AND a.indkey <@ b.indkey
  AND (
      -- First N columns of longer index match all columns of shorter index in order
      a.indkey = b.indkey[0:array_length(a.indkey, 1) - 1]
  )
ORDER BY pg_relation_size(a.indexrelid) DESC;

-- ---------------------------------------------------------------------------
-- 5. Index bloat estimation
--    High bloat means the index has many dead entries and wasted space.
-- ---------------------------------------------------------------------------
SELECT
    current_database()                 AS db,
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    pg_size_pretty(pg_relation_size(relid))      AS table_size,
    round(
        CASE WHEN pg_relation_size(relid) > 0
             THEN 100.0 * pg_relation_size(indexrelid) / pg_relation_size(relid)
             ELSE 0
        END, 1
    )                                  AS index_to_table_pct
FROM pg_stat_user_indexes
JOIN pg_indexes ON pg_stat_user_indexes.indexrelname = pg_indexes.indexname
               AND pg_stat_user_indexes.schemaname = pg_indexes.schemaname
WHERE pg_relation_size(indexrelid) > 50 * 1024 * 1024  -- indexes > 50 MB
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 20;

-- For more precise bloat estimation, use pgstattuple:
-- CREATE EXTENSION IF NOT EXISTS pgstattuple;
-- SELECT * FROM pgstatindex('idx_orders_customer');
-- Look at: avg_leaf_density (should be > 70%), leaf_fragmentation

-- ---------------------------------------------------------------------------
-- 6. Indexes larger than their tables
-- ---------------------------------------------------------------------------
SELECT
    s.schemaname,
    s.relname                          AS table_name,
    s.indexrelname                     AS index_name,
    pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size,
    pg_size_pretty(pg_relation_size(s.relid))      AS table_size,
    round(
        pg_relation_size(s.indexrelid)::numeric /
        NULLIF(pg_relation_size(s.relid), 0), 2
    )                                  AS index_to_table_ratio
FROM pg_stat_user_indexes s
WHERE pg_relation_size(s.indexrelid) > pg_relation_size(s.relid)
  AND pg_relation_size(s.relid) > 1024 * 1024  -- ignore tiny tables
ORDER BY pg_relation_size(s.indexrelid) - pg_relation_size(s.relid) DESC;

-- ---------------------------------------------------------------------------
-- 7. Reindex bloated indexes (run during maintenance window)
-- ---------------------------------------------------------------------------
-- REINDEX INDEX CONCURRENTLY idx_orders_customer;  -- PostgreSQL 12+
-- REINDEX TABLE CONCURRENTLY orders;


-- ############################################################################
-- MYSQL
-- ############################################################################

-- ---------------------------------------------------------------------------
-- 1. Unused indexes (from sys schema, MySQL 5.7+)
-- ---------------------------------------------------------------------------
SELECT
    object_schema                      AS db_name,
    object_name                        AS table_name,
    index_name
FROM sys.schema_unused_indexes
WHERE object_schema NOT IN ('mysql', 'sys', 'performance_schema', 'information_schema')
ORDER BY object_schema, object_name;

-- ---------------------------------------------------------------------------
-- 2. Redundant indexes (from sys schema)
--    An index is redundant if another index has it as a prefix.
-- ---------------------------------------------------------------------------
SELECT
    table_schema                       AS db_name,
    table_name,
    redundant_index_name,
    redundant_index_columns,
    dominant_index_name,
    dominant_index_columns,
    subpart_exists,
    sql_drop_index
FROM sys.schema_redundant_indexes
WHERE table_schema NOT IN ('mysql', 'sys', 'performance_schema', 'information_schema')
ORDER BY table_schema, table_name;

-- ---------------------------------------------------------------------------
-- 3. Tables without primary keys
--    These cause performance issues with replication and have no clustered index control.
-- ---------------------------------------------------------------------------
SELECT
    t.TABLE_SCHEMA                     AS db_name,
    t.TABLE_NAME,
    t.ENGINE,
    t.TABLE_ROWS                       AS estimated_rows,
    ROUND(t.DATA_LENGTH / 1024 / 1024, 1) AS data_mb
FROM information_schema.TABLES t
LEFT JOIN information_schema.TABLE_CONSTRAINTS tc
    ON t.TABLE_SCHEMA = tc.TABLE_SCHEMA
   AND t.TABLE_NAME = tc.TABLE_NAME
   AND tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
WHERE t.TABLE_SCHEMA NOT IN ('mysql', 'sys', 'performance_schema', 'information_schema')
  AND t.TABLE_TYPE = 'BASE TABLE'
  AND tc.CONSTRAINT_NAME IS NULL
ORDER BY t.TABLE_ROWS DESC;

-- ---------------------------------------------------------------------------
-- 4. Full table scans from Performance Schema (tables frequently scanned)
-- ---------------------------------------------------------------------------
SELECT
    OBJECT_SCHEMA                      AS db_name,
    OBJECT_NAME                        AS table_name,
    COUNT_READ                         AS total_reads,
    COUNT_FETCH                        AS rows_fetched,
    ROUND(SUM_TIMER_FETCH / 1e12, 2)  AS total_fetch_sec
FROM performance_schema.table_io_waits_summary_by_table
WHERE OBJECT_SCHEMA NOT IN ('mysql', 'sys', 'performance_schema', 'information_schema')
  AND COUNT_FETCH > 100000
ORDER BY COUNT_FETCH DESC
LIMIT 20;

-- ---------------------------------------------------------------------------
-- 5. Index cardinality check (low-cardinality indexes may not help)
-- ---------------------------------------------------------------------------
SELECT
    TABLE_SCHEMA                       AS db_name,
    TABLE_NAME,
    INDEX_NAME,
    GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS index_columns,
    MAX(CARDINALITY)                   AS max_cardinality,
    (SELECT TABLE_ROWS
     FROM information_schema.TABLES t
     WHERE t.TABLE_SCHEMA = s.TABLE_SCHEMA AND t.TABLE_NAME = s.TABLE_NAME
    )                                  AS estimated_rows,
    CASE
        WHEN (SELECT TABLE_ROWS FROM information_schema.TABLES t
              WHERE t.TABLE_SCHEMA = s.TABLE_SCHEMA AND t.TABLE_NAME = s.TABLE_NAME) > 0
        THEN ROUND(100.0 * MAX(CARDINALITY) /
             (SELECT TABLE_ROWS FROM information_schema.TABLES t
              WHERE t.TABLE_SCHEMA = s.TABLE_SCHEMA AND t.TABLE_NAME = s.TABLE_NAME), 1)
        ELSE 0
    END                                AS selectivity_pct
FROM information_schema.STATISTICS s
WHERE TABLE_SCHEMA NOT IN ('mysql', 'sys', 'performance_schema', 'information_schema')
GROUP BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME
HAVING selectivity_pct < 1.0   -- less than 1% selectivity = very low cardinality
   AND estimated_rows > 10000
ORDER BY estimated_rows DESC;

-- ---------------------------------------------------------------------------
-- 6. Index sizes per table
-- ---------------------------------------------------------------------------
SELECT
    TABLE_SCHEMA                       AS db_name,
    TABLE_NAME,
    ROUND(DATA_LENGTH / 1024 / 1024, 1) AS data_mb,
    ROUND(INDEX_LENGTH / 1024 / 1024, 1) AS index_mb,
    CASE WHEN DATA_LENGTH > 0
         THEN ROUND(100.0 * INDEX_LENGTH / DATA_LENGTH, 1)
         ELSE 0
    END                                AS index_to_data_pct,
    TABLE_ROWS                         AS estimated_rows
FROM information_schema.TABLES
WHERE TABLE_SCHEMA NOT IN ('mysql', 'sys', 'performance_schema', 'information_schema')
  AND TABLE_TYPE = 'BASE TABLE'
  AND INDEX_LENGTH > 50 * 1024 * 1024  -- indexes > 50 MB
ORDER BY INDEX_LENGTH DESC
LIMIT 20;

-- ---------------------------------------------------------------------------
-- 7. InnoDB index fragmentation estimate
-- ---------------------------------------------------------------------------
SELECT
    TABLE_SCHEMA                       AS db_name,
    TABLE_NAME,
    DATA_LENGTH,
    DATA_FREE,
    ROUND(100.0 * DATA_FREE / NULLIF(DATA_LENGTH + DATA_FREE, 0), 1) AS frag_pct
FROM information_schema.TABLES
WHERE TABLE_SCHEMA NOT IN ('mysql', 'sys', 'performance_schema', 'information_schema')
  AND ENGINE = 'InnoDB'
  AND DATA_FREE > 10 * 1024 * 1024  -- > 10 MB free
ORDER BY DATA_FREE DESC
LIMIT 20;

-- To defragment: ALTER TABLE tablename ENGINE=InnoDB;  (online DDL in 5.6+)
-- Or: OPTIMIZE TABLE tablename;


-- ############################################################################
-- SQL SERVER
-- ############################################################################

-- ---------------------------------------------------------------------------
-- 1. Missing indexes from DMVs (with estimated improvement and suggested DDL)
-- ---------------------------------------------------------------------------
SELECT TOP 30
    DB_NAME(d.database_id)             AS database_name,
    d.statement                        AS table_name,
    d.equality_columns,
    d.inequality_columns,
    d.included_columns,
    gs.user_seeks,
    gs.user_scans,
    gs.unique_compiles,
    ROUND(gs.avg_total_user_cost, 2)   AS avg_query_cost,
    ROUND(gs.avg_user_impact, 1)       AS avg_pct_improvement,
    ROUND(gs.avg_total_user_cost * gs.avg_user_impact *
          (gs.user_seeks + gs.user_scans), 0) AS improvement_score,
    -- Suggested CREATE INDEX statement
    'CREATE NONCLUSTERED INDEX [IX_' +
        REPLACE(REPLACE(REPLACE(d.statement, '[', ''), ']', ''), '.', '_') +
        '] ON ' + d.statement + ' (' +
        ISNULL(d.equality_columns, '') +
        CASE WHEN d.equality_columns IS NOT NULL AND d.inequality_columns IS NOT NULL
             THEN ', ' ELSE '' END +
        ISNULL(d.inequality_columns, '') +
        ')' +
        CASE WHEN d.included_columns IS NOT NULL
             THEN ' INCLUDE (' + d.included_columns + ')'
             ELSE '' END +
        ';'                            AS suggested_ddl
FROM sys.dm_db_missing_index_details d
JOIN sys.dm_db_missing_index_groups g ON d.index_handle = g.index_handle
JOIN sys.dm_db_missing_index_group_stats gs ON g.index_group_handle = gs.group_handle
WHERE d.database_id = DB_ID()
ORDER BY improvement_score DESC;

-- ---------------------------------------------------------------------------
-- 2. Unused indexes (never seeked, scanned, or looked up since last restart)
-- ---------------------------------------------------------------------------
SELECT
    OBJECT_SCHEMA_NAME(i.object_id)    AS schema_name,
    OBJECT_NAME(i.object_id)           AS table_name,
    i.name                             AS index_name,
    i.type_desc,
    s.user_seeks,
    s.user_scans,
    s.user_lookups,
    s.user_updates,
    pg.rows                            AS table_rows,
    ROUND(
        (SUM(a.used_pages) * 8.0) / 1024, 1
    )                                  AS index_size_mb
FROM sys.indexes i
JOIN sys.dm_db_index_usage_stats s ON i.object_id = s.object_id AND i.index_id = s.index_id
JOIN sys.partitions pg ON i.object_id = pg.object_id AND i.index_id = pg.index_id
JOIN sys.allocation_units a ON pg.partition_id = a.container_id
WHERE OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
  AND s.database_id = DB_ID()
  AND i.type_desc != 'CLUSTERED'       -- never drop the clustered index
  AND i.is_primary_key = 0             -- never drop primary keys
  AND i.is_unique_constraint = 0       -- never drop unique constraints
  AND s.user_seeks = 0
  AND s.user_scans = 0
  AND s.user_lookups = 0
  AND s.user_updates > 100             -- index is maintained but never used
GROUP BY OBJECT_SCHEMA_NAME(i.object_id), OBJECT_NAME(i.object_id),
         i.name, i.type_desc, s.user_seeks, s.user_scans,
         s.user_lookups, s.user_updates, pg.rows
ORDER BY s.user_updates DESC;

-- ---------------------------------------------------------------------------
-- 3. Duplicate indexes (same key columns in the same order)
-- ---------------------------------------------------------------------------
;WITH IndexColumns AS (
    SELECT
        i.object_id,
        i.index_id,
        i.name AS index_name,
        i.type_desc,
        i.is_unique,
        STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.key_ordinal) AS key_columns,
        STRING_AGG(
            CASE WHEN ic.is_included_column = 1 THEN c.name END, ', '
        ) WITHIN GROUP (ORDER BY c.name) AS included_columns
    FROM sys.indexes i
    JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id
    JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
    WHERE OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
      AND i.type IN (1, 2)  -- clustered and nonclustered
    GROUP BY i.object_id, i.index_id, i.name, i.type_desc, i.is_unique
)
SELECT
    OBJECT_SCHEMA_NAME(a.object_id)    AS schema_name,
    OBJECT_NAME(a.object_id)           AS table_name,
    a.index_name                       AS index_a,
    b.index_name                       AS index_b,
    a.key_columns,
    a.included_columns                 AS index_a_includes,
    b.included_columns                 AS index_b_includes,
    a.type_desc                        AS index_a_type,
    b.type_desc                        AS index_b_type
FROM IndexColumns a
JOIN IndexColumns b ON a.object_id = b.object_id
                    AND a.key_columns = b.key_columns
                    AND a.index_id < b.index_id
ORDER BY OBJECT_NAME(a.object_id), a.key_columns;

-- ---------------------------------------------------------------------------
-- 4. Index fragmentation (focus on heavily fragmented, large indexes)
-- ---------------------------------------------------------------------------
SELECT
    OBJECT_SCHEMA_NAME(ips.object_id)  AS schema_name,
    OBJECT_NAME(ips.object_id)         AS table_name,
    i.name                             AS index_name,
    i.type_desc,
    ROUND(ips.avg_fragmentation_in_percent, 1) AS frag_pct,
    ips.page_count,
    ROUND(ips.page_count * 8.0 / 1024, 1) AS index_size_mb,
    CASE
        WHEN ips.avg_fragmentation_in_percent > 30 THEN 'REBUILD'
        WHEN ips.avg_fragmentation_in_percent > 10 THEN 'REORGANIZE'
        ELSE 'OK'
    END                                AS recommendation
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
JOIN sys.indexes i ON ips.object_id = i.object_id AND ips.index_id = i.index_id
WHERE ips.page_count > 1000            -- only indexes > ~8 MB
  AND ips.avg_fragmentation_in_percent > 10
  AND OBJECTPROPERTY(ips.object_id, 'IsUserTable') = 1
ORDER BY ips.avg_fragmentation_in_percent DESC;

-- To defragment:
-- ALTER INDEX idx_name ON dbo.table_name REORGANIZE;      -- < 30% fragmentation
-- ALTER INDEX idx_name ON dbo.table_name REBUILD ONLINE;  -- > 30% fragmentation (Enterprise only for ONLINE)

-- ---------------------------------------------------------------------------
-- 5. Index operational stats (which indexes have the most physical I/O)
-- ---------------------------------------------------------------------------
SELECT TOP 20
    OBJECT_SCHEMA_NAME(os.object_id)   AS schema_name,
    OBJECT_NAME(os.object_id)          AS table_name,
    i.name                             AS index_name,
    os.leaf_insert_count + os.leaf_update_count + os.leaf_delete_count AS leaf_modifications,
    os.range_scan_count,
    os.singleton_lookup_count,
    os.page_latch_wait_count,
    os.page_latch_wait_in_ms
FROM sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) os
JOIN sys.indexes i ON os.object_id = i.object_id AND os.index_id = i.index_id
WHERE OBJECTPROPERTY(os.object_id, 'IsUserTable') = 1
ORDER BY leaf_modifications DESC;

-- ---------------------------------------------------------------------------
-- 6. Columnstore index candidates (tables with many rows and analytical queries)
-- ---------------------------------------------------------------------------
SELECT
    OBJECT_SCHEMA_NAME(t.object_id)    AS schema_name,
    t.name                             AS table_name,
    p.rows,
    ROUND(
        SUM(a.used_pages) * 8.0 / 1024, 1
    )                                  AS total_size_mb
FROM sys.tables t
JOIN sys.partitions p ON t.object_id = p.object_id AND p.index_id IN (0, 1)
JOIN sys.allocation_units a ON p.partition_id = a.container_id
WHERE p.rows > 1000000  -- tables with > 1M rows are candidates for columnstore
GROUP BY OBJECT_SCHEMA_NAME(t.object_id), t.name, t.object_id, p.rows
ORDER BY p.rows DESC;


-- ############################################################################
-- ORACLE
-- ############################################################################

-- ---------------------------------------------------------------------------
-- 1. Index usage tracking (Oracle 12.2+ DBA_INDEX_USAGE)
-- ---------------------------------------------------------------------------
-- Enable monitoring for all indexes (if not using 19c+ automatic tracking):
-- ALTER INDEX idx_name MONITORING USAGE;

-- Oracle 19c+ automatic index usage tracking:
SELECT
    u.name                             AS index_name,
    u.owner,
    u.total_access_count,
    u.total_exec_count,
    u.total_rows_returned,
    u.last_used,
    i.table_name,
    i.index_type,
    ROUND(s.bytes / 1024 / 1024, 1)   AS index_size_mb
FROM dba_index_usage u
JOIN dba_indexes i ON u.owner = i.owner AND u.name = i.index_name
LEFT JOIN dba_segments s ON s.owner = i.owner AND s.segment_name = i.index_name AND s.segment_type LIKE 'INDEX%'
WHERE u.owner NOT IN ('SYS', 'SYSTEM', 'OUTLN')
ORDER BY u.total_access_count ASC
FETCH FIRST 30 ROWS ONLY;

-- Pre-19c: check V$OBJECT_USAGE for monitored indexes
SELECT
    u.index_name,
    u.table_name,
    u.monitoring,
    u.used,
    u.start_monitoring,
    u.end_monitoring
FROM v$object_usage u
WHERE u.used = 'NO'
ORDER BY u.index_name;

-- ---------------------------------------------------------------------------
-- 2. Invisible indexes (for safe testing before dropping)
-- ---------------------------------------------------------------------------
-- Make an index invisible (queries won't use it, but it's still maintained)
-- ALTER INDEX idx_orders_status INVISIBLE;

-- Check if anything breaks, then drop it if safe:
-- DROP INDEX idx_orders_status;

-- Or make it visible again:
-- ALTER INDEX idx_orders_status VISIBLE;

-- List all invisible indexes:
SELECT
    owner,
    index_name,
    table_name,
    index_type,
    visibility,
    status
FROM dba_indexes
WHERE visibility = 'INVISIBLE'
  AND owner NOT IN ('SYS', 'SYSTEM')
ORDER BY owner, table_name;

-- Test with optimizer hint to use invisible index:
-- SELECT /*+ USE_INVISIBLE_INDEXES */ * FROM orders WHERE status = 'pending';
-- Or session-level: ALTER SESSION SET optimizer_use_invisible_indexes = TRUE;

-- ---------------------------------------------------------------------------
-- 3. Unused indexes (from DBA_INDEX_USAGE, 19c+)
-- ---------------------------------------------------------------------------
SELECT
    i.owner,
    i.table_name,
    i.index_name,
    i.index_type,
    ROUND(s.bytes / 1024 / 1024, 1)   AS index_size_mb,
    u.total_access_count,
    u.last_used
FROM dba_indexes i
LEFT JOIN dba_index_usage u ON i.owner = u.owner AND i.index_name = u.name
LEFT JOIN dba_segments s ON s.owner = i.owner AND s.segment_name = i.index_name AND s.segment_type LIKE 'INDEX%'
WHERE i.owner NOT IN ('SYS', 'SYSTEM', 'OUTLN', 'XDB', 'WMSYS')
  AND (u.total_access_count = 0 OR u.total_access_count IS NULL)
  AND i.uniqueness = 'NONUNIQUE'       -- don't recommend dropping unique indexes
  AND NOT EXISTS (                      -- don't recommend dropping PK/FK supporting indexes
      SELECT 1 FROM dba_constraints c
      WHERE c.owner = i.owner
        AND c.index_name = i.index_name
        AND c.constraint_type IN ('P', 'U')
  )
ORDER BY s.bytes DESC NULLS LAST
FETCH FIRST 30 ROWS ONLY;

-- ---------------------------------------------------------------------------
-- 4. Duplicate indexes (same columns, same order)
-- ---------------------------------------------------------------------------
SELECT
    a.owner,
    a.table_name,
    a.index_name                       AS index_a,
    b.index_name                       AS index_b,
    a.columns                          AS shared_columns,
    ROUND(sa.bytes / 1024 / 1024, 1)  AS index_a_size_mb,
    ROUND(sb.bytes / 1024 / 1024, 1)  AS index_b_size_mb
FROM (
    SELECT owner, table_name, index_name,
           LISTAGG(column_name, ', ') WITHIN GROUP (ORDER BY column_position) AS columns
    FROM dba_ind_columns
    WHERE index_owner NOT IN ('SYS', 'SYSTEM')
    GROUP BY owner, table_name, index_name
) a
JOIN (
    SELECT owner, table_name, index_name,
           LISTAGG(column_name, ', ') WITHIN GROUP (ORDER BY column_position) AS columns
    FROM dba_ind_columns
    WHERE index_owner NOT IN ('SYS', 'SYSTEM')
    GROUP BY owner, table_name, index_name
) b ON a.owner = b.owner
   AND a.table_name = b.table_name
   AND a.columns = b.columns
   AND a.index_name < b.index_name
LEFT JOIN dba_segments sa ON sa.owner = a.owner AND sa.segment_name = a.index_name AND sa.segment_type LIKE 'INDEX%'
LEFT JOIN dba_segments sb ON sb.owner = b.owner AND sb.segment_name = b.index_name AND sb.segment_type LIKE 'INDEX%'
ORDER BY sa.bytes DESC NULLS LAST;

-- ---------------------------------------------------------------------------
-- 5. Index clustering factor (high value = poor correlation with table order)
-- ---------------------------------------------------------------------------
SELECT
    i.owner,
    i.table_name,
    i.index_name,
    i.clustering_factor,
    t.num_rows,
    t.blocks                           AS table_blocks,
    CASE
        WHEN t.blocks > 0 THEN ROUND(i.clustering_factor / t.blocks, 1)
        ELSE 0
    END                                AS cf_to_blocks_ratio,
    -- Ratio close to 1 = well-clustered; close to num_rows = poorly clustered
    CASE
        WHEN i.clustering_factor <= t.blocks * 2 THEN 'WELL_CLUSTERED'
        WHEN i.clustering_factor >= t.num_rows * 0.5 THEN 'POORLY_CLUSTERED'
        ELSE 'MODERATE'
    END                                AS clustering_assessment
FROM dba_indexes i
JOIN dba_tables t ON i.owner = t.owner AND i.table_name = t.table_name
WHERE i.owner NOT IN ('SYS', 'SYSTEM', 'OUTLN')
  AND t.num_rows > 10000
  AND i.index_type = 'NORMAL'
ORDER BY i.clustering_factor / NULLIF(t.blocks, 0) DESC
FETCH FIRST 20 ROWS ONLY;

-- ---------------------------------------------------------------------------
-- 6. Tables that may benefit from indexes (high full table scan count)
-- ---------------------------------------------------------------------------
SELECT
    owner,
    object_name                        AS table_name,
    statistic_name,
    value                              AS full_scan_count
FROM v$segment_statistics
WHERE statistic_name = 'segment scans'
  AND value > 1000
  AND owner NOT IN ('SYS', 'SYSTEM')
ORDER BY value DESC
FETCH FIRST 20 ROWS ONLY;

-- ---------------------------------------------------------------------------
-- 7. Index fragmentation / space analysis
-- ---------------------------------------------------------------------------
-- Use DBMS_SPACE.SPACE_USAGE or ANALYZE INDEX ... VALIDATE STRUCTURE
-- for detailed stats. Quick check via DBA_IND_STATISTICS:
SELECT
    i.owner,
    i.index_name,
    i.table_name,
    ROUND(s.bytes / 1024 / 1024, 1)   AS index_size_mb,
    i.blevel                           AS tree_height,
    i.leaf_blocks,
    i.distinct_keys,
    i.num_rows                         AS index_rows,
    CASE WHEN i.leaf_blocks > 0
         THEN ROUND(i.distinct_keys / i.leaf_blocks, 1)
         ELSE 0
    END                                AS keys_per_leaf_block
FROM dba_indexes i
LEFT JOIN dba_segments s ON s.owner = i.owner AND s.segment_name = i.index_name AND s.segment_type LIKE 'INDEX%'
WHERE i.owner NOT IN ('SYS', 'SYSTEM')
  AND i.blevel >= 3                    -- indexes with height >= 3 may need investigation
ORDER BY i.blevel DESC, s.bytes DESC NULLS LAST
FETCH FIRST 20 ROWS ONLY;

-- To rebuild a fragmented index:
-- ALTER INDEX schema.idx_name REBUILD ONLINE;
-- ALTER INDEX schema.idx_name COALESCE;  -- lighter-weight, reclaims leaf blocks
