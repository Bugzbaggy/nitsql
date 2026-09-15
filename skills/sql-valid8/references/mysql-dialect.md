# MySQL / MariaDB — Dialect Reference

## Version Features

### MySQL 8.0 (General Availability)
- **Window functions**: `ROW_NUMBER()`, `RANK()`, `DENSE_RANK()`, `LEAD()`, `LAG()`, `NTILE()`
- **Common Table Expressions (CTEs)**: `WITH cte AS (...)` including recursive CTEs
- **JSON_TABLE**: Convert JSON arrays into relational rows
- **Roles**: `CREATE ROLE`, `GRANT role TO user`
- **Invisible indexes**: Test without dropping via `ALTER TABLE ... ALTER INDEX idx INVISIBLE`
- **Descending indexes**: `CREATE INDEX idx ON t(col DESC)`
- **Functional indexes**: `CREATE INDEX idx ON t((LOWER(email)))`
- **Instant ADD COLUMN**: `ALTER TABLE ... ADD COLUMN ... , ALGORITHM=INSTANT` (no table rebuild)

### MySQL 8.0.13+
- **DEFAULT expressions**: `CREATE TABLE t (created_at DATETIME DEFAULT (NOW()))`

### MySQL 8.0.17+
- **Multi-valued indexes for JSON arrays**: Index individual elements in JSON arrays
```sql
CREATE TABLE products (
    id INT PRIMARY KEY,
    tags JSON,
    INDEX idx_tags ((CAST(tags->'$[*]' AS CHAR(50) ARRAY)))
);
-- Query: SELECT * FROM products WHERE 'electronics' MEMBER OF (tags->'$[*]');
```

### MySQL 8.4 (LTS)
- Long-term support release with stability focus
- Deprecation of mysql_native_password authentication plugin
- Group Replication improvements

### MariaDB 10.5+ Divergence
- Sequences: `CREATE SEQUENCE` (native support unlike MySQL)
- System-versioned tables (temporal tables): `WITH SYSTEM VERSIONING`
- Oracle compatibility mode: `SET sql_mode='ORACLE'`
- `RETURNING` clause on INSERT/DELETE (MySQL does not have this)

## Stored Procedure Template

### Standard Procedure
```sql
DELIMITER //

CREATE PROCEDURE app_db.upsert_customer_order(
    IN p_customer_id INT,
    IN p_product_id INT,
    IN p_quantity INT,
    OUT p_order_id INT,
    OUT p_status VARCHAR(20)
)
BEGIN
    DECLARE v_existing_id INT DEFAULT NULL;
    DECLARE v_error_occurred BOOLEAN DEFAULT FALSE;
    DECLARE v_error_message VARCHAR(500);

    -- Error handler: catch all SQL exceptions
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1
            v_error_message = MESSAGE_TEXT;
        SET v_error_occurred = TRUE;
    END;

    -- Validate input
    IF p_quantity <= 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Quantity must be positive';
    END IF;

    START TRANSACTION;

    -- Check for existing pending order
    SELECT order_id INTO v_existing_id
    FROM app_db.orders
    WHERE customer_id = p_customer_id
      AND product_id = p_product_id
      AND status = 'PENDING'
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
        UPDATE app_db.orders
        SET quantity = p_quantity, modified_date = NOW()
        WHERE order_id = v_existing_id;
        SET p_order_id = v_existing_id;
        SET p_status = 'UPDATED';
    ELSE
        INSERT INTO app_db.orders (customer_id, product_id, quantity, order_date)
        VALUES (p_customer_id, p_product_id, p_quantity, NOW());
        SET p_order_id = LAST_INSERT_ID();
        SET p_status = 'CREATED';
    END IF;

    IF v_error_occurred THEN
        ROLLBACK;
        SET p_order_id = -1;
        SET p_status = CONCAT('ERROR: ', v_error_message);
    ELSE
        COMMIT;
    END IF;
END //

DELIMITER ;
```

### Function
```sql
DELIMITER //

CREATE FUNCTION app_db.calculate_order_total(
    p_order_id INT
) RETURNS DECIMAL(12,2)
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_total DECIMAL(12,2);

    SELECT SUM(quantity * unit_price)
    INTO v_total
    FROM app_db.order_items
    WHERE order_id = p_order_id;

    RETURN IFNULL(v_total, 0.00);
END //

DELIMITER ;
```

