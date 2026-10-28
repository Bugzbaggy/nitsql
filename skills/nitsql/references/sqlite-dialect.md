# SQLite — Dialect Reference

## Version Features

### SQLite 3.25 (2018-09-15)
- **Window functions**: `ROW_NUMBER()`, `RANK()`, `DENSE_RANK()`, `LEAD()`, `LAG()`, `NTILE()`, `FIRST_VALUE()`, `LAST_VALUE()`
- **Renamed columns in ALTER TABLE**: `ALTER TABLE t RENAME COLUMN old TO new`

### SQLite 3.30 (2019-10-04)
- **FILTER clause on aggregates**: `COUNT(*) FILTER (WHERE status = 'active')`
- **NULLS FIRST / NULLS LAST**: Explicit NULL ordering in ORDER BY

### SQLite 3.33 (2020-08-14)
- **UPDATE FROM**: `UPDATE t SET col = s.val FROM source s WHERE t.id = s.id`
- **DECIMAL128 arithmetic improvements**

### SQLite 3.35 (2021-03-12)
- **RETURNING clause**: `INSERT ... RETURNING id`, `UPDATE ... RETURNING *`, `DELETE ... RETURNING *`
- **DROP COLUMN**: `ALTER TABLE t DROP COLUMN col` (previously required table rebuild)
- **Built-in math functions**: `ceil()`, `floor()`, `ln()`, `log()`, `pow()`, `sqrt()`, `trunc()`
- **Materialized CTEs**: `WITH cte AS MATERIALIZED (...)`

### SQLite 3.37 (2021-11-27)
- **STRICT tables**: Enforce declared column types (no type affinity coercion)
```sql
CREATE TABLE measurements (
    id INTEGER PRIMARY KEY,
    value REAL NOT NULL,
    label TEXT NOT NULL
) STRICT;
-- Inserting '42' as TEXT into REAL column now raises an error
```
- **ANY type in STRICT tables**: One column can opt out of strict typing

### SQLite 3.38 (2022-02-22)
- **unixepoch() function**: Convert date/time to Unix timestamp
- **JSON operators**: `->` and `->>` (extract JSON value / extract as text)
- **Built-in JSON functions** enabled by default (previously compile-time option)

### SQLite 3.39 (2022-09-05)
- **RIGHT OUTER JOIN** and **FULL OUTER JOIN**: Previously only LEFT JOIN was supported
- **IS DISTINCT FROM / IS NOT DISTINCT FROM**: NULL-safe equality
- **Built-in printf()** renamed to `format()` (printf still accepted as alias)

### SQLite 3.45 (2024-01-15)
- **JSONB**: Binary JSON storage for faster read-back of JSON values
- `jsonb()`, `jsonb_extract()`, `jsonb_insert()`, `jsonb_replace()`, `jsonb_set()`, `jsonb_patch()`
- JSONB stored in BLOB columns, not directly human-readable

## Essential PRAGMAs

### Connection Setup (Run Once Per Connection)
```sql
-- Every SQLite connection should configure these pragmas before any DML.
-- PRAGMAs are per-connection, NOT persisted across reconnections (except journal_mode).

-- WAL mode: allows concurrent reads while writing (persists after set once)
PRAGMA journal_mode=WAL;

-- Enable foreign key enforcement (OFF by default!)
PRAGMA foreign_keys=ON;

-- Retry for 5 seconds on SQLITE_BUSY instead of failing immediately
PRAGMA busy_timeout=5000;

-- NORMAL is safe with WAL mode and significantly faster than FULL
PRAGMA synchronous=NORMAL;

-- Negative value = number of KiB; -64000 ≈ 64 MB page cache
PRAGMA cache_size=-64000;

-- Store temp tables and indices in memory
PRAGMA temp_store=MEMORY;

-- Memory-mapped I/O: 256 MB (0 to disable; improves read performance)
PRAGMA mmap_size=268435456;

-- Auto-vacuum mode (must be set before any tables are created)
-- INCREMENTAL allows manual PRAGMA incremental_vacuum(N) to reclaim pages
PRAGMA auto_vacuum=INCREMENTAL;
```

