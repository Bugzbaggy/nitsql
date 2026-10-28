# Error Handling Patterns

Multi-dialect error handling covering SQL Server, PostgreSQL, Oracle, MySQL, and SQLite. Includes transaction management, retry patterns for transient errors, and error logging.

## Why Error Handling Matters

Unhandled errors in stored procedures cause silent data corruption: half of a multi-step operation succeeds while the other half fails, leaving the database in an inconsistent state. In SQL Server, unhandled errors inside a transaction can leave the transaction open, holding locks and blocking all other sessions.

## Error Handling Comparison

| Feature | PostgreSQL | MySQL | SQL Server | Oracle | SQLite |
|---------|-----------|-------|------------|--------|--------|
| Error block | `EXCEPTION WHEN...THEN` | `DECLARE HANDLER` | `BEGIN TRY...END CATCH` | `EXCEPTION WHEN...THEN` | Application-level |
| Raise custom error | `RAISE EXCEPTION 'msg'` | `SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='msg'` | `THROW 50001, 'msg', 1` | `RAISE_APPLICATION_ERROR(-20001, 'msg')` | Application-level |
| Re-raise | `RAISE` (no args) | `RESIGNAL` | `THROW` (no args) | `RAISE` (no args) | Application-level |
| Get error info | `SQLSTATE`, `SQLERRM` | `GET DIAGNOSTICS CONDITION 1` | `ERROR_NUMBER()`, `ERROR_MESSAGE()`, `ERROR_LINE()` | `SQLCODE`, `SQLERRM` | Return code / exception |
| Row count after DML | `GET DIAGNOSTICS v = ROW_COUNT` | `ROW_COUNT()` | `@@ROWCOUNT` | `SQL%ROWCOUNT` | `changes()` |
| Auto-rollback on error | Yes (subtransaction in functions) | No (must explicit `ROLLBACK`) | No (must check `@@TRANCOUNT`) | No (must explicit `ROLLBACK`) | No (application-level) |

## SQL Server: TRY...CATCH with XACT_ABORT

```sql
CREATE PROCEDURE dbo.TransferFunds
    @FromAccount INT,
    @ToAccount   INT,
    @Amount      DECIMAL(10,2)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;  -- Auto-rollback on timeout/severe errors

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
            THROW 50004, 'Debit failed: no rows updated', 1;

        -- Credit
        UPDATE dbo.Accounts
        SET Balance = Balance + @Amount
        WHERE AccountID = @ToAccount;

        IF @@ROWCOUNT = 0
            THROW 50005, 'Credit failed: no rows updated', 1;

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

        THROW;  -- Re-raise the original error to the caller
    END CATCH
END;
```

### SQL Server Error Functions Reference

| Function | Returns |
|----------|---------|
| `ERROR_NUMBER()` | Error number (e.g., 547 for FK violation, 2627 for unique key violation) |
| `ERROR_MESSAGE()` | Full error message text |
| `ERROR_SEVERITY()` | Severity level (0-25) |
| `ERROR_STATE()` | Error state number |
| `ERROR_PROCEDURE()` | Name of the procedure where the error occurred |
| `ERROR_LINE()` | Line number where the error occurred |

### SQL Server: Handling Specific Error Numbers

```sql
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    DECLARE @ErrorNumber INT = ERROR_NUMBER();

    IF @ErrorNumber = 1205  -- Deadlock
    BEGIN
        -- Log and let caller retry
        INSERT INTO dbo.ErrorLog (ErrorNumber, ErrorMessage, ErrorProcedure, ErrorDate)
        VALUES (@ErrorNumber, 'Deadlock detected', ERROR_PROCEDURE(), SYSUTCDATETIME());
        THROW 50010, 'Deadlock detected. Please retry the operation.', 1;
    END
    ELSE IF @ErrorNumber = 2627  -- Unique constraint violation
    BEGIN
        THROW 50011, 'Duplicate record already exists.', 1;
    END
    ELSE IF @ErrorNumber = 547  -- Foreign key violation
    BEGIN
        THROW 50012, 'Referenced record not found or cannot be deleted.', 1;
    END
    ELSE
    BEGIN
        -- Unknown error: log and re-raise
        INSERT INTO dbo.ErrorLog (ErrorNumber, ErrorMessage, ErrorProcedure, ErrorLine, ErrorDate)
        VALUES (ERROR_NUMBER(), ERROR_MESSAGE(), ERROR_PROCEDURE(), ERROR_LINE(), SYSUTCDATETIME());
        THROW;
    END
END CATCH
```

