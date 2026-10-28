# Oracle Database — Dialect Reference

## Version Features

### Oracle 19c (Long-Term Support)
- **Automatic indexing**: `EXEC DBMS_AUTO_INDEX.CONFIGURE('AUTO_INDEX_MODE', 'IMPLEMENT')` — Oracle auto-creates indexes
- **Real-time statistics**: Statistics gathered automatically during DML operations
- **SQL quarantine**: Automatically prevents resource-intensive SQL from executing
- **Polymorphic table functions**: Generic table functions that adapt output shape to input
- **Active Data Guard DML redirection**: Write to standby, redirected to primary

### Oracle 21c
- **JSON data type**: Native `JSON` column type (not CLOB-based). `JSON_VALUE()`/`JSON_QUERY()`/`JSON_TABLE()` themselves are older (12.1.0.2+) and work fine against `CLOB`/`VARCHAR2` columns holding JSON text -- the native `JSON` type in 21c is a storage/validation improvement, not a prerequisite for querying JSON
- **Blockchain tables**: Tamper-evident, insert-only tables with cryptographic chaining
- **SQL macros**: Reusable SQL expressions inlined at parse time (table and scalar macros)
- **In-memory hybrid columnar scan**: Automatic in-memory columnar processing
- **Expression-based default values**: Complex expressions as column defaults

### Oracle 23ai
- **JSON relational duality views**: Single JSON document maps to multiple relational tables
- **SQL domains**: Reusable column constraints (`CREATE DOMAIN email_domain AS VARCHAR2(255) CHECK (VALUE LIKE '%@%.%')`)
- **Boolean data type**: Native `BOOLEAN` (finally!)
- **Schema-level privileges**: `GRANT SELECT ANY TABLE ON SCHEMA hr TO appuser`
- **IF [NOT] EXISTS**: `CREATE TABLE IF NOT EXISTS`, `DROP TABLE IF EXISTS`
- **Table value constructor**: `VALUES (1,'a'), (2,'b')` like other databases
- **GROUP BY column alias**: Reference SELECT aliases in GROUP BY

## PL/SQL Block Template

### Stored Procedure
```sql
CREATE OR REPLACE PROCEDURE app_schema.upsert_customer_order(
    p_customer_id   IN  NUMBER,
    p_product_id    IN  NUMBER,
    p_quantity       IN  NUMBER,
    p_order_date     IN  DATE DEFAULT SYSDATE,
    p_order_id       OUT NUMBER
) AS
    v_existing_count NUMBER;
    e_invalid_quantity EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_invalid_quantity, -20001);
BEGIN
    -- Validate input
    IF p_quantity <= 0 THEN
        RAISE_APPLICATION_ERROR(-20001, 'Quantity must be positive');
    END IF;

    -- Check for existing order
    SELECT COUNT(*) INTO v_existing_count
    FROM app_schema.orders
    WHERE customer_id = p_customer_id
      AND product_id = p_product_id
      AND status = 'PENDING';

    IF v_existing_count > 0 THEN
        -- Update existing
        UPDATE app_schema.orders
        SET quantity = p_quantity, modified_date = SYSDATE
        WHERE customer_id = p_customer_id
          AND product_id = p_product_id
          AND status = 'PENDING'
        RETURNING order_id INTO p_order_id;
    ELSE
        -- Insert new
        INSERT INTO app_schema.orders (customer_id, product_id, quantity, order_date)
        VALUES (p_customer_id, p_product_id, p_quantity, p_order_date)
        RETURNING order_id INTO p_order_id;
    END IF;

    COMMIT;
EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
        ROLLBACK;
        RAISE_APPLICATION_ERROR(-20002, 'Duplicate order detected');
    WHEN NO_DATA_FOUND THEN
        p_order_id := 0;
    WHEN OTHERS THEN
        ROLLBACK;
        -- Log the error
        INSERT INTO app_schema.error_log (error_code, error_message, procedure_name, error_date)
        VALUES (SQLCODE, SQLERRM, 'upsert_customer_order', SYSDATE);
        COMMIT;  -- Commit the error log entry
        RAISE_APPLICATION_ERROR(-20000, 'Error in upsert_customer_order: ' || SQLERRM);
END upsert_customer_order;
/
```

