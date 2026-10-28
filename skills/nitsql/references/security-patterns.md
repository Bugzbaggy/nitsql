# Database Security Patterns

Comprehensive security patterns for PostgreSQL, MySQL, SQL Server, Oracle, and SQLite. Covers SQL injection prevention, least privilege, encryption, auditing, and common anti-patterns.

## 1. SQL Injection Prevention with Parameterized Queries

SQL injection is the most exploited database vulnerability (OWASP Top 10). String-concatenated queries let attackers read, modify, or delete any data. Parameterized queries also enable plan caching, improving performance.

### Python

```python
# --- PostgreSQL (psycopg2) ---
# BAD: SQL injection vulnerable
cursor.execute(f"SELECT * FROM users WHERE email = '{user_input}'")

# GOOD: Parameterized query
cursor.execute("SELECT * FROM app.users WHERE email = %s", (user_input,))

# --- MySQL (pymysql / mysql-connector-python) ---
# BAD
cursor.execute(f"SELECT * FROM users WHERE email = '{user_input}'")

# GOOD
cursor.execute("SELECT * FROM users WHERE email = %s", (user_input,))

# --- SQL Server (pyodbc) ---
# BAD
cursor.execute(f"SELECT * FROM dbo.Users WHERE Email = '{user_input}'")

# GOOD
cursor.execute("SELECT UserID, Name FROM dbo.Users WHERE Email = ?", (user_input,))

# --- Oracle (oracledb) ---
# BAD
cursor.execute(f"SELECT * FROM users WHERE email = '{user_input}'")

# GOOD
cursor.execute("SELECT user_id, name FROM users WHERE email = :email", {"email": user_input})

# --- SQLite (sqlite3) ---
# BAD
cursor.execute(f"SELECT * FROM users WHERE email = '{user_input}'")

# GOOD
cursor.execute("SELECT user_id, name FROM users WHERE email = ?", (user_input,))
```

### Node.js

```javascript
// --- PostgreSQL (pg) ---
// BAD
await client.query(`SELECT * FROM users WHERE email = '${userInput}'`);
// GOOD
await client.query('SELECT user_id, name FROM app.users WHERE email = $1', [userInput]);

// --- MySQL (mysql2) ---
// BAD
await conn.execute(`SELECT * FROM users WHERE email = '${userInput}'`);
// GOOD
await conn.execute('SELECT user_id, name FROM users WHERE email = ?', [userInput]);

// --- SQL Server (mssql) ---
// BAD
await pool.request().query(`SELECT * FROM dbo.Users WHERE Email = '${userInput}'`);
// GOOD
await pool.request()
    .input('email', sql.NVarChar(255), userInput)
    .query('SELECT UserID, Name FROM dbo.Users WHERE Email = @email');

// --- Oracle (oracledb) ---
// BAD
await conn.execute(`SELECT * FROM users WHERE email = '${userInput}'`);
// GOOD
await conn.execute('SELECT user_id, name FROM users WHERE email = :email', { email: userInput });

// --- SQLite (better-sqlite3) ---
// BAD
db.prepare(`SELECT * FROM users WHERE email = '${userInput}'`).all();
// GOOD
db.prepare('SELECT user_id, name FROM users WHERE email = ?').all(userInput);
```

### C#

```csharp
// --- PostgreSQL (Npgsql) ---
// BAD
cmd.CommandText = $"SELECT * FROM users WHERE email = '{userInput}'";
// GOOD
cmd.CommandText = "SELECT user_id, name FROM app.users WHERE email = @email";
cmd.Parameters.AddWithValue("@email", userInput);

// --- MySQL (MySqlConnector) ---
// BAD
cmd.CommandText = $"SELECT * FROM users WHERE email = '{userInput}'";
// GOOD
cmd.CommandText = "SELECT user_id, name FROM users WHERE email = @email";
cmd.Parameters.AddWithValue("@email", userInput);

// --- SQL Server (SqlClient) ---
// BAD
cmd.CommandText = $"SELECT * FROM dbo.Users WHERE Email = '{userInput}'";
// GOOD
cmd.CommandText = "SELECT UserID, Name FROM dbo.Users WHERE Email = @email";
cmd.Parameters.Add("@email", SqlDbType.NVarChar, 255).Value = userInput;

// --- Oracle (ODP.NET) ---
// BAD
cmd.CommandText = $"SELECT * FROM users WHERE email = '{userInput}'";
// GOOD
cmd.CommandText = "SELECT user_id, name FROM users WHERE email = :email";
cmd.BindByName = true;
cmd.Parameters.Add(new OracleParameter("email", userInput));

// --- SQLite (Microsoft.Data.Sqlite) ---
// BAD
cmd.CommandText = $"SELECT * FROM users WHERE email = '{userInput}'";
// GOOD
cmd.CommandText = "SELECT user_id, name FROM users WHERE email = @email";
cmd.Parameters.AddWithValue("@email", userInput);
```