## PostgreSQL: BEGIN...EXCEPTION WHEN

```sql
CREATE OR REPLACE FUNCTION app.transfer_funds(
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
        -- The subtransaction inside EXCEPTION is auto-rolled back
        INSERT INTO app.error_log (error_message, error_detail, error_context, error_date)
        VALUES (SQLERRM, SQLSTATE, 'transfer_funds', NOW());
        RAISE;  -- Re-raise to the caller
END;
$$ LANGUAGE plpgsql;
```

### PostgreSQL: Handling Specific SQLSTATE Codes

```sql
EXCEPTION
    WHEN unique_violation THEN  -- SQLSTATE 23505
        RAISE NOTICE 'Record already exists: %', SQLERRM;
        -- Handle duplicate gracefully
    WHEN foreign_key_violation THEN  -- SQLSTATE 23503
        RAISE EXCEPTION 'Referenced record not found';
    WHEN check_violation THEN  -- SQLSTATE 23514
        RAISE EXCEPTION 'Data validation failed: %', SQLERRM;
    WHEN serialization_failure THEN  -- SQLSTATE 40001 (deadlock)
        RAISE EXCEPTION 'Deadlock detected. Please retry.';
    WHEN OTHERS THEN
        INSERT INTO app.error_log (error_message, error_detail, error_date)
        VALUES (SQLERRM, SQLSTATE, NOW());
        RAISE;
```

### PostgreSQL: RAISE Levels

```sql
-- DEBUG (lowest): only visible when client_min_messages = debug
RAISE DEBUG 'Processing row %', v_id;

-- LOG: written to server log but not sent to client by default
RAISE LOG 'Batch processed % rows', v_count;

-- NOTICE: informational message sent to the client
RAISE NOTICE 'Transfer completed: % from account % to %', p_amount, p_from, p_to;

-- WARNING: warning sent to client
RAISE WARNING 'Account % has low balance: %', p_from, v_balance;

-- EXCEPTION (highest): aborts the current transaction/subtransaction
RAISE EXCEPTION 'Insufficient funds in account %', p_from
    USING ERRCODE = '22004',       -- Optional: custom SQLSTATE
          HINT = 'Check account balance before transfer',
          DETAIL = format('Balance: %s, Requested: %s', v_balance, p_amount);
```

### PostgreSQL: GET STACKED DIAGNOSTICS for Full Error Details

```sql
EXCEPTION
    WHEN OTHERS THEN
        DECLARE
            v_state TEXT;
            v_msg   TEXT;
            v_detail TEXT;
            v_hint   TEXT;
            v_context TEXT;
        BEGIN
            GET STACKED DIAGNOSTICS
                v_state   = RETURNED_SQLSTATE,
                v_msg     = MESSAGE_TEXT,
                v_detail  = PG_EXCEPTION_DETAIL,
                v_hint    = PG_EXCEPTION_HINT,
                v_context = PG_EXCEPTION_CONTEXT;

            INSERT INTO app.error_log (sqlstate, message, detail, hint, context, error_date)
            VALUES (v_state, v_msg, v_detail, v_hint, v_context, NOW());

            RAISE;
        END;
```

## Oracle: PL/SQL EXCEPTION Blocks

```sql
CREATE OR REPLACE PROCEDURE app.transfer_funds(
    p_from   IN NUMBER,
    p_to     IN NUMBER,
    p_amount IN NUMBER
) AS
    v_rows NUMBER;
    e_insufficient_funds EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_insufficient_funds, -20010);
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
    WHEN DUP_VAL_ON_INDEX THEN  -- ORA-00001: unique constraint violated
        ROLLBACK;
        log_error(SQLCODE, 'Duplicate transfer detected', 'transfer_funds');
        RAISE;
    WHEN e_insufficient_funds THEN
        ROLLBACK;
        log_error(SQLCODE, SQLERRM, 'transfer_funds');
        RAISE;
    WHEN OTHERS THEN
        ROLLBACK;
        -- Log the error using an autonomous transaction so the log persists
        log_error(SQLCODE, SQLERRM, 'transfer_funds');
        RAISE;  -- Re-raise to the caller
END;
/
```

