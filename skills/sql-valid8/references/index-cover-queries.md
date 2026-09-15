# index-cover-queries
**Priority:** CRITICAL
**Category:** Indexing
**Applies to:** MSSQL, PostgreSQL, Oracle, MySQL

## Why It Matters

A covering index contains every column a query needs, so the engine never visits the base table. This eliminates expensive key lookups (MSSQL), heap fetches (PostgreSQL), table-access-by-rowid (Oracle), and secondary-to-clustered lookups (MySQL InnoDB). On read-heavy workloads, covering indexes reduce I/O by 90%+ and dramatically lower CPU consumption.

## Incorrect Code

### MSSQL
```sql
-- Index only on filter column; query needs OrderDate and TotalAmount too
CREATE NONCLUSTERED INDEX IX_Orders_CustomerID
ON dbo.Orders (CustomerID);

-- This triggers Index Seek + Key Lookup for every matching row
SELECT OrderID, CustomerID, OrderDate, TotalAmount
FROM dbo.Orders
WHERE CustomerID = @CustomerID;
```

### PostgreSQL
```sql
-- Index only on filter column
CREATE INDEX idx_orders_customer_id ON public.orders (customer_id);

-- Requires index scan + heap fetch for order_date, total_amount
SELECT order_id, customer_id, order_date, total_amount
FROM public.orders
WHERE customer_id = $1;
```

### Oracle
```sql
-- Index only on filter column
CREATE INDEX idx_orders_cust ON app.orders (customer_id);

-- Requires TABLE ACCESS BY INDEX ROWID for every row
SELECT order_id, customer_id, order_date, total_amount
FROM app.orders
WHERE customer_id = :cust_id;
```

### MySQL
```sql
-- Index only on filter column
CREATE INDEX idx_orders_customer_id ON orders (customer_id);

-- InnoDB secondary index includes PK implicitly, but not order_date or total_amount
-- Requires secondary index lookup + clustered index lookup per row
SELECT order_id, customer_id, order_date, total_amount
FROM orders
WHERE customer_id = ?;
```

## Correct Code

### MSSQL
```sql
-- Good: INCLUDE columns cover the SELECT list without widening the key
CREATE NONCLUSTERED INDEX IX_Orders_CustomerID_Covering
ON dbo.Orders (CustomerID)
INCLUDE (OrderDate, TotalAmount, OrderID);

-- Now: Index Seek only, zero key lookups
SELECT OrderID, CustomerID, OrderDate, TotalAmount
FROM dbo.Orders
WHERE CustomerID = @CustomerID;

-- Good: key columns for filter + ORDER BY; INCLUDE for output-only columns
CREATE NONCLUSTERED INDEX IX_Orders_CustDate
ON dbo.Orders (CustomerID, OrderDate)
INCLUDE (TotalAmount, Status);
```

### PostgreSQL
```sql
-- Good: INCLUDE clause (PostgreSQL 11+)
CREATE INDEX idx_orders_cust_covering
ON public.orders (customer_id)
INCLUDE (order_date, total_amount, order_id);

-- Good: composite key when INCLUDE is unavailable or when columns are used in WHERE/ORDER BY
CREATE INDEX idx_orders_cust_date
ON public.orders (customer_id, order_date, total_amount);

-- Index-only scan: verify with EXPLAIN (ANALYZE, BUFFERS)
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, customer_id, order_date, total_amount
FROM public.orders
WHERE customer_id = $1;
-- Look for "Index Only Scan" in the output
```

### Oracle
```sql
-- Oracle has no INCLUDE syntax. Use a composite index with all needed columns.
CREATE INDEX idx_orders_cust_covering
ON app.orders (customer_id, order_date, total_amount, order_id);

-- Good: for single-table lookups, consider an Index-Organized Table (IOT)
CREATE TABLE app.order_lookup (
    customer_id  NUMBER       NOT NULL,
    order_id     NUMBER       NOT NULL,
    order_date   DATE         NOT NULL,
    total_amount NUMBER(10,2) NOT NULL,
    CONSTRAINT pk_order_lookup PRIMARY KEY (customer_id, order_id)
) ORGANIZATION INDEX;

-- Verify with execution plan: look for INDEX RANGE SCAN (no TABLE ACCESS BY INDEX ROWID)
EXPLAIN PLAN FOR
SELECT order_id, customer_id, order_date, total_amount
FROM app.orders
WHERE customer_id = :cust_id;
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);
```

### MySQL
```sql
-- MySQL InnoDB: secondary indexes implicitly include the PK columns.
-- If the PK is (order_id), then idx on (customer_id) already covers order_id.
-- To cover order_date and total_amount, use a composite index:
CREATE INDEX idx_orders_cust_covering
ON orders (customer_id, order_date, total_amount);

-- Verify covering scan with EXPLAIN
EXPLAIN SELECT order_id, customer_id, order_date, total_amount
FROM orders
WHERE customer_id = ?;
-- Look for "Using index" in the Extra column
```

## Key Columns vs INCLUDE Columns (MSSQL and PostgreSQL 11+)

