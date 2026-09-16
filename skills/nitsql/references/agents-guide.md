# nitsql - Complete Multi-Dialect Agent Guide

This is the compiled reference document for AI agents. Use this guide when analyzing, writing, or refactoring code that interacts with **MSSQL** (SQL Server 2019+, Azure SQL), **PostgreSQL** (13+), **Oracle** (19c+), or **MySQL** (8.0+).

---

## Quick Decision Tree

```
What dialect is this code?
├── Contains SET NOCOUNT ON, @@, sp_executesql, IDENTITY?        → MSSQL
├── Contains DO $$, ::cast, RETURNING, ILIKE, ~regex?            → PostgreSQL
├── Contains DBMS_, NVL, SYSDATE, :=, / terminator?             → Oracle
├── Contains DELIMITER, backticks, ENGINE=InnoDB, AUTO_INCREMENT? → MySQL
└── Unclear? → Check connection string or driver imports

Is this a database query? (applies to ALL dialects)
├── Uses SELECT *?                         → Apply query-avoid-select-star
├── String concatenation in SQL?           → Apply query-parameterize (CRITICAL)
├── Functions on columns in WHERE?         → Apply query-sargable
├── COUNT(*) > 0 for existence?            → Apply query-exists-vs-count
├── Cursor loop?                           → Apply query-avoid-cursors
├── Row-by-row INSERT/UPDATE/DELETE?       → Apply query-batch-operations
└── Missing LIMIT/TOP/FETCH/ROWNUM?        → Apply query-limit-results

Is this a stored procedure/function?
├── MSSQL: Missing SET NOCOUNT ON?         → Apply proc-set-nocount
├── MSSQL: Missing SET XACT_ABORT ON?      → Apply proc-xact-abort
├── Any dialect: No error handling?        → Apply proc-error-handling
├── Any dialect: Long transaction?         → Apply proc-transaction-scope
├── Any dialect: Unqualified object names? → Apply proc-schema-qualify
└── Any dialect: Dynamic SQL with concat?  → Apply query-parameterize

Is this application code?
├── New connection per request?            → Apply connection-pooling
├── No retry logic?                        → Apply connection-retry-logic
├── Admin/root/superuser permissions?      → Apply security-least-privilege
└── Missing async?                         → Apply connection-async

Is this database configuration?
├── MSSQL: Query Store disabled?           → Apply config-query-store
├── PostgreSQL: pg_stat_statements off?    → Enable extension
├── Oracle: AWR/ADDM not reviewed?         → Review diagnostic reports
├── MySQL: Performance Schema disabled?    → Enable performance_schema
└── Any dialect: Missing index analysis?   → Apply index-maintenance
```

---

## Category 1: Query Performance (CRITICAL) -- Universal

### query-avoid-select-star

**Never use `SELECT *` in production code. Applies to ALL dialects.**

Explicit columns enable covering indexes, reduce network I/O, prevent breakage when schema changes, and make intent clear.

**MSSQL:**

Bad:
```sql
SELECT * FROM dbo.Orders WHERE CustomerID = @CustomerID;
```

Good:
```sql
SELECT OrderID, OrderDate, TotalAmount, Status
FROM dbo.Orders
WHERE CustomerID = @CustomerID;
```

**PostgreSQL:**

Bad:
```sql
SELECT * FROM public.orders WHERE customer_id = p_customer_id;
```

Good:
```sql
SELECT order_id, order_date, total_amount, status
FROM public.orders
WHERE customer_id = p_customer_id;
```

**Oracle:**

Bad:
```sql
SELECT * FROM SALES.ORDERS WHERE CUSTOMER_ID = :customer_id;
```

Good:
```sql
SELECT ORDER_ID, ORDER_DATE, TOTAL_AMOUNT, STATUS
FROM SALES.ORDERS
WHERE CUSTOMER_ID = :customer_id;
```

**MySQL:**

Bad:
```sql
SELECT * FROM orders WHERE customer_id = ?;
```

Good:
```sql
SELECT order_id, order_date, total_amount, status
FROM orders
WHERE customer_id = ?;
```

**Exception:** `EXISTS` subqueries where only existence is checked (`SELECT 1` is preferred but `SELECT *` is functionally equivalent in EXISTS).

---

### query-parameterize

**CRITICAL: Always use parameterized queries. This is both a security AND performance issue. SQL injection is the #1 database vulnerability.**

#### Python per dialect

Bad (ALL dialects -- SQL injection vulnerable):
```python
query = f"SELECT * FROM users WHERE user_id = {user_id}"
cursor.execute(query)
```

Good -- MSSQL (pyodbc):
```python
cursor.execute("SELECT user_id, name, email FROM dbo.Users WHERE user_id = ?", (user_id,))
```

Good -- PostgreSQL (psycopg2):
```python
cursor.execute("SELECT user_id, name, email FROM public.users WHERE user_id = %s", (user_id,))
```

Good -- Oracle (oracledb):
```python
cursor.execute("SELECT USER_ID, NAME, EMAIL FROM APP.USERS WHERE USER_ID = :id", {"id": user_id})
```

Good -- MySQL (pymysql / mysql-connector-python):
```python
cursor.execute("SELECT user_id, name, email FROM users WHERE user_id = %s", (user_id,))
```

#### Node.js per dialect

Bad (ALL dialects):
```javascript
const result = await connection.query(`SELECT * FROM users WHERE id = ${userId}`);
```

Good -- MSSQL (mssql):
```javascript
const result = await pool.request()
    .input('id', sql.Int, userId)
    .query('SELECT user_id, name, email FROM dbo.Users WHERE user_id = @id');
```

Good -- PostgreSQL (pg):
```javascript
const result = await pool.query(
    'SELECT user_id, name, email FROM public.users WHERE user_id = $1',
    [userId]
);
```

Good -- Oracle (oracledb):
```javascript
const result = await conn.execute(
    'SELECT USER_ID, NAME, EMAIL FROM APP.USERS WHERE USER_ID = :id',
    [userId]
);
```

Good -- MySQL (mysql2):
```javascript
const [rows] = await conn.execute(
    'SELECT user_id, name, email FROM users WHERE user_id = ?',
    [userId]
);
```

#### C# per dialect

Bad (ALL dialects):
```csharp
var cmd = new SqlCommand($"SELECT * FROM Users WHERE UserId = {userId}", conn);
```

Good -- MSSQL (Microsoft.Data.SqlClient):
```csharp
using var cmd = new SqlCommand("SELECT UserId, Name, Email FROM dbo.Users WHERE UserId = @id", conn);
cmd.Parameters.AddWithValue("@id", userId);
```

Good -- PostgreSQL (Npgsql):
```csharp
using var cmd = new NpgsqlCommand("SELECT user_id, name, email FROM public.users WHERE user_id = @id", conn);
cmd.Parameters.AddWithValue("@id", userId);
```

Good -- Oracle (ODP.NET):
```csharp
using var cmd = new OracleCommand("SELECT USER_ID, NAME, EMAIL FROM APP.USERS WHERE USER_ID = :id", conn);
cmd.Parameters.Add(":id", OracleDbType.Int32, userId, ParameterDirection.Input);
```

Good -- MySQL (MySqlConnector):
```csharp
using var cmd = new MySqlCommand("SELECT user_id, name, email FROM users WHERE user_id = @id", conn);
cmd.Parameters.AddWithValue("@id", userId);
```

#### Native SQL (Dynamic SQL) per dialect

**MSSQL** -- use `sp_executesql`:

Bad:
```sql
SET @SQL = N'SELECT * FROM Orders WHERE CustomerName = ''' + @Name + ''''
EXEC(@SQL)
```

Good:
```sql
SET @SQL = N'SELECT OrderID, OrderDate FROM dbo.Orders WHERE CustomerName = @CustomerName'
EXEC sp_executesql @SQL, N'@CustomerName NVARCHAR(100)', @CustomerName = @Name
```

**PostgreSQL** -- use `EXECUTE ... USING` in PL/pgSQL:

Bad:
```sql
EXECUTE 'SELECT * FROM orders WHERE customer_name = ''' || p_name || '''';
```

Good:
```sql
EXECUTE format('SELECT order_id, order_date FROM public.orders WHERE customer_name = $1')
USING p_name;
```

**Oracle** -- use `EXECUTE IMMEDIATE ... USING`:

Bad:
```sql
EXECUTE IMMEDIATE 'SELECT * FROM ORDERS WHERE CUSTOMER_NAME = ''' || v_name || '''';
```

Good:
```sql
EXECUTE IMMEDIATE 'SELECT ORDER_ID, ORDER_DATE FROM SALES.ORDERS WHERE CUSTOMER_NAME = :1'
USING v_name;
```

**MySQL** -- use `PREPARE ... EXECUTE ... USING`:

Bad:
```sql
SET @sql = CONCAT('SELECT * FROM orders WHERE customer_name = ''', @name, '''');
PREPARE stmt FROM @sql;
EXECUTE stmt;
```

Good:
```sql
PREPARE stmt FROM 'SELECT order_id, order_date FROM orders WHERE customer_name = ?';
EXECUTE stmt USING @name;
DEALLOCATE PREPARE stmt;
```

---