### Oracle: Autonomous Transaction Logger

```sql
-- Autonomous transaction ensures log persists even after ROLLBACK
CREATE OR REPLACE PROCEDURE app.log_error(
    p_code    IN NUMBER,
    p_message IN VARCHAR2,
    p_source  IN VARCHAR2
) AS
    PRAGMA AUTONOMOUS_TRANSACTION;
BEGIN
    INSERT INTO app.error_log (error_code, error_message, error_source, error_date)
    VALUES (p_code, SUBSTR(p_message, 1, 4000), p_source, SYSTIMESTAMP);
    COMMIT;
END;
/
```

### Oracle: Common Named Exceptions

| Exception | ORA Code | Description |
|-----------|----------|-------------|
| `NO_DATA_FOUND` | ORA-01403 | SELECT INTO returned no rows |
| `TOO_MANY_ROWS` | ORA-01422 | SELECT INTO returned more than one row |
| `DUP_VAL_ON_INDEX` | ORA-00001 | Unique constraint violated |
| `INVALID_NUMBER` | ORA-01722 | Invalid number conversion |
| `VALUE_ERROR` | ORA-06502 | Arithmetic, conversion, truncation error |
| `ZERO_DIVIDE` | ORA-01476 | Division by zero |
| `CURSOR_ALREADY_OPEN` | ORA-06511 | Tried to open an already-open cursor |
| `LOGIN_DENIED` | ORA-01017 | Invalid username/password |
| `TIMEOUT_ON_RESOURCE` | ORA-00051 | Timeout waiting for resource |

### Oracle: PRAGMA EXCEPTION_INIT for Custom Error Mapping

```sql
DECLARE
    e_child_record_found EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_child_record_found, -2292);  -- ORA-02292: FK violation on delete
BEGIN
    DELETE FROM app.customers WHERE customer_id = 42;
EXCEPTION
    WHEN e_child_record_found THEN
        RAISE_APPLICATION_ERROR(-20100,
            'Cannot delete customer: active orders exist. Archive orders first.');
END;
/
```

### Oracle: Error Backtrace

```sql
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLCODE || ' - ' || SQLERRM);
        DBMS_OUTPUT.PUT_LINE('Backtrace: ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        DBMS_OUTPUT.PUT_LINE('Call Stack: ' || DBMS_UTILITY.FORMAT_CALL_STACK);
        RAISE;
```

## MySQL: DECLARE HANDLER with SIGNAL/RESIGNAL

```sql
DELIMITER //
CREATE PROCEDURE transfer_funds(
    IN p_from   INT,
    IN p_to     INT,
    IN p_amount DECIMAL(10,2)
)
BEGIN
    DECLARE v_rows INT DEFAULT 0;
    DECLARE v_error_msg TEXT;
    DECLARE v_sqlstate CHAR(5);

    -- Exit handler: rollback and re-signal on any error
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1
            v_error_msg = MESSAGE_TEXT,
            v_sqlstate = RETURNED_SQLSTATE;
        ROLLBACK;
        -- Log the error
        INSERT INTO error_log (error_message, sqlstate, error_source, error_date)
        VALUES (v_error_msg, v_sqlstate, 'transfer_funds', NOW());
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
END //
DELIMITER ;
```

### MySQL: Handler Types

```sql
-- EXIT HANDLER: executes handler then exits the BEGIN...END block
DECLARE EXIT HANDLER FOR SQLEXCEPTION
BEGIN
    ROLLBACK;
    RESIGNAL;
END;

-- CONTINUE HANDLER: executes handler then continues execution
DECLARE CONTINUE HANDLER FOR SQLWARNING
BEGIN
    SET @warning_count = @warning_count + 1;
END;

-- Specific condition handlers
DECLARE EXIT HANDLER FOR 1062  -- Duplicate key (MySQL error code)
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Record already exists';
END;

DECLARE EXIT HANDLER FOR SQLSTATE '23000'  -- Integrity constraint violation
BEGIN
    ROLLBACK;
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Data integrity violation';
END;
```

### MySQL: SIGNAL and RESIGNAL