### Package (Encapsulate Related Logic)
```sql
CREATE OR REPLACE PACKAGE app_schema.order_pkg AS
    -- Public type
    TYPE order_rec IS RECORD (
        order_id    NUMBER,
        customer_id NUMBER,
        total       NUMBER(12,2)
    );
    TYPE order_tab IS TABLE OF order_rec;

    -- Public procedures/functions
    FUNCTION get_order_total(p_order_id IN NUMBER) RETURN NUMBER;
    PROCEDURE cancel_order(p_order_id IN NUMBER);
END order_pkg;
/

CREATE OR REPLACE PACKAGE BODY app_schema.order_pkg AS
    -- Private variable
    g_default_tax_rate NUMBER(5,4) := 0.0875;

    FUNCTION get_order_total(p_order_id IN NUMBER) RETURN NUMBER IS
        v_subtotal NUMBER(12,2);
    BEGIN
        SELECT SUM(quantity * unit_price) INTO v_subtotal
        FROM app_schema.order_items
        WHERE order_id = p_order_id;

        RETURN v_subtotal * (1 + g_default_tax_rate);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN RETURN 0;
    END get_order_total;

    PROCEDURE cancel_order(p_order_id IN NUMBER) IS
    BEGIN
        UPDATE app_schema.orders SET status = 'CANCELLED' WHERE order_id = p_order_id;
        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20003, 'Order not found: ' || p_order_id);
        END IF;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END cancel_order;
END order_pkg;
/
```

## Parameter Syntax

### PL/SQL Bind Variables
```sql
-- In PL/SQL blocks
DECLARE
    v_user_id NUMBER := 42;
    v_name VARCHAR2(100);
BEGIN
    SELECT user_name INTO v_name FROM app_schema.users WHERE user_id = v_user_id;
END;
/
```

### cx_Oracle / oracledb (Python)
```python
import oracledb

# Positional bind
cursor.execute(
    "SELECT user_id, name FROM users WHERE user_id = :1 AND status = :2",
    [user_id, 'ACTIVE']
)

# Named bind (preferred)
cursor.execute(
    "SELECT user_id, name FROM users WHERE user_id = :id AND status = :status",
    {"id": user_id, "status": "ACTIVE"}
)

# OUT parameter
cursor.callproc('app_schema.upsert_customer_order',
    [customer_id, product_id, quantity, order_date, out_var])
```

### node-oracledb (Node.js)
```javascript
// Named bind
const result = await connection.execute(
    `SELECT user_id, name FROM users WHERE user_id = :id AND status = :status`,
    { id: userId, status: 'ACTIVE' },
    { outFormat: oracledb.OUT_FORMAT_OBJECT }
);

// OUT parameter
const result = await connection.execute(
    `BEGIN app_schema.upsert_customer_order(:cust, :prod, :qty, SYSDATE, :order_id); END;`,
    {
        cust: customerId,
        prod: productId,
        qty: quantity,
        order_id: { dir: oracledb.BIND_OUT, type: oracledb.NUMBER }
    }
);
```

### ODP.NET (C#)
```csharp
using var cmd = new OracleCommand("SELECT * FROM users WHERE user_id = :id", conn);
cmd.Parameters.Add(new OracleParameter(":id", OracleDbType.Int32) { Value = userId });

// Oracle binds by position by default — set BindByName for named binding
cmd.BindByName = true;
```

## Identity and Sequences

### GENERATED AS IDENTITY (12c+)
```sql
CREATE TABLE app_schema.orders (
    order_id NUMBER GENERATED ALWAYS AS IDENTITY
        (START WITH 1 INCREMENT BY 1 CACHE 20)
        CONSTRAINT pk_orders PRIMARY KEY,
    customer_id NUMBER NOT NULL,
    order_date DATE DEFAULT SYSDATE NOT NULL
);

-- GENERATED ALWAYS: no manual insert allowed
-- GENERATED BY DEFAULT: allows manual insert
-- GENERATED BY DEFAULT ON NULL: auto-generates only when NULL is inserted
```

