# proc-schema-qualify
**Priority:** HIGH
**Category:** Procedural
**Applies to:** MSSQL, PostgreSQL, Oracle, MySQL

## Why It Matters

Unqualified object names are resolved at runtime using the caller's default schema or search path. This means the same stored procedure can hit different tables depending on which user executes it. In MSSQL, schema resolution involves a two-step lookup (user schema, then `dbo`) that wastes CPU and prevents plan caching. In PostgreSQL, the `search_path` can be manipulated to hijack unqualified function calls. In Oracle, shared schemas make ambiguity a correctness risk. Always schema-qualify every object reference.

## Incorrect Code

### MSSQL
```sql
-- Bad: unqualified object names resolve differently per user
CREATE PROCEDURE GetActiveOrders
AS
BEGIN
    SET NOCOUNT ON;
    SELECT OrderID, CustomerID, OrderDate
    FROM Orders                 -- dbo.Orders? sales.Orders? depends on caller's default schema
    WHERE Status = 'Active';

    UPDATE OrderStats           -- which schema?
    SET LastChecked = GETDATE();
END;
```

### PostgreSQL
```sql
-- Bad: relies on search_path, which can be changed per session or per user
CREATE OR REPLACE FUNCTION get_active_orders()
RETURNS SETOF orders AS $$
BEGIN
    RETURN QUERY
    SELECT order_id, customer_id, order_date
    FROM orders                 -- could resolve to any schema in search_path
    WHERE status = 'active';
END;
$$ LANGUAGE plpgsql;

-- Attacker can exploit: SET search_path TO malicious_schema, public;
```

### Oracle
```sql
-- Bad: unqualified name in a shared environment
CREATE OR REPLACE PROCEDURE get_active_orders AS
    CURSOR c IS
        SELECT order_id, customer_id, order_date
        FROM orders             -- which schema? depends on the procedure owner
        WHERE status = 'ACTIVE';
BEGIN
    FOR r IN c LOOP
        NULL;
    END LOOP;
END;
/
```

### MySQL
```sql
-- Bad: no database qualifier in cross-database queries
CREATE PROCEDURE get_active_orders()
BEGIN
    SELECT order_id, customer_id, order_date
    FROM orders                 -- resolved from the USE database context
    WHERE status = 'active';
END;
-- If called from a different database context, this breaks
```

## Correct Code

### MSSQL
```sql
-- Good: every object is schema-qualified; procedure itself is schema-qualified
CREATE PROCEDURE Sales.GetActiveOrders
AS
BEGIN
    SET NOCOUNT ON;
    SELECT OrderID, CustomerID, OrderDate
    FROM Sales.Orders
    WHERE Status = 'Active';

    UPDATE Reporting.OrderStats
    SET LastChecked = GETDATE();
END;

-- Good: JOINs consistently qualified
SELECT o.OrderID, c.CustomerName
FROM Sales.Orders o
INNER JOIN Sales.Customers c ON o.CustomerID = c.CustomerID;
```

### PostgreSQL
```sql
-- Good: schema-qualified and search_path locked down
CREATE OR REPLACE FUNCTION app.get_active_orders()
RETURNS SETOF app.orders AS $$
BEGIN
    RETURN QUERY
    SELECT o.order_id, o.customer_id, o.order_date
    FROM app.orders o
    WHERE o.status = 'active';
END;
$$ LANGUAGE plpgsql
SET search_path = app, pg_catalog;  -- lock search_path inside the function

-- Good: set search_path at the role level for defense in depth
ALTER ROLE app_user SET search_path = app, pg_catalog;
```

### Oracle
```sql
-- Good: schema-qualified references
CREATE OR REPLACE PROCEDURE app.get_active_orders(
    p_cur OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_cur FOR
        SELECT o.order_id, o.customer_id, o.order_date
        FROM app.orders o
        WHERE o.status = 'ACTIVE';
END;
/

-- Good: synonyms for cross-schema access (explicit mapping)
CREATE SYNONYM app.ext_customers FOR shared_schema.customers;
```

### MySQL
```sql
-- Good: database-qualified when accessing objects outside the default database
CREATE PROCEDURE myapp.get_active_orders()
BEGIN
    SELECT order_id, customer_id, order_date
    FROM myapp.orders
    WHERE status = 'active';
END;

-- Good: cross-database reference is explicit
SELECT o.order_id, c.customer_name
FROM myapp.orders o
INNER JOIN crm.customers c ON o.customer_id = c.customer_id;
```

