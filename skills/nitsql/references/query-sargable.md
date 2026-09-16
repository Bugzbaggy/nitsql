# query-sargable
**Priority:** CRITICAL
**Category:** Performance
**Applies to:** MSSQL, PostgreSQL, Oracle, MySQL

## Why It Matters

A SARGable (Search ARGument ABLE) predicate allows the optimizer to use an index seek or range scan. Wrapping an indexed column in a function, performing arithmetic on it, or casting it forces a full table or index scan because the engine must evaluate the expression for every row. On a 100-million-row table, the difference between an index seek (< 1 ms) and a full scan (> 10 s) is the difference between a responsive application and an outage.

## Incorrect Code

### MSSQL
```sql
-- Bad: function on indexed column prevents index seek
SELECT OrderID, OrderDate
FROM dbo.Orders
WHERE YEAR(OrderDate) = 2024;

-- Bad: implicit conversion via concatenation
SELECT CustomerID, Name
FROM dbo.Customers
WHERE UPPER(Name) = 'JOHN SMITH';

-- Bad: arithmetic on the column side
SELECT ProductID, Price
FROM dbo.Products
WHERE Price * 1.1 > 100;

-- Bad: CONVERT/CAST wrapping the column
SELECT OrderID, OrderDate
FROM dbo.Orders
WHERE CONVERT(DATE, OrderDate) = '2024-06-15';
```

### PostgreSQL
```sql
-- Bad: function on indexed column
SELECT order_id, order_date
FROM public.orders
WHERE EXTRACT(YEAR FROM order_date) = 2024;

-- Bad: UPPER on indexed column (ILIKE may also prevent btree usage)
SELECT customer_id, name
FROM public.customers
WHERE UPPER(name) = 'JOHN SMITH';

-- Bad: arithmetic on column
SELECT product_id, price
FROM public.products
WHERE price * 1.1 > 100;

-- Bad: casting the column
SELECT order_id, order_date
FROM public.orders
WHERE order_date::date = '2024-06-15';
```

### Oracle
```sql
-- Bad: function on indexed column
SELECT order_id, order_date
FROM app.orders
WHERE TO_CHAR(order_date, 'YYYY') = '2024';

-- Bad: NLS-dependent function wrapping
SELECT customer_id, name
FROM app.customers
WHERE UPPER(name) = 'JOHN SMITH';

-- Bad: arithmetic on column
SELECT product_id, price
FROM app.products
WHERE price * 1.1 > 100;

-- Bad: TRUNC wrapping DATE column
SELECT order_id, order_date
FROM app.orders
WHERE TRUNC(order_date) = DATE '2024-06-15';
```

### MySQL
```sql
-- Bad: function on indexed column
SELECT order_id, order_date
FROM orders
WHERE YEAR(order_date) = 2024;

-- Bad: UPPER on indexed column
SELECT customer_id, name
FROM customers
WHERE UPPER(name) = 'JOHN SMITH';

-- Bad: arithmetic on column
SELECT product_id, price
FROM products
WHERE price * 1.1 > 100;

-- Bad: DATE() wrapping DATETIME column
SELECT order_id, order_date
FROM orders
WHERE DATE(order_date) = '2024-06-15';
```

## Correct Code

### MSSQL
```sql
-- Good: range predicate on the raw column (index seek)
SELECT OrderID, OrderDate
FROM dbo.Orders
WHERE OrderDate >= '2024-01-01' AND OrderDate < '2025-01-01';

-- Good: move function to the literal side or precompute
SELECT CustomerID, Name
FROM dbo.Customers
WHERE Name = 'JOHN SMITH';  -- store data in consistent case, or use a computed column

-- Good: use a persisted computed column + index for case-insensitive search
ALTER TABLE dbo.Customers ADD NameUpper AS UPPER(Name) PERSISTED;
CREATE INDEX IX_Customers_NameUpper ON dbo.Customers (NameUpper);
SELECT CustomerID, Name FROM dbo.Customers WHERE NameUpper = 'JOHN SMITH';

-- Good: move arithmetic to the literal side
SELECT ProductID, Price
FROM dbo.Products
WHERE Price > 100.0 / 1.1;   -- algebra: Price * 1.1 > 100 => Price > 100/1.1

-- Good: range predicate for date equality
SELECT OrderID, OrderDate
FROM dbo.Orders
WHERE OrderDate >= '2024-06-15' AND OrderDate < '2024-06-16';
```