### Sequences (Traditional)
```sql
CREATE SEQUENCE app_schema.order_seq
    START WITH 1
    INCREMENT BY 1
    CACHE 20
    NOCYCLE;

-- Use in INSERT
INSERT INTO app_schema.orders (order_id, customer_id)
VALUES (app_schema.order_seq.NEXTVAL, 42);

-- RETURNING INTO (get generated value)
DECLARE
    v_order_id NUMBER;
BEGIN
    INSERT INTO app_schema.orders (order_id, customer_id)
    VALUES (app_schema.order_seq.NEXTVAL, 42)
    RETURNING order_id INTO v_order_id;
END;
/
```

## Error Handling

### Exception Types
```sql
-- Predefined exceptions
EXCEPTION
    WHEN NO_DATA_FOUND THEN         -- ORA-01403: SELECT INTO returned no rows
        NULL;
    WHEN TOO_MANY_ROWS THEN         -- ORA-01422: SELECT INTO returned multiple rows
        NULL;
    WHEN DUP_VAL_ON_INDEX THEN      -- ORA-00001: unique constraint violated
        NULL;
    WHEN VALUE_ERROR THEN            -- ORA-06502: numeric/value error
        NULL;
    WHEN ZERO_DIVIDE THEN            -- ORA-01476: divisor is zero
        NULL;
    WHEN INVALID_CURSOR THEN         -- ORA-01001: invalid cursor
        NULL;
```

### Custom Exceptions with PRAGMA EXCEPTION_INIT
```sql
DECLARE
    e_insufficient_inventory EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_insufficient_inventory, -20010);

    e_order_locked EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_order_locked, -20011);
BEGIN
    IF v_available < v_requested THEN
        RAISE_APPLICATION_ERROR(-20010,
            'Insufficient inventory. Available: ' || v_available || ', Requested: ' || v_requested);
    END IF;
EXCEPTION
    WHEN e_insufficient_inventory THEN
        -- Handle specifically
        dbms_output.put_line('Insufficient inventory: ' || SQLERRM);
    WHEN OTHERS THEN
        dbms_output.put_line('Error ' || SQLCODE || ': ' || SQLERRM);
        dbms_output.put_line('Backtrace: ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        RAISE;
END;
/
```

### RAISE_APPLICATION_ERROR
```sql
-- Range: -20000 to -20999 (user-defined)
RAISE_APPLICATION_ERROR(-20001, 'Customer not found: ' || p_customer_id);

-- With third parameter TRUE to add to error stack (default FALSE replaces)
RAISE_APPLICATION_ERROR(-20001, 'Validation failed', TRUE);
```

### Error Backtrace
```sql
EXCEPTION
    WHEN OTHERS THEN
        -- DBMS_UTILITY.FORMAT_ERROR_BACKTRACE shows where the error occurred
        INSERT INTO error_log (error_text, backtrace, call_stack)
        VALUES (
            SQLCODE || ': ' || SQLERRM,
            DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
            DBMS_UTILITY.FORMAT_CALL_STACK
        );
        RAISE;
```

## Transaction Handling

### Implicit Transactions
```sql
-- Oracle does NOT require BEGIN TRANSACTION — transactions start implicitly
-- Every DML statement is part of a transaction until COMMIT or ROLLBACK

UPDATE app_schema.orders SET status = 'SHIPPED' WHERE order_id = 42;
-- Transaction is now open

COMMIT;  -- Makes change permanent
-- or
ROLLBACK;  -- Undoes the change
```

### DDL Auto-Commit (Critical Gotcha)
```sql
-- DDL statements issue an implicit COMMIT BEFORE and AFTER execution
-- This means:
UPDATE app_schema.orders SET status = 'PROCESSING' WHERE order_id = 42;
-- ^ This UPDATE is now committed because of the CREATE TABLE below:
CREATE TABLE app_schema.temp_data (id NUMBER);
-- Both the UPDATE and CREATE TABLE are committed, even if you ROLLBACK after
```