## Parameter Syntax

### Native MySQL (Prepared Statements)
```sql
-- Server-side prepared statements
PREPARE stmt FROM 'SELECT user_id, name FROM users WHERE user_id = ? AND status = ?';
SET @uid = 42;
SET @stat = 'active';
EXECUTE stmt USING @uid, @stat;
DEALLOCATE PREPARE stmt;
```

### mysql-connector-python
```python
import mysql.connector

# Positional with %s (NEVER use f-strings or format)
cursor.execute(
    "SELECT user_id, name FROM users WHERE user_id = %s AND status = %s",
    (user_id, 'active')
)

# Named with %(name)s
cursor.execute(
    "SELECT * FROM users WHERE user_id = %(id)s AND status = %(status)s",
    {'id': user_id, 'status': 'active'}
)
```

### pymysql (Python)
```python
import pymysql

# Positional with %s only
cursor.execute(
    "SELECT user_id, name FROM users WHERE user_id = %s AND status = %s",
    (user_id, 'active')
)
```

### mysql2 (Node.js)
```javascript
// Positional with ?
const [rows] = await pool.execute(
    'SELECT user_id, name FROM users WHERE user_id = ? AND status = ?',
    [userId, 'active']
);

// Named placeholders (mysql2 supports this)
const [rows] = await pool.execute(
    'SELECT user_id, name FROM users WHERE user_id = :id AND status = :status',
    { id: userId, status: 'active' }
);
```

### MySqlConnector (.NET)
```csharp
using var cmd = new MySqlCommand(
    "SELECT * FROM users WHERE user_id = @id AND status = @status", conn);
cmd.Parameters.AddWithValue("@id", userId);
cmd.Parameters.AddWithValue("@status", "active");
```

## Identity and Sequences

### AUTO_INCREMENT
```sql
CREATE TABLE app_db.orders (
    order_id INT NOT NULL AUTO_INCREMENT,
    customer_id INT NOT NULL,
    order_date DATETIME NOT NULL DEFAULT NOW(),
    PRIMARY KEY (order_id)
) ENGINE=InnoDB;

-- Get last generated ID (session-scoped, safe)
INSERT INTO app_db.orders (customer_id) VALUES (42);
SELECT LAST_INSERT_ID() AS new_order_id;

-- Reset auto-increment
ALTER TABLE app_db.orders AUTO_INCREMENT = 1000;
```

### No RETURNING Clause (MySQL Limitation)
```sql
-- MySQL does not support RETURNING
-- You must use LAST_INSERT_ID() after INSERT:
INSERT INTO app_db.orders (customer_id) VALUES (42);
SET @new_id = LAST_INSERT_ID();
SELECT * FROM app_db.orders WHERE order_id = @new_id;
```

### Table-Based Sequence (Workaround)
```sql
-- For custom sequences not tied to a single table
CREATE TABLE app_db.sequences (
    seq_name VARCHAR(50) PRIMARY KEY,
    current_val BIGINT NOT NULL DEFAULT 0
) ENGINE=InnoDB;

-- Get next value (atomic)
UPDATE app_db.sequences SET current_val = LAST_INSERT_ID(current_val + 1) WHERE seq_name = 'invoice_number';
SELECT LAST_INSERT_ID() AS next_val;
```

## Error Handling

### DECLARE HANDLER
```sql
DELIMITER //
CREATE PROCEDURE app_db.safe_operation()
BEGIN
    -- Specific handler for duplicate key
    DECLARE EXIT HANDLER FOR 1062
    BEGIN
        -- 1062 = Duplicate entry
        SELECT 'Duplicate key error' AS error_msg;
    END;

    -- General handler for any SQL exception
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1
            @sqlstate = RETURNED_SQLSTATE,
            @errno = MYSQL_ERRNO,
            @msg = MESSAGE_TEXT;
        SELECT @sqlstate AS sql_state, @errno AS error_no, @msg AS error_message;
        ROLLBACK;
    END;

    START TRANSACTION;
    INSERT INTO app_db.users (email, name) VALUES ('user@example.com', 'Test');
    COMMIT;
END //
DELIMITER ;
```

