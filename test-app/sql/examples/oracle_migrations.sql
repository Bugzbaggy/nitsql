-- ============================================================================
-- ORACLE DATABASE MIGRATION EXAMPLES
-- ============================================================================
-- This file demonstrates Oracle-specific migration patterns including:
-- - Online DDL operations (ALTER TABLE ... ONLINE)
-- - DBMS_REDEFINITION for zero-downtime table restructuring
-- - Adding columns with DEFAULT ON NULL (12c+, no table rewrite)
-- - Invisible columns for backward compatibility
-- - Partition management (ADD, SPLIT, MERGE, EXCHANGE partitions)
-- - Edition-based redefinition for rolling upgrades
-- - Materialized view log management
-- - Tablespace management and data file operations
-- - Converting to partitioned tables (12.2+ online conversion)
-- - Index maintenance (REBUILD ONLINE, INVISIBLE indexes for testing)
-- - Renaming columns and tables with dependency tracking
-- - Data pump patterns for large data migrations
-- ============================================================================

-- Oracle Migration Best Practices:
-- 1. Always test migrations on a clone of production (RMAN or Data Pump)
-- 2. Use ONLINE operations whenever possible to avoid locks
-- 3. Run DBMS_STATS.GATHER_TABLE_STATS after structural changes
-- 4. Monitor V$SESSION_LONGOPS for progress on long DDL operations
-- 5. Plan for UNDO tablespace consumption during large DML operations
-- 6. Use DBMS_REDEFINITION for complex changes requiring zero downtime
-- 7. Always have a rollback plan and test it before executing the migration


-- ============================================================================
-- SECTION 1: ONLINE DDL OPERATIONS
-- ============================================================================

-- Migration 1.1: Add a column with DEFAULT (Oracle 12c+: metadata-only, instant)
-- ============================================================================
-- In Oracle 12c+, adding a column with a DEFAULT and NOT NULL constraint is a
-- metadata-only operation. Oracle does NOT rewrite the table; existing rows
-- return the default value lazily. This is safe on billion-row tables.

-- UP
ALTER TABLE orders
ADD (priority NUMBER(1) DEFAULT 3 NOT NULL);
-- Oracle stores the default in the data dictionary; existing rows appear to have
-- the value 3 without any physical update. Only newly inserted/updated rows
-- store the value physically.

-- DOWN
ALTER TABLE orders DROP (priority);


-- Migration 1.2: DEFAULT ON NULL (Oracle 12c+)
-- ============================================================================
-- DEFAULT ON NULL means: if an INSERT provides an explicit NULL for this column,
-- Oracle replaces it with the default value. This is stricter than a plain DEFAULT.

-- UP
ALTER TABLE customers
ADD (account_status VARCHAR2(20) DEFAULT ON NULL 'active' NOT NULL);

-- Verify: even explicit NULL inserts get the default
-- INSERT INTO customers (..., account_status) VALUES (..., NULL);
-- SELECT account_status FROM customers WHERE customer_id = ...;
-- Result: 'active' (not NULL)

-- DOWN
ALTER TABLE customers DROP (account_status);


-- Migration 1.3: Online index creation
-- ============================================================================
-- ONLINE allows concurrent DML while the index is being built.
-- Without ONLINE, Oracle holds an exclusive lock on the table.

-- UP
CREATE INDEX idx_orders_cust_status ON orders (customer_id, status) ONLINE;

-- For very large tables, use PARALLEL and NOLOGGING to speed up creation,
-- then rebuild with logging for production safety
CREATE INDEX idx_orders_date_amount ON orders (order_date, total_amount)
    TABLESPACE idx_ts
    PARALLEL 4
    NOLOGGING
    ONLINE;

-- Re-enable logging after creation (important for recoverability)
ALTER INDEX idx_orders_date_amount LOGGING;
ALTER INDEX idx_orders_date_amount NOPARALLEL;

-- DOWN
DROP INDEX idx_orders_cust_status;
DROP INDEX idx_orders_date_amount;


-- Migration 1.4: Online table move (12c+: move table without downtime)
-- ============================================================================
-- Moves a table to a different tablespace while DML continues
-- Also compresses the table and updates all indexes automatically

-- UP
ALTER TABLE orders MOVE
    TABLESPACE data_ts
    COMPRESS FOR OLTP        -- Advanced row compression
    UPDATE INDEXES            -- Rebuild all indexes during the move
    ONLINE;                   -- Allow concurrent DML

-- Verify new location
-- SELECT tablespace_name FROM user_tables WHERE table_name = 'ORDERS';

-- DOWN (move back to original tablespace)
-- ALTER TABLE orders MOVE TABLESPACE original_ts UPDATE INDEXES ONLINE;


-- ============================================================================
-- SECTION 2: DBMS_REDEFINITION (ZERO-DOWNTIME TABLE RESTRUCTURING)
-- ============================================================================

-- Migration 2.1: Restructure a table online using DBMS_REDEFINITION
-- ============================================================================
-- DBMS_REDEFINITION creates an interim table, synchronizes data via materialized
-- view logs, and performs an atomic swap. The original table remains available
-- for DML throughout the entire process.