### Savepoints
```sql
UPDATE app_schema.accounts SET balance = balance - 100 WHERE account_id = 1;
SAVEPOINT after_debit;

UPDATE app_schema.accounts SET balance = balance + 100 WHERE account_id = 2;
-- If credit fails:
ROLLBACK TO SAVEPOINT after_debit;
-- Debit is still in the transaction, credit is undone

COMMIT;  -- Commits just the debit
```

### Autonomous Transactions (Logging in Separate Transaction)
```sql
CREATE OR REPLACE PROCEDURE app_schema.log_error(
    p_message IN VARCHAR2
) AS
    PRAGMA AUTONOMOUS_TRANSACTION;  -- This runs in its own transaction
BEGIN
    INSERT INTO app_schema.error_log (message, log_date) VALUES (p_message, SYSDATE);
    COMMIT;  -- Commits only the log entry, not the caller's transaction
END;
/

-- Usage: call from within a transaction that might roll back
BEGIN
    UPDATE app_schema.orders SET status = 'PROCESSING' WHERE order_id = 42;
    -- ... something goes wrong ...
    app_schema.log_error('Failed to process order 42');  -- This is committed even if...
    ROLLBACK;  -- ...we rollback the main transaction
END;
/
```

## Indexing

### B-tree (Default)
```sql
-- Standard index
CREATE INDEX idx_orders_customer ON app_schema.orders (customer_id);

-- Composite index (no INCLUDE columns in Oracle — use composite instead)
CREATE INDEX idx_orders_cust_date_amt ON app_schema.orders (customer_id, order_date, total_amount);

-- Unique index
CREATE UNIQUE INDEX uq_users_email ON app_schema.users (LOWER(email));
```

### Function-Based Index
```sql
-- Index on expression (case-insensitive search)
CREATE INDEX idx_users_email_lower ON app_schema.users (LOWER(email));
-- Query must match: SELECT * FROM users WHERE LOWER(email) = 'user@example.com';

-- Index on computed value
CREATE INDEX idx_orders_year ON app_schema.orders (EXTRACT(YEAR FROM order_date));
```

### Bitmap Index (OLAP / Low Cardinality)
```sql
-- Ideal for columns with few distinct values in read-heavy tables
CREATE BITMAP INDEX idx_orders_status ON app_schema.orders (status);
-- WARNING: Bitmap indexes cause severe contention in OLTP (concurrent DML) — use only for warehouses
```

### Index-Organized Table (IOT)
```sql
-- Data stored inside the index structure (like SQL Server clustered index)
CREATE TABLE app_schema.lookup_codes (
    code_type VARCHAR2(30),
    code_value VARCHAR2(30),
    description VARCHAR2(200),
    CONSTRAINT pk_lookup_codes PRIMARY KEY (code_type, code_value)
) ORGANIZATION INDEX;
```

### Invisible Index (Testing)
```sql
-- Make index invisible to optimizer (but still maintained)
ALTER INDEX idx_orders_customer INVISIBLE;
-- Test query performance without the index
-- If performance degrades, make visible again:
ALTER INDEX idx_orders_customer VISIBLE;
```

### Partitioned Indexes
```sql
-- Local index (one partition per table partition — recommended)
CREATE INDEX idx_orders_date_local ON app_schema.orders (order_date) LOCAL;

-- Global index (single index across all partitions — faster for non-partition-key queries)
CREATE INDEX idx_orders_customer_global ON app_schema.orders (customer_id) GLOBAL;
```

### Online Index Rebuild
```sql
-- Rebuild index without blocking DML
ALTER INDEX app_schema.idx_orders_customer REBUILD ONLINE;

-- Rebuild with parallel
ALTER INDEX app_schema.idx_orders_customer REBUILD ONLINE PARALLEL 4;
```

## Query Optimization

