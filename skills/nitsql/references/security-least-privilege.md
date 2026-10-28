# security-least-privilege
**Priority:** CRITICAL
**Category:** Security
**Applies to:** MSSQL, PostgreSQL, Oracle, MySQL

## Why It Matters

If an application account has `db_owner`, `SUPERUSER`, `DBA`, or `SUPER` privileges and its credentials leak, the attacker can read every table, drop schemas, create backdoor accounts, or exfiltrate the entire database. Least privilege limits the blast radius of a compromised credential to only the objects the application actually needs, satisfying SOC 2, HIPAA, and GDPR audit requirements.

## Incorrect Code

### MSSQL
```sql
-- Bad: application login with db_owner
CREATE USER AppUser WITH PASSWORD = 'P@ssw0rd';
ALTER ROLE db_owner ADD MEMBER AppUser;

-- Bad: granting ALL on the dbo schema
GRANT ALL ON SCHEMA::dbo TO AppUser;
```

### PostgreSQL
```sql
-- Bad: application role with SUPERUSER
CREATE ROLE app_user WITH LOGIN PASSWORD 'P@ssw0rd' SUPERUSER;

-- Bad: granting ALL on public schema
GRANT ALL ON ALL TABLES IN SCHEMA public TO app_user;
```

### Oracle
```sql
-- Bad: granting DBA role to application account
CREATE USER app_user IDENTIFIED BY "P@ssw0rd";
GRANT DBA TO app_user;

-- Bad: unrestricted access
GRANT ALL PRIVILEGES TO app_user;
```

### MySQL
```sql
-- Bad: granting ALL with GRANT OPTION
CREATE USER 'app_user'@'%' IDENTIFIED BY 'P@ssw0rd';
GRANT ALL PRIVILEGES ON *.* TO 'app_user'@'%' WITH GRANT OPTION;

-- Bad: granting SUPER privilege
GRANT SUPER ON *.* TO 'app_user'@'%';
```

## Correct Code

### MSSQL
```sql
-- Create purpose-specific schemas
CREATE SCHEMA app AUTHORIZATION dbo;
CREATE SCHEMA reports AUTHORIZATION dbo;

-- Application service role: read/write on app schema only
CREATE ROLE AppServiceRole;
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::app TO AppServiceRole;
GRANT EXECUTE ON SCHEMA::app TO AppServiceRole;

-- Reporting role: read-only
CREATE ROLE ReportingRole;
GRANT SELECT ON SCHEMA::app TO ReportingRole;
GRANT SELECT ON SCHEMA::reports TO ReportingRole;

-- CI/CD migration role: DDL only, not used at runtime
CREATE ROLE MigrationRole;
GRANT ALTER, CREATE TABLE, CREATE PROCEDURE, CREATE VIEW ON SCHEMA::app TO MigrationRole;

-- Create users and assign roles
CREATE USER AppServiceUser WITH PASSWORD = 'Str0ng!P@ss';
ALTER ROLE AppServiceRole ADD MEMBER AppServiceUser;

CREATE USER ReportUser WITH PASSWORD = 'An0ther!Pass';
ALTER ROLE ReportingRole ADD MEMBER ReportUser;

-- Column-level grant for sensitive data
GRANT SELECT (CustomerID, Name, Email) ON app.Customers TO AppServiceRole;
-- SSN and CreditCard columns are NOT granted
```

### PostgreSQL
```sql
-- Create purpose-specific schemas
CREATE SCHEMA app;
CREATE SCHEMA reports;

-- Application service role
CREATE ROLE app_service NOLOGIN;
GRANT USAGE ON SCHEMA app TO app_service;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA app TO app_service;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA app TO app_service;
ALTER DEFAULT PRIVILEGES IN SCHEMA app
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_service;

-- Reporting role: read-only
CREATE ROLE reporting NOLOGIN;
GRANT USAGE ON SCHEMA app, reports TO reporting;
GRANT SELECT ON ALL TABLES IN SCHEMA app TO reporting;
GRANT SELECT ON ALL TABLES IN SCHEMA reports TO reporting;
ALTER DEFAULT PRIVILEGES IN SCHEMA app GRANT SELECT ON TABLES TO reporting;

-- Login users inherit from roles
CREATE ROLE app_user WITH LOGIN PASSWORD 'Str0ng!P@ss';
GRANT app_service TO app_user;

CREATE ROLE report_user WITH LOGIN PASSWORD 'An0ther!Pass';
GRANT reporting TO report_user;
```