### Java

```java
// Works for all dialects via JDBC -- placeholder is always ?
// BAD
Statement stmt = conn.createStatement();
ResultSet rs = stmt.executeQuery("SELECT * FROM users WHERE email = '" + userInput + "'");

// GOOD
PreparedStatement ps = conn.prepareStatement("SELECT user_id, name FROM users WHERE email = ?");
ps.setString(1, userInput);
ResultSet rs = ps.executeQuery();
```

### Dynamic Column/Table Names Cannot Be Parameterized

Use allowlists instead:

```python
ALLOWED_SORT_COLUMNS = {"name", "email", "created_at", "status"}
ALLOWED_DIRECTIONS = {"ASC", "DESC"}

def get_users_sorted(sort_col: str, direction: str = "ASC"):
    if sort_col not in ALLOWED_SORT_COLUMNS:
        raise ValueError(f"Invalid sort column: {sort_col}")
    if direction.upper() not in ALLOWED_DIRECTIONS:
        raise ValueError(f"Invalid direction: {direction}")

    query = f"SELECT user_id, name, email FROM users ORDER BY {sort_col} {direction}"
    cursor.execute(query)
```

## 2. Principle of Least Privilege

If an application account has `db_owner`, `SUPERUSER`, `DBA`, or `SUPER` privileges and its credentials leak, the attacker can read every table, drop schemas, or exfiltrate the entire database. Least privilege limits the blast radius.

### PostgreSQL

```sql
-- Create purpose-specific schemas
CREATE SCHEMA app;
CREATE SCHEMA reports;

-- Application service role: read/write on app schema only
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

-- Create users with host restriction and assign roles
CREATE USER 'app_user'@'10.0.0.%' IDENTIFIED BY 'Str0ng!P@ss';
GRANT 'app_service_role' TO 'app_user'@'10.0.0.%';
SET DEFAULT ROLE 'app_service_role' TO 'app_user'@'10.0.0.%';

CREATE USER 'report_user'@'10.0.0.%' IDENTIFIED BY 'An0ther!Pass';
GRANT 'reporting_role' TO 'report_user'@'10.0.0.%';
SET DEFAULT ROLE 'reporting_role' TO 'report_user'@'10.0.0.%';

-- NEVER grant these to application accounts:
-- GRANT SUPER ON *.* TO 'app_user'@'%';
-- GRANT ALL ON *.* TO 'app_user'@'%';
-- GRANT FILE ON *.* TO 'app_user'@'%';
```

### SQL Server

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

-- Create users with roles
CREATE USER app_user IDENTIFIED BY "Str0ng!P@ss"
    DEFAULT TABLESPACE app_data QUOTA 0 ON app_data;
GRANT app_service_role TO app_user;
GRANT CREATE SESSION TO app_user;

-- NEVER grant these to application accounts:
-- GRANT DBA TO app_user;
-- GRANT ALTER ANY TABLE TO app_user;
-- GRANT DROP ANY TABLE TO app_user;
```

### SQLite

```sql
-- SQLite has no built-in user system. Security is enforced at the application layer.
-- Best practices:
-- 1. Use file system permissions to restrict database file access
-- 2. Open databases in read-only mode when writes are not needed:
--    sqlite3.connect('file:mydb.db?mode=ro', uri=True)
-- 3. Disable loading of extensions if not needed:
--    conn.enable_load_extension(False)
-- 4. Use PRAGMA settings to harden:
```

```python
# SQLite hardening in Python
import sqlite3