### Execution Plans
```sql
-- EXPLAIN PLAN
EXPLAIN PLAN FOR
SELECT o.order_id, c.name
FROM app_schema.orders o JOIN app_schema.customers c ON o.customer_id = c.customer_id
WHERE o.order_date > SYSDATE - 30;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(NULL, NULL, 'ALL'));

-- Real-time SQL monitoring (for currently running or recently run queries)
SELECT DBMS_SQLTUNE.REPORT_SQL_MONITOR(sql_id => 'abc123def') FROM DUAL;
```

### Optimizer Hints
```sql
-- Force index usage
SELECT /*+ INDEX(o idx_orders_customer) */ o.order_id, o.order_date
FROM app_schema.orders o WHERE o.customer_id = 42;

-- Force parallelism
SELECT /*+ PARALLEL(4) */ customer_id, SUM(total_amount)
FROM app_schema.orders GROUP BY customer_id;

-- Force join method
SELECT /*+ USE_HASH(o c) */ o.order_id, c.name
FROM app_schema.orders o JOIN app_schema.customers c ON o.customer_id = c.customer_id;

-- Force full table scan (when you know index would be slower)
SELECT /*+ FULL(o) */ * FROM app_schema.orders o WHERE status IN ('A','B','C','D','E');
```

### SQL Plan Baselines (Plan Stability)
```sql
-- Capture baseline for a specific SQL
DECLARE
    v_plans PLS_INTEGER;
BEGIN
    v_plans := DBMS_SPM.LOAD_PLANS_FROM_CURSOR_CACHE(sql_id => 'abc123def');
END;
/

-- View baselines
SELECT sql_handle, plan_name, enabled, accepted, fixed
FROM DBA_SQL_PLAN_BASELINES WHERE sql_text LIKE '%orders%';

-- Fix a plan (prevent optimizer from choosing alternatives)
DECLARE
    v_plans PLS_INTEGER;
BEGIN
    v_plans := DBMS_SPM.ALTER_SQL_PLAN_BASELINE(
        sql_handle => 'SQL_abc123',
        plan_name  => 'SQL_PLAN_xyz',
        attribute_name => 'FIXED',
        attribute_value => 'YES'
    );
END;
/
```

### SQL Tuning Advisor
```sql
-- Create and run a tuning task for a specific SQL
DECLARE
    v_task_name VARCHAR2(64);
BEGIN
    v_task_name := DBMS_SQLTUNE.CREATE_TUNING_TASK(sql_id => 'abc123def');
    DBMS_SQLTUNE.EXECUTE_TUNING_TASK(task_name => v_task_name);
END;
/

-- View recommendations
SELECT DBMS_SQLTUNE.REPORT_TUNING_TASK('task_name') FROM DUAL;
```

### Statistics Gathering
```sql
-- Gather table statistics (critical for optimizer)
EXEC DBMS_STATS.GATHER_TABLE_STATS('APP_SCHEMA', 'ORDERS', CASCADE => TRUE);

-- Gather schema statistics
EXEC DBMS_STATS.GATHER_SCHEMA_STATS('APP_SCHEMA');

-- Set statistics preferences for a table
EXEC DBMS_STATS.SET_TABLE_PREFS('APP_SCHEMA', 'ORDERS', 'STALE_PERCENT', '5');
```

## Configuration

### Memory Management
```sql
-- Automatic Memory Management (AMM)
-- MEMORY_TARGET = total SGA + PGA (let Oracle manage the split)
ALTER SYSTEM SET MEMORY_TARGET = 8G SCOPE=SPFILE;

-- Or manual: SGA + PGA separately
ALTER SYSTEM SET SGA_TARGET = 6G SCOPE=SPFILE;
ALTER SYSTEM SET PGA_AGGREGATE_TARGET = 2G SCOPE=SPFILE;
```

### Optimizer Mode
```sql
-- ALL_ROWS (default): optimize for throughput (batch/reporting)
-- FIRST_ROWS_n: optimize for returning first N rows quickly (OLTP)
ALTER SESSION SET OPTIMIZER_MODE = ALL_ROWS;

-- Per-query
SELECT /*+ FIRST_ROWS(10) */ * FROM app_schema.orders WHERE customer_id = 42;
```