### Oracle
```sql
-- Create custom role (not DBA)
CREATE ROLE app_service_role;

-- Grant object-level privileges
GRANT SELECT, INSERT, UPDATE, DELETE ON app.orders TO app_service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.customers TO app_service_role;
GRANT EXECUTE ON app.pkg_order_api TO app_service_role;

-- Reporting role
CREATE ROLE reporting_role;
GRANT SELECT ON app.orders TO reporting_role;
GRANT SELECT ON app.customers TO reporting_role;
GRANT SELECT ANY TABLE TO reporting_role;  -- only if truly needed for BI tools

-- Create users with roles
CREATE USER app_user IDENTIFIED BY "Str0ng!P@ss"
    DEFAULT TABLESPACE app_data QUOTA 0 ON app_data;
GRANT app_service_role TO app_user;
GRANT CREATE SESSION TO app_user;

-- Never grant these to application accounts:
-- GRANT DBA TO app_user;            -- NO
-- GRANT ALTER ANY TABLE TO app_user; -- NO
-- GRANT DROP ANY TABLE TO app_user;  -- NO
```

### MySQL
```sql
-- Create roles (MySQL 8.0+)
CREATE ROLE 'app_service_role';
CREATE ROLE 'reporting_role';

-- Application role: scoped to specific database
GRANT SELECT, INSERT, UPDATE, DELETE ON myapp.* TO 'app_service_role';
GRANT EXECUTE ON myapp.* TO 'app_service_role';

-- Reporting role: read-only
GRANT SELECT ON myapp.* TO 'reporting_role';

-- Create users and assign roles
CREATE USER 'app_user'@'10.0.0.%' IDENTIFIED BY 'Str0ng!P@ss';
GRANT 'app_service_role' TO 'app_user'@'10.0.0.%';
SET DEFAULT ROLE 'app_service_role' TO 'app_user'@'10.0.0.%';

CREATE USER 'report_user'@'10.0.0.%' IDENTIFIED BY 'An0ther!Pass';
GRANT 'reporting_role' TO 'report_user'@'10.0.0.%';
SET DEFAULT ROLE 'reporting_role' TO 'report_user'@'10.0.0.%';

-- Restrict host access: never use '%' for production accounts
-- Never grant these to application accounts:
-- GRANT SUPER ON *.* TO 'app_user'@'%';   -- NO
-- GRANT ALL ON *.* TO 'app_user'@'%';     -- NO
-- GRANT FILE ON *.* TO 'app_user'@'%';    -- NO
```

## Application Code Detection

### Python

```python
# Bad (any dialect): hardcoded overprivileged credentials
conn = pyodbc.connect("Server=srv;Database=db;UID=sa;PWD=secret")

# Good: use environment variables, secrets manager, or managed identity
import os
conn_str = os.environ["DB_CONNECTION_STRING"]  # injected by vault/secrets manager
```

### Node.js

```javascript
// Bad: sa / root / admin credentials in code
const pool = await sql.connect({ user: 'sa', password: 'secret', ... });

// Good: pull from environment or secrets manager
const pool = await sql.connect({
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    server: process.env.DB_SERVER,
    database: process.env.DB_NAME
});
```

### C#

