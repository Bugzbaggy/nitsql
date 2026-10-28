-- ==========================================================================
-- nitsql (example) - MySQL Security Audit
-- Dialect: MySQL
-- Minimum version: MySQL 8.0+
-- ==========================================================================
-- Run as a user with SELECT on mysql.user, performance_schema, and
-- information_schema. Root or equivalent administrative user recommended.
-- For other dialects, see:
--   security-audit-mssql.sql
--   security-audit-postgresql.sql
--   security-audit-oracle.sql
-- ==========================================================================

-- ============================================================================
-- 1. ROOT / ADMIN ACCOUNTS
-- ============================================================================
-- What: Identifies all accounts with administrative privileges. The 'root'
--       account should be renamed or restricted, and remote root login
--       should be disabled.
-- Look for: root accounts with host='%'; multiple admin accounts.
-- Remediation:
--   -- Rename root: RENAME USER 'root'@'localhost' TO 'dba_admin'@'localhost';
--   -- Remove remote root: DROP USER 'root'@'%';
--   -- Create dedicated admin: CREATE USER 'admin'@'10.0.0.%' IDENTIFIED BY '...';
-- ============================================================================

SELECT user, host,
       account_locked,
       password_expired,
       password_last_changed,
       password_lifetime,
       CASE
           WHEN user = 'root' AND host = '%' THEN 'CRITICAL: root accessible from any host'
           WHEN user = 'root' AND host != 'localhost' THEN 'WARNING: root accessible remotely'
           WHEN user = 'root' THEN 'REVIEW: Ensure root access is necessary'
           ELSE 'INFO: Administrative account'
       END AS recommendation
FROM mysql.user
WHERE (
    Super_priv = 'Y'
    OR Grant_priv = 'Y'
    OR (Select_priv = 'Y' AND Insert_priv = 'Y' AND Update_priv = 'Y'
        AND Delete_priv = 'Y' AND Create_priv = 'Y' AND Drop_priv = 'Y')
)
ORDER BY
    CASE WHEN user = 'root' THEN 0 ELSE 1 END,
    user, host;

-- ============================================================================
-- 2. USERS WITHOUT PASSWORDS
-- ============================================================================
-- What: Finds accounts with empty authentication strings (no password set).
--       These can be logged into without any credentials.
-- Look for: Any results indicate accounts that need passwords.
-- Remediation:
--   ALTER USER '<user>'@'<host>' IDENTIFIED BY '<strong_password>';
--   or DROP USER '<user>'@'<host>'; if the account is unused.
-- Note: In MySQL 8.0, authentication_string is hashed; empty = no password.
-- ============================================================================

SELECT user, host,
       plugin AS auth_plugin,
       account_locked,
       password_expired,
       CASE
           WHEN authentication_string = '' OR authentication_string IS NULL
               THEN 'CRITICAL: No password set'
           ELSE 'OK'
       END AS recommendation
FROM mysql.user
WHERE (authentication_string = '' OR authentication_string IS NULL)
  AND user != ''
  AND account_locked = 'N'
ORDER BY user, host;

-- ============================================================================
-- 3. USERS WITH SUPER / ALL PRIVILEGES
-- ============================================================================
-- What: Identifies users with SUPER privilege or equivalent (ALL PRIVILEGES).
--       SUPER allows killing queries, changing global variables, and
--       bypassing read-only mode. In MySQL 8.0+, SUPER is being decomposed
--       into finer-grained dynamic privileges.
-- Look for: Application users with SUPER; any non-DBA with ALL PRIVILEGES.
-- Remediation:
--   REVOKE SUPER ON *.* FROM '<user>'@'<host>';
--   Grant only specific dynamic privileges as needed:
--   GRANT CONNECTION_ADMIN, SYSTEM_VARIABLES_ADMIN ON *.* TO '<user>'@'<host>';
-- ============================================================================

SELECT user, host,
       Super_priv,
       Grant_priv,
       CASE
           WHEN Super_priv = 'Y' AND Grant_priv = 'Y'
               THEN 'CRITICAL: SUPER + WITH GRANT OPTION'
           WHEN Super_priv = 'Y'
               THEN 'WARNING: SUPER privilege granted'
           WHEN Grant_priv = 'Y'
               THEN 'WARNING: Can grant privileges to others'
           ELSE 'REVIEW'
       END AS recommendation
FROM mysql.user
WHERE Super_priv = 'Y' OR Grant_priv = 'Y'
ORDER BY user, host;