### PRAGMA Notes
| PRAGMA | Persisted? | Notes |
|--------|-----------|-------|
| `journal_mode=WAL` | Yes (file-level) | Only needs to be set once; survives close/reopen |
| `foreign_keys=ON` | No (per-connection) | Must be set on every new connection |
| `busy_timeout` | No (per-connection) | Must be set on every new connection |
| `synchronous` | No (per-connection) | NORMAL is safe with WAL; FULL adds extra fsync |
| `cache_size` | No (per-connection) | Negative = KiB; positive = pages |
| `temp_store` | No (per-connection) | 0=DEFAULT, 1=FILE, 2=MEMORY |
| `mmap_size` | Partially | Stored in DB but can be overridden per connection |
| `auto_vacuum` | Yes (file-level) | Must be set before first CREATE TABLE |

## INTEGER PRIMARY KEY and AUTOINCREMENT

### rowid Alias Behavior
```sql
-- INTEGER PRIMARY KEY is a direct alias for SQLite's internal rowid
-- This is THE recommended pattern for auto-generated IDs in SQLite
CREATE TABLE users (
    user_id INTEGER PRIMARY KEY,  -- Alias for rowid; auto-assigns if NULL or omitted
    email TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL
);

-- Insert without specifying user_id: auto-assigns next available rowid
INSERT INTO users (email, name) VALUES ('alice@example.com', 'Alice');

-- Retrieve the generated ID
SELECT last_insert_rowid();  -- Returns the rowid just inserted
```

### Why AUTOINCREMENT Is Rarely Needed
```sql
-- AUTOINCREMENT adds overhead: maintains sqlite_sequence table, extra I/O per insert
-- Only difference: prevents reuse of deleted rowids
-- Without AUTOINCREMENT: rowid = max(existing rowids) + 1 (may reuse deleted IDs)
-- With AUTOINCREMENT: rowid = max(ever-used rowid) + 1 (never reuses)

-- BAD: unnecessary overhead for most use cases
CREATE TABLE events_bad (
    event_id INTEGER PRIMARY KEY AUTOINCREMENT,  -- Avoid unless you need non-reuse
    event_data TEXT
);

-- GOOD: standard pattern — simpler, faster
CREATE TABLE events_good (
    event_id INTEGER PRIMARY KEY,  -- Auto-generates via rowid alias
    event_data TEXT
);

-- AUTOINCREMENT is only needed when:
-- 1. External systems depend on IDs never being reused after deletion
-- 2. Audit/compliance requires monotonically increasing IDs with no gaps from reuse
-- In practice, this is very rare.
```

## WITHOUT ROWID Tables

```sql
-- WITHOUT ROWID stores data in the PRIMARY KEY's B-tree directly (clustered index)
-- Benefits: smaller storage for tables where PK is the only access pattern

-- Use case 1: Composite primary key lookup tables
CREATE TABLE user_roles (
    user_id INTEGER NOT NULL,
    role_id INTEGER NOT NULL,
    granted_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (user_id, role_id)
) WITHOUT ROWID;

-- Use case 2: Small rows with non-integer PK
CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
) WITHOUT ROWID;

-- Use case 3: Many-to-many junction tables
CREATE TABLE order_tags (
    order_id INTEGER NOT NULL,
    tag TEXT NOT NULL,
    PRIMARY KEY (order_id, tag)
) WITHOUT ROWID;

-- When to use WITHOUT ROWID:
-- - Composite primary keys (no separate rowid needed)
-- - TEXT or BLOB primary keys
-- - Small rows where rowid overhead is significant
-- When NOT to use:
-- - Tables with INTEGER PRIMARY KEY (already uses rowid efficiently)
-- - Large rows (B-tree page splitting is costlier)
-- - Tables that need rowid for FTS or other extensions
```

## Type Affinity System

### Default Behavior (Non-STRICT Tables)
```sql
-- SQLite uses TYPE AFFINITY, not strict types. Any column can store any type.
-- The declared type name determines affinity via pattern matching:
--
-- | Affinity  | Type names that trigger it                    |
-- |-----------|-----------------------------------------------|
-- | INTEGER   | INT, INTEGER, TINYINT, SMALLINT, BIGINT, etc. |
-- | TEXT      | TEXT, CHAR, VARCHAR, CLOB                      |
-- | REAL      | REAL, DOUBLE, FLOAT                            |
-- | NUMERIC   | NUMERIC, DECIMAL, BOOLEAN, DATE, DATETIME      |
-- | BLOB      | BLOB, or no type specified                     |

-- Affinity only determines how values are COERCED, not rejected:
CREATE TABLE demo (
    id INTEGER PRIMARY KEY,
    name TEXT,           -- TEXT affinity: stores as-is
    amount NUMERIC,      -- NUMERIC affinity: tries to convert text '42' to integer 42
    data BLOB            -- BLOB affinity: no conversion
);

-- This succeeds even though 'not_a_number' goes into a NUMERIC column:
INSERT INTO demo (name, amount, data) VALUES ('test', 'not_a_number', x'DEADBEEF');
-- Affinity just attempted conversion, but stores the original text when conversion fails
```

