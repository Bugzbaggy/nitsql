# query-avoid-cursors
**Priority:** HIGH
**Category:** Performance
**Applies to:** MSSQL, PostgreSQL, Oracle, MySQL

## Why It Matters

Cursors process rows one at a time: fetch a row, do work, fetch the next. Set-based operations process all rows in a single pass through the optimizer, leveraging parallel execution, batch-mode processing, and minimal context switching. A cursor loop over 100,000 rows can take minutes; the equivalent set-based `UPDATE ... WHERE` or `MERGE` finishes in seconds. Cursors also hold locks longer, increasing blocking and deadlock risk.

## Incorrect Code

### MSSQL
```sql
-- Bad: cursor loop to update each row individually
CREATE PROCEDURE dbo.ApplyDiscount
    @DiscountPct DECIMAL(5,2)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @OrderID INT, @Total DECIMAL(10,2);
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT OrderID, TotalAmount FROM dbo.Orders WHERE Status = 'Pending';

    OPEN cur;
    FETCH NEXT FROM cur INTO @OrderID, @Total;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        UPDATE dbo.Orders
        SET TotalAmount = @Total * (1 - @DiscountPct / 100),
            DiscountApplied = 1
        WHERE OrderID = @OrderID;

        FETCH NEXT FROM cur INTO @OrderID, @Total;
    END;
    CLOSE cur;
    DEALLOCATE cur;
END;
```

### PostgreSQL
```sql
-- Bad: FOR loop processing rows one by one
CREATE OR REPLACE FUNCTION apply_discount(p_pct NUMERIC)
RETURNS VOID AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN SELECT order_id, total_amount FROM app.orders WHERE status = 'pending' LOOP
        UPDATE app.orders
        SET total_amount = rec.total_amount * (1 - p_pct / 100),
            discount_applied = TRUE
        WHERE order_id = rec.order_id;
    END LOOP;
END;
$$ LANGUAGE plpgsql;
```

### Oracle
```sql
-- Bad: explicit cursor loop
CREATE OR REPLACE PROCEDURE apply_discount(p_pct IN NUMBER) AS
    CURSOR c_orders IS
        SELECT order_id, total_amount
        FROM app.orders
        WHERE status = 'PENDING';
BEGIN
    FOR rec IN c_orders LOOP
        UPDATE app.orders
        SET total_amount = rec.total_amount * (1 - p_pct / 100),
            discount_applied = 'Y'
        WHERE order_id = rec.order_id;
    END LOOP;
    COMMIT;
END;
/
```

### MySQL
```sql
-- Bad: cursor loop
CREATE PROCEDURE apply_discount(IN p_pct DECIMAL(5,2))
BEGIN
    DECLARE v_order_id INT;
    DECLARE v_total DECIMAL(10,2);
    DECLARE v_done INT DEFAULT 0;
    DECLARE cur CURSOR FOR
        SELECT order_id, total_amount FROM orders WHERE status = 'pending';
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO v_order_id, v_total;
        IF v_done THEN LEAVE read_loop; END IF;

        UPDATE orders
        SET total_amount = v_total * (1 - p_pct / 100),
            discount_applied = 1
        WHERE order_id = v_order_id;
    END LOOP;
    CLOSE cur;
END;
```

## Correct Code

### MSSQL
```sql
-- Good: single set-based UPDATE replaces the entire cursor
CREATE PROCEDURE dbo.ApplyDiscount
    @DiscountPct DECIMAL(5,2)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    UPDATE dbo.Orders
    SET TotalAmount = TotalAmount * (1 - @DiscountPct / 100),
        DiscountApplied = 1
    WHERE Status = 'Pending';
END;

-- Good: MERGE for upsert instead of cursor with IF EXISTS / INSERT / UPDATE
MERGE dbo.ProductInventory AS tgt
USING dbo.StagingInventory AS src
    ON tgt.ProductID = src.ProductID
WHEN MATCHED THEN
    UPDATE SET tgt.Quantity = src.Quantity, tgt.LastUpdated = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT (ProductID, Quantity, LastUpdated)
    VALUES (src.ProductID, src.Quantity, SYSUTCDATETIME());

-- Good: INSERT...SELECT instead of cursor loop with INSERT
INSERT INTO dbo.OrderArchive (OrderID, CustomerID, OrderDate, TotalAmount)
SELECT OrderID, CustomerID, OrderDate, TotalAmount
FROM dbo.Orders
WHERE OrderDate < DATEADD(YEAR, -2, GETDATE());
```

