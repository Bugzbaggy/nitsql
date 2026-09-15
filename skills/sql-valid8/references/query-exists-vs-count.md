# query-exists-vs-count
**Priority:** HIGH
**Category:** Performance
**Applies to:** MSSQL, PostgreSQL, Oracle, MySQL

## Why It Matters

`COUNT(*) > 0` forces the engine to scan and aggregate every matching row before it can evaluate the comparison. `EXISTS` uses a semi-join: it stops at the first match and returns immediately. When millions of rows match, `EXISTS` is orders of magnitude faster. The optimizer in every major RDBMS can short-circuit an `EXISTS` subquery but cannot short-circuit an aggregate.

## Incorrect Code

### MSSQL
```sql
-- Bad: COUNT scans all matching rows to check existence
IF (SELECT COUNT(*) FROM dbo.Orders WHERE CustomerID = @CustomerID) > 0
BEGIN
    PRINT 'Customer has orders';
END;

-- Bad: COUNT in a correlated subquery
SELECT c.CustomerID, c.CustomerName
FROM dbo.Customers c
WHERE (SELECT COUNT(*) FROM dbo.Orders o WHERE o.CustomerID = c.CustomerID) > 0;
```

### PostgreSQL
```sql
-- Bad: COUNT scans all matching rows
SELECT customer_id, customer_name
FROM public.customers c
WHERE (SELECT COUNT(*) FROM public.orders o WHERE o.customer_id = c.customer_id) > 0;
```

### Oracle
```sql
-- Bad: COUNT scans all matching rows
SELECT customer_id, customer_name
FROM app.customers c
WHERE (SELECT COUNT(*) FROM app.orders o WHERE o.customer_id = c.customer_id) > 0;
```

### MySQL
```sql
-- Bad: COUNT scans all matching rows
SELECT c.customer_id, c.customer_name
FROM customers c
WHERE (SELECT COUNT(*) FROM orders o WHERE o.customer_id = c.customer_id) > 0;
```

## Correct Code

### MSSQL
```sql
-- Good: EXISTS stops at first match
IF EXISTS (SELECT 1 FROM dbo.Orders WHERE CustomerID = @CustomerID)
BEGIN
    PRINT 'Customer has orders';
END;

-- Good: EXISTS in a correlated subquery uses semi-join
SELECT c.CustomerID, c.CustomerName
FROM dbo.Customers c
WHERE EXISTS (SELECT 1 FROM dbo.Orders o WHERE o.CustomerID = c.CustomerID);

-- Good: NOT EXISTS for non-existence
IF NOT EXISTS (SELECT 1 FROM dbo.Orders WHERE OrderID = @OrderID)
BEGIN
    THROW 50710, 'Order not found', 1;
END;
```

### PostgreSQL
```sql
-- Good: EXISTS with semi-join
SELECT c.customer_id, c.customer_name
FROM public.customers c
WHERE EXISTS (SELECT 1 FROM public.orders o WHERE o.customer_id = c.customer_id);

-- Good: NOT EXISTS for non-existence
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.orders WHERE order_id = 123) THEN
        RAISE EXCEPTION 'Order not found';
    END IF;
END $$;
```

### Oracle
```sql
-- Good: EXISTS with semi-join
SELECT c.customer_id, c.customer_name
FROM app.customers c
WHERE EXISTS (SELECT 1 FROM app.orders o WHERE o.customer_id = c.customer_id);

-- Good: NOT EXISTS check in PL/SQL
DECLARE
    v_found NUMBER;
BEGIN
    SELECT CASE WHEN EXISTS (SELECT 1 FROM app.orders WHERE order_id = :id)
                THEN 1 ELSE 0 END
    INTO v_found FROM DUAL;

    IF v_found = 0 THEN
        RAISE_APPLICATION_ERROR(-20001, 'Order not found');
    END IF;
END;
/
```

### MySQL
```sql
-- Good: EXISTS with semi-join
SELECT c.customer_id, c.customer_name
FROM customers c
WHERE EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.customer_id);

-- Good: NOT EXISTS in a procedure
CREATE PROCEDURE check_order(IN p_order_id INT)
BEGIN
    IF NOT EXISTS (SELECT 1 FROM orders WHERE order_id = p_order_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Order not found';
    END IF;
END;
```

## When COUNT Is Appropriate

COUNT is correct when you need the actual numeric value:

