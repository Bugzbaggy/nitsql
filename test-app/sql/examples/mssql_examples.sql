-- ============================================================================
-- SQL SERVER (T-SQL) EXAMPLES
-- ============================================================================
-- This file demonstrates SQL Server-specific patterns including:
-- - T-SQL stored procedures with TRY...CATCH and XACT_ABORT
-- - MERGE statement with OUTPUT clause
-- - Window functions with ROWS/RANGE frames
-- - STRING_AGG and STRING_SPLIT (2017+)
-- - JSON operations (FOR JSON, OPENJSON, JSON_VALUE, JSON_MODIFY)
-- - Temporal tables (system-versioned) for audit trails
-- - In-Memory OLTP (memory-optimized tables)
-- - Graph tables and MATCH queries (2017+)
-- - Columnstore indexes
-- - SEQUENCE objects
-- - CROSS APPLY and OUTER APPLY
-- - Common Table Expressions with recursive queries
-- - Indexed views (materialized views equivalent)
-- - OFFSET/FETCH pagination
-- - TRY_CAST, TRY_CONVERT, TRY_PARSE for safe type conversions
-- ============================================================================


-- ============================================================================
-- SECTION 1: T-SQL STORED PROCEDURES WITH TRY...CATCH AND XACT_ABORT
-- ============================================================================

-- Example 1.1: Robust stored procedure with full error handling
-- SET XACT_ABORT ON ensures that any runtime error automatically rolls back
-- the transaction, preventing partial commits even in edge cases that
-- TRY...CATCH alone might not catch (e.g., query timeout, lock escalation).
CREATE OR ALTER PROCEDURE dbo.ProcessPendingOrders
    @BatchSize   INT = 100,
    @Processed   INT OUTPUT,
    @Errors      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;        -- Suppress "N rows affected" messages for performance
    SET XACT_ABORT ON;     -- Auto-rollback on runtime errors

    DECLARE @OrderId       INT;
    DECLARE @ErrorMessage  NVARCHAR(4000);
    DECLARE @ErrorSeverity INT;
    DECLARE @ErrorState    INT;

    SET @Processed = 0;
    SET @Errors = 0;

    -- Use a cursor for row-by-row processing with individual error handling
    DECLARE order_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT TOP (@BatchSize) order_id
        FROM dbo.Orders
        WHERE status = 'pending'
          AND order_date < DATEADD(HOUR, -1, SYSDATETIME())
        ORDER BY order_date;

    OPEN order_cursor;
    FETCH NEXT FROM order_cursor INTO @OrderId;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            -- Reserve inventory
            UPDATE inv
            SET inv.reserved_quantity = inv.reserved_quantity + oi.quantity
            FROM dbo.Inventory inv
            INNER JOIN dbo.OrderItems oi ON inv.product_id = oi.product_id
            WHERE oi.order_id = @OrderId
              AND inv.quantity - inv.reserved_quantity >= oi.quantity;

            -- Check if all items were reserved
            IF EXISTS (
                SELECT 1
                FROM dbo.OrderItems oi
                LEFT JOIN dbo.Inventory inv ON oi.product_id = inv.product_id
                WHERE oi.order_id = @OrderId
                  AND (inv.product_id IS NULL
                       OR inv.quantity - inv.reserved_quantity < oi.quantity)
            )
            BEGIN
                -- Insufficient inventory: mark as backordered
                UPDATE dbo.Orders
                SET status = 'backordered', updated_at = SYSDATETIME()
                WHERE order_id = @OrderId;
            END
            ELSE
            BEGIN
                -- All items available: mark as processing
                UPDATE dbo.Orders
                SET status = 'processing', updated_at = SYSDATETIME()
                WHERE order_id = @OrderId;
            END;

            COMMIT TRANSACTION;
            SET @Processed = @Processed + 1;

        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0
                ROLLBACK TRANSACTION;

            -- Capture error details
            SET @ErrorMessage  = ERROR_MESSAGE();
            SET @ErrorSeverity = ERROR_SEVERITY();
            SET @ErrorState    = ERROR_STATE();

            -- Log the error (separate transaction so it persists after rollback)
            INSERT INTO dbo.OrderProcessingLog (
                order_id, error_number, error_severity, error_state,
                error_message, error_procedure, error_line, logged_at
            )
            VALUES (
                @OrderId, ERROR_NUMBER(), @ErrorSeverity, @ErrorState,
                @ErrorMessage, ERROR_PROCEDURE(), ERROR_LINE(), SYSDATETIME()
            );

            SET @Errors = @Errors + 1;
        END CATCH;

        FETCH NEXT FROM order_cursor INTO @OrderId;
    END;

    CLOSE order_cursor;
    DEALLOCATE order_cursor;
END;
GO


-- Example 1.2: Stored procedure with table-valued parameters and THROW
CREATE TYPE dbo.OrderItemType AS TABLE (
    product_id  INT           NOT NULL,
    quantity    INT           NOT NULL,
    unit_price  DECIMAL(10,2) NOT NULL
);
GO

