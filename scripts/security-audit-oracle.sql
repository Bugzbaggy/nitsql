-- ==========================================================================
-- nitsql (example) - Oracle Security Audit
-- Dialect: Oracle Database
-- Minimum version: Oracle 19c+ (some queries compatible with 12c+)
-- ==========================================================================
-- Run as a DBA user or a user with SELECT ANY DICTIONARY privilege.
-- Required: SELECT_CATALOG_ROLE or equivalent grants on DBA_ views.
-- For other dialects, see:
--   security-audit-mssql.sql
--   security-audit-postgresql.sql
--   security-audit-mysql.sql
-- ==========================================================================

-- ============================================================================
-- 1. DBA / SYSDBA ACCOUNTS
-- ============================================================================
-- What: Lists users with DBA role or SYSDBA/SYSOPER administrative privileges.
--       These accounts have unrestricted access and should be tightly controlled.
-- Look for: More than 2-3 DBA-level accounts; service accounts with DBA role.
-- Remediation: Revoke DBA where not required:
--   REVOKE DBA FROM <user>;
--   Grant only specific privileges needed for the application.
-- ============================================================================

-- Users with DBA role
SELECT grantee, granted_role, admin_option, default_role
FROM dba_role_privs
WHERE granted_role = 'DBA'
ORDER BY grantee;

-- Users with SYSDBA / SYSOPER privileges
SELECT username, sysdba, sysoper, sysasm, sysbackup, sysdg, syskm
FROM v$pwfile_users
ORDER BY username;

-- ============================================================================
-- 2. USERS WITH EXCESSIVE PRIVILEGES
-- ============================================================================
-- What: Identifies users granted DBA, RESOURCE, or UNLIMITED TABLESPACE.
--       RESOURCE grants CREATE TABLE, CREATE SEQUENCE, etc. with implicit
--       UNLIMITED TABLESPACE in older Oracle versions.
-- Look for: Application users with DBA or RESOURCE roles.
-- Remediation:
--   REVOKE RESOURCE FROM <user>;
--   REVOKE UNLIMITED TABLESPACE FROM <user>;
--   Grant explicit CREATE TABLE, CREATE SEQUENCE as needed with quotas:
--   ALTER USER <user> QUOTA 100M ON <tablespace>;
-- ============================================================================

SELECT grantee,
       granted_role,
       admin_option,
       default_role,
       CASE
           WHEN granted_role = 'DBA' THEN 'CRITICAL: Full database admin'
           WHEN granted_role = 'RESOURCE' THEN 'WARNING: Legacy role with broad DDL access'
           WHEN granted_role = 'CONNECT' THEN 'INFO: Basic connection role'
           ELSE 'REVIEW'
       END AS risk_level
FROM dba_role_privs
WHERE granted_role IN ('DBA', 'RESOURCE', 'CONNECT', 'IMP_FULL_DATABASE', 'EXP_FULL_DATABASE')
  AND grantee NOT IN ('SYS', 'SYSTEM', 'DBSNMP', 'DBA')
ORDER BY
    CASE granted_role
        WHEN 'DBA' THEN 1
        WHEN 'IMP_FULL_DATABASE' THEN 2
        WHEN 'EXP_FULL_DATABASE' THEN 3
        WHEN 'RESOURCE' THEN 4
        ELSE 5
    END,
    grantee;

-- Users with UNLIMITED TABLESPACE
SELECT grantee, privilege, admin_option
FROM dba_sys_privs
WHERE privilege = 'UNLIMITED TABLESPACE'
  AND grantee NOT IN ('SYS', 'SYSTEM', 'DBA')
ORDER BY grantee;

-- ============================================================================
-- 3. PASSWORD PROFILE SETTINGS
-- ============================================================================
-- What: Reviews password policies configured in profiles. Weak settings allow
--       brute-force attacks and stale passwords.
-- Look for: UNLIMITED values on critical limits; missing lockout settings.
-- Remediation: Create a strict profile and assign:
--   CREATE PROFILE strict_profile LIMIT
--     FAILED_LOGIN_ATTEMPTS 5
--     PASSWORD_LIFE_TIME 90
--     PASSWORD_REUSE_MAX 12
--     PASSWORD_LOCK_TIME 1
--     PASSWORD_VERIFY_FUNCTION ora12c_strong_verify_function;
--   ALTER USER <user> PROFILE strict_profile;
-- ============================================================================

