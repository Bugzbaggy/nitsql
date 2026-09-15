# MSSQL / SQL Server — Dialect Reference

## Version Features

### SQL Server 2019 (Compatibility Level 150)
- **Batch mode on rowstore**: Batch mode processing for analytics queries even without columnstore indexes
- **Table Variable Deferred Compilation (TVD)**: Table variables get accurate cardinality estimates at first compilation
- **Scalar UDF inlining**: Scalar functions inlined into calling query for better performance
- **Adaptive joins**: Runtime switch between nested loop and hash join based on actual row counts
- **Memory grant feedback (batch and row mode)**: Adjusts memory grants based on previous executions
- **APPROX_COUNT_DISTINCT**: Fast approximate distinct counts for large datasets
- **OPTIMIZE_FOR_SEQUENTIAL_KEY**: Reduces contention on last-page insert for identity-based clustered indexes
- **Accelerated Database Recovery (ADR)**: Near-instant recovery regardless of active transaction count
- **UTF-8 collation support**: `_UTF8` collations for storage-efficient Unicode

### SQL Server 2022 (Compatibility Level 160)
- **Parameter Sensitive Plan Optimization (PSP)**: Multiple plans cached for different parameter ranges
- **DOP feedback**: Auto-adjusts degree of parallelism per query
- **Cardinality Estimation feedback**: Corrects CE model assumptions at runtime
- **Query Store hints**: Force plan hints without changing application code via `sp_query_store_set_hints`
- **GENERATE_SERIES()**: Generate sequences of numbers
- **GREATEST() / LEAST()**: Return max/min from a list of values
- **DATE_BUCKET()**: Bucket date/time values into intervals
- **IS [NOT] DISTINCT FROM**: NULL-safe equality comparison
- **WINDOW clause**: Define reusable window specifications
- **Ledger tables**: Tamper-evident, blockchain-verifiable tables

## Stored Procedure Template

```sql
CREATE OR ALTER PROCEDURE dbo.UpsertCustomerOrder
    @CustomerID     INT,
    @ProductID      INT,
    @Quantity        INT,
    @OrderDate       DATETIME2 = NULL,
    @OrderID         INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @OrderDate IS NULL
        SET @OrderDate = SYSDATETIME();

    BEGIN TRY
        BEGIN TRANSACTION;

        MERGE dbo.Orders AS tgt
        USING (SELECT @CustomerID, @ProductID, @Quantity, @OrderDate)
              AS src (CustomerID, ProductID, Quantity, OrderDate)
        ON tgt.CustomerID = src.CustomerID AND tgt.ProductID = src.ProductID
        WHEN MATCHED THEN
            UPDATE SET Quantity = src.Quantity, ModifiedDate = SYSDATETIME()
        WHEN NOT MATCHED THEN
            INSERT (CustomerID, ProductID, Quantity, OrderDate)
            VALUES (src.CustomerID, src.ProductID, src.Quantity, src.OrderDate);

        SET @OrderID = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        -- Log error details before re-throwing
        INSERT INTO dbo.ErrorLog (ErrorNumber, ErrorMessage, ErrorLine, ErrorProcedure, ErrorTime)
        VALUES (ERROR_NUMBER(), ERROR_MESSAGE(), ERROR_LINE(), ERROR_PROCEDURE(), SYSDATETIME());

        THROW;  -- Re-raise original error
    END CATCH
END;
```

## Parameter Syntax

### T-SQL Native
```sql
DECLARE @UserID INT = 42;
SELECT UserID, UserName FROM dbo.Users WHERE UserID = @UserID;
```

### sp_executesql (Dynamic SQL)
```sql
DECLARE @sql NVARCHAR(MAX) = N'SELECT * FROM dbo.Users WHERE UserID = @id AND Status = @status';
DECLARE @params NVARCHAR(200) = N'@id INT, @status NVARCHAR(20)';
EXEC sp_executesql @sql, @params, @id = 42, @status = N'Active';
```

### ADO.NET / C#
```csharp
using var cmd = new SqlCommand("SELECT * FROM dbo.Users WHERE UserID = @id", connection);
cmd.Parameters.Add("@id", SqlDbType.Int).Value = userId;
```

