# proc-set-nocount
**Priority:** MEDIUM
**Category:** Procedural
**Applies to:** MSSQL (required), PostgreSQL (not needed), Oracle (not needed), MySQL (not needed)

## Why It Matters

In MSSQL, every DML statement sends a `(N rows affected)` message to the client over TDS. In a procedure with 10 statements, that is 10 extra network round-trips of metadata the application never uses. These messages also confuse ORMs and data-access layers that expect only result sets, causing silent data-read failures. `SET NOCOUNT ON` suppresses these messages.

PostgreSQL (PL/pgSQL), Oracle (PL/SQL), and MySQL stored procedures do not send per-statement row-count messages by default, so no equivalent setting is needed. The row count is available programmatically when requested.

## Incorrect Code

### MSSQL
```sql
-- Bad: no SET NOCOUNT ON; every statement sends a row-count message
CREATE PROCEDURE dbo.UpdateOrderStatus
    @OrderID INT,
    @Status  VARCHAR(20)
AS
BEGIN
    UPDATE dbo.Orders SET Status = @Status WHERE OrderID = @OrderID;
    INSERT INTO dbo.OrderHistory (OrderID, Status, ChangedDate)
    VALUES (@OrderID, @Status, GETDATE());
    UPDATE dbo.Orders SET LastModified = GETDATE() WHERE OrderID = @OrderID;
    SELECT OrderID, Status, LastModified FROM dbo.Orders WHERE OrderID = @OrderID;
END;
-- Client receives: "1 row affected", "1 row affected", "1 row affected", then result set
```

### PostgreSQL
```sql
-- No incorrect pattern. PL/pgSQL does not send row-count messages.
-- GET DIAGNOSTICS is available if you need the count:
CREATE OR REPLACE FUNCTION update_order_status(p_id INT, p_status TEXT)
RETURNS VOID AS $$
DECLARE
    v_rows INT;
BEGIN
    UPDATE public.orders SET status = p_status WHERE order_id = p_id;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE NOTICE 'Updated % rows', v_rows;  -- only sent if client listens for NOTICEs
END;
$$ LANGUAGE plpgsql;
```

### Oracle
```sql
-- No incorrect pattern. PL/SQL does not send per-statement row counts.
-- SQL%ROWCOUNT is available after each DML:
CREATE OR REPLACE PROCEDURE update_order_status(
    p_id     IN NUMBER,
    p_status IN VARCHAR2
) AS
BEGIN
    UPDATE app.orders SET status = p_status WHERE order_id = p_id;
    DBMS_OUTPUT.PUT_LINE('Updated ' || SQL%ROWCOUNT || ' rows');
END;
/
```

### MySQL
```sql
-- No incorrect pattern. MySQL procedures do not send per-statement row counts.
-- ROW_COUNT() is available if needed:
CREATE PROCEDURE update_order_status(IN p_id INT, IN p_status VARCHAR(20))
BEGIN
    UPDATE orders SET status = p_status WHERE order_id = p_id;
    SELECT ROW_COUNT() AS rows_updated;  -- available on demand
END;
```

## Correct Code

### MSSQL
```sql
-- Good: SET NOCOUNT ON at the top of every procedure
CREATE PROCEDURE dbo.UpdateOrderStatus
    @OrderID INT,
    @Status  VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.Orders SET Status = @Status WHERE OrderID = @OrderID;

    INSERT INTO dbo.OrderHistory (OrderID, Status, ChangedDate)
    VALUES (@OrderID, @Status, GETDATE());

    UPDATE dbo.Orders SET LastModified = GETDATE() WHERE OrderID = @OrderID;

    SELECT OrderID, Status, LastModified
    FROM dbo.Orders
    WHERE OrderID = @OrderID;
END;
-- Client receives only the final SELECT result set

-- Good: capture row count when needed
CREATE PROCEDURE dbo.BulkUpdatePrices
    @CategoryID  INT,
    @NewPrice    DECIMAL(10,2),
    @RowsUpdated INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.Products
    SET Price = @NewPrice
    WHERE CategoryID = @CategoryID;

    SET @RowsUpdated = @@ROWCOUNT;
END;
```

