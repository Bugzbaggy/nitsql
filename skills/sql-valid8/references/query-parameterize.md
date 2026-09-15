# query-parameterize
**Priority:** CRITICAL
**Category:** Security
**Applies to:** MSSQL, PostgreSQL, Oracle, MySQL

## Why It Matters

SQL injection is the most exploited database vulnerability (OWASP Top 10 #3). String-concatenated queries let attackers read, modify, or delete any data, escalate privileges, or execute OS commands. Parameterized queries also enable plan caching: without them, each unique literal produces a separate compiled plan, bloating the plan cache and wasting CPU.

## Incorrect Code

### MSSQL
```sql
-- Bad: dynamic SQL with string concatenation in a stored procedure
CREATE PROCEDURE dbo.GetCustomerOrders
    @CustomerName NVARCHAR(100)
AS
BEGIN
    DECLARE @SQL NVARCHAR(MAX);
    SET @SQL = N'SELECT * FROM dbo.Orders WHERE CustomerName = '''
             + @CustomerName + N'''';
    EXEC(@SQL);  -- injectable
END;
```

### PostgreSQL
```sql
-- Bad: string concatenation in PL/pgSQL
CREATE OR REPLACE FUNCTION get_customer_orders(p_name TEXT)
RETURNS SETOF orders AS $$
BEGIN
    RETURN QUERY EXECUTE
        'SELECT * FROM public.orders WHERE customer_name = '''
        || p_name || '''';  -- injectable
END;
$$ LANGUAGE plpgsql;
```

### Oracle
```sql
-- Bad: string concatenation in PL/SQL
CREATE OR REPLACE PROCEDURE get_customer_orders(p_name IN VARCHAR2) AS
    v_sql VARCHAR2(4000);
    v_cur SYS_REFCURSOR;
BEGIN
    v_sql := 'SELECT * FROM app.orders WHERE customer_name = '''
             || p_name || '''';
    OPEN v_cur FOR v_sql;  -- injectable
END;
/
```

### MySQL
```sql
-- Bad: CONCAT in a prepared statement
CREATE PROCEDURE get_customer_orders(IN p_name VARCHAR(100))
BEGIN
    SET @sql = CONCAT('SELECT * FROM orders WHERE customer_name = ''',
                      p_name, '''');
    PREPARE stmt FROM @sql;  -- injectable
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
END;
```

## Correct Code

### MSSQL
```sql
-- Good: sp_executesql with typed parameters
CREATE PROCEDURE dbo.SearchProducts
    @SearchTerm NVARCHAR(100),
    @CategoryID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SQL   NVARCHAR(MAX);
    DECLARE @Params NVARCHAR(500);

    SET @SQL = N'SELECT ProductID, ProductName, Price
                 FROM dbo.Products
                 WHERE ProductName LIKE @Pattern';

    IF @CategoryID IS NOT NULL
        SET @SQL += N' AND CategoryID = @CatID';

    SET @Params = N'@Pattern NVARCHAR(100), @CatID INT';

    EXEC sp_executesql @SQL, @Params,
        @Pattern = @SearchTerm,
        @CatID   = @CategoryID;
END;
```

### PostgreSQL
```sql
-- Good: EXECUTE ... USING with typed placeholders
CREATE OR REPLACE FUNCTION search_products(
    p_term TEXT,
    p_category_id INT DEFAULT NULL
) RETURNS SETOF products AS $$
DECLARE
    v_sql TEXT;
BEGIN
    v_sql := 'SELECT * FROM public.products WHERE name LIKE $1';
    IF p_category_id IS NOT NULL THEN
        v_sql := v_sql || ' AND category_id = $2';
    END IF;
    RETURN QUERY EXECUTE v_sql USING p_term, p_category_id;
END;
$$ LANGUAGE plpgsql;
```

### Oracle
```sql
-- Good: EXECUTE IMMEDIATE ... USING with bind variables
CREATE OR REPLACE PROCEDURE search_products(
    p_term     IN VARCHAR2,
    p_category IN NUMBER DEFAULT NULL,
    p_cur      OUT SYS_REFCURSOR
) AS
    v_sql VARCHAR2(4000);
BEGIN
    v_sql := 'SELECT product_id, name, price
              FROM app.products
              WHERE name LIKE :term';
    IF p_category IS NOT NULL THEN
        v_sql := v_sql || ' AND category_id = :cat';
        OPEN p_cur FOR v_sql USING p_term, p_category;
    ELSE
        OPEN p_cur FOR v_sql USING p_term;
    END IF;
END;
/
```

### MySQL
```sql
-- Good: PREPARE / EXECUTE with user-defined variables
CREATE PROCEDURE search_products(
    IN p_term VARCHAR(100),
    IN p_category INT
)
BEGIN
    SET @sql = 'SELECT product_id, name, price
                FROM products
                WHERE name LIKE ?';
    SET @term = p_term;

    IF p_category IS NOT NULL THEN
        SET @sql = CONCAT(@sql, ' AND category_id = ?');
        SET @cat = p_category;
        PREPARE stmt FROM @sql;
        EXECUTE stmt USING @term, @cat;
    ELSE
        PREPARE stmt FROM @sql;
        EXECUTE stmt USING @term;
    END IF;

    DEALLOCATE PREPARE stmt;
END;
```

## Application Code Detection

### Python

```python
# --- MSSQL (pyodbc) ---
# Bad
cursor.execute(f"SELECT * FROM dbo.Users WHERE UserID = {user_id}")
# Good  (? placeholder)
cursor.execute("SELECT UserID, Name FROM dbo.Users WHERE UserID = ?", (user_id,))

# --- PostgreSQL (psycopg2) ---
# Bad
cur.execute(f"SELECT * FROM users WHERE user_id = {user_id}")
# Good  (%s placeholder)
cur.execute("SELECT user_id, name FROM public.users WHERE user_id = %s", (user_id,))

# --- PostgreSQL (asyncpg) ---
# Good  ($1 placeholder)
row = await conn.fetchrow("SELECT user_id, name FROM public.users WHERE user_id = $1", user_id)

# --- Oracle (oracledb) ---
# Bad
cur.execute(f"SELECT * FROM users WHERE user_id = {user_id}")
# Good  (:named placeholder)
cur.execute("SELECT user_id, name FROM app.users WHERE user_id = :id", {"id": user_id})

# --- MySQL (pymysql / mysql-connector-python) ---
# Bad
cursor.execute(f"SELECT * FROM users WHERE user_id = {user_id}")
# Good  (%s placeholder)
cursor.execute("SELECT user_id, name FROM users WHERE user_id = %s", (user_id,))
```

### Node.js

```javascript
// --- MSSQL (mssql) ---
// Bad
await pool.request().query(`SELECT * FROM dbo.Users WHERE UserID = ${userId}`);
// Good
await pool.request()
    .input('userId', sql.Int, userId)
    .query('SELECT UserID, Name FROM dbo.Users WHERE UserID = @userId');

// --- PostgreSQL (pg) ---
// Bad
await client.query(`SELECT * FROM users WHERE user_id = ${userId}`);
// Good  ($1 placeholder)
await client.query('SELECT user_id, name FROM public.users WHERE user_id = $1', [userId]);

// --- Oracle (oracledb) ---
// Bad
await conn.execute(`SELECT * FROM users WHERE user_id = ${userId}`);
// Good  (:named placeholder)
await conn.execute('SELECT user_id, name FROM app.users WHERE user_id = :id', { id: userId });

// --- MySQL (mysql2) ---
// Bad
await conn.execute(`SELECT * FROM users WHERE user_id = ${userId}`);
// Good  (? placeholder)
await conn.execute('SELECT user_id, name FROM users WHERE user_id = ?', [userId]);
```

### C#

```csharp
// --- MSSQL (Microsoft.Data.SqlClient) ---
// Bad
cmd.CommandText = $"SELECT * FROM dbo.Users WHERE UserID = {userId}";
// Good
cmd.CommandText = "SELECT UserID, Name FROM dbo.Users WHERE UserID = @id";
cmd.Parameters.Add("@id", SqlDbType.Int).Value = userId;

// --- PostgreSQL (Npgsql) ---
// Bad
cmd.CommandText = $"SELECT * FROM users WHERE user_id = {userId}";
// Good
cmd.CommandText = "SELECT user_id, name FROM public.users WHERE user_id = @id";
cmd.Parameters.AddWithValue("@id", userId);

// --- Oracle (Oracle.ManagedDataAccess.Core) ---
// Bad
cmd.CommandText = $"SELECT * FROM users WHERE user_id = {userId}";
// Good
cmd.CommandText = "SELECT user_id, name FROM app.users WHERE user_id = :id";
cmd.Parameters.Add(":id", OracleDbType.Int32).Value = userId;

// --- MySQL (MySqlConnector) ---
// Bad
cmd.CommandText = $"SELECT * FROM users WHERE user_id = {userId}";
// Good
cmd.CommandText = "SELECT user_id, name FROM users WHERE user_id = @id";
cmd.Parameters.AddWithValue("@id", userId);
```

## Exceptions

- **Truly static SQL** with no user input (e.g., `SELECT COUNT(*) FROM sys.objects`) does not need parameterization, but parameterizing it costs nothing and keeps the pattern consistent.
- **DDL statements** (`CREATE TABLE`, `ALTER INDEX`) cannot be parameterized in most dialects; validate inputs rigorously and use allowlists.
- **Dynamic column or table names** cannot be parameterized. Use allowlists:
  ```python
  ALLOWED_COLUMNS = {"name", "email", "status"}
  if col not in ALLOWED_COLUMNS:
      raise ValueError("Invalid column")
  ```

## How to Detect

### MSSQL
```sql
-- Queries with embedded literals that should be parameterized (Query Store)
SELECT TOP 20
    q.query_id,
    qt.query_sql_text,
    COUNT(DISTINCT p.plan_id) AS plan_count,
    SUM(rs.count_executions) AS total_executions
FROM sys.query_store_query q
JOIN sys.query_store_query_text qt ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_plan p ON q.query_id = p.query_id
JOIN sys.query_store_runtime_stats rs ON p.plan_id = rs.plan_id
GROUP BY q.query_id, qt.query_sql_text
HAVING COUNT(DISTINCT p.plan_id) > 3   -- many plans = likely non-parameterized
ORDER BY total_executions DESC;
```

### PostgreSQL
```sql
-- Queries with many distinct plans (pg_stat_statements)
SELECT query, calls, mean_exec_time, rows
FROM pg_stat_statements
WHERE query LIKE '%WHERE%=%'
ORDER BY calls DESC
LIMIT 20;
```

### Oracle
```sql
-- Identify literal SQL in the shared pool
SELECT sql_text, executions, version_count
FROM v$sqlarea
WHERE version_count > 5
ORDER BY version_count DESC
FETCH FIRST 20 ROWS ONLY;
```

### MySQL
```sql
-- Queries with high count but no prepared-statement digest
SELECT DIGEST_TEXT, COUNT_STAR, AVG_TIMER_WAIT / 1000000000 AS avg_ms
FROM performance_schema.events_statements_summary_by_digest
WHERE DIGEST_TEXT LIKE '%WHERE%=%'
ORDER BY COUNT_STAR DESC
LIMIT 20;
```

## Performance Impact

Parameterized queries are not just a security measure — they have measurable performance benefits:

| Metric | Non-parameterized | Parameterized |
|--------|------------------|---------------|
| **Plan cache efficiency** | One plan per unique literal value (cache bloat) | One plan reused for all values |
| **CPU for compilation** | Hard parse every execution (Oracle) / plan compilation every execution | Soft parse / plan reuse |
| **Memory** | Thousands of duplicate plans in cache | Single plan in cache |
| **MSSQL** | Query Store records thousands of similar queries | Single query_id tracks all executions |
| **Oracle** | Library cache fills → ORA-04031 (shared pool exhaustion) | Minimal library cache usage |
| **PostgreSQL** | `pg_stat_statements` shows generic plan stats per parameterized query | Same |
| **MySQL** | Prepared statement protocol reduces parsing overhead by ~20% | Same |

## ORM-Specific Guidance

Most ORMs parameterize automatically, but watch for these patterns that bypass it:
- **Raw SQL with string interpolation**: `Model.objects.raw(f"SELECT ... WHERE id = {id}")` — always use `Model.objects.raw("SELECT ... WHERE id = %s", [id])`
- **Entity Framework `FromSqlRaw`**: use `FromSqlInterpolated` or pass parameters explicitly
- **SQLAlchemy `text()`**: always use `text("... WHERE id = :id").bindparams(id=value)`
- **Sequelize `literal()`**: avoid; use parameter binding instead