### pyodbc (Python)
```python
cursor.execute("SELECT * FROM dbo.Users WHERE UserID = ?", user_id)
# Multiple parameters:
cursor.execute("SELECT * FROM dbo.Users WHERE UserID = ? AND Status = ?", user_id, status)
```

### node-mssql (Node.js)
```javascript
const result = await pool.request()
    .input('id', sql.Int, userId)
    .input('status', sql.NVarChar(20), 'Active')
    .query('SELECT * FROM dbo.Users WHERE UserID = @id AND Status = @status');
```

## Identity and Sequences

### IDENTITY Column
```sql
CREATE TABLE dbo.Orders (
    OrderID INT IDENTITY(1,1) NOT NULL,
    CustomerID INT NOT NULL,
    CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED (OrderID)
);

-- After INSERT, retrieve the generated ID:
INSERT INTO dbo.Orders (CustomerID) VALUES (100);
SELECT SCOPE_IDENTITY() AS NewOrderID;  -- Safe: session + scope limited

-- NEVER use @@IDENTITY (cross-scope, affected by triggers)
-- NEVER use IDENT_CURRENT('dbo.Orders') (cross-session)
```

### SEQUENCE Objects (2012+)
```sql
CREATE SEQUENCE dbo.OrderNumberSeq
    AS INT
    START WITH 1000
    INCREMENT BY 1
    NO CACHE;  -- Use CACHE 50 for high-throughput scenarios

-- Use in INSERT
INSERT INTO dbo.Orders (OrderNumber, CustomerID)
VALUES (NEXT VALUE FOR dbo.OrderNumberSeq, 100);

-- Use as column default
ALTER TABLE dbo.Orders ADD CONSTRAINT DF_OrderNumber
    DEFAULT (NEXT VALUE FOR dbo.OrderNumberSeq) FOR OrderNumber;
```

## Error Handling

### TRY...CATCH with Full Error Details
```sql
BEGIN TRY
    -- Dangerous operation
    DELETE FROM dbo.Orders WHERE OrderID = @OrderID;
END TRY
BEGIN CATCH
    SELECT
        ERROR_NUMBER()    AS ErrorNumber,
        ERROR_SEVERITY()  AS ErrorSeverity,
        ERROR_STATE()     AS ErrorState,
        ERROR_PROCEDURE() AS ErrorProcedure,
        ERROR_LINE()      AS ErrorLine,
        ERROR_MESSAGE()   AS ErrorMessage;

    -- THROW re-raises the original error (SQL 2012+)
    THROW;

    -- RAISERROR is legacy but still useful for custom messages:
    -- RAISERROR('Custom error: %s', 16, 1, @detail);
END CATCH
```

### Custom Error Numbers
```sql
-- THROW with custom error
THROW 50001, 'Order not found for the specified customer.', 1;

-- Conditional error
IF NOT EXISTS (SELECT 1 FROM dbo.Orders WHERE OrderID = @OrderID)
    THROW 50001, 'Order not found.', 1;
```

## Transaction Handling

### Standard Pattern
```sql
SET XACT_ABORT ON;  -- CRITICAL: ensures automatic rollback on timeout/abort

BEGIN TRY
    BEGIN TRANSACTION;

    UPDATE dbo.Inventory SET Quantity = Quantity - @Qty WHERE ProductID = @ProductID;
    INSERT INTO dbo.OrderItems (OrderID, ProductID, Quantity) VALUES (@OrderID, @ProductID, @Qty);

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;
    THROW;
END CATCH
```

### Savepoints for Partial Rollback
```sql
BEGIN TRANSACTION;

INSERT INTO dbo.OrderHeader (CustomerID) VALUES (@CustomerID);

SAVE TRANSACTION SaveBeforeItems;

BEGIN TRY
    INSERT INTO dbo.OrderItems (OrderID, ProductID) VALUES (@OrderID, @ProductID);
END TRY
BEGIN CATCH
    ROLLBACK TRANSACTION SaveBeforeItems;  -- Only rolls back items, header remains
    -- Log and continue with partial order
END CATCH

COMMIT TRANSACTION;
```