### SIGNAL and RESIGNAL
```sql
-- Raise custom error
SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'Custom error: order quantity exceeds maximum',
        MYSQL_ERRNO = 50001;

-- Re-raise from handler with additional context
DECLARE EXIT HANDLER FOR SQLEXCEPTION
BEGIN
    RESIGNAL SET MESSAGE_TEXT = 'Error in process_order procedure';
END;
```

### Handler Types
```sql
-- CONTINUE: execution continues after handler
DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = TRUE;

-- EXIT: exits the BEGIN...END block
DECLARE EXIT HANDLER FOR SQLEXCEPTION
BEGIN
    ROLLBACK;
END;

-- Named conditions
DECLARE duplicate_entry CONDITION FOR 1062;
DECLARE EXIT HANDLER FOR duplicate_entry
BEGIN
    SELECT 'Duplicate found' AS msg;
END;
```

## Transaction Handling

### Standard Transaction (InnoDB Only)
```sql
-- MyISAM does NOT support transactions — always use InnoDB
START TRANSACTION;

UPDATE app_db.accounts SET balance = balance - 100 WHERE account_id = 1;
UPDATE app_db.accounts SET balance = balance + 100 WHERE account_id = 2;

-- Check for errors before committing
-- (In stored procedures, use handlers)
COMMIT;
```

### Savepoints
```sql
START TRANSACTION;

INSERT INTO app_db.orders (customer_id) VALUES (42);

SAVEPOINT before_items;

INSERT INTO app_db.order_items (order_id, product_id, quantity)
VALUES (LAST_INSERT_ID(), 101, 5);

-- If items fail, rollback only items
ROLLBACK TO SAVEPOINT before_items;
-- Order header survives

COMMIT;
```

### DDL Auto-Commit (Critical Gotcha)
```sql
-- DDL statements cause an implicit COMMIT before and after:
START TRANSACTION;
INSERT INTO app_db.orders (customer_id) VALUES (42);
-- This INSERT is now committed because of:
CREATE TABLE app_db.temp (id INT);
-- Both the INSERT and CREATE TABLE are committed
-- A subsequent ROLLBACK has no effect on the INSERT
```

### Autocommit Control
```sql
-- Disable autocommit for explicit transaction control
SET autocommit = 0;

-- All statements now require explicit COMMIT
UPDATE app_db.orders SET status = 'processing' WHERE order_id = 42;
COMMIT;  -- Must commit explicitly

-- Re-enable
SET autocommit = 1;
```

### Locking Reads
```sql
-- Pessimistic locking (exclusive lock)
START TRANSACTION;
SELECT * FROM app_db.orders WHERE order_id = 42 FOR UPDATE;
-- Row is locked until COMMIT/ROLLBACK

-- Shared lock (allows other reads but not writes)
SELECT * FROM app_db.orders WHERE order_id = 42 FOR SHARE;

-- Skip locked rows (8.0+, useful for queue processing)
SELECT * FROM app_db.orders WHERE status = 'pending'
ORDER BY created_at LIMIT 10 FOR UPDATE SKIP LOCKED;
```

## Indexing

### InnoDB Clustering (Important to Understand)
```sql
-- InnoDB stores data sorted by PRIMARY KEY (clustered index)
-- Choose PK wisely: sequential, narrow, immutable
CREATE TABLE app_db.orders (
    order_id BIGINT NOT NULL AUTO_INCREMENT,
    customer_id INT NOT NULL,
    PRIMARY KEY (order_id)  -- Clustered: data sorted by order_id
) ENGINE=InnoDB;

-- Secondary indexes INCLUDE the primary key columns automatically
-- So a secondary index on (customer_id) is effectively (customer_id, order_id)
CREATE INDEX idx_customer ON app_db.orders (customer_id);
-- No need for INCLUDE — PK columns are always appended
```

### Composite Index (Covering)
```sql
-- Since MySQL has no INCLUDE, create a composite index for covering
CREATE INDEX idx_orders_covering ON app_db.orders (customer_id, order_date, total_amount);
-- Query covered (no table lookup needed):
-- SELECT order_date, total_amount FROM orders WHERE customer_id = 42;
```