```sql
-- Raise a custom error
SIGNAL SQLSTATE '45000'
SET MESSAGE_TEXT = 'Custom error message',
    MYSQL_ERRNO = 50001;

-- Re-raise with modified message
DECLARE EXIT HANDLER FOR SQLEXCEPTION
BEGIN
    GET DIAGNOSTICS CONDITION 1 @msg = MESSAGE_TEXT;
    ROLLBACK;
    SET @msg = CONCAT('transfer_funds failed: ', @msg);
    RESIGNAL SET MESSAGE_TEXT = @msg;
END;
```

## SQLite: Application-Level Error Handling

SQLite has no stored procedure language. All error handling occurs at the application level.

### Python

```python
import sqlite3

def transfer_funds(db_path: str, from_acct: int, to_acct: int, amount: float):
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")

    try:
        conn.execute("BEGIN IMMEDIATE")  # Acquire write lock immediately

        # Validate
        row = conn.execute(
            "SELECT balance FROM accounts WHERE account_id = ?", (from_acct,)
        ).fetchone()
        if row is None:
            raise ValueError(f"Source account {from_acct} not found")
        if row[0] < amount:
            raise ValueError(f"Insufficient funds: balance={row[0]}, requested={amount}")

        # Debit
        conn.execute(
            "UPDATE accounts SET balance = balance - ? WHERE account_id = ?",
            (amount, from_acct)
        )

        # Credit
        conn.execute(
            "UPDATE accounts SET balance = balance + ? WHERE account_id = ?",
            (amount, to_acct)
        )

        # Audit
        conn.execute(
            "INSERT INTO transfer_log (from_account, to_account, amount, transfer_date) "
            "VALUES (?, ?, ?, datetime('now'))",
            (from_acct, to_acct, amount)
        )

        conn.commit()

    except sqlite3.IntegrityError as e:
        conn.rollback()
        # Log to error table
        conn.execute(
            "INSERT INTO error_log (error_message, error_source, error_date) VALUES (?, ?, datetime('now'))",
            (str(e), 'transfer_funds')
        )
        conn.commit()
        raise
    except sqlite3.OperationalError as e:
        conn.rollback()
        if "database is locked" in str(e):
            raise TimeoutError("Database is locked. Retry the operation.") from e
        raise
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
```

### Node.js (better-sqlite3)

```javascript
const Database = require('better-sqlite3');

function transferFunds(dbPath, fromAcct, toAcct, amount) {
    const db = new Database(dbPath);
    db.pragma('journal_mode = WAL');
    db.pragma('foreign_keys = ON');

    const transfer = db.transaction(() => {
        // Validate
        const row = db.prepare('SELECT balance FROM accounts WHERE account_id = ?').get(fromAcct);
        if (!row) throw new Error(`Source account ${fromAcct} not found`);
        if (row.balance < amount) throw new Error(`Insufficient funds: ${row.balance}`);

        // Debit and credit
        const debit = db.prepare('UPDATE accounts SET balance = balance - ? WHERE account_id = ?');
        const credit = db.prepare('UPDATE accounts SET balance = balance + ? WHERE account_id = ?');
        debit.run(amount, fromAcct);
        credit.run(amount, toAcct);

        // Audit
        db.prepare(
            'INSERT INTO transfer_log (from_account, to_account, amount, transfer_date) VALUES (?, ?, ?, datetime(?))'
        ).run(fromAcct, toAcct, amount, 'now');
    });

    try {
        transfer();
    } catch (err) {
        // Log error
        db.prepare(
            'INSERT INTO error_log (error_message, error_source, error_date) VALUES (?, ?, datetime(?))'
        ).run(err.message, 'transferFunds', 'now');
        throw err;
    } finally {
        db.close();
    }
}
```

### SQLite Error Codes Reference

| Code | Name | Description |
|------|------|-------------|
| 5 | SQLITE_BUSY | Database is locked by another connection |
| 6 | SQLITE_LOCKED | Table-level lock conflict (e.g., within same connection) |
| 11 | SQLITE_CORRUPT | Database file is corrupted |
| 13 | SQLITE_FULL | Disk is full |
| 19 | SQLITE_CONSTRAINT | Constraint violation (FK, unique, check, not null) |
| 787 | SQLITE_CONSTRAINT_FOREIGNKEY | Foreign key constraint failed |
| 1555 | SQLITE_CONSTRAINT_PRIMARYKEY | Primary key constraint failed |
| 2067 | SQLITE_CONSTRAINT_UNIQUE | Unique constraint failed |

