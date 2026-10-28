# proc-error-handling
**Priority:** CRITICAL
**Category:** Procedural
**Applies to:** MSSQL, PostgreSQL, Oracle, MySQL

## Why It Matters

Unhandled errors in stored procedures cause silent data corruption: half of a multi-step operation succeeds while the other half fails, leaving the database in an inconsistent state. In MSSQL, unhandled errors inside a transaction can leave the transaction open, holding locks and blocking all other sessions. Every procedure that modifies data must have explicit error handling that logs the failure and ensures a clean rollback.

## Incorrect Code

### MSSQL
```sql
-- Bad: no error handling; if the second UPDATE fails, the first is already committed
CREATE PROCEDURE dbo.TransferFunds
    @FromAccount INT,
    @ToAccount   INT,
    @Amount      DECIMAL(10,2)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRANSACTION;
    UPDATE dbo.Accounts SET Balance = Balance - @Amount WHERE AccountID = @FromAccount;
    UPDATE dbo.Accounts SET Balance = Balance + @Amount WHERE AccountID = @ToAccount;
    COMMIT TRANSACTION;
END;
```

### PostgreSQL
```sql
-- Bad: no EXCEPTION block; error aborts the function and the caller's transaction
CREATE OR REPLACE FUNCTION transfer_funds(
    p_from INT, p_to INT, p_amount NUMERIC
) RETURNS VOID AS $$
BEGIN
    UPDATE app.accounts SET balance = balance - p_amount WHERE account_id = p_from;
    UPDATE app.accounts SET balance = balance + p_amount WHERE account_id = p_to;
END;
$$ LANGUAGE plpgsql;
```

### Oracle
```sql
-- Bad: no EXCEPTION block; unhandled error propagates with cryptic ORA- code
CREATE OR REPLACE PROCEDURE transfer_funds(
    p_from   IN NUMBER,
    p_to     IN NUMBER,
    p_amount IN NUMBER
) AS
BEGIN
    UPDATE app.accounts SET balance = balance - p_amount WHERE account_id = p_from;
    UPDATE app.accounts SET balance = balance + p_amount WHERE account_id = p_to;
    COMMIT;
END;
/
```

### MySQL
```sql
-- Bad: no HANDLER; error causes partial commit (if autocommit is ON) or leaves
-- transaction in unknown state
CREATE PROCEDURE transfer_funds(
    IN p_from INT, IN p_to INT, IN p_amount DECIMAL(10,2)
)
BEGIN
    START TRANSACTION;
    UPDATE accounts SET balance = balance - p_amount WHERE account_id = p_from;
    UPDATE accounts SET balance = balance + p_amount WHERE account_id = p_to;
    COMMIT;
END;
```

## Correct Code

### MSSQL
```sql
-- Good: TRY...CATCH with XACT_ABORT, THROW, and error logging
CREATE PROCEDURE dbo.TransferFunds
    @FromAccount INT,
    @ToAccount   INT,
    @Amount      DECIMAL(10,2)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Validate inputs
        IF @Amount <= 0
            THROW 50001, 'Transfer amount must be positive', 1;

        IF NOT EXISTS (SELECT 1 FROM dbo.Accounts WHERE AccountID = @FromAccount)
            THROW 50002, 'Source account not found', 1;

        IF NOT EXISTS (SELECT 1 FROM dbo.Accounts WHERE AccountID = @ToAccount)
            THROW 50003, 'Destination account not found', 1;

        -- Debit
        UPDATE dbo.Accounts
        SET Balance = Balance - @Amount
        WHERE AccountID = @FromAccount;

        IF @@ROWCOUNT = 0
            THROW 50004, 'Debit failed: account not found or no update', 1;

        -- Credit
        UPDATE dbo.Accounts
        SET Balance = Balance + @Amount
        WHERE AccountID = @ToAccount;

        IF @@ROWCOUNT = 0
            THROW 50005, 'Credit failed: account not found or no update', 1;

        -- Audit log
        INSERT INTO dbo.TransferLog (FromAccount, ToAccount, Amount, TransferDate)
        VALUES (@FromAccount, @ToAccount, @Amount, SYSUTCDATETIME());

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        -- Log the error
        INSERT INTO dbo.ErrorLog (ErrorNumber, ErrorMessage, ErrorProcedure, ErrorLine, ErrorDate)
        VALUES (ERROR_NUMBER(), ERROR_MESSAGE(), ERROR_PROCEDURE(), ERROR_LINE(), SYSUTCDATETIME());

        THROW;  -- re-raise the original error to the caller
    END CATCH
END;
```