-- Users with ALL PRIVILEGES on all databases
SELECT grantee, privilege_type, is_grantable
FROM information_schema.user_privileges
WHERE privilege_type = 'SUPER'
   OR (privilege_type IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE', 'CREATE', 'DROP',
                           'ALTER', 'INDEX', 'EXECUTE', 'CREATE VIEW', 'SHOW VIEW',
                           'TRIGGER', 'REFERENCES')
       AND grantee NOT IN ("'mysql.sys'@'localhost'", "'mysql.infoschema'@'localhost'",
                            "'mysql.session'@'localhost'"))
ORDER BY grantee, privilege_type;

-- ============================================================================
-- 4. SSL / TLS ENFORCEMENT
-- ============================================================================
-- What: Checks which users are required to connect over SSL/TLS and the
--       server's SSL configuration. Unencrypted connections expose data.
-- Look for: Users with ssl_type = '' (no SSL required); server with
--           have_ssl = 'DISABLED'.
-- Remediation:
--   -- Require SSL per user:
--   ALTER USER '<user>'@'<host>' REQUIRE SSL;
--   -- Or require specific cipher/issuer:
--   ALTER USER '<user>'@'<host>' REQUIRE X509;
--   -- Server-wide: set require_secure_transport = ON in my.cnf
-- ============================================================================

-- Server SSL status
SELECT VARIABLE_NAME, VARIABLE_VALUE
FROM performance_schema.global_variables
WHERE VARIABLE_NAME IN (
    'have_ssl', 'have_openssl', 'require_secure_transport',
    'ssl_ca', 'ssl_cert', 'ssl_key', 'ssl_cipher',
    'tls_version', 'admin_tls_version'
)
ORDER BY VARIABLE_NAME;

-- Per-user SSL requirements
SELECT user, host,
       ssl_type,
       ssl_cipher,
       x509_issuer,
       x509_subject,
       CASE
           WHEN ssl_type = '' THEN 'WARNING: No SSL requirement'
           WHEN ssl_type = 'ANY' THEN 'OK: SSL required'
           WHEN ssl_type = 'X509' THEN 'GOOD: X509 certificate required'
           WHEN ssl_type = 'SPECIFIED' THEN 'GOOD: Specific cipher/issuer required'
           ELSE 'REVIEW'
       END AS recommendation
FROM mysql.user
WHERE user NOT IN ('mysql.sys', 'mysql.infoschema', 'mysql.session')
  AND user != ''
ORDER BY ssl_type, user, host;

-- ============================================================================
-- 5. ACCOUNTS WITH WILDCARD HOST (%)
-- ============================================================================
-- What: Accounts with host='%' can connect from any IP address. This
--       significantly increases the attack surface.
-- Look for: Any application or administrative accounts with '%' host.
-- Remediation:
--   -- Restrict to specific IP/subnet:
--   RENAME USER '<user>'@'%' TO '<user>'@'10.0.0.%';
--   -- Or use specific IPs:
--   DROP USER '<user>'@'%';
--   CREATE USER '<user>'@'10.0.0.5' IDENTIFIED BY '...';
-- ============================================================================

SELECT user, host,
       account_locked,
       password_expired,
       Super_priv,
       Grant_priv,
       CASE
           WHEN host = '%' AND Super_priv = 'Y'
               THEN 'CRITICAL: Admin accessible from ANY host'
           WHEN host = '%'
               THEN 'WARNING: User accessible from ANY host'
           ELSE 'OK'
       END AS recommendation
FROM mysql.user
WHERE host = '%'
  AND user NOT IN ('mysql.sys', 'mysql.infoschema', 'mysql.session')
  AND user != ''
ORDER BY Super_priv DESC, user;

-- ============================================================================
-- 6. OLD AUTHENTICATION PLUGINS
-- ============================================================================
-- What: MySQL 8.0 defaults to caching_sha2_password. Older plugins like
--       mysql_native_password are less secure. mysql_old_password is
--       deprecated and vulnerable.
-- Look for: Accounts using mysql_native_password or mysql_old_password.
-- Remediation:
--   ALTER USER '<user>'@'<host>' IDENTIFIED WITH caching_sha2_password BY '<password>';
--   -- Ensure client libraries support caching_sha2_password.
--   -- Fallback: mysql_native_password if client compatibility needed.
-- ============================================================================

SELECT user, host,
       plugin AS auth_plugin,
       password_expired,
       CASE
           WHEN plugin = 'mysql_old_password' THEN 'CRITICAL: Deprecated and insecure plugin'
           WHEN plugin = 'mysql_native_password' THEN 'WARNING: Consider upgrading to caching_sha2_password'
           WHEN plugin = 'caching_sha2_password' THEN 'OK: Modern authentication'
           WHEN plugin = 'auth_socket' THEN 'OK: OS-level authentication'
           WHEN plugin = 'mysql_no_login' THEN 'OK: Login disabled (service account)'
           ELSE 'REVIEW: Non-standard plugin'
       END AS recommendation