### query-sargable

**Write SARGable (Search ARGument ABLE) predicates that can use indexes. Universal across all dialects.**

Bad (cannot use index -- applies to ALL dialects):
```sql
WHERE YEAR(order_date) = 2024
WHERE LEFT(customer_name, 3) = 'ABC'
WHERE price * 1.1 > 100
```

Good (uses index -- applies to ALL dialects):
```sql
WHERE order_date >= '2024-01-01' AND order_date < '2025-01-01'
WHERE customer_name LIKE 'ABC%'
WHERE price > 100 / 1.1
```

Dialect-specific null handling in WHERE:

Bad:
```sql
-- MSSQL
WHERE ISNULL(Status, 'pending') = 'pending'
-- PostgreSQL
WHERE COALESCE(status, 'pending') = 'pending'
-- Oracle
WHERE NVL(STATUS, 'pending') = 'pending'
-- MySQL
WHERE COALESCE(status, 'pending') = 'pending'
```

Good (all dialects):
```sql
WHERE (status = 'pending' OR status IS NULL)
```

---

### query-avoid-cursors

**Replace cursors with set-based operations. Cursors process rows one at a time; set-based operations process entire result sets at once.**

**MSSQL cursor (BAD):**
```sql
DECLARE order_cursor CURSOR FOR SELECT OrderID FROM dbo.Orders WHERE Processed = 0
OPEN order_cursor
FETCH NEXT FROM order_cursor INTO @OrderID
WHILE @@FETCH_STATUS = 0
BEGIN
    UPDATE dbo.Orders SET Processed = 1 WHERE OrderID = @OrderID
    FETCH NEXT FROM order_cursor INTO @OrderID
END
CLOSE order_cursor
DEALLOCATE order_cursor
```

**PostgreSQL cursor (BAD):**
```sql
DO $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN SELECT order_id FROM public.orders WHERE processed = false
    LOOP
        UPDATE public.orders SET processed = true WHERE order_id = rec.order_id;
    END LOOP;
END $$;
```

**Oracle cursor (BAD):**
```sql
DECLARE
    CURSOR c_orders IS SELECT ORDER_ID FROM SALES.ORDERS WHERE PROCESSED = 0;
    v_order_id SALES.ORDERS.ORDER_ID%TYPE;
BEGIN
    OPEN c_orders;
    LOOP
        FETCH c_orders INTO v_order_id;
        EXIT WHEN c_orders%NOTFOUND;
        UPDATE SALES.ORDERS SET PROCESSED = 1 WHERE ORDER_ID = v_order_id;
    END LOOP;
    CLOSE c_orders;
END;
/
```

**MySQL cursor (BAD):**
```sql
DELIMITER //
CREATE PROCEDURE process_orders()
BEGIN
    DECLARE v_order_id INT;
    DECLARE done INT DEFAULT FALSE;
    DECLARE cur CURSOR FOR SELECT order_id FROM orders WHERE processed = 0;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;
    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO v_order_id;
        IF done THEN LEAVE read_loop; END IF;
        UPDATE orders SET processed = 1 WHERE order_id = v_order_id;
    END LOOP;
    CLOSE cur;
END //
DELIMITER ;
```

**Set-based alternative (GOOD -- all dialects):**
```sql
-- Works in MSSQL, PostgreSQL, Oracle, and MySQL
UPDATE orders SET processed = 1 WHERE processed = 0;
```

---

### query-batch-operations

**Batch INSERT/UPDATE/DELETE operations instead of row-by-row loops.**

Bad (ALL dialects):
```python
for item in items:
    cursor.execute("INSERT INTO items (name, price) VALUES (?, ?)", (item.name, item.price))
```

**MSSQL -- table-valued parameters + executemany:**
```python
# executemany
cursor.fast_executemany = True
cursor.executemany(
    "INSERT INTO dbo.Items (Name, Price) VALUES (?, ?)",
    [(item.name, item.price) for item in items]
)
```

```sql
-- Table-valued parameter in T-SQL
CREATE TYPE dbo.ItemTableType AS TABLE (Name NVARCHAR(100), Price DECIMAL(10,2));
GO

CREATE PROCEDURE dbo.InsertItems @Items dbo.ItemTableType READONLY
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.Items (Name, Price)
    SELECT Name, Price FROM @Items;
END;
```

**PostgreSQL -- COPY or VALUES list:**
```python
# psycopg2 execute_values (fastest for bulk)
from psycopg2.extras import execute_values
execute_values(
    cursor,
    "INSERT INTO public.items (name, price) VALUES %s",
    [(item.name, item.price) for item in items]
)
```

```sql
-- Multi-row VALUES in SQL
INSERT INTO public.items (name, price)
VALUES ('Widget', 9.99), ('Gadget', 19.99), ('Doohickey', 4.99);
```

**Oracle -- executemany with bind arrays:**
```python
# oracledb executemany
cursor.executemany(
    "INSERT INTO APP.ITEMS (NAME, PRICE) VALUES (:1, :2)",
    [(item.name, item.price) for item in items]
)
```

```sql
-- FORALL in PL/SQL for bulk operations
FORALL i IN 1..v_names.COUNT
    INSERT INTO APP.ITEMS (NAME, PRICE) VALUES (v_names(i), v_prices(i));
```

**MySQL -- executemany or LOAD DATA:**
```python
# executemany
cursor.executemany(
    "INSERT INTO items (name, price) VALUES (%s, %s)",
    [(item.name, item.price) for item in items]
)
```

```sql
-- Multi-row INSERT
INSERT INTO items (name, price)
VALUES ('Widget', 9.99), ('Gadget', 19.99), ('Doohickey', 4.99);

-- LOAD DATA for very large datasets
LOAD DATA INFILE '/tmp/items.csv'
INTO TABLE items
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
(name, price);
```

---

### query-exists-vs-count

**Use EXISTS instead of COUNT(*) > 0 for existence checks. COUNT scans all matching rows; EXISTS stops at the first match. Universal across all dialects.**

Bad:
```sql
-- MSSQL
IF (SELECT COUNT(*) FROM dbo.Orders WHERE CustomerID = @CustomerID) > 0
    PRINT 'Has orders';

-- PostgreSQL
SELECT CASE WHEN COUNT(*) > 0 THEN true ELSE false END
FROM public.orders WHERE customer_id = p_customer_id;

-- Oracle
SELECT COUNT(*) INTO v_count FROM SALES.ORDERS WHERE CUSTOMER_ID = :customer_id;
IF v_count > 0 THEN ...

-- MySQL
SELECT COUNT(*) INTO @cnt FROM orders WHERE customer_id = ?;
IF @cnt > 0 THEN ...
```

Good:
```sql
-- MSSQL
IF EXISTS (SELECT 1 FROM dbo.Orders WHERE CustomerID = @CustomerID)
    PRINT 'Has orders';

-- PostgreSQL
SELECT EXISTS (SELECT 1 FROM public.orders WHERE customer_id = p_customer_id);

-- Oracle
BEGIN
    SELECT 1 INTO v_dummy FROM DUAL
    WHERE EXISTS (SELECT 1 FROM SALES.ORDERS WHERE CUSTOMER_ID = :customer_id);
EXCEPTION
    WHEN NO_DATA_FOUND THEN NULL;
END;

-- MySQL
SELECT EXISTS (SELECT 1 FROM orders WHERE customer_id = ?) AS has_orders;
```

---

### query-limit-results

**Always limit result sets for user-facing queries. Unbounded queries can exhaust memory and bandwidth.**

```sql
-- MSSQL (use TOP or OFFSET/FETCH)
SELECT TOP 50 OrderID, OrderDate FROM dbo.Orders ORDER BY OrderDate DESC;
-- or
SELECT OrderID, OrderDate FROM dbo.Orders
ORDER BY OrderDate DESC
OFFSET 0 ROWS FETCH NEXT 50 ROWS ONLY;

-- PostgreSQL (LIMIT/OFFSET)
SELECT order_id, order_date FROM public.orders
ORDER BY order_date DESC
LIMIT 50 OFFSET 0;

-- Oracle (FETCH FIRST or ROWNUM)
SELECT ORDER_ID, ORDER_DATE FROM SALES.ORDERS
ORDER BY ORDER_DATE DESC
FETCH FIRST 50 ROWS ONLY;   -- 12c+

-- MySQL (LIMIT)
SELECT order_id, order_date FROM orders
ORDER BY order_date DESC
LIMIT 50 OFFSET 0;
```

---

### query-union-all-vs-union

**Use `UNION ALL` instead of `UNION` when duplicate elimination is not required. `UNION` forces a sort/distinct operation across the entire result set.**

```sql
-- BAD (all dialects): UNION removes duplicates even when they can't exist
SELECT customer_id, order_date FROM active_orders WHERE status = 'open'
UNION
SELECT customer_id, order_date FROM archived_orders WHERE status = 'closed';

-- GOOD (all dialects): UNION ALL skips the expensive sort/distinct
SELECT customer_id, order_date FROM active_orders WHERE status = 'open'
UNION ALL
SELECT customer_id, order_date FROM archived_orders WHERE status = 'closed';
```

---

## Category 2: Indexing Strategy (CRITICAL)

