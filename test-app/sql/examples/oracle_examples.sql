-- ============================================================================
-- ORACLE DATABASE SQL EXAMPLES
-- ============================================================================
-- This file demonstrates Oracle-specific SQL patterns including:
-- - PL/SQL anonymous blocks and stored procedures with EXCEPTION handling
-- - Oracle MERGE statement (the original UPSERT)
-- - Hierarchical queries with CONNECT BY PRIOR and START WITH
-- - Oracle analytic functions (LISTAGG, FIRST_VALUE, LAST_VALUE, NTH_VALUE)
-- - PIVOT and UNPIVOT operations
-- - Flashback queries (AS OF TIMESTAMP, VERSIONS BETWEEN)
-- - Oracle sequences and IDENTITY columns (12c+)
-- - BULK COLLECT and FORALL for batch operations
-- - Oracle JSON support (JSON_TABLE, JSON_QUERY, JSON_VALUE, IS JSON)
-- - Pipelined table functions
-- - Model clause for spreadsheet-like calculations
-- - Edition-based redefinition patterns
-- - Result cache hints
-- - Global temporary tables vs private temporary tables (18c+)
-- - Row-level security with VPD (Virtual Private Database) policies
-- ============================================================================


-- ============================================================================
-- SECTION 1: PL/SQL ANONYMOUS BLOCKS AND STORED PROCEDURES
-- ============================================================================

-- Example 1.1: Anonymous block with EXCEPTION handling
-- Process a batch of customer updates with full error logging
DECLARE
    v_customer_id   customers.customer_id%TYPE;
    v_new_tier      VARCHAR2(20);
    v_total_spent   NUMBER(12, 2);
    v_rows_updated  PLS_INTEGER := 0;
    e_invalid_tier  EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_invalid_tier, -20001);
BEGIN
    -- Loop through customers needing tier recalculation
    FOR rec IN (
        SELECT customer_id, SUM(total_amount) AS total_spent
        FROM orders
        WHERE order_date >= ADD_MONTHS(SYSDATE, -12)
        GROUP BY customer_id
    ) LOOP
        v_customer_id := rec.customer_id;
        v_total_spent := rec.total_spent;

        -- Determine new tier based on spending
        v_new_tier := CASE
            WHEN v_total_spent >= 10000 THEN 'platinum'
            WHEN v_total_spent >= 5000  THEN 'gold'
            WHEN v_total_spent >= 1000  THEN 'silver'
            ELSE 'bronze'
        END;

        UPDATE customers
        SET tier = v_new_tier,
            tier_updated_at = SYSTIMESTAMP,
            annual_spend = v_total_spent
        WHERE customer_id = v_customer_id;

        v_rows_updated := v_rows_updated + SQL%ROWCOUNT;

        -- Commit every 500 rows to avoid long-running transactions
        IF MOD(v_rows_updated, 500) = 0 THEN
            COMMIT;
            DBMS_APPLICATION_INFO.SET_MODULE('tier_update', v_rows_updated || ' rows processed');
        END IF;
    END LOOP;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Tier update complete. Rows updated: ' || v_rows_updated);

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('No customer data found for tier recalculation.');
    WHEN DUP_VAL_ON_INDEX THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Duplicate value error for customer_id: ' || v_customer_id);
        RAISE;
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error Code: ' || SQLCODE);
        DBMS_OUTPUT.PUT_LINE('Error Message: ' || SQLERRM);
        DBMS_OUTPUT.PUT_LINE('Backtrace: ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        -- Log the error to an error table
        INSERT INTO error_log (error_code, error_message, error_backtrace, created_at)
        VALUES (SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, SYSTIMESTAMP);
        COMMIT;
        RAISE;
END;
/


-- Example 1.2: Stored procedure with autonomous transaction for error logging
-- This procedure processes orders and logs errors independently of the main txn
CREATE OR REPLACE PROCEDURE process_pending_orders (
    p_batch_size   IN  NUMBER DEFAULT 100,
    p_processed    OUT NUMBER,
    p_errors       OUT NUMBER
)
AUTHID CURRENT_USER
AS
    -- Autonomous transaction procedure for error logging
    -- Ensures log entries persist even if the main transaction rolls back
    PROCEDURE log_error (
        p_order_id     IN NUMBER,
        p_error_code   IN NUMBER,
        p_error_msg    IN VARCHAR2
    )
    IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO order_processing_log (
            order_id, error_code, error_message, processed_at
        ) VALUES (
            p_order_id, p_error_code, p_error_msg, SYSTIMESTAMP
        );
        COMMIT;
    END log_error;

    TYPE t_order_ids IS TABLE OF orders.order_id%TYPE;
    v_order_ids t_order_ids;
BEGIN
    p_processed := 0;
    p_errors := 0;

    -- Fetch pending orders
    SELECT order_id
    BULK COLLECT INTO v_order_ids
    FROM orders
    WHERE status = 'pending'
      AND order_date < SYSDATE - INTERVAL '1' HOUR
    ORDER BY order_date
    FETCH FIRST p_batch_size ROWS ONLY;  -- 12c+ row-limiting clause

    FOR i IN 1 .. v_order_ids.COUNT LOOP
        BEGIN
            -- Validate inventory
            UPDATE inventory inv
            SET inv.reserved_quantity = inv.reserved_quantity + (
                SELECT oi.quantity
                FROM order_items oi
                WHERE oi.order_id = v_order_ids(i)
                  AND oi.product_id = inv.product_id
            )
            WHERE inv.product_id IN (
                SELECT product_id FROM order_items WHERE order_id = v_order_ids(i)
            )
            AND inv.quantity - inv.reserved_quantity >= (
                SELECT oi.quantity
                FROM order_items oi
                WHERE oi.order_id = v_order_ids(i)
                  AND oi.product_id = inv.product_id
            );

            -- Mark order as processing
            UPDATE orders
            SET status = 'processing',
                updated_at = SYSTIMESTAMP
            WHERE order_id = v_order_ids(i);

            p_processed := p_processed + 1;

        EXCEPTION
            WHEN OTHERS THEN
                -- Log the error via autonomous transaction (survives rollback)
                log_error(v_order_ids(i), SQLCODE, SQLERRM);
                p_errors := p_errors + 1;
                -- Continue processing remaining orders
                CONTINUE;
        END;
    END LOOP;

    COMMIT;
END process_pending_orders;
/


-- Example 1.3: Package with initialization, overloaded procedures, and cursor variables
CREATE OR REPLACE PACKAGE customer_mgmt AS
    -- Public types
    TYPE t_customer_rec IS RECORD (
        customer_id   customers.customer_id%TYPE,
        full_name     VARCHAR2(200),
        tier          VARCHAR2(20),
        lifetime_value NUMBER(12,2)
    );
    TYPE t_customer_cur IS REF CURSOR RETURN t_customer_rec;

    -- Public constants
    c_max_tier_age_days CONSTANT PLS_INTEGER := 365;

    -- Overloaded: find customer by ID or by email
    FUNCTION get_customer (p_customer_id IN NUMBER) RETURN t_customer_rec;
    FUNCTION get_customer (p_email IN VARCHAR2) RETURN t_customer_rec;

    -- Open a ref cursor of customers by tier
    PROCEDURE get_customers_by_tier (
        p_tier    IN  VARCHAR2,
        p_cursor  OUT t_customer_cur
    );
END customer_mgmt;
/

CREATE OR REPLACE PACKAGE BODY customer_mgmt AS
    -- Private package variable initialized once per session
    g_default_tier VARCHAR2(20);

    FUNCTION get_customer (p_customer_id IN NUMBER) RETURN t_customer_rec IS
        v_rec t_customer_rec;
    BEGIN
        SELECT c.customer_id,
               c.first_name || ' ' || c.last_name,
               NVL(c.tier, g_default_tier),
               NVL(SUM(o.total_amount), 0)
        INTO v_rec
        FROM customers c
        LEFT JOIN orders o ON c.customer_id = o.customer_id
        WHERE c.customer_id = p_customer_id
        GROUP BY c.customer_id, c.first_name, c.last_name, c.tier;

        RETURN v_rec;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20100, 'Customer not found: ' || p_customer_id);
    END get_customer;

    FUNCTION get_customer (p_email IN VARCHAR2) RETURN t_customer_rec IS
        v_rec t_customer_rec;
    BEGIN
        SELECT c.customer_id,
               c.first_name || ' ' || c.last_name,
               NVL(c.tier, g_default_tier),
               NVL(SUM(o.total_amount), 0)
        INTO v_rec
        FROM customers c
        LEFT JOIN orders o ON c.customer_id = o.customer_id
        WHERE UPPER(c.email) = UPPER(p_email)
        GROUP BY c.customer_id, c.first_name, c.last_name, c.tier;

        RETURN v_rec;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20101, 'Customer not found for email: ' || p_email);
    END get_customer;

    PROCEDURE get_customers_by_tier (
        p_tier    IN  VARCHAR2,
        p_cursor  OUT t_customer_cur
    ) IS
    BEGIN
        OPEN p_cursor FOR
            SELECT c.customer_id,
                   c.first_name || ' ' || c.last_name AS full_name,
                   c.tier,
                   NVL(SUM(o.total_amount), 0) AS lifetime_value
            FROM customers c
            LEFT JOIN orders o ON c.customer_id = o.customer_id
            WHERE c.tier = p_tier
            GROUP BY c.customer_id, c.first_name, c.last_name, c.tier
            ORDER BY lifetime_value DESC;
    END get_customers_by_tier;