## Transaction Management with Proper Rollback

### Pattern: Nested Transaction Safety

**SQL Server**
```sql
-- Procedure called from another procedure -- must handle nested transactions
CREATE PROCEDURE dbo.InsertOrderItem
    @OrderID INT,
    @ProductID INT,
    @Quantity INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @TranStarted BIT = 0;

    BEGIN TRY
        IF @@TRANCOUNT = 0
        BEGIN
            BEGIN TRANSACTION;
            SET @TranStarted = 1;
        END

        INSERT INTO dbo.OrderItems (OrderID, ProductID, Quantity)
        VALUES (@OrderID, @ProductID, @Quantity);

        UPDATE dbo.Products
        SET Stock = Stock - @Quantity
        WHERE ProductID = @ProductID;

        IF @TranStarted = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @TranStarted = 1 AND @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
```

**PostgreSQL (Savepoints for partial recovery)**
```sql
CREATE OR REPLACE FUNCTION app.process_order_items(
    p_order_id INT, p_items JSONB
) RETURNS INT AS $$
DECLARE
    v_item RECORD;
    v_success_count INT := 0;
BEGIN
    FOR v_item IN SELECT * FROM jsonb_to_recordset(p_items)
        AS (product_id INT, quantity INT)
    LOOP
        -- Savepoint before each item
        BEGIN
            INSERT INTO app.order_items (order_id, product_id, quantity)
            VALUES (p_order_id, v_item.product_id, v_item.quantity);

            UPDATE app.products
            SET stock = stock - v_item.quantity
            WHERE product_id = v_item.product_id;

            v_success_count := v_success_count + 1;
        EXCEPTION
            WHEN OTHERS THEN
                -- This item failed, but the subtransaction is rolled back
                -- and we continue with the next item
                RAISE NOTICE 'Failed to add item %: %', v_item.product_id, SQLERRM;
        END;
    END LOOP;

    RETURN v_success_count;
END;
$$ LANGUAGE plpgsql;
```

## Retry Patterns for Transient Errors

Transient errors (deadlocks, timeouts, connection drops) should be retried at the application level, not inside stored procedures.

### Transient Error Codes by Dialect

| Error Type | PostgreSQL | MySQL | SQL Server | Oracle |
|-----------|-----------|-------|------------|--------|
| Deadlock | `40P01` | `1213` | `1205` | `ORA-00060` |
| Lock timeout | `55P03` | `1205` | `-2` (timeout) | `ORA-30006` |
| Connection lost | `08006`, `08001` | `2006`, `2013` | `-1`, `233` | `ORA-03113`, `ORA-03114` |
| Serialization failure | `40001` | `1213` | `1205` | `ORA-08177` |
| Too many connections | `53300` | `1040` | N/A | `ORA-12519` |
| Temporary failure | `57P03` (not accepting) | `1053` (shutdown) | `40613` (Azure) | `ORA-12505` |

### Python: Generic Retry with Exponential Backoff