### VARCHAR(N) Has No Effect
```sql
-- CRITICAL: VARCHAR(255) in SQLite is parsed but the length constraint is IGNORED
-- SQLite stores it as TEXT affinity with no length enforcement

-- BAD: misleading — implies a 255-char limit that doesn't exist
CREATE TABLE contacts_bad (
    name VARCHAR(255),
    email VARCHAR(100)
);

-- GOOD: honest declaration for SQLite
CREATE TABLE contacts_good (
    name TEXT NOT NULL,
    email TEXT NOT NULL,
    CHECK (length(email) <= 320)  -- Use CHECK for actual length enforcement
);
```

### STRICT Tables (SQLite 3.37+)
```sql
-- STRICT keyword enforces column types — inserts of wrong type raise errors
CREATE TABLE measurements (
    sensor_id INTEGER PRIMARY KEY,
    reading REAL NOT NULL,
    unit TEXT NOT NULL,
    raw_data BLOB,
    recorded_at TEXT NOT NULL  -- ISO-8601 format
) STRICT;

-- Allowed types in STRICT tables: INTEGER, REAL, TEXT, BLOB, ANY
-- Attempting to insert text into a REAL column raises a type mismatch error

-- ANY type allows any value in a STRICT table (opt-out for one column)
CREATE TABLE flexible_data (
    id INTEGER PRIMARY KEY,
    key TEXT NOT NULL,
    value ANY  -- Can hold INTEGER, REAL, TEXT, or BLOB
) STRICT;
```

## Date and Time Handling

### Storage Strategies (No Native Date Type)
```sql
-- SQLite has no DATE, TIME, or TIMESTAMP type. Use one of these strategies:

-- Strategy 1: ISO-8601 text (RECOMMENDED — human-readable, sorts correctly)
CREATE TABLE events (
    event_id INTEGER PRIMARY KEY,
    event_time TEXT NOT NULL DEFAULT (datetime('now')),        -- '2026-04-06 12:30:00'
    event_date TEXT NOT NULL DEFAULT (date('now'))             -- '2026-04-06'
);

-- Strategy 2: Unix timestamp (INTEGER) — compact, fast arithmetic
CREATE TABLE logs (
    log_id INTEGER PRIMARY KEY,
    created_at INTEGER NOT NULL DEFAULT (unixepoch())          -- 1775193600
);

-- Strategy 3: Julian day number (REAL) — used by date functions internally
CREATE TABLE calendar (
    id INTEGER PRIMARY KEY,
    julian_day REAL NOT NULL DEFAULT (julianday('now'))         -- 2461402.5
);
```

### Built-in Date/Time Functions
```sql
-- Current date/time
SELECT date('now');                            -- '2026-04-06'
SELECT time('now');                            -- '14:30:00'
SELECT datetime('now');                        -- '2026-04-06 14:30:00'
SELECT datetime('now', 'localtime');           -- Convert UTC to local time
SELECT unixepoch();                            -- 1775193600  (3.38+)
SELECT unixepoch('now');                       -- Same as above

-- Date arithmetic
SELECT date('now', '+7 days');                 -- One week from now
SELECT date('now', '-1 month');                -- One month ago
SELECT datetime('now', '+2 hours', '+30 minutes');
SELECT date('now', 'start of month');          -- First day of current month
SELECT date('now', 'start of year', '+1 year', '-1 day');  -- Last day of year

-- Extract components
SELECT strftime('%Y', '2026-04-06');           -- '2026'
SELECT strftime('%m', '2026-04-06');           -- '04'
SELECT strftime('%W', '2026-04-06');           -- Week number

-- Convert between formats
SELECT datetime(1775193600, 'unixepoch');       -- Unix → ISO text
SELECT unixepoch('2026-04-06 14:00:00');        -- ISO text → Unix
SELECT julianday('2026-04-06');                 -- ISO text → Julian day

-- Date differences
SELECT julianday('2026-12-31') - julianday('2026-01-01');  -- Days between
SELECT CAST((unixepoch('2026-04-06') - unixepoch('2026-01-01')) / 86400 AS INTEGER);  -- Days via Unix
```

