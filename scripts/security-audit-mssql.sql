-- ==========================================================================
-- nitsql (example) - MSSQL Security Audit Script
-- Dialect: Microsoft SQL Server / Azure SQL Database
-- Compatible with SQL Server 2019+, Azure SQL Database, Azure SQL Managed Instance
-- ==========================================================================
-- This is the MSSQL-specific version of the security audit script.
-- For other dialects, see:
--   security-audit-postgresql.sql
--   security-audit-oracle.sql
--   security-audit-mysql.sql
-- ==========================================================================

SET NOCOUNT ON;

PRINT '=== nitsql - MSSQL Security Audit ===';
PRINT 'Database: ' + DB_NAME();
PRINT 'Audit Time: ' + CONVERT(VARCHAR, GETDATE(), 120);
PRINT '';

-- ============================================================================
-- 1. CHECK FOR OVERLY PERMISSIVE ROLES
-- ============================================================================
PRINT '--- Users with High-Privilege Roles ---';

SELECT
    dp.name AS UserName,
    dp.type_desc AS UserType,
    STRING_AGG(r.name, ', ') AS HighPrivilegeRoles,
    'REVIEW: Users with db_owner, db_securityadmin, or db_ddladmin should be limited' AS Recommendation
FROM sys.database_role_members rm
JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
JOIN sys.database_principals dp ON rm.member_principal_id = dp.principal_id
WHERE r.name IN ('db_owner', 'db_securityadmin', 'db_ddladmin', 'db_accessadmin')
    AND dp.name NOT IN ('dbo')
GROUP BY dp.name, dp.type_desc
ORDER BY dp.name;

PRINT '';

-- ============================================================================
-- 2. CHECK FOR USERS WITH EXCESSIVE PERMISSIONS
-- ============================================================================
PRINT '--- Users with CONTROL or ALTER ANY Permissions ---';

SELECT
    dp.name AS UserName,
    dp.type_desc AS UserType,
    p.permission_name,
    p.state_desc AS PermissionState,
    COALESCE(OBJECT_NAME(p.major_id), 'DATABASE') AS ObjectName,
    'CRITICAL: CONTROL and ALTER permissions should be restricted' AS Recommendation
FROM sys.database_permissions p
JOIN sys.database_principals dp ON p.grantee_principal_id = dp.principal_id
WHERE (p.permission_name LIKE '%CONTROL%' OR p.permission_name LIKE '%ALTER%')
    AND p.state_desc IN ('GRANT', 'GRANT_WITH_GRANT_OPTION')
    AND dp.name NOT IN ('dbo', 'public', 'guest')
ORDER BY dp.name;

PRINT '';

-- ============================================================================
-- 3. CHECK FOR SQL AUTHENTICATION (vs Azure AD)
-- ============================================================================
PRINT '--- SQL Authentication Users (Consider Windows AD / Azure AD) ---';

SELECT
    name AS UserName,
    type_desc AS UserType,
    create_date,
    modify_date,
    'RECOMMENDATION: Consider migrating to Windows AD or Azure AD (Microsoft Entra) authentication' AS Recommendation
FROM sys.database_principals
WHERE type_desc = 'SQL_USER'
    AND name NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys')
ORDER BY name;

PRINT '';

-- ============================================================================
-- 4. CHECK FOR GUEST USER PERMISSIONS
-- ============================================================================
PRINT '--- Guest User Permissions ---';

SELECT
    dp.name AS Principal,
    p.permission_name,
    p.state_desc,
    COALESCE(OBJECT_NAME(p.major_id), 'DATABASE') AS ObjectName,
    'WARNING: Guest user should not have explicit permissions' AS Recommendation
FROM sys.database_permissions p
JOIN sys.database_principals dp ON p.grantee_principal_id = dp.principal_id
WHERE dp.name = 'guest'
    AND p.permission_name != 'CONNECT';

PRINT '';

-- ============================================================================
-- 5. CHECK FOR PUBLIC ROLE PERMISSIONS
-- ============================================================================
PRINT '--- Permissions Granted to PUBLIC Role ---';