```sql
-- All dialects: you need the real count for business logic
-- MSSQL
DECLARE @OrderCount INT = (SELECT COUNT(*) FROM dbo.Orders WHERE CustomerID = @CustomerID);
IF @OrderCount >= 10 SET @Tier = 'Gold';

-- PostgreSQL
SELECT COUNT(*) INTO v_cnt FROM public.orders WHERE customer_id = p_id;

-- Oracle
SELECT COUNT(*) INTO v_cnt FROM app.orders WHERE customer_id = p_id;

-- MySQL
SELECT COUNT(*) INTO v_cnt FROM orders WHERE customer_id = p_id;
```

## Performance Comparison

| Pattern | Matching Rows | Behavior |
|---------|--------------|----------|
| `EXISTS (SELECT 1 ...)` | 1,000,000 | Stops after 1st row |
| `COUNT(*) > 0` | 1,000,000 | Counts all 1,000,000 rows |
| `EXISTS (SELECT 1 ...)` | 0 | Full scan (same as COUNT) |
| `COUNT(*) = 0` | 0 | Full scan (same as EXISTS) |

The benefit of EXISTS grows linearly with the number of matching rows.

## Application Code Detection

### Python

```python
# Bad (any dialect)
cursor.execute("SELECT COUNT(*) FROM orders WHERE customer_id = %s", (cid,))
count = cursor.fetchone()[0]
if count > 0:
    process()

# Good (any dialect -- adjust placeholder per driver)
cursor.execute("SELECT 1 FROM orders WHERE customer_id = %s LIMIT 1", (cid,))
if cursor.fetchone():
    process()
```

### Node.js

```javascript
// Bad
const { rows } = await client.query(
    'SELECT COUNT(*) AS cnt FROM orders WHERE customer_id = $1', [cid]);
if (rows[0].cnt > 0) { /* ... */ }

// Good
const { rows } = await client.query(
    'SELECT 1 FROM orders WHERE customer_id = $1 LIMIT 1', [cid]);
if (rows.length > 0) { /* ... */ }
```

### C#

```csharp
// Bad
cmd.CommandText = "SELECT COUNT(*) FROM orders WHERE customer_id = @id";
int count = (int)await cmd.ExecuteScalarAsync();
if (count > 0) { /* ... */ }

// Good
cmd.CommandText = "SELECT 1 FROM orders WHERE customer_id = @id";
// MSSQL: add "TOP 1"; PostgreSQL/MySQL: add "LIMIT 1"; Oracle: add "FETCH FIRST 1 ROW ONLY"
var result = await cmd.ExecuteScalarAsync();
if (result != null) { /* ... */ }
```

## Exceptions

- When you need the actual count value (e.g., pagination totals, threshold checks against specific numbers like >= 10).
- `COUNT(*)` in a `GROUP BY` report -- EXISTS is not a substitute for aggregation.

## How to Detect

### MSSQL
```sql
SELECT TOP 20 qt.query_sql_text, SUM(rs.count_executions) AS execs
FROM sys.query_store_query_text qt
JOIN sys.query_store_query q ON qt.query_text_id = q.query_text_id
JOIN sys.query_store_plan p ON q.query_id = p.query_id
JOIN sys.query_store_runtime_stats rs ON p.plan_id = rs.plan_id
WHERE qt.query_sql_text LIKE '%COUNT(%)%>%0%'
   OR qt.query_sql_text LIKE '%COUNT(%)%=%0%'
GROUP BY qt.query_sql_text
ORDER BY execs DESC;
```

### PostgreSQL
```sql
SELECT query, calls, mean_exec_time
FROM pg_stat_statements
WHERE query ~* 'count\(\*\)\s*[>=]'
ORDER BY calls DESC
LIMIT 20;
```

### Oracle
```sql
SELECT sql_text, executions
FROM v$sqlarea
WHERE UPPER(sql_text) LIKE '%COUNT(%)%>%0%'
   OR UPPER(sql_text) LIKE '%COUNT(%)%=%0%'
ORDER BY executions DESC
FETCH FIRST 20 ROWS ONLY;
```

### MySQL
```sql
SELECT DIGEST_TEXT, COUNT_STAR
FROM performance_schema.events_statements_summary_by_digest
WHERE DIGEST_TEXT LIKE '%COUNT%>%0%'
   OR DIGEST_TEXT LIKE '%COUNT%=%0%'
ORDER BY COUNT_STAR DESC
LIMIT 20;
```