```python
import time
import random
import logging
from functools import wraps

logger = logging.getLogger(__name__)

# Transient error codes per dialect
TRANSIENT_ERRORS = {
    "postgresql": {"40001", "40P01", "55P03", "57P03", "08006", "08001"},
    "mysql": {1205, 1213, 2006, 2013, 1040, 1053},
    "sqlserver": {1205, -1, -2, 233, 10054, 40613, 40197, 40501, 49918},
    "oracle": {60, 3113, 3114, 3135, 12519, 12505, 30006, 8177},
}

def retry_on_transient(dialect: str, max_retries: int = 3, base_delay: float = 0.5):
    """Decorator that retries a function on transient database errors."""
    def decorator(func):
        @wraps(func)
        def wrapper(*args, **kwargs):
            last_exception = None
            for attempt in range(max_retries + 1):
                try:
                    return func(*args, **kwargs)
                except Exception as e:
                    last_exception = e
                    error_code = _extract_error_code(e, dialect)

                    if error_code not in TRANSIENT_ERRORS.get(dialect, set()):
                        raise  # Not transient, do not retry

                    if attempt == max_retries:
                        logger.error("Max retries (%d) exceeded for %s: %s",
                                     max_retries, func.__name__, e)
                        raise

                    delay = base_delay * (2 ** attempt) + random.uniform(0, 0.5)
                    logger.warning("Transient error (attempt %d/%d), retrying in %.2fs: %s",
                                   attempt + 1, max_retries, delay, e)
                    time.sleep(delay)

            raise last_exception
        return wrapper
    return decorator


def _extract_error_code(exc, dialect):
    """Extract the database-specific error code from an exception."""
    if dialect == "postgresql":
        return getattr(exc, 'pgcode', None)
    elif dialect == "mysql":
        return getattr(exc, 'errno', getattr(exc, 'args', [None])[0] if exc.args else None)
    elif dialect == "sqlserver":
        # pyodbc stores error code in args[0] as a string like '[SQL Server]...'
        if hasattr(exc, 'args') and exc.args:
            try:
                return int(exc.args[0]) if isinstance(exc.args[0], (int, str)) else None
            except (ValueError, TypeError):
                return None
    elif dialect == "oracle":
        return getattr(exc, 'code', None)
    return None


# Usage:
@retry_on_transient("postgresql", max_retries=3, base_delay=0.5)
def transfer_funds(pool, from_id, to_id, amount):
    conn = pool.getconn()
    try:
        with conn:
            with conn.cursor() as cur:
                cur.execute("UPDATE app.accounts SET balance = balance - %s WHERE account_id = %s",
                            (amount, from_id))
                cur.execute("UPDATE app.accounts SET balance = balance + %s WHERE account_id = %s",
                            (amount, to_id))
    finally:
        pool.putconn(conn)
```

### Node.js: Retry Pattern

```javascript
const TRANSIENT_PG_CODES = new Set(['40001', '40P01', '55P03', '57P03', '08006']);
const TRANSIENT_MYSQL_CODES = new Set([1205, 1213, 2006, 2013]);
const TRANSIENT_MSSQL_CODES = new Set([1205, -1, -2, 233, 40613, 40197]);

async function withRetry(fn, { maxRetries = 3, baseDelay = 500, dialect = 'postgresql' } = {}) {
    let lastError;
    for (let attempt = 0; attempt <= maxRetries; attempt++) {
        try {
            return await fn();
        } catch (err) {
            lastError = err;
            const code = dialect === 'postgresql' ? err.code :
                         dialect === 'mysql' ? err.errno :
                         err.number;

            const transientCodes = dialect === 'postgresql' ? TRANSIENT_PG_CODES :
                                   dialect === 'mysql' ? TRANSIENT_MYSQL_CODES :
                                   TRANSIENT_MSSQL_CODES;

            if (!transientCodes.has(code) || attempt === maxRetries) {
                throw err;
            }

            const delay = baseDelay * Math.pow(2, attempt) + Math.random() * 500;
            console.warn(`Transient error (attempt ${attempt + 1}/${maxRetries}), retrying in ${delay}ms:`, err.message);
            await new Promise(resolve => setTimeout(resolve, delay));
        }
    }
    throw lastError;
}

// Usage:
await withRetry(async () => {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        await client.query('UPDATE app.accounts SET balance = balance - $1 WHERE account_id = $2', [amount, fromId]);
        await client.query('UPDATE app.accounts SET balance = balance + $1 WHERE account_id = $2', [amount, toId]);
        await client.query('COMMIT');
    } catch (err) {
        await client.query('ROLLBACK');
        throw err;
    } finally {
        client.release();
    }
}, { maxRetries: 3, dialect: 'postgresql' });
```

### C#: Retry Pattern

