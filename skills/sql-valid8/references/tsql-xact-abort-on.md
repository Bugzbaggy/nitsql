# proc-transaction-handling
**Priority:** CRITICAL
**Category:** Procedural
**Applies to:** MSSQL, PostgreSQL, Oracle, MySQL

## Why It Matters

Improper transaction handling leaves orphaned transactions that hold locks indefinitely, blocking all other sessions. Each RDBMS has different default behaviors that can catch developers off guard:

- **MSSQL**: Without `SET XACT_ABORT ON`, client timeouts and certain errors do NOT roll back the open transaction.
- **PostgreSQL**: An error inside a transaction marks it as aborted; no further statements succeed until you `ROLLBACK`. Savepoints enable partial recovery.
- **Oracle**: DDL statements (`CREATE`, `ALTER`, `TRUNCATE`) issue an implicit `COMMIT` before and after execution, potentially committing incomplete work.
- **MySQL (InnoDB)**: DDL statements also cause implicit commits. `autocommit=1` is the default, meaning each statement is its own transaction unless you explicitly `START TRANSACTION`.

## Incorrect Code

### MSSQL
```sql
-- Bad: no XACT_ABORT; a client timeout leaves the transaction open
CREATE PROCEDURE dbo.ProcessPayment
    @OrderID INT,
    @Amount  DECIMAL(10,2)
AS
BEGIN
    SET NOCOUNT ON;
    -- SET XACT_ABORT ON is missing!

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE dbo.Orders SET PaymentStatus = 'Processing' WHERE OrderID = @OrderID;
        UPDATE dbo.Accounts SET Balance = Balance - @Amount WHERE OrderID = @OrderID;
        -- If a query timeout fires here, the transaction stays OPEN and holds locks
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
```

### PostgreSQL
```sql
-- Bad: no error handling; if the UPDATE fails the transaction is aborted
-- and the subsequent INSERT silently errors out
CREATE OR REPLACE FUNCTION process_payment(p_order_id INT, p_amount NUMERIC)
RETURNS VOID AS $$
BEGIN
    UPDATE app.orders SET payment_status = 'processing' WHERE order_id = p_order_id;
    UPDATE app.accounts SET balance = balance - p_amount WHERE order_id = p_order_id;
    -- If the second UPDATE fails, the function aborts but the caller may not know
END;
$$ LANGUAGE plpgsql;
```

### Oracle
```sql
-- Bad: DDL inside a transaction commits partial work
CREATE OR REPLACE PROCEDURE process_payment(
    p_order_id IN NUMBER,
    p_amount   IN NUMBER
) AS
BEGIN
    UPDATE app.orders SET payment_status = 'processing' WHERE order_id = p_order_id;
    UPDATE app.accounts SET balance = balance - p_amount WHERE order_id = p_order_id;

    -- DANGER: This DDL causes an implicit COMMIT of the two UPDATEs above,
    -- even if you intended to roll back on failure later
    EXECUTE IMMEDIATE 'CREATE TABLE app.temp_log AS SELECT * FROM app.audit_log';
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;  -- too late: the implicit COMMIT already fired
        RAISE;
END;
/
```

### MySQL
```sql
-- Bad: DDL inside a transaction commits partial work
CREATE PROCEDURE process_payment(IN p_order_id INT, IN p_amount DECIMAL(10,2))
BEGIN
    START TRANSACTION;
    UPDATE orders SET payment_status = 'processing' WHERE order_id = p_order_id;
    UPDATE accounts SET balance = balance - p_amount WHERE order_id = p_order_id;

    -- DANGER: TRUNCATE causes an implicit COMMIT of the two UPDATEs
    TRUNCATE TABLE temp_log;

    COMMIT;  -- this commit is redundant; the TRUNCATE already committed
END;
```

## Correct Code

### MSSQL
```sql
-- Good: SET XACT_ABORT ON guarantees immediate rollback on any error
CREATE PROCEDURE dbo.ProcessPayment
    @OrderID INT,
    @Amount  DECIMAL(10,2)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE dbo.Orders SET PaymentStatus = 'Processing' WHERE OrderID = @OrderID;
        UPDATE dbo.Accounts SET Balance = Balance - @Amount WHERE OrderID = @OrderID;

        INSERT INTO dbo.PaymentLog (OrderID, Amount, ProcessedDate)
        VALUES (@OrderID, @Amount, SYSUTCDATETIME());

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
```

