-- ==========================================================================
-- nitsql (example) - PostgreSQL Security Audit
-- Dialect: PostgreSQL
-- Minimum version: PostgreSQL 13+
-- ==========================================================================
-- Run as a superuser or a role with pg_read_all_settings, pg_read_all_stats.
-- Some queries require superuser access (pg_authid, pg_stat_ssl).
-- For other dialects, see:
--   security-audit-mssql.sql
--   security-audit-oracle.sql
--   security-audit-mysql.sql
-- ==========================================================================

-- ============================================================================
-- 1. SUPERUSER ACCOUNTS (Should be minimal)
-- ============================================================================
-- What: Lists all roles with superuser privileges. Superusers bypass all
--       permission checks and should be limited to administrative accounts.
-- Look for: More than 1-2 superuser accounts.
-- Remediation: REVOKE superuser where not needed:
--   ALTER ROLE <role> NOSUPERUSER;
--   Use pg_read_all_data / pg_write_all_data for read/write-all needs.
-- ============================================================================

SELECT rolname,
       rolsuper,
       rolcreaterole,
       rolcreatedb,
       rolcanlogin,
       rolreplication,
       rolconnlimit,
       rolvaliduntil
FROM pg_roles
WHERE rolsuper = true
ORDER BY rolname;

-- ============================================================================
-- 2. ROLES WITH EXCESSIVE PRIVILEGES
-- ============================================================================
-- What: Identifies roles that are members of powerful built-in roles
--       (pg_read_all_data, pg_write_all_data, pg_execute_server_program).
--       These grant broad access across all databases/schemas.
-- Look for: Application roles or service accounts with these memberships.
-- Remediation: Revoke and grant only schema-specific permissions:
--   REVOKE pg_read_all_data FROM <role>;
--   GRANT SELECT ON ALL TABLES IN SCHEMA <schema> TO <role>;
-- ============================================================================

SELECT r.rolname AS role_name,
       m.rolname AS member_of,
       am.admin_option
FROM pg_roles r
JOIN pg_auth_members am ON r.oid = am.member
JOIN pg_roles m ON am.roleid = m.oid
WHERE m.rolname IN ('pg_read_all_data', 'pg_write_all_data',
                     'pg_execute_server_program', 'pg_read_server_files',
                     'pg_write_server_files')
ORDER BY r.rolname, m.rolname;

-- ============================================================================
-- 3. PASSWORD AUTHENTICATION METHOD
-- ============================================================================
-- What: Checks whether login roles use md5 (weak) or scram-sha-256 (strong)
--       password hashing. md5 is vulnerable to pass-the-hash attacks.
-- Look for: Any role using md5. All should use scram-sha-256.
-- Remediation:
--   1. Set: password_encryption = 'scram-sha-256' in postgresql.conf
--   2. Reset passwords: ALTER ROLE <role> PASSWORD '<new_password>';
--   3. Update pg_hba.conf to use scram-sha-256 instead of md5.
-- Note: Requires superuser to read pg_authid.
-- ============================================================================

SELECT rolname,
       rolcanlogin,
       rolpassword IS NOT NULL AS has_password,
       CASE
           WHEN rolpassword LIKE 'md5%' THEN 'md5 (WEAK - upgrade to scram-sha-256)'
           WHEN rolpassword LIKE 'SCRAM%' THEN 'scram-sha-256 (good)'
           WHEN rolpassword IS NULL THEN 'no password set'
           ELSE 'unknown method'
       END AS auth_method,
       rolvaliduntil,
       CASE
           WHEN rolvaliduntil IS NOT NULL AND rolvaliduntil < NOW() THEN 'EXPIRED'
           WHEN rolvaliduntil IS NOT NULL AND rolvaliduntil < NOW() + INTERVAL '30 days' THEN 'EXPIRING SOON'
           ELSE 'OK'
       END AS expiry_status
FROM pg_authid
WHERE rolcanlogin = true
ORDER BY rolname;

-- ============================================================================
-- 4. PUBLIC SCHEMA PERMISSIONS
-- ============================================================================
-- What: By default, the PUBLIC role has CREATE and USAGE on the public schema.
--       This allows any authenticated user to create objects, which is a
--       security risk in multi-tenant environments.
-- Look for: public_can_create = true on any schema.
-- Remediation:
--   REVOKE CREATE ON SCHEMA public FROM PUBLIC;
--   REVOKE ALL ON DATABASE <db> FROM PUBLIC;
-- ============================================================================