BEGIN
    -- Package initialization block: runs once per session
    g_default_tier := 'bronze';
END customer_mgmt;
/


-- ============================================================================
-- SECTION 2: ORACLE MERGE STATEMENT (THE ORIGINAL UPSERT)
-- ============================================================================

-- Example 2.1: Basic MERGE to synchronize customer summary table
-- Oracle's MERGE predates PostgreSQL's ON CONFLICT and is more powerful
MERGE INTO customer_summary cs
USING (
    SELECT
        o.customer_id,
        COUNT(*)            AS order_count,
        SUM(o.total_amount) AS total_spent,
        MAX(o.order_date)   AS last_order_date,
        MIN(o.order_date)   AS first_order_date
    FROM orders o
    WHERE o.order_date >= ADD_MONTHS(SYSDATE, -12)
    GROUP BY o.customer_id
) src
ON (cs.customer_id = src.customer_id)
WHEN MATCHED THEN
    UPDATE SET
        cs.order_count     = src.order_count,
        cs.total_spent     = src.total_spent,
        cs.last_order_date = src.last_order_date,
        cs.updated_at      = SYSTIMESTAMP
    -- DELETE rows where customer has very low activity (Oracle 10g+ feature)
    DELETE WHERE src.order_count < 2 AND src.total_spent < 10
WHEN NOT MATCHED THEN
    INSERT (customer_id, order_count, total_spent, first_order_date, last_order_date, updated_at)
    VALUES (src.customer_id, src.order_count, src.total_spent,
            src.first_order_date, src.last_order_date, SYSTIMESTAMP);


-- Example 2.2: MERGE with conditional insert/update and logging via LOG ERRORS
-- LOG ERRORS INTO captures DML errors without aborting the entire statement
MERGE INTO inventory inv
USING (
    SELECT product_id, warehouse_id, quantity_received, received_date
    FROM shipment_details
    WHERE shipment_id = 12345
) ship
ON (inv.product_id = ship.product_id AND inv.warehouse_id = ship.warehouse_id)
WHEN MATCHED THEN
    UPDATE SET
        inv.quantity    = inv.quantity + ship.quantity_received,
        inv.updated_at  = SYSTIMESTAMP
    WHERE inv.quantity + ship.quantity_received <= 999999  -- Capacity guard
WHEN NOT MATCHED THEN
    INSERT (product_id, warehouse_id, quantity, reorder_point, updated_at)
    VALUES (ship.product_id, ship.warehouse_id, ship.quantity_received, 10, SYSTIMESTAMP)
LOG ERRORS INTO err_inventory ('shipment_12345') REJECT LIMIT 100;


-- ============================================================================
-- SECTION 3: HIERARCHICAL QUERIES WITH CONNECT BY
-- ============================================================================