### PostgreSQL
```sql
-- Good: EXCEPTION block auto-rolls back the subtransaction (implicit savepoint)
CREATE OR REPLACE FUNCTION process_payment(p_order_id INT, p_amount NUMERIC)
RETURNS VOID AS $$
BEGIN
    UPDATE app.orders SET payment_status = 'processing' WHERE order_id = p_order_id;
    UPDATE app.accounts SET balance = balance - p_amount WHERE order_id = p_order_id;

    INSERT INTO app.payment_log (order_id, amount, processed_at)
    VALUES (p_order_id, p_amount, NOW());
EXCEPTION
    WHEN OTHERS THEN
        -- The subtransaction is automatically rolled back
        RAISE EXCEPTION 'Payment failed for order %: %', p_order_id, SQLERRM;
END;
$$ LANGUAGE plpgsql;

-- Good: explicit savepoints for partial rollback
CREATE OR REPLACE FUNCTION process_batch(p_ids INT[])
RETURNS VOID AS $$
DECLARE
    v_id INT;
BEGIN
    FOREACH v_id IN ARRAY p_ids LOOP
        BEGIN
            PERFORM process_single_order(v_id);
        EXCEPTION
            WHEN OTHERS THEN
                RAISE WARNING 'Order % failed: %', v_id, SQLERRM;
                -- Continues with next item; failed subtransaction is rolled back
        END;
    END LOOP;
END;
$$ LANGUAGE plpgsql;
```

### Oracle
```sql
-- Good: explicit error handling; never mix DDL with DML transactions
CREATE OR REPLACE PROCEDURE process_payment(
    p_order_id IN NUMBER,
    p_amount   IN NUMBER
) AS
BEGIN
    SAVEPOINT before_payment;

    UPDATE app.orders SET payment_status = 'processing' WHERE order_id = p_order_id;
    UPDATE app.accounts SET balance = balance - p_amount WHERE order_id = p_order_id;

    INSERT INTO app.payment_log (order_id, amount, processed_at)
    VALUES (p_order_id, p_amount, SYSTIMESTAMP);

    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK TO before_payment;
        RAISE_APPLICATION_ERROR(-20001, 'Payment failed for order '
            || p_order_id || ': ' || SQLERRM);
END;
/

-- WARNING: Never put DDL inside a DML transaction in Oracle.
-- DDL (CREATE, ALTER, DROP, TRUNCATE) issues an implicit COMMIT.
-- Separate DDL operations into their own procedure calls.
```

### MySQL
```sql
-- Good: explicit transaction with DECLARE HANDLER for rollback
CREATE PROCEDURE process_payment(IN p_order_id INT, IN p_amount DECIMAL(10,2))
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    UPDATE orders SET payment_status = 'processing' WHERE order_id = p_order_id;
    UPDATE accounts SET balance = balance - p_amount WHERE order_id = p_order_id;

    INSERT INTO payment_log (order_id, amount, processed_at)
    VALUES (p_order_id, p_amount, NOW());

    COMMIT;
END;

-- WARNING: Never put DDL (CREATE, ALTER, DROP, TRUNCATE) inside a transaction in MySQL.
-- DDL causes an implicit COMMIT of any pending work.
-- Separate DDL operations from DML transactions.
```

## DDL Auto-Commit Reference

| Operation | MSSQL | PostgreSQL | Oracle | MySQL |
|---|---|---|---|---|
| CREATE TABLE | Transactional | Transactional | IMPLICIT COMMIT | IMPLICIT COMMIT |
| ALTER TABLE | Transactional | Transactional | IMPLICIT COMMIT | IMPLICIT COMMIT |
| DROP TABLE | Transactional | Transactional | IMPLICIT COMMIT | IMPLICIT COMMIT |
| TRUNCATE | Transactional | Transactional | IMPLICIT COMMIT | IMPLICIT COMMIT |
| CREATE INDEX | Transactional | Transactional | IMPLICIT COMMIT | IMPLICIT COMMIT |

MSSQL and PostgreSQL support transactional DDL. Oracle and MySQL do not.

## Application Code Detection

### Python

```python
# --- MSSQL (pyodbc) ---
# Bad: no transaction management
cursor.execute("UPDATE dbo.Orders SET Status = 'paid' WHERE OrderID = ?", (oid,))
cursor.execute("UPDATE dbo.Accounts SET Balance = Balance - ? WHERE OrderID = ?", (amt, oid))
conn.commit()  # if second UPDATE fails, first is already committed (autocommit per statement)

# Good: explicit transaction
conn.autocommit = False
try:
    cursor.execute("UPDATE dbo.Orders SET Status = 'paid' WHERE OrderID = ?", (oid,))
    cursor.execute("UPDATE dbo.Accounts SET Balance = Balance - ? WHERE OrderID = ?", (amt, oid))
    conn.commit()
except Exception:
    conn.rollback()
    raise

# --- PostgreSQL (psycopg2) ---
# Good: psycopg2 auto-begins a transaction; just commit or rollback
try:
    cur.execute("UPDATE app.orders SET status = 'paid' WHERE order_id = %s", (oid,))
    cur.execute("UPDATE app.accounts SET balance = balance - %s WHERE order_id = %s", (amt, oid))
    conn.commit()
except Exception:
    conn.rollback()
    raise
```