### CURSOR_SHARING (Last Resort for Non-Parameterized Apps)
```sql
-- EXACT (default): each SQL text gets its own plan
-- FORCE: replace literals with bind variables (reduces hard parsing, but can degrade plans)
ALTER SYSTEM SET CURSOR_SHARING = FORCE;
-- Use only when application cannot be fixed to use bind variables
```

## Security Features

### Virtual Private Database (VPD)
```sql
-- Policy function: returns WHERE clause predicate
CREATE OR REPLACE FUNCTION app_schema.orders_vpd_policy(
    p_schema IN VARCHAR2,
    p_table  IN VARCHAR2
) RETURN VARCHAR2 AS
BEGIN
    RETURN 'tenant_id = SYS_CONTEXT(''APP_CTX'', ''TENANT_ID'')';
END;
/

-- Apply policy
BEGIN
    DBMS_RLS.ADD_POLICY(
        object_schema   => 'APP_SCHEMA',
        object_name     => 'ORDERS',
        policy_name     => 'ORDERS_TENANT_POLICY',
        function_schema => 'APP_SCHEMA',
        policy_function => 'orders_vpd_policy',
        statement_types => 'SELECT,INSERT,UPDATE,DELETE'
    );
END;
/

-- Set context in application
EXEC DBMS_SESSION.SET_CONTEXT('APP_CTX', 'TENANT_ID', '42');
```

### Data Redaction
```sql
BEGIN
    DBMS_REDACT.ADD_POLICY(
        object_schema => 'APP_SCHEMA',
        object_name   => 'USERS',
        column_name   => 'SSN',
        policy_name   => 'REDACT_SSN',
        function_type => DBMS_REDACT.PARTIAL,
        function_parameters => 'VVVFVVFVVVV,VVV-VV-VVVV,*,1,7',
        expression    => 'SYS_CONTEXT(''APP_CTX'',''ROLE'') != ''ADMIN'''
    );
END;
/
-- Non-admin users see: ***-**-6789
```

### Audit Policies (Unified Auditing, 12c+)
```sql
-- Create audit policy
CREATE AUDIT POLICY sensitive_data_access
    ACTIONS SELECT ON app_schema.users,
            UPDATE ON app_schema.users,
            DELETE ON app_schema.users;

-- Enable policy for all users
AUDIT POLICY sensitive_data_access;

-- Enable for specific users only
AUDIT POLICY sensitive_data_access BY appuser, admin_user;

-- Query audit trail
SELECT event_timestamp, dbusername, sql_text, object_name, action_name
FROM UNIFIED_AUDIT_TRAIL
WHERE object_name = 'USERS'
ORDER BY event_timestamp DESC;
```

### Blockchain Tables (21c)
```sql
CREATE BLOCKCHAIN TABLE app_schema.audit_trail (
    entry_id NUMBER GENERATED ALWAYS AS IDENTITY,
    action_type VARCHAR2(20) NOT NULL,
    action_detail VARCHAR2(4000),
    action_date TIMESTAMP DEFAULT SYSTIMESTAMP
) NO DROP UNTIL 365 DAYS IDLE
  NO DELETE UNTIL 365 DAYS AFTER INSERT
  HASHING USING "SHA2_512" VERSION "v2";

-- Insert-only: cannot UPDATE or DELETE rows within retention period
INSERT INTO app_schema.audit_trail (action_type, action_detail)
VALUES ('LOGIN', 'User admin logged in from 10.0.0.1');

-- Verify integrity
DECLARE
    v_verified PLS_INTEGER;
BEGIN
    DBMS_BLOCKCHAIN_TABLE.VERIFY_ROWS('APP_SCHEMA', 'AUDIT_TRAIL', v_verified);
    DBMS_OUTPUT.PUT_LINE('Verified rows: ' || v_verified);
END;
/
```

## Monitoring