### index-cover-queries

**Create covering indexes to eliminate key lookups / table access by index rowid.**

**MSSQL -- INCLUDE clause:**
```sql
-- Key columns in WHERE/JOIN, INCLUDEd columns in SELECT
CREATE INDEX IX_Orders_Customer_Covering
ON dbo.Orders (CustomerID)
INCLUDE (OrderDate, TotalAmount);
```

**PostgreSQL -- INCLUDE clause (v11+):**
```sql
CREATE INDEX ix_orders_customer_covering
ON public.orders (customer_id)
INCLUDE (order_date, total_amount);
```

**Oracle -- composite key (no INCLUDE support):**
```sql
-- All needed columns go in the key itself
CREATE INDEX IX_ORDERS_CUST_COVER
ON SALES.ORDERS (CUSTOMER_ID, ORDER_DATE, TOTAL_AMOUNT);
```

**MySQL -- composite key (InnoDB secondary indexes automatically include PK):**
```sql
-- InnoDB stores PK in all secondary indexes automatically.
-- For additional columns, use a composite key.
CREATE INDEX ix_orders_customer_covering
ON orders (customer_id, order_date, total_amount);
```

---

### index-maintenance

**Regularly check for missing and unused indexes.**

**MSSQL -- DMVs:**
```sql
-- Missing indexes (high-impact recommendations)
SELECT
    OBJECT_NAME(mid.object_id) AS TableName,
    mid.equality_columns,
    mid.inequality_columns,
    mid.included_columns,
    migs.avg_total_user_cost * migs.avg_user_impact * migs.user_seeks AS ImpactScore
FROM sys.dm_db_missing_index_details mid
JOIN sys.dm_db_missing_index_groups mig ON mid.index_handle = mig.index_handle
JOIN sys.dm_db_missing_index_group_stats migs ON mig.index_group_handle = migs.group_handle
ORDER BY ImpactScore DESC;

-- Unused indexes (candidates for removal)
SELECT OBJECT_NAME(i.object_id) AS TableName, i.name AS IndexName,
       ius.user_seeks, ius.user_scans, ius.user_lookups, ius.user_updates
FROM sys.dm_db_index_usage_stats ius
JOIN sys.indexes i ON ius.object_id = i.object_id AND ius.index_id = i.index_id
WHERE ius.user_seeks + ius.user_scans + ius.user_lookups = 0
  AND ius.user_updates > 0
  AND i.is_primary_key = 0 AND i.is_unique = 0
ORDER BY ius.user_updates DESC;
```

**PostgreSQL -- pg_stat catalogs:**
```sql
-- Missing indexes (tables with high sequential scans)
SELECT schemaname, relname AS table_name,
       seq_scan, seq_tup_read,
       idx_scan, n_live_tup
FROM pg_stat_user_tables
WHERE seq_scan > 100 AND n_live_tup > 10000
ORDER BY seq_tup_read DESC;

-- Unused indexes
SELECT schemaname, relname AS table_name, indexrelname AS index_name,
       idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE idx_scan = 0
ORDER BY pg_relation_size(indexrelid) DESC;
```

**Oracle -- V$ and DBA views:**
```sql
-- Tables with excessive full table scans (potential missing indexes)
SELECT sql_id, plan_hash_value, object_name, operation, options
FROM V$SQL_PLAN
WHERE operation = 'TABLE ACCESS' AND options = 'FULL'
  AND object_owner NOT IN ('SYS', 'SYSTEM');

-- Unused indexes (12c+ with index monitoring)
SELECT owner, index_name, table_name, monitoring, used
FROM DBA_OBJECT_USAGE
WHERE used = 'NO';
```

**MySQL -- performance_schema:**
```sql
-- Unused indexes
SELECT object_schema, object_name, index_name
FROM performance_schema.table_io_waits_summary_by_index_usage
WHERE index_name IS NOT NULL
  AND count_star = 0
  AND object_schema NOT IN ('mysql', 'performance_schema', 'sys');

-- Alternative via sys schema
SELECT * FROM sys.schema_unused_indexes
WHERE object_schema NOT IN ('mysql', 'performance_schema', 'sys');
```

---

## Category 3: Security & Compliance (HIGH)

### security-least-privilege

**Grant minimum required permissions. Never use admin roles for application accounts.**

**MSSQL:**

Bad:
```sql
ALTER ROLE db_owner ADD MEMBER AppUser;
```

Good:
```sql
CREATE ROLE AppServiceRole;
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::app TO AppServiceRole;
-- Grant EXECUTE on specific procedures, not all
GRANT EXECUTE ON dbo.ProcessOrder TO AppServiceRole;
ALTER ROLE AppServiceRole ADD MEMBER AppUser;
```

**PostgreSQL:**

Bad:
```sql
ALTER USER app_user WITH SUPERUSER;
-- or
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO app_user;
```

Good:
```sql
CREATE ROLE app_service_role;
GRANT USAGE ON SCHEMA app TO app_service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA app TO app_service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA app TO app_service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA app GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_service_role;
GRANT app_service_role TO app_user;
```

**Oracle:**

Bad:
```sql
GRANT DBA TO APP_USER;
```

Good:
```sql
CREATE ROLE APP_SERVICE_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON SALES.ORDERS TO APP_SERVICE_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON SALES.ORDER_ITEMS TO APP_SERVICE_ROLE;
GRANT EXECUTE ON SALES.PROCESS_ORDER TO APP_SERVICE_ROLE;
GRANT APP_SERVICE_ROLE TO APP_USER;
```

**MySQL:**

Bad:
```sql
GRANT ALL PRIVILEGES ON *.* TO 'app_user'@'%' WITH GRANT OPTION;
-- or
GRANT SUPER ON *.* TO 'app_user'@'%';
```

Good:
```sql
CREATE ROLE 'app_service_role';
GRANT SELECT, INSERT, UPDATE, DELETE ON mydb.* TO 'app_service_role';
GRANT EXECUTE ON PROCEDURE mydb.process_order TO 'app_service_role';
GRANT 'app_service_role' TO 'app_user'@'%';
SET DEFAULT ROLE 'app_service_role' TO 'app_user'@'%';
```

---

### security-encrypt-connections

**Always encrypt database connections in production.**

**MSSQL:**
```
Server=myserver.database.windows.net;Database=mydb;Encrypt=True;TrustServerCertificate=False;
```
For on-premises SQL Server 2019+, also ensure TLS 1.2+ is configured.

**PostgreSQL:**
```
host=myserver.example.com dbname=mydb sslmode=verify-full sslrootcert=/path/to/ca.pem
```
Use `sslmode=verify-full` to validate server certificate AND hostname. Never use `sslmode=disable` or `sslmode=allow` in production.

**Oracle:**
Configure in `tnsnames.ora` or `sqlnet.ora`:
```
mydb =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCPS)(HOST = myserver.example.com)(PORT = 2484))
    (CONNECT_DATA = (SERVICE_NAME = mydb))
    (SECURITY = (SSL_SERVER_CERT_DN = "CN=myserver.example.com"))
  )

-- In sqlnet.ora
WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = /path/to/wallet)))
SSL_VERSION = 1.2
```

**MySQL:**
```
mysql --host=myserver.example.com --ssl-mode=VERIFY_IDENTITY --ssl-ca=/path/to/ca.pem
```
Or in connection string:
```
host=myserver.example.com;SslMode=VerifyCA;SslCa=/path/to/ca.pem
```

---

## Category 4: Connection Management (HIGH)

### connection-pooling

**Always use connection pooling. Creating a new connection per request is expensive (TCP handshake, authentication, TLS negotiation).**

#### Python

**MSSQL (pyodbc + connection pooling is built-in, or use SQLAlchemy):**
```python
from sqlalchemy import create_engine
engine = create_engine(
    "mssql+pyodbc://user:pass@server/db?driver=ODBC+Driver+18+for+SQL+Server",
    pool_size=10, max_overflow=20, pool_recycle=3600
)
# Use engine.connect() or Session -- connections return to pool automatically
```

**PostgreSQL (psycopg2 pool or SQLAlchemy):**
```python
from psycopg2 import pool
connection_pool = pool.ThreadedConnectionPool(
    minconn=5, maxconn=20,
    host="server", dbname="mydb", user="app_user", password="pass",
    sslmode="verify-full", sslrootcert="/path/to/ca.pem"
)
conn = connection_pool.getconn()
try:
    # use conn
finally:
    connection_pool.putconn(conn)
```

**Oracle (oracledb pool):**
```python
import oracledb
pool = oracledb.create_pool(
    user="app_user", password="pass", dsn="server/mydb",
    min=5, max=20, increment=1
)
with pool.acquire() as conn:
    cursor = conn.cursor()
    cursor.execute("SELECT 1 FROM DUAL")
```

**MySQL (mysql-connector-python pool):**
```python
import mysql.connector.pooling
pool = mysql.connector.pooling.MySQLConnectionPool(
    pool_name="mypool", pool_size=10,
    host="server", database="mydb", user="app_user", password="pass",
    ssl_ca="/path/to/ca.pem"
)
conn = pool.get_connection()
try:
    cursor = conn.cursor()
    cursor.execute("SELECT 1")
finally:
    conn.close()  # Returns to pool
```