### Why SET XACT_ABORT ON Matters
```sql
-- WITHOUT XACT_ABORT ON:
--   If a query times out, the transaction is NOT automatically rolled back.
--   Locks are held indefinitely. The connection returns to the app with an open transaction.
--
-- WITH XACT_ABORT ON:
--   Any runtime error (including timeouts) triggers an automatic ROLLBACK.
--   Always set this in stored procedures that use transactions.
```

## Indexing

### Clustered vs Nonclustered
```sql
-- Clustered index (data physically sorted by this key — one per table)
CREATE CLUSTERED INDEX CIX_Orders_OrderDate ON dbo.Orders (OrderDate);

-- Nonclustered index with INCLUDE (covering index)
CREATE NONCLUSTERED INDEX IX_Orders_CustomerID
    ON dbo.Orders (CustomerID)
    INCLUDE (OrderDate, TotalAmount)
    WHERE IsDeleted = 0;  -- Filtered index: smaller, faster
```

### Columnstore Indexes
```sql
-- Nonclustered columnstore for analytics on OLTP table
CREATE NONCLUSTERED COLUMNSTORE INDEX NCCIX_OrderItems_Analytics
    ON dbo.OrderItems (ProductID, Quantity, UnitPrice, OrderDate);
```

### OPTIMIZE_FOR_SEQUENTIAL_KEY (2019+)
```sql
-- Reduces last-page latch contention on high-insert identity tables
CREATE TABLE dbo.EventLog (
    EventID BIGINT IDENTITY(1,1) NOT NULL,
    EventTime DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
    EventData NVARCHAR(4000),
    CONSTRAINT PK_EventLog PRIMARY KEY CLUSTERED (EventID)
        WITH (OPTIMIZE_FOR_SEQUENTIAL_KEY = ON)
);
```

### Resumable Online Index Operations (2019+)
```sql
-- Can pause/resume, survives failover
CREATE INDEX IX_Orders_CustomerID ON dbo.Orders (CustomerID)
    WITH (ONLINE = ON, RESUMABLE = ON, MAX_DURATION = 10 MINUTES);

-- Pause if needed
ALTER INDEX IX_Orders_CustomerID ON dbo.Orders PAUSE;

-- Resume later
ALTER INDEX IX_Orders_CustomerID ON dbo.Orders RESUME;
```

**CRITICAL — `RESUMABLE = ON` cannot run inside a user transaction.** SQL Server raises error 574: *"RESUMABLE INDEX statement cannot be used inside a user transaction."* Migration tools that wrap each script in an implicit transaction (Flyway, Liquibase `runInTransaction=true`, etc.) are therefore incompatible with `RESUMABLE = ON`. Use it only for ad-hoc maintenance scripts executed outside an explicit/implicit transaction; for transactional migrations, drop `RESUMABLE` and rely on `ONLINE = ON (WAIT_AT_LOW_PRIORITY (...))` alone.

### Index Options — Valid Syntax by Statement Type (SQL Server)

`WAIT_AT_LOW_PRIORITY` and `RESUMABLE` are accepted by `CREATE INDEX` / `ALTER INDEX REBUILD` but are **rejected** by `ALTER TABLE ... ADD CONSTRAINT ... PRIMARY KEY | UNIQUE`. Using them on `ALTER TABLE ADD CONSTRAINT` triggers error 155: *"'WAIT_AT_LOW_PRIORITY' is not a recognized ALTER TABLE option."*

| Option | `CREATE INDEX` / `ALTER INDEX REBUILD` | `ALTER TABLE ADD CONSTRAINT PK/UQ` | Inline PK/UQ in `CREATE TABLE` |
|--------|:-:|:-:|:-:|
| `FILLFACTOR` | Yes (90 clustered, 95 non-clustered) | Yes (90 clustered, 95 non-clustered) | No |
| `ONLINE = ON` (flat) | Yes | Yes | No |
| `ONLINE = ON (WAIT_AT_LOW_PRIORITY (...))` | Yes | **No (error 155)** | No |
| `RESUMABLE = ON, MAX_DURATION = ...` | Yes, but **not inside a transaction (error 574)** | **No** | No |
| `OPTIMIZE_FOR_SEQUENTIAL_KEY = ON` | Yes (applies to PK/clustered) | Yes | Yes |