SELECT
    p.permission_name,
    p.state_desc,
    OBJECT_SCHEMA_NAME(p.major_id) + '.' + OBJECT_NAME(p.major_id) AS ObjectName,
    p.class_desc,
    'REVIEW: PUBLIC role permissions apply to all users' AS Recommendation
FROM sys.database_permissions p
JOIN sys.database_principals dp ON p.grantee_principal_id = dp.principal_id
WHERE dp.name = 'public'
    AND p.major_id > 0
    AND OBJECT_NAME(p.major_id) IS NOT NULL
ORDER BY p.permission_name;

PRINT '';

-- ============================================================================
-- 6. CHECK FOR ORPHANED USERS
-- ============================================================================
PRINT '--- Orphaned Users (No Login) ---';

SELECT
    name AS UserName,
    type_desc,
    create_date,
    'ACTION: Remove orphaned users or re-map to logins' AS Recommendation
FROM sys.database_principals
WHERE type_desc IN ('SQL_USER', 'WINDOWS_USER')
    AND sid NOT IN (SELECT sid FROM sys.server_principals WHERE type_desc IN ('SQL_LOGIN', 'WINDOWS_LOGIN', 'WINDOWS_GROUP'))
    AND name NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys', 'MS_DataCollectorInternalUser');

PRINT '';

-- ============================================================================
-- 7. CHECK ENCRYPTION STATUS
-- ============================================================================
PRINT '--- Database Encryption Status ---';

SELECT
    DB_NAME() AS DatabaseName,
    CASE is_encrypted WHEN 1 THEN 'Encrypted (TDE)' ELSE 'NOT ENCRYPTED' END AS EncryptionStatus,
    CASE WHEN is_encrypted = 0 THEN 'CRITICAL: Enable Transparent Data Encryption' ELSE 'OK' END AS Recommendation
FROM sys.databases
WHERE name = DB_NAME();

PRINT '';

-- ============================================================================
-- 8. CHECK FOR SENSITIVE COLUMNS WITHOUT MASKING
-- ============================================================================
PRINT '--- Columns That May Need Dynamic Data Masking ---';

SELECT
    OBJECT_SCHEMA_NAME(c.object_id) + '.' + OBJECT_NAME(c.object_id) AS TableName,
    c.name AS ColumnName,
    t.name AS DataType,
    CASE
        WHEN c.name LIKE '%ssn%' OR c.name LIKE '%social%' THEN 'SSN'
        WHEN c.name LIKE '%credit%' OR c.name LIKE '%card%' THEN 'Credit Card'
        WHEN c.name LIKE '%password%' OR c.name LIKE '%pwd%' THEN 'Password'
        WHEN c.name LIKE '%email%' THEN 'Email'
        WHEN c.name LIKE '%phone%' OR c.name LIKE '%mobile%' THEN 'Phone'
        WHEN c.name LIKE '%salary%' OR c.name LIKE '%income%' THEN 'Financial'
        ELSE 'PII'
    END AS SensitiveType,
    CASE WHEN mc.column_id IS NULL THEN 'NOT MASKED' ELSE 'Masked' END AS MaskingStatus,
    'REVIEW: Consider Dynamic Data Masking for sensitive columns' AS Recommendation
FROM sys.columns c
JOIN sys.types t ON c.user_type_id = t.user_type_id
LEFT JOIN sys.masked_columns mc ON c.object_id = mc.object_id AND c.column_id = mc.column_id
WHERE (c.name LIKE '%ssn%'
    OR c.name LIKE '%social%security%'
    OR c.name LIKE '%credit%card%'
    OR c.name LIKE '%password%'
    OR c.name LIKE '%email%'
    OR c.name LIKE '%phone%'
    OR c.name LIKE '%salary%')
    AND OBJECTPROPERTY(c.object_id, 'IsUserTable') = 1
    AND mc.column_id IS NULL;

PRINT '';

-- ============================================================================
-- 9. CHECK FOR ROW-LEVEL SECURITY
-- ============================================================================
PRINT '--- Row-Level Security Policies ---';