### PostgreSQL
```sql
-- Good: range predicate
SELECT order_id, order_date
FROM public.orders
WHERE order_date >= '2024-01-01' AND order_date < '2025-01-01';

-- Good: expression index for case-insensitive search
CREATE INDEX idx_customers_name_upper ON public.customers (UPPER(name));
SELECT customer_id, name
FROM public.customers
WHERE UPPER(name) = 'JOHN SMITH';
-- The expression index matches the WHERE expression exactly

-- Good: use citext type or a GIN trigram index for ILIKE
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_customers_name_trgm ON public.customers USING gin (name gin_trgm_ops);
SELECT customer_id, name
FROM public.customers
WHERE name ILIKE '%smith%';   -- GIN trigram index supports ILIKE

-- Good: move arithmetic to the literal side
SELECT product_id, price
FROM public.products
WHERE price > 100.0 / 1.1;

-- Good: range predicate for date equality
SELECT order_id, order_date
FROM public.orders
WHERE order_date >= '2024-06-15' AND order_date < '2024-06-16';
```

### Oracle
```sql
-- Good: range predicate
SELECT order_id, order_date
FROM app.orders
WHERE order_date >= DATE '2024-01-01' AND order_date < DATE '2025-01-01';

-- Good: function-based index
CREATE INDEX idx_customers_name_upper ON app.customers (UPPER(name));
SELECT customer_id, name
FROM app.customers
WHERE UPPER(name) = 'JOHN SMITH';
-- Oracle CBO uses the function-based index

-- Good: move arithmetic to the literal side
SELECT product_id, price
FROM app.products
WHERE price > 100.0 / 1.1;

-- Good: range predicate for date equality (avoids TRUNC)
SELECT order_id, order_date
FROM app.orders
WHERE order_date >= DATE '2024-06-15' AND order_date < DATE '2024-06-16';
```

### MySQL
```sql
-- Good: range predicate
SELECT order_id, order_date
FROM orders
WHERE order_date >= '2024-01-01' AND order_date < '2025-01-01';

-- Good: functional index (MySQL 8.0.13+)
CREATE INDEX idx_customers_name_upper ON customers ((UPPER(name)));
SELECT customer_id, name
FROM customers
WHERE UPPER(name) = 'JOHN SMITH';

-- Good: generated column + index (MySQL 5.7+)
ALTER TABLE customers ADD name_upper VARCHAR(200) AS (UPPER(name)) STORED;
CREATE INDEX idx_customers_name_upper ON customers (name_upper);
SELECT customer_id, name FROM customers WHERE name_upper = 'JOHN SMITH';

-- Good: move arithmetic to the literal side
SELECT product_id, price
FROM products
WHERE price > 100.0 / 1.1;

-- Good: range predicate for date equality
SELECT order_id, order_date
FROM orders
WHERE order_date >= '2024-06-15' AND order_date < '2024-06-16';
```

## Common Non-SARGable Patterns and Fixes

| Non-SARGable (bad) | SARGable (good) | Why |
|---|---|---|
| `WHERE YEAR(dt) = 2024` | `WHERE dt >= '2024-01-01' AND dt < '2025-01-01'` | Range scan vs full scan |
| `WHERE UPPER(name) = 'X'` | Expression index on `UPPER(name)` | Index matches the expression |
| `WHERE col * 2 > 100` | `WHERE col > 50` | Move math to literal side |
| `WHERE CAST(col AS DATE) = 'x'` | `WHERE col >= 'x' AND col < 'x+1'` | Range vs full scan |
| `WHERE col + 1 = 5` | `WHERE col = 4` | Move constant to literal side |
| `WHERE SUBSTRING(col,1,3) = 'ABC'` | `WHERE col LIKE 'ABC%'` | Leading wildcard is seekable |
| `WHERE col LIKE '%ABC'` | Full-text index or trigram index | Leading `%` prevents btree seek |