```sql
-- GOOD: CREATE INDEX — full options (ad-hoc maintenance; drop RESUMABLE if run inside a transaction)
CREATE NONCLUSTERED INDEX IX_Orders_Customer ON dbo.Orders (CustomerID)
    WITH (FILLFACTOR = 95,
          ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 5 MINUTES, ABORT_AFTER_WAIT = SELF)));

-- GOOD: ALTER TABLE ADD CONSTRAINT — flat ONLINE only
ALTER TABLE dbo.Orders
    ADD CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED (OrderID)
    WITH (FILLFACTOR = 90, OPTIMIZE_FOR_SEQUENTIAL_KEY = ON, ONLINE = ON);

-- BAD: WAIT_AT_LOW_PRIORITY on ALTER TABLE ADD CONSTRAINT — error 155
ALTER TABLE dbo.Orders
    ADD CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED (OrderID)
    WITH (ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 5 MINUTES, ABORT_AFTER_WAIT = SELF)));

-- BAD: RESUMABLE inside a Flyway/Liquibase migration — error 574
CREATE NONCLUSTERED INDEX IX_Orders_Customer ON dbo.Orders (CustomerID)
    WITH (ONLINE = ON, RESUMABLE = ON, MAX_DURATION = 60 MINUTES);  -- rejected inside user transaction
```

## Query Optimization

### Query Store Configuration
```sql
ALTER DATABASE MyDatabase SET QUERY_STORE = ON (
    OPERATION_MODE = READ_WRITE,
    DATA_FLUSH_INTERVAL_SECONDS = 900,
    INTERVAL_LENGTH_MINUTES = 60,
    MAX_STORAGE_SIZE_MB = 1024,
    QUERY_CAPTURE_MODE = AUTO,
    STALE_QUERY_THRESHOLD_DAYS = 30,
    MAX_PLANS_PER_QUERY = 200,
    CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 30)
);
```

### Query Store Hints (2022)
```sql
-- Force a hint on a query without changing the application code
EXEC sp_query_store_set_hints
    @query_id = 42,
    @query_hints = N'OPTION (MAXDOP 4, RECOMPILE)';

-- Remove hints
EXEC sp_query_store_clear_hints @query_id = 42;
```

### Auto-Tuning
```sql
-- Enable automatic plan correction
ALTER DATABASE MyDatabase SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = ON);
```

### Execution Plan Analysis
```sql
-- IO statistics (always useful for tuning)
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

-- Actual execution plan (in SSMS: Ctrl+M before execution)
-- Or in T-SQL:
SET STATISTICS XML ON;
SELECT * FROM dbo.Orders WHERE CustomerID = 42;
SET STATISTICS XML OFF;

-- Top resource-consuming queries from Query Store
SELECT TOP 20
    qt.query_sql_text,
    rs.avg_duration / 1000.0 AS avg_duration_ms,
    rs.avg_cpu_time / 1000.0 AS avg_cpu_ms,
    rs.avg_logical_io_reads,
    rs.count_executions
FROM sys.query_store_query_text qt
JOIN sys.query_store_query q ON qt.query_text_id = q.query_text_id
JOIN sys.query_store_plan p ON q.query_id = p.query_id
JOIN sys.query_store_runtime_stats rs ON p.plan_id = rs.plan_id
ORDER BY rs.avg_duration DESC;
```

## Configuration

### Compatibility Level
```sql
-- Check current level
SELECT name, compatibility_level FROM sys.databases WHERE name = 'MyDatabase';

-- Set to 2019 (150) or 2022 (160)
ALTER DATABASE MyDatabase SET COMPATIBILITY_LEVEL = 160;
```

### Accelerated Database Recovery
```sql
ALTER DATABASE MyDatabase SET ACCELERATED_DATABASE_RECOVERY = ON;
```

### tempdb Optimization
```sql
-- Recommended: 1 data file per logical CPU, max 8
-- Each file should be the same size for proportional fill
-- Check current files:
SELECT name, physical_name, size * 8 / 1024 AS size_mb
FROM sys.master_files WHERE database_id = 2;
```