SELECT
    CASE WHEN COUNT(*) = 0
        THEN 'No RLS policies found. Consider implementing for multi-tenant scenarios.'
        ELSE 'RLS policies are implemented'
    END AS RLSStatus,
    COUNT(*) AS PolicyCount
FROM sys.security_policies;

IF EXISTS (SELECT 1 FROM sys.security_policies)
BEGIN
    SELECT
        sp.name AS PolicyName,
        OBJECT_NAME(sp.object_id) AS PolicyObjectName,
        sp.is_enabled,
        STRING_AGG(OBJECT_SCHEMA_NAME(pred.target_object_id) + '.' + OBJECT_NAME(pred.target_object_id), ', ') AS ProtectedTables
    FROM sys.security_policies sp
    JOIN sys.security_predicates pred ON sp.object_id = pred.object_id
    GROUP BY sp.name, sp.object_id, sp.is_enabled;
END

PRINT '';

-- ============================================================================
-- 10. AUDIT CONFIGURATION
-- ============================================================================
PRINT '--- Database Audit Status ---';

SELECT
    a.name AS AuditName,
    a.type_desc AS AuditType,
    CASE a.is_state_enabled WHEN 1 THEN 'Enabled' ELSE 'Disabled' END AS Status
FROM sys.dm_server_audit_status a;

IF NOT EXISTS (SELECT 1 FROM sys.dm_server_audit_status WHERE is_state_enabled = 1)
BEGIN
    SELECT 'WARNING: No active database audits found. Consider enabling SQL Audit.' AS Recommendation;
END

PRINT '';

-- ============================================================================
-- 11. DATA CLASSIFICATION STATUS (SQL Server 2019+)
-- ============================================================================
PRINT '--- Data Classification / Sensitivity Labels ---';

SELECT
    OBJECT_SCHEMA_NAME(c.major_id) + '.' + OBJECT_NAME(c.major_id) AS TableName,
    COL_NAME(c.major_id, c.minor_id) AS ColumnName,
    c.label AS SensitivityLabel,
    c.information_type AS InformationType
FROM sys.sensitivity_classifications c
ORDER BY TableName, ColumnName;

IF NOT EXISTS (SELECT 1 FROM sys.sensitivity_classifications)
BEGIN
    SELECT 'INFO: No data classifications found. Consider ADD SENSITIVITY CLASSIFICATION for PII columns (SQL Server 2019+).' AS Recommendation;
END

PRINT '';

-- ============================================================================
-- 12. COMPATIBILITY LEVEL & ADR STATUS
-- ============================================================================
PRINT '--- Compatibility Level and SQL Server 2019+ Features ---';

SELECT
    name AS DatabaseName,
    compatibility_level,
    CASE
        WHEN compatibility_level >= 160 THEN 'SQL Server 2022 (full IQP)'
        WHEN compatibility_level >= 150 THEN 'SQL Server 2019 (IQP enabled)'
        WHEN compatibility_level >= 140 THEN 'SQL Server 2017 (limited IQP)'
        ELSE 'Pre-2017 — upgrade to unlock IQP features'
    END AS IQPStatus,
    is_accelerated_database_recovery_on AS ADREnabled
FROM sys.databases
WHERE name = DB_NAME();

PRINT '';

-- ============================================================================
-- SUMMARY
-- ============================================================================
PRINT '=== MSSQL Security Audit Summary ===';

DECLARE @issues INT = 0;

-- Count high-privilege users
SELECT @issues = @issues + COUNT(*)
FROM sys.database_role_members rm
JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
JOIN sys.database_principals dp ON rm.member_principal_id = dp.principal_id
WHERE r.name IN ('db_owner', 'db_securityadmin', 'db_ddladmin')
    AND dp.name NOT IN ('dbo');

-- Count SQL auth users
SELECT @issues = @issues + COUNT(*)
FROM sys.database_principals
WHERE type_desc = 'SQL_USER'
    AND name NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys');

PRINT 'Total potential issues found: ' + CAST(@issues AS VARCHAR);
PRINT '';
PRINT '=== MSSQL Security Audit Complete ===';