-- Step 1: Verify the table can be redefined
-- Must have a primary key or use DBMS_REDEFINITION.CONS_USE_ROWID
DECLARE
    v_can_redefine BOOLEAN;
BEGIN
    DBMS_REDEFINITION.CAN_REDEF_TABLE(
        uname       => USER,
        tname       => 'ORDERS',
        options_flag => DBMS_REDEFINITION.CONS_USE_PK
    );
    DBMS_OUTPUT.PUT_LINE('Table can be redefined online.');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Cannot redefine: ' || SQLERRM);
        RAISE;
END;
/

-- Step 2: Create the interim table with the desired new structure
CREATE TABLE orders_interim (
    order_id         NUMBER NOT NULL,
    customer_id      NUMBER NOT NULL,
    order_date       TIMESTAMP DEFAULT SYSTIMESTAMP,
    status           VARCHAR2(20) DEFAULT 'pending',
    total_amount     NUMBER(12, 2),
    priority         NUMBER(1) DEFAULT 3,
    -- New columns added during restructuring:
    order_source     VARCHAR2(50) DEFAULT 'web',
    fulfillment_type VARCHAR2(20) DEFAULT 'standard',
    created_at       TIMESTAMP DEFAULT SYSTIMESTAMP,
    updated_at       TIMESTAMP DEFAULT SYSTIMESTAMP,
    -- Change to range-partitioned structure
    CONSTRAINT pk_orders_interim PRIMARY KEY (order_id)
)
PARTITION BY RANGE (order_date) (
    PARTITION p_2023 VALUES LESS THAN (TIMESTAMP '2024-01-01 00:00:00'),
    PARTITION p_2024 VALUES LESS THAN (TIMESTAMP '2025-01-01 00:00:00'),
    PARTITION p_2025 VALUES LESS THAN (TIMESTAMP '2026-01-01 00:00:00'),
    PARTITION p_max  VALUES LESS THAN (MAXVALUE)
);

-- Step 3: Start the redefinition process
BEGIN
    DBMS_REDEFINITION.START_REDEF_TABLE(
        uname         => USER,
        orig_table    => 'ORDERS',
        int_table     => 'ORDERS_INTERIM',
        -- Column mapping: map old columns to new structure
        col_mapping   => 'order_id order_id, '                          ||
                         'customer_id customer_id, '                      ||
                         'order_date order_date, '                        ||
                         'status status, '                                ||
                         'total_amount total_amount, '                    ||
                         'NVL(priority, 3) priority, '                    ||
                         '''web'' order_source, '                         ||
                         '''standard'' fulfillment_type, '                ||
                         'created_at created_at, '                        ||
                         'NVL(updated_at, SYSTIMESTAMP) updated_at',
        options_flag  => DBMS_REDEFINITION.CONS_USE_PK
    );
END;
/

-- Step 4: Copy dependent objects (indexes, constraints, triggers, grants)
DECLARE
    v_errors PLS_INTEGER;
BEGIN
    DBMS_REDEFINITION.COPY_TABLE_DEPENDENTS(
        uname            => USER,
        orig_table       => 'ORDERS',
        int_table        => 'ORDERS_INTERIM',
        copy_indexes     => DBMS_REDEFINITION.CONS_ORIG_PARAMS,
        copy_triggers    => TRUE,
        copy_constraints => TRUE,
        copy_privileges  => TRUE,
        ignore_errors    => FALSE,
        num_errors       => v_errors
    );
    DBMS_OUTPUT.PUT_LINE('Dependent objects copied. Errors: ' || v_errors);
END;
/

-- Step 5: Optionally sync interim table if redefinition takes a long time
-- This reduces the time for the final FINISH step
BEGIN
    DBMS_REDEFINITION.SYNC_INTERIM_TABLE(
        uname      => USER,
        orig_table => 'ORDERS',
        int_table  => 'ORDERS_INTERIM'
    );
END;
/

-- Step 6: Finish redefinition (atomic swap, very brief lock)
BEGIN
    DBMS_REDEFINITION.FINISH_REDEF_TABLE(
        uname      => USER,
        orig_table => 'ORDERS',
        int_table  => 'ORDERS_INTERIM'
    );
END;
/

-- Step 7: Clean up the interim table (now contains the old structure)
DROP TABLE orders_interim PURGE;

-- Step 8: Gather fresh statistics
BEGIN
    DBMS_STATS.GATHER_TABLE_STATS(
        ownname => USER,
        tabname => 'ORDERS',
        cascade => TRUE,
        degree  => 4
    );
END;
/

-- ROLLBACK: If something goes wrong during redefinition
-- BEGIN
--     DBMS_REDEFINITION.ABORT_REDEF_TABLE(
--         uname      => USER,
--         orig_table => 'ORDERS',
--         int_table  => 'ORDERS_INTERIM'
--     );
-- END;
-- /
-- DROP TABLE orders_interim PURGE;


-- ============================================================================
-- SECTION 3: INVISIBLE COLUMNS FOR BACKWARD COMPATIBILITY
-- ============================================================================