```csharp
// Bad: db_owner or sa in connection string
var cs = "Server=srv;Database=db;User Id=sa;Password=secret;";

// Good: use Azure Managed Identity (MSSQL) or minimal-privilege user
// MSSQL with Azure AD
var cs = "Server=srv.database.windows.net;Database=db;Authentication=Active Directory Managed Identity;";

// Good: per-purpose connection strings via DI
services.AddDbContext<AppDbContext>(o => o.UseSqlServer(config["ConnectionStrings:App"]));
services.AddDbContext<ReportDbContext>(o => o.UseSqlServer(config["ConnectionStrings:Reports"]));
```

## Exceptions

- **Database migration tools** (Flyway, Liquibase, EF Migrations) need DDL privileges. Use a separate user that is never used at runtime and whose credentials are stored in the CI/CD pipeline only.
- **DBA administrative sessions** require elevated privileges. These should use personal accounts with MFA, not shared logins.
- **Development environments** may use broader permissions for convenience, but staging and production must enforce least privilege.

## How to Detect

### MSSQL
```sql
-- Users with db_owner or sysadmin
SELECT dp.name AS UserName, r.name AS RoleName
FROM sys.database_role_members rm
JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
JOIN sys.database_principals dp ON rm.member_principal_id = dp.principal_id
WHERE r.name IN ('db_owner', 'db_securityadmin', 'db_ddladmin')
ORDER BY r.name, dp.name;
```

### PostgreSQL
```sql
-- Roles with superuser or createrole
SELECT rolname, rolsuper, rolcreaterole, rolcreatedb
FROM pg_roles
WHERE rolsuper OR rolcreaterole
ORDER BY rolname;
```

### Oracle
```sql
-- Users with DBA role or critical system privileges
SELECT grantee, granted_role
FROM dba_role_privs
WHERE granted_role IN ('DBA', 'SYSDBA', 'SYSOPER')
ORDER BY grantee;

SELECT grantee, privilege
FROM dba_sys_privs
WHERE privilege IN ('ALTER ANY TABLE', 'DROP ANY TABLE', 'SELECT ANY TABLE')
ORDER BY grantee;
```

### MySQL
```sql
-- Users with global ALL PRIVILEGES or SUPER
SELECT user, host
FROM mysql.user
WHERE Super_priv = 'Y'
   OR Grant_priv = 'Y'
ORDER BY user;

-- MySQL 8.0+ with roles
SELECT TO_USER, TO_HOST, FROM_USER
FROM mysql.role_edges
ORDER BY TO_USER;
```

## Advanced: Row-Level Security (RLS) for Multi-Tenant Isolation

For applications sharing tables across tenants, use row-level security to guarantee data isolation at the database layer:

**MSSQL:**
```sql
-- Create security policy with session context
CREATE FUNCTION dbo.fn_tenant_filter(@TenantID INT) RETURNS TABLE
WITH SCHEMABINDING AS
RETURN SELECT 1 AS result WHERE @TenantID = CAST(SESSION_CONTEXT(N'tenant_id') AS INT);

CREATE SECURITY POLICY dbo.TenantPolicy
ADD FILTER PREDICATE dbo.fn_tenant_filter(TenantID) ON dbo.Orders;
-- Application sets: EXEC sp_set_session_context N'tenant_id', @TenantID;
```

**PostgreSQL:**
```sql
ALTER TABLE app.orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON app.orders
    USING (tenant_id = current_setting('app.tenant_id')::INT);
-- Application sets: SET app.tenant_id = '42';
```

**Oracle (VPD):**
```sql
CREATE OR REPLACE FUNCTION security.tenant_policy(p_schema VARCHAR2, p_table VARCHAR2)
RETURN VARCHAR2 AS
BEGIN
    RETURN 'TENANT_ID = SYS_CONTEXT(''APP_CTX'', ''TENANT_ID'')';
END;
/
EXEC DBMS_RLS.ADD_POLICY('APP', 'ORDERS', 'TENANT_POLICY', 'SECURITY', 'TENANT_POLICY');
```

**MySQL:** No native RLS. Use views with `WHERE tenant_id = @current_tenant` as the access layer, and revoke direct table access from application roles.
