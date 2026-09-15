# query-avoid-select-star
**Priority:** CRITICAL
**Category:** Performance
**Applies to:** MSSQL, PostgreSQL, Oracle, MySQL

## Why It Matters

`SELECT *` forces the engine to read every column from disk, bloats network packets, and prevents covering-index-only scans. When a table gains or drops columns, application code that relies on ordinal positions breaks silently. On high-throughput systems this translates directly to higher CPU, memory, and I/O costs.

## Incorrect Code

### MSSQL
```sql
-- Bad: returns all columns from a schema-qualified table
SELECT *
FROM dbo.Orders
WHERE CustomerID = @CustomerID;

-- Bad: SELECT * inside a CTE
WITH RecentOrders AS (
    SELECT *
    FROM dbo.Orders
    WHERE OrderDate > DATEADD(DAY, -30, GETDATE())
)
SELECT * FROM RecentOrders;
```

### PostgreSQL
```sql
-- Bad: returns all columns
SELECT *
FROM public.orders
WHERE customer_id = $1;

-- Bad: SELECT * inside a CTE
WITH recent_orders AS (
    SELECT *
    FROM public.orders
    WHERE order_date > CURRENT_DATE - INTERVAL '30 days'
)
SELECT * FROM recent_orders;
```

### Oracle
```sql
-- Bad: returns all columns
SELECT *
FROM app_schema.orders
WHERE customer_id = :customer_id;

-- Bad: SELECT * inside an inline view
SELECT *
FROM (
    SELECT *
    FROM app_schema.orders
    WHERE order_date > SYSDATE - 30
);
```

### MySQL
```sql
-- Bad: returns all columns
SELECT *
FROM orders
WHERE customer_id = ?;

-- Bad: SELECT * inside a derived table
SELECT *
FROM (
    SELECT *
    FROM orders
    WHERE order_date > DATE_SUB(CURDATE(), INTERVAL 30 DAY)
) AS recent_orders;
```

## Correct Code

### MSSQL
```sql
-- Good: explicit column list, schema-qualified
SELECT OrderID, OrderDate, TotalAmount, Status
FROM dbo.Orders
WHERE CustomerID = @CustomerID;

WITH RecentOrders AS (
    SELECT OrderID, CustomerID, OrderDate, TotalAmount
    FROM dbo.Orders
    WHERE OrderDate > DATEADD(DAY, -30, GETDATE())
)
SELECT OrderID, OrderDate, TotalAmount
FROM RecentOrders;
```

### PostgreSQL
```sql
-- Good: explicit column list, schema-qualified
SELECT order_id, order_date, total_amount, status
FROM public.orders
WHERE customer_id = $1;

WITH recent_orders AS (
    SELECT order_id, customer_id, order_date, total_amount
    FROM public.orders
    WHERE order_date > CURRENT_DATE - INTERVAL '30 days'
)
SELECT order_id, order_date, total_amount
FROM recent_orders;
```

### Oracle
```sql
-- Good: explicit column list, schema-qualified
SELECT order_id, order_date, total_amount, status
FROM app_schema.orders
WHERE customer_id = :customer_id;

SELECT order_id, order_date, total_amount
FROM (
    SELECT order_id, customer_id, order_date, total_amount
    FROM app_schema.orders
    WHERE order_date > SYSDATE - 30
);
```

### MySQL
```sql
-- Good: explicit column list
SELECT order_id, order_date, total_amount, status
FROM orders
WHERE customer_id = ?;

SELECT order_id, order_date, total_amount
FROM (
    SELECT order_id, customer_id, order_date, total_amount
    FROM orders
    WHERE order_date > DATE_SUB(CURDATE(), INTERVAL 30 DAY)
) AS recent_orders;
```

## Application Code Detection

### Python

```python
# --- MSSQL (pyodbc) ---
# Bad
cursor.execute("SELECT * FROM dbo.Users WHERE UserID = ?", user_id)
# Good
cursor.execute("SELECT UserID, Name, Email FROM dbo.Users WHERE UserID = ?", user_id)

# --- PostgreSQL (psycopg2) ---
# Bad
cur.execute("SELECT * FROM public.users WHERE user_id = %s", (user_id,))
# Good
cur.execute("SELECT user_id, name, email FROM public.users WHERE user_id = %s", (user_id,))

# --- Oracle (oracledb) ---
# Bad
cur.execute("SELECT * FROM app_schema.users WHERE user_id = :id", {"id": user_id})
# Good
cur.execute("SELECT user_id, name, email FROM app_schema.users WHERE user_id = :id", {"id": user_id})

# --- MySQL (pymysql / mysql-connector) ---
# Bad
cursor.execute("SELECT * FROM users WHERE user_id = %s", (user_id,))
# Good
cursor.execute("SELECT user_id, name, email FROM users WHERE user_id = %s", (user_id,))
```