### Node.js

```javascript
// --- MSSQL (mssql) ---
const transaction = pool.transaction();
await transaction.begin();
try {
    await transaction.request()
        .input('oid', sql.Int, orderId)
        .query('UPDATE dbo.Orders SET Status = \'paid\' WHERE OrderID = @oid');
    await transaction.request()
        .input('amt', sql.Decimal(10,2), amount)
        .input('oid', sql.Int, orderId)
        .query('UPDATE dbo.Accounts SET Balance = Balance - @amt WHERE OrderID = @oid');
    await transaction.commit();
} catch (err) {
    await transaction.rollback();
    throw err;
}

// --- PostgreSQL (pg) ---
const client = await pgPool.connect();
try {
    await client.query('BEGIN');
    await client.query('UPDATE app.orders SET status = $1 WHERE order_id = $2', ['paid', orderId]);
    await client.query('UPDATE app.accounts SET balance = balance - $1 WHERE order_id = $2', [amount, orderId]);
    await client.query('COMMIT');
} catch (err) {
    await client.query('ROLLBACK');
    throw err;
} finally {
    client.release();
}
```

### C#

```csharp
// --- MSSQL (SqlClient) ---
using var conn = new SqlConnection(connectionString);
await conn.OpenAsync();
using var tx = conn.BeginTransaction();
try
{
    using var cmd1 = new SqlCommand("UPDATE dbo.Orders SET Status = 'paid' WHERE OrderID = @id", conn, tx);
    cmd1.Parameters.AddWithValue("@id", orderId);
    await cmd1.ExecuteNonQueryAsync();

    using var cmd2 = new SqlCommand("UPDATE dbo.Accounts SET Balance = Balance - @amt WHERE OrderID = @id", conn, tx);
    cmd2.Parameters.AddWithValue("@amt", amount);
    cmd2.Parameters.AddWithValue("@id", orderId);
    await cmd2.ExecuteNonQueryAsync();

    await tx.CommitAsync();
}
catch
{
    await tx.RollbackAsync();
    throw;
}
```

## Exceptions

- **Read-only procedures** (SELECT only) do not need explicit transaction handling, but `SET XACT_ABORT ON` is still harmless and recommended in MSSQL.
- **Single-statement DML** in PostgreSQL and MySQL is auto-committed by default and does not need `BEGIN/COMMIT`.
- **Intentional partial commits** in Oracle (using `COMMIT` mid-procedure) are valid when each step is independently meaningful (e.g., logging audit records that must persist regardless of later failures).

## How to Detect

### MSSQL
```sql
-- Procedures with BEGIN TRANSACTION but no SET XACT_ABORT ON
SELECT SCHEMA_NAME(o.schema_id) + '.' + o.name AS ProcedureName
FROM sys.objects o
JOIN sys.sql_modules m ON o.object_id = m.object_id
WHERE o.type = 'P'
  AND m.definition LIKE '%BEGIN TRAN%'
  AND m.definition NOT LIKE '%SET XACT_ABORT ON%'
ORDER BY ProcedureName;
```

### PostgreSQL
```sql
-- Functions with DML but no EXCEPTION block
SELECT n.nspname || '.' || p.proname AS func_name
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND pg_get_functiondef(p.oid) ~* '(INSERT|UPDATE|DELETE)'
  AND pg_get_functiondef(p.oid) NOT LIKE '%EXCEPTION%'
ORDER BY func_name;
```

### Oracle
```sql
-- Procedures with DML but no EXCEPTION block
SELECT owner || '.' || name AS object_name
FROM (
    SELECT DISTINCT owner, name
    FROM all_source
    WHERE type IN ('PROCEDURE', 'FUNCTION', 'PACKAGE BODY')
      AND UPPER(text) LIKE '%UPDATE %'
    MINUS
    SELECT DISTINCT owner, name
    FROM all_source
    WHERE type IN ('PROCEDURE', 'FUNCTION', 'PACKAGE BODY')
      AND UPPER(text) LIKE '%EXCEPTION%'
)
ORDER BY object_name;
```

### MySQL
```sql
-- Procedures with START TRANSACTION but no HANDLER
SELECT ROUTINE_SCHEMA, ROUTINE_NAME
FROM information_schema.ROUTINES
WHERE ROUTINE_DEFINITION LIKE '%START TRANSACTION%'
  AND ROUTINE_DEFINITION NOT LIKE '%HANDLER%'
  AND ROUTINE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
ORDER BY ROUTINE_SCHEMA, ROUTINE_NAME;
```