-- Migration 3.1: Add an invisible column
-- ============================================================================
-- Invisible columns exist in the table but are not returned by SELECT *
-- and are not included in INSERT without an explicit column list.
-- This allows adding columns without breaking existing application code.

-- UP
ALTER TABLE customers
ADD (internal_score NUMBER(10, 4) INVISIBLE);

-- Invisible columns can still be queried explicitly
-- SELECT customer_id, internal_score FROM customers WHERE customer_id = 1;

-- Backfill the invisible column
UPDATE customers c
SET internal_score = (
    SELECT NVL(SUM(o.total_amount) * 0.01 + COUNT(o.order_id) * 2, 0)
    FROM orders o
    WHERE o.customer_id = c.customer_id
);

-- Once the application is updated to use the column, make it visible
-- ALTER TABLE customers MODIFY (internal_score VISIBLE);

-- DOWN
ALTER TABLE customers DROP (internal_score);


-- Migration 3.2: Make an existing column invisible during deprecation
-- ============================================================================
-- Use this to "hide" a column from SELECT * while keeping the data intact
-- Useful when decommissioning a column over multiple releases

-- UP: Hide the column (apps using SELECT * stop seeing it)
ALTER TABLE products MODIFY (legacy_category_code INVISIBLE);

-- Verify: SELECT * no longer returns the column
-- But explicit references still work:
-- SELECT product_id, legacy_category_code FROM products;

-- DOWN: Make visible again
-- ALTER TABLE products MODIFY (legacy_category_code VISIBLE);

-- Final cleanup (later release): drop the column
-- ALTER TABLE products DROP (legacy_category_code);
-- Or set unused to avoid DDL lock on very large tables:
-- ALTER TABLE products SET UNUSED (legacy_category_code);
-- ALTER TABLE products DROP UNUSED COLUMNS;


-- ============================================================================
-- SECTION 4: PARTITION MANAGEMENT
-- ============================================================================

-- Migration 4.1: Add a new partition for the upcoming year
-- ============================================================================
-- UP
ALTER TABLE orders_partitioned
ADD PARTITION p_2026 VALUES LESS THAN (TIMESTAMP '2027-01-01 00:00:00')
    TABLESPACE data_ts;

-- DOWN
ALTER TABLE orders_partitioned DROP PARTITION p_2026;


-- Migration 4.2: Split a partition (e.g., split annual into quarterly)
-- ============================================================================
-- UP: Split the 2025 partition into quarterly partitions
ALTER TABLE orders_partitioned SPLIT PARTITION p_2025 INTO (
    PARTITION p_2025_q1 VALUES LESS THAN (TIMESTAMP '2025-04-01 00:00:00'),
    PARTITION p_2025_q2 VALUES LESS THAN (TIMESTAMP '2025-07-01 00:00:00'),
    PARTITION p_2025_q3 VALUES LESS THAN (TIMESTAMP '2025-10-01 00:00:00'),
    PARTITION p_2025_q4  -- Inherits the upper bound of the original partition
) ONLINE                  -- 12c+ allows online split
UPDATE INDEXES;           -- Maintain local indexes during split

-- DOWN: Merge quarterly partitions back into annual
ALTER TABLE orders_partitioned
MERGE PARTITIONS p_2025_q1, p_2025_q2, p_2025_q3, p_2025_q4
INTO PARTITION p_2025
UPDATE INDEXES;


-- Migration 4.3: Exchange partition for instant data loading
-- ============================================================================
-- EXCHANGE PARTITION swaps a non-partitioned table's data segment with a
-- partition's data segment. The operation is metadata-only (instant),
-- making it ideal for bulk loading into partitioned tables.

-- Step 1: Create a staging table with identical structure to the partition
CREATE TABLE orders_staging (
    order_id      NUMBER NOT NULL,
    customer_id   NUMBER NOT NULL,
    order_date    TIMESTAMP,
    status        VARCHAR2(20),
    total_amount  NUMBER(12, 2)
);

-- Step 2: Load data into the staging table (fast path: SQL*Loader, external table, etc.)
INSERT /*+ APPEND */ INTO orders_staging
SELECT order_id, customer_id, order_date, status, total_amount
FROM external_order_import
WHERE order_date >= TIMESTAMP '2025-01-01 00:00:00'
  AND order_date <  TIMESTAMP '2026-01-01 00:00:00';
COMMIT;

-- Step 3: Validate and create matching indexes/constraints on staging table
ALTER TABLE orders_staging ADD CONSTRAINT pk_orders_staging PRIMARY KEY (order_id);

-- Step 4: Exchange the partition (instant, metadata-only swap)
ALTER TABLE orders_partitioned
EXCHANGE PARTITION p_2025 WITH TABLE orders_staging
INCLUDING INDEXES
WITHOUT VALIDATION;  -- Skip validation if you trust the data

-- Step 5: Validate after exchange (optional but recommended)
-- ALTER TABLE orders_partitioned VALIDATE PARTITION p_2025;

-- Step 6: Drop staging table (now contains the old partition data, if any)
DROP TABLE orders_staging PURGE;


-- Migration 4.4: Convert interval partitioning to explicit partitions
-- ============================================================================
-- Interval partitioning auto-creates partitions, but you may want to
-- pre-create them with specific names and tablespaces

