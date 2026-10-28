-- ============================================================================
-- SQLITE EXAMPLES — SA-LITE RULE VIOLATION TESTS
-- ============================================================================
-- This file is split into two parts:
--   Part A: Code that intentionally TRIGGERS SA-LITE violations
--   Part B: Correct SQLite patterns that should NOT trigger violations
--
-- SA-LITE001: Missing PRAGMA journal_mode=WAL
-- SA-LITE002: Missing PRAGMA foreign_keys=ON when REFERENCES/FOREIGN KEY used
-- SA-LITE003: Unnecessary AUTOINCREMENT
-- SA-LITE004: Missing PRAGMA busy_timeout when write operations present
-- SA-LITE005: VARCHAR(N) in CREATE TABLE (length ignored by SQLite)
-- ============================================================================


-- ############################################################################
-- PART A: INTENTIONAL VIOLATIONS
-- ############################################################################
-- The following section deliberately omits required PRAGMAs and uses
-- anti-patterns so the analyzer can flag them.
-- NOTE: No PRAGMA journal_mode=WAL anywhere → triggers SA-LITE001
-- NOTE: No PRAGMA foreign_keys=ON anywhere  → triggers SA-LITE002
-- NOTE: No PRAGMA busy_timeout anywhere     → triggers SA-LITE004


-- ============================================================================
-- SA-LITE001 TRIGGER: DML present but no PRAGMA journal_mode=WAL
-- The analyzer sees INSERT/UPDATE/SELECT/CREATE TABLE without WAL mode set.
-- ============================================================================