### Invisible Index (8.0+)
```sql
-- Hide index from optimizer without dropping it
ALTER TABLE app_db.orders ALTER INDEX idx_customer INVISIBLE;
-- Test performance without the index
-- Then restore:
ALTER TABLE app_db.orders ALTER INDEX idx_customer VISIBLE;
```

### Descending Index (8.0+)
```sql
-- Before 8.0, DESC was accepted but ignored
CREATE INDEX idx_orders_date_desc ON app_db.orders (order_date DESC);
-- Useful for ORDER BY order_date DESC queries
```

### Functional Index (8.0+)
```sql
-- Index on expression
CREATE INDEX idx_users_email_lower ON app_db.users ((LOWER(email)));
-- Query must match: SELECT * FROM users WHERE LOWER(email) = 'user@example.com';

-- Index on JSON extracted value
CREATE INDEX idx_users_city ON app_db.users ((CAST(profile->>'$.city' AS CHAR(100))));
```

### Fulltext Index
```sql
CREATE FULLTEXT INDEX idx_articles_content ON app_db.articles (title, body);

-- Natural language search
SELECT * FROM app_db.articles
WHERE MATCH(title, body) AGAINST('database optimization' IN NATURAL LANGUAGE MODE);

-- Boolean mode search
SELECT * FROM app_db.articles
WHERE MATCH(title, body) AGAINST('+database -nosql' IN BOOLEAN MODE);
```

### Online DDL
```sql
-- Add index without blocking DML
ALTER TABLE app_db.orders ADD INDEX idx_status (status), ALGORITHM=INPLACE, LOCK=NONE;

-- Instant column add (8.0+, only for appending columns)
ALTER TABLE app_db.orders ADD COLUMN notes VARCHAR(500) DEFAULT NULL, ALGORITHM=INSTANT;
```

## Query Optimization

### EXPLAIN and EXPLAIN ANALYZE
```sql
-- Basic EXPLAIN
EXPLAIN SELECT o.order_id, c.name
FROM app_db.orders o
JOIN app_db.customers c ON o.customer_id = c.customer_id
WHERE o.order_date > NOW() - INTERVAL 30 DAY;

-- EXPLAIN ANALYZE (8.0.18+): actually executes the query
EXPLAIN ANALYZE SELECT o.order_id, c.name
FROM app_db.orders o
JOIN app_db.customers c ON o.customer_id = c.customer_id
WHERE o.order_date > NOW() - INTERVAL 30 DAY;

-- JSON format for detailed output
EXPLAIN FORMAT=JSON SELECT ...;

-- Tree format (8.0.16+)
EXPLAIN FORMAT=TREE SELECT ...;
```

### Performance Schema (Top Queries)
```sql
-- Top queries by total execution time
SELECT
    DIGEST_TEXT AS query_pattern,
    COUNT_STAR AS executions,
    ROUND(SUM_TIMER_WAIT / 1000000000000, 3) AS total_time_sec,
    ROUND(AVG_TIMER_WAIT / 1000000000000, 3) AS avg_time_sec,
    SUM_ROWS_EXAMINED,
    SUM_ROWS_SENT,
    FIRST_SEEN, LAST_SEEN
FROM performance_schema.events_statements_summary_by_digest
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 20;
```

### Slow Query Log
```sql
-- Enable slow query log
SET GLOBAL slow_query_log = 1;
SET GLOBAL long_query_time = 1;  -- Log queries > 1 second
SET GLOBAL log_queries_not_using_indexes = 1;  -- Also log unindexed queries
SHOW VARIABLES LIKE 'slow_query_log_file';  -- Find the log file
```

### Optimizer Hints (8.0+)
```sql
-- Force/prevent index usage
SELECT /*+ INDEX(o idx_customer) */ order_id FROM app_db.orders o WHERE customer_id = 42;
SELECT /*+ NO_INDEX(o idx_customer) */ order_id FROM app_db.orders o WHERE customer_id = 42;

-- Join order
SELECT /*+ JOIN_ORDER(c, o) */ o.order_id, c.name
FROM app_db.orders o JOIN app_db.customers c ON o.customer_id = c.customer_id;

-- Parallelism (InnoDB 8.0.14+)
SELECT /*+ SET_VAR(innodb_parallel_read_threads=4) */ COUNT(*) FROM app_db.large_table;
```