## JSON Support

### Core JSON Functions
```sql
-- json(): Validate and minify JSON text
SELECT json('  { "name" : "Alice" , "age" : 30 }  ');
-- '{"name":"Alice","age":30}'

-- json_extract(): Extract a value by path
SELECT json_extract('{"user":{"name":"Alice","scores":[95,87,92]}}', '$.user.name');
-- 'Alice'

SELECT json_extract('{"user":{"scores":[95,87,92]}}', '$.user.scores[0]');
-- 95

-- ->> operator (3.38+): Extract as text (always returns TEXT or NULL)
SELECT '{"name":"Alice","age":30}' ->> '$.name';    -- 'Alice'
SELECT '{"name":"Alice","age":30}' ->> '$.age';     -- '30' (text)

-- -> operator (3.38+): Extract as JSON (preserves type)
SELECT '{"user":{"name":"Alice"}}' -> '$.user';     -- '{"name":"Alice"}'
```

### JSON Aggregation and Table Functions
```sql
-- json_each(): Expand a JSON array into rows
SELECT je.key, je.value, je.type
FROM json_each('[10, "hello", true, null]') AS je;
-- 0, 10, integer
-- 1, hello, text
-- 2, 1, true
-- 3, (null), null

-- json_group_array(): Aggregate rows into a JSON array
SELECT json_group_array(name) FROM users WHERE active = 1;
-- '["Alice","Bob","Charlie"]'

-- json_group_object(): Aggregate key/value pairs into a JSON object
SELECT json_group_object(key, value) FROM settings;
-- '{"theme":"dark","lang":"en"}'

-- json_tree(): Recursively walk all JSON elements
SELECT jt.fullkey, jt.value, jt.type
FROM json_tree('{"a":{"b":[1,2]},"c":3}') AS jt
WHERE jt.type NOT IN ('object', 'array');

-- json_patch(): RFC 7396 Merge Patch
SELECT json_patch(
    '{"name":"Alice","role":"user"}',
    '{"role":"admin","dept":"eng"}'
);
-- '{"name":"Alice","role":"admin","dept":"eng"}'
```

### JSON in Table Columns
```sql
CREATE TABLE products (
    product_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    attributes TEXT NOT NULL DEFAULT '{}',  -- Store JSON as TEXT
    CHECK (json_valid(attributes))          -- Validate JSON on insert/update
);

-- Insert with JSON
INSERT INTO products (name, attributes)
VALUES ('Laptop', '{"brand":"Dell","ram_gb":16,"ports":["USB-C","HDMI"]}');

-- Query JSON fields
SELECT
    name,
    attributes ->> '$.brand' AS brand,
    attributes ->> '$.ram_gb' AS ram_gb
FROM products
WHERE CAST(attributes ->> '$.ram_gb' AS INTEGER) >= 16;

-- Index on JSON field (expression index)
CREATE INDEX idx_products_brand ON products (attributes ->> '$.brand');
```

## Full-Text Search (FTS5)

### Creating and Using FTS5 Tables
```sql
-- FTS5 virtual table for full-text search
CREATE VIRTUAL TABLE articles_fts USING fts5(
    title,
    body,
    author,
    content='articles',            -- External content table (optional)
    content_rowid='article_id',    -- Map to real table's rowid
    tokenize='porter unicode61'    -- Porter stemming + Unicode normalization
);

-- Populate from source table
INSERT INTO articles_fts (rowid, title, body, author)
SELECT article_id, title, body, author FROM articles;

-- Basic MATCH query (full-text search)
SELECT rowid, title, rank
FROM articles_fts
WHERE articles_fts MATCH 'database optimization'
ORDER BY rank;

-- Phrase search
SELECT * FROM articles_fts WHERE articles_fts MATCH '"full text search"';

-- Boolean operators
SELECT * FROM articles_fts WHERE articles_fts MATCH 'sqlite AND (performance OR optimization)';

-- Column-specific search
SELECT * FROM articles_fts WHERE articles_fts MATCH 'title:database';

-- Prefix search
SELECT * FROM articles_fts WHERE articles_fts MATCH 'optim*';

-- highlight() and snippet()
SELECT
    rowid,
    highlight(articles_fts, 0, '<b>', '</b>') AS highlighted_title,
    snippet(articles_fts, 1, '<b>', '</b>', '...', 32) AS body_snippet
FROM articles_fts
WHERE articles_fts MATCH 'sqlite performance'
ORDER BY rank;
```

