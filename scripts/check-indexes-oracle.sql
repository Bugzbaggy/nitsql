-- ==========================================================================
-- SQL Valid8 (example) - Oracle Index Health Check
-- Dialect: Oracle Database
-- Minimum version: Oracle 19c+ (some queries require 12c+ features)
-- ==========================================================================
-- Run as a DBA user or a user with SELECT privileges on DBA_ views.
-- Required privileges: SELECT ANY DICTIONARY or SELECT_CATALOG_ROLE.
-- For other dialects, see:
--   check-indexes-mssql.sql
--   check-indexes-postgresql.sql
--   check-indexes-mysql.sql
-- ==========================================================================

-- ============================================================================
-- 1. FULL TABLE SCANS ON LARGE TABLES (Potential missing indexes)
-- ============================================================================
-- What: Identifies SQL statements performing full table scans on tables that
--       are frequently accessed. Full scans on large tables are expensive.
-- Look for: High execution count + large elapsed_sec values.
-- Remediation: Create indexes on filter/join columns identified in the SQL.
-- Note: v$sql_plan is in-memory only; data is lost on instance restart.
-- ============================================================================

SELECT s.sql_id,
       p.object_owner,
       p.object_name,
       p.operation,
       p.options,
       s.executions,
       ROUND(s.elapsed_time / 1000000, 2) AS elapsed_sec,
       s.buffer_gets,
       s.disk_reads,
       SUBSTR(s.sql_text, 1, 200) AS sql_preview
FROM v$sql_plan p
JOIN v$sql s ON p.sql_id = s.sql_id AND p.child_number = s.child_number
WHERE p.operation = 'TABLE ACCESS'
  AND p.options = 'FULL'
  AND s.executions > 100
  AND p.object_owner NOT IN ('SYS', 'SYSTEM', 'DBSNMP', 'OUTLN', 'MDSYS', 'CTXSYS')
ORDER BY s.elapsed_time DESC
FETCH FIRST 20 ROWS ONLY;

-- ============================================================================
-- 2. UNUSED INDEXES (Oracle 12.2+ DBA_INDEX_USAGE)
-- ============================================================================
-- What: Identifies indexes that have never been used according to Oracle's
--       index usage tracking (12.2+). Unused indexes waste space and slow DML.
-- Look for: Indexes with total_access_count = 0.
-- Remediation: Validate over a full business cycle, then make INVISIBLE first:
--   ALTER INDEX <owner>.<index_name> INVISIBLE;
--   -- Monitor for regressions, then DROP if safe.
-- Note: For pre-12.2, use ALTER INDEX ... MONITORING USAGE + V$OBJECT_USAGE.
-- ============================================================================

SELECT owner,
       index_name,
       table_name,
       total_access_count,
       total_rows_returned,
       last_used
FROM dba_index_usage
WHERE total_access_count = 0
  AND owner NOT IN ('SYS', 'SYSTEM', 'OUTLN', 'DBSNMP', 'MDSYS', 'CTXSYS')
ORDER BY owner, index_name;

-- ============================================================================
-- 3. INDEX FRAGMENTATION / STATISTICS (High B-Tree levels)
-- ============================================================================
-- What: Indexes with high B-Tree levels (blevel > 3) may be inefficient.
--       High clustering_factor indicates poor correlation between index and
--       table row order, leading to excessive I/O.
-- Look for: blevel > 3, clustering_factor >> num_rows.
-- Remediation: ALTER INDEX <index> REBUILD [ONLINE];
--              or COALESCE for less intrusive maintenance.
-- ============================================================================

SELECT owner,
       index_name,
       table_name,
       index_type,
       blevel,
       leaf_blocks,
       clustering_factor,
       num_rows,
       distinct_keys,
       avg_leaf_blocks_per_key,
       avg_data_blocks_per_key,
       CASE
           WHEN blevel > 4 THEN 'CRITICAL: Consider rebuilding'
           WHEN blevel > 3 THEN 'WARNING: Monitor and consider rebuild'
           ELSE 'OK'
       END AS recommendation
FROM dba_indexes
WHERE owner NOT IN ('SYS', 'SYSTEM', 'OUTLN', 'DBSNMP', 'MDSYS', 'CTXSYS',
                     'XDB', 'WMSYS', 'ORDSYS', 'APEX_PUBLIC_USER')
  AND blevel > 3
ORDER BY blevel DESC, leaf_blocks DESC;

-- ============================================================================
-- 4. DUPLICATE INDEXES (Same leading columns)
-- ============================================================================
-- What: Finds indexes that share the same leading column(s), which typically
--       means one is redundant. Exact duplicates are always wasteful.
-- Look for: Pairs sharing identical leading columns.
-- Remediation: Keep the broader index; drop the narrower duplicate.
-- ============================================================================