CREATE TABLE customers (
    customer_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

INSERT INTO customers (name, email) VALUES ('Alice Johnson', 'alice@example.com');
INSERT INTO customers (name, email) VALUES ('Bob Smith', 'bob@example.com');

SELECT customer_id, name, email FROM customers WHERE email = 'alice@example.com';


-- ============================================================================
-- SA-LITE002 TRIGGER: FOREIGN KEY / REFERENCES without PRAGMA foreign_keys=ON
-- SQLite does NOT enforce foreign keys by default. Without the pragma,
-- these constraints are silently ignored.
-- ============================================================================

CREATE TABLE orders (
    order_id INTEGER PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(customer_id),
    order_date TEXT NOT NULL DEFAULT (datetime('now')),
    status TEXT NOT NULL DEFAULT 'pending',
    total_amount REAL NOT NULL DEFAULT 0.0
);

CREATE TABLE order_items (
    item_id INTEGER PRIMARY KEY,
    order_id INTEGER NOT NULL,
    product_name TEXT NOT NULL,
    quantity INTEGER NOT NULL DEFAULT 1,
    unit_price REAL NOT NULL,
    FOREIGN KEY (order_id) REFERENCES orders(order_id) ON DELETE CASCADE
);

-- This INSERT would succeed even with an invalid customer_id because
-- foreign keys are not enforced without the pragma:
INSERT INTO orders (customer_id, order_date, status, total_amount)
VALUES (9999, datetime('now'), 'pending', 49.99);


-- ============================================================================
-- SA-LITE003 TRIGGER: Unnecessary AUTOINCREMENT
-- INTEGER PRIMARY KEY already auto-generates via rowid alias.
-- AUTOINCREMENT adds overhead (sqlite_sequence table) and is rarely needed.
-- ============================================================================

CREATE TABLE audit_log (
    log_id INTEGER PRIMARY KEY AUTOINCREMENT,
    action TEXT NOT NULL,
    table_name TEXT NOT NULL,
    record_id INTEGER,
    changed_by TEXT,
    changed_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE notifications (
    notification_id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    message TEXT NOT NULL,
    is_read INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

INSERT INTO audit_log (action, table_name, record_id, changed_by)
VALUES ('INSERT', 'customers', 1, 'system');

INSERT INTO notifications (user_id, message)
VALUES (1, 'Welcome to the platform!');


-- ============================================================================
-- SA-LITE004 TRIGGER: INSERT/UPDATE present but no PRAGMA busy_timeout
-- Without busy_timeout, concurrent write attempts get SQLITE_BUSY immediately
-- instead of retrying for a configurable duration.
-- ============================================================================

UPDATE customers SET name = 'Alice J.' WHERE customer_id = 1;

DELETE FROM notifications WHERE is_read = 1 AND created_at < date('now', '-30 days');


-- ============================================================================
-- SA-LITE005 TRIGGER: VARCHAR(N) in CREATE TABLE
-- SQLite ignores the length in VARCHAR(255). All text is stored as TEXT
-- affinity with no length enforcement. This misleads developers.
-- ============================================================================

CREATE TABLE contacts (
    contact_id INTEGER PRIMARY KEY,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    email VARCHAR(255),
    phone VARCHAR(20),
    notes VARCHAR(4000)
);

INSERT INTO contacts (first_name, last_name, email, phone)
VALUES ('Charlie', 'Brown', 'charlie@example.com', '+1-555-0100');


-- ############################################################################
-- PART B: CORRECT SQLITE PATTERNS (NO VIOLATIONS EXPECTED)
-- ############################################################################
-- If this section were in its own file WITH the proper PRAGMAs, none of these
-- patterns would trigger any SA-LITE violations.
-- The patterns below demonstrate idiomatic, production-quality SQLite usage.


-- ============================================================================
-- SECTION 1: Proper PRAGMA Setup (Connection Initialization)
-- ============================================================================
-- In a real application, these PRAGMAs would be at the very top of the file
-- or executed once when each database connection is opened.

-- PRAGMA journal_mode=WAL;       -- Enables concurrent reads during writes
-- PRAGMA foreign_keys=ON;        -- Enforces FK constraints (off by default!)
-- PRAGMA busy_timeout=5000;      -- Retry for 5s on SQLITE_BUSY
-- PRAGMA synchronous=NORMAL;     -- Safe with WAL, faster than FULL
-- PRAGMA cache_size=-64000;      -- 64 MB page cache
-- PRAGMA temp_store=MEMORY;      -- Temp tables/indices in memory
-- PRAGMA mmap_size=268435456;    -- 256 MB memory-mapped I/O


-- ============================================================================
-- SECTION 2: INTEGER PRIMARY KEY Without AUTOINCREMENT (Correct Pattern)
-- ============================================================================

CREATE TABLE products (
    product_id INTEGER PRIMARY KEY,    -- rowid alias, auto-generates IDs
    name TEXT NOT NULL,
    description TEXT,
    price REAL NOT NULL CHECK (price >= 0),
    stock_quantity INTEGER NOT NULL DEFAULT 0 CHECK (stock_quantity >= 0),
    category TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

INSERT INTO products (name, description, price, stock_quantity, category)
VALUES ('Wireless Mouse', 'Ergonomic bluetooth mouse', 29.99, 150, 'electronics');

INSERT INTO products (name, description, price, stock_quantity, category)
VALUES ('USB-C Hub', '7-port hub with HDMI', 49.99, 75, 'electronics');

-- Retrieve auto-generated ID
SELECT last_insert_rowid();


-- ============================================================================
-- SECTION 3: TEXT Instead of VARCHAR (Correct Pattern)
-- ============================================================================

CREATE TABLE employees (
    employee_id INTEGER PRIMARY KEY,
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    email TEXT NOT NULL UNIQUE,
    department TEXT NOT NULL,
    hire_date TEXT NOT NULL DEFAULT (date('now')),
    CHECK (length(email) <= 320),         -- Explicit length check if needed
    CHECK (length(first_name) <= 100),
    CHECK (length(last_name) <= 100)
);


-- ============================================================================
-- SECTION 4: WITHOUT ROWID Table
-- ============================================================================
-- WITHOUT ROWID is ideal for composite-PK lookup/junction tables and
-- tables with non-integer primary keys.

CREATE TABLE employee_skills (
    employee_id INTEGER NOT NULL,
    skill_name TEXT NOT NULL,
    proficiency_level INTEGER NOT NULL CHECK (proficiency_level BETWEEN 1 AND 5),
    certified_at TEXT,
    PRIMARY KEY (employee_id, skill_name)
) WITHOUT ROWID;

INSERT INTO employee_skills (employee_id, skill_name, proficiency_level, certified_at)
VALUES (1, 'SQL', 5, '2025-06-15');

INSERT INTO employee_skills (employee_id, skill_name, proficiency_level)
VALUES (1, 'Python', 4);

-- Config/settings table with text PK
CREATE TABLE app_config (
    config_key TEXT PRIMARY KEY,
    config_value TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
) WITHOUT ROWID;

INSERT INTO app_config (config_key, config_value)
VALUES ('app.version', '2.1.0');

INSERT INTO app_config (config_key, config_value)
VALUES ('app.maintenance_mode', 'false');


-- ============================================================================
-- SECTION 5: STRICT Table (SQLite 3.37+)
-- ============================================================================

CREATE TABLE sensor_readings (
    reading_id INTEGER PRIMARY KEY,
    sensor_id INTEGER NOT NULL,
    temperature REAL NOT NULL,
    humidity REAL NOT NULL,
    label TEXT NOT NULL,
    recorded_at TEXT NOT NULL DEFAULT (datetime('now'))
) STRICT;

-- These inserts work because the types match the column declarations
INSERT INTO sensor_readings (sensor_id, temperature, humidity, label)
VALUES (101, 22.5, 45.2, 'lab-room-a');

INSERT INTO sensor_readings (sensor_id, temperature, humidity, label)
VALUES (102, 19.8, 62.1, 'warehouse-b');

-- In a STRICT table, this would FAIL at runtime:
-- INSERT INTO sensor_readings (sensor_id, temperature, humidity, label)
-- VALUES ('not_an_int', 22.5, 45.2, 'lab');  -- Error: type mismatch


-- ============================================================================
-- SECTION 6: JSON Operations with json_extract and ->>
-- ============================================================================

CREATE TABLE product_metadata (
    product_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    attributes TEXT NOT NULL DEFAULT '{}',
    CHECK (json_valid(attributes))
);

INSERT INTO product_metadata (product_id, name, attributes)
VALUES (1, 'Laptop Pro', '{"brand":"Dell","ram_gb":32,"ports":["USB-C","HDMI","Thunderbolt"]}');

INSERT INTO product_metadata (product_id, name, attributes)
VALUES (2, 'Monitor Ultra', '{"brand":"LG","size_inches":27,"panel":"IPS","resolution":"4K"}');

INSERT INTO product_metadata (product_id, name, attributes)
VALUES (3, 'Keyboard Mech', '{"brand":"Keychron","switches":"brown","wireless":true}');

-- Extract with json_extract()
SELECT
    name,
    json_extract(attributes, '$.brand') AS brand,
    json_extract(attributes, '$.ram_gb') AS ram_gb
FROM product_metadata
WHERE json_extract(attributes, '$.brand') = 'Dell';

-- Extract with ->> operator (3.38+, returns text)
SELECT
    name,
    attributes ->> '$.brand' AS brand,
    attributes ->> '$.size_inches' AS size
FROM product_metadata
WHERE attributes ->> '$.brand' = 'LG';

-- Expand JSON arrays with json_each()
SELECT
    pm.name,
    je.value AS port
FROM product_metadata pm, json_each(pm.attributes, '$.ports') AS je
WHERE pm.product_id = 1;

-- Aggregate into JSON
SELECT json_group_array(
    json_object('id', product_id, 'name', name, 'brand', attributes ->> '$.brand')
) AS products_json
FROM product_metadata;

-- json_patch() for merging JSON objects
SELECT json_patch(
    '{"brand":"Dell","ram_gb":16}',
    '{"ram_gb":32,"ssd_gb":512}'
) AS merged;
-- Result: '{"brand":"Dell","ram_gb":32,"ssd_gb":512}'

-- Expression index on JSON field
CREATE INDEX idx_product_brand ON product_metadata (json_extract(attributes, '$.brand'));


-- ============================================================================
-- SECTION 7: FTS5 Full-Text Search
-- ============================================================================

CREATE TABLE articles (
    article_id INTEGER PRIMARY KEY,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    author TEXT NOT NULL,
    published_at TEXT NOT NULL DEFAULT (datetime('now'))
);

INSERT INTO articles (title, body, author)
VALUES (
    'Getting Started with SQLite FTS5',
    'Full-text search in SQLite is powered by the FTS5 extension. It supports boolean queries, phrase matching, prefix search, and custom tokenizers. FTS5 is significantly faster than LIKE or GLOB for text search operations.',
    'Jane Developer'
);

INSERT INTO articles (title, body, author)
VALUES (
    'SQLite Performance Optimization Guide',
    'Key performance techniques include WAL mode, proper indexing, EXPLAIN QUERY PLAN analysis, and avoiding unnecessary AUTOINCREMENT. The busy_timeout pragma prevents spurious SQLITE_BUSY errors.',
    'John DBA'
);

INSERT INTO articles (title, body, author)
VALUES (
    'Database Migration Strategies',
    'When migrating from PostgreSQL or MySQL to SQLite, pay attention to type affinity differences, missing stored procedure support, and the single-writer concurrency model.',
    'Jane Developer'
);

-- Create FTS5 virtual table
CREATE VIRTUAL TABLE articles_fts USING fts5(
    title,
    body,
    author,
    content='articles',
    content_rowid='article_id',
    tokenize='porter unicode61'
);

-- Populate FTS index from source table
INSERT INTO articles_fts (rowid, title, body, author)
SELECT article_id, title, body, author FROM articles;

-- Basic MATCH search
SELECT rowid, title, rank
FROM articles_fts
WHERE articles_fts MATCH 'sqlite performance'
ORDER BY rank;

-- Phrase search
SELECT rowid, title
FROM articles_fts
WHERE articles_fts MATCH '"full-text search"';

-- Column-specific search
SELECT rowid, title
FROM articles_fts
WHERE articles_fts MATCH 'author:Jane';

-- highlight() and snippet()
SELECT
    rowid,
    highlight(articles_fts, 0, '<b>', '</b>') AS highlighted_title,
    snippet(articles_fts, 1, '<b>', '</b>', '...', 32) AS body_snippet
FROM articles_fts
WHERE articles_fts MATCH 'SQLite optimization'
ORDER BY rank;

-- Boolean operators
SELECT rowid, title
FROM articles_fts
WHERE articles_fts MATCH 'sqlite AND (performance OR optimization) NOT migration';

-- Prefix search
SELECT rowid, title
FROM articles_fts
WHERE articles_fts MATCH 'optim*';


-- ============================================================================
-- SECTION 8: UPSERT with ON CONFLICT
-- ============================================================================

CREATE TABLE inventory (
    product_id INTEGER NOT NULL,
    warehouse_id INTEGER NOT NULL,
    quantity INTEGER NOT NULL DEFAULT 0 CHECK (quantity >= 0),
    last_restocked TEXT,
    PRIMARY KEY (product_id, warehouse_id)
) WITHOUT ROWID;

-- Basic upsert: insert or update quantity
INSERT INTO inventory (product_id, warehouse_id, quantity, last_restocked)
VALUES (1, 100, 50, datetime('now'))
ON CONFLICT (product_id, warehouse_id) DO UPDATE SET
    quantity = inventory.quantity + excluded.quantity,
    last_restocked = excluded.last_restocked;

-- Another upsert with conditional update
INSERT INTO inventory (product_id, warehouse_id, quantity, last_restocked)
VALUES (1, 100, 200, datetime('now'))
ON CONFLICT (product_id, warehouse_id) DO UPDATE SET
    quantity = inventory.quantity + excluded.quantity,
    last_restocked = excluded.last_restocked
WHERE inventory.quantity + excluded.quantity <= 10000;

-- DO NOTHING on conflict (silently skip duplicates)
INSERT INTO inventory (product_id, warehouse_id, quantity)
VALUES (2, 100, 30)
ON CONFLICT (product_id, warehouse_id) DO NOTHING;

-- Upsert with RETURNING (3.35+)
INSERT INTO inventory (product_id, warehouse_id, quantity, last_restocked)
VALUES (3, 100, 75, datetime('now'))
ON CONFLICT (product_id, warehouse_id) DO UPDATE SET
    quantity = inventory.quantity + excluded.quantity,
    last_restocked = excluded.last_restocked
RETURNING product_id, warehouse_id, quantity;


-- ============================================================================
-- SECTION 9: EXPLAIN QUERY PLAN
-- ============================================================================

-- Create indexes for the explain examples
CREATE INDEX idx_orders_customer ON orders (customer_id);
CREATE INDEX idx_orders_status ON orders (status);
CREATE INDEX idx_orders_date_status ON orders (order_date, status);
CREATE INDEX idx_order_items_order ON order_items (order_id);

-- Example: see how SQLite plans to execute a join
EXPLAIN QUERY PLAN
SELECT o.order_id, o.order_date, o.total_amount, c.name
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
WHERE o.status = 'active'
  AND o.order_date > '2026-01-01'
ORDER BY o.order_date DESC;

-- Expected output interpretation:
-- SEARCH orders USING INDEX idx_orders_date_status (order_date>? AND status=?)
-- SEARCH customers USING INTEGER PRIMARY KEY (rowid=?)
-- ↑ SEARCH = good (index used), SCAN = review needed (full table scan)

-- Example: covering index check
EXPLAIN QUERY PLAN
SELECT order_id, status FROM orders WHERE status = 'pending';
-- If idx_orders_status covers both columns → USING COVERING INDEX

-- Example: subquery plan
EXPLAIN QUERY PLAN
SELECT c.name, (
    SELECT COUNT(*) FROM orders o WHERE o.customer_id = c.customer_id
) AS order_count
FROM customers c;


-- ============================================================================
-- SECTION 10: Generated Columns
-- ============================================================================

CREATE TABLE line_items (
    item_id INTEGER PRIMARY KEY,
    description TEXT NOT NULL,
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price REAL NOT NULL CHECK (unit_price >= 0),
    tax_rate REAL NOT NULL DEFAULT 0.08,
    -- STORED: physically saved, can be indexed
    subtotal REAL GENERATED ALWAYS AS (quantity * unit_price) STORED,
    -- VIRTUAL: computed on read, not stored on disk
    tax_amount REAL GENERATED ALWAYS AS (quantity * unit_price * tax_rate) VIRTUAL,
    -- STORED: can be used in WHERE clauses with index support
    total REAL GENERATED ALWAYS AS (quantity * unit_price * (1.0 + tax_rate)) STORED
);

-- Index on stored generated column
CREATE INDEX idx_line_items_total ON line_items (total);

INSERT INTO line_items (description, quantity, unit_price, tax_rate)
VALUES ('Widget A', 10, 5.99, 0.08);

INSERT INTO line_items (description, quantity, unit_price, tax_rate)
VALUES ('Gadget B', 3, 24.99, 0.10);

-- Query uses generated columns directly
SELECT description, subtotal, tax_amount, total
FROM line_items
WHERE total > 50.00
ORDER BY total DESC;


-- ============================================================================
-- SECTION 11: Recursive CTE — Date Series Generation
-- ============================================================================

-- Generate a date series for January 2026 (no generate_series in SQLite for dates)
WITH RECURSIVE date_series(d) AS (
    SELECT date('2026-01-01')
    UNION ALL
    SELECT date(d, '+1 day')
    FROM date_series
    WHERE d < '2026-01-31'
)
SELECT
    d AS date,
    CASE CAST(strftime('%w', d) AS INTEGER)
        WHEN 0 THEN 'Sunday'
        WHEN 1 THEN 'Monday'
        WHEN 2 THEN 'Tuesday'
        WHEN 3 THEN 'Wednesday'
        WHEN 4 THEN 'Thursday'
        WHEN 5 THEN 'Friday'
        WHEN 6 THEN 'Saturday'
    END AS day_name,
    strftime('%W', d) AS week_number
FROM date_series;

-- Left join date series with orders to find days with no orders
WITH RECURSIVE date_series(d) AS (
    SELECT date('2026-01-01')
    UNION ALL
    SELECT date(d, '+1 day')
    FROM date_series
    WHERE d < '2026-01-31'
)
SELECT
    ds.d AS date,
    COALESCE(COUNT(o.order_id), 0) AS order_count,
    COALESCE(SUM(o.total_amount), 0.0) AS daily_total
FROM date_series ds
LEFT JOIN orders o ON date(o.order_date) = ds.d
GROUP BY ds.d
ORDER BY ds.d;


-- ============================================================================
-- SECTION 12: Hierarchical Query with Recursive CTE
-- ============================================================================

CREATE TABLE categories (
    category_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    parent_id INTEGER,
    FOREIGN KEY (parent_id) REFERENCES categories(category_id)
);

INSERT INTO categories (category_id, name, parent_id) VALUES (1, 'Electronics', NULL);
INSERT INTO categories (category_id, name, parent_id) VALUES (2, 'Computers', 1);
INSERT INTO categories (category_id, name, parent_id) VALUES (3, 'Laptops', 2);
INSERT INTO categories (category_id, name, parent_id) VALUES (4, 'Desktops', 2);
INSERT INTO categories (category_id, name, parent_id) VALUES (5, 'Peripherals', 1);
INSERT INTO categories (category_id, name, parent_id) VALUES (6, 'Keyboards', 5);
INSERT INTO categories (category_id, name, parent_id) VALUES (7, 'Mice', 5);

-- Traverse the category tree top-down
WITH RECURSIVE category_tree AS (
    SELECT category_id, name, parent_id, 0 AS depth, name AS path
    FROM categories
    WHERE parent_id IS NULL
    UNION ALL
    SELECT c.category_id, c.name, c.parent_id, ct.depth + 1,
           ct.path || ' > ' || c.name
    FROM categories c
    JOIN category_tree ct ON c.parent_id = ct.category_id
)
SELECT
    depth,
    substr('                ', 1, depth * 4) || name AS indented_name,
    path
FROM category_tree
ORDER BY path;


-- ============================================================================
-- SECTION 13: Window Functions
-- ============================================================================

-- Ranking customers by total spend
SELECT
    c.name,
    SUM(o.total_amount) AS total_spent,
    RANK() OVER (ORDER BY SUM(o.total_amount) DESC) AS spend_rank,
    DENSE_RANK() OVER (ORDER BY SUM(o.total_amount) DESC) AS dense_rank
FROM customers c
JOIN orders o ON c.customer_id = o.customer_id
GROUP BY c.customer_id, c.name;

-- Running total of daily orders
SELECT
    date(order_date) AS order_day,
    COUNT(*) AS daily_orders,
    SUM(total_amount) AS daily_revenue,
    SUM(SUM(total_amount)) OVER (ORDER BY date(order_date) ROWS UNBOUNDED PRECEDING) AS cumulative_revenue
FROM orders
GROUP BY date(order_date)
ORDER BY order_day;

-- Moving average (7-day window)
SELECT
    date(order_date) AS order_day,
    total_amount,
    AVG(total_amount) OVER (
        ORDER BY date(order_date)
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) AS moving_avg_7d
FROM orders
ORDER BY order_day;