### Keeping FTS5 in Sync with Content Table
```sql
-- Triggers to keep FTS index synchronized with source table
CREATE TRIGGER articles_ai AFTER INSERT ON articles BEGIN
    INSERT INTO articles_fts (rowid, title, body, author)
    VALUES (new.article_id, new.title, new.body, new.author);
END;

CREATE TRIGGER articles_ad AFTER DELETE ON articles BEGIN
    INSERT INTO articles_fts (articles_fts, rowid, title, body, author)
    VALUES ('delete', old.article_id, old.title, old.body, old.author);
END;

CREATE TRIGGER articles_au AFTER UPDATE ON articles BEGIN
    INSERT INTO articles_fts (articles_fts, rowid, title, body, author)
    VALUES ('delete', old.article_id, old.title, old.body, old.author);
    INSERT INTO articles_fts (rowid, title, body, author)
    VALUES (new.article_id, new.title, new.body, new.author);
END;
```

## Window Functions (3.25+)

```sql
-- Ranking
SELECT
    customer_id,
    order_date,
    total_amount,
    ROW_NUMBER() OVER (ORDER BY order_date DESC) AS row_num,
    RANK() OVER (ORDER BY total_amount DESC) AS amount_rank,
    DENSE_RANK() OVER (PARTITION BY customer_id ORDER BY total_amount DESC) AS cust_rank
FROM orders;

-- Running totals and moving averages
SELECT
    order_date,
    total_amount,
    SUM(total_amount) OVER (ORDER BY order_date ROWS UNBOUNDED PRECEDING) AS running_total,
    AVG(total_amount) OVER (ORDER BY order_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS moving_avg_7d
FROM orders;

-- LEAD / LAG
SELECT
    order_id,
    order_date,
    total_amount,
    LAG(total_amount, 1) OVER (ORDER BY order_date) AS prev_amount,
    LEAD(total_amount, 1) OVER (ORDER BY order_date) AS next_amount
FROM orders;

-- FILTER clause on window aggregates (3.30+)
SELECT
    order_date,
    COUNT(*) OVER w AS total_orders,
    COUNT(*) FILTER (WHERE status = 'completed') OVER w AS completed_orders
FROM orders
WINDOW w AS (ORDER BY order_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW);
```

## UPSERT (ON CONFLICT)

```sql
-- INSERT OR REPLACE replaces the entire row (losing columns not in INSERT)
-- Use ON CONFLICT for true UPSERT behavior (3.24+)

-- Basic upsert: update on conflict
INSERT INTO users (email, name, updated_at)
VALUES ('alice@example.com', 'Alice Smith', datetime('now'))
ON CONFLICT (email) DO UPDATE SET
    name = excluded.name,
    updated_at = excluded.updated_at;

-- Upsert with WHERE clause: conditional update
INSERT INTO inventory (product_id, quantity, warehouse_id)
VALUES (42, 100, 1)
ON CONFLICT (product_id, warehouse_id) DO UPDATE SET
    quantity = inventory.quantity + excluded.quantity
WHERE inventory.quantity + excluded.quantity <= 10000;

-- DO NOTHING: silently skip on conflict
INSERT OR IGNORE INTO tags (tag_name) VALUES ('sqlite');
-- Equivalent to:
INSERT INTO tags (tag_name) VALUES ('sqlite')
ON CONFLICT (tag_name) DO NOTHING;
```

## Generated Columns

```sql
-- VIRTUAL: computed on read, not stored (saves space, costs CPU on every read)
-- STORED: computed on write, physically stored (uses space, free on read)

CREATE TABLE orders (
    order_id INTEGER PRIMARY KEY,
    quantity INTEGER NOT NULL,
    unit_price REAL NOT NULL,
    tax_rate REAL NOT NULL DEFAULT 0.08,
    subtotal REAL GENERATED ALWAYS AS (quantity * unit_price) STORED,
    tax_amount REAL GENERATED ALWAYS AS (quantity * unit_price * tax_rate) VIRTUAL,
    total REAL GENERATED ALWAYS AS (quantity * unit_price * (1 + tax_rate)) STORED
);

-- STORED generated columns can be indexed
CREATE INDEX idx_orders_total ON orders (total);

-- VIRTUAL generated columns CANNOT be indexed
-- Generated columns can reference other (non-generated) columns in the same table
```

## Common Table Expressions (WITH / WITH RECURSIVE)

