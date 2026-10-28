-- ============================================================================
-- BAD_PROCEDURES_POSTGRESQL.SQL
-- This file contains PostgreSQL functions/procedures with INTENTIONAL violations
-- Use this to test if the skill can identify and fix these issues
-- Target: PostgreSQL 13+
-- ============================================================================

-- Violations Summary:
-- CRITICAL: SELECT * usage (SA0001)
-- CRITICAL: SQL injection via EXECUTE without USING (SA0002)
-- HIGH: Non-SARGable WHERE EXTRACT(YEAR FROM ...) (SA0003)
-- HIGH: Leading wildcard LIKE/ILIKE '%value' (SA0004)
-- HIGH: COUNT(*) > 0 instead of EXISTS (SA0005)
-- HIGH: INSERT without column list (SA0006)
-- HIGH: Cursor loop instead of set-based UPDATE (SA0007)
-- MEDIUM: Unqualified table names - no schema prefix (SA0008)
-- MEDIUM: SERIAL instead of GENERATED AS IDENTITY (SA-PG001)
-- MEDIUM: VARCHAR(255) everywhere instead of TEXT (SA-PG002)
-- HIGH: SECURITY DEFINER without search_path (SA-PG004)
-- MEDIUM: Missing EXCEPTION handling
-- MEDIUM: Transaction misuse (COMMIT inside function)

-- ============================================================================
-- TABLE SETUP (for context - these tables have violations too)
-- Violation: SA-PG001 (SERIAL), SA-PG002 (VARCHAR(255))
-- ============================================================================

CREATE TABLE orders (
    order_id SERIAL PRIMARY KEY,                    -- SA-PG001: Use GENERATED AS IDENTITY
    customer_id INTEGER NOT NULL,
    order_date TIMESTAMP NOT NULL DEFAULT now(),
    status VARCHAR(255),                             -- SA-PG002: Use TEXT or appropriately sized VARCHAR
    total_amount NUMERIC(10,2),
    shipping_cost NUMERIC(10,2),
    notes VARCHAR(255),                              -- SA-PG002: Use TEXT
    last_modified TIMESTAMP
);

CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,                  -- SA-PG001: Use GENERATED AS IDENTITY
    customer_name VARCHAR(255) NOT NULL,              -- SA-PG002: Use TEXT
    email VARCHAR(255),                               -- SA-PG002: Use TEXT
    phone VARCHAR(255),                               -- SA-PG002: Use TEXT
    is_active BOOLEAN DEFAULT TRUE
);

CREATE TABLE order_history (
    history_id SERIAL PRIMARY KEY,                   -- SA-PG001: Use GENERATED AS IDENTITY
    order_id INTEGER NOT NULL,
    old_status VARCHAR(255),                          -- SA-PG002: Use TEXT
    new_status VARCHAR(255),                          -- SA-PG002: Use TEXT
    changed_date TIMESTAMP DEFAULT now()
);

CREATE TABLE products (
    product_id SERIAL PRIMARY KEY,                   -- SA-PG001: Use GENERATED AS IDENTITY
    product_name VARCHAR(255) NOT NULL,               -- SA-PG002: Use TEXT
    price NUMERIC(10,2),
    category_id INTEGER
);

-- ============================================================================
-- FUNCTION 1: get_customer_orders
-- Violations: SA0001 (SELECT *), SA0008 (no schema qualifier)
-- ============================================================================
CREATE OR REPLACE FUNCTION get_customer_orders(p_customer_id INTEGER)
RETURNS SETOF RECORD AS $$
BEGIN
    -- SA0001: Using SELECT * instead of explicit columns
    -- SA0008: No schema qualifier on table name
    RETURN QUERY SELECT * FROM orders WHERE customer_id = p_customer_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 2: search_products (SQL INJECTION)