```csharp
public static class DbRetry
{
    // SQL Server transient error numbers
    private static readonly HashSet<int> TransientSqlServerErrors = new()
    {
        -2, -1, 233, 1205, 10054, 40197, 40501, 40613, 49918
    };

    // PostgreSQL transient SQLSTATE codes
    private static readonly HashSet<string> TransientPgStates = new()
    {
        "40001", "40P01", "55P03", "57P03", "08006"
    };

    public static async Task<T> ExecuteWithRetryAsync<T>(
        Func<Task<T>> operation,
        int maxRetries = 3,
        int baseDelayMs = 500)
    {
        for (int attempt = 0; attempt <= maxRetries; attempt++)
        {
            try
            {
                return await operation();
            }
            catch (SqlException ex) when (attempt < maxRetries && TransientSqlServerErrors.Contains(ex.Number))
            {
                var delay = baseDelayMs * (int)Math.Pow(2, attempt) + Random.Shared.Next(500);
                await Task.Delay(delay);
            }
            catch (NpgsqlException ex) when (attempt < maxRetries && TransientPgStates.Contains(ex.SqlState))
            {
                var delay = baseDelayMs * (int)Math.Pow(2, attempt) + Random.Shared.Next(500);
                await Task.Delay(delay);
            }
        }
        throw new InvalidOperationException("Should not reach here");
    }
}

// Usage:
await DbRetry.ExecuteWithRetryAsync(async () =>
{
    await using var conn = new SqlConnection(connectionString);
    await conn.OpenAsync();
    await using var txn = (SqlTransaction)await conn.BeginTransactionAsync();
    try
    {
        // ... execute commands ...
        await txn.CommitAsync();
        return true;
    }
    catch
    {
        await txn.RollbackAsync();
        throw;
    }
});
```

## Error Logging to Audit Tables

### Universal Error Log Table Schema

**PostgreSQL**
```sql
CREATE TABLE app.error_log (
    error_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    error_message TEXT NOT NULL,
    error_detail TEXT,
    error_context TEXT,
    sqlstate CHAR(5),
    error_source TEXT,
    error_date TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_error_log_date ON app.error_log (error_date DESC);
```

**MySQL**
```sql
CREATE TABLE error_log (
    error_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    error_message TEXT NOT NULL,
    sqlstate CHAR(5),
    mysql_errno INT,
    error_source VARCHAR(255),
    error_date DATETIME DEFAULT NOW(),
    INDEX idx_error_date (error_date)
) ENGINE=InnoDB;
```

**SQL Server**
```sql
CREATE TABLE dbo.ErrorLog (
    ErrorID BIGINT IDENTITY PRIMARY KEY,
    ErrorNumber INT,
    ErrorMessage NVARCHAR(4000),
    ErrorSeverity INT,
    ErrorState INT,
    ErrorProcedure NVARCHAR(128),
    ErrorLine INT,
    ErrorDate DATETIME2 DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_ErrorLog_Date ON dbo.ErrorLog (ErrorDate DESC);
```

**Oracle**
```sql
CREATE TABLE app.error_log (
    error_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    error_code NUMBER,
    error_message VARCHAR2(4000),
    error_backtrace VARCHAR2(4000),
    error_source VARCHAR2(255),
    error_date TIMESTAMP DEFAULT SYSTIMESTAMP
);
CREATE INDEX idx_error_log_date ON app.error_log (error_date DESC);
```

**SQLite**
```sql
CREATE TABLE error_log (
    error_id INTEGER PRIMARY KEY,
    error_message TEXT NOT NULL,
    error_source TEXT,
    error_date TEXT DEFAULT (datetime('now'))
);
CREATE INDEX idx_error_log_date ON error_log (error_date);
```

## Error Handling Principles (All Dialects)

1. **Never swallow errors silently.** Every CATCH/EXCEPTION block must either re-raise the error or log it explicitly. Oracle's `WHEN OTHERS THEN NULL` is the most dangerous anti-pattern.

2. **Always rollback on error.** If a transaction is open, the error handler must rollback before re-raising. SQL Server requires `IF @@TRANCOUNT > 0 ROLLBACK`; PostgreSQL auto-rolls back the subtransaction; Oracle and MySQL require explicit `ROLLBACK`.

3. **Log before re-raising.** Insert the error details into an audit/error table before re-raising. In Oracle, use an `AUTONOMOUS_TRANSACTION` logger so the log persists even after rollback.

4. **Include context in error messages.** Include the procedure name, parameters, and the original error message/code. This saves hours of debugging.

5. **Keep error handling consistent.** Use the same pattern in every procedure within a project. Create template procedures as a starting point.

6. **Retry transient errors at the application layer.** Deadlocks, timeouts, and connection drops belong in application retry logic, not inside stored procedures. Use exponential backoff with jitter.

7. **Distinguish between transient and permanent errors.** Retrying a constraint violation or syntax error is pointless. Only retry errors identified as transient for each dialect.