-- Create an interval-partitioned table
CREATE TABLE sensor_data (
    reading_id    NUMBER GENERATED ALWAYS AS IDENTITY,
    sensor_id     NUMBER NOT NULL,
    reading_value NUMBER(15, 6),
    reading_time  TIMESTAMP NOT NULL,
    CONSTRAINT pk_sensor_data PRIMARY KEY (reading_id, reading_time)
)
PARTITION BY RANGE (reading_time)
INTERVAL (NUMTODSINTERVAL(1, 'DAY'))  -- Auto-create daily partitions
(
    PARTITION p_initial VALUES LESS THAN (TIMESTAMP '2025-01-01 00:00:00')
);

-- Oracle automatically creates partitions like SYS_P12345 when data arrives
-- To rename auto-created partitions for clarity:
-- ALTER TABLE sensor_data RENAME PARTITION SYS_P12345 TO p_20250101;


-- ============================================================================
-- SECTION 5: EDITION-BASED REDEFINITION FOR ROLLING UPGRADES
-- ============================================================================

-- Migration 5.1: Complete EBR workflow for a column rename
-- ============================================================================
-- Scenario: Rename customers.name to customers.full_name with zero downtime

-- Step 1: Add the new column
ALTER TABLE customers ADD (full_name VARCHAR2(200));

-- Step 2: Create a FORWARD crossedition trigger
-- This trigger keeps the new column in sync when old-edition apps write to old column
CREATE OR REPLACE TRIGGER customers_fwd_xed
    BEFORE INSERT OR UPDATE ON customers
    FOR EACH ROW
    FORWARD CROSSEDITION
    DISABLE  -- Enable after testing
BEGIN
    IF :NEW.full_name IS NULL OR :OLD.name != :NEW.name THEN
        :NEW.full_name := :NEW.first_name || ' ' || :NEW.last_name;
    END IF;
END customers_fwd_xed;
/

ALTER TRIGGER customers_fwd_xed ENABLE;

-- Step 3: Backfill existing rows using the crossedition trigger
-- DBMS_SQL.PARSE with APPLY_CROSSEDITION_TRIGGER fires the trigger on existing rows
DECLARE
    v_cursor  INTEGER;
    v_rows    INTEGER;
BEGIN
    v_cursor := DBMS_SQL.OPEN_CURSOR;
    DBMS_SQL.PARSE(
        v_cursor,
        'UPDATE customers SET full_name = first_name || '' '' || last_name WHERE full_name IS NULL',
        DBMS_SQL.NATIVE
    );
    v_rows := DBMS_SQL.EXECUTE(v_cursor);
    DBMS_SQL.CLOSE_CURSOR(v_cursor);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Backfilled ' || v_rows || ' rows.');
END;
/

-- Step 4: Create a REVERSE crossedition trigger (optional)
-- Keeps old column in sync when new-edition apps write to new column
CREATE OR REPLACE TRIGGER customers_rev_xed
    BEFORE INSERT OR UPDATE ON customers
    FOR EACH ROW
    REVERSE CROSSEDITION
    DISABLE
BEGIN
    -- If new-edition app sets full_name, parse back into first/last
    IF :NEW.full_name IS NOT NULL THEN
        :NEW.first_name := REGEXP_SUBSTR(:NEW.full_name, '^\S+');
        :NEW.last_name  := REGEXP_SUBSTR(:NEW.full_name, '\S+$');
    END IF;
END customers_rev_xed;
/

-- Step 5: In the new edition, update editioning views and PL/SQL code
-- Step 6: After all sessions have migrated, drop the triggers and old column


-- ============================================================================
-- SECTION 6: MATERIALIZED VIEW LOG MANAGEMENT
-- ============================================================================

-- Migration 6.1: Create materialized view with fast refresh
-- ============================================================================

-- UP: Create the materialized view log on the base table
-- The log tracks changes for fast (incremental) refresh
CREATE MATERIALIZED VIEW LOG ON orders
WITH ROWID, PRIMARY KEY (customer_id, order_date, total_amount, status)
INCLUDING NEW VALUES;

CREATE MATERIALIZED VIEW LOG ON order_items
WITH ROWID, PRIMARY KEY (order_id, product_id, quantity, unit_price)
INCLUDING NEW VALUES;

-- Create the materialized view
CREATE MATERIALIZED VIEW mv_daily_sales
    BUILD IMMEDIATE           -- Populate now
    REFRESH FAST              -- Incremental refresh using MV logs
    ON DEMAND                 -- Refresh manually or via scheduler
    ENABLE QUERY REWRITE      -- CBO can transparently rewrite queries to use this MV
AS
SELECT
    TRUNC(o.order_date) AS sale_date,
    o.customer_id,
    COUNT(*)            AS order_count,
    SUM(oi.quantity)    AS total_items,
    SUM(oi.quantity * oi.unit_price) AS total_revenue
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id
WHERE o.status != 'cancelled'
GROUP BY TRUNC(o.order_date), o.customer_id;