conn = sqlite3.connect('mydb.db')
conn.execute("PRAGMA journal_mode=WAL")        # Better concurrency
conn.execute("PRAGMA foreign_keys=ON")          # Enforce referential integrity
conn.execute("PRAGMA trusted_schema=OFF")       # Prevent malicious schema objects
conn.execute("PRAGMA cell_size_check=ON")       # Detect corruption
```

## 3. Column-Level Grants and Row-Level Security (RLS)

### Column-Level Grants

**PostgreSQL**
```sql
-- Grant access to non-sensitive columns only
GRANT SELECT (customer_id, name, email) ON app.customers TO app_service;
-- SSN and credit_card columns are NOT granted
```

**SQL Server**
```sql
GRANT SELECT (CustomerID, Name, Email) ON app.Customers TO AppServiceRole;
-- SSN and CreditCard columns are NOT granted
```

**MySQL**
```sql
GRANT SELECT (customer_id, name, email) ON myapp.customers TO 'app_service_role';
```

**Oracle**
```sql
-- Oracle does not support column-level SELECT grants directly.
-- Use a view to expose only permitted columns:
CREATE VIEW app.v_customers AS
SELECT customer_id, name, email FROM app.customers;
GRANT SELECT ON app.v_customers TO app_service_role;
```

### Row-Level Security (RLS) for Multi-Tenant Isolation

**PostgreSQL**
```sql
ALTER TABLE app.orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON app.orders
    USING (tenant_id = current_setting('app.tenant_id')::INT);
-- Application sets: SET app.tenant_id = '42';
```

**SQL Server**
```sql
-- Create security predicate function
CREATE FUNCTION dbo.fn_tenant_filter(@TenantID INT)
RETURNS TABLE
WITH SCHEMABINDING AS
RETURN SELECT 1 AS result
WHERE @TenantID = CAST(SESSION_CONTEXT(N'tenant_id') AS INT);

CREATE SECURITY POLICY dbo.TenantPolicy
ADD FILTER PREDICATE dbo.fn_tenant_filter(TenantID) ON dbo.Orders;
-- Application sets: EXEC sp_set_session_context N'tenant_id', @TenantID;
```

**Oracle (Virtual Private Database)**
```sql
CREATE OR REPLACE FUNCTION security.tenant_policy(
    p_schema VARCHAR2, p_table VARCHAR2
) RETURN VARCHAR2 AS
BEGIN
    RETURN 'TENANT_ID = SYS_CONTEXT(''APP_CTX'', ''TENANT_ID'')';
END;
/
EXEC DBMS_RLS.ADD_POLICY('APP', 'ORDERS', 'TENANT_POLICY',
    'SECURITY', 'TENANT_POLICY');
```

**MySQL**
```sql
-- No native RLS. Use views as the access layer:
CREATE VIEW myapp.v_orders AS
SELECT * FROM myapp.orders WHERE tenant_id = @current_tenant;
-- Revoke direct table access; grant only the view.
GRANT SELECT ON myapp.v_orders TO 'app_service_role';
```

## 4. Connection String Security

Never hardcode credentials in source code. Use environment variables, secrets managers, or managed identity.

### Anti-Patterns

```python
# BAD: Hardcoded credentials in source code
conn = psycopg2.connect("host=prod-db dbname=mydb user=admin password=s3cret123")

# BAD: Credentials in config files committed to git
config = {"db_password": "s3cret123"}  # This will end up in version control

# BAD: Using sa/root/admin accounts for application connections
conn = pyodbc.connect("Server=srv;Database=db;UID=sa;PWD=secret")
```

### Correct Patterns

```python
import os

# GOOD: Environment variables (all dialects)
conn_str = os.environ["DATABASE_URL"]

# GOOD: Azure Managed Identity (SQL Server)
conn_str = (
    "Driver={ODBC Driver 18 for SQL Server};"
    "Server=myserver.database.windows.net;"
    "Database=mydb;"
    "Authentication=ActiveDirectoryMsi;"
)

# GOOD: AWS Secrets Manager
import boto3
import json
client = boto3.client('secretsmanager')
secret = json.loads(client.get_secret_value(SecretId='prod/db')['SecretString'])
conn = psycopg2.connect(
    host=secret['host'], dbname=secret['dbname'],
    user=secret['username'], password=secret['password']
)

# GOOD: HashiCorp Vault
import hvac
client = hvac.Client(url='https://vault.example.com')
creds = client.secrets.database.generate_credentials('app-role')
conn = psycopg2.connect(
    host='db.example.com', dbname='mydb',
    user=creds['data']['username'], password=creds['data']['password']
)
```

```javascript
// Node.js: GOOD patterns
// Environment variables
const pool = new Pool({
    connectionString: process.env.DATABASE_URL,
    ssl: { rejectUnauthorized: true }
});