## Application Code Detection

### Python

```python
# Bad (any dialect)
cursor.execute("SELECT * FROM orders WHERE YEAR(order_date) = %s", (year,))

# Good
cursor.execute(
    "SELECT * FROM orders WHERE order_date >= %s AND order_date < %s",
    (f"{year}-01-01", f"{year + 1}-01-01")
)
```

### Node.js

```javascript
// Bad
await client.query('SELECT * FROM orders WHERE YEAR(order_date) = $1', [year]);

// Good
await client.query(
    'SELECT * FROM orders WHERE order_date >= $1 AND order_date < $2',
    [`${year}-01-01`, `${year + 1}-01-01`]
);
```

### C#

```csharp
// Bad (EF Core generates non-SARGable queries if you use .Year in LINQ)
var orders = ctx.Orders.Where(o => o.OrderDate.Year == 2024).ToList();

// Good
var start = new DateTime(2024, 1, 1);
var end = new DateTime(2025, 1, 1);
var orders = ctx.Orders.Where(o => o.OrderDate >= start && o.OrderDate < end).ToList();
```

## Exceptions

- **Expression/functional indexes** make the wrapped expression SARGable. If `UPPER(name)` has a dedicated index, then `WHERE UPPER(name) = 'X'` IS SARGable.
- **Full-text indexes** are designed for non-SARGable patterns like `CONTAINS`, `MATCH ... AGAINST`, or trigram similarity.
- **Small tables** (< 1,000 rows): the optimizer will table-scan regardless; SARGability is irrelevant.

## How to Detect

### MSSQL
```sql
-- Queries with Index Scans that should be Index Seeks
SELECT TOP 20
    qt.query_sql_text,
    qp.query_plan,
    rs.avg_logical_io_reads,
    rs.count_executions
FROM sys.query_store_query q
JOIN sys.query_store_query_text qt ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_plan p ON q.query_id = p.query_id
JOIN sys.query_store_runtime_stats rs ON p.plan_id = rs.plan_id
CROSS APPLY (SELECT TRY_CAST(p.query_plan AS XML) AS query_plan) qp
WHERE rs.avg_logical_io_reads > 10000
  AND CAST(p.query_plan AS NVARCHAR(MAX)) LIKE '%Scan%'
  AND CAST(p.query_plan AS NVARCHAR(MAX)) LIKE '%WHERE%'
ORDER BY rs.avg_logical_io_reads DESC;
```

### PostgreSQL
```sql
-- Queries with sequential scans that have filters (non-SARGable predicates)
SELECT query, calls, mean_exec_time, rows
FROM pg_stat_statements
WHERE query ~* '(EXTRACT|UPPER|LOWER|CAST|SUBSTRING|DATE_PART|TO_CHAR)\s*\('
ORDER BY mean_exec_time DESC
LIMIT 20;
```

### Oracle
```sql
-- SQL with full table scans that have predicate functions
SELECT sql_id, sql_text, executions, buffer_gets
FROM v$sql
WHERE sql_id IN (
    SELECT sql_id FROM v$sql_plan
    WHERE operation = 'TABLE ACCESS' AND options = 'FULL'
)
AND (UPPER(sql_text) LIKE '%UPPER(%' OR UPPER(sql_text) LIKE '%TO_CHAR(%'
     OR UPPER(sql_text) LIKE '%TRUNC(%')
ORDER BY buffer_gets DESC
FETCH FIRST 20 ROWS ONLY;
```

### MySQL
```sql
-- Queries doing full table scans with function-wrapped predicates
SELECT DIGEST_TEXT, COUNT_STAR, SUM_ROWS_EXAMINED, SUM_NO_INDEX_USED
FROM performance_schema.events_statements_summary_by_digest
WHERE SUM_NO_INDEX_USED > 0
  AND (DIGEST_TEXT LIKE '%YEAR(%' OR DIGEST_TEXT LIKE '%UPPER(%'
       OR DIGEST_TEXT LIKE '%DATE(%' OR DIGEST_TEXT LIKE '%SUBSTRING(%')
ORDER BY SUM_ROWS_EXAMINED DESC
LIMIT 20;
```