### Top SQL by Elapsed Time (AWR)
```sql
SELECT
    sql_id,
    executions_total,
    ROUND(elapsed_time_total / 1000000, 2) AS elapsed_sec,
    ROUND(cpu_time_total / 1000000, 2) AS cpu_sec,
    buffer_gets_total,
    disk_reads_total,
    SUBSTR(sql_text, 1, 100) AS sql_preview
FROM DBA_HIST_SQLSTAT s
JOIN DBA_HIST_SQLTEXT t USING (sql_id)
WHERE snap_id BETWEEN :begin_snap AND :end_snap
ORDER BY elapsed_time_total DESC
FETCH FIRST 20 ROWS ONLY;
```

### Active Session History (ASH)
```sql
-- Current activity (last 10 minutes)
SELECT
    session_id, sql_id, event, wait_class,
    session_type, blocking_session,
    TO_CHAR(sample_time, 'HH24:MI:SS') AS sample_time
FROM V$ACTIVE_SESSION_HISTORY
WHERE sample_time > SYSDATE - INTERVAL '10' MINUTE
ORDER BY sample_time DESC;

-- Top wait events
SELECT event, wait_class, COUNT(*) AS samples
FROM V$ACTIVE_SESSION_HISTORY
WHERE sample_time > SYSDATE - INTERVAL '1' HOUR
GROUP BY event, wait_class
ORDER BY samples DESC
FETCH FIRST 10 ROWS ONLY;
```

### Session and Lock Analysis
```sql
-- Blocking sessions
SELECT
    s1.sid AS blocked_sid, s1.username AS blocked_user,
    s2.sid AS blocking_sid, s2.username AS blocking_user,
    s1.event AS wait_event,
    s1.sql_id AS blocked_sql
FROM V$SESSION s1
JOIN V$SESSION s2 ON s1.blocking_session = s2.sid
WHERE s1.blocking_session IS NOT NULL;
```

### System Wait Statistics
```sql
SELECT
    wait_class, event,
    total_waits,
    ROUND(time_waited_micro / 1000000, 2) AS time_waited_sec,
    ROUND(average_wait_micro / 1000, 2) AS avg_wait_ms
FROM V$SYSTEM_EVENT
WHERE wait_class != 'Idle'
ORDER BY time_waited_micro DESC
FETCH FIRST 20 ROWS ONLY;
```

## Detection Markers

| Marker Type | Pattern |
|-------------|---------|
| **Block terminator** | `/` on its own line after PL/SQL blocks |
| **Assignment** | `:=` (not `=` for assignment) |
| **DBMS packages** | `DBMS_OUTPUT`, `DBMS_LOB`, `DBMS_SQL`, `DBMS_STATS`, `DBMS_RLS` |
| **NVL function** | `NVL(a, b)` instead of `ISNULL()` or `COALESCE()` |
| **Date/time** | `SYSDATE`, `SYSTIMESTAMP`, `TO_DATE()`, `TO_CHAR()` |
| **Pseudocolumns** | `ROWNUM`, `ROWID`, `LEVEL` (CONNECT BY) |
| **Hierarchical queries** | `CONNECT BY PRIOR`, `START WITH`, `SYS_CONNECT_BY_PATH` |
| **DUAL table** | `SELECT SYSDATE FROM DUAL` |
| **Data types** | `NUMBER`, `VARCHAR2` (not `VARCHAR`), `CLOB`, `DATE` (includes time!) |
| **System views** | `SYS.*`, `ALL_*`, `DBA_*`, `USER_*`, `V$*` |
| **Parameter direction** | `IN`, `OUT`, `IN OUT` parameter modes |
| **Package syntax** | `CREATE PACKAGE`, `PACKAGE BODY` |
| **Connection drivers** | cx_Oracle, oracledb (Python), node-oracledb, ODP.NET |
| **Utilities** | `sqlplus`, `expdp/impdp`, `RMAN` |
| **String concat** | `||` operator |
| **Exception names** | `NO_DATA_FOUND`, `TOO_MANY_ROWS`, `DUP_VAL_ON_INDEX` |