// Azure Managed Identity (SQL Server)
const config = {
    server: process.env.DB_SERVER,
    database: process.env.DB_NAME,
    authentication: { type: 'azure-active-directory-msi-app-service' },
    options: { encrypt: true }
};
```

```csharp
// C#: GOOD patterns
// Configuration from secrets (not appsettings.json committed to git)
var connStr = configuration["ConnectionStrings:DefaultConnection"];

// Azure Managed Identity (SQL Server)
var connStr = "Server=myserver.database.windows.net;Database=mydb;"
            + "Authentication=Active Directory Managed Identity;";

// Azure Key Vault
var secret = await keyVaultClient.GetSecretAsync("https://myvault.vault.azure.net/", "db-password");
var connStr = $"Host=db;Database=mydb;Username=app;Password={secret.Value}";
```

## 5. Stored Procedure Security

### EXECUTE AS / SECURITY DEFINER

**PostgreSQL**
```sql
-- SECURITY DEFINER: runs with the privileges of the function owner
CREATE OR REPLACE FUNCTION app.create_order(p_customer_id INT, p_total NUMERIC)
RETURNS INT AS $$
DECLARE
    v_order_id INT;
BEGIN
    INSERT INTO app.orders (customer_id, total, status)
    VALUES (p_customer_id, p_total, 'pending')
    RETURNING order_id INTO v_order_id;
    RETURN v_order_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = app, pg_catalog;  -- Lock search_path to prevent hijacking

-- Grant EXECUTE on the function, not direct table access
REVOKE ALL ON FUNCTION app.create_order(INT, NUMERIC) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.create_order(INT, NUMERIC) TO app_service;
```

**SQL Server**
```sql
-- EXECUTE AS OWNER: runs with owner's permissions
CREATE PROCEDURE app.CreateOrder
    @CustomerID INT,
    @Total DECIMAL(10,2),
    @OrderID INT OUTPUT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO app.Orders (CustomerID, Total, Status)
    VALUES (@CustomerID, @Total, 'pending');
    SET @OrderID = SCOPE_IDENTITY();
END;

-- Grant EXECUTE, not direct table access
GRANT EXECUTE ON app.CreateOrder TO AppServiceRole;
```

**Oracle**
```sql
-- AUTHID DEFINER (default): runs with owner's privileges
CREATE OR REPLACE PROCEDURE app.create_order(
    p_customer_id IN NUMBER,
    p_total IN NUMBER,
    p_order_id OUT NUMBER
) AUTHID DEFINER AS
BEGIN
    INSERT INTO app.orders (customer_id, total, status)
    VALUES (p_customer_id, p_total, 'pending')
    RETURNING order_id INTO p_order_id;
    COMMIT;
END;
/
GRANT EXECUTE ON app.create_order TO app_service_role;
```

**MySQL**
```sql
-- SQL SECURITY DEFINER (default): runs with definer's privileges
DELIMITER //
CREATE PROCEDURE myapp.create_order(
    IN p_customer_id INT,
    IN p_total DECIMAL(10,2),
    OUT p_order_id INT
)
SQL SECURITY DEFINER
BEGIN
    INSERT INTO myapp.orders (customer_id, total, status)
    VALUES (p_customer_id, p_total, 'pending');
    SET p_order_id = LAST_INSERT_ID();
END //
DELIMITER ;

GRANT EXECUTE ON PROCEDURE myapp.create_order TO 'app_service_role';
```

## 6. Encryption at Rest and in Transit

### Encryption in Transit (TLS/SSL)

| Dialect | Connection String / Config |
|---------|--------------------------|
| PostgreSQL | `sslmode=require` (or `verify-full` for CA validation) |
| MySQL | `ssl_ca=/path/to/ca.pem; ssl_verify_cert=true` or `--require_secure_transport=ON` server-side |
| SQL Server | `Encrypt=yes;TrustServerCertificate=no` |
| Oracle | `sqlnet.ora`: `SQLNET.ENCRYPTION_CLIENT=REQUIRED` or use `tcps://` protocol |
| SQLite | N/A (local file, no network layer) |

### Encryption at Rest