-- Example 3.1: Classic employee org chart using CONNECT BY
-- CONNECT BY is Oracle's original syntax for hierarchical queries (predates recursive CTEs)
SELECT
    LEVEL                                        AS depth,
    employee_id,
    LPAD(' ', 2 * (LEVEL - 1)) || last_name     AS indented_name,
    title,
    manager_id,
    SYS_CONNECT_BY_PATH(last_name, ' / ')        AS full_path,
    CONNECT_BY_ISLEAF                             AS is_leaf_node,
    CONNECT_BY_ROOT last_name                     AS top_manager
FROM employees
START WITH manager_id IS NULL          -- Root nodes (top-level managers)
CONNECT BY PRIOR employee_id = manager_id  -- Parent-child relationship
ORDER SIBLINGS BY last_name;           -- Preserve hierarchy, sort siblings


-- Example 3.2: Bill of Materials (BOM) explosion with cycle detection
-- Finds all components of a product, including sub-assemblies
SELECT
    LEVEL AS bom_level,
    LPAD(' ', 2 * (LEVEL - 1)) || component_name AS component_tree,
    parent_component_id,
    component_id,
    quantity_required,
    -- Calculate total quantity needed (multiply through levels)
    quantity_required * PRIOR quantity_required AS total_qty_needed,
    SYS_CONNECT_BY_PATH(component_name, ' -> ') AS assembly_path
FROM bill_of_materials
START WITH parent_component_id IS NULL
CONNECT BY NOCYCLE PRIOR component_id = parent_component_id
    -- NOCYCLE prevents infinite loops in case of circular references
ORDER SIBLINGS BY component_name;


-- Example 3.3: Generate a date series using CONNECT BY (no recursive CTE needed)
-- Oracle idiom for generating rows: CONNECT BY LEVEL
SELECT
    TRUNC(SYSDATE, 'MM') + LEVEL - 1 AS calendar_date,
    TO_CHAR(TRUNC(SYSDATE, 'MM') + LEVEL - 1, 'DY') AS day_name,
    CASE
        WHEN TO_CHAR(TRUNC(SYSDATE, 'MM') + LEVEL - 1, 'DY') IN ('SAT', 'SUN')
        THEN 'Weekend'
        ELSE 'Weekday'
    END AS day_type
FROM dual
CONNECT BY LEVEL <= EXTRACT(DAY FROM LAST_DAY(SYSDATE));


-- ============================================================================
-- SECTION 4: ORACLE ANALYTIC FUNCTIONS
-- ============================================================================

-- Example 4.1: LISTAGG for string aggregation
-- Concatenate all product names per category into a comma-separated list
SELECT
    category,
    LISTAGG(name, ', ') WITHIN GROUP (ORDER BY name) AS product_list,
    COUNT(*) AS product_count
FROM products
WHERE is_active = 1
GROUP BY category
ORDER BY category;

-- LISTAGG with DISTINCT (Oracle 19c+) to eliminate duplicates
SELECT
    c.customer_id,
    c.first_name || ' ' || c.last_name AS customer_name,
    LISTAGG(DISTINCT p.category, ', ') WITHIN GROUP (ORDER BY p.category) AS categories_purchased
FROM customers c
JOIN orders o ON c.customer_id = o.customer_id
JOIN order_items oi ON o.order_id = oi.order_id
JOIN products p ON oi.product_id = p.product_id
GROUP BY c.customer_id, c.first_name, c.last_name;

-- Handling LISTAGG overflow (Oracle 12c R2+)
-- ON OVERFLOW TRUNCATE prevents ORA-01489 when result exceeds 4000 chars
SELECT
    department_id,
    LISTAGG(employee_name, ', ' ON OVERFLOW TRUNCATE '...' WITH COUNT)
        WITHIN GROUP (ORDER BY employee_name) AS employee_list
FROM employees
GROUP BY department_id;