### PostgreSQL
```sql
-- No action required. This is the default behavior.
-- Standard procedure template for reference:
CREATE OR REPLACE FUNCTION process_order(p_order_id INT)
RETURNS TABLE(order_id INT, status TEXT) AS $$
BEGIN
    UPDATE public.orders SET status = 'processing' WHERE order_id = p_order_id;
    RETURN QUERY SELECT o.order_id, o.status FROM public.orders o WHERE o.order_id = p_order_id;
END;
$$ LANGUAGE plpgsql;
```

### Oracle
```sql
-- No action required. This is the default behavior.
-- Standard procedure template for reference:
CREATE OR REPLACE PROCEDURE process_order(
    p_order_id IN NUMBER,
    p_cur      OUT SYS_REFCURSOR
) AS
BEGIN
    UPDATE app.orders SET status = 'processing' WHERE order_id = p_order_id;
    OPEN p_cur FOR SELECT order_id, status FROM app.orders WHERE order_id = p_order_id;
END;
/
```

### MySQL
```sql
-- No action required. This is the default behavior.
-- Standard procedure template for reference:
CREATE PROCEDURE process_order(IN p_order_id INT)
BEGIN
    UPDATE orders SET status = 'processing' WHERE order_id = p_order_id;
    SELECT order_id, status FROM orders WHERE order_id = p_order_id;
END;
```

## Application Code Detection

### Python

```python
# MSSQL (pyodbc): @@ROWCOUNT is still available via cursor.rowcount
cursor.execute("EXEC dbo.UpdateOrderStatus @OrderID=?, @Status=?", (order_id, status))
rows_affected = cursor.rowcount  # works even with SET NOCOUNT ON
```

### Node.js

```javascript
// MSSQL (mssql): rowsAffected is populated from the TDS done token
const result = await pool.request()
    .input('OrderID', sql.Int, orderId)
    .input('Status', sql.VarChar(20), status)
    .execute('dbo.UpdateOrderStatus');
console.log(result.rowsAffected);  // array of row counts per statement
```

### C#

```csharp
// MSSQL (SqlClient): ExecuteNonQuery returns row count regardless of NOCOUNT
using var cmd = new SqlCommand("dbo.UpdateOrderStatus", conn);
cmd.CommandType = CommandType.StoredProcedure;
cmd.Parameters.AddWithValue("@OrderID", orderId);
cmd.Parameters.AddWithValue("@Status", status);
int rows = await cmd.ExecuteNonQueryAsync();  // returns -1 with NOCOUNT ON
// Use OUTPUT parameter if you need the actual count
```

## Exceptions

- **Legacy systems** that parse `(N rows affected)` text output may require `SET NOCOUNT OFF`. This is rare and should be documented as tech debt.
- This rule applies only to MSSQL. PostgreSQL, Oracle, and MySQL do not require an equivalent setting.

## How to Detect

### MSSQL
```sql
-- Find stored procedures missing SET NOCOUNT ON
SELECT SCHEMA_NAME(o.schema_id) + '.' + o.name AS ProcedureName
FROM sys.objects o
JOIN sys.sql_modules m ON o.object_id = m.object_id
WHERE o.type = 'P'
  AND m.definition NOT LIKE '%SET NOCOUNT ON%'
ORDER BY ProcedureName;
```

### PostgreSQL
```sql
-- Not applicable. No equivalent setting needed.
SELECT 'N/A: PL/pgSQL does not send row-count messages by default' AS note;
```

### Oracle
```sql
-- Not applicable. No equivalent setting needed.
SELECT 'N/A: PL/SQL does not send row-count messages by default' AS note FROM DUAL;
```

### MySQL
```sql
-- Not applicable. No equivalent setting needed.
SELECT 'N/A: MySQL procedures do not send row-count messages by default' AS note;
```