### Standard CTE
```sql
WITH active_customers AS (
    SELECT customer_id, name, email
    FROM customers
    WHERE status = 'active'
      AND last_order_date > date('now', '-1 year')
),
customer_totals AS (
    SELECT ac.customer_id, ac.name, SUM(o.total_amount) AS annual_total
    FROM active_customers ac
    JOIN orders o ON ac.customer_id = o.customer_id
    WHERE o.order_date > date('now', '-1 year')
    GROUP BY ac.customer_id, ac.name
)
SELECT name, annual_total
FROM customer_totals
WHERE annual_total > 1000
ORDER BY annual_total DESC;
```

### Recursive CTE
```sql
-- Generate a date series (SQLite has no generate_series built-in for dates)
WITH RECURSIVE date_range(d) AS (
    SELECT date('2026-01-01')                          -- Anchor: start date
    UNION ALL
    SELECT date(d, '+1 day')                           -- Recursive: next day
    FROM date_range
    WHERE d < '2026-01-31'                             -- Termination condition
)
SELECT d AS date, strftime('%w', d) AS day_of_week
FROM date_range;

-- Hierarchical query: org chart
WITH RECURSIVE org_tree AS (
    SELECT employee_id, name, manager_id, 0 AS depth
    FROM employees
    WHERE manager_id IS NULL                           -- Root: top-level manager
    UNION ALL
    SELECT e.employee_id, e.name, e.manager_id, ot.depth + 1
    FROM employees e
    JOIN org_tree ot ON e.manager_id = ot.employee_id
)
SELECT depth, name, employee_id, manager_id
FROM org_tree
ORDER BY depth, name;

-- Bill of materials: recursive parts explosion
WITH RECURSIVE bom AS (
    SELECT part_id, parent_id, part_name, 1 AS quantity, 0 AS level
    FROM parts
    WHERE parent_id IS NULL
    UNION ALL
    SELECT p.part_id, p.parent_id, p.part_name, p.quantity * bom.quantity, bom.level + 1
    FROM parts p
    JOIN bom ON p.parent_id = bom.part_id
)
SELECT level, part_name, quantity
FROM bom
ORDER BY level, part_name;
```

## EXPLAIN QUERY PLAN

### Interpreting Output
```sql
-- Run before a query to see the plan without executing it
EXPLAIN QUERY PLAN
SELECT o.order_id, c.name
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
WHERE o.order_date > '2026-01-01'
  AND o.status = 'active';

-- Output interpretation:
-- SCAN table_name               → Full table scan (no index used — often bad)
-- SEARCH table_name             → Index-assisted lookup (good)
-- USING INDEX idx_name          → Uses a non-covering index (lookup + row fetch)
-- USING COVERING INDEX idx_name → Index contains all needed columns (best)
-- USING INTEGER PRIMARY KEY     → Direct rowid lookup (fastest possible)
-- USE TEMP B-TREE FOR ORDER BY  → Sort required (consider index to avoid)
-- COMPOUND SUBQUERIES n AND m   → UNION / INTERSECT / EXCEPT operations

-- Full EXPLAIN (shows bytecode — advanced debugging)
EXPLAIN
SELECT * FROM orders WHERE order_id = 42;
-- Shows the VDBE (Virtual Database Engine) opcodes
```

### Optimization Hints from EXPLAIN QUERY PLAN
```sql
-- SCAN → Add an index on the WHERE clause columns
-- USE TEMP B-TREE → Add an index matching the ORDER BY columns
-- Multiple SCAN in a JOIN → Add index on the join column of the inner table
-- USING INDEX (non-covering) → Add INCLUDE-like columns if needed often
--   (SQLite doesn't have INCLUDE, but you can create a wider composite index)
```

## Connection Management

### Single-Writer Concurrency Model
```sql
-- SQLite allows only ONE writer at a time, regardless of mode.
-- Readers do NOT block other readers.

-- DELETE journal mode (default):
--   Writers block readers. Readers block writers.
--   Only one connection can read OR write at a time effectively.

-- WAL mode (recommended for multi-connection apps):
--   Writers do NOT block readers. Readers do NOT block writers.
--   Multiple readers can proceed concurrently with one writer.
--   Only constraint: one writer at a time (others get SQLITE_BUSY).

-- Set WAL mode (only need to do once per database file):
PRAGMA journal_mode=WAL;

-- busy_timeout tells SQLite to retry for N milliseconds before returning BUSY
PRAGMA busy_timeout=5000;
```