#### Node.js

**MSSQL (mssql):**
```javascript
const sql = require('mssql');
const poolPromise = new sql.ConnectionPool({
    server: 'myserver', database: 'mydb',
    user: 'app_user', password: 'pass',
    pool: { max: 10, min: 5, idleTimeoutMillis: 30000 },
    options: { encrypt: true, trustServerCertificate: false }
}).connect();

async function getUser(userId) {
    const pool = await poolPromise;
    const result = await pool.request()
        .input('userId', sql.Int, userId)
        .query('SELECT UserID, Name FROM dbo.Users WHERE UserID = @userId');
    return result.recordset[0];
}
```

**PostgreSQL (pg):**
```javascript
const { Pool } = require('pg');
const pool = new Pool({
    host: 'myserver', database: 'mydb',
    user: 'app_user', password: 'pass',
    max: 20, idleTimeoutMillis: 30000,
    ssl: { rejectUnauthorized: true, ca: fs.readFileSync('/path/to/ca.pem') }
});

async function getUser(userId) {
    const result = await pool.query(
        'SELECT user_id, name FROM public.users WHERE user_id = $1', [userId]
    );
    return result.rows[0];
}
```

**Oracle (oracledb):**
```javascript
const oracledb = require('oracledb');
await oracledb.createPool({
    user: 'app_user', password: 'pass',
    connectString: 'myserver/mydb',
    poolMin: 5, poolMax: 20, poolIncrement: 1
});

async function getUser(userId) {
    const conn = await oracledb.getConnection();
    try {
        const result = await conn.execute(
            'SELECT USER_ID, NAME FROM APP.USERS WHERE USER_ID = :id', [userId]
        );
        return result.rows[0];
    } finally {
        await conn.close();  // Returns to pool
    }
}
```

**MySQL (mysql2):**
```javascript
const mysql = require('mysql2/promise');
const pool = mysql.createPool({
    host: 'myserver', database: 'mydb',
    user: 'app_user', password: 'pass',
    waitForConnections: true, connectionLimit: 10,
    ssl: { ca: fs.readFileSync('/path/to/ca.pem') }
});

async function getUser(userId) {
    const [rows] = await pool.execute(
        'SELECT user_id, name FROM users WHERE user_id = ?', [userId]
    );
    return rows[0];
}
```

#### C#

**MSSQL (Microsoft.Data.SqlClient):**
```csharp
// Connection pooling is automatic via connection string.
// Same connection string = same pool.
var connStr = "Server=myserver;Database=mydb;User=app_user;Password=pass;Encrypt=True;Max Pool Size=100;";
using var conn = new SqlConnection(connStr);
await conn.OpenAsync();
```

**PostgreSQL (Npgsql):**
```csharp
var connStr = "Host=myserver;Database=mydb;Username=app_user;Password=pass;SSL Mode=VerifyFull;Maximum Pool Size=100;";
using var conn = new NpgsqlConnection(connStr);
await conn.OpenAsync();
```

**Oracle (ODP.NET):**
```csharp
var connStr = "Data Source=myserver/mydb;User Id=app_user;Password=pass;Min Pool Size=5;Max Pool Size=100;";
using var conn = new OracleConnection(connStr);
await conn.OpenAsync();
```

**MySQL (MySqlConnector):**
```csharp
var connStr = "Server=myserver;Database=mydb;User=app_user;Password=pass;SslMode=VerifyCA;Maximum Pool Size=100;";
using var conn = new MySqlConnection(connStr);
await conn.OpenAsync();
```

---

### connection-retry-logic

**Implement retry with exponential backoff for transient failures.**

**Transient error codes by dialect:**