### PostgreSQL
```sql
-- Good: EXCEPTION block with RAISE EXCEPTION and logging
CREATE OR REPLACE FUNCTION transfer_funds(
    p_from   INT,
    p_to     INT,
    p_amount NUMERIC
) RETURNS VOID AS $$
DECLARE
    v_rows INT;
BEGIN
    -- Validate
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Transfer amount must be positive: %', p_amount;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM app.accounts WHERE account_id = p_from) THEN
        RAISE EXCEPTION 'Source account % not found', p_from;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM app.accounts WHERE account_id = p_to) THEN
        RAISE EXCEPTION 'Destination account % not found', p_to;
    END IF;

    -- Debit
    UPDATE app.accounts SET balance = balance - p_amount WHERE account_id = p_from;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows = 0 THEN
        RAISE EXCEPTION 'Debit failed for account %', p_from;
    END IF;

    -- Credit
    UPDATE app.accounts SET balance = balance + p_amount WHERE account_id = p_to;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows = 0 THEN
        RAISE EXCEPTION 'Credit failed for account %', p_to;
    END IF;

    -- Audit
    INSERT INTO app.transfer_log (from_account, to_account, amount, transfer_date)
    VALUES (p_from, p_to, p_amount, NOW());

EXCEPTION
    WHEN OTHERS THEN
        -- Log the error (the subtransaction is auto-rolled back)
        INSERT INTO app.error_log (error_message, error_detail, error_context, error_date)
        VALUES (SQLERRM, SQLSTATE, 'transfer_funds', NOW());
        RAISE;  -- re-raise to the caller
END;
$$ LANGUAGE plpgsql;
```

### Oracle
```sql
-- Good: EXCEPTION with RAISE_APPLICATION_ERROR and logging
CREATE OR REPLACE PROCEDURE transfer_funds(
    p_from   IN NUMBER,
    p_to     IN NUMBER,
    p_amount IN NUMBER
) AS
    v_rows NUMBER;
BEGIN
    -- Validate
    IF p_amount <= 0 THEN
        RAISE_APPLICATION_ERROR(-20001, 'Transfer amount must be positive: ' || p_amount);
    END IF;

    -- Debit
    UPDATE app.accounts SET balance = balance - p_amount WHERE account_id = p_from;
    v_rows := SQL%ROWCOUNT;
    IF v_rows = 0 THEN
        RAISE_APPLICATION_ERROR(-20002, 'Source account not found: ' || p_from);
    END IF;

    -- Credit
    UPDATE app.accounts SET balance = balance + p_amount WHERE account_id = p_to;
    v_rows := SQL%ROWCOUNT;
    IF v_rows = 0 THEN
        RAISE_APPLICATION_ERROR(-20003, 'Destination account not found: ' || p_to);
    END IF;

    -- Audit
    INSERT INTO app.transfer_log (from_account, to_account, amount, transfer_date)
    VALUES (p_from, p_to, p_amount, SYSTIMESTAMP);

    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        -- Log the error using an autonomous transaction so the log persists
        log_error(SQLCODE, SQLERRM, 'transfer_funds');
        RAISE;  -- re-raise to the caller
END;
/

-- Autonomous transaction logging procedure (Oracle-specific)
CREATE OR REPLACE PROCEDURE log_error(
    p_code    IN NUMBER,
    p_message IN VARCHAR2,
    p_source  IN VARCHAR2
) AS
    PRAGMA AUTONOMOUS_TRANSACTION;
BEGIN
    INSERT INTO app.error_log (error_code, error_message, error_source, error_date)
    VALUES (p_code, p_message, p_source, SYSTIMESTAMP);
    COMMIT;
END;
/
```