### Connection Pooling Considerations
```text
- SQLite connections are cheap to create (no network round-trip)
- Pool size is less critical than with client/server databases
- Keep the pool small (1-4 connections) to minimize lock contention
- Consider a single writer connection + multiple reader connections
- WAL mode is essential for any multi-connection setup
- Always close connections promptly to release file locks
```

## Application-Level Error Handling

SQLite has no stored procedures, triggers with exception handling, or PL/SQL-style blocks. All error handling must be done in application code.

### Python (sqlite3 module)
```python
import sqlite3

def setup_connection(db_path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA cache_size=-64000")
    conn.execute("PRAGMA temp_store=MEMORY")
    conn.row_factory = sqlite3.Row  # Access columns by name
    return conn

def upsert_user(conn: sqlite3.Connection, email: str, name: str) -> int:
    try:
        cursor = conn.execute(
            """INSERT INTO users (email, name, updated_at)
               VALUES (?, ?, datetime('now'))
               ON CONFLICT (email) DO UPDATE SET
                   name = excluded.name,
                   updated_at = excluded.updated_at
               RETURNING user_id""",
            (email, name)
        )
        row = cursor.fetchone()
        conn.commit()
        return row["user_id"]
    except sqlite3.IntegrityError as e:
        conn.rollback()
        raise ValueError(f"Data integrity error: {e}")
    except sqlite3.OperationalError as e:
        conn.rollback()
        if "database is locked" in str(e):
            raise TimeoutError("Database busy — retry later")
        raise
```

### Node.js (better-sqlite3)
```javascript
const Database = require('better-sqlite3');

function setupConnection(dbPath) {
    const db = new Database(dbPath);
    db.pragma('journal_mode = WAL');
    db.pragma('foreign_keys = ON');
    db.pragma('busy_timeout = 5000');
    db.pragma('synchronous = NORMAL');
    db.pragma('cache_size = -64000');
    db.pragma('temp_store = MEMORY');
    return db;
}

// better-sqlite3 is synchronous — no callback/promise needed
const upsertUser = db.prepare(`
    INSERT INTO users (email, name, updated_at)
    VALUES (?, ?, datetime('now'))
    ON CONFLICT (email) DO UPDATE SET
        name = excluded.name, updated_at = excluded.updated_at
    RETURNING user_id
`);

// Transaction helper
const batchInsert = db.transaction((users) => {
    for (const user of users) {
        upsertUser.run(user.email, user.name);
    }
});

try {
    batchInsert(userList);
} catch (err) {
    if (err.code === 'SQLITE_BUSY') {
        // Retry logic
    } else if (err.code === 'SQLITE_CONSTRAINT_FOREIGNKEY') {
        // FK violation
    }
}
```

### C# (Microsoft.Data.Sqlite)
```csharp
using Microsoft.Data.Sqlite;

static SqliteConnection SetupConnection(string dbPath)
{
    var conn = new SqliteConnection($"Data Source={dbPath}");
    conn.Open();
    using var cmd = conn.CreateCommand();
    cmd.CommandText = @"
        PRAGMA journal_mode=WAL;
        PRAGMA foreign_keys=ON;
        PRAGMA busy_timeout=5000;
        PRAGMA synchronous=NORMAL;
        PRAGMA cache_size=-64000;
        PRAGMA temp_store=MEMORY;
    ";
    cmd.ExecuteNonQuery();
    return conn;
}

// Parameterized query with named parameters
using var cmd = new SqliteCommand(
    "SELECT * FROM users WHERE email = @email", conn);
cmd.Parameters.AddWithValue("@email", email);
```

## Parameter Syntax

### Positional Parameters
```sql
-- ? (positional, 1-based)
SELECT * FROM users WHERE user_id = ? AND status = ?;
-- Bound in order: (42, 'active')

-- ?NNN (numbered positional)
SELECT * FROM users WHERE user_id = ?1 AND status = ?2;
-- Allows reuse: WHERE id = ?1 OR parent_id = ?1
```

### Named Parameters
```sql
-- :name
SELECT * FROM users WHERE email = :email AND status = :status;

-- @name
SELECT * FROM users WHERE email = @email AND status = @status;

-- $name
SELECT * FROM users WHERE email = $email AND status = $status;

-- All three forms are equivalent — choice depends on your driver/language
-- Python sqlite3: use :name or ?
-- better-sqlite3 (Node.js): use :name, @name, or $name
-- Microsoft.Data.Sqlite: use @name or $name
```

## Backup Strategies