### Legacy Index Hints
```sql
-- Force specific index
SELECT * FROM app_db.orders FORCE INDEX (idx_customer) WHERE customer_id = 42;

-- Ignore specific index
SELECT * FROM app_db.orders IGNORE INDEX (idx_status) WHERE status = 'active';

-- Suggest index (optimizer can override)
SELECT * FROM app_db.orders USE INDEX (idx_customer) WHERE customer_id = 42;
```

## Configuration

### InnoDB Buffer Pool
```sql
-- Primary tuning parameter: 70-80% of RAM on dedicated MySQL servers
-- Check current setting
SHOW VARIABLES LIKE 'innodb_buffer_pool_size';

-- Set dynamically (8.0+)
SET GLOBAL innodb_buffer_pool_size = 8589934592;  -- 8GB

-- Buffer pool hit ratio (should be > 99%)
SHOW STATUS LIKE 'Innodb_buffer_pool_read_requests';  -- Logical reads
SHOW STATUS LIKE 'Innodb_buffer_pool_reads';           -- Disk reads
-- Hit ratio = 1 - (reads / read_requests)
```

### InnoDB Log File
```sql
-- Larger log files = fewer checkpoints = better write performance
-- But longer recovery time after crash
-- Recommended: 256MB - 2GB
SHOW VARIABLES LIKE 'innodb_log_file_size';
-- Change requires restart (set in my.cnf)
```

### Durability Setting
```sql
-- innodb_flush_log_at_trx_commit:
-- 1 = Full ACID (flush on every commit) — safest, slowest
-- 2 = Flush once per second (data loss up to 1 second on OS crash) — good balance
-- 0 = Flush once per second (data loss on any crash) — fastest, least safe
SHOW VARIABLES LIKE 'innodb_flush_log_at_trx_commit';
SET GLOBAL innodb_flush_log_at_trx_commit = 1;  -- Production default
```

### Connection Settings
```sql
SHOW VARIABLES LIKE 'max_connections';     -- Default 151, increase for high-concurrency apps
SHOW VARIABLES LIKE 'thread_cache_size';   -- Cache threads to avoid creation overhead
SHOW VARIABLES LIKE 'wait_timeout';        -- Idle connection timeout (default 28800 = 8 hours)
```

## Security Features

### Roles (8.0+)
```sql
-- Create roles
CREATE ROLE 'app_readonly', 'app_readwrite', 'app_admin';

-- Grant privileges to roles
GRANT SELECT ON app_db.* TO 'app_readonly';
GRANT SELECT, INSERT, UPDATE, DELETE ON app_db.* TO 'app_readwrite';
GRANT ALL PRIVILEGES ON app_db.* TO 'app_admin';

-- Assign roles to users
CREATE USER 'appuser'@'%' IDENTIFIED BY 'StrongPassword123!';
GRANT 'app_readwrite' TO 'appuser'@'%';

-- Set default role
SET DEFAULT ROLE 'app_readwrite' TO 'appuser'@'%';
```

### Authentication
```sql
-- caching_sha2_password (default in 8.0, most secure built-in)
CREATE USER 'newuser'@'%' IDENTIFIED WITH caching_sha2_password BY 'StrongPassword123!';

-- Require SSL
ALTER USER 'appuser'@'%' REQUIRE SSL;

-- Require specific cipher
ALTER USER 'appuser'@'%' REQUIRE CIPHER 'TLS_AES_256_GCM_SHA384';

-- Password expiration
ALTER USER 'appuser'@'%' PASSWORD EXPIRE INTERVAL 90 DAY;

-- Failed login lockout
ALTER USER 'appuser'@'%' FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
```

### Data-at-Rest Encryption
```sql
-- Enable tablespace encryption (InnoDB)
ALTER TABLE app_db.sensitive_data ENCRYPTION='Y';

-- Check encryption status
SELECT TABLE_SCHEMA, TABLE_NAME, CREATE_OPTIONS
FROM INFORMATION_SCHEMA.TABLES
WHERE CREATE_OPTIONS LIKE '%ENCRYPTION%';
```