SELECT profile,
       resource_name,
       resource_type,
       limit AS current_setting,
       CASE
           WHEN resource_name = 'FAILED_LOGIN_ATTEMPTS' AND (limit = 'UNLIMITED' OR limit = 'DEFAULT')
               THEN 'CRITICAL: No login lockout'
           WHEN resource_name = 'PASSWORD_LIFE_TIME' AND (limit = 'UNLIMITED' OR limit = 'DEFAULT')
               THEN 'WARNING: Passwords never expire'
           WHEN resource_name = 'PASSWORD_VERIFY_FUNCTION' AND (limit = 'NULL' OR limit = 'DEFAULT')
               THEN 'CRITICAL: No password complexity enforcement'
           WHEN resource_name = 'PASSWORD_REUSE_MAX' AND (limit = 'UNLIMITED' OR limit = 'DEFAULT')
               THEN 'WARNING: Password reuse not restricted'
           WHEN resource_name = 'PASSWORD_LOCK_TIME' AND (limit = 'UNLIMITED' OR limit = 'DEFAULT')
               THEN 'INFO: Account lockout time not set'
           ELSE 'OK'
       END AS recommendation
FROM dba_profiles
WHERE resource_type = 'PASSWORD'
ORDER BY profile, resource_name;

-- ============================================================================
-- 4. AUDIT TRAIL CONFIGURATION
-- ============================================================================
-- What: Checks if unified auditing is enabled and active audit policies.
--       Oracle 12c+ recommends unified auditing over traditional.
-- Look for: Unified audit enabled; policies covering logon, DDL, DML on
--           sensitive objects.
-- Remediation: Enable unified auditing:
--   AUDIT POLICY ora_logon_failures;
--   AUDIT POLICY ora_secureconfig;
--   CREATE AUDIT POLICY custom_policy ACTIONS ALL ON <schema>.<table>;
-- ============================================================================

-- Check if unified auditing is enabled
SELECT value AS unified_auditing_status,
       CASE value
           WHEN 'TRUE' THEN 'OK: Unified auditing enabled'
           ELSE 'WARNING: Consider enabling unified auditing'
       END AS recommendation
FROM v$option
WHERE parameter = 'Unified Auditing';

-- Active audit policies
SELECT policy_name,
       enabled_option,
       entity_name,
       entity_type,
       success,
       failure
FROM audit_unified_enabled_policies
ORDER BY policy_name;

-- Audit trail size and last cleanup
SELECT audit_trail,
       os_file_prefix,
       last_archive_ts
FROM dba_audit_mgmt_config_params
WHERE parameter_name = 'AUDIT TRAIL TYPE';

-- ============================================================================
-- 5. NETWORK ENCRYPTION (SQLNET.ENCRYPTION)
-- ============================================================================
-- What: Checks Oracle Net encryption settings. Data in transit should be
--       encrypted using native network encryption or TLS.
-- Look for: SQLNET.ENCRYPTION_SERVER = REQUIRED (not REQUESTED or REJECTED).
-- Remediation: Configure sqlnet.ora:
--   SQLNET.ENCRYPTION_SERVER = REQUIRED
--   SQLNET.ENCRYPTION_TYPES_SERVER = (AES256, AES192)
--   SQLNET.CRYPTO_CHECKSUM_SERVER = REQUIRED
-- Or configure TLS in listener.ora and tnsnames.ora.
-- ============================================================================

-- Check current session encryption
SELECT network_service_banner
FROM v$session_connect_info
WHERE sid = SYS_CONTEXT('USERENV', 'SID')
  AND network_service_banner IS NOT NULL;

-- Check sqlnet parameters (requires reading from v$parameter or init.ora)
SELECT name, value,
       CASE
           WHEN name LIKE '%encryption%' AND (value IS NULL OR value = 'REJECTED')
               THEN 'CRITICAL: Encryption not enforced'
           WHEN name LIKE '%encryption%' AND value = 'REQUESTED'
               THEN 'WARNING: Encryption requested but not required'
           WHEN name LIKE '%encryption%' AND value = 'REQUIRED'
               THEN 'OK: Encryption required'
           ELSE 'REVIEW'
       END AS recommendation
FROM v$parameter
WHERE name LIKE '%encryption%'
   OR name LIKE '%crypto%'
ORDER BY name;

-- ============================================================================
-- 6. VIRTUAL PRIVATE DATABASE (VPD) POLICIES
-- ============================================================================
-- What: Lists VPD/Fine-Grained Access Control policies that enforce row-level
--       security. Essential for multi-tenant schemas or sensitive data.
-- Look for: Tables with sensitive data that lack VPD policies.
-- Remediation:
--   BEGIN
--     DBMS_RLS.ADD_POLICY(
--       object_schema => '<schema>',
--       object_name   => '<table>',
--       policy_name   => '<policy>',
--       function_schema => '<schema>',
--       policy_function => '<function>',
--       statement_types => 'SELECT,INSERT,UPDATE,DELETE'
--     );
--   END;
-- ============================================================================