### .backup Command (sqlite3 CLI)
```bash
# Online backup while database is in use
sqlite3 mydb.db ".backup /path/to/backup.db"

# With explicit database name
sqlite3 mydb.db ".backup main /path/to/backup.db"
```

### VACUUM INTO (3.27+)
```sql
-- Creates a compacted copy of the database (defragmented, no free pages)
VACUUM INTO '/path/to/backup.db';
-- Does not modify the source database
-- Safe to run while other connections are active (reads only)
```

### sqlite3_backup API (Programmatic)
```python
import sqlite3

def backup_database(source_path: str, dest_path: str) -> None:
    source = sqlite3.connect(source_path)
    dest = sqlite3.connect(dest_path)
    with dest:
        source.backup(dest, pages=100, progress=backup_progress)
    dest.close()
    source.close()

def backup_progress(status, remaining, total):
    print(f"Backup: {total - remaining}/{total} pages copied")
```

## Limitations

| Limitation | Details | Workaround |
|------------|---------|------------|
| **No ALTER COLUMN** | Cannot change column type, rename (before 3.25), add constraints | Rebuild table: create new, copy data, drop old, rename new |
| **No DROP COLUMN** (< 3.35) | `ALTER TABLE DROP COLUMN` added in 3.35 | Rebuild table (see above) |
| **No RIGHT/FULL JOIN** (< 3.39) | Only LEFT JOIN supported before 3.39 | Rewrite with LEFT JOIN + UNION, or upgrade |
| **No GRANT / REVOKE** | No built-in user/role system | Handle permissions in application layer or file-system ACLs |
| **Single writer** | Only one write transaction at a time | Use WAL mode + busy_timeout; queue writes in application |
| **No stored procedures** | No PL/SQL, T-SQL, or PL/pgSQL | Implement logic in application code |
| **No server process** | Embedded library, no daemon | Deploy behind an application server |
| **Limited ALTER TABLE** | Cannot add constraints to existing columns | Rebuild table or use CHECK on new columns |
| **No materialized views** | No `CREATE MATERIALIZED VIEW` | Use regular tables + triggers or periodic refresh |
| **64-bit rowid limit** | Max rowid = 9,223,372,036,854,775,807 | Not a practical limitation |
| **Max database size** | 281 TB (theoretical), ~140 TB practical | Not a practical limitation for most use cases |
| **Max row size** | 1 GB (default 1,000,000,000 bytes) | Adjustable at compile time |

## Detection Markers

Use these patterns to identify SQLite dialect in SQL files:

| Marker Type | Pattern |
|-------------|---------|
| **PRAGMAs** | `PRAGMA journal_mode`, `PRAGMA foreign_keys`, `PRAGMA busy_timeout`, `PRAGMA synchronous` |
| **AUTOINCREMENT** | `AUTOINCREMENT` (one word, not `AUTO_INCREMENT` like MySQL) |
| **rowid** | `INTEGER PRIMARY KEY` as auto-increment, `last_insert_rowid()`, `rowid` |
| **Table modifiers** | `WITHOUT ROWID`, `STRICT` |
| **Built-in functions** | `datetime('now')`, `date('now')`, `unixepoch()`, `julianday()`, `strftime()` |
| **JSON operators** | `->`, `->>`, `json_extract()`, `json_each()`, `json_group_array()` |
| **FTS5** | `CREATE VIRTUAL TABLE ... USING fts5(...)`, `MATCH`, `highlight()`, `snippet()` |
| **Conflict handling** | `INSERT OR REPLACE`, `INSERT OR IGNORE`, `ON CONFLICT ... DO UPDATE` |
| **Parameter syntax** | `?`, `:name`, `@name`, `$name` (without type declarations) |
| **CLI commands** | `.backup`, `.dump`, `.import`, `.schema`, `.tables` |
| **Data types** | `TEXT` (not `VARCHAR`), `INTEGER` (not `INT`), `REAL` (not `DOUBLE`) |
| **File extension** | `.db`, `.sqlite`, `.sqlite3` |
| **Connection drivers** | sqlite3 (Python), better-sqlite3/sql.js (Node.js), Microsoft.Data.Sqlite (.NET) |
| **System tables** | `sqlite_master`, `sqlite_sequence`, `sqlite_stat1` |
| **VACUUM** | `VACUUM`, `VACUUM INTO` |
| **Explain** | `EXPLAIN QUERY PLAN` (not `EXPLAIN ANALYZE`) |