## What Must Be Schema-Qualified

| Object Type | MSSQL Example | PostgreSQL Example | Oracle Example | MySQL Example |
|---|---|---|---|---|
| Tables | `Sales.Orders` | `app.orders` | `app.orders` | `myapp.orders` |
| Views | `Reporting.vwSummary` | `reports.v_summary` | `reports.v_summary` | `myapp.v_summary` |
| Procedures | `Sales.Order_Insert` | `app.insert_order()` | `app.insert_order` | `myapp.insert_order` |
| Functions | `dbo.fn_GetDays` | `app.get_days()` | `app.fn_get_days` | `myapp.fn_get_days` |

## Application Code Detection

### Python

```python
# Bad (MSSQL)
cursor.execute("SELECT * FROM Orders WHERE OrderID = ?", (oid,))
# Good
cursor.execute("SELECT OrderID, Status FROM dbo.Orders WHERE OrderID = ?", (oid,))

# Bad (PostgreSQL)
cur.execute("SELECT * FROM orders WHERE order_id = %s", (oid,))
# Good
cur.execute("SELECT order_id, status FROM app.orders WHERE order_id = %s", (oid,))
```

### Node.js

```javascript
// Bad (MSSQL)
await pool.request().query('SELECT * FROM Orders');
// Good
await pool.request().query('SELECT OrderID, Status FROM Sales.Orders');

// Bad (PostgreSQL)
await client.query('SELECT * FROM orders');
// Good
await client.query('SELECT order_id, status FROM app.orders');
```

### C#

```csharp
// Bad (MSSQL)
cmd.CommandText = "SELECT * FROM Orders WHERE OrderID = @id";
// Good
cmd.CommandText = "SELECT OrderID, Status FROM Sales.Orders WHERE OrderID = @id";

// Bad (PostgreSQL / Npgsql)
cmd.CommandText = "SELECT * FROM orders WHERE order_id = @id";
// Good
cmd.CommandText = "SELECT order_id, status FROM app.orders WHERE order_id = @id";
```

## Exceptions

- **Temp tables** (`#TempOrders`, `##GlobalTemp` in MSSQL) live in `tempdb` and cannot be schema-qualified.
- **Table variables** (`@TableVar` in MSSQL) are query-scoped.
- **CTEs** (Common Table Expressions) are query-scoped aliases, not schema objects.
- **MySQL single-database applications** where all objects are in one database and cross-database queries never occur. Even then, explicit qualification is a good habit.
- **System catalog views** (`sys.objects`, `information_schema.*`, `pg_catalog.*`) are already in well-known schemas.

## How to Detect

### MSSQL
```sql
SELECT SCHEMA_NAME(o.schema_id) + '.' + o.name AS ProcedureName
FROM sys.objects o
JOIN sys.sql_modules m ON o.object_id = m.object_id
WHERE o.type IN ('P', 'V', 'FN', 'IF', 'TF')
  AND m.definition LIKE '%FROM %'
  AND m.definition NOT LIKE '%FROM [a-z]%.%'
ORDER BY ProcedureName;
```

### PostgreSQL
```sql
-- Find functions that do not lock search_path
SELECT n.nspname || '.' || p.proname AS func_name,
       p.proconfig
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND (p.proconfig IS NULL OR NOT 'search_path' = ANY(
      SELECT split_part(unnest(p.proconfig), '=', 1)))
ORDER BY func_name;
```

### Oracle
```sql
-- Find source lines with unqualified FROM clauses
SELECT owner, name, type, line, text
FROM all_source
WHERE type IN ('PROCEDURE', 'FUNCTION', 'PACKAGE BODY')
  AND UPPER(text) LIKE '%FROM %'
  AND text NOT LIKE '%FROM %.%'
  AND owner NOT IN ('SYS', 'SYSTEM')
ORDER BY owner, name, line;
```

### MySQL
```sql
SELECT ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_DEFINITION
FROM information_schema.ROUTINES
WHERE ROUTINE_DEFINITION LIKE '%FROM %'
  AND ROUTINE_DEFINITION NOT LIKE '%FROM %.%'
  AND ROUTINE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
ORDER BY ROUTINE_SCHEMA, ROUTINE_NAME;
```