SELECT object_owner,
       object_name,
       policy_name,
       pf_owner AS function_owner,
       package || '.' || function AS policy_function,
       sel AS applies_to_select,
       ins AS applies_to_insert,
       upd AS applies_to_update,
       del AS applies_to_delete,
       enable AS is_enabled,
       CASE
           WHEN enable = 'NO' THEN 'WARNING: VPD policy disabled'
           ELSE 'OK'
       END AS recommendation
FROM dba_policies
WHERE object_owner NOT IN ('SYS', 'SYSTEM', 'MDSYS', 'CTXSYS', 'XDB')
ORDER BY object_owner, object_name, policy_name;

-- ============================================================================
-- 7. DEFAULT PASSWORDS CHECK
-- ============================================================================
-- What: Detects accounts still using default (well-known) passwords.
--       Oracle ships with many default accounts whose passwords are published.
-- Look for: Any rows indicate accounts with default passwords.
-- Remediation: ALTER USER <user> IDENTIFIED BY <strong_password>;
--              or ALTER USER <user> ACCOUNT LOCK; if the account is unused.
-- Note: DBA_USERS_WITH_DEFPWD available in 11g+.
-- ============================================================================

SELECT username,
       account_status,
       lock_date,
       expiry_date,
       profile,
       'CRITICAL: Account has a default/well-known password' AS recommendation
FROM dba_users_with_defpwd
ORDER BY username;

-- Also check for unlocked default accounts
SELECT username,
       account_status,
       default_tablespace,
       profile,
       created,
       CASE
           WHEN account_status NOT LIKE '%LOCKED%' THEN 'WARNING: Default account is unlocked'
           ELSE 'OK: Account is locked'
       END AS recommendation
FROM dba_users
WHERE oracle_maintained = 'Y'
  AND username NOT IN ('SYS', 'SYSTEM')
ORDER BY account_status, username;

-- ============================================================================
-- 8. PUBLIC GRANTS ON SENSITIVE PACKAGES
-- ============================================================================
-- What: Checks for EXECUTE grants on dangerous packages to PUBLIC. These
--       packages allow file I/O, HTTP calls, and dynamic SQL that can be
--       exploited for privilege escalation or data exfiltration.
-- Look for: Any EXECUTE grant on listed packages to PUBLIC.
-- Remediation:
--   REVOKE EXECUTE ON SYS.UTL_FILE FROM PUBLIC;
--   REVOKE EXECUTE ON SYS.UTL_HTTP FROM PUBLIC;
--   Grant to specific roles only as needed.
-- ============================================================================

SELECT grantee,
       owner,
       table_name AS package_name,
       privilege,
       grantable,
       CASE
           WHEN table_name IN ('UTL_FILE', 'UTL_HTTP', 'UTL_TCP', 'UTL_SMTP')
               THEN 'CRITICAL: Network/filesystem access package'
           WHEN table_name IN ('DBMS_SQL', 'DBMS_SYS_SQL')
               THEN 'CRITICAL: Dynamic SQL execution'
           WHEN table_name IN ('DBMS_RANDOM', 'DBMS_CRYPTO')
               THEN 'WARNING: Cryptographic package'
           WHEN table_name IN ('DBMS_JAVA', 'DBMS_JAVA_TEST')
               THEN 'CRITICAL: Java execution in database'
           WHEN table_name = 'DBMS_SCHEDULER'
               THEN 'WARNING: Job scheduling (can execute OS commands)'
           WHEN table_name = 'DBMS_ADVISOR'
               THEN 'WARNING: Advisor package with broad read access'
           ELSE 'REVIEW'
       END AS risk_level
FROM dba_tab_privs
WHERE grantee = 'PUBLIC'
  AND privilege = 'EXECUTE'
  AND table_name IN (
      'UTL_FILE', 'UTL_HTTP', 'UTL_TCP', 'UTL_SMTP', 'UTL_INADDR',
      'DBMS_SQL', 'DBMS_SYS_SQL', 'DBMS_LOB', 'DBMS_JAVA', 'DBMS_JAVA_TEST',
      'DBMS_BACKUP_RESTORE', 'DBMS_SCHEDULER', 'DBMS_ADVISOR',
      'DBMS_RANDOM', 'DBMS_CRYPTO', 'DBMS_XMLGEN'
  )
ORDER BY risk_level, table_name;