### Node.js

```javascript
// --- MSSQL (mssql) ---
// Bad
await pool.request().query('SELECT * FROM dbo.Users');
// Good
await pool.request().query('SELECT UserID, Name, Email FROM dbo.Users');

// --- PostgreSQL (pg) ---
// Bad
await client.query('SELECT * FROM public.users WHERE user_id = $1', [userId]);
// Good
await client.query('SELECT user_id, name, email FROM public.users WHERE user_id = $1', [userId]);

// --- Oracle (oracledb) ---
// Bad
await connection.execute('SELECT * FROM app_schema.users WHERE user_id = :id', [userId]);
// Good
await connection.execute('SELECT user_id, name, email FROM app_schema.users WHERE user_id = :id', [userId]);

// --- MySQL (mysql2) ---
// Bad
await connection.execute('SELECT * FROM users WHERE user_id = ?', [userId]);
// Good
await connection.execute('SELECT user_id, name, email FROM users WHERE user_id = ?', [userId]);
```

### C#

```csharp
// --- MSSQL (Microsoft.Data.SqlClient) ---
// Bad
command.CommandText = "SELECT * FROM dbo.Users WHERE UserID = @id";
// Good
command.CommandText = "SELECT UserID, Name, Email FROM dbo.Users WHERE UserID = @id";

// --- PostgreSQL (Npgsql) ---
// Bad
cmd.CommandText = "SELECT * FROM public.users WHERE user_id = @id";
// Good
cmd.CommandText = "SELECT user_id, name, email FROM public.users WHERE user_id = @id";

// --- Oracle (Oracle.ManagedDataAccess) ---
// Bad
cmd.CommandText = "SELECT * FROM app_schema.users WHERE user_id = :id";
// Good
cmd.CommandText = "SELECT user_id, name, email FROM app_schema.users WHERE user_id = :id";

// --- MySQL (MySqlConnector) ---
// Bad
cmd.CommandText = "SELECT * FROM users WHERE user_id = @id";
// Good
cmd.CommandText = "SELECT user_id, name, email FROM users WHERE user_id = @id";
```

## Exceptions

- **EXISTS subqueries** -- the column list is ignored; `SELECT *` is acceptable:
  ```sql
  -- All dialects: OK inside EXISTS
  WHERE EXISTS (SELECT * FROM orders WHERE customer_id = c.customer_id)
  ```
- **CREATE TABLE AS SELECT (CTAS)** or **INSERT INTO ... SELECT** when you intentionally need all columns.
- **COUNT(*)** -- the optimizer resolves this to the narrowest available index; no columns are actually read.
- **Ad-hoc exploration** during development (never in production code or stored procedures).

## How to Detect

### MSSQL
```sql
SELECT
    OBJECT_SCHEMA_NAME(object_id) + '.' + OBJECT_NAME(object_id) AS ProcedureName,
    OBJECT_DEFINITION(object_id) AS Definition
FROM sys.procedures
WHERE OBJECT_DEFINITION(object_id) LIKE '%SELECT[^a-z]%*[^/]%FROM%'
  AND OBJECT_DEFINITION(object_id) NOT LIKE '%EXISTS%(%SELECT%*%'
ORDER BY ProcedureName;
```

### PostgreSQL
```sql
SELECT n.nspname || '.' || p.proname AS func_name,
       pg_get_functiondef(p.oid) AS definition
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND pg_get_functiondef(p.oid) LIKE '%SELECT%*%FROM%'
  AND pg_get_functiondef(p.oid) NOT LIKE '%EXISTS%(%SELECT%*%'
ORDER BY func_name;
```

### Oracle
```sql
SELECT owner || '.' || name AS object_name, text
FROM all_source
WHERE type IN ('PROCEDURE', 'FUNCTION', 'PACKAGE BODY')
  AND UPPER(text) LIKE '%SELECT%*%FROM%'
  AND UPPER(text) NOT LIKE '%EXISTS%(%SELECT%*%'
ORDER BY owner, name, line;
```

### MySQL
```sql
SELECT ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_DEFINITION
FROM information_schema.ROUTINES
WHERE ROUTINE_DEFINITION LIKE '%SELECT%*%FROM%'
  AND ROUTINE_DEFINITION NOT LIKE '%EXISTS%(%SELECT%*%'
  AND ROUTINE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
ORDER BY ROUTINE_SCHEMA, ROUTINE_NAME;
```