### MAXDOP Settings
```sql
-- Server level: match NUMA node CPU count or 8, whichever is lower
EXEC sp_configure 'max degree of parallelism', 8;
RECONFIGURE;

-- Database level (2016+):
ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 8;

-- Cost threshold for parallelism (raise from default 5)
EXEC sp_configure 'cost threshold for parallelism', 50;
RECONFIGURE;
```

## Security Features

### Always Encrypted (with Enclaves, 2019+)
```sql
-- Column encryption (data never exposed to SQL Server in plaintext)
CREATE TABLE dbo.Patients (
    PatientID INT IDENTITY(1,1) PRIMARY KEY,
    SSN CHAR(11) COLLATE Latin1_General_BIN2
        ENCRYPTED WITH (
            COLUMN_ENCRYPTION_KEY = CEK1,
            ENCRYPTION_TYPE = DETERMINISTIC,
            ALGORITHM = 'AEAD_AES_256_CBC_HMAC_SHA_256'
        ),
    Salary MONEY
        ENCRYPTED WITH (
            COLUMN_ENCRYPTION_KEY = CEK1,
            ENCRYPTION_TYPE = RANDOMIZED,
            ALGORITHM = 'AEAD_AES_256_CBC_HMAC_SHA_256'
        )
);
```

### Row-Level Security (RLS)
```sql
-- Predicate function
CREATE FUNCTION dbo.fn_SecurityPredicate(@TenantID INT)
RETURNS TABLE WITH SCHEMABINDING AS
RETURN SELECT 1 AS result WHERE @TenantID = CAST(SESSION_CONTEXT(N'TenantID') AS INT);

-- Apply to table
CREATE SECURITY POLICY dbo.OrdersSecurityPolicy
ADD FILTER PREDICATE dbo.fn_SecurityPredicate(TenantID) ON dbo.Orders,
ADD BLOCK PREDICATE dbo.fn_SecurityPredicate(TenantID) ON dbo.Orders
WITH (STATE = ON);

-- Set tenant context in application
EXEC sp_set_session_context @key = N'TenantID', @value = 42;
```

### Dynamic Data Masking
```sql
ALTER TABLE dbo.Users ALTER COLUMN Email ADD MASKED WITH (FUNCTION = 'email()');
ALTER TABLE dbo.Users ALTER COLUMN Phone ADD MASKED WITH (FUNCTION = 'partial(0,"XXX-XXX-",4)');
ALTER TABLE dbo.Users ALTER COLUMN SSN ADD MASKED WITH (FUNCTION = 'default()');

-- Grant unmask permission
GRANT UNMASK ON dbo.Users TO [ReportingRole];
```

### Ledger Tables (2022)
```sql
CREATE TABLE dbo.AuditedBalances (
    AccountID INT NOT NULL PRIMARY KEY,
    Balance DECIMAL(18,2) NOT NULL,
    LastModified DATETIME2 NOT NULL
) WITH (SYSTEM_VERSIONING = ON, LEDGER = ON);

-- Verify ledger integrity
EXEC sp_verify_database_ledger;
```

### Data Classification
```sql
ADD SENSITIVITY CLASSIFICATION TO dbo.Users.SSN
WITH (LABEL = 'Highly Confidential', INFORMATION_TYPE = 'National ID', RANK = CRITICAL);

ADD SENSITIVITY CLASSIFICATION TO dbo.Users.Email
WITH (LABEL = 'Confidential', INFORMATION_TYPE = 'Contact Info', RANK = HIGH);
```

## Monitoring DMVs

### Top Queries by CPU
```sql
SELECT TOP 20
    qs.total_worker_time / qs.execution_count AS avg_cpu_us,
    qs.execution_count,
    SUBSTRING(st.text, (qs.statement_start_offset / 2) + 1,
        ((CASE qs.statement_end_offset
            WHEN -1 THEN DATALENGTH(st.text)
            ELSE qs.statement_end_offset
        END - qs.statement_start_offset) / 2) + 1) AS query_text
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
ORDER BY avg_cpu_us DESC;
```