CREATE OR ALTER PROCEDURE dbo.CreateOrder
    @CustomerId   INT,
    @Items        dbo.OrderItemType READONLY,  -- Table-valued parameter (read-only)
    @OrderId      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Validate input
    IF NOT EXISTS (SELECT 1 FROM dbo.Customers WHERE customer_id = @CustomerId AND active = 1)
    BEGIN
        -- THROW (SQL Server 2012+) is preferred over RAISERROR for new code
        -- It always has severity 16 and respects XACT_ABORT
        THROW 50001, 'Customer not found or inactive.', 1;
    END;

    IF NOT EXISTS (SELECT 1 FROM @Items)
    BEGIN
        THROW 50002, 'Order must contain at least one item.', 1;
    END;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Create the order
        INSERT INTO dbo.Orders (customer_id, order_date, status, total_amount)
        VALUES (
            @CustomerId,
            SYSDATETIME(),
            'pending',
            (SELECT SUM(quantity * unit_price) FROM @Items)
        );

        SET @OrderId = SCOPE_IDENTITY();  -- Get the auto-generated ID

        -- Insert order items
        INSERT INTO dbo.OrderItems (order_id, product_id, quantity, unit_price)
        SELECT @OrderId, product_id, quantity, unit_price
        FROM @Items;

        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        -- Re-throw the original error with full context
        -- THROW without parameters re-raises the caught exception
        THROW;
    END CATCH;
END;
GO


-- ============================================================================
-- SECTION 2: MERGE STATEMENT WITH OUTPUT CLAUSE
-- ============================================================================

-- Example 2.1: MERGE with OUTPUT to log all changes
-- SQL Server's MERGE can capture what happened to each row via OUTPUT
DECLARE @MergeLog TABLE (
    action_type   NVARCHAR(10),
    customer_id   INT,
    old_tier      NVARCHAR(20),
    new_tier      NVARCHAR(20),
    old_total     DECIMAL(12, 2),
    new_total     DECIMAL(12, 2)
);

MERGE INTO dbo.CustomerSummary AS tgt
USING (
    SELECT
        customer_id,
        COUNT(*)            AS order_count,
        SUM(total_amount)   AS total_spent,
        MAX(order_date)     AS last_order_date
    FROM dbo.Orders
    WHERE order_date >= DATEADD(YEAR, -1, SYSDATETIME())
    GROUP BY customer_id
) AS src
ON tgt.customer_id = src.customer_id

WHEN MATCHED AND (tgt.total_spent <> src.total_spent OR tgt.order_count <> src.order_count) THEN
    UPDATE SET
        tgt.order_count     = src.order_count,
        tgt.total_spent     = src.total_spent,
        tgt.last_order_date = src.last_order_date,
        tgt.tier = CASE
            WHEN src.total_spent >= 10000 THEN 'platinum'
            WHEN src.total_spent >= 5000  THEN 'gold'
            WHEN src.total_spent >= 1000  THEN 'silver'
            ELSE 'bronze'
        END,
        tgt.updated_at = SYSDATETIME()

WHEN NOT MATCHED BY TARGET THEN
    INSERT (customer_id, order_count, total_spent, last_order_date, tier, updated_at)
    VALUES (
        src.customer_id,
        src.order_count,
        src.total_spent,
        src.last_order_date,
        CASE
            WHEN src.total_spent >= 10000 THEN 'platinum'
            WHEN src.total_spent >= 5000  THEN 'gold'
            WHEN src.total_spent >= 1000  THEN 'silver'
            ELSE 'bronze'
        END,
        SYSDATETIME()
    )

-- NOT MATCHED BY SOURCE: rows in target not in source (customer had no orders this year)
WHEN NOT MATCHED BY SOURCE THEN
    DELETE

-- OUTPUT captures every action taken by the MERGE
OUTPUT
    $action,
    COALESCE(INSERTED.customer_id, DELETED.customer_id),
    DELETED.tier,
    INSERTED.tier,
    DELETED.total_spent,
    INSERTED.total_spent
INTO @MergeLog (action_type, customer_id, old_tier, new_tier, old_total, new_total);

-- Review what the MERGE did
SELECT action_type, COUNT(*) AS row_count
FROM @MergeLog
GROUP BY action_type;

SELECT * FROM @MergeLog
WHERE old_tier <> new_tier;  -- Tier changes
GO


-- ============================================================================
-- SECTION 3: WINDOW FUNCTIONS WITH ROWS/RANGE FRAMES
-- ============================================================================