-- Schedule automatic refresh
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'REFRESH_MV_DAILY_SALES',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN DBMS_MVIEW.REFRESH(''MV_DAILY_SALES'', ''F''); END;',
        start_date      => TRUNC(SYSDATE + 1) + 1/24,  -- Tomorrow at 1 AM
        repeat_interval => 'FREQ=DAILY; BYHOUR=1; BYMINUTE=0; BYSECOND=0',
        enabled         => TRUE,
        comments        => 'Daily fast refresh of sales summary MV'
    );
END;
/

-- DOWN
DROP MATERIALIZED VIEW mv_daily_sales;
DROP MATERIALIZED VIEW LOG ON order_items;
DROP MATERIALIZED VIEW LOG ON orders;

BEGIN
    DBMS_SCHEDULER.DROP_JOB('REFRESH_MV_DAILY_SALES', force => TRUE);
END;
/


-- ============================================================================
-- SECTION 7: TABLESPACE MANAGEMENT AND DATA FILE OPERATIONS
-- ============================================================================

-- Migration 7.1: Create and manage tablespaces for a new application schema
-- ============================================================================

-- Create tablespace for table data
CREATE TABLESPACE app_data
    DATAFILE '/u01/oradata/mydb/app_data01.dbf' SIZE 10G
    AUTOEXTEND ON NEXT 1G MAXSIZE 50G
    EXTENT MANAGEMENT LOCAL AUTOALLOCATE
    SEGMENT SPACE MANAGEMENT AUTO;

-- Create tablespace for indexes (separate I/O path)
CREATE TABLESPACE app_idx
    DATAFILE '/u01/oradata/mydb/app_idx01.dbf' SIZE 5G
    AUTOEXTEND ON NEXT 512M MAXSIZE 20G
    EXTENT MANAGEMENT LOCAL AUTOALLOCATE
    SEGMENT SPACE MANAGEMENT AUTO;

-- Create tablespace for LOBs (separate I/O path)
CREATE TABLESPACE app_lob
    DATAFILE '/u01/oradata/mydb/app_lob01.dbf' SIZE 5G
    AUTOEXTEND ON NEXT 1G MAXSIZE 100G
    EXTENT MANAGEMENT LOCAL AUTOALLOCATE
    SEGMENT SPACE MANAGEMENT AUTO;


-- Migration 7.2: Add data file to an existing tablespace (space expansion)
-- ============================================================================
-- UP
ALTER TABLESPACE app_data
ADD DATAFILE '/u01/oradata/mydb/app_data02.dbf' SIZE 10G
AUTOEXTEND ON NEXT 1G MAXSIZE 50G;

-- Monitor space usage
-- SELECT tablespace_name, file_name, bytes/1024/1024 AS size_mb,
--        autoextensible, maxbytes/1024/1024 AS max_size_mb
-- FROM dba_data_files
-- WHERE tablespace_name = 'APP_DATA';

-- DOWN (cannot remove a data file; must move data off it first)
-- ALTER TABLE ... MOVE TABLESPACE other_ts;
-- ALTER TABLESPACE app_data DROP DATAFILE '/u01/oradata/mydb/app_data02.dbf';
-- Only works if data file is empty (Oracle 11g R2+)


-- Migration 7.3: Resize a data file
-- ============================================================================
ALTER DATABASE DATAFILE '/u01/oradata/mydb/app_data01.dbf' RESIZE 20G;

-- To shrink a data file (only if free space exists at the end):
-- ALTER DATABASE DATAFILE '/u01/oradata/mydb/app_data01.dbf' RESIZE 5G;


-- ============================================================================
-- SECTION 8: CONVERTING TO PARTITIONED TABLES (12.2+ ONLINE)
-- ============================================================================

-- Migration 8.1: Online conversion of a non-partitioned table to partitioned
-- ============================================================================
-- Oracle 12.2+ allows converting a heap table to a partitioned table ONLINE.
-- This is a single DDL command that works while the table is in use.

-- UP: Convert orders to range-partitioned by order_date
ALTER TABLE orders MODIFY
    PARTITION BY RANGE (order_date) (
        PARTITION p_2023 VALUES LESS THAN (TIMESTAMP '2024-01-01 00:00:00'),
        PARTITION p_2024 VALUES LESS THAN (TIMESTAMP '2025-01-01 00:00:00'),
        PARTITION p_2025 VALUES LESS THAN (TIMESTAMP '2026-01-01 00:00:00'),
        PARTITION p_max  VALUES LESS THAN (MAXVALUE)
    )
    ONLINE
    UPDATE INDEXES;

-- Note: DOWN (converting back to non-partitioned) requires DBMS_REDEFINITION
-- or CREATE TABLE AS SELECT + rename


-- Migration 8.2: Add sub-partitioning to an existing partitioned table
-- ============================================================================
-- Convert range partitioning to composite range-hash partitioning
-- This requires DBMS_REDEFINITION (cannot alter subpartitioning template in-place)