### MySQL
```sql
-- Good: DECLARE HANDLER with SIGNAL and logging
CREATE PROCEDURE transfer_funds(
    IN p_from   INT,
    IN p_to     INT,
    IN p_amount DECIMAL(10,2)
)
BEGIN
    DECLARE v_rows INT DEFAULT 0;
    DECLARE v_error_msg TEXT;

    -- Exit handler: rollback and re-signal on any error
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_error_msg = MESSAGE_TEXT;
        ROLLBACK;
        -- Log the error
        INSERT INTO error_log (error_message, error_source, error_date)
        VALUES (v_error_msg, 'transfer_funds', NOW());
        RESIGNAL;
    END;

    -- Validate
    IF p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transfer amount must be positive';
    END IF;

    START TRANSACTION;

    -- Debit
    UPDATE accounts SET balance = balance - p_amount WHERE account_id = p_from;
    SET v_rows = ROW_COUNT();
    IF v_rows = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Source account not found';
    END IF;

    -- Credit
    UPDATE accounts SET balance = balance + p_amount WHERE account_id = p_to;
    SET v_rows = ROW_COUNT();
    IF v_rows = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Destination account not found';
    END IF;

    -- Audit
    INSERT INTO transfer_log (from_account, to_account, amount, transfer_date)
    VALUES (p_from, p_to, p_amount, NOW());

    COMMIT;
END;
```

## Error Handling Comparison

| Feature | MSSQL | PostgreSQL | Oracle | MySQL |
|---|---|---|---|---|
| Error block | `BEGIN TRY...END CATCH` | `EXCEPTION WHEN...THEN` | `EXCEPTION WHEN...THEN` | `DECLARE HANDLER` |
| Raise custom error | `THROW 50001, 'msg', 1` | `RAISE EXCEPTION 'msg'` | `RAISE_APPLICATION_ERROR(-20001, 'msg')` | `SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'msg'` |
| Re-raise | `THROW` (no args) | `RAISE` (no args) | `RAISE` | `RESIGNAL` |
| Get error info | `ERROR_NUMBER()`, `ERROR_MESSAGE()` | `SQLERRM`, `SQLSTATE` | `SQLCODE`, `SQLERRM` | `GET DIAGNOSTICS CONDITION 1` |
| Row count | `@@ROWCOUNT` | `GET DIAGNOSTICS v = ROW_COUNT` | `SQL%ROWCOUNT` | `ROW_COUNT()` |

## Application Code Detection

### Python

```python
# Good pattern for all dialects: catch and log at the application layer too
try:
    cursor.execute("CALL transfer_funds(%s, %s, %s)", (from_id, to_id, amount))
    conn.commit()
except Exception as e:
    conn.rollback()
    logger.error("Transfer failed: from=%s to=%s amount=%s error=%s", from_id, to_id, amount, e)
    raise
```

### Node.js

```javascript
// Good: wrap in try/catch with transaction management
try {
    await client.query('BEGIN');
    await client.query('SELECT app.transfer_funds($1, $2, $3)', [fromId, toId, amount]);
    await client.query('COMMIT');
} catch (err) {
    await client.query('ROLLBACK');
    logger.error({ fromId, toId, amount, err }, 'Transfer failed');
    throw err;
}
```

### C#

```csharp
// Good: wrap in try/catch with transaction
using var tx = await conn.BeginTransactionAsync();
try
{
    using var cmd = new SqlCommand("dbo.TransferFunds", conn, tx)
    {
        CommandType = CommandType.StoredProcedure
    };
    cmd.Parameters.AddWithValue("@FromAccount", fromId);
    cmd.Parameters.AddWithValue("@ToAccount", toId);
    cmd.Parameters.AddWithValue("@Amount", amount);
    await cmd.ExecuteNonQueryAsync();
    await tx.CommitAsync();
}
catch (Exception ex)
{
    await tx.RollbackAsync();
    _logger.LogError(ex, "Transfer failed: {From} -> {To}, {Amount}", fromId, toId, amount);
    throw;
}
```

## Error Handling Principles (All Dialects)

1. **Never swallow errors silently.** Every CATCH/EXCEPTION block must either re-raise the error or log it explicitly. Oracle's `WHEN OTHERS THEN NULL` is the most dangerous anti-pattern.
2. **Always rollback on error.** If a transaction is open, the error handler must rollback before re-raising. MSSQL requires `IF @@TRANCOUNT > 0 ROLLBACK`; PostgreSQL auto-rolls back the subtransaction; Oracle and MySQL require explicit `ROLLBACK`.
3. **Log before re-raising.** Insert the error details into an audit/error table before re-raising. In Oracle, use an `AUTONOMOUS_TRANSACTION` logger so the log persists even after rollback.
4. **Include context in error messages.** Include the procedure name, parameters, and the original error message/code. This saves hours of debugging.
5. **Keep error handling consistent.** Use the same pattern in every procedure within a project.