-- Example 4.2: FIRST_VALUE, LAST_VALUE, and NTH_VALUE
-- Get the first, last, and third-highest order amounts per customer
SELECT
    customer_id,
    order_id,
    order_date,
    total_amount,
    FIRST_VALUE(total_amount) OVER (
        PARTITION BY customer_id
        ORDER BY total_amount DESC
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS highest_order,
    LAST_VALUE(total_amount) OVER (
        PARTITION BY customer_id
        ORDER BY total_amount DESC
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS lowest_order,
    NTH_VALUE(total_amount, 3) OVER (
        PARTITION BY customer_id
        ORDER BY total_amount DESC
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS third_highest_order,
    total_amount - FIRST_VALUE(total_amount) OVER (
        PARTITION BY customer_id
        ORDER BY total_amount DESC
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS diff_from_highest
FROM orders
ORDER BY customer_id, total_amount DESC;


-- Example 4.3: RATIO_TO_REPORT and CUME_DIST (Oracle-specific analytics)
-- Calculate each product's share of category revenue and cumulative distribution
SELECT
    category,
    name AS product_name,
    total_revenue,
    -- Percentage of category total (Oracle-specific function)
    ROUND(RATIO_TO_REPORT(total_revenue) OVER (PARTITION BY category) * 100, 2) AS pct_of_category,
    -- Cumulative distribution (what percentile is this product at?)
    ROUND(CUME_DIST() OVER (PARTITION BY category ORDER BY total_revenue) * 100, 2) AS cumulative_pct,
    -- Percentile rank
    ROUND(PERCENT_RANK() OVER (PARTITION BY category ORDER BY total_revenue) * 100, 2) AS percentile_rank
FROM (
    SELECT
        p.category,
        p.name,
        SUM(oi.quantity * oi.unit_price) AS total_revenue
    FROM products p
    JOIN order_items oi ON p.product_id = oi.product_id
    GROUP BY p.category, p.name
) product_rev
ORDER BY category, total_revenue DESC;


-- ============================================================================
-- SECTION 5: PIVOT AND UNPIVOT OPERATIONS
-- ============================================================================

-- Example 5.1: PIVOT - Convert rows to columns
-- Monthly sales pivoted into columns (Oracle 11g+)
SELECT *
FROM (
    SELECT
        p.category,
        TO_CHAR(o.order_date, 'MON') AS order_month,
        oi.quantity * oi.unit_price   AS revenue
    FROM products p
    JOIN order_items oi ON p.product_id = oi.product_id
    JOIN orders o ON oi.order_id = o.order_id
    WHERE o.order_date >= TRUNC(SYSDATE, 'YYYY')
)
PIVOT (
    SUM(revenue)
    FOR order_month IN (
        'JAN' AS jan, 'FEB' AS feb, 'MAR' AS mar,
        'APR' AS apr, 'MAY' AS may, 'JUN' AS jun,
        'JUL' AS jul, 'AUG' AS aug, 'SEP' AS sep,
        'OCT' AS oct, 'NOV' AS nov, 'DEC' AS dec
    )
)
ORDER BY category;


-- Example 5.2: UNPIVOT - Convert columns to rows
-- Useful for normalizing denormalized tables or for reporting
SELECT *
FROM (
    SELECT
        product_id,
        product_name,
        q1_revenue,
        q2_revenue,
        q3_revenue,
        q4_revenue
    FROM quarterly_sales
)
UNPIVOT (
    revenue FOR quarter IN (
        q1_revenue AS 'Q1',
        q2_revenue AS 'Q2',
        q3_revenue AS 'Q3',
        q4_revenue AS 'Q4'
    )
)
ORDER BY product_name, quarter;


-- Example 5.3: PIVOT with multiple aggregations
SELECT *
FROM (
    SELECT
        department_id,
        job_title,
        salary,
        commission_pct
    FROM employees
)
PIVOT (
    AVG(salary)         AS avg_sal,
    COUNT(*)            AS headcount,
    MAX(commission_pct) AS max_comm
    FOR job_title IN (
        'Manager'  AS mgr,
        'Engineer' AS eng,
        'Analyst'  AS anl
    )
)
ORDER BY department_id;


-- ============================================================================
-- SECTION 6: FLASHBACK QUERIES
-- ============================================================================

-- Example 6.1: AS OF TIMESTAMP - Query data as it existed at a point in time
-- Useful for investigating data changes or recovering accidentally modified data
-- Requires UNDO tablespace with sufficient retention
SELECT customer_id, first_name, last_name, email, tier
FROM customers AS OF TIMESTAMP (SYSTIMESTAMP - INTERVAL '1' HOUR)
WHERE customer_id = 42;

-- Compare current data to what it was 30 minutes ago
SELECT
    curr.customer_id,
    curr.tier         AS current_tier,
    hist.tier         AS previous_tier,
    curr.email        AS current_email,
    hist.email        AS previous_email
FROM customers curr
JOIN customers AS OF TIMESTAMP (SYSTIMESTAMP - INTERVAL '30' MINUTE) hist
    ON curr.customer_id = hist.customer_id
WHERE curr.tier != hist.tier;


-- Example 6.2: VERSIONS BETWEEN - See all changes to a row over a time range
-- Each row represents a version of the data that existed during the period
SELECT
    customer_id,
    first_name,
    last_name,
    tier,
    VERSIONS_STARTSCN,
    VERSIONS_ENDSCN,
    VERSIONS_STARTTIME,
    VERSIONS_ENDTIME,
    VERSIONS_XID,          -- Transaction ID that made this change
    VERSIONS_OPERATION     -- I=Insert, U=Update, D=Delete
FROM customers
VERSIONS BETWEEN TIMESTAMP
    (SYSTIMESTAMP - INTERVAL '24' HOUR) AND SYSTIMESTAMP
WHERE customer_id = 42
ORDER BY VERSIONS_STARTTIME;


-- Example 6.3: Flashback query on a specific SCN (System Change Number)
-- Useful when you know the exact SCN from a log or audit record
SELECT order_id, status, total_amount
FROM orders AS OF SCN 123456789
WHERE order_id = 9001;

-- Recover deleted rows using flashback
INSERT INTO customers
SELECT *
FROM customers AS OF TIMESTAMP (SYSTIMESTAMP - INTERVAL '2' HOUR)
WHERE customer_id NOT IN (SELECT customer_id FROM customers);


-- ============================================================================
-- SECTION 7: SEQUENCES AND IDENTITY COLUMNS
-- ============================================================================

-- Example 7.1: Traditional Oracle sequence (all versions)
CREATE SEQUENCE order_seq
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 1000
    MAXVALUE 9999999999
    NOCYCLE
    CACHE 50         -- Pre-allocate 50 values for performance
    ORDER;           -- Guarantee ordering (important for RAC environments)

-- Use in INSERT
INSERT INTO orders (order_id, customer_id, order_date, status)
VALUES (order_seq.NEXTVAL, 42, SYSDATE, 'pending');

-- Check current value (does NOT increment)
SELECT order_seq.CURRVAL FROM dual;


-- Example 7.2: IDENTITY columns (Oracle 12c+)
-- Simpler syntax, no separate sequence object needed
CREATE TABLE audit_events (
    -- GENERATED ALWAYS: Oracle manages the value, you cannot override it
    event_id       NUMBER GENERATED ALWAYS AS IDENTITY (
                       START WITH 1 INCREMENT BY 1 CACHE 100
                   ) NOT NULL,
    event_type     VARCHAR2(50)  NOT NULL,
    event_data     CLOB,
    created_at     TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_audit_events PRIMARY KEY (event_id)
);

-- GENERATED BY DEFAULT: Oracle generates if you don't provide a value
-- ON NULL: also generates if you explicitly insert NULL (12c+)
CREATE TABLE support_tickets (
    ticket_id      NUMBER GENERATED BY DEFAULT ON NULL AS IDENTITY
                       CONSTRAINT pk_support_tickets PRIMARY KEY,
    customer_id    NUMBER        NOT NULL,
    subject        VARCHAR2(200) NOT NULL,
    priority       NUMBER(1)     DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
    status         VARCHAR2(20)  DEFAULT 'open',
    created_at     TIMESTAMP     DEFAULT SYSTIMESTAMP
);

-- Insert without specifying identity column
INSERT INTO support_tickets (customer_id, subject, priority)
VALUES (42, 'Login issue after password reset', 1);

-- Insert with NULL explicitly (ON NULL causes identity generation)
INSERT INTO support_tickets (ticket_id, customer_id, subject)
VALUES (NULL, 43, 'Billing inquiry');


-- ============================================================================
-- SECTION 8: BULK COLLECT AND FORALL
-- ============================================================================

-- Example 8.1: BULK COLLECT for efficient data retrieval
-- Retrieves all matching rows into a PL/SQL collection in a single context switch
DECLARE
    TYPE t_order_tab IS TABLE OF orders%ROWTYPE;
    v_orders       t_order_tab;
    v_total_amount NUMBER := 0;
BEGIN
    -- BULK COLLECT fetches all rows at once (much faster than row-by-row)
    SELECT *
    BULK COLLECT INTO v_orders
    FROM orders
    WHERE status = 'pending'
      AND order_date >= TRUNC(SYSDATE) - 7;

    DBMS_OUTPUT.PUT_LINE('Fetched ' || v_orders.COUNT || ' pending orders.');

    -- Process in PL/SQL (no additional SQL context switches)
    FOR i IN 1 .. v_orders.COUNT LOOP
        v_total_amount := v_total_amount + v_orders(i).total_amount;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('Total pending amount: ' || TO_CHAR(v_total_amount, 'FM$999,999,990.00'));
END;
/


-- Example 8.2: BULK COLLECT with LIMIT for large datasets
-- Prevents excessive memory use by processing in chunks
DECLARE
    TYPE t_customer_ids IS TABLE OF customers.customer_id%TYPE;
    TYPE t_emails       IS TABLE OF customers.email%TYPE;
    v_ids      t_customer_ids;
    v_emails   t_emails;
    v_batch    PLS_INTEGER := 0;

    CURSOR c_inactive IS
        SELECT customer_id, email
        FROM customers
        WHERE last_login_date < ADD_MONTHS(SYSDATE, -6)
          AND is_active = 1
        ORDER BY customer_id;
BEGIN
    OPEN c_inactive;
    LOOP
        -- Fetch 1000 rows at a time
        FETCH c_inactive BULK COLLECT INTO v_ids, v_emails LIMIT 1000;
        EXIT WHEN v_ids.COUNT = 0;

        v_batch := v_batch + 1;
        DBMS_OUTPUT.PUT_LINE('Processing batch ' || v_batch || ': ' || v_ids.COUNT || ' rows');

        -- FORALL sends all DML to SQL engine in a single context switch
        -- Much faster than looping with individual UPDATE statements
        FORALL i IN 1 .. v_ids.COUNT
            UPDATE customers
            SET is_active = 0,
                deactivated_at = SYSTIMESTAMP,
                deactivation_reason = 'Inactive for 6+ months'
            WHERE customer_id = v_ids(i);

        COMMIT;
    END LOOP;
    CLOSE c_inactive;
END;
/


-- Example 8.3: FORALL with SAVE EXCEPTIONS for fault-tolerant batch DML
-- Continues processing even if individual rows fail
DECLARE
    TYPE t_product_ids IS TABLE OF products.product_id%TYPE;
    TYPE t_prices      IS TABLE OF products.base_price%TYPE;
    v_ids    t_product_ids;
    v_prices t_prices;
    v_errors PLS_INTEGER;
    e_bulk_errors EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_bulk_errors, -24381);
BEGIN
    -- Fetch products and their new prices from a staging table
    SELECT product_id, new_price
    BULK COLLECT INTO v_ids, v_prices
    FROM price_update_staging
    WHERE effective_date = TRUNC(SYSDATE);

    -- SAVE EXCEPTIONS: continue processing even if individual rows fail
    -- Without it, the first error aborts the entire FORALL
    FORALL i IN 1 .. v_ids.COUNT SAVE EXCEPTIONS
        UPDATE products
        SET base_price = v_prices(i),
            updated_at = SYSTIMESTAMP
        WHERE product_id = v_ids(i);

    COMMIT;

EXCEPTION
    WHEN e_bulk_errors THEN
        -- SQL%BULK_EXCEPTIONS contains details of each failure
        v_errors := SQL%BULK_EXCEPTIONS.COUNT;
        DBMS_OUTPUT.PUT_LINE('Total errors: ' || v_errors);

        FOR i IN 1 .. v_errors LOOP
            DBMS_OUTPUT.PUT_LINE(
                'Error ' || i ||
                ' at index ' || SQL%BULK_EXCEPTIONS(i).ERROR_INDEX ||
                ': ORA-' || LPAD(SQL%BULK_EXCEPTIONS(i).ERROR_CODE, 5, '0')
            );
        END LOOP;

        -- Commit the rows that succeeded
        COMMIT;
END;
/


-- ============================================================================
-- SECTION 9: ORACLE JSON SUPPORT
-- ============================================================================

-- Example 9.1: Table with JSON column and IS JSON constraint
-- Oracle 12c+ supports JSON natively in VARCHAR2, CLOB, or BLOB columns
CREATE TABLE api_events (
    event_id       NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_type     VARCHAR2(100)  NOT NULL,
    payload        CLOB           NOT NULL
        CONSTRAINT ck_payload_json CHECK (payload IS JSON),
    -- IS JSON STRICT rejects duplicate keys; IS JSON validates structure
    headers        VARCHAR2(4000)
        CONSTRAINT ck_headers_json CHECK (headers IS JSON),
    created_at     TIMESTAMP DEFAULT SYSTIMESTAMP
);

-- Oracle 21c+ supports native JSON data type
-- CREATE TABLE api_events_21c (
--     event_id   NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
--     payload    JSON NOT NULL,  -- Native JSON type, stored in binary OSON format
--     created_at TIMESTAMP DEFAULT SYSTIMESTAMP
-- );


-- Example 9.2: JSON_VALUE - Extract scalar values from JSON
-- Useful for filtering, indexing, and projecting JSON fields into SQL columns
SELECT
    event_id,
    event_type,
    JSON_VALUE(payload, '$.user_id' RETURNING NUMBER)          AS user_id,
    JSON_VALUE(payload, '$.action')                             AS action,
    JSON_VALUE(payload, '$.metadata.ip_address')                AS ip_address,
    JSON_VALUE(payload, '$.metadata.user_agent'
               DEFAULT 'unknown' ON ERROR)                      AS user_agent,
    JSON_VALUE(payload, '$.timestamp'
               RETURNING TIMESTAMP WITH TIME ZONE)              AS event_timestamp
FROM api_events
WHERE event_type = 'user_action'
  AND JSON_VALUE(payload, '$.user_id' RETURNING NUMBER) = 42;

-- Create a functional index on a JSON field for fast lookups
CREATE INDEX idx_events_user_id ON api_events (
    JSON_VALUE(payload, '$.user_id' RETURNING NUMBER ERROR ON ERROR)
);


-- Example 9.3: JSON_TABLE - Decompose JSON arrays into relational rows
-- The most powerful Oracle JSON function: turns nested JSON into a table
SELECT
    e.event_id,
    e.event_type,
    jt.item_id,
    jt.product_name,
    jt.quantity,
    jt.unit_price,
    jt.quantity * jt.unit_price AS line_total
FROM api_events e,
    JSON_TABLE(e.payload, '$.items[*]'
        COLUMNS (
            item_id      NUMBER       PATH '$.id',
            product_name VARCHAR2(100) PATH '$.name',
            quantity      NUMBER       PATH '$.qty',
            unit_price    NUMBER(10,2) PATH '$.price',
            -- NESTED PATH for sub-arrays within each item
            NESTED PATH '$.tags[*]' COLUMNS (
                tag VARCHAR2(50) PATH '$'
            )
        )
    ) jt
WHERE e.event_type = 'order_placed'
  AND jt.quantity > 0;


-- Example 9.4: JSON_QUERY - Extract JSON objects or arrays (non-scalar)
SELECT
    event_id,
    JSON_QUERY(payload, '$.metadata')                      AS metadata_obj,
    JSON_QUERY(payload, '$.items' WITH WRAPPER)             AS items_array,
    JSON_QUERY(payload, '$.items[0]')                       AS first_item,
    JSON_QUERY(payload, '$.items[*].name' WITH WRAPPER)     AS all_item_names
FROM api_events
WHERE JSON_EXISTS(payload, '$.items[*]?(@.price > 100)');  -- Filter: any item > $100


-- Example 9.5: Building JSON from relational data
SELECT JSON_OBJECT(
    'customer_id' VALUE c.customer_id,
    'name'        VALUE c.first_name || ' ' || c.last_name,
    'email'       VALUE c.email,
    'orders'      VALUE (
        SELECT JSON_ARRAYAGG(
            JSON_OBJECT(
                'order_id'   VALUE o.order_id,
                'date'       VALUE TO_CHAR(o.order_date, 'YYYY-MM-DD'),
                'total'      VALUE o.total_amount,
                'status'     VALUE o.status
            )
            ORDER BY o.order_date DESC
            RETURNING CLOB
        )
        FROM orders o
        WHERE o.customer_id = c.customer_id
    )
    RETURNING CLOB
) AS customer_json
FROM customers c
WHERE c.customer_id = 42;


-- ============================================================================
-- SECTION 10: PIPELINED TABLE FUNCTIONS
-- ============================================================================

-- Example 10.1: Pipelined function for streaming row generation
-- Returns rows one at a time without materializing the entire result set in memory
-- Useful for ETL, data generation, and transforming external data sources

-- Step 1: Define the row type
CREATE OR REPLACE TYPE t_date_range_row AS OBJECT (
    calendar_date   DATE,
    day_name        VARCHAR2(10),
    is_weekend      NUMBER(1),
    is_holiday      NUMBER(1),
    fiscal_quarter  VARCHAR2(5)
);
/

CREATE OR REPLACE TYPE t_date_range_tab IS TABLE OF t_date_range_row;
/

-- Step 2: Create the pipelined function
CREATE OR REPLACE FUNCTION generate_date_range (
    p_start_date IN DATE,
    p_end_date   IN DATE
)
RETURN t_date_range_tab PIPELINED
DETERMINISTIC
PARALLEL_ENABLE
AS
    v_date DATE := p_start_date;
    v_day  VARCHAR2(10);
BEGIN
    WHILE v_date <= p_end_date LOOP
        v_day := TO_CHAR(v_date, 'DY');

        -- PIPE ROW sends one row to the caller immediately
        -- The function does not need to finish before the caller starts receiving rows
        PIPE ROW (t_date_range_row(
            v_date,
            v_day,
            CASE WHEN v_day IN ('SAT', 'SUN') THEN 1 ELSE 0 END,
            0,  -- Holiday detection would go here
            'Q' || TO_CHAR(v_date, 'Q')
        ));

        v_date := v_date + 1;
    END LOOP;

    RETURN;  -- Must have RETURN with no value for pipelined functions
END generate_date_range;
/

-- Step 3: Use it like a table with the TABLE() operator
SELECT d.calendar_date, d.day_name, d.fiscal_quarter
FROM TABLE(generate_date_range(DATE '2024-01-01', DATE '2024-12-31')) d
WHERE d.is_weekend = 0
  AND d.is_holiday = 0;


-- Example 10.2: Pipelined function for splitting delimited strings
CREATE OR REPLACE TYPE t_varchar_row AS OBJECT (item VARCHAR2(4000));
/
CREATE OR REPLACE TYPE t_varchar_tab IS TABLE OF t_varchar_row;
/

CREATE OR REPLACE FUNCTION split_string (
    p_string    IN VARCHAR2,
    p_delimiter IN VARCHAR2 DEFAULT ','
)
RETURN t_varchar_tab PIPELINED
DETERMINISTIC
AS
    v_start PLS_INTEGER := 1;
    v_pos   PLS_INTEGER;
BEGIN
    LOOP
        v_pos := INSTR(p_string, p_delimiter, v_start);
        IF v_pos = 0 THEN
            PIPE ROW (t_varchar_row(TRIM(SUBSTR(p_string, v_start))));
            EXIT;
        END IF;
        PIPE ROW (t_varchar_row(TRIM(SUBSTR(p_string, v_start, v_pos - v_start))));
        v_start := v_pos + LENGTH(p_delimiter);
    END LOOP;
    RETURN;
END split_string;
/

-- Usage: parse a comma-separated list into rows
SELECT item
FROM TABLE(split_string('apple,banana,cherry,date'));


-- ============================================================================
-- SECTION 11: MODEL CLAUSE
-- ============================================================================

-- Example 11.1: Spreadsheet-like calculations using the MODEL clause
-- Oracle's MODEL clause allows cell-referencing like Excel formulas
-- Project revenue for each product 3 months into the future using growth rate
SELECT
    product_id,
    month_num,
    revenue,
    ROUND(growth_rate, 4)   AS growth_rate,
    projected_flag
FROM (
    SELECT
        p.product_id,
        EXTRACT(MONTH FROM o.order_date) AS month_num,
        SUM(oi.quantity * oi.unit_price)  AS revenue
    FROM products p
    JOIN order_items oi ON p.product_id = oi.product_id
    JOIN orders o ON oi.order_id = o.order_id
    WHERE o.order_date >= TRUNC(SYSDATE, 'YYYY')
    GROUP BY p.product_id, EXTRACT(MONTH FROM o.order_date)
)
MODEL
    -- PARTITION BY: separate calculation for each product
    PARTITION BY (product_id)
    -- DIMENSION BY: the axis (like row numbers in a spreadsheet)
    DIMENSION BY (month_num)
    -- MEASURES: the values we compute
    MEASURES (revenue, 0 AS growth_rate, 0 AS projected_flag)
    -- RULES: the formulas (like Excel cell formulas)
    RULES (
        -- Calculate month-over-month growth rate
        growth_rate[ANY] = CASE
            WHEN revenue[CV() - 1] IS NOT NULL AND revenue[CV() - 1] != 0
            THEN (revenue[CV()] - revenue[CV() - 1]) / revenue[CV() - 1]
            ELSE 0
        END,
        -- Project revenue for months 10, 11, 12 using average growth rate
        revenue[FOR month_num FROM 10 TO 12 INCREMENT 1] =
            revenue[CV() - 1] * (1 + AVG(growth_rate)[month_num BETWEEN 2 AND 9]),
        -- Flag projected rows
        projected_flag[FOR month_num FROM 10 TO 12 INCREMENT 1] = 1
    )
ORDER BY product_id, month_num;


-- Example 11.2: Running totals and YTD calculations with MODEL
SELECT
    region,
    month_num,
    monthly_sales,
    ytd_sales,
    pct_of_annual_target
FROM sales_data
MODEL
    PARTITION BY (region)
    DIMENSION BY (month_num)
    MEASURES (
        monthly_sales,
        0 AS ytd_sales,
        0 AS pct_of_annual_target,
        annual_target
    )
    RULES (
        -- Year-to-date running sum: SUM from month 1 to current month
        ytd_sales[ANY] = SUM(monthly_sales)[month_num BETWEEN 1 AND CV()],
        -- Percentage of annual target achieved
        pct_of_annual_target[ANY] =
            ROUND(ytd_sales[CV()] / NULLIF(annual_target[CV()], 0) * 100, 2)
    )
ORDER BY region, month_num;


-- ============================================================================
-- SECTION 12: EDITION-BASED REDEFINITION PATTERNS
-- ============================================================================

-- Example 12.1: Edition-based redefinition (EBR) for zero-downtime code deployment
-- EBR allows multiple versions of PL/SQL code to coexist simultaneously
-- Active sessions use the old edition while new sessions use the new edition

-- Step 1: Create a new edition (DBA privilege required)
-- CREATE EDITION v2_release;

-- Step 2: Set the session to the new edition
-- ALTER SESSION SET EDITION = v2_release;

-- Step 3: Create an editioning view (one-time setup per table)
-- Editioning views decouple application code from table column names
CREATE OR REPLACE EDITIONING VIEW customers_ev AS
SELECT
    customer_id,
    first_name,
    last_name,
    email,
    tier,
    -- In the new edition, we rename/reshape columns via the view
    first_name || ' ' || last_name AS full_name
FROM customers;

-- Step 4: Modify PL/SQL in the new edition (does not affect old edition)
-- CREATE OR REPLACE FUNCTION get_customer_display_name (p_id NUMBER)
-- RETURN VARCHAR2
-- AS
--     v_name VARCHAR2(200);
-- BEGIN
--     SELECT full_name INTO v_name FROM customers_ev WHERE customer_id = p_id;
--     RETURN v_name;
-- END;

-- Step 5: Crossedition triggers synchronize data between editions
-- This forward crossedition trigger populates the new column from old columns
-- CREATE OR REPLACE TRIGGER customers_fwd_xed
--     BEFORE INSERT OR UPDATE ON customers
--     FOR EACH ROW
--     FORWARD CROSSEDITION
-- BEGIN
--     :NEW.full_name := :NEW.first_name || ' ' || :NEW.last_name;
-- END;


-- ============================================================================
-- SECTION 13: RESULT CACHE HINTS
-- ============================================================================

-- Example 13.1: Query result cache
-- Oracle caches the result set in the shared pool; subsequent identical queries
-- return instantly without re-executing. Cache is auto-invalidated on DML.
SELECT /*+ RESULT_CACHE */
    category,
    COUNT(*)              AS product_count,
    AVG(base_price)       AS avg_price,
    SUM(stock_quantity)   AS total_stock
FROM products
WHERE is_active = 1
GROUP BY category
ORDER BY category;


-- Example 13.2: PL/SQL function result cache
-- Cached per unique input parameter combination
-- Automatically invalidated when the referenced table changes
CREATE OR REPLACE FUNCTION get_product_category_stats (
    p_category IN VARCHAR2
)
RETURN VARCHAR2
RESULT_CACHE RELIES_ON (products, order_items)
AS
    v_result VARCHAR2(4000);
BEGIN
    SELECT JSON_OBJECT(
        'category'      VALUE p_category,
        'product_count' VALUE COUNT(DISTINCT p.product_id),
        'avg_price'     VALUE ROUND(AVG(p.base_price), 2),
        'total_sold'    VALUE NVL(SUM(oi.quantity), 0)
    )
    INTO v_result
    FROM products p
    LEFT JOIN order_items oi ON p.product_id = oi.product_id
    WHERE p.category = p_category
      AND p.is_active = 1;

    RETURN v_result;
END get_product_category_stats;
/


-- ============================================================================
-- SECTION 14: GLOBAL TEMPORARY TABLES VS PRIVATE TEMPORARY TABLES
-- ============================================================================

-- Example 14.1: Global Temporary Table (GTT) - all Oracle versions
-- Data is session-private but the table definition is visible to all sessions
-- ON COMMIT DELETE ROWS: data visible only within the transaction (default)
-- ON COMMIT PRESERVE ROWS: data visible for the entire session
CREATE GLOBAL TEMPORARY TABLE gtt_order_staging (
    order_id        NUMBER,
    customer_id     NUMBER        NOT NULL,
    product_id      NUMBER        NOT NULL,
    quantity        NUMBER(10)    NOT NULL,
    unit_price      NUMBER(10,2)  NOT NULL,
    staging_status  VARCHAR2(20)  DEFAULT 'pending',
    created_at      TIMESTAMP     DEFAULT SYSTIMESTAMP,
    CONSTRAINT pk_gtt_order_staging PRIMARY KEY (order_id)
)
ON COMMIT PRESERVE ROWS;

-- GTTs do not generate redo log (minimal I/O), making them fast for temp data
-- Statistics should be gathered per-session for GTTs
-- DBMS_STATS.SET_TABLE_PREFS('MYSCHEMA', 'GTT_ORDER_STAGING', 'GLOBAL_TEMP_TABLE_STATS', 'SESSION');

-- Usage: load temp data, process it, results persist until session ends
INSERT INTO gtt_order_staging (order_id, customer_id, product_id, quantity, unit_price)
SELECT order_seq.NEXTVAL, customer_id, product_id, quantity, unit_price
FROM order_import_file
WHERE validation_status = 'valid';


-- Example 14.2: Private Temporary Table (Oracle 18c+)
-- Both definition and data are session-private; no DDL locks, no catalog entries
-- Name must start with ORA$PTT_ prefix
CREATE PRIVATE TEMPORARY TABLE ORA$PTT_calc_results (
    customer_id     NUMBER,
    calculated_tier VARCHAR2(20),
    score           NUMBER(10, 4),
    computed_at     TIMESTAMP DEFAULT SYSTIMESTAMP
)
ON COMMIT PRESERVE DEFINITION;
-- ON COMMIT PRESERVE DEFINITION: table survives COMMIT (dropped at session end)
-- ON COMMIT DROP DEFINITION: table dropped on COMMIT (default)

-- PTTs are ideal for complex multi-step calculations within a procedure
INSERT INTO ORA$PTT_calc_results (customer_id, calculated_tier, score)
SELECT
    c.customer_id,
    CASE
        WHEN score >= 90 THEN 'platinum'
        WHEN score >= 70 THEN 'gold'
        WHEN score >= 40 THEN 'silver'
        ELSE 'bronze'
    END,
    score
FROM (
    SELECT
        c.customer_id,
        NVL(SUM(o.total_amount), 0) * 0.4 +
        NVL(COUNT(o.order_id), 0) * 2 +
        MONTHS_BETWEEN(SYSDATE, MIN(o.order_date)) * 0.5 AS score
    FROM customers c
    LEFT JOIN orders o ON c.customer_id = o.customer_id
    GROUP BY c.customer_id
) c;


-- ============================================================================
-- SECTION 15: ROW-LEVEL SECURITY WITH VPD (VIRTUAL PRIVATE DATABASE)
-- ============================================================================

-- Example 15.1: VPD policy function
-- VPD automatically appends a WHERE clause to every query/DML on a table
-- This enforces row-level security transparently to the application

-- Step 1: Create the policy function
-- This function returns a predicate string that Oracle appends to queries
CREATE OR REPLACE FUNCTION vpd_orders_policy (
    p_schema  IN VARCHAR2,
    p_object  IN VARCHAR2
)
RETURN VARCHAR2
DETERMINISTIC
AS
    v_predicate VARCHAR2(4000);
    v_user      VARCHAR2(128) := SYS_CONTEXT('USERENV', 'SESSION_USER');
    v_role      VARCHAR2(50);
BEGIN
    -- Admins see all data
    IF v_user = 'ADMIN_USER' THEN
        RETURN NULL;  -- NULL means no restriction (see all rows)
    END IF;

    -- Get the user's role from a custom application context or table
    SELECT role_name INTO v_role
    FROM app_users
    WHERE username = v_user;

    -- Regional managers see orders for their region only
    IF v_role = 'REGIONAL_MANAGER' THEN
        v_predicate := 'region_id IN (SELECT region_id FROM user_regions WHERE username = SYS_CONTEXT(''USERENV'', ''SESSION_USER''))';
    -- Sales reps see only their own orders
    ELSIF v_role = 'SALES_REP' THEN
        v_predicate := 'sales_rep_id = (SELECT employee_id FROM employees WHERE UPPER(email) = UPPER(SYS_CONTEXT(''USERENV'', ''SESSION_USER'')))';
    -- Default: see nothing
    ELSE
        v_predicate := '1=0';
    END IF;

    RETURN v_predicate;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN '1=0';  -- No matching user: deny all access
END vpd_orders_policy;
/

-- Step 2: Attach the policy to the table
-- STATEMENT_TYPES controls which operations the policy applies to
BEGIN
    DBMS_RLS.ADD_POLICY(
        object_schema   => 'APP_SCHEMA',
        object_name     => 'ORDERS',
        policy_name     => 'ORDERS_ROW_SECURITY',
        function_schema => 'SECURITY_SCHEMA',
        policy_function => 'VPD_ORDERS_POLICY',
        statement_types => 'SELECT, INSERT, UPDATE, DELETE',
        update_check    => TRUE,   -- Prevent UPDATE from making rows invisible
        enable          => TRUE
    );
END;
/

-- Step 3: Verify - When a sales rep queries orders, VPD silently adds
-- the WHERE clause so they only see their own rows
-- SELECT * FROM orders;
-- Oracle internally rewrites this to:
-- SELECT * FROM orders WHERE sales_rep_id = (SELECT employee_id ...)


-- Example 15.2: Application context for VPD
-- Custom contexts allow you to store session-level attributes used by VPD

-- Create a context namespace
CREATE OR REPLACE CONTEXT app_ctx USING set_app_context;

-- Create the trusted procedure that sets context values
CREATE OR REPLACE PROCEDURE set_app_context (
    p_user_id   IN NUMBER,
    p_region_id IN NUMBER,
    p_role      IN VARCHAR2
)
AS
BEGIN
    DBMS_SESSION.SET_CONTEXT('APP_CTX', 'USER_ID',   TO_CHAR(p_user_id));
    DBMS_SESSION.SET_CONTEXT('APP_CTX', 'REGION_ID', TO_CHAR(p_region_id));
    DBMS_SESSION.SET_CONTEXT('APP_CTX', 'ROLE',      p_role);
END set_app_context;
/

-- Application calls this on login; VPD policies then reference the context:
-- SYS_CONTEXT('APP_CTX', 'USER_ID')
-- SYS_CONTEXT('APP_CTX', 'REGION_ID')
-- SYS_CONTEXT('APP_CTX', 'ROLE')
