-- ==========================================================================
-- nitsql (example) - MSSQL Index Health Check
-- Dialect: Microsoft SQL Server / Azure SQL Database
-- Compatible with SQL Server 2019+, Azure SQL Database, Azure SQL Managed Instance
-- ==========================================================================
-- This is the MSSQL-specific version of the index health check script.
-- For other dialects, see:
--   check-indexes-postgresql.sql
--   check-indexes-oracle.sql
--   check-indexes-mysql.sql
-- ==========================================================================

SET NOCOUNT ON;

PRINT '=== nitsql - MSSQL Index Health Check ===';
PRINT '';

-- ============================================================================
-- 1. MISSING INDEXES
-- ============================================================================
PRINT '--- Missing Indexes (Top 20 by Impact) ---';

SELECT TOP 20
    CONVERT(DECIMAL(18,2),
        migs.avg_total_user_cost * migs.avg_user_impact * (migs.user_seeks + migs.user_scans)
    ) AS ImprovementMeasure,
    'CREATE NONCLUSTERED INDEX [IX_' +
        OBJECT_NAME(mid.object_id) + '_' +
        REPLACE(REPLACE(REPLACE(COALESCE(mid.equality_columns, ''), '[', ''), ']', ''), ', ', '_') +
        '] ON ' + mid.statement + ' (' +
        COALESCE(mid.equality_columns, '') +
        CASE WHEN mid.equality_columns IS NOT NULL AND mid.inequality_columns IS NOT NULL THEN ', ' ELSE '' END +
        COALESCE(mid.inequality_columns, '') + ')' +
        COALESCE(' INCLUDE (' + mid.included_columns + ')', '') AS CreateIndexStatement,
    mid.equality_columns,
    mid.inequality_columns,
    mid.included_columns,
    migs.user_seeks,
    migs.user_scans,
    migs.avg_total_user_cost,
    migs.avg_user_impact
FROM sys.dm_db_missing_index_groups mig
JOIN sys.dm_db_missing_index_group_stats migs
    ON migs.group_handle = mig.index_group_handle
JOIN sys.dm_db_missing_index_details mid
    ON mig.index_handle = mid.index_handle
WHERE mid.database_id = DB_ID()
ORDER BY ImprovementMeasure DESC;

PRINT '';

-- ============================================================================
-- 2. UNUSED INDEXES
-- ============================================================================
PRINT '--- Unused Indexes (Never Read, But Written To) ---';

SELECT
    OBJECT_SCHEMA_NAME(i.object_id) + '.' + OBJECT_NAME(i.object_id) AS TableName,
    i.name AS IndexName,
    i.type_desc AS IndexType,
    ius.user_seeks,
    ius.user_scans,
    ius.user_lookups,
    ius.user_updates,
    (ius.user_seeks + ius.user_scans + ius.user_lookups) AS TotalReads,
    ps.used_page_count * 8 / 1024 AS IndexSizeMB,
    'DROP INDEX [' + i.name + '] ON [' + OBJECT_SCHEMA_NAME(i.object_id) + '].[' + OBJECT_NAME(i.object_id) + '];' AS DropStatement
FROM sys.indexes i
LEFT JOIN sys.dm_db_index_usage_stats ius
    ON i.object_id = ius.object_id AND i.index_id = ius.index_id AND ius.database_id = DB_ID()
LEFT JOIN sys.dm_db_partition_stats ps
    ON i.object_id = ps.object_id AND i.index_id = ps.index_id
WHERE OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
    AND i.type_desc = 'NONCLUSTERED'
    AND i.is_primary_key = 0
    AND i.is_unique_constraint = 0
    AND COALESCE(ius.user_seeks, 0) + COALESCE(ius.user_scans, 0) + COALESCE(ius.user_lookups, 0) = 0
    AND COALESCE(ius.user_updates, 0) > 0
ORDER BY ius.user_updates DESC;

PRINT '';

-- ============================================================================
-- 3. KEY LOOKUPS (Indexes Not Covering Queries)
-- ============================================================================
PRINT '--- Indexes with High Key Lookups (Consider Covering Index) ---';

SELECT TOP 20
    OBJECT_SCHEMA_NAME(i.object_id) + '.' + OBJECT_NAME(i.object_id) AS TableName,
    i.name AS IndexName,
    ius.user_seeks AS IndexSeeks,
    ius.user_lookups AS KeyLookups,
    CAST(ius.user_lookups AS FLOAT) / NULLIF(ius.user_seeks + ius.user_scans, 0) AS LookupRatio,
    'Consider adding INCLUDE columns to eliminate key lookups' AS Recommendation
FROM sys.dm_db_index_usage_stats ius
JOIN sys.indexes i
    ON ius.object_id = i.object_id AND ius.index_id = i.index_id
WHERE ius.database_id = DB_ID()
    AND ius.user_lookups > 1000
    AND i.type_desc = 'NONCLUSTERED'