### PostgreSQL
```sql
-- Good: single set-based UPDATE
CREATE OR REPLACE FUNCTION apply_discount(p_pct NUMERIC)
RETURNS VOID AS $$
BEGIN
    UPDATE app.orders
    SET total_amount = total_amount * (1 - p_pct / 100),
        discount_applied = TRUE
    WHERE status = 'pending';
END;
$$ LANGUAGE plpgsql;

-- Good: INSERT ... ON CONFLICT (upsert) instead of cursor
INSERT INTO app.product_inventory (product_id, quantity, last_updated)
SELECT product_id, quantity, NOW()
FROM app.staging_inventory
ON CONFLICT (product_id) DO UPDATE
SET quantity = EXCLUDED.quantity,
    last_updated = EXCLUDED.last_updated;

-- Good: INSERT...SELECT for bulk operations
INSERT INTO app.order_archive (order_id, customer_id, order_date, total_amount)
SELECT order_id, customer_id, order_date, total_amount
FROM app.orders
WHERE order_date < CURRENT_DATE - INTERVAL '2 years';
```

### Oracle
```sql
-- Good: single set-based UPDATE
CREATE OR REPLACE PROCEDURE apply_discount(p_pct IN NUMBER) AS
BEGIN
    UPDATE app.orders
    SET total_amount = total_amount * (1 - p_pct / 100),
        discount_applied = 'Y'
    WHERE status = 'PENDING';
    COMMIT;
END;
/

-- Good: MERGE for upsert instead of cursor
MERGE INTO app.product_inventory tgt
USING app.staging_inventory src
    ON (tgt.product_id = src.product_id)
WHEN MATCHED THEN
    UPDATE SET tgt.quantity = src.quantity, tgt.last_updated = SYSTIMESTAMP
WHEN NOT MATCHED THEN
    INSERT (product_id, quantity, last_updated)
    VALUES (src.product_id, src.quantity, SYSTIMESTAMP);

-- Good: BULK COLLECT + FORALL when cursor-like processing is truly needed
CREATE OR REPLACE PROCEDURE bulk_apply_discount(p_pct IN NUMBER) AS
    TYPE t_ids IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    v_ids t_ids;
BEGIN
    SELECT order_id BULK COLLECT INTO v_ids
    FROM app.orders WHERE status = 'PENDING';

    FORALL i IN 1..v_ids.COUNT
        UPDATE app.orders
        SET total_amount = total_amount * (1 - p_pct / 100),
            discount_applied = 'Y'
        WHERE order_id = v_ids(i);
    COMMIT;
END;
/
```

### MySQL
```sql
-- Good: single set-based UPDATE
CREATE PROCEDURE apply_discount(IN p_pct DECIMAL(5,2))
BEGIN
    UPDATE orders
    SET total_amount = total_amount * (1 - p_pct / 100),
        discount_applied = 1
    WHERE status = 'pending';
END;

-- Good: INSERT...ON DUPLICATE KEY UPDATE (upsert)
INSERT INTO product_inventory (product_id, quantity, last_updated)
SELECT product_id, quantity, NOW()
FROM staging_inventory
ON DUPLICATE KEY UPDATE
    quantity = VALUES(quantity),
    last_updated = VALUES(last_updated);

-- Good: INSERT...SELECT for bulk operations
INSERT INTO order_archive (order_id, customer_id, order_date, total_amount)
SELECT order_id, customer_id, order_date, total_amount
FROM orders
WHERE order_date < DATE_SUB(CURDATE(), INTERVAL 2 YEAR);
```

## Set-Based Replacements Reference

| Cursor Pattern | Set-Based Replacement | All Dialects? |
|---|---|---|
| Loop + UPDATE each row | Single `UPDATE ... WHERE` | Yes |
| Loop + INSERT each row | `INSERT ... SELECT` | Yes |
| Loop + IF EXISTS then UPDATE else INSERT | `MERGE` / `ON CONFLICT` / `ON DUPLICATE KEY` | Yes (syntax varies) |
| Loop + DELETE each row | Single `DELETE ... WHERE` | Yes |
| Loop + conditional logic per row | `CASE` expression in UPDATE/INSERT | Yes |
| Loop + running total | Window function `SUM() OVER (ORDER BY ...)` | Yes |
| Loop + row numbering | `ROW_NUMBER() OVER (...)` | Yes |