-- Create interim with composite partitioning
CREATE TABLE orders_interim_subpart (
    order_id      NUMBER NOT NULL,
    customer_id   NUMBER NOT NULL,
    order_date    TIMESTAMP,
    status        VARCHAR2(20),
    total_amount  NUMBER(12, 2),
    CONSTRAINT pk_orders_interim_subpart PRIMARY KEY (order_id)
)
PARTITION BY RANGE (order_date)
SUBPARTITION BY HASH (customer_id) SUBPARTITIONS 8
(
    PARTITION p_2024 VALUES LESS THAN (TIMESTAMP '2025-01-01 00:00:00'),
    PARTITION p_2025 VALUES LESS THAN (TIMESTAMP '2026-01-01 00:00:00'),
    PARTITION p_max  VALUES LESS THAN (MAXVALUE)
);

-- Then use DBMS_REDEFINITION as shown in Section 2


-- ============================================================================
-- SECTION 9: INDEX MAINTENANCE
-- ============================================================================

-- Migration 9.1: Rebuild index ONLINE to reduce fragmentation
-- ============================================================================
-- Indexes degrade over time due to DML; rebuilding reclaims space and
-- restores a balanced B-tree structure

-- UP: Rebuild online (no lock on the table)
ALTER INDEX idx_orders_customer_id REBUILD ONLINE
    TABLESPACE app_idx
    PARALLEL 4;