-- ============================================================================
-- 9. OBJECT PRIVILEGES AUDIT (Broad grants)
-- ============================================================================
-- What: Identifies users with direct privileges on many objects, or
--       WITH GRANT OPTION on sensitive tables.
-- Look for: Users with grantable = 'YES' or with > 50 object grants.
-- Remediation: Use roles instead of direct grants:
--   CREATE ROLE app_reader;
--   GRANT SELECT ON <schema>.<table> TO app_reader;
--   GRANT app_reader TO <user>;
-- ============================================================================

-- Users with WITH GRANT OPTION
SELECT grantee,
       owner,
       table_name,
       privilege,
       grantable,
       'WARNING: User can propagate this privilege to others' AS recommendation
FROM dba_tab_privs
WHERE grantable = 'YES'
  AND grantee NOT IN ('SYS', 'SYSTEM', 'DBA', 'PUBLIC')
  AND owner NOT IN ('SYS', 'SYSTEM', 'MDSYS', 'CTXSYS', 'XDB', 'OUTLN', 'DBSNMP')
ORDER BY grantee, owner, table_name;

-- Count of object privileges per user (detect over-privileged accounts)
SELECT grantee,
       COUNT(*) AS total_object_privs,
       COUNT(DISTINCT owner || '.' || table_name) AS distinct_objects,
       SUM(CASE WHEN privilege = 'SELECT' THEN 1 ELSE 0 END) AS select_grants,
       SUM(CASE WHEN privilege IN ('INSERT', 'UPDATE', 'DELETE') THEN 1 ELSE 0 END) AS dml_grants,
       SUM(CASE WHEN privilege IN ('ALTER', 'INDEX', 'REFERENCES') THEN 1 ELSE 0 END) AS ddl_grants,
       CASE
           WHEN COUNT(*) > 100 THEN 'CRITICAL: Excessive direct grants - use roles'
           WHEN COUNT(*) > 50 THEN 'WARNING: Many direct grants - consider consolidating'
           ELSE 'OK'
       END AS recommendation
FROM dba_tab_privs
WHERE grantee NOT IN ('SYS', 'SYSTEM', 'DBA', 'PUBLIC',
                       'MDSYS', 'CTXSYS', 'XDB', 'OUTLN', 'DBSNMP')
  AND owner NOT IN ('SYS', 'SYSTEM', 'MDSYS', 'CTXSYS', 'XDB', 'OUTLN', 'DBSNMP')
GROUP BY grantee
ORDER BY total_object_privs DESC
FETCH FIRST 20 ROWS ONLY;

-- ============================================================================
-- 10. DATA ENCRYPTION (TDE) STATUS
-- ============================================================================
-- What: Checks Transparent Data Encryption status for tablespaces and columns.
--       TDE protects data at rest from physical media theft.
-- Look for: User tablespaces with encrypt = 'NO'.
-- Remediation:
--   -- Encrypt tablespace:
--   ALTER TABLESPACE <ts> ENCRYPTION ONLINE ENCRYPT;
--   -- Or create encrypted tablespace:
--   CREATE TABLESPACE <ts> DATAFILE ... ENCRYPTION USING 'AES256' DEFAULT STORAGE(ENCRYPT);
--   -- Requires: ALTER SYSTEM SET WALLET_ROOT='...' SCOPE=SPFILE;
--   --           ALTER SYSTEM SET TDE_CONFIGURATION='KEYSTORE_CONFIGURATION=FILE' SCOPE=BOTH;
-- ============================================================================

-- Tablespace encryption status
SELECT tablespace_name,
       encrypted,
       CASE encrypted
           WHEN 'YES' THEN 'OK: Tablespace encrypted'
           ELSE 'WARNING: Tablespace NOT encrypted - consider TDE'
       END AS recommendation
FROM dba_tablespaces
WHERE tablespace_name NOT IN ('SYSTEM', 'SYSAUX', 'TEMP', 'UNDOTBS1')
  AND contents = 'PERMANENT'
ORDER BY encrypted, tablespace_name;

-- Column-level encryption
SELECT owner,
       table_name,
       column_name,
       encryption_alg,
       salt
FROM dba_encrypted_columns
ORDER BY owner, table_name, column_name;

-- Keystore status
SELECT con_id,
       keystore_mode,
       wallet_type,
       wallet_order,
       status,
       CASE
           WHEN status != 'OPEN' THEN 'CRITICAL: TDE keystore is not open'
           ELSE 'OK: Keystore is open'
       END AS recommendation
FROM v$encryption_wallet;

-- ==========================================================================
-- End of Oracle Security Audit
-- ==========================================================================