**PostgreSQL**
```sql
-- pgcrypto extension for column-level encryption
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Encrypt sensitive data
INSERT INTO app.users (name, ssn_encrypted)
VALUES ('Alice', pgp_sym_encrypt('123-45-6789', current_setting('app.encryption_key')));

-- Decrypt
SELECT name, pgp_sym_decrypt(ssn_encrypted, current_setting('app.encryption_key')) AS ssn
FROM app.users WHERE user_id = 1;

-- Disk-level: use LUKS/dm-crypt on the data directory, or cloud-managed encryption (AWS RDS, Azure)
```

**SQL Server**
```sql
-- Transparent Data Encryption (TDE) -- encrypts the entire database at rest
CREATE DATABASE ENCRYPTION KEY
WITH ALGORITHM = AES_256
ENCRYPTION BY SERVER CERTIFICATE MyServerCert;

ALTER DATABASE MyDB SET ENCRYPTION ON;

-- Always Encrypted for column-level encryption (client-side)
-- The database never sees the plaintext
CREATE TABLE dbo.Patients (
    PatientID INT IDENTITY PRIMARY KEY,
    SSN NVARCHAR(11) COLLATE Latin1_General_BIN2
        ENCRYPTED WITH (
            COLUMN_ENCRYPTION_KEY = CEK1,
            ENCRYPTION_TYPE = DETERMINISTIC,
            ALGORITHM = 'AEAD_AES_256_CBC_HMAC_SHA_256'
        ),
    Name NVARCHAR(100)
);
```

**MySQL**
```sql
-- InnoDB tablespace encryption (at rest)
ALTER TABLE users ENCRYPTION='Y';

-- Or server-wide in my.cnf:
-- [mysqld]
-- innodb_encrypt_tables=ON
-- innodb_encrypt_log=ON

-- AES encryption for column-level
INSERT INTO users (name, ssn_encrypted)
VALUES ('Alice', AES_ENCRYPT('123-45-6789', @encryption_key));

SELECT name, AES_DECRYPT(ssn_encrypted, @encryption_key) AS ssn
FROM users WHERE user_id = 1;
```

**Oracle**
```sql
-- Transparent Data Encryption (TDE)
ALTER SYSTEM SET ENCRYPTION KEY IDENTIFIED BY "wallet_password";
ALTER TABLE app.customers MODIFY (ssn ENCRYPT);

-- Or encrypt the entire tablespace:
CREATE TABLESPACE secure_ts
DATAFILE '/path/to/secure01.dbf' SIZE 100M
ENCRYPTION USING 'AES256' DEFAULT STORAGE(ENCRYPT);
```

## 7. Audit Logging Patterns

### PostgreSQL

```sql
-- Using pgAudit extension
-- postgresql.conf: shared_preload_libraries = 'pgaudit'
-- postgresql.conf: pgaudit.log = 'write, ddl'
-- postgresql.conf: pgaudit.log_catalog = off

-- Custom audit trigger
CREATE TABLE app.audit_log (
    audit_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name TEXT NOT NULL,
    operation TEXT NOT NULL,  -- INSERT, UPDATE, DELETE
    old_data JSONB,
    new_data JSONB,
    changed_by TEXT DEFAULT current_user,
    changed_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION app.audit_trigger_func()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        INSERT INTO app.audit_log (table_name, operation, old_data)
        VALUES (TG_TABLE_NAME, 'DELETE', to_jsonb(OLD));
        RETURN OLD;
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO app.audit_log (table_name, operation, old_data, new_data)
        VALUES (TG_TABLE_NAME, 'UPDATE', to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSIF TG_OP = 'INSERT' THEN
        INSERT INTO app.audit_log (table_name, operation, new_data)
        VALUES (TG_TABLE_NAME, 'INSERT', to_jsonb(NEW));
        RETURN NEW;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER orders_audit
AFTER INSERT OR UPDATE OR DELETE ON app.orders
FOR EACH ROW EXECUTE FUNCTION app.audit_trigger_func();
```

### SQL Server

```sql
-- SQL Server Audit (built-in)
CREATE SERVER AUDIT MainAudit
TO FILE (FILEPATH = 'C:\AuditLogs\', MAXSIZE = 100 MB);
ALTER SERVER AUDIT MainAudit WITH (STATE = ON);

CREATE DATABASE AUDIT SPECIFICATION AppAudit
FOR SERVER AUDIT MainAudit
ADD (INSERT, UPDATE, DELETE ON dbo.Orders BY public),
ADD (INSERT, UPDATE, DELETE ON dbo.Customers BY public)
WITH (STATE = ON);

-- Custom audit table with trigger
CREATE TABLE dbo.AuditLog (
    AuditID BIGINT IDENTITY PRIMARY KEY,
    TableName NVARCHAR(128),
    Operation NVARCHAR(10),
    OldData NVARCHAR(MAX),  -- JSON
    NewData NVARCHAR(MAX),  -- JSON
    ChangedBy NVARCHAR(128) DEFAULT SUSER_SNAME(),
    ChangedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);
```