FROM mysql.user
WHERE user NOT IN ('mysql.sys', 'mysql.infoschema', 'mysql.session')
  AND user != ''
ORDER BY
    CASE plugin
        WHEN 'mysql_old_password' THEN 1
        WHEN 'mysql_native_password' THEN 2
        WHEN 'sha256_password' THEN 3
        WHEN 'caching_sha2_password' THEN 4
        ELSE 5
    END,
    user, host;

-- ============================================================================
-- 7. GLOBAL GRANTS AUDIT
-- ============================================================================
-- What: Reviews all global-level privileges (*.* grants). Global privileges
--       apply to ALL databases and should be limited to DBA accounts.
-- Look for: Application users with global SELECT, INSERT, UPDATE, DELETE.
-- Remediation: Replace global grants with database-specific grants:
--   REVOKE ALL PRIVILEGES ON *.* FROM '<user>'@'<host>';
--   GRANT SELECT, INSERT, UPDATE, DELETE ON <database>.* TO '<user>'@'<host>';
-- ============================================================================

SELECT user, host,
       Select_priv, Insert_priv, Update_priv, Delete_priv,
       Create_priv, Drop_priv, Alter_priv,
       Grant_priv, Super_priv,
       File_priv, Process_priv, Reload_priv, Shutdown_priv,
       CASE
           WHEN File_priv = 'Y' THEN 'CRITICAL: FILE privilege (can read/write server files)'
           WHEN Process_priv = 'Y' AND Super_priv = 'N'
               THEN 'WARNING: PROCESS privilege (can see all queries)'
           WHEN Shutdown_priv = 'Y' THEN 'CRITICAL: SHUTDOWN privilege'
           WHEN Reload_priv = 'Y' THEN 'WARNING: RELOAD privilege (can flush logs/caches)'
           WHEN Select_priv = 'Y' AND Insert_priv = 'Y'
               THEN 'REVIEW: Global DML privileges'
           ELSE 'REVIEW'
       END AS highest_risk
FROM mysql.user
WHERE user NOT IN ('mysql.sys', 'mysql.infoschema', 'mysql.session', 'root')
  AND user != ''
  AND (Select_priv = 'Y' OR Insert_priv = 'Y' OR Update_priv = 'Y'
       OR Delete_priv = 'Y' OR Create_priv = 'Y' OR Drop_priv = 'Y'
       OR Grant_priv = 'Y' OR Super_priv = 'Y' OR File_priv = 'Y'
       OR Process_priv = 'Y' OR Reload_priv = 'Y' OR Shutdown_priv = 'Y')
ORDER BY
    CASE WHEN Super_priv = 'Y' OR File_priv = 'Y' OR Shutdown_priv = 'Y' THEN 0 ELSE 1 END,
    user, host;

-- ============================================================================
-- 8. BINARY LOG ENCRYPTION
-- ============================================================================
-- What: Binary logs can contain sensitive data (DML with actual values).
--       MySQL 8.0.14+ supports binary log encryption at rest.
-- Look for: binlog_encryption = OFF.
-- Remediation:
--   SET PERSIST binlog_encryption = ON;
--   -- Requires keyring plugin (e.g., keyring_file or keyring_encrypted_file).
--   -- Add to my.cnf: early-plugin-load=keyring_file.so
-- ============================================================================

SELECT VARIABLE_NAME, VARIABLE_VALUE,
       CASE
           WHEN VARIABLE_NAME = 'binlog_encryption' AND VARIABLE_VALUE = 'OFF'
               THEN 'WARNING: Binary logs are NOT encrypted at rest'
           WHEN VARIABLE_NAME = 'binlog_encryption' AND VARIABLE_VALUE = 'ON'
               THEN 'OK: Binary log encryption enabled'
           WHEN VARIABLE_NAME = 'log_bin' AND VARIABLE_VALUE = 'OFF'
               THEN 'INFO: Binary logging is disabled'
           ELSE 'REVIEW'
       END AS recommendation
FROM performance_schema.global_variables
WHERE VARIABLE_NAME IN (
    'log_bin', 'binlog_encryption', 'binlog_format', 'binlog_row_image',
    'binlog_expire_logs_seconds', 'binlog_expire_logs_auto_purge'
)
ORDER BY VARIABLE_NAME;

-- Keyring plugin status (required for encryption)
SELECT PLUGIN_NAME, PLUGIN_STATUS, PLUGIN_TYPE
FROM information_schema.plugins
WHERE PLUGIN_NAME LIKE 'keyring%'
ORDER BY PLUGIN_NAME;