### Enterprise Features (MySQL Enterprise Edition)
- **Audit Plugin**: Log all database activity
- **Firewall**: Whitelist approved SQL patterns
- **Data Masking**: `mysql_data_masking` plugin
- **Transparent Data Encryption (TDE)**: Encrypt redo/undo logs, binary logs
- **Key Management**: HashiCorp Vault integration

## Monitoring

### Performance Schema Queries
```sql
-- Current running queries
SELECT
    THREAD_ID, EVENT_NAME, TIMER_WAIT / 1000000000 AS duration_ms,
    SQL_TEXT, CURRENT_SCHEMA
FROM performance_schema.events_statements_current
WHERE SQL_TEXT IS NOT NULL;

-- Full table scans (need indexes)
SELECT * FROM sys.statements_with_full_table_scans
ORDER BY no_index_used_count DESC LIMIT 20;

-- Unused indexes (candidates for removal)
SELECT * FROM sys.schema_unused_indexes;

-- Tables with most I/O
SELECT * FROM sys.io_global_by_file_by_bytes ORDER BY total DESC LIMIT 20;
```

### InnoDB Status
```sql
-- Comprehensive InnoDB diagnostics
SHOW ENGINE INNODB STATUS\G

-- Active transactions
SELECT
    trx_id, trx_state, trx_started,
    TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS duration_sec,
    trx_rows_locked, trx_rows_modified, trx_query
FROM INFORMATION_SCHEMA.INNODB_TRX
ORDER BY trx_started;
```

### Process List
```sql
-- Active connections (prefer performance_schema over SHOW PROCESSLIST)
SELECT
    PROCESSLIST_ID AS id,
    PROCESSLIST_USER AS user,
    PROCESSLIST_HOST AS host,
    PROCESSLIST_DB AS db,
    PROCESSLIST_COMMAND AS command,
    PROCESSLIST_TIME AS time_sec,
    PROCESSLIST_STATE AS state,
    LEFT(PROCESSLIST_INFO, 100) AS query_preview
FROM performance_schema.threads
WHERE PROCESSLIST_COMMAND != 'Sleep'
  AND PROCESSLIST_ID IS NOT NULL
ORDER BY PROCESSLIST_TIME DESC;
```

### sys Schema (Bundled with 8.0)
```sql
-- Top statements by latency
SELECT * FROM sys.statement_analysis ORDER BY total_latency DESC LIMIT 10;

-- Memory usage by connection
SELECT * FROM sys.memory_by_thread_by_current_bytes LIMIT 10;

-- Wait analysis
SELECT * FROM sys.waits_global_by_latency LIMIT 10;

-- Table statistics
SELECT * FROM sys.schema_table_statistics ORDER BY total_latency DESC LIMIT 10;
```

## Detection Markers

| Marker Type | Pattern |
|-------------|---------|
| **Backtick quoting** | `` `table_name` ``, `` `column` `` (unique to MySQL) |
| **DELIMITER** | `DELIMITER //` before stored procedures |
| **Engine specification** | `ENGINE=InnoDB`, `ENGINE=MyISAM` |
| **AUTO_INCREMENT** | Column definition includes `AUTO_INCREMENT` |
| **NULL functions** | `IFNULL()`, `COALESCE()` |
| **Date/time** | `NOW()`, `CURDATE()`, `DATE_FORMAT()` |
| **LIMIT** | `LIMIT n` without `OFFSET` keyword (though `LIMIT n OFFSET m` also works) |
| **System databases** | `information_schema`, `mysql`, `performance_schema`, `sys` |
| **Data types** | `INT UNSIGNED`, `TINYINT(1)` for boolean, `ENUM('a','b')`, `SET(...)`, `MEDIUMTEXT`, `LONGTEXT` |
| **Group concat** | `GROUP_CONCAT()` instead of `STRING_AGG()` or `LISTAGG()` |
| **Connection drivers** | mysql-connector-python, pymysql, mysql2 (node), MySqlConnector (.NET) |
| **Utilities** | `mysql` CLI, `mysqldump`, `mysqlpump` |
| **Variables** | `@@global.var`, `@@session.var`, user variables `@var` |
| **Boolean** | No native BOOLEAN display; uses `0` and `1` |
| **String quoting** | Single quotes for strings, backticks for identifiers (double quotes only with ANSI_QUOTES mode) |