-- Example 3.1: Precise window framing with ROWS vs RANGE
-- ROWS operates on physical row positions; RANGE operates on logical value ranges.
-- Understanding the difference prevents subtle bugs with duplicate values.
SELECT
    customer_id,
    order_id,
    order_date,
    total_amount,

    -- ROWS BETWEEN: counts physical rows regardless of duplicate order_date values
    SUM(total_amount) OVER (
        PARTITION BY customer_id
        ORDER BY order_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_total_rows,

    -- RANGE BETWEEN: includes all rows with the same order_date as current row
    -- If two orders have the same date, RANGE includes both in every calculation
    SUM(total_amount) OVER (
        PARTITION BY customer_id
        ORDER BY order_date
        RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_total_range,

    -- 3-row moving average
    AVG(total_amount) OVER (
        PARTITION BY customer_id
        ORDER BY order_date
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ) AS moving_avg_3,

    -- Centered moving average (1 row before and after current)
    AVG(total_amount) OVER (
        PARTITION BY customer_id
        ORDER BY order_date
        ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING
    ) AS centered_avg,

    -- Percentage of partition total
    total_amount * 100.0 / SUM(total_amount) OVER (
        PARTITION BY customer_id
    ) AS pct_of_customer_total

FROM dbo.Orders
ORDER BY customer_id, order_date;


-- Example 3.2: FIRST_VALUE and LAST_VALUE with proper framing
-- LAST_VALUE requires explicit framing because the default frame
-- (RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) stops at the current row
SELECT
    department_id,
    employee_id,
    last_name,
    salary,
    FIRST_VALUE(last_name) OVER (
        PARTITION BY department_id ORDER BY salary DESC
    ) AS highest_paid_name,
    LAST_VALUE(last_name) OVER (
        PARTITION BY department_id ORDER BY salary DESC
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING  -- Must specify!
    ) AS lowest_paid_name
FROM dbo.Employees;


-- ============================================================================
-- SECTION 4: STRING_AGG AND STRING_SPLIT (2017+)
-- ============================================================================

-- Example 4.1: STRING_AGG for concatenating strings within groups
-- Replaces the old FOR XML PATH('') hack
SELECT
    c.customer_id,
    c.first_name + ' ' + c.last_name AS customer_name,
    STRING_AGG(p.category, ', ')
        WITHIN GROUP (ORDER BY p.category) AS categories_purchased,
    COUNT(DISTINCT p.category) AS category_count,
    STRING_AGG(CAST(o.order_id AS NVARCHAR(20)), ', ')
        WITHIN GROUP (ORDER BY o.order_date DESC) AS order_ids
FROM dbo.Customers c
INNER JOIN dbo.Orders o ON c.customer_id = o.customer_id
INNER JOIN dbo.OrderItems oi ON o.order_id = oi.order_id
INNER JOIN dbo.Products p ON oi.product_id = p.product_id
GROUP BY c.customer_id, c.first_name, c.last_name
HAVING COUNT(DISTINCT p.category) >= 2
ORDER BY category_count DESC;


-- Example 4.2: STRING_SPLIT for parsing delimited input
-- Splits a string by a delimiter into a single-column table of values
-- Commonly used for "IN clause with a parameter" patterns
CREATE OR ALTER PROCEDURE dbo.GetProductsByCategories
    @CategoryList NVARCHAR(MAX)   -- e.g., 'Electronics,Books,Toys'
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.*
    FROM dbo.Products p
    INNER JOIN STRING_SPLIT(@CategoryList, ',') ss ON p.category = TRIM(ss.value)
    WHERE p.is_active = 1
    ORDER BY p.category, p.name;
END;
GO

-- SQL Server 2022+ adds ordinal output to STRING_SPLIT
-- The enable_ordinal parameter returns the 1-based position of each element
SELECT value, ordinal
FROM STRING_SPLIT('red,green,blue,yellow', ',', 1)
ORDER BY ordinal;


-- ============================================================================
-- SECTION 5: JSON OPERATIONS
-- ============================================================================

-- Example 5.1: FOR JSON - Generate JSON from query results
-- PATH mode gives full control over JSON structure
SELECT
    c.customer_id                                AS 'id',
    c.first_name + ' ' + c.last_name             AS 'name',
    c.email                                       AS 'contact.email',
    c.phone                                       AS 'contact.phone',
    (
        SELECT
            o.order_id                            AS 'orderId',
            FORMAT(o.order_date, 'yyyy-MM-dd')    AS 'date',
            o.total_amount                        AS 'total',
            o.status                              AS 'status'
        FROM dbo.Orders o
        WHERE o.customer_id = c.customer_id
        ORDER BY o.order_date DESC
        FOR JSON PATH
    )                                             AS 'orders'
FROM dbo.Customers c
WHERE c.customer_id = 42
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;  -- Single object, not array
GO


-- Example 5.2: OPENJSON - Parse JSON into relational rows
-- Converts a JSON array into a result set with typed columns
DECLARE @OrderJson NVARCHAR(MAX) = N'{
    "customer_id": 42,
    "order_date": "2025-03-15",
    "items": [
        {"product_id": 101, "name": "Widget A", "qty": 3, "price": 29.99},
        {"product_id": 205, "name": "Gadget B", "qty": 1, "price": 149.50},
        {"product_id": 310, "name": "Doohickey", "qty": 5, "price": 9.99}
    ]
}';

-- Extract scalar values
SELECT
    JSON_VALUE(@OrderJson, '$.customer_id')  AS customer_id,
    JSON_VALUE(@OrderJson, '$.order_date')   AS order_date;

-- Shred the items array into rows with explicit schema
SELECT *
FROM OPENJSON(@OrderJson, '$.items')
WITH (
    product_id   INT            '$.product_id',
    product_name NVARCHAR(100)  '$.name',
    quantity     INT            '$.qty',
    unit_price   DECIMAL(10,2)  '$.price'
);
GO


-- Example 5.3: JSON_MODIFY - Update JSON values in place
-- Useful for patching JSON documents stored in NVARCHAR columns
UPDATE dbo.UserPreferences
SET settings = JSON_MODIFY(
    JSON_MODIFY(
        JSON_MODIFY(
            settings,
            '$.notifications.email', CAST(1 AS BIT)  -- Set nested property
        ),
        '$.theme', 'dark'                             -- Set top-level property
    ),
    'append $.favoriteCategories', 'Electronics'       -- Append to array
)
WHERE user_id = 42
  AND ISJSON(settings) = 1;  -- Guard: only modify valid JSON


-- Example 5.4: Query a table with JSON column using JSON_VALUE and OPENJSON
-- Create an index on a computed column derived from JSON for fast lookups
ALTER TABLE dbo.ApiEvents
ADD event_user_id AS CAST(JSON_VALUE(payload, '$.user_id') AS INT) PERSISTED;

CREATE INDEX idx_api_events_user_id ON dbo.ApiEvents (event_user_id)
WHERE event_user_id IS NOT NULL;

-- Now queries filtering on user_id inside JSON use the index
SELECT event_id, event_type, payload
FROM dbo.ApiEvents
WHERE event_user_id = 42
  AND JSON_VALUE(payload, '$.action') = 'login';
GO


-- ============================================================================
-- SECTION 6: TEMPORAL TABLES (SYSTEM-VERSIONED)
-- ============================================================================

-- Example 6.1: Create a system-versioned temporal table for automatic audit trail
-- SQL Server automatically tracks all changes to the table with full history
CREATE TABLE dbo.Products (
    product_id      INT IDENTITY(1,1) NOT NULL PRIMARY KEY CLUSTERED,
    name            NVARCHAR(100)     NOT NULL,
    category        NVARCHAR(50)      NOT NULL,
    base_price      DECIMAL(10, 2)    NOT NULL,
    stock_quantity  INT               NOT NULL DEFAULT 0,
    is_active       BIT               NOT NULL DEFAULT 1,

    -- Temporal columns: SQL Server manages these automatically
    valid_from      DATETIME2 GENERATED ALWAYS AS ROW START NOT NULL,
    valid_to        DATETIME2 GENERATED ALWAYS AS ROW END   NOT NULL,

    -- Enable system versioning
    PERIOD FOR SYSTEM_TIME (valid_from, valid_to)
)
WITH (SYSTEM_VERSIONING = ON (
    HISTORY_TABLE = dbo.ProductsHistory,
    DATA_CONSISTENCY_CHECK = ON
));
GO


-- Example 6.2: Query temporal table history
-- AS OF: point-in-time snapshot
SELECT product_id, name, base_price, valid_from, valid_to
FROM dbo.Products
FOR SYSTEM_TIME AS OF '2025-01-15T10:00:00'
WHERE product_id = 101;

-- BETWEEN: all versions that overlap with a time range
SELECT product_id, name, base_price, valid_from, valid_to
FROM dbo.Products
FOR SYSTEM_TIME BETWEEN '2025-01-01' AND '2025-03-31'
WHERE product_id = 101
ORDER BY valid_from;

-- ALL: every version that ever existed
SELECT product_id, name, base_price, valid_from, valid_to
FROM dbo.Products
FOR SYSTEM_TIME ALL
WHERE product_id = 101
ORDER BY valid_from;

-- Find what changed (compare consecutive versions)
SELECT
    curr.product_id,
    curr.name,
    prev.base_price AS old_price,
    curr.base_price AS new_price,
    curr.base_price - prev.base_price AS price_change,
    curr.valid_from AS changed_at
FROM dbo.Products FOR SYSTEM_TIME ALL curr
INNER JOIN dbo.Products FOR SYSTEM_TIME ALL prev
    ON curr.product_id = prev.product_id
    AND curr.valid_from = prev.valid_to   -- Current version starts where previous ended
WHERE curr.base_price <> prev.base_price
ORDER BY curr.valid_from DESC;


-- ============================================================================
-- SECTION 7: IN-MEMORY OLTP (MEMORY-OPTIMIZED TABLES)
-- ============================================================================

-- Example 7.1: Create a memory-optimized table
-- Requires a MEMORY_OPTIMIZED_DATA filegroup on the database
-- These tables live entirely in memory for extreme OLTP performance

-- First, ensure the database has a memory-optimized filegroup:
-- ALTER DATABASE MyDB ADD FILEGROUP mem_fg CONTAINS MEMORY_OPTIMIZED_DATA;
-- ALTER DATABASE MyDB ADD FILE (NAME='mem_file', FILENAME='C:\data\mem_file')
--     TO FILEGROUP mem_fg;

CREATE TABLE dbo.SessionCache (
    session_id     UNIQUEIDENTIFIER NOT NULL PRIMARY KEY NONCLUSTERED
                       HASH WITH (BUCKET_COUNT = 131072),
    user_id        INT              NOT NULL,
    session_data   NVARCHAR(MAX)    NOT NULL,
    created_at     DATETIME2        NOT NULL DEFAULT SYSDATETIME(),
    expires_at     DATETIME2        NOT NULL,

    -- Hash index for fast point lookups
    INDEX ix_session_user HASH (user_id) WITH (BUCKET_COUNT = 65536)
)
WITH (
    MEMORY_OPTIMIZED = ON,
    DURABILITY = SCHEMA_AND_DATA  -- Survives restart; use SCHEMA_ONLY for temp data
);
GO


-- Example 7.2: Natively compiled stored procedure for memory-optimized tables
-- These procedures are compiled to native machine code (C DLL) for max speed
-- They have restrictions: no cursors, no temp tables, limited T-SQL surface
CREATE OR ALTER PROCEDURE dbo.UpsertSession
    @SessionId   UNIQUEIDENTIFIER,
    @UserId      INT,
    @SessionData NVARCHAR(MAX),
    @TtlMinutes  INT = 30
WITH NATIVE_COMPILATION, SCHEMABINDING
AS
BEGIN ATOMIC WITH (
    TRANSACTION ISOLATION LEVEL = SNAPSHOT,
    LANGUAGE = N'English'
)
    -- Delete existing session if present
    DELETE FROM dbo.SessionCache
    WHERE session_id = @SessionId;

    -- Insert new/updated session
    INSERT INTO dbo.SessionCache (session_id, user_id, session_data, expires_at)
    VALUES (@SessionId, @UserId, @SessionData, DATEADD(MINUTE, @TtlMinutes, SYSDATETIME()));
END;
GO


-- ============================================================================
-- SECTION 8: GRAPH TABLES AND MATCH QUERIES (2017+)
-- ============================================================================

-- Example 8.1: Create graph node and edge tables
-- SQL Server graph tables model nodes and edges for relationship queries
CREATE TABLE dbo.Person (
    person_id   INT IDENTITY(1,1) PRIMARY KEY,
    name        NVARCHAR(100) NOT NULL,
    email       NVARCHAR(200),
    department  NVARCHAR(50)
) AS NODE;  -- Node table: each row is a vertex in the graph

CREATE TABLE dbo.Project (
    project_id  INT IDENTITY(1,1) PRIMARY KEY,
    name        NVARCHAR(200) NOT NULL,
    start_date  DATE,
    status      NVARCHAR(20)
) AS NODE;

CREATE TABLE dbo.WorksOn (
    role         NVARCHAR(50),
    hours_per_week DECIMAL(4,1),
    start_date   DATE
) AS EDGE;  -- Edge table: each row is a directed relationship between two nodes

CREATE TABLE dbo.ReportsTo (
    since_date DATE
) AS EDGE;
GO


-- Example 8.2: Insert graph data
INSERT INTO dbo.Person (name, email, department) VALUES
    ('Alice Chen', 'alice@example.com', 'Engineering'),
    ('Bob Smith', 'bob@example.com', 'Engineering'),
    ('Carol Davis', 'carol@example.com', 'Product'),
    ('Dan Wilson', 'dan@example.com', 'Engineering');

INSERT INTO dbo.Project (name, start_date, status) VALUES
    ('Platform Redesign', '2025-01-15', 'active'),
    ('Mobile App v3', '2025-03-01', 'planning');

-- Edge inserts reference the $node_id pseudo-columns
INSERT INTO dbo.WorksOn ($from_id, $to_id, role, hours_per_week)
SELECT p.node_id, proj.node_id, 'Lead', 30
FROM (SELECT $node_id AS node_id FROM dbo.Person WHERE name = 'Alice Chen') p,
     (SELECT $node_id AS node_id FROM dbo.Project WHERE name = 'Platform Redesign') proj;

INSERT INTO dbo.ReportsTo ($from_id, $to_id, since_date)
SELECT emp.node_id, mgr.node_id, '2024-06-01'
FROM (SELECT $node_id AS node_id FROM dbo.Person WHERE name = 'Bob Smith') emp,
     (SELECT $node_id AS node_id FROM dbo.Person WHERE name = 'Alice Chen') mgr;
GO


-- Example 8.3: Query the graph using MATCH
-- MATCH uses ASCII-art-like syntax to express graph traversal patterns
-- Find people who work on projects led by someone they report to
SELECT
    employee.name   AS employee,
    manager.name    AS manager,
    project.name    AS project_name,
    wo_mgr.role     AS manager_role
FROM dbo.Person AS employee,
     dbo.ReportsTo AS reports_to,
     dbo.Person AS manager,
     dbo.WorksOn AS wo_mgr,
     dbo.Project AS project
WHERE MATCH(employee-(reports_to)->manager-(wo_mgr)->project)
  AND wo_mgr.role = 'Lead';

-- SQL Server 2019+: Shortest path queries
-- Find the shortest reporting chain between two people
SELECT
    PersonName = STRING_AGG(person.name, ' -> ')
        WITHIN GROUP (GRAPH PATH)
FROM dbo.Person AS person,
     dbo.ReportsTo FOR PATH AS reports
WHERE MATCH(SHORTEST_PATH(person(-(reports)->person)+))
  AND person.name = 'Dan Wilson';
GO


-- ============================================================================
-- SECTION 9: COLUMNSTORE INDEXES
-- ============================================================================

-- Example 9.1: Clustered columnstore index for analytics/data warehouse tables
-- Columnstore stores data by column, enabling massive compression and fast
-- analytical queries (100x+ performance improvement for scans/aggregations)
CREATE TABLE dbo.SalesFactHistory (
    sale_date       DATE            NOT NULL,
    product_id      INT             NOT NULL,
    customer_id     INT             NOT NULL,
    store_id        INT             NOT NULL,
    quantity        INT             NOT NULL,
    unit_price      DECIMAL(10, 2)  NOT NULL,
    discount_pct    DECIMAL(5, 2)   DEFAULT 0,
    total_amount    DECIMAL(12, 2)  NOT NULL,

    -- Clustered columnstore: entire table stored in columnar format
    INDEX cci_salesfacthistory CLUSTERED COLUMNSTORE
);
GO


-- Example 9.2: Nonclustered columnstore index on an OLTP table
-- Enables real-time analytics on an OLTP table without a separate data warehouse
-- The rowstore (B-tree) handles OLTP; the columnstore handles analytics
CREATE TABLE dbo.Orders_HTAP (
    order_id       INT IDENTITY(1,1) PRIMARY KEY CLUSTERED,  -- B-tree for OLTP
    customer_id    INT NOT NULL,
    order_date     DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
    status         NVARCHAR(20) NOT NULL DEFAULT 'pending',
    total_amount   DECIMAL(12,2) NOT NULL,
    region         NVARCHAR(50)
);

-- Add a nonclustered columnstore for analytics queries
CREATE NONCLUSTERED COLUMNSTORE INDEX ncci_orders_analytics
ON dbo.Orders_HTAP (customer_id, order_date, status, total_amount, region);

-- Now OLTP queries use the B-tree primary key,
-- while analytical queries use the columnstore:
SELECT
    region,
    DATEPART(YEAR, order_date)  AS order_year,
    DATEPART(MONTH, order_date) AS order_month,
    COUNT(*)                    AS order_count,
    SUM(total_amount)           AS total_revenue,
    AVG(total_amount)           AS avg_order_value
FROM dbo.Orders_HTAP
WHERE order_date >= '2024-01-01'
GROUP BY region, DATEPART(YEAR, order_date), DATEPART(MONTH, order_date)
ORDER BY region, order_year, order_month;
GO


-- ============================================================================
-- SECTION 10: SEQUENCE OBJECTS
-- ============================================================================

-- Example 10.1: Create and use a SEQUENCE
-- Sequences are independent objects (not tied to a table like IDENTITY)
-- Useful when multiple tables share a number series
CREATE SEQUENCE dbo.GlobalOrderSequence
    AS BIGINT
    START WITH 1000000
    INCREMENT BY 1
    MINVALUE 1000000
    NO MAXVALUE
    NO CYCLE
    CACHE 50;
GO

-- Use NEXT VALUE FOR in an INSERT
INSERT INTO dbo.Orders (order_id, customer_id, order_date, status, total_amount)
VALUES (
    NEXT VALUE FOR dbo.GlobalOrderSequence,
    42,
    SYSDATETIME(),
    'pending',
    299.99
);

-- Use as a default constraint
ALTER TABLE dbo.InternalDocuments
ADD CONSTRAINT df_doc_number
DEFAULT (NEXT VALUE FOR dbo.GlobalOrderSequence) FOR document_number;

-- Generate a range of sequence values (SQL Server 2012+)
SELECT value AS sequence_value
FROM GENERATE_SERIES(
    CAST(NEXT VALUE FOR dbo.GlobalOrderSequence AS BIGINT),
    CAST(NEXT VALUE FOR dbo.GlobalOrderSequence AS BIGINT) + 9  -- 10 values
);
-- Note: GENERATE_SERIES requires SQL Server 2022+
-- For earlier versions, use a numbers table or recursive CTE
GO


-- ============================================================================
-- SECTION 11: CROSS APPLY AND OUTER APPLY
-- ============================================================================

-- Example 11.1: CROSS APPLY - like INNER JOIN but for correlated subqueries
-- Returns only rows where the applied function/subquery returns results
-- CROSS APPLY evaluates the right side for each row on the left side
SELECT
    c.customer_id,
    c.first_name + ' ' + c.last_name AS customer_name,
    recent.order_id,
    recent.order_date,
    recent.total_amount
FROM dbo.Customers c
CROSS APPLY (
    -- Get top 3 most recent orders per customer
    SELECT TOP (3) o.order_id, o.order_date, o.total_amount
    FROM dbo.Orders o
    WHERE o.customer_id = c.customer_id
    ORDER BY o.order_date DESC
) recent
ORDER BY c.customer_id, recent.order_date DESC;


-- Example 11.2: OUTER APPLY - like LEFT JOIN for correlated subqueries
-- Returns all rows from the left side, with NULLs where no match exists
SELECT
    c.customer_id,
    c.first_name + ' ' + c.last_name AS customer_name,
    stats.order_count,
    stats.total_spent,
    stats.first_order,
    stats.last_order
FROM dbo.Customers c
OUTER APPLY (
    SELECT
        COUNT(*)            AS order_count,
        SUM(total_amount)   AS total_spent,
        MIN(order_date)     AS first_order,
        MAX(order_date)     AS last_order
    FROM dbo.Orders o
    WHERE o.customer_id = c.customer_id
) stats
ORDER BY stats.total_spent DESC;


-- Example 11.3: CROSS APPLY with a table-valued function
-- Split a comma-separated tag column into individual rows
SELECT
    p.product_id,
    p.name,
    tag.value AS tag
FROM dbo.Products p
CROSS APPLY STRING_SPLIT(p.tags, ',') tag
WHERE p.tags IS NOT NULL
ORDER BY p.product_id;


-- Example 11.4: OUTER APPLY for top-N-per-group with additional computed data
SELECT
    d.department_id,
    d.name AS department_name,
    top_emp.employee_id,
    top_emp.last_name,
    top_emp.salary,
    top_emp.rank_in_dept
FROM dbo.Departments d
OUTER APPLY (
    SELECT
        e.employee_id,
        e.last_name,
        e.salary,
        ROW_NUMBER() OVER (ORDER BY e.salary DESC) AS rank_in_dept
    FROM dbo.Employees e
    WHERE e.department_id = d.department_id
      AND e.is_active = 1
) top_emp
WHERE top_emp.rank_in_dept <= 3 OR top_emp.rank_in_dept IS NULL
ORDER BY d.department_id, top_emp.rank_in_dept;
GO


-- ============================================================================
-- SECTION 12: RECURSIVE CTEs
-- ============================================================================

-- Example 12.1: Recursive CTE for org chart hierarchy
-- SQL Server recursive CTEs do NOT use the RECURSIVE keyword (unlike PostgreSQL)
WITH OrgChart AS (
    -- Anchor: top-level managers (no manager_id)
    SELECT
        employee_id,
        first_name + ' ' + last_name AS full_name,
        title,
        manager_id,
        CAST(first_name + ' ' + last_name AS NVARCHAR(MAX)) AS hierarchy_path,
        0 AS depth
    FROM dbo.Employees
    WHERE manager_id IS NULL

    UNION ALL

    -- Recursive member: employees who report to someone already in the result
    SELECT
        e.employee_id,
        e.first_name + ' ' + e.last_name,
        e.title,
        e.manager_id,
        oc.hierarchy_path + ' > ' + e.first_name + ' ' + e.last_name,
        oc.depth + 1
    FROM dbo.Employees e
    INNER JOIN OrgChart oc ON e.manager_id = oc.employee_id
)
SELECT
    employee_id,
    REPLICATE('    ', depth) + full_name AS indented_name,
    title,
    depth,
    hierarchy_path
FROM OrgChart
ORDER BY hierarchy_path
-- OPTION (MAXRECURSION 100);  -- Default is 100; set to 0 for unlimited
;


-- Example 12.2: Recursive CTE for generating a date range
WITH DateSeries AS (
    SELECT CAST('2025-01-01' AS DATE) AS dt
    UNION ALL
    SELECT DATEADD(DAY, 1, dt) FROM DateSeries WHERE dt < '2025-12-31'
)
SELECT
    dt AS calendar_date,
    DATENAME(WEEKDAY, dt) AS day_name,
    DATEPART(ISO_WEEK, dt) AS iso_week,
    EOMONTH(dt) AS end_of_month,
    IIF(DATEPART(WEEKDAY, dt) IN (1, 7), 'Weekend', 'Weekday') AS day_type
FROM DateSeries
OPTION (MAXRECURSION 366);  -- 366 to cover leap years


-- ============================================================================
-- SECTION 13: INDEXED VIEWS (MATERIALIZED VIEWS EQUIVALENT)
-- ============================================================================

-- Example 13.1: Create an indexed view for pre-computed aggregations
-- SQL Server indexed views physically store the result set on disk
-- and are automatically maintained (updated) by the engine on every DML

-- Requirements for indexed views:
-- 1. View must be created WITH SCHEMABINDING
-- 2. First index must be a unique clustered index
-- 3. Only certain functions/operations are allowed (no subqueries, OUTER JOIN, etc.)

CREATE OR ALTER VIEW dbo.vw_DailySalesSummary
WITH SCHEMABINDING  -- Required: locks the view to the base table schemas
AS
SELECT
    CAST(o.order_date AS DATE) AS sale_date,
    p.category,
    COUNT_BIG(*) AS order_line_count,   -- COUNT_BIG required (not COUNT)
    SUM(oi.quantity)                    AS total_quantity,
    SUM(oi.quantity * oi.unit_price)    AS total_revenue
FROM dbo.Orders o
INNER JOIN dbo.OrderItems oi ON o.order_id = oi.order_id
INNER JOIN dbo.Products p ON oi.product_id = p.product_id
WHERE o.status <> 'cancelled'
GROUP BY CAST(o.order_date AS DATE), p.category;
GO

-- Create the unique clustered index to materialize the view
CREATE UNIQUE CLUSTERED INDEX uci_daily_sales
ON dbo.vw_DailySalesSummary (sale_date, category);

-- Add a nonclustered index for queries filtering by category
CREATE NONCLUSTERED INDEX nci_daily_sales_category
ON dbo.vw_DailySalesSummary (category, sale_date)
INCLUDE (total_revenue, total_quantity);

-- Enterprise Edition: the optimizer automatically uses the indexed view
-- even when queries don't reference it directly.
-- Standard Edition: you must reference the view with NOEXPAND hint.
SELECT sale_date, category, total_revenue
FROM dbo.vw_DailySalesSummary WITH (NOEXPAND)
WHERE category = 'Electronics'
  AND sale_date >= '2025-01-01'
ORDER BY sale_date;
GO


-- ============================================================================
-- SECTION 14: OFFSET/FETCH PAGINATION
-- ============================================================================

-- Example 14.1: Basic keyset pagination (preferred for performance)
-- Keyset (seek) pagination is more efficient than OFFSET for large datasets
-- because it uses an index seek instead of scanning and skipping rows
DECLARE @LastOrderId   INT = 0;      -- From previous page's last row
DECLARE @LastOrderDate DATETIME2;     -- From previous page's last row
DECLARE @PageSize      INT = 25;

-- First page (no previous cursor)
SELECT TOP (@PageSize)
    order_id,
    customer_id,
    order_date,
    total_amount,
    status
FROM dbo.Orders
ORDER BY order_date DESC, order_id DESC;

-- Subsequent pages: use the last values from the previous page
SELECT TOP (@PageSize)
    order_id,
    customer_id,
    order_date,
    total_amount,
    status
FROM dbo.Orders
WHERE (order_date < @LastOrderDate)
   OR (order_date = @LastOrderDate AND order_id < @LastOrderId)
ORDER BY order_date DESC, order_id DESC;


-- Example 14.2: OFFSET/FETCH for page-number-based pagination
-- Simpler but slower on large offsets because SQL Server must scan & skip rows
DECLARE @PageNumber INT = 5;
DECLARE @RowsPerPage INT = 25;

SELECT
    order_id,
    customer_id,
    order_date,
    total_amount,
    status
FROM dbo.Orders
ORDER BY order_date DESC, order_id DESC
OFFSET (@PageNumber - 1) * @RowsPerPage ROWS
FETCH NEXT @RowsPerPage ROWS ONLY;


-- Example 14.3: Pagination with total count (common API pattern)
DECLARE @Page INT = 3;
DECLARE @Size INT = 20;

SELECT
    order_id,
    customer_id,
    order_date,
    total_amount,
    COUNT(*) OVER () AS total_count  -- Total matching rows (window function)
FROM dbo.Orders
WHERE status = 'processing'
ORDER BY order_date DESC
OFFSET (@Page - 1) * @Size ROWS
FETCH NEXT @Size ROWS ONLY;
GO


-- ============================================================================
-- SECTION 15: TRY_CAST, TRY_CONVERT, TRY_PARSE FOR SAFE TYPE CONVERSIONS
-- ============================================================================

-- Example 15.1: TRY_CAST - returns NULL instead of error on conversion failure
-- Essential for cleaning dirty data from imports or user input
SELECT
    raw_value,
    TRY_CAST(raw_value AS INT)            AS as_int,
    TRY_CAST(raw_value AS DECIMAL(10,2))  AS as_decimal,
    TRY_CAST(raw_value AS DATE)           AS as_date,
    TRY_CAST(raw_value AS UNIQUEIDENTIFIER) AS as_guid,
    CASE
        WHEN TRY_CAST(raw_value AS INT) IS NOT NULL THEN 'integer'
        WHEN TRY_CAST(raw_value AS DECIMAL(10,2)) IS NOT NULL THEN 'decimal'
        WHEN TRY_CAST(raw_value AS DATE) IS NOT NULL THEN 'date'
        WHEN TRY_CAST(raw_value AS UNIQUEIDENTIFIER) IS NOT NULL THEN 'guid'
        ELSE 'string'
    END AS detected_type
FROM dbo.ImportStaging;


-- Example 15.2: TRY_CONVERT with style codes
-- TRY_CONVERT supports style parameters for date/number formatting
SELECT
    date_string,
    TRY_CONVERT(DATE, date_string, 101) AS us_format,     -- MM/DD/YYYY
    TRY_CONVERT(DATE, date_string, 103) AS uk_format,     -- DD/MM/YYYY
    TRY_CONVERT(DATE, date_string, 120) AS iso_format,    -- YYYY-MM-DD HH:MI:SS
    TRY_CONVERT(DATE, date_string, 112) AS compact_format -- YYYYMMDD
FROM (VALUES
    ('03/15/2025'),
    ('15/03/2025'),
    ('2025-03-15'),
    ('20250315'),
    ('not a date'),
    (NULL)
) AS samples(date_string);


-- Example 15.3: TRY_PARSE with culture codes for locale-aware parsing
-- TRY_PARSE uses the .NET Framework for parsing, so it supports culture codes
-- It is slower than TRY_CAST/TRY_CONVERT but handles more formats
SELECT
    amount_string,
    TRY_PARSE(amount_string AS DECIMAL(10,2) USING 'en-US') AS us_amount,   -- 1,234.56
    TRY_PARSE(amount_string AS DECIMAL(10,2) USING 'de-DE') AS de_amount,   -- 1.234,56
    TRY_PARSE(amount_string AS DECIMAL(10,2) USING 'fr-FR') AS fr_amount    -- 1 234,56
FROM (VALUES
    ('1,234.56'),
    ('1.234,56'),
    ('$1,000.00'),
    ('invalid')
) AS samples(amount_string);


-- Example 15.4: Data cleaning pipeline using TRY functions
-- Clean and validate import data before inserting into production tables
INSERT INTO dbo.Customers (first_name, last_name, email, signup_date, loyalty_points)
SELECT
    TRIM(first_name),
    TRIM(last_name),
    LOWER(TRIM(email)),
    COALESCE(
        TRY_CONVERT(DATE, signup_date, 120),   -- Try ISO format first
        TRY_CONVERT(DATE, signup_date, 101),   -- Try US format
        TRY_CONVERT(DATE, signup_date, 103),   -- Try UK format
        CAST(GETDATE() AS DATE)                -- Fallback to today
    ),
    COALESCE(TRY_CAST(loyalty_points AS INT), 0)
FROM dbo.CustomerImportStaging
WHERE TRIM(first_name) <> ''
  AND TRIM(last_name)  <> ''
  AND TRIM(email) LIKE '%_@_%.__%'     -- Basic email validation
  AND TRY_CAST(email AS NVARCHAR(200)) IS NOT NULL;
GO