### MySQL

```sql
-- Enable general audit (Enterprise: audit_log plugin, Community: use triggers)
-- my.cnf: plugin-load-add=audit_log.so

-- Custom audit table
CREATE TABLE myapp.audit_log (
    audit_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    table_name VARCHAR(128) NOT NULL,
    operation VARCHAR(10) NOT NULL,
    old_data JSON,
    new_data JSON,
    changed_by VARCHAR(128) DEFAULT CURRENT_USER(),
    changed_at DATETIME DEFAULT NOW()
);

DELIMITER //
CREATE TRIGGER orders_after_update
AFTER UPDATE ON myapp.orders
FOR EACH ROW
BEGIN
    INSERT INTO myapp.audit_log (table_name, operation, old_data, new_data)
    VALUES ('orders', 'UPDATE',
        JSON_OBJECT('order_id', OLD.order_id, 'status', OLD.status, 'total', OLD.total),
        JSON_OBJECT('order_id', NEW.order_id, 'status', NEW.status, 'total', NEW.total));
END //
DELIMITER ;
```

### Oracle

```sql
-- Unified Auditing (12c+)
CREATE AUDIT POLICY svc_audit
ACTIONS INSERT ON app.orders,
        UPDATE ON app.orders,
        DELETE ON app.orders,
        INSERT ON app.customers,
        UPDATE ON app.customers;

AUDIT POLICY svc_audit;

-- Query audit trail
SELECT event_timestamp, dbusername, action_name, object_name, sql_text
FROM unified_audit_trail
WHERE object_schema = 'APP'
ORDER BY event_timestamp DESC
FETCH FIRST 100 ROWS ONLY;

-- Custom audit with autonomous transaction (persists even after rollback)
CREATE OR REPLACE PROCEDURE app.log_audit(
    p_table VARCHAR2, p_operation VARCHAR2,
    p_old_data VARCHAR2, p_new_data VARCHAR2
) AS
    PRAGMA AUTONOMOUS_TRANSACTION;
BEGIN
    INSERT INTO app.audit_log (table_name, operation, old_data, new_data, changed_by, changed_at)
    VALUES (p_table, p_operation, p_old_data, p_new_data, SYS_CONTEXT('USERENV','SESSION_USER'), SYSTIMESTAMP);
    COMMIT;
END;
/
```

## 8. Common Security Anti-Patterns and Fixes

### Anti-Pattern 1: Using Admin Accounts for Application Access

```sql
-- BAD (all dialects): application connecting as superuser
-- PostgreSQL: SUPERUSER
-- MySQL: root or SUPER privilege
-- SQL Server: sa or db_owner
-- Oracle: SYS or DBA role

-- FIX: Create a dedicated application role with minimal permissions (see Section 2)
```

### Anti-Pattern 2: Granting Excessive Permissions

```sql
-- BAD
GRANT ALL PRIVILEGES ON *.* TO 'app_user'@'%';          -- MySQL
GRANT ALL ON SCHEMA::dbo TO AppUser;                      -- SQL Server
GRANT ALL ON ALL TABLES IN SCHEMA public TO app_user;     -- PostgreSQL

-- FIX: Grant only what the application needs
GRANT SELECT, INSERT, UPDATE ON myapp.orders TO 'app_service_role';     -- MySQL
GRANT SELECT, INSERT, UPDATE ON SCHEMA::app TO AppServiceRole;          -- SQL Server
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA app TO app_service; -- PostgreSQL
```

### Anti-Pattern 3: Using Wildcard Host for MySQL Users

```sql
-- BAD: accessible from any host
CREATE USER 'app_user'@'%' IDENTIFIED BY 'password';

-- FIX: restrict to application subnet
CREATE USER 'app_user'@'10.0.1.%' IDENTIFIED BY 'Str0ng!P@ss';
```

### Anti-Pattern 4: Swallowing Errors in Exception Handlers