-- ============================================================================
-- 9. AUDIT LOG PLUGIN STATUS
-- ============================================================================
-- What: Checks if MySQL Enterprise Audit (audit_log) or the Community
--       alternative is installed and active. Database auditing is critical
--       for compliance (SOX, HIPAA, PCI-DSS, GDPR).
-- Look for: audit_log plugin not installed or not active.
-- Remediation:
--   -- Enterprise:
--   INSTALL PLUGIN audit_log SONAME 'audit_log.so';
--   SET GLOBAL audit_log_policy = 'ALL';
--   -- Community alternative: MariaDB Audit Plugin or McAfee MySQL Audit
-- ============================================================================

-- Check for audit plugins
SELECT PLUGIN_NAME,
       PLUGIN_STATUS,
       PLUGIN_TYPE,
       PLUGIN_DESCRIPTION,
       CASE
           WHEN PLUGIN_STATUS = 'ACTIVE' THEN 'OK: Audit plugin is active'
           WHEN PLUGIN_STATUS = 'DISABLED' THEN 'WARNING: Audit plugin installed but disabled'
           ELSE 'REVIEW'
       END AS recommendation
FROM information_schema.plugins
WHERE PLUGIN_NAME LIKE '%audit%'
ORDER BY PLUGIN_NAME;

-- If no audit plugin found, report it
SELECT 'WARNING: No audit plugin detected. Consider installing MySQL Enterprise Audit or a community alternative.'
    AS recommendation
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM information_schema.plugins WHERE PLUGIN_NAME LIKE '%audit%'
);

-- Audit log settings (if enterprise audit is installed)
SELECT VARIABLE_NAME, VARIABLE_VALUE
FROM performance_schema.global_variables
WHERE VARIABLE_NAME LIKE 'audit_log%'
ORDER BY VARIABLE_NAME;

-- ============================================================================
-- 10. DEFAULT SCHEMA PERMISSIONS
-- ============================================================================
-- What: Checks permissions on default schemas. The 'test' database (if it
--       exists) is world-readable by default in older MySQL versions.
--       Also checks for overly permissive database-level grants.
-- Look for: Grants on 'test%' databases; broad database-level grants.
-- Remediation:
--   DROP DATABASE IF EXISTS test;
--   REVOKE ALL PRIVILEGES ON <database>.* FROM '<user>'@'<host>';
-- ============================================================================

-- Check for 'test' database (common security finding)
SELECT schema_name,
       default_character_set_name,
       'WARNING: test database should be removed in production' AS recommendation
FROM information_schema.schemata
WHERE schema_name LIKE 'test%';

-- Database-level grants (from mysql.db)
SELECT user, host, db,
       Select_priv, Insert_priv, Update_priv, Delete_priv,
       Create_priv, Drop_priv, Grant_priv, Alter_priv,
       CASE
           WHEN db = '%' THEN 'CRITICAL: Wildcard database grant'
           WHEN db LIKE 'test%' THEN 'WARNING: Grant on test database'
           WHEN Grant_priv = 'Y' THEN 'WARNING: WITH GRANT OPTION on database'
           ELSE 'REVIEW'
       END AS recommendation
FROM mysql.db
WHERE user NOT IN ('mysql.sys', 'mysql.infoschema', 'mysql.session')
  AND user != ''
ORDER BY
    CASE WHEN db = '%' THEN 0 WHEN db LIKE 'test%' THEN 1 ELSE 2 END,
    user, host;

-- Anonymous user check (user = '')
SELECT user, host,
       'CRITICAL: Anonymous user account detected - should be removed' AS recommendation
FROM mysql.user
WHERE user = '';

-- ============================================================================
-- SUMMARY
-- ============================================================================
-- Quick summary count of potential issues

SELECT 'Accounts without passwords' AS check_name,
       COUNT(*) AS issue_count
FROM mysql.user
WHERE (authentication_string = '' OR authentication_string IS NULL)
  AND user != '' AND account_locked = 'N'

UNION ALL

SELECT 'Wildcard host accounts',
       COUNT(*)
FROM mysql.user
WHERE host = '%' AND user != ''
  AND user NOT IN ('mysql.sys', 'mysql.infoschema', 'mysql.session')

UNION ALL

SELECT 'Old auth plugin accounts',
       COUNT(*)
FROM mysql.user
WHERE plugin IN ('mysql_native_password', 'mysql_old_password')
  AND user != ''

UNION ALL

SELECT 'Accounts with SUPER privilege',
       COUNT(*)
FROM mysql.user
WHERE Super_priv = 'Y' AND user != ''

UNION ALL

SELECT 'Accounts with FILE privilege',
       COUNT(*)
FROM mysql.user
WHERE File_priv = 'Y' AND user NOT IN ('root') AND user != '';

-- ==========================================================================
-- End of MySQL Security Audit
-- ==========================================================================