| Dialect | Common Transient Errors |
|---------|------------------------|
| **MSSQL** | 4060 (db not available), 40197 (service error), 40501 (service busy), 40613 (db unavailable), 49918/49919/49920 (resource limit), 1204 (lock resources), 1205 (deadlock), -2 (timeout), 11001 (network) |
| **PostgreSQL** | `08000`-`08006` (connection exceptions), `40001` (serialization failure), `40P01` (deadlock), `57P01` (admin shutdown), `53300` (too many connections) |
| **Oracle** | ORA-00060 (deadlock), ORA-03113/03114 (end-of-file/not connected), ORA-12170 (connect timeout), ORA-12541 (no listener), ORA-01033 (startup/shutdown in progress) |
| **MySQL** | 1040 (too many connections), 1205 (lock wait timeout), 1213 (deadlock), 2003 (can't connect), 2006 (server gone away), 2013 (lost connection) |

**Python retry pattern (universal):**
```python
import time
import random

def execute_with_retry(func, max_retries=3, base_delay=1.0):
    for attempt in range(max_retries + 1):
        try:
            return func()
        except Exception as e:
            if attempt == max_retries or not is_transient(e):
                raise
            delay = base_delay * (2 ** attempt) + random.uniform(0, 0.5)
            time.sleep(delay)
```

**C# -- MSSQL built-in retry (Microsoft.Data.SqlClient):**
```csharp
var options = new SqlRetryLogicOption()
{
    NumberOfTries = 3,
    DeltaTime = TimeSpan.FromSeconds(1),
    MaxTimeInterval = TimeSpan.FromSeconds(20),
    TransientErrors = new[] { 4060, 40197, 40501, 40613, 49918, 49919, 49920, 1204, 1205, -2 }
};
connection.RetryLogicProvider = SqlConfigurableRetryFactory.CreateExponentialRetryProvider(options);
```

**C# -- PostgreSQL (Npgsql with Polly):**
```csharp
services.AddNpgsqlDataSource("Host=myserver;Database=mydb;...",
    builder => builder.UsePeriodicPasswordProvider(async (_, ct) => await GetPassword(ct), TimeSpan.FromMinutes(5)));
// Or use Polly for retry
var retryPolicy = Policy
    .Handle<NpgsqlException>(ex => ex.IsTransient)
    .WaitAndRetryAsync(3, attempt => TimeSpan.FromSeconds(Math.Pow(2, attempt)));
```

---

## Category 5: Procedural Code Patterns (MEDIUM-HIGH)

### proc-set-nocount (MSSQL only)

**Always use SET NOCOUNT ON in MSSQL stored procedures.** Without it, SQL Server sends "N rows affected" messages after every statement, adding network overhead and confusing some ORMs/drivers.

```sql
CREATE PROCEDURE dbo.ProcessOrder
    @OrderID INT
AS
BEGIN
    SET NOCOUNT ON;
    -- Procedure logic here
END;
```

This has no equivalent in PostgreSQL, Oracle, or MySQL because they do not send row-count messages by default.

---

### proc-error-handling

**Every stored procedure/function that modifies data MUST have error handling.**

**MSSQL -- TRY...CATCH + THROW:**
```sql
CREATE PROCEDURE Sales.ProcessPayment
    @OrderID INT,
    @Amount DECIMAL(10,2)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE Sales.Orders SET PaymentStatus = 'Paid' WHERE OrderID = @OrderID;
        INSERT INTO Sales.PaymentLog (OrderID, Amount, PaidDate)
        VALUES (@OrderID, @Amount, SYSUTCDATETIME());

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;  -- Re-raises the original error
    END CATCH
END;
```

**PostgreSQL -- EXCEPTION WHEN...THEN + RAISE:**
```sql
CREATE OR REPLACE FUNCTION sales.process_payment(
    p_order_id INT,
    p_amount NUMERIC(10,2)
) RETURNS VOID AS $$
BEGIN
    UPDATE sales.orders SET payment_status = 'paid' WHERE order_id = p_order_id;
    INSERT INTO sales.payment_log (order_id, amount, paid_date)
    VALUES (p_order_id, p_amount, NOW());
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Payment failed for order %: %', p_order_id, SQLERRM;
        RAISE;  -- Re-raise the exception (auto-rollback occurs)
END;
$$ LANGUAGE plpgsql;
```

Note: In PostgreSQL, a function body with EXCEPTION is implicitly wrapped in a subtransaction. If the exception fires, all changes in the block are rolled back automatically.

**Oracle -- EXCEPTION WHEN...THEN + RAISE_APPLICATION_ERROR:**
```sql
CREATE OR REPLACE PROCEDURE SALES.PROCESS_PAYMENT(
    P_ORDER_ID IN NUMBER,
    P_AMOUNT   IN NUMBER
) AS
BEGIN
    UPDATE SALES.ORDERS SET PAYMENT_STATUS = 'Paid' WHERE ORDER_ID = P_ORDER_ID;
    INSERT INTO SALES.PAYMENT_LOG (ORDER_ID, AMOUNT, PAID_DATE)
    VALUES (P_ORDER_ID, P_AMOUNT, SYSTIMESTAMP);

    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE_APPLICATION_ERROR(-20001, 'Payment failed for order ' || P_ORDER_ID || ': ' || SQLERRM);
END;
/
```

**MySQL -- DECLARE HANDLER + SIGNAL:**
```sql
DELIMITER //
CREATE PROCEDURE process_payment(
    IN p_order_id INT,
    IN p_amount DECIMAL(10,2)
)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;  -- Re-raise the error
    END;

    START TRANSACTION;

    UPDATE orders SET payment_status = 'paid' WHERE order_id = p_order_id;
    INSERT INTO payment_log (order_id, amount, paid_date)
    VALUES (p_order_id, p_amount, NOW());

    COMMIT;
END //
DELIMITER ;
```

---

### proc-transaction-handling

**Handle transactions correctly per dialect. Pay attention to auto-commit gotchas.**

**MSSQL -- SET XACT_ABORT ON + TRY/CATCH:**
```sql
CREATE PROCEDURE Sales.TransferFunds
    @FromAccountID INT, @ToAccountID INT, @Amount DECIMAL(10,2)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;  -- Guarantees rollback on ANY runtime error or timeout

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE Accounts.Balances SET Balance = Balance - @Amount WHERE AccountID = @FromAccountID;
        UPDATE Accounts.Balances SET Balance = Balance + @Amount WHERE AccountID = @ToAccountID;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
```

**PostgreSQL -- function vs procedure:**
```sql
-- FUNCTION: body is one implicit transaction (auto-commit at end).
-- Use EXCEPTION block for subtransaction/rollback.
CREATE OR REPLACE FUNCTION app.transfer_funds(
    p_from INT, p_to INT, p_amount NUMERIC
) RETURNS VOID AS $$
BEGIN
    UPDATE app.balances SET balance = balance - p_amount WHERE account_id = p_from;
    UPDATE app.balances SET balance = balance + p_amount WHERE account_id = p_to;
    -- Commits automatically when function returns successfully
EXCEPTION
    WHEN OTHERS THEN
        RAISE;  -- Changes rolled back automatically
END;
$$ LANGUAGE plpgsql;

-- PROCEDURE (PG 11+): can manage transactions explicitly.
CREATE OR REPLACE PROCEDURE app.transfer_funds_proc(
    p_from INT, p_to INT, p_amount NUMERIC
) LANGUAGE plpgsql AS $$
BEGIN
    UPDATE app.balances SET balance = balance - p_amount WHERE account_id = p_from;
    UPDATE app.balances SET balance = balance + p_amount WHERE account_id = p_to;
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE;
END;
$$;
```

**Oracle -- implicit begin, explicit COMMIT/ROLLBACK:**

GOTCHA: DDL statements (CREATE, ALTER, DROP, TRUNCATE) issue an implicit COMMIT before and after execution. Never mix DDL with DML in a transaction that needs rollback capability.

```sql
CREATE OR REPLACE PROCEDURE HR.TRANSFER_FUNDS(
    P_FROM IN NUMBER, P_TO IN NUMBER, P_AMOUNT IN NUMBER
) AS
BEGIN
    SAVEPOINT before_transfer;

    UPDATE HR.BALANCES SET BALANCE = BALANCE - P_AMOUNT WHERE ACCOUNT_ID = P_FROM;
    UPDATE HR.BALANCES SET BALANCE = BALANCE + P_AMOUNT WHERE ACCOUNT_ID = P_TO;

    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK TO before_transfer;
        RAISE_APPLICATION_ERROR(-20001, 'Transfer failed: ' || SQLERRM);
END;
/
```

**MySQL -- START TRANSACTION, explicit COMMIT/ROLLBACK:**

GOTCHA: DDL statements (CREATE, ALTER, DROP, TRUNCATE) cause an implicit COMMIT. Never mix DDL with DML in a transaction that needs rollback capability. Same as Oracle.

```sql
DELIMITER //
CREATE PROCEDURE transfer_funds(
    IN p_from INT, IN p_to INT, IN p_amount DECIMAL(10,2)
)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
    UPDATE balances SET balance = balance - p_amount WHERE account_id = p_from;
    UPDATE balances SET balance = balance + p_amount WHERE account_id = p_to;
    COMMIT;
END //
DELIMITER ;
```

---

### proc-schema-qualify

**Always schema-qualify object names. Unqualified names can resolve differently for different users/contexts.**

**MSSQL** -- default schema is `dbo`:
```sql
-- BAD
SELECT * FROM Orders;
EXEC UpdateStatus;

-- GOOD
SELECT OrderID, OrderDate FROM Sales.Orders;
EXEC Sales.UpdateStatus;
```

**PostgreSQL** -- default schema is `public`, controlled by `search_path`:
```sql
-- BAD (depends on search_path)
SELECT * FROM orders;
SELECT app.get_order(1);  -- this one is actually qualified

-- GOOD
SELECT order_id, order_date FROM app.orders;
SELECT * FROM app.get_order(1);
```

**Oracle** -- objects default to current user's schema:
```sql
-- BAD
SELECT * FROM ORDERS;
EXEC UPDATE_STATUS;

-- GOOD
SELECT ORDER_ID, ORDER_DATE FROM SALES.ORDERS;
EXEC SALES.UPDATE_STATUS;
```

**MySQL** -- objects default to current database:
```sql
-- BAD (depends on USE database)
SELECT * FROM orders;

-- GOOD (explicit database reference, especially in cross-database queries)
SELECT order_id, order_date FROM myapp.orders;
```

---

### proc-explicit-insert-columns

**Always list column names in INSERT statements. `INSERT INTO Table VALUES (...)` breaks silently when columns are added or reordered. Universal across all dialects.**

Bad:
```sql
INSERT INTO orders VALUES (1001, 'Shipped', GETDATE(), 'System');
```

Good:
```sql
-- MSSQL
INSERT INTO Sales.OrderHistory (OrderID, Status, ChangedDate, ChangedBy)
VALUES (1001, 'Shipped', SYSUTCDATETIME(), 'System');

-- PostgreSQL
INSERT INTO app.order_history (order_id, status, changed_date, changed_by)
VALUES (1001, 'shipped', NOW(), 'system');

-- Oracle
INSERT INTO SALES.ORDER_HISTORY (ORDER_ID, STATUS, CHANGED_DATE, CHANGED_BY)
VALUES (1001, 'Shipped', SYSTIMESTAMP, 'System');

-- MySQL
INSERT INTO order_history (order_id, status, changed_date, changed_by)
VALUES (1001, 'shipped', NOW(), 'system');
```

---

## Category 6: Static Analysis (MEDIUM-HIGH)

Universal static analysis rules. These apply across all dialects unless noted.

### Design Issues

| Rule | Check | MSSQL | PostgreSQL | Oracle | MySQL |
|------|-------|-------|------------|--------|-------|
| **SA0001** | `SELECT *` in queries | List explicit columns | Same | Same | Same |
| **SA0008** | Identity/sequence misuse | Use `SCOPE_IDENTITY()` not `@@IDENTITY` | Use `RETURNING id` or `currval()` | Use `RETURNING INTO` or `.CURRVAL` | Use `LAST_INSERT_ID()` not `@@IDENTITY` |
| **SA0009** | Oversized fixed-width types | `VARCHAR(1)` -> `CHAR(1)` | `VARCHAR(1)` -> `CHAR(1)` | `VARCHAR2(1)` -> `CHAR(1)` | `VARCHAR(1)` -> `CHAR(1)` |
| **SA0010** | Deprecated join syntax | No `*=` / `=*` -- use ANSI JOIN | N/A (never supported) | No `(+)` -- use ANSI JOIN | N/A (never supported) |
| **SA0013** | OUTPUT param not set in all paths | Add ELSE branch or initialize | Return all OUT params | Initialize OUT params | Set all OUT params |
| **SA0014** | Implicit type conversion | Use explicit `CAST`/`CONVERT` | Use explicit `::type` cast | Use explicit `TO_NUMBER`/`TO_CHAR` | Use explicit `CAST()` |

### Performance Issues

| Rule | Check | Applies To |
|------|-------|-----------|
| **SA0004** | Non-indexed columns in `IN` predicates | All dialects |
| **SA0005** | `LIKE '%value'` leading wildcard -- cannot use index | All dialects |
| **SA0006** | Column arithmetic in WHERE (`col / x > y`) | All dialects -- rewrite as `col > y * x` |
| **SA0007** | Nullable column without null handling | MSSQL: `ISNULL()`, PG/MySQL: `COALESCE()`, Oracle: `NVL()` |
| **SA0015** | Non-deterministic function per-row in WHERE | MSSQL: `GETDATE()`, PG: `NOW()` (stable in txn, but be aware), Oracle: `SYSDATE`, MySQL: `NOW()` -- extract to variable |

### Naming Issues

| Rule | Check | Applies To |
|------|-------|-----------|
| **SA0011** | Special characters in object names | All dialects -- use letters, numbers, underscores only |
| **SA0012** | Reserved words as identifiers | All dialects -- each has different reserved words; avoid all of them |
| **SA0016** | `sp_` prefix on procedures (MSSQL) | MSSQL only -- `sp_` causes master DB lookup first. Use `usp_` or no prefix |

### Dialect-Specific Gotchas

| Dialect | Gotcha | Impact |
|---------|--------|--------|
| **MSSQL** | `@@IDENTITY` vs `SCOPE_IDENTITY()` | `@@IDENTITY` returns last identity from ANY scope (triggers included). Always use `SCOPE_IDENTITY()`. |
| **PostgreSQL** | Function vs Procedure (PG 11+) | Functions cannot manage transactions (implicit commit at end). Procedures can `COMMIT`/`ROLLBACK`. |
| **Oracle** | DDL auto-commits | `CREATE TABLE`, `ALTER`, `DROP`, `TRUNCATE` issue implicit COMMIT before AND after. Cannot roll back DDL. |
| **MySQL** | DDL auto-commits | Same as Oracle -- DDL causes implicit COMMIT. |
| **MySQL** | `AUTO_INCREMENT` gaps | AUTO_INCREMENT can have gaps after rollbacks. Do not rely on contiguity. |
| **Oracle** | `DUAL` table required | `SELECT 1` fails. Use `SELECT 1 FROM DUAL`. |
| **PostgreSQL** | Case sensitivity | Unquoted identifiers fold to lowercase. `CREATE TABLE MyTable` creates `mytable`. Use `"MyTable"` to preserve case (but avoid this). |
| **MSSQL** | `WITH (NOLOCK)` reads dirty data | Reads uncommitted rows, phantom rows, and can return duplicate or missing data. Use `READ_COMMITTED_SNAPSHOT` isolation instead. |
| **MSSQL** | `SET XACT_ABORT` default is OFF | Without `SET XACT_ABORT ON`, some errors (timeouts, linked server) leave transactions open, holding locks indefinitely. |
| **Oracle** | `WHEN OTHERS THEN NULL` | Silently swallows all exceptions. Always log and re-raise: `RAISE_APPLICATION_ERROR(-20001, SQLERRM)`. |
| **Oracle** | `CURSOR_SHARING = FORCE` | Never set globally — causes unexpected plan changes. Use bind variables in application code instead. |
| **PostgreSQL** | `CREATE INDEX` locks writes | Use `CREATE INDEX CONCURRENTLY` in production to avoid blocking INSERT/UPDATE/DELETE during index build. |
| **MySQL** | `utf8` is NOT true UTF-8 | MySQL's `utf8` charset is 3-byte max (cannot store emoji). Always use `utf8mb4` for true UTF-8 support. |
| **MySQL** | `FLOAT`/`DOUBLE` imprecision | Never use for currency. `DECIMAL(19,4)` is the correct type for financial data in all dialects. |

---

## Category 7: Database Configuration (MEDIUM)

### MSSQL Configuration

```sql
-- Query Store (enable and configure)
ALTER DATABASE [YourDatabase] SET QUERY_STORE = ON;
ALTER DATABASE [YourDatabase] SET QUERY_STORE (
    OPERATION_MODE = READ_WRITE,
    MAX_STORAGE_SIZE_MB = 1000,
    QUERY_CAPTURE_MODE = AUTO,
    SIZE_BASED_CLEANUP_MODE = AUTO
);

-- Compatibility level (unlock IQP features)
-- 150 = SQL Server 2019 IQP (batch mode on rowstore, table variable deferred compilation, scalar UDF inlining)
-- 160 = SQL Server 2022 IQP (parameter sensitive plan optimization, DOP feedback, CE feedback)
ALTER DATABASE [YourDatabase] SET COMPATIBILITY_LEVEL = 150;

-- MAXDOP (match CPU count, Azure SQL defaults to cores/2)
ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 8;

-- Accelerated Database Recovery (instant rollback, aggressive log truncation)
ALTER DATABASE [YourDatabase] SET ACCELERATED_DATABASE_RECOVERY = ON;

-- tempdb: Multiple data files = number of cores (up to 8), equal initial size
-- Configured via SQL Server setup or ALTER DATABASE tempdb

-- Auto-tuning
ALTER DATABASE [YourDatabase] SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = ON);
```

### PostgreSQL Configuration

Key `postgresql.conf` settings:
```ini
# Memory
shared_buffers = '4GB'          # 25% of RAM as starting point
work_mem = '256MB'              # Per-operation sort/hash memory
effective_cache_size = '12GB'   # 75% of RAM (hint to planner, not allocation)
maintenance_work_mem = '1GB'    # For VACUUM, CREATE INDEX, ALTER TABLE

# WAL
wal_level = 'replica'           # Or 'logical' if using logical replication
max_wal_size = '4GB'

# Query stats
shared_preload_libraries = 'pg_stat_statements'

# Autovacuum (tune for write-heavy workloads)
autovacuum_max_workers = 5
autovacuum_vacuum_cost_limit = 2000
autovacuum_naptime = '30s'
```

```sql
-- Enable pg_stat_statements
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Find slow queries
SELECT query, calls, mean_exec_time, total_exec_time
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 20;
```

### Oracle Configuration

```sql
-- Check SGA/PGA sizing
SELECT name, value FROM V$SGA;
SELECT * FROM V$PGASTAT WHERE name LIKE '%target%';

-- Gather optimizer statistics (critical for good plans)
EXEC DBMS_STATS.GATHER_SCHEMA_STATS('SALES', cascade => TRUE);

-- Enable AWR (Automatic Workload Repository) -- requires Diagnostics Pack license
-- AWR is enabled by default; review reports:
SELECT * FROM DBA_HIST_SNAPSHOT ORDER BY SNAP_ID DESC FETCH FIRST 10 ROWS ONLY;

-- SQL Plan Baselines (prevent plan regressions)
DECLARE
    v_plans PLS_INTEGER;
BEGIN
    v_plans := DBMS_SPM.LOAD_PLANS_FROM_CURSOR_CACHE(sql_id => 'abc123def');
END;
/

-- Check for plan regressions
SELECT SQL_HANDLE, PLAN_NAME, ENABLED, ACCEPTED, FIXED
FROM DBA_SQL_PLAN_BASELINES
WHERE ACCEPTED = 'YES';
```

### MySQL Configuration

Key `my.cnf` / `my.ini` settings:
```ini
[mysqld]
# InnoDB buffer pool (60-80% of RAM for dedicated DB server)
innodb_buffer_pool_size = 8G
innodb_buffer_pool_instances = 8

# Redo log
innodb_log_file_size = 1G
innodb_log_buffer_size = 64M

# Slow query log
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 1

# Performance Schema (enabled by default in 8.0)
performance_schema = ON
```

```sql
-- Check buffer pool hit ratio (should be > 99%)
SHOW STATUS LIKE 'Innodb_buffer_pool_read%';

-- Find slow queries via Performance Schema
SELECT DIGEST_TEXT, COUNT_STAR, AVG_TIMER_WAIT/1000000000 AS avg_ms
FROM performance_schema.events_statements_summary_by_digest
ORDER BY AVG_TIMER_WAIT DESC
LIMIT 20;

-- Check InnoDB status
SHOW ENGINE INNODB STATUS;
```

---

## Category 8: Data Types & Naming (MEDIUM)

### type-appropriate-size

Use the smallest data type that fits. Oversized types waste storage, memory, and cache.

| Purpose | MSSQL | PostgreSQL | Oracle | MySQL |
|---------|-------|------------|--------|-------|
| Small integer (0-255) | `TINYINT` | `SMALLINT` (no TINYINT) | `NUMBER(3)` | `TINYINT UNSIGNED` |
| Boolean | `BIT` | `BOOLEAN` | `NUMBER(1)` or `CHAR(1)` | `BOOLEAN` (alias for TINYINT(1)) |
| UUID/GUID | `UNIQUEIDENTIFIER` | `UUID` | `RAW(16)` | `BINARY(16)` or `CHAR(36)` |
| Date only | `DATE` | `DATE` | `DATE` (includes time in Oracle!) | `DATE` |
| Timestamp | `DATETIME2` | `TIMESTAMPTZ` | `TIMESTAMP WITH TIME ZONE` | `DATETIME(6)` or `TIMESTAMP(6)` |
| Variable text | `NVARCHAR(n)` / `VARCHAR(n)` | `TEXT` or `VARCHAR(n)` | `VARCHAR2(n)` | `VARCHAR(n)` |
| Large text | `NVARCHAR(MAX)` | `TEXT` | `CLOB` | `LONGTEXT` |
| Money | `DECIMAL(19,4)` | `NUMERIC(19,4)` | `NUMBER(19,4)` | `DECIMAL(19,4)` |

**Deprecated types to avoid:**

| Dialect | Deprecated | Replacement |
|---------|-----------|-------------|
| MSSQL | `TEXT`, `NTEXT`, `IMAGE` | `VARCHAR(MAX)`, `NVARCHAR(MAX)`, `VARBINARY(MAX)` |
| Oracle | `LONG`, `LONG RAW` | `CLOB`, `BLOB` |
| MySQL | `FLOAT`/`DOUBLE` for money | `DECIMAL(p,s)` |

### naming-conventions

| Convention | MSSQL | PostgreSQL | Oracle | MySQL |
|-----------|-------|------------|--------|-------|
| Table names | PascalCase: `Orders` | snake_case: `orders` | UPPER_CASE: `ORDERS` | snake_case: `orders` |
| Column names | PascalCase: `OrderDate` | snake_case: `order_date` | UPPER_CASE: `ORDER_DATE` | snake_case: `order_date` |
| Procedures | PascalCase: `ProcessOrder` | snake_case: `process_order` | UPPER_CASE: `PROCESS_ORDER` | snake_case: `process_order` |
| Indexes | `IX_Table_Column` | `ix_table_column` | `IX_TABLE_COLUMN` | `ix_table_column` |
| Primary keys | `PK_Table` | `table_pkey` (default) | `PK_TABLE` | `PRIMARY` (auto) |
| Foreign keys | `FK_Child_Parent` | `child_parent_fkey` | `FK_CHILD_PARENT` | `fk_child_parent` |
| Schemas | `Sales`, `HR` | `sales`, `hr` | `SALES`, `HR` | N/A (databases) |

---

## Category 9: Data Modeling (MEDIUM)

### model-temporal-tables

**System-versioned temporal tables for automatic history tracking.**

**MSSQL (SQL Server 2016+):**
```sql
CREATE TABLE dbo.Employees (
    EmployeeID INT PRIMARY KEY,
    Name NVARCHAR(100),
    Salary DECIMAL(18,2),
    ValidFrom DATETIME2 GENERATED ALWAYS AS ROW START,
    ValidTo DATETIME2 GENERATED ALWAYS AS ROW END,
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.EmployeesHistory));

-- Query as of a point in time
SELECT * FROM dbo.Employees FOR SYSTEM_TIME AS OF '2024-06-01';
```

**PostgreSQL (no native temporal; use triggers or temporal_tables extension):**
```sql
-- Manual approach with triggers
CREATE TABLE app.employees (
    employee_id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    salary NUMERIC(18,2),
    valid_from TIMESTAMPTZ DEFAULT NOW(),
    valid_to TIMESTAMPTZ DEFAULT 'infinity'
);

CREATE TABLE app.employees_history (LIKE app.employees);

-- Create trigger to copy old row to history on UPDATE/DELETE
CREATE OR REPLACE FUNCTION app.employees_history_trigger()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO app.employees_history VALUES (OLD.*);
    NEW.valid_from := NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_employees_history
BEFORE UPDATE ON app.employees
FOR EACH ROW EXECUTE FUNCTION app.employees_history_trigger();
```

**Oracle (Flashback Data Archive -- Total Recall):**
```sql
-- Create flashback data archive
CREATE FLASHBACK ARCHIVE fda_1year TABLESPACE users RETENTION 1 YEAR;

-- Enable on table
ALTER TABLE HR.EMPLOYEES FLASHBACK ARCHIVE fda_1year;

-- Query as of a point in time
SELECT * FROM HR.EMPLOYEES AS OF TIMESTAMP TO_TIMESTAMP('2024-06-01', 'YYYY-MM-DD');
```

**MySQL (no native temporal; use triggers or application-level versioning):**
```sql
-- Manual approach: audit table + triggers
CREATE TABLE employees (
    employee_id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100),
    salary DECIMAL(18,2)
) ENGINE=InnoDB;

CREATE TABLE employees_history (
    history_id INT AUTO_INCREMENT PRIMARY KEY,
    employee_id INT,
    name VARCHAR(100),
    salary DECIMAL(18,2),
    changed_at DATETIME DEFAULT NOW(),
    change_type ENUM('INSERT', 'UPDATE', 'DELETE')
) ENGINE=InnoDB;

-- Trigger example
DELIMITER //
CREATE TRIGGER trg_employees_after_update
AFTER UPDATE ON employees
FOR EACH ROW
BEGIN
    INSERT INTO employees_history (employee_id, name, salary, change_type)
    VALUES (OLD.employee_id, OLD.name, OLD.salary, 'UPDATE');
END //
DELIMITER ;
```

---

## Category 10: Monitoring & Diagnostics (LOW-MEDIUM)

### MSSQL Monitoring

```sql
-- Extended Events for slow queries (replaces deprecated SQL Profiler)
CREATE EVENT SESSION [SlowQueries] ON SERVER
ADD EVENT sqlserver.sql_statement_completed (
    ACTION (sqlserver.sql_text, sqlserver.database_name)
    WHERE duration > 1000000  -- > 1 second (microseconds)
)
ADD TARGET package0.event_file (SET filename = N'SlowQueries.xel')
WITH (MAX_DISPATCH_LATENCY = 5 SECONDS);
ALTER EVENT SESSION [SlowQueries] ON SERVER STATE = START;

-- Wait statistics (top performance bottleneck indicator)
SELECT TOP 10 wait_type, wait_time_ms / 1000.0 AS wait_time_sec,
       waiting_tasks_count,
       wait_time_ms * 100.0 / SUM(wait_time_ms) OVER() AS pct
FROM sys.dm_os_wait_stats
WHERE wait_type NOT LIKE 'SLEEP%' AND wait_type NOT LIKE 'BROKER%'
  AND wait_type NOT LIKE 'XE%' AND wait_type != 'WAITFOR'
ORDER BY wait_time_ms DESC;

-- Active queries with execution plans
SELECT r.session_id, r.status, r.command, r.wait_type,
       t.text AS query_text, p.query_plan
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) p
WHERE r.session_id > 50;
```

### PostgreSQL Monitoring

```sql
-- pg_stat_statements for query performance
SELECT query, calls, mean_exec_time::NUMERIC(10,2) AS avg_ms,
       total_exec_time::NUMERIC(10,2) AS total_ms, rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;

-- Active queries
SELECT pid, now() - pg_stat_activity.query_start AS duration,
       query, state, wait_event_type, wait_event
FROM pg_stat_activity
WHERE state != 'idle'
  AND pid <> pg_backend_pid()
ORDER BY duration DESC;

-- Table bloat (dead tuples needing VACUUM)
SELECT schemaname, relname, n_dead_tup, n_live_tup,
       ROUND(n_dead_tup::NUMERIC / NULLIF(n_live_tup, 0) * 100, 2) AS dead_pct,
       last_autovacuum
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC;

-- Lock waits
SELECT blocked.pid AS blocked_pid, blocked.query AS blocked_query,
       blocking.pid AS blocking_pid, blocking.query AS blocking_query
FROM pg_stat_activity blocked
JOIN pg_locks bl ON bl.pid = blocked.pid AND NOT bl.granted
JOIN pg_locks gl ON gl.locktype = bl.locktype AND gl.relation = bl.relation AND gl.granted
JOIN pg_stat_activity blocking ON blocking.pid = gl.pid
WHERE blocked.pid <> blocking.pid;
```

### Oracle Monitoring

```sql
-- Top SQL by elapsed time (requires AWR / Diagnostics Pack)
SELECT sql_id, elapsed_time / 1000000 AS elapsed_sec, executions,
       elapsed_time / NULLIF(executions, 0) / 1000000 AS avg_sec,
       sql_text
FROM V$SQL
ORDER BY elapsed_time DESC
FETCH FIRST 20 ROWS ONLY;

-- Active sessions
SELECT sid, serial#, username, status, sql_id, event, wait_class,
       last_call_et AS seconds_in_state
FROM V$SESSION
WHERE type = 'USER' AND status = 'ACTIVE';

-- Blocking sessions
SELECT s1.sid AS blocked_sid, s1.username AS blocked_user,
       s2.sid AS blocking_sid, s2.username AS blocking_user,
       s1.event AS wait_event
FROM V$SESSION s1
JOIN V$SESSION s2 ON s1.blocking_session = s2.sid
WHERE s1.blocking_session IS NOT NULL;

-- Tablespace usage
SELECT tablespace_name,
       ROUND(used_space * 8192 / 1024 / 1024) AS used_mb,
       ROUND(tablespace_size * 8192 / 1024 / 1024) AS total_mb,
       ROUND(used_percent, 1) AS used_pct
FROM DBA_TABLESPACE_USAGE_METRICS
ORDER BY used_percent DESC;
```

### MySQL Monitoring

```sql
-- Slow query digest via Performance Schema
SELECT DIGEST_TEXT, COUNT_STAR AS calls,
       ROUND(AVG_TIMER_WAIT / 1000000000, 2) AS avg_ms,
       ROUND(SUM_TIMER_WAIT / 1000000000, 2) AS total_ms,
       SUM_ROWS_EXAMINED, SUM_ROWS_SENT
FROM performance_schema.events_statements_summary_by_digest
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 20;

-- Active queries
SELECT id, user, host, db, command, time AS seconds, state, info AS query
FROM information_schema.PROCESSLIST
WHERE command != 'Sleep'
ORDER BY time DESC;

-- InnoDB lock waits
SELECT
    r.trx_id AS waiting_trx_id, r.trx_mysql_thread_id AS waiting_pid,
    r.trx_query AS waiting_query,
    b.trx_id AS blocking_trx_id, b.trx_mysql_thread_id AS blocking_pid,
    b.trx_query AS blocking_query
FROM performance_schema.data_lock_waits w
JOIN information_schema.innodb_trx r ON r.trx_id = w.REQUESTING_ENGINE_TRANSACTION_ID
JOIN information_schema.innodb_trx b ON b.trx_id = w.BLOCKING_ENGINE_TRANSACTION_ID;

-- Table I/O statistics
SELECT object_schema, object_name,
       count_read, count_write, count_fetch,
       ROUND(sum_timer_wait / 1000000000, 2) AS total_wait_ms
FROM performance_schema.table_io_waits_summary_by_table
WHERE object_schema NOT IN ('mysql', 'performance_schema', 'sys')
ORDER BY sum_timer_wait DESC
LIMIT 20;
```

---

## Detection Queries

### Find procedures/functions without error handling

**MSSQL:**
```sql
SELECT SCHEMA_NAME(p.schema_id) + '.' + p.name AS ProcedureName
FROM sys.procedures p
JOIN sys.sql_modules m ON p.object_id = m.object_id
WHERE m.definition NOT LIKE '%TRY%'
  AND m.definition NOT LIKE '%CATCH%';
```

**PostgreSQL:**
```sql
SELECT routine_schema || '.' || routine_name AS function_name
FROM information_schema.routines
WHERE routine_type = 'FUNCTION'
  AND specific_schema NOT IN ('pg_catalog', 'information_schema')
  AND routine_definition NOT LIKE '%EXCEPTION%';
```

**Oracle:**
```sql
SELECT owner || '.' || name AS object_name, type
FROM DBA_SOURCE
WHERE type IN ('PROCEDURE', 'FUNCTION')
  AND owner NOT IN ('SYS', 'SYSTEM')
GROUP BY owner, name, type
HAVING SUM(CASE WHEN UPPER(text) LIKE '%EXCEPTION%' THEN 1 ELSE 0 END) = 0;
```

**MySQL:**
```sql
SELECT routine_schema, routine_name, routine_type
FROM information_schema.routines
WHERE routine_schema NOT IN ('mysql', 'sys', 'performance_schema', 'information_schema')
  AND routine_definition NOT LIKE '%HANDLER%';
```

### Find non-parameterized / high-plan-count queries

**MSSQL (Query Store):**
```sql
SELECT qt.query_sql_text, COUNT(DISTINCT p.plan_id) AS PlanCount
FROM sys.query_store_query q
JOIN sys.query_store_query_text qt ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_plan p ON q.query_id = p.query_id
GROUP BY q.query_id, qt.query_sql_text
HAVING COUNT(DISTINCT p.plan_id) > 3
ORDER BY PlanCount DESC;
```

**PostgreSQL (pg_stat_statements):**
```sql
-- Queries with many calls but no parameter placeholders (potential non-parameterized)
SELECT query, calls, mean_exec_time
FROM pg_stat_statements
WHERE query NOT LIKE '%$1%'
  AND calls > 100
ORDER BY calls DESC
LIMIT 20;
```

**Oracle:**
```sql
-- Queries with many child cursors (sign of non-parameterized SQL)
SELECT sql_id, COUNT(*) AS child_count, MIN(sql_text) AS sql_text
FROM V$SQL
GROUP BY sql_id
HAVING COUNT(*) > 5
ORDER BY child_count DESC;
```

**MySQL:**
```sql
-- Queries with no parameter placeholders and high frequency
SELECT DIGEST_TEXT, COUNT_STAR AS calls, SCHEMA_NAME
FROM performance_schema.events_statements_summary_by_digest
WHERE DIGEST_TEXT NOT LIKE '%?%'
  AND COUNT_STAR > 100
ORDER BY COUNT_STAR DESC
LIMIT 20;
```

### Find procedures without SET NOCOUNT ON (MSSQL only)

```sql
SELECT SCHEMA_NAME(p.schema_id) + '.' + p.name AS ProcedureName
FROM sys.procedures p
JOIN sys.sql_modules m ON p.object_id = m.object_id
WHERE m.definition NOT LIKE '%SET NOCOUNT ON%';
```

### Find queries with key lookups / full scans

**MSSQL:**
```sql
SELECT OBJECT_NAME(i.object_id) AS TableName, i.name AS IndexName,
       ius.user_lookups AS KeyLookups
FROM sys.dm_db_index_usage_stats ius
JOIN sys.indexes i ON ius.object_id = i.object_id AND ius.index_id = i.index_id
WHERE ius.user_lookups > 1000
ORDER BY ius.user_lookups DESC;
```

**PostgreSQL:**
```sql
SELECT schemaname, relname AS table_name,
       seq_scan, seq_tup_read, idx_scan,
       CASE WHEN seq_scan > 0 THEN seq_tup_read / seq_scan ELSE 0 END AS avg_rows_per_seq_scan
FROM pg_stat_user_tables
WHERE seq_scan > 100
ORDER BY seq_tup_read DESC;
```

**Oracle:**
```sql
SELECT sql_id, object_name, operation, options, cardinality
FROM V$SQL_PLAN
WHERE operation = 'TABLE ACCESS' AND options = 'FULL'
  AND object_owner NOT IN ('SYS', 'SYSTEM')
ORDER BY cardinality DESC NULLS LAST;
```

**MySQL:**
```sql
SELECT object_schema, object_name, index_name,
       count_read, count_fetch
FROM performance_schema.table_io_waits_summary_by_index_usage
WHERE index_name IS NULL  -- NULL = full table scan
  AND object_schema NOT IN ('mysql', 'performance_schema', 'sys')
ORDER BY count_fetch DESC;
```

---

## Code Review Checklist

### CRITICAL (all dialects)
- [ ] No `SELECT *` in production code (SA0001)
- [ ] All queries parameterized -- no string concatenation in SQL (SA0002)
- [ ] SARGable predicates -- no functions on columns in WHERE
- [ ] No cursors where set-based operations work
- [ ] Batch INSERT/UPDATE/DELETE operations (no row-by-row loops from app code)
- [ ] No implicit type conversions in JOINs or WHERE clauses
- [ ] Existence checks use EXISTS, not COUNT(*) > 0
- [ ] Result sets are bounded (TOP/LIMIT/FETCH FIRST)

### HIGH (all dialects)
- [ ] Connection pooling implemented
- [ ] Retry logic for transient failures with exponential backoff
- [ ] Encrypted connections (TLS/SSL) in all environments
- [ ] Least-privilege database permissions (no admin roles for applications)
- [ ] Appropriate indexes for frequent queries
- [ ] No hardcoded credentials in source code

### MEDIUM-HIGH (all dialects)
- [ ] Error handling in all stored procedures/functions
- [ ] Schema-qualified object names
- [ ] Explicit column lists in INSERT statements
- [ ] Async/await for database calls in application code
- [ ] No dynamic SQL with string concatenation
- [ ] Transactions kept as short as possible

### MSSQL-Specific
- [ ] `SET NOCOUNT ON` in all stored procedures
- [ ] `SET XACT_ABORT ON` in procedures with transactions
- [ ] `SCOPE_IDENTITY()` instead of `@@IDENTITY`
- [ ] Query Store enabled and configured
- [ ] Compatibility level set to 150+ (unlock IQP features)
- [ ] ADR enabled for long-running transaction scenarios
- [ ] No deprecated types (`TEXT`, `NTEXT`, `IMAGE`)
- [ ] No `WITH (NOLOCK)` hints except for known-safe reporting queries (dirty reads risk)
- [ ] No `sp_` prefix on stored procedures (causes master DB lookup)

### PostgreSQL-Specific
- [ ] `pg_stat_statements` extension enabled
- [ ] `autovacuum` properly tuned for write-heavy tables
- [ ] Functions use `SECURITY DEFINER` only when necessary (and with `SET search_path`)
- [ ] `RETURNING` used instead of separate SELECT after INSERT/UPDATE
- [ ] Connection uses `sslmode=verify-full` in production
- [ ] `CREATE INDEX CONCURRENTLY` used for production index builds (avoids write lock)
- [ ] `search_path` explicitly set in functions to prevent schema hijacking
- [ ] `GENERATED ALWAYS AS IDENTITY` preferred over `SERIAL` for new tables

### Oracle-Specific
- [ ] Optimizer statistics gathered regularly (`DBMS_STATS`)
- [ ] No DDL mixed with DML in transactions (DDL auto-commits)
- [ ] Bind variables used in all application SQL (avoid library cache bloat)
- [ ] `NVL` / `NVL2` / `COALESCE` used for null handling (not bare expressions)
- [ ] PL/SQL uses `FORALL` for bulk DML instead of row-by-row loops
- [ ] `CURSOR_SHARING = EXACT` (default) — never set to `FORCE` except as a temporary measure for non-parameterized legacy apps
- [ ] No `WHEN OTHERS THEN NULL` — never silently swallow exceptions
- [ ] `VARCHAR2` used instead of `VARCHAR` (they differ subtly in Oracle)

### MySQL-Specific
- [ ] InnoDB engine used for all tables (not MyISAM)
- [ ] `innodb_buffer_pool_size` properly sized (70-80% of RAM for dedicated servers)
- [ ] No DDL mixed with DML in transactions (DDL auto-commits)
- [ ] `utf8mb4` character set used (not `utf8` which is only 3-byte and cannot store emojis/CJK supplementary)
- [ ] `sql_mode` includes `STRICT_TRANS_TABLES` (prevents silent data truncation)
- [ ] `EXPLAIN ANALYZE` used to verify query plans (8.0.18+)
- [ ] `DELIMITER` used correctly in stored procedure definitions
- [ ] `DECIMAL` used for currency/financial columns (never `FLOAT`/`DOUBLE`)
- [ ] Foreign keys defined for referential integrity (InnoDB supports them; MyISAM does not)