```sql
-- BAD (Oracle): silently ignoring all errors
EXCEPTION
    WHEN OTHERS THEN NULL;

-- BAD (PostgreSQL): catching everything without logging
EXCEPTION
    WHEN OTHERS THEN
        -- do nothing

-- FIX: always log and re-raise
EXCEPTION
    WHEN OTHERS THEN
        INSERT INTO app.error_log (error_message, error_date)
        VALUES (SQLERRM, NOW());
        RAISE;
```

### Anti-Pattern 5: Storing Passwords in Plain Text

```sql
-- BAD: plain text passwords
INSERT INTO users (username, password) VALUES ('alice', 'mypassword123');

-- FIX: use application-level hashing (bcrypt, argon2, scrypt)
-- NEVER hash passwords in SQL -- use your application framework
```

```python
# Python: correct password hashing
import bcrypt

# Storing
hashed = bcrypt.hashpw(password.encode(), bcrypt.gensalt())
cursor.execute("INSERT INTO users (username, password_hash) VALUES (%s, %s)",
               (username, hashed.decode()))

# Verifying
cursor.execute("SELECT password_hash FROM users WHERE username = %s", (username,))
stored_hash = cursor.fetchone()[0]
if bcrypt.checkpw(password.encode(), stored_hash.encode()):
    print("Login successful")
```

### Anti-Pattern 6: Missing Input Validation for Dynamic SQL

```sql
-- BAD (SQL Server): dynamic SQL for DDL without validation
CREATE PROCEDURE dbo.DropTable @TableName NVARCHAR(128)
AS
BEGIN
    EXEC('DROP TABLE ' + @TableName);  -- SQL injection risk
END;

-- FIX: validate against allowlist
CREATE PROCEDURE dbo.DropTable @TableName NVARCHAR(128)
AS
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM sys.tables
        WHERE name = @TableName AND schema_id = SCHEMA_ID('staging')
    )
        THROW 50001, 'Table not found in staging schema', 1;

    DECLARE @SQL NVARCHAR(MAX) = N'DROP TABLE staging.' + QUOTENAME(@TableName);
    EXEC sp_executesql @SQL;
END;
```

## 9. Detecting Overprivileged Accounts

### PostgreSQL
```sql
SELECT rolname, rolsuper, rolcreaterole, rolcreatedb
FROM pg_roles
WHERE rolsuper OR rolcreaterole
ORDER BY rolname;
```

### MySQL
```sql
SELECT user, host FROM mysql.user
WHERE Super_priv = 'Y' OR Grant_priv = 'Y'
ORDER BY user;
```

### SQL Server
```sql
SELECT dp.name AS UserName, r.name AS RoleName
FROM sys.database_role_members rm
JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
JOIN sys.database_principals dp ON rm.member_principal_id = dp.principal_id
WHERE r.name IN ('db_owner', 'db_securityadmin', 'db_ddladmin')
ORDER BY r.name, dp.name;
```

### Oracle
```sql
SELECT grantee, granted_role
FROM dba_role_privs
WHERE granted_role IN ('DBA', 'SYSDBA', 'SYSOPER')
ORDER BY grantee;
```

## 10. Security Checklist

| Check | PostgreSQL | MySQL | SQL Server | Oracle | SQLite |
|-------|-----------|-------|------------|--------|--------|
| Parameterized queries | `%s` / `$1` | `%s` / `?` | `?` / `@param` | `:param` | `?` |
| TLS/SSL enabled | `sslmode=require` | `require_secure_transport=ON` | `Encrypt=yes` | `SQLNET.ENCRYPTION_CLIENT=REQUIRED` | N/A (local) |
| Least privilege roles | `NOLOGIN` group roles | Named roles (8.0+) | Custom DB roles | Custom roles | File permissions |
| No admin accounts in app | No `SUPERUSER` | No `root`/`SUPER` | No `sa`/`db_owner` | No `DBA`/`SYS` | N/A |
| Credentials in vault | env vars / vault | env vars / vault | Managed Identity / vault | Oracle Wallet / vault | File permissions |
| Audit logging | pgAudit / triggers | Audit plugin / triggers | SQL Server Audit | Unified Auditing | Application-level |
| Encryption at rest | pgcrypto / disk | InnoDB encryption | TDE / Always Encrypted | TDE | SQLCipher / disk |
| Row-level security | RLS policies | Views (workaround) | Security policies | VPD | Application-level |