## Error Handling Comparison

| Feature | MSSQL | PostgreSQL | Oracle | MySQL |
|---------|-------|------------|--------|-------|
| **Mechanism** | `TRY...CATCH` | `EXCEPTION WHEN` | `EXCEPTION WHEN` | `DECLARE HANDLER` |
| **Auto-rollback** | No (must check `@@TRANCOUNT`) | Yes (subtransaction in functions) | No (must explicitly `ROLLBACK`) | No (must explicitly `ROLLBACK`) |
| **Re-raise** | `THROW` | `RAISE` | `RAISE` or `RAISE_APPLICATION_ERROR` | `RESIGNAL` |
| **Error info** | `ERROR_NUMBER()`, `ERROR_MESSAGE()`, `ERROR_LINE()` | `SQLSTATE`, `SQLERRM`, `GET STACKED DIAGNOSTICS` | `SQLCODE`, `SQLERRM` | `GET DIAGNOSTICS CONDITION 1` |
| **Custom errors** | `THROW 50001, 'msg', 1` | `RAISE EXCEPTION 'msg'` | `RAISE_APPLICATION_ERROR(-20001, 'msg')` | `SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'msg'` |

## Exceptions

- **Read-only functions/procedures** that contain only SELECT statements do not need ROLLBACK logic, but EXCEPTION blocks for logging unexpected errors are still recommended.
- **Fire-and-forget logging** procedures may intentionally suppress errors (e.g., Oracle's autonomous transaction logger above). Document this clearly.
- **Retry logic** for deadlocks and timeouts belongs in the application layer, not inside the stored procedure.

## How to Detect

### MSSQL
```sql
-- Procedures with transactions but no TRY...CATCH
SELECT SCHEMA_NAME(o.schema_id) + '.' + o.name AS ProcedureName
FROM sys.objects o
JOIN sys.sql_modules m ON o.object_id = m.object_id
WHERE o.type = 'P'
  AND m.definition LIKE '%BEGIN TRAN%'
  AND m.definition NOT LIKE '%BEGIN TRY%'
ORDER BY ProcedureName;
```

### PostgreSQL
```sql
-- Functions with DML but no EXCEPTION block
SELECT n.nspname || '.' || p.proname AS func_name
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND pg_get_functiondef(p.oid) ~* '(INSERT|UPDATE|DELETE)\s'
  AND pg_get_functiondef(p.oid) NOT LIKE '%EXCEPTION%'
ORDER BY func_name;
```

### Oracle
```sql
-- Procedures with DML but no EXCEPTION handler
SELECT DISTINCT owner || '.' || name AS object_name
FROM all_source
WHERE type IN ('PROCEDURE', 'FUNCTION', 'PACKAGE BODY')
  AND (UPPER(text) LIKE '%UPDATE %' OR UPPER(text) LIKE '%INSERT %' OR UPPER(text) LIKE '%DELETE %')
  AND owner NOT IN ('SYS', 'SYSTEM')
MINUS
SELECT DISTINCT owner || '.' || name
FROM all_source
WHERE type IN ('PROCEDURE', 'FUNCTION', 'PACKAGE BODY')
  AND UPPER(text) LIKE '%EXCEPTION%'
  AND owner NOT IN ('SYS', 'SYSTEM');
```

### MySQL
```sql
-- Procedures with DML but no HANDLER
SELECT ROUTINE_SCHEMA, ROUTINE_NAME
FROM information_schema.ROUTINES
WHERE ROUTINE_TYPE = 'PROCEDURE'
  AND (ROUTINE_DEFINITION LIKE '%UPDATE %'
       OR ROUTINE_DEFINITION LIKE '%INSERT %'
       OR ROUTINE_DEFINITION LIKE '%DELETE %')
  AND ROUTINE_DEFINITION NOT LIKE '%HANDLER%'
  AND ROUTINE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
ORDER BY ROUTINE_SCHEMA, ROUTINE_NAME;
```