### Missing Indexes
```sql
SELECT
    CONVERT(DECIMAL(18,2), migs.avg_user_impact) AS avg_impact_pct,
    migs.user_seeks + migs.user_scans AS total_usage,
    mid.statement AS table_name,
    mid.equality_columns, mid.inequality_columns, mid.included_columns
FROM sys.dm_db_missing_index_groups mig
JOIN sys.dm_db_missing_index_group_stats migs ON mig.index_group_handle = migs.group_handle
JOIN sys.dm_db_missing_index_details mid ON mig.index_handle = mid.index_handle
ORDER BY migs.avg_user_impact * (migs.user_seeks + migs.user_scans) DESC;
```

### Index Usage Stats
```sql
SELECT
    OBJECT_NAME(ius.object_id) AS table_name,
    i.name AS index_name,
    ius.user_seeks, ius.user_scans, ius.user_lookups, ius.user_updates,
    ius.last_user_seek, ius.last_user_scan
FROM sys.dm_db_index_usage_stats ius
JOIN sys.indexes i ON ius.object_id = i.object_id AND ius.index_id = i.index_id
WHERE ius.database_id = DB_ID()
ORDER BY ius.user_seeks + ius.user_scans + ius.user_lookups DESC;
```

### Wait Statistics
```sql
SELECT TOP 20
    wait_type,
    waiting_tasks_count,
    wait_time_ms / 1000.0 AS wait_time_sec,
    signal_wait_time_ms / 1000.0 AS signal_wait_sec,
    (wait_time_ms - signal_wait_time_ms) / 1000.0 AS resource_wait_sec
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN (
    'CLR_SEMAPHORE','LAZYWRITER_SLEEP','RESOURCE_QUEUE','SQLTRACE_BUFFER_FLUSH',
    'SLEEP_TASK','SLEEP_SYSTEMTASK','WAITFOR','BROKER_TO_FLUSH',
    'CHECKPOINT_QUEUE','XE_TIMER_EVENT','HADR_FILESTREAM_IOMGR_IOCOMPLETION'
)
ORDER BY wait_time_ms DESC;
```

### Extended Events (Preferred over SQL Profiler)
```sql
CREATE EVENT SESSION [QueryPerformance] ON SERVER
ADD EVENT sqlserver.sql_statement_completed (
    SET collect_statement = (1)
    ACTION (sqlserver.sql_text, sqlserver.database_name, sqlserver.username)
    WHERE duration > 1000000  -- > 1 second (microseconds)
)
ADD TARGET package0.ring_buffer (SET max_memory = 4096)
WITH (MAX_MEMORY = 4096 KB, EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS);

ALTER EVENT SESSION [QueryPerformance] ON SERVER STATE = START;
```

## Detection Markers

Use these patterns to identify MSSQL/SQL Server dialect in SQL files:

| Marker Type | Pattern |
|-------------|---------|
| **Session settings** | `SET NOCOUNT ON`, `SET XACT_ABORT ON`, `SET ANSI_NULLS ON` |
| **System variables** | `@@TRANCOUNT`, `@@ROWCOUNT`, `@@IDENTITY`, `@@ERROR`, `@@SPID` |
| **Dynamic SQL** | `sp_executesql`, `EXEC(@sql)` |
| **Block structure** | `BEGIN...END` without `$$`, `DO`, or `/` terminator |
| **Identity** | `IDENTITY(1,1)`, `SCOPE_IDENTITY()` |
| **System objects** | `sys.objects`, `sys.columns`, `sp_help`, `sp_who2`, `INFORMATION_SCHEMA` |
| **Data types** | `NVARCHAR`, `DATETIME2`, `UNIQUEIDENTIFIER`, `BIT`, `VARCHAR(MAX)` |
| **String ops** | `ISNULL()`, `LEN()`, `GETDATE()`, `SYSDATETIME()`, `CHARINDEX()` |
| **Top N** | `SELECT TOP N` (not `LIMIT`) |
| **Connection drivers** | pyodbc, mssql (node), SqlConnection/SqlClient (.NET) |
| **File indicators** | `.sql` files with `GO` batch separator |