-- Violations: SA0002 (SQL injection via EXECUTE without USING)
-- ============================================================================
CREATE OR REPLACE FUNCTION search_products(p_name TEXT)
RETURNS SETOF RECORD AS $$
BEGIN
    -- SA0002: SQL injection - string concatenation in EXECUTE without USING
    RETURN QUERY EXECUTE 'SELECT * FROM products WHERE product_name = ''' || p_name || '''';
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 3: search_products_dynamic (SQL INJECTION - another variant)
-- Violations: SA0002 (SQL injection), SA0001 (SELECT *)
-- ============================================================================
CREATE OR REPLACE FUNCTION search_products_dynamic(
    p_table_name TEXT,
    p_filter TEXT
)
RETURNS SETOF RECORD AS $$
DECLARE
    v_sql TEXT;
BEGIN
    -- SA0002: SQL injection - concatenating user input into dynamic SQL
    v_sql := 'SELECT * FROM ' || p_table_name || ' WHERE ' || p_filter;
    RETURN QUERY EXECUTE v_sql;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 4: get_orders_by_year (NON-SARGABLE)
-- Violations: SA0003 (non-SARGable EXTRACT), SA0001 (SELECT *)
-- ============================================================================
CREATE OR REPLACE FUNCTION get_orders_by_year(p_year INTEGER)
RETURNS SETOF RECORD AS $$
BEGIN
    -- SA0003: Non-SARGable - EXTRACT on column prevents index usage
    -- SA0001: SELECT *
    RETURN QUERY
        SELECT *
        FROM orders
        WHERE EXTRACT(YEAR FROM order_date) = p_year;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 5: find_customers_by_name (LEADING WILDCARD)
-- Violations: SA0004 (leading wildcard ILIKE), SA0001 (SELECT *)
-- ============================================================================
CREATE OR REPLACE FUNCTION find_customers_by_name(p_search TEXT)
RETURNS SETOF RECORD AS $$
BEGIN
    -- SA0004: Leading wildcard prevents index usage
    -- SA0001: SELECT *
    RETURN QUERY
        SELECT *
        FROM customers
        WHERE customer_name ILIKE '%' || p_search;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 6: customer_has_orders (COUNT > 0 instead of EXISTS)
-- Violations: SA0005 (COUNT(*) > 0 instead of EXISTS)
-- ============================================================================
CREATE OR REPLACE FUNCTION customer_has_orders(p_customer_id INTEGER)
RETURNS BOOLEAN AS $$
DECLARE
    v_count INTEGER;
BEGIN
    -- SA0005: Using COUNT(*) > 0 instead of EXISTS
    SELECT COUNT(*) INTO v_count
    FROM orders
    WHERE customer_id = p_customer_id;

    RETURN v_count > 0;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 7: insert_order_quick (INSERT without column list)
-- Violations: SA0006 (INSERT without column list)
-- ============================================================================
CREATE OR REPLACE FUNCTION insert_order_quick(
    p_customer_id INTEGER,
    p_total NUMERIC
)
RETURNS VOID AS $$
BEGIN
    -- SA0006: INSERT without explicit column list - breaks if table schema changes
    INSERT INTO orders VALUES (DEFAULT, p_customer_id, now(), 'pending', p_total, 0.00, NULL, now());
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 8: expire_old_orders (CURSOR loop)
-- Violations: SA0007 (cursor loop instead of set-based UPDATE)
-- ============================================================================
CREATE OR REPLACE FUNCTION expire_old_orders()
RETURNS VOID AS $$
DECLARE
    v_order RECORD;
    cur_orders CURSOR FOR
        SELECT order_id, status
        FROM orders
        WHERE status = 'pending'
          AND order_date < now() - INTERVAL '30 days';
BEGIN
    -- SA0007: Cursor loop instead of single set-based UPDATE
    OPEN cur_orders;
    LOOP
        FETCH cur_orders INTO v_order;
        EXIT WHEN NOT FOUND;

        -- Individual UPDATE per row - very inefficient
        UPDATE orders
        SET status = 'expired',
            last_modified = now()
        WHERE order_id = v_order.order_id;

        -- Individual INSERT per row - very inefficient
        INSERT INTO order_history (order_id, old_status, new_status, changed_date)
        VALUES (v_order.order_id, v_order.status, 'expired', now());
    END LOOP;
    CLOSE cur_orders;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 9: admin_get_all_users (SECURITY DEFINER without search_path)
-- Violations: SA-PG004 (SECURITY DEFINER without SET search_path)
-- ============================================================================
CREATE OR REPLACE FUNCTION admin_get_all_users()
RETURNS SETOF RECORD
SECURITY DEFINER  -- SA-PG004: No SET search_path = pg_catalog, public
AS $$
BEGIN
    -- Without search_path restriction, attacker can hijack function resolution
    RETURN QUERY SELECT * FROM customers WHERE is_active = TRUE;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 10: get_report_data (Multiple violations)
-- Violations: SA0003 (non-SARGable), SA0004 (leading wildcard),
--             SA0008 (no schema qualifier), Missing EXCEPTION handling
-- ============================================================================
CREATE OR REPLACE FUNCTION get_report_data(
    p_year INTEGER,
    p_month INTEGER,
    p_search_pattern TEXT
)
RETURNS TABLE (
    order_id INTEGER,
    order_date TIMESTAMP,
    total_amount NUMERIC,
    customer_name VARCHAR(255)
) AS $$
BEGIN
    -- SA0003: Non-SARGable - EXTRACT on columns prevents index usage
    -- SA0004: Leading wildcard on ILIKE
    -- SA0008: No schema qualifier on tables
    -- Missing EXCEPTION block for error handling
    RETURN QUERY
        SELECT o.order_id, o.order_date, o.total_amount, c.customer_name
        FROM orders o
        INNER JOIN customers c ON o.customer_id = c.customer_id
        WHERE EXTRACT(YEAR FROM o.order_date) = p_year
          AND EXTRACT(MONTH FROM o.order_date) = p_month
          AND c.email ILIKE '%' || p_search_pattern;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 11: process_payment (Transaction misuse + missing exception)
-- Violations: Transaction misuse (COMMIT in function), missing EXCEPTION block
-- ============================================================================
CREATE OR REPLACE FUNCTION process_payment(
    p_order_id INTEGER,
    p_payment_amount NUMERIC,
    p_payment_method TEXT
)
RETURNS VOID AS $$
BEGIN
    -- COMMIT/ROLLBACK inside a regular function is not allowed in PG
    -- (only in procedures with CALL). This will cause a runtime error.
    UPDATE orders
    SET status = 'processing',
        last_modified = now()
    WHERE order_id = p_order_id;

    INSERT INTO order_history (order_id, old_status, new_status, changed_date)
    VALUES (p_order_id, 'pending', 'processing', now());

    -- This COMMIT is invalid inside a PL/pgSQL function!
    -- It should be a PROCEDURE with transaction control.
    COMMIT;

    -- No EXCEPTION handler - if anything fails, no cleanup happens
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 12: get_customer_summary (Multiple anti-patterns)
-- Violations: SA0001 (SELECT *), SA0005 (COUNT > 0), SA-PG002 (VARCHAR(255))
-- ============================================================================
CREATE OR REPLACE FUNCTION get_customer_summary(
    p_customer_name VARCHAR(255)       -- SA-PG002: Should use TEXT parameter type
)
RETURNS TABLE (
    cust_id INTEGER,
    cust_name VARCHAR(255),            -- SA-PG002: Should use TEXT
    order_count BIGINT,
    has_orders BOOLEAN
) AS $$
BEGIN
    -- SA0005: Using COUNT(*) > 0 logic; should use EXISTS for boolean check
    -- SA0001: SELECT * in subquery
    RETURN QUERY
        SELECT
            c.customer_id,
            c.customer_name,
            (SELECT COUNT(*) FROM orders WHERE customer_id = c.customer_id),
            (SELECT COUNT(*) FROM orders WHERE customer_id = c.customer_id) > 0
        FROM customers c
        WHERE c.customer_name ILIKE '%' || p_customer_name || '%';
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 13: unsafe_delete_by_filter (SQL injection + no schema)
-- Violations: SA0002 (SQL injection), SA0008 (no schema qualifier)
-- ============================================================================
CREATE OR REPLACE FUNCTION unsafe_delete_by_filter(
    p_table TEXT,
    p_where_clause TEXT
)
RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    -- SA0002: Catastrophic SQL injection - user controls entire WHERE clause
    -- SA0008: No schema qualifier
    EXECUTE 'DELETE FROM ' || p_table || ' WHERE ' || p_where_clause;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 14: get_monthly_report (Non-SARGable + implicit cast)
-- Violations: SA0003 (non-SARGable), implicit cast concern
-- ============================================================================
CREATE OR REPLACE FUNCTION get_monthly_report(
    p_date_str TEXT  -- Accepting text instead of DATE type
)
RETURNS TABLE (
    order_id INTEGER,
    total_amount NUMERIC
) AS $$
BEGIN
    -- SA0003: Non-SARGable - to_char on column prevents index usage
    -- Also: implicit cast from TEXT to date comparison
    RETURN QUERY
        SELECT o.order_id, o.total_amount
        FROM orders o
        WHERE to_char(o.order_date, 'YYYY-MM') = p_date_str;
END;
$$ LANGUAGE plpgsql;