ORDER BY ius.user_lookups DESC;

PRINT '';

-- ============================================================================
-- 4. INDEX FRAGMENTATION (For indexes > 10MB)
-- ============================================================================
-- NOTE: The emitted REBUILD commands include RESUMABLE = ON. This requires
--       running them OUTSIDE any user transaction (SQL Server error 574
--       otherwise). Do NOT paste them into a Flyway/Liquibase migration or
--       any script that is wrapped in BEGIN TRAN. For transactional contexts,
--       drop RESUMABLE and rely on ONLINE = ON alone.
PRINT '--- Index Fragmentation (>30% fragmentation on indexes >10MB) ---';

SELECT
    OBJECT_SCHEMA_NAME(ips.object_id) + '.' + OBJECT_NAME(ips.object_id) AS TableName,
    i.name AS IndexName,
    ips.index_type_desc,
    ips.avg_fragmentation_in_percent,
    ips.page_count,
    ips.page_count * 8 / 1024 AS IndexSizeMB,
    CASE
        WHEN ips.avg_fragmentation_in_percent < 30 THEN 'REORGANIZE'
        ELSE 'REBUILD'
    END AS RecommendedAction,
    CASE
        WHEN ips.avg_fragmentation_in_percent < 30 THEN
            'ALTER INDEX [' + i.name + '] ON [' + OBJECT_SCHEMA_NAME(ips.object_id) + '].[' + OBJECT_NAME(ips.object_id) + '] REORGANIZE;'
        ELSE
            'ALTER INDEX [' + i.name + '] ON [' + OBJECT_SCHEMA_NAME(ips.object_id) + '].[' + OBJECT_NAME(ips.object_id) + '] REBUILD WITH (ONLINE = ON, RESUMABLE = ON, MAX_DURATION = 60 MINUTES);'
    END AS MaintenanceScript
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
JOIN sys.indexes i
    ON ips.object_id = i.object_id AND ips.index_id = i.index_id
WHERE ips.avg_fragmentation_in_percent > 10
    AND ips.page_count > 1000  -- At least ~8MB
    AND ips.index_id > 0  -- Not heaps
ORDER BY ips.avg_fragmentation_in_percent DESC;

PRINT '';

-- ============================================================================
-- 5. DUPLICATE INDEXES
-- ============================================================================
PRINT '--- Potentially Duplicate Indexes ---';

WITH IndexColumns AS (
    SELECT
        OBJECT_SCHEMA_NAME(i.object_id) AS SchemaName,
        OBJECT_NAME(i.object_id) AS TableName,
        i.name AS IndexName,
        i.index_id,
        i.object_id,
        STRING_AGG(c.name, ',') WITHIN GROUP (ORDER BY ic.key_ordinal) AS KeyColumns,
        STRING_AGG(CASE WHEN ic.is_included_column = 1 THEN c.name END, ',') WITHIN GROUP (ORDER BY c.name) AS IncludedColumns
    FROM sys.indexes i
    JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id
    JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
    WHERE i.type_desc = 'NONCLUSTERED'
        AND OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
    GROUP BY i.object_id, i.name, i.index_id
)
SELECT
    ic1.SchemaName,
    ic1.TableName,
    ic1.IndexName AS Index1,
    ic2.IndexName AS Index2,
    ic1.KeyColumns,
    ic1.IncludedColumns AS Index1Includes,
    ic2.IncludedColumns AS Index2Includes,
    'Review and potentially remove duplicate index' AS Recommendation
FROM IndexColumns ic1
JOIN IndexColumns ic2
    ON ic1.object_id = ic2.object_id
    AND ic1.KeyColumns = ic2.KeyColumns
    AND ic1.index_id < ic2.index_id;

PRINT '';

-- ============================================================================
-- 6. OPTIMIZE_FOR_SEQUENTIAL_KEY CANDIDATES (SQL Server 2019+)
-- ============================================================================
PRINT '--- Identity Column PKs Missing OPTIMIZE_FOR_SEQUENTIAL_KEY ---';

SELECT
    OBJECT_SCHEMA_NAME(i.object_id) + '.' + OBJECT_NAME(i.object_id) AS TableName,
    i.name AS IndexName,
    c.name AS KeyColumn,
    c.is_identity,
    i.optimize_for_sequential_key,
    'ALTER INDEX [' + i.name + '] ON [' + OBJECT_SCHEMA_NAME(i.object_id) + '].[' + OBJECT_NAME(i.object_id) + '] SET (OPTIMIZE_FOR_SEQUENTIAL_KEY = ON);' AS FixScript
FROM sys.indexes i
JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id AND ic.key_ordinal = 1
JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
WHERE i.type_desc IN ('CLUSTERED')
    AND c.is_identity = 1
    AND i.optimize_for_sequential_key = 0
    AND OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
ORDER BY OBJECT_NAME(i.object_id);

PRINT '';
PRINT '=== MSSQL Index Health Check Complete ===';