| Column used in ... | Should be a ... |
|---------------------|-----------------|
| WHERE, JOIN ON, ORDER BY | Key column |
| SELECT output only | INCLUDE column |
| GROUP BY, HAVING | Key column |

**INCLUDE columns** are stored only in the leaf level of the index (not intermediate pages), making the index narrower and cheaper to maintain.

## Application Code Detection

### Python

```python
# Tip: after writing a query, check the execution plan to verify covering index usage.
# MSSQL (pyodbc)
cursor.execute("SET STATISTICS PROFILE ON")
cursor.execute("SELECT OrderID, OrderDate FROM dbo.Orders WHERE CustomerID = ?", (cid,))
# Look for "Index Seek" without "Key Lookup" in the plan output

# PostgreSQL (psycopg2)
cur.execute("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT order_id, order_date FROM public.orders WHERE customer_id = %s", (cid,))
plan = cur.fetchone()[0]
# Look for "Index Only Scan"
```

### Node.js

```javascript
// PostgreSQL (pg)
const { rows } = await client.query(
    'EXPLAIN (ANALYZE, FORMAT JSON) SELECT order_id, order_date FROM public.orders WHERE customer_id = $1',
    [cid]
);
// Check for "Index Only Scan" in rows[0]['QUERY PLAN']

// MySQL (mysql2)
const [rows] = await conn.execute('EXPLAIN SELECT order_id, order_date FROM orders WHERE customer_id = ?', [cid]);
// Check for "Using index" in Extra column
```

### C#

```csharp
// MSSQL: check execution plan XML
cmd.CommandText = @"SET SHOWPLAN_XML ON";
await cmd.ExecuteNonQueryAsync();
cmd.CommandText = "SELECT OrderID, OrderDate FROM dbo.Orders WHERE CustomerID = @id";
cmd.Parameters.Add("@id", SqlDbType.Int).Value = customerId;
var planXml = (string)await cmd.ExecuteScalarAsync();
// Parse planXml: look for IndexScan/@Lookup = false
```

## Exceptions

- **Write-heavy tables**: every index slows INSERT/UPDATE/DELETE. If the table receives thousands of writes per second and the query runs infrequently, a covering index may not be worth the maintenance cost.
- **Wide columns (VARCHAR(MAX), TEXT, BLOB)**: including these in an index is usually impractical or disallowed. Filter and fetch wide columns from the heap.
- **Tables under 1,000 rows**: the optimizer may table-scan regardless; a covering index adds maintenance cost for negligible read benefit.

## How to Detect

### MSSQL
```sql
-- Find indexes with high key-lookup ratios
SELECT TOP 20
    OBJECT_NAME(ius.object_id) AS TableName,
    i.name AS IndexName,
    ius.user_lookups AS KeyLookups,
    ius.user_seeks AS IndexSeeks
FROM sys.dm_db_index_usage_stats ius
JOIN sys.indexes i ON ius.object_id = i.object_id AND ius.index_id = i.index_id
WHERE ius.database_id = DB_ID()
  AND ius.user_lookups > 1000
  AND i.type_desc = 'NONCLUSTERED'
ORDER BY ius.user_lookups DESC;

-- Missing index DMV suggestions
SELECT TOP 20
    CONVERT(DECIMAL(18,2), migs.avg_total_user_cost * migs.avg_user_impact
        * (migs.user_seeks + migs.user_scans)) AS improvement_measure,
    mid.equality_columns,
    mid.inequality_columns,
    mid.included_columns,
    OBJECT_NAME(mid.object_id) AS table_name
FROM sys.dm_db_missing_index_groups mig
JOIN sys.dm_db_missing_index_group_stats migs ON migs.group_handle = mig.index_group_handle
JOIN sys.dm_db_missing_index_details mid ON mig.index_handle = mid.index_handle
WHERE mid.database_id = DB_ID()
ORDER BY improvement_measure DESC;
```

### PostgreSQL
```sql
-- Tables with high index-scan counts but also high heap fetches (not index-only)
SELECT schemaname, relname, indexrelname,
       idx_scan, idx_tup_read, idx_tup_fetch
FROM pg_stat_user_indexes
WHERE idx_scan > 1000
ORDER BY idx_tup_fetch DESC
LIMIT 20;
```

### Oracle
```sql
-- Statements with TABLE ACCESS BY INDEX ROWID
SELECT sql_id, sql_text, executions
FROM v$sql
WHERE sql_text NOT LIKE '%v$sql%'
  AND sql_id IN (
      SELECT sql_id FROM v$sql_plan
      WHERE operation = 'TABLE ACCESS' AND options = 'BY INDEX ROWID'
  )
ORDER BY executions DESC
FETCH FIRST 20 ROWS ONLY;
```

### MySQL
```sql
-- Recent queries not using covering indexes (no "Using index" in Extra)
SELECT DIGEST_TEXT, COUNT_STAR,
       AVG_TIMER_WAIT / 1000000000 AS avg_ms
FROM performance_schema.events_statements_summary_by_digest
WHERE DIGEST_TEXT LIKE '%SELECT%FROM%WHERE%'
ORDER BY COUNT_STAR DESC
LIMIT 20;
-- Then EXPLAIN each top query and look for missing "Using index"
```