## Application Code Detection

### Python

```python
# Bad: fetching all rows and updating one by one
rows = cursor.fetchall()
for row in rows:
    cursor.execute("UPDATE orders SET status = 'processed' WHERE order_id = %s", (row[0],))
conn.commit()

# Good: single set-based UPDATE
cursor.execute("UPDATE orders SET status = 'processed' WHERE status = 'pending'")
conn.commit()
```

### Node.js

```javascript
// Bad: looping over rows
const { rows } = await client.query("SELECT order_id FROM orders WHERE status = 'pending'");
for (const row of rows) {
    await client.query("UPDATE orders SET status = 'processed' WHERE order_id = $1", [row.order_id]);
}

// Good: single set-based UPDATE
await client.query("UPDATE orders SET status = 'processed' WHERE status = 'pending'");
```

### C#

```csharp
// Bad: looping over rows
var reader = await selectCmd.ExecuteReaderAsync();
while (await reader.ReadAsync())
{
    var id = reader.GetInt32(0);
    using var updateCmd = new SqlCommand("UPDATE Orders SET Status = 'processed' WHERE OrderID = @id", conn);
    updateCmd.Parameters.AddWithValue("@id", id);
    await updateCmd.ExecuteNonQueryAsync();
}

// Good: single set-based UPDATE
using var cmd = new SqlCommand("UPDATE Orders SET Status = 'processed' WHERE Status = 'pending'", conn);
await cmd.ExecuteNonQueryAsync();
```

## Exceptions

- **Row-by-row business logic** that truly differs per row and cannot be expressed as a `CASE` expression (e.g., calling an external API per row). Move this logic to the application layer instead of a SQL cursor.
- **Batched deletes/updates** in very large tables (> 10M rows) where a single statement would cause excessive lock escalation and transaction log growth. Use a `WHILE` loop with `TOP N` (MSSQL), `LIMIT N` (PostgreSQL/MySQL), or `ROWNUM` (Oracle) to process in chunks -- this is a controlled loop, not a row-by-row cursor.
- **Oracle BULK COLLECT + FORALL** is a hybrid approach that fetches rows in batches and sends DML in bulk. It is significantly faster than a plain cursor and acceptable when a pure set-based statement is not possible.
- **Administrative maintenance scripts** (index rebuilds, partition maintenance) may use cursors to iterate over metadata. This is acceptable since the iteration is over a small set of schema objects, not data rows.

## How to Detect

### MSSQL
```sql
-- Procedures using DECLARE CURSOR
SELECT SCHEMA_NAME(o.schema_id) + '.' + o.name AS ProcedureName
FROM sys.objects o
JOIN sys.sql_modules m ON o.object_id = m.object_id
WHERE o.type = 'P'
  AND UPPER(m.definition) LIKE '%DECLARE%CURSOR%'
ORDER BY ProcedureName;
```

### PostgreSQL
```sql
-- Functions using FOR ... IN ... LOOP with DML inside
SELECT n.nspname || '.' || p.proname AS func_name
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND pg_get_functiondef(p.oid) ~* 'FOR\s+\w+\s+IN\s+.*LOOP'
  AND (pg_get_functiondef(p.oid) ~* 'UPDATE\s' OR pg_get_functiondef(p.oid) ~* 'INSERT\s')
ORDER BY func_name;
```

### Oracle
```sql
-- Procedures with CURSOR declarations
SELECT DISTINCT owner || '.' || name AS object_name
FROM all_source
WHERE type IN ('PROCEDURE', 'FUNCTION', 'PACKAGE BODY')
  AND UPPER(text) LIKE '%CURSOR%IS%SELECT%'
  AND owner NOT IN ('SYS', 'SYSTEM')
ORDER BY object_name;
```

### MySQL
```sql
-- Procedures with DECLARE CURSOR
SELECT ROUTINE_SCHEMA, ROUTINE_NAME
FROM information_schema.ROUTINES
WHERE ROUTINE_TYPE = 'PROCEDURE'
  AND UPPER(ROUTINE_DEFINITION) LIKE '%DECLARE%CURSOR%'
  AND ROUTINE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
ORDER BY ROUTINE_SCHEMA, ROUTINE_NAME;
```