-- Remove parallel after rebuild (don't want queries using parallel by default)
ALTER INDEX idx_orders_customer_id NOPARALLEL;

-- Check index fragmentation before rebuild:
-- ANALYZE INDEX idx_orders_customer_id VALIDATE STRUCTURE;
-- SELECT name, btree_space, used_space, pct_used
-- FROM index_stats
-- WHERE name = 'IDX_ORDERS_CUSTOMER_ID';


-- Migration 9.2: INVISIBLE indexes for safe testing
-- ============================================================================
-- Invisible indexes are maintained by DML but ignored by the optimizer.
-- This lets you build a new index without affecting query plans until you verify it.

-- UP: Create as invisible (optimizer won't use it yet)
CREATE INDEX idx_orders_status_date ON orders (status, order_date DESC)
    TABLESPACE app_idx
    INVISIBLE
    ONLINE;

-- Test: force the optimizer to see the invisible index in this session only
ALTER SESSION SET OPTIMIZER_USE_INVISIBLE_INDEXES = TRUE;

-- Run explain plans, verify the index improves performance
-- EXPLAIN PLAN FOR SELECT * FROM orders WHERE status = 'pending' ORDER BY order_date DESC;
-- SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- Once verified, make visible to all sessions
ALTER INDEX idx_orders_status_date VISIBLE;

-- DOWN
DROP INDEX idx_orders_status_date;


-- Migration 9.3: Coalesce index instead of full rebuild
-- ============================================================================
-- COALESCE is lighter than REBUILD: it merges adjacent leaf blocks
-- without rebuilding the entire B-tree structure
ALTER INDEX idx_orders_customer_id COALESCE;

-- For partitioned indexes: rebuild a specific partition
ALTER INDEX idx_orders_part_local REBUILD PARTITION p_2024 ONLINE;


-- Migration 9.4: Convert between index types
-- ============================================================================
-- Convert a regular B-tree index to a compressed index (reduces space)
ALTER INDEX idx_orders_cust_status REBUILD
    COMPRESS 1     -- Compress the first column (customer_id has many duplicates)
    ONLINE;

-- Convert a non-unique index to a bitmap index (for low-cardinality columns)
-- Note: bitmap indexes are only suitable for OLAP/DW workloads, NOT OLTP
DROP INDEX idx_products_category;
CREATE BITMAP INDEX idx_products_category ON products (category)
    TABLESPACE app_idx;


-- ============================================================================
-- SECTION 10: RENAMING COLUMNS AND TABLES WITH DEPENDENCY TRACKING
-- ============================================================================

-- Migration 10.1: Rename a column safely
-- ============================================================================
-- Oracle's RENAME COLUMN is a metadata-only operation (instant)
-- but breaks any objects that reference the old column name

-- Step 1: Find all dependencies on the column
-- This query identifies views, PL/SQL, triggers, etc. that reference the column
/*
SELECT
    d.owner,
    d.name,
    d.type,
    d.referenced_owner,
    d.referenced_name
FROM dba_dependencies d
WHERE d.referenced_name = 'CUSTOMERS'
  AND d.referenced_owner = USER
  AND d.type IN ('VIEW', 'PROCEDURE', 'FUNCTION', 'PACKAGE', 'PACKAGE BODY', 'TRIGGER');
*/

-- Step 2: Rename the column
-- UP
ALTER TABLE customers RENAME COLUMN name TO full_name;

-- Step 3: Recompile invalidated objects
BEGIN
    FOR rec IN (
        SELECT owner, object_name, object_type
        FROM all_objects
        WHERE status = 'INVALID'
          AND owner = USER
        ORDER BY
            CASE object_type
                WHEN 'PACKAGE' THEN 1
                WHEN 'PACKAGE BODY' THEN 2
                WHEN 'FUNCTION' THEN 3
                WHEN 'PROCEDURE' THEN 4
                WHEN 'VIEW' THEN 5
                WHEN 'TRIGGER' THEN 6
                ELSE 7
            END
    ) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'ALTER ' || rec.object_type || ' ' ||
                              rec.owner || '.' || rec.object_name || ' COMPILE';
            DBMS_OUTPUT.PUT_LINE('Recompiled: ' || rec.object_type || ' ' || rec.object_name);
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('FAILED: ' || rec.object_type || ' ' || rec.object_name ||
                                     ' - ' || SQLERRM);
        END;
    END LOOP;
END;
/

-- DOWN
ALTER TABLE customers RENAME COLUMN full_name TO name;
-- Then recompile invalidated objects again


-- Migration 10.2: Rename a table with synonym for backward compatibility
-- ============================================================================
-- UP
ALTER TABLE user_sessions RENAME TO sessions;

-- Create a synonym so old code still works during migration period
CREATE OR REPLACE SYNONYM user_sessions FOR sessions;

-- Rename associated sequences
RENAME user_sessions_seq TO sessions_seq;

-- Rename indexes
ALTER INDEX idx_user_sessions_user_id RENAME TO idx_sessions_user_id;
ALTER INDEX idx_user_sessions_created RENAME TO idx_sessions_created;

-- DOWN
ALTER TABLE sessions RENAME TO user_sessions;
DROP SYNONYM user_sessions;
RENAME sessions_seq TO user_sessions_seq;
ALTER INDEX idx_sessions_user_id RENAME TO idx_user_sessions_user_id;
ALTER INDEX idx_sessions_created RENAME TO idx_user_sessions_created;


-- ============================================================================
-- SECTION 11: SET UNUSED FOR DEFERRED COLUMN DROPS
-- ============================================================================

-- Migration 11.1: SET UNUSED instead of DROP COLUMN on large tables
-- ============================================================================
-- DROP COLUMN on a very large table requires a table rewrite which can take
-- hours and hold locks. SET UNUSED marks the column as invisible and inaccessible
-- instantly, with actual physical removal deferred to a maintenance window.

-- UP: Instantly hide the column (metadata-only operation)
ALTER TABLE orders SET UNUSED (legacy_tracking_code);

-- The column is now invisible. Oracle has renamed it internally.
-- No application can reference it. No new data goes to it.

-- Later, during a maintenance window, physically remove unused columns:
-- ALTER TABLE orders DROP UNUSED COLUMNS CHECKPOINT 1000;
-- The CHECKPOINT clause commits every N rows to avoid exhausting UNDO space

-- DOWN: Cannot reverse SET UNUSED - the column metadata is gone.
-- Must recreate the column:
-- ALTER TABLE orders ADD (legacy_tracking_code VARCHAR2(100));


-- ============================================================================
-- SECTION 12: DATA PUMP PATTERNS FOR LARGE DATA MIGRATIONS
-- ============================================================================

-- Migration 12.1: Export a table subset using Data Pump
-- ============================================================================
-- Data Pump is Oracle's high-performance data movement tool
-- It runs server-side (not client-side like the old exp/imp)

-- Create a directory object pointing to the OS directory
CREATE OR REPLACE DIRECTORY dp_export_dir AS '/u01/exports';
GRANT READ, WRITE ON DIRECTORY dp_export_dir TO migration_user;

-- Export via PL/SQL (alternative to command-line expdp)
DECLARE
    v_handle NUMBER;
BEGIN
    v_handle := DBMS_DATAPUMP.OPEN(
        operation => 'EXPORT',
        job_mode  => 'TABLE',
        job_name  => 'EXPORT_ORDERS_2024'
    );

    DBMS_DATAPUMP.ADD_FILE(
        handle    => v_handle,
        filename  => 'orders_2024.dmp',
        directory => 'DP_EXPORT_DIR',
        filetype  => DBMS_DATAPUMP.KU$_FILE_TYPE_DUMP_FILE
    );

    DBMS_DATAPUMP.ADD_FILE(
        handle    => v_handle,
        filename  => 'orders_2024.log',
        directory => 'DP_EXPORT_DIR',
        filetype  => DBMS_DATAPUMP.KU$_FILE_TYPE_LOG_FILE
    );

    -- Filter: only export orders from 2024
    DBMS_DATAPUMP.DATA_FILTER(
        handle    => v_handle,
        name      => 'SUBQUERY',
        value     => 'WHERE order_date >= TIMESTAMP ''2024-01-01 00:00:00'' AND order_date < TIMESTAMP ''2025-01-01 00:00:00'''
    );

    -- Parallelize for performance
    DBMS_DATAPUMP.SET_PARALLEL(
        handle         => v_handle,
        degree         => 4
    );

    -- Enable compression
    DBMS_DATAPUMP.SET_PARAMETER(
        handle => v_handle,
        name   => 'COMPRESSION',
        value  => 'ALL'
    );

    DBMS_DATAPUMP.START_JOB(v_handle);
    DBMS_DATAPUMP.DETACH(v_handle);
END;
/


-- Migration 12.2: Import data with remapping
-- ============================================================================
-- Import the exported data into a different schema or table
DECLARE
    v_handle NUMBER;
BEGIN
    v_handle := DBMS_DATAPUMP.OPEN(
        operation => 'IMPORT',
        job_mode  => 'TABLE',
        job_name  => 'IMPORT_ORDERS_ARCHIVE'
    );

    DBMS_DATAPUMP.ADD_FILE(
        handle    => v_handle,
        filename  => 'orders_2024.dmp',
        directory => 'DP_EXPORT_DIR',
        filetype  => DBMS_DATAPUMP.KU$_FILE_TYPE_DUMP_FILE
    );

    DBMS_DATAPUMP.ADD_FILE(
        handle    => v_handle,
        filename  => 'import_orders_2024.log',
        directory => 'DP_EXPORT_DIR',
        filetype  => DBMS_DATAPUMP.KU$_FILE_TYPE_LOG_FILE
    );

    -- Remap to a different schema
    DBMS_DATAPUMP.METADATA_REMAP(
        handle    => v_handle,
        name      => 'REMAP_SCHEMA',
        old_value => 'APP_SCHEMA',
        value     => 'ARCHIVE_SCHEMA'
    );

    -- Remap to a different tablespace
    DBMS_DATAPUMP.METADATA_REMAP(
        handle    => v_handle,
        name      => 'REMAP_TABLESPACE',
        old_value => 'APP_DATA',
        value     => 'ARCHIVE_DATA'
    );

    -- Remap table name
    DBMS_DATAPUMP.METADATA_REMAP(
        handle    => v_handle,
        name      => 'REMAP_TABLE',
        old_value => 'ORDERS',
        value     => 'ORDERS_2024_ARCHIVE'
    );

    -- Truncate target table before import (if it exists)
    DBMS_DATAPUMP.SET_PARAMETER(
        handle => v_handle,
        name   => 'TABLE_EXISTS_ACTION',
        value  => 'TRUNCATE'
    );

    DBMS_DATAPUMP.SET_PARALLEL(
        handle => v_handle,
        degree => 4
    );

    DBMS_DATAPUMP.START_JOB(v_handle);
    DBMS_DATAPUMP.DETACH(v_handle);
END;
/


-- Migration 12.3: Monitor Data Pump jobs
-- ============================================================================
-- Check status of running Data Pump jobs
/*
SELECT
    owner_name,
    job_name,
    operation,
    job_mode,
    state,
    degree,
    attached_sessions
FROM dba_datapump_jobs
WHERE state = 'EXECUTING';

-- Detailed progress
SELECT
    opname,
    target_desc,
    sofar,
    totalwork,
    ROUND(sofar / NULLIF(totalwork, 0) * 100, 2) AS pct_complete,
    time_remaining AS est_seconds_remaining
FROM v$session_longops
WHERE opname LIKE 'EXPORT%' OR opname LIKE 'IMPORT%'
ORDER BY start_time DESC;
*/


-- ============================================================================
-- SECTION 13: MIGRATION VALIDATION AND MONITORING
-- ============================================================================

-- Migration 13.1: Validate migration with row counts and checksums
-- ============================================================================
DECLARE
    v_source_count NUMBER;
    v_target_count NUMBER;
    v_source_sum   NUMBER;
    v_target_sum   NUMBER;
BEGIN
    SELECT COUNT(*), NVL(SUM(total_amount), 0)
    INTO v_source_count, v_source_sum
    FROM orders
    WHERE order_date >= TIMESTAMP '2024-01-01 00:00:00'
      AND order_date <  TIMESTAMP '2025-01-01 00:00:00';

    SELECT COUNT(*), NVL(SUM(total_amount), 0)
    INTO v_target_count, v_target_sum
    FROM orders_2024_archive;

    IF v_source_count != v_target_count THEN
        RAISE_APPLICATION_ERROR(-20500,
            'Row count mismatch: source=' || v_source_count ||
            ' target=' || v_target_count);
    END IF;

    IF v_source_sum != v_target_sum THEN
        RAISE_APPLICATION_ERROR(-20501,
            'Amount mismatch: source=' || v_source_sum ||
            ' target=' || v_target_sum);
    END IF;

    DBMS_OUTPUT.PUT_LINE('Validation passed: ' || v_source_count || ' rows, total=' || v_source_sum);
END;
/


-- Migration 13.2: Create a migration audit table for Oracle
-- ============================================================================
CREATE TABLE schema_migrations (
    migration_id     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    version          VARCHAR2(50)   NOT NULL UNIQUE,
    description      VARCHAR2(500),
    applied_at       TIMESTAMP      DEFAULT SYSTIMESTAMP,
    applied_by       VARCHAR2(128)  DEFAULT SYS_CONTEXT('USERENV', 'SESSION_USER'),
    execution_secs   NUMBER(10, 2),
    success          NUMBER(1)      DEFAULT 1 CHECK (success IN (0, 1)),
    error_message    VARCHAR2(4000),
    rollback_sql     CLOB
);

-- Record a migration
INSERT INTO schema_migrations (version, description, execution_secs)
VALUES ('2025_04_06_001', 'Add priority column to orders, partition by date', 12.5);
COMMIT;

-- Check migration history
-- SELECT version, description, applied_at, applied_by, execution_secs
-- FROM schema_migrations
-- ORDER BY applied_at DESC;