SELECT nspname AS schema_name,
       has_schema_privilege('public', nspname, 'CREATE') AS public_can_create,
       has_schema_privilege('public', nspname, 'USAGE') AS public_can_use,
       CASE
           WHEN has_schema_privilege('public', nspname, 'CREATE') THEN
               'WARNING: PUBLIC can create objects in ' || nspname
           ELSE 'OK'
       END AS recommendation
FROM pg_namespace
WHERE nspname NOT LIKE 'pg_%'
  AND nspname != 'information_schema'
ORDER BY nspname;

-- ============================================================================
-- 5. UNENCRYPTED CONNECTIONS
-- ============================================================================
-- What: Identifies active connections not using SSL/TLS encryption.
--       Unencrypted connections expose data and credentials in transit.
-- Look for: ssl = false with non-local client_addr.
-- Remediation:
--   1. Configure ssl = on in postgresql.conf
--   2. Add hostssl entries in pg_hba.conf (replace host with hostssl)
--   3. Set ssl_min_protocol_version = 'TLSv1.2'
-- Note: Requires pg_stat_ssl (available since PostgreSQL 9.5).
-- ============================================================================

SELECT sa.datname AS database_name,
       sa.usename AS username,
       sa.client_addr,
       sa.client_port,
       ss.ssl,
       ss.version AS ssl_version,
       ss.cipher,
       sa.backend_start,
       sa.state,
       CASE
           WHEN ss.ssl = false AND sa.client_addr IS NOT NULL THEN 'CRITICAL: Unencrypted remote connection'
           WHEN ss.ssl = false AND sa.client_addr IS NULL THEN 'INFO: Local connection (no SSL needed)'
           ELSE 'OK: Encrypted'
       END AS recommendation
FROM pg_stat_ssl ss
JOIN pg_stat_activity sa USING (pid)
WHERE sa.pid != pg_backend_pid()
ORDER BY ss.ssl, sa.datname;

-- ============================================================================
-- 6. ROW-LEVEL SECURITY (RLS) STATUS
-- ============================================================================
-- What: Lists all user tables and their Row-Level Security status.
--       RLS is essential for multi-tenant databases to enforce data isolation.
-- Look for: Tables with sensitive data that have rowsecurity = false.
-- Remediation:
--   ALTER TABLE <table> ENABLE ROW LEVEL SECURITY;
--   ALTER TABLE <table> FORCE ROW LEVEL SECURITY;  -- Also apply to table owner
--   CREATE POLICY <name> ON <table> USING (<predicate>);
-- ============================================================================

SELECT schemaname,
       tablename,
       rowsecurity AS rls_enabled,
       forcerowsecurity AS rls_forced,
       CASE
           WHEN NOT rowsecurity THEN 'INFO: RLS not enabled'
           WHEN rowsecurity AND NOT forcerowsecurity THEN 'WARNING: RLS enabled but not forced (table owner bypasses)'
           ELSE 'OK: RLS enabled and forced'
       END AS recommendation
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY schemaname, tablename;

-- ============================================================================
-- 7. FUNCTIONS WITH SECURITY DEFINER (Privilege escalation risk)
-- ============================================================================
-- What: Functions marked SECURITY DEFINER execute with the privileges of the
--       function owner, not the caller. This can lead to privilege escalation
--       if the function is not carefully written (e.g., SQL injection).
-- Look for: Functions owned by superusers with SECURITY DEFINER.
-- Remediation: Review each function for:
--   - Input validation and parameterized queries
--   - Explicit search_path setting: SET search_path = pg_catalog, <schema>
--   - Minimal owner privileges
-- ============================================================================

SELECT n.nspname AS schema_name,
       p.proname AS function_name,
       pg_get_userbyid(p.proowner) AS owner,
       r.rolsuper AS owner_is_superuser,
       p.prosecdef AS security_definer,
       pg_get_function_arguments(p.oid) AS arguments,
       array_to_string(p.proconfig, ', ') AS config_settings,
       CASE
           WHEN r.rolsuper AND p.prosecdef THEN 'CRITICAL: SECURITY DEFINER owned by superuser'
           WHEN p.prosecdef AND (p.proconfig IS NULL OR NOT 'search_path' = ANY(
               SELECT split_part(unnest(p.proconfig), '=', 1)))
               THEN 'WARNING: SECURITY DEFINER without explicit search_path'
           ELSE 'REVIEW: Ensure input validation is robust'
       END AS recommendation
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
JOIN pg_roles r ON p.proowner = r.oid
WHERE p.prosecdef = true
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY n.nspname, p.proname;