WITH idx_cols AS (
    SELECT
        ic.table_owner,
        ic.table_name,
        ic.index_name,
        LISTAGG(ic.column_name, ',') WITHIN GROUP (ORDER BY ic.column_position) AS col_list
    FROM dba_ind_columns ic
    WHERE ic.table_owner NOT IN ('SYS', 'SYSTEM', 'OUTLN', 'DBSNMP', 'MDSYS', 'CTXSYS')
    GROUP BY ic.table_owner, ic.table_name, ic.index_name
)
SELECT
    a.table_owner,
    a.table_name,
    a.index_name AS index_1,
    b.index_name AS index_2,
    a.col_list AS index_1_columns,
    b.col_list AS index_2_columns,
    'Review and drop redundant index' AS recommendation
FROM idx_cols a
JOIN idx_cols b
    ON a.table_owner = b.table_owner
    AND a.table_name = b.table_name
    AND a.col_list = b.col_list
    AND a.index_name < b.index_name
ORDER BY a.table_owner, a.table_name;

-- ============================================================================
-- 5. INVISIBLE INDEXES (Candidates for dropping)
-- ============================================================================
-- What: Invisible indexes are not used by the optimizer but still maintained
--       on DML. They are often left invisible after testing.
-- Look for: Indexes that have been invisible for an extended period.
-- Remediation: If no performance regression observed, DROP INDEX.
-- ============================================================================

SELECT owner,
       index_name,
       table_name,
       index_type,
       visibility,
       status,
       last_analyzed,
       num_rows,
       'Index is INVISIBLE - if not needed, consider dropping' AS recommendation
FROM dba_indexes
WHERE visibility = 'INVISIBLE'
  AND owner NOT IN ('SYS', 'SYSTEM')
ORDER BY owner, table_name, index_name;

-- ============================================================================
-- 6. TABLES WITHOUT PRIMARY KEYS
-- ============================================================================
-- What: Tables without a primary key may have data integrity issues and
--       cannot be used efficiently with certain replication mechanisms
--       (e.g., GoldenGate supplemental logging).
-- Look for: Any user tables returned here.
-- Remediation: Add a PRIMARY KEY constraint.
-- ============================================================================

SELECT t.owner,
       t.table_name,
       t.num_rows,
       t.last_analyzed
FROM dba_tables t
WHERE t.owner NOT IN ('SYS', 'SYSTEM', 'OUTLN', 'DBSNMP', 'MDSYS', 'CTXSYS',
                       'XDB', 'WMSYS', 'ORDSYS', 'APEX_PUBLIC_USER')
  AND NOT EXISTS (
      SELECT 1
      FROM dba_constraints c
      WHERE c.owner = t.owner
        AND c.table_name = t.table_name
        AND c.constraint_type = 'P'
  )
  AND t.num_rows > 0
ORDER BY t.num_rows DESC NULLS LAST
FETCH FIRST 50 ROWS ONLY;

-- ============================================================================
-- 7. STALE INDEX STATISTICS
-- ============================================================================
-- What: Indexes with stale or missing statistics can cause the optimizer
--       to choose suboptimal execution plans.
-- Look for: last_analyzed older than 30 days or NULL.
-- Remediation: EXEC DBMS_STATS.GATHER_INDEX_STATS('<owner>', '<index>');
-- ============================================================================

SELECT owner,
       index_name,
       table_name,
       num_rows,
       last_analyzed,
       ROUND(SYSDATE - last_analyzed) AS days_since_analyzed,
       CASE
           WHEN last_analyzed IS NULL THEN 'CRITICAL: Never analyzed'
           WHEN SYSDATE - last_analyzed > 30 THEN 'WARNING: Stale statistics (>30 days)'
           ELSE 'OK'
       END AS recommendation
FROM dba_indexes
WHERE owner NOT IN ('SYS', 'SYSTEM', 'OUTLN', 'DBSNMP', 'MDSYS', 'CTXSYS')
  AND (last_analyzed IS NULL OR SYSDATE - last_analyzed > 30)
  AND num_rows > 0
ORDER BY last_analyzed NULLS FIRST
FETCH FIRST 30 ROWS ONLY;

-- ============================================================================
-- 8. INDEX COMPRESSION CANDIDATES
-- ============================================================================
-- What: Indexes with low distinct_keys relative to num_rows benefit from
--       COMPRESS (Advanced Index Compression in 12c+). Reduces I/O and space.
-- Look for: Indexes with compression = 'DISABLED' and high duplication ratio.
-- Remediation:
--   ALTER INDEX <owner>.<index> REBUILD COMPRESS ADVANCED LOW ONLINE;
-- ============================================================================

SELECT owner,
       index_name,
       table_name,
       num_rows,
       distinct_keys,
       CASE WHEN distinct_keys > 0
            THEN ROUND(num_rows / distinct_keys, 1)
            ELSE 0 END AS avg_dups_per_key,
       compression,
       leaf_blocks,
       'Consider COMPRESS ADVANCED LOW for space savings' AS recommendation
FROM dba_indexes
WHERE owner NOT IN ('SYS', 'SYSTEM', 'OUTLN', 'DBSNMP', 'MDSYS', 'CTXSYS')
  AND compression = 'DISABLED'
  AND num_rows > 10000
  AND distinct_keys > 0
  AND (num_rows / distinct_keys) > 5
ORDER BY num_rows DESC
FETCH FIRST 20 ROWS ONLY;

-- ==========================================================================
-- End of Oracle Index Health Check
-- ==========================================================================