-- ============================================================================
-- 8. EXTENSION AUDIT
-- ============================================================================
-- What: Lists installed extensions. Some extensions (e.g., dblink, file_fdw,
--       plpythonu) can be used for privilege escalation or data exfiltration.
-- Look for: Unnecessary or dangerous extensions.
-- Remediation: DROP EXTENSION <ext> if not needed.
--   High-risk extensions: dblink, file_fdw, postgres_fdw, plpythonu,
--   plperlu, adminpack, pg_execute_server_program
-- ============================================================================

SELECT e.extname AS extension_name,
       e.extversion AS version,
       n.nspname AS schema,
       r.rolname AS owner,
       CASE
           WHEN e.extname IN ('dblink', 'file_fdw', 'postgres_fdw') THEN 'WARNING: Can access external data'
           WHEN e.extname IN ('plpythonu', 'plperlu', 'pltclu') THEN 'CRITICAL: Untrusted PL - can execute OS commands'
           WHEN e.extname = 'adminpack' THEN 'WARNING: Administrative functions exposed'
           ELSE 'OK'
       END AS risk_level
FROM pg_extension e
JOIN pg_namespace n ON e.extnamespace = n.oid
JOIN pg_roles r ON e.extowner = r.oid
ORDER BY e.extname;

-- ============================================================================
-- 9. DEFAULT PRIVILEGES CHECK
-- ============================================================================
-- What: Reviews default privileges that automatically apply to newly created
--       objects. Overly permissive defaults can silently grant access.
-- Look for: Default grants to PUBLIC or broad roles.
-- Remediation:
--   ALTER DEFAULT PRIVILEGES IN SCHEMA <schema> REVOKE ALL ON TABLES FROM PUBLIC;
-- ============================================================================

SELECT pg_get_userbyid(d.defaclrole) AS granting_role,
       n.nspname AS schema_name,
       CASE d.defaclobjtype
           WHEN 'r' THEN 'TABLE'
           WHEN 'S' THEN 'SEQUENCE'
           WHEN 'f' THEN 'FUNCTION'
           WHEN 'T' THEN 'TYPE'
           WHEN 'n' THEN 'SCHEMA'
           ELSE d.defaclobjtype::text
       END AS object_type,
       array_to_string(d.defaclacl, E'\n') AS default_acl
FROM pg_default_acl d
LEFT JOIN pg_namespace n ON d.defaclnamespace = n.oid
ORDER BY granting_role, schema_name;

-- ============================================================================
-- 10. ORPHANED / DORMANT ROLES
-- ============================================================================
-- What: Roles that cannot log in and are not members of any other role,
--       or login roles that have never connected. These accumulate over time
--       and increase the attack surface.
-- Look for: Roles with no memberships and no login, or expired passwords.
-- Remediation: DROP ROLE <role>; (after confirming it owns no objects)
--   Check owned objects: SELECT * FROM pg_class WHERE relowner = <role_oid>;
-- ============================================================================

-- Roles that can't login and have no members
SELECT r.rolname,
       r.rolcanlogin,
       r.rolvaliduntil,
       r.rolconnlimit,
       CASE
           WHEN r.rolvaliduntil IS NOT NULL AND r.rolvaliduntil < NOW() THEN 'EXPIRED'
           WHEN NOT r.rolcanlogin AND NOT EXISTS (
               SELECT 1 FROM pg_auth_members am WHERE am.roleid = r.oid
           ) THEN 'ORPHANED: No login and no members'
           ELSE 'REVIEW'
       END AS status,
       (SELECT count(*) FROM pg_class WHERE relowner = r.oid) AS owned_objects
FROM pg_roles r
WHERE r.rolname NOT LIKE 'pg_%'
  AND r.rolname NOT IN ('postgres')
  AND (
      (NOT r.rolcanlogin AND NOT EXISTS (
          SELECT 1 FROM pg_auth_members am WHERE am.roleid = r.oid
      ))
      OR (r.rolvaliduntil IS NOT NULL AND r.rolvaliduntil < NOW())
  )
ORDER BY r.rolname;

-- ==========================================================================
-- End of PostgreSQL Security Audit
-- ==========================================================================
