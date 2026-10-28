-- ============================================================================
-- BAD_PROCEDURES_ORACLE.SQL
-- This file contains Oracle PL/SQL procedures with INTENTIONAL violations
-- Use this to test if the skill can identify and fix these issues
-- Target: Oracle 19c+
-- ============================================================================

-- Violations Summary:
-- CRITICAL: SELECT * usage (SA0001)
-- CRITICAL: EXECUTE IMMEDIATE with || concatenation (SA0002)
-- HIGH: Non-SARGable WHERE TO_CHAR(date_col, 'YYYY') (SA0003)
-- HIGH: WHEN OTHERS THEN NULL (SA-ORA001)
-- MEDIUM: VARCHAR instead of VARCHAR2 (SA-ORA002)
-- HIGH: SELECT INTO without NO_DATA_FOUND handler (SA-ORA004)
-- MEDIUM: LONG data type usage (SA-ORA005)
-- MEDIUM: Missing COMMIT/ROLLBACK in procedures with DML
-- HIGH: Cursor FOR loop where set-based would work
-- CRITICAL: Unvalidated input to EXECUTE IMMEDIATE

-- ============================================================================
-- PROCEDURE 1: get_customer_orders
-- Violations: SA0001 (SELECT *), SA-ORA001 (WHEN OTHERS THEN NULL)
-- ============================================================================
CREATE OR REPLACE PROCEDURE get_customer_orders(
    p_customer_id IN NUMBER,
    p_cursor      OUT SYS_REFCURSOR
) AS
BEGIN
    -- SA0001: Using SELECT * instead of explicit columns
    OPEN p_cursor FOR
        SELECT * FROM orders WHERE customer_id = p_customer_id;
EXCEPTION
    -- SA-ORA001: Swallowing all exceptions silently!
    WHEN OTHERS THEN NULL;
END get_customer_orders;
/

-- ============================================================================
-- PROCEDURE 2: search_products (SQL INJECTION)
-- Violations: SA0002 (SQL injection via EXECUTE IMMEDIATE + ||)
-- ============================================================================
CREATE OR REPLACE PROCEDURE search_products(
    p_name IN VARCHAR2
) AS
    v_sql  VARCHAR2(4000);
    v_cursor SYS_REFCURSOR;
BEGIN
    -- SA0002: SQL injection - string concatenation with EXECUTE IMMEDIATE
    v_sql := 'SELECT * FROM products WHERE product_name = ''' || p_name || '''';
    OPEN v_cursor FOR v_sql;
    -- Cursor left open without processing (resource leak)
END search_products;
/

-- ============================================================================
-- PROCEDURE 3: get_orders_by_year (NON-SARGABLE)
-- Violations: SA0003 (non-SARGable TO_CHAR on date column)
-- ============================================================================
CREATE OR REPLACE PROCEDURE get_orders_by_year(
    p_year    IN NUMBER,
    p_cursor  OUT SYS_REFCURSOR
) AS
BEGIN
    -- SA0003: Non-SARGable - TO_CHAR on column prevents index usage
    OPEN p_cursor FOR
        SELECT order_id, customer_id, order_date, total_amount
        FROM orders
        WHERE TO_CHAR(order_date, 'YYYY') = TO_CHAR(p_year);
EXCEPTION
    WHEN OTHERS THEN NULL;  -- SA-ORA001: Silent exception swallowing
END get_orders_by_year;
/

-- ============================================================================
-- PROCEDURE 4: find_customer_by_email (SELECT INTO without NO_DATA_FOUND)
-- Violations: SA-ORA004 (SELECT INTO without NO_DATA_FOUND handler)
-- ============================================================================
CREATE OR REPLACE PROCEDURE find_customer_by_email(
    p_email       IN VARCHAR2,
    p_customer_id OUT NUMBER,
    p_name        OUT VARCHAR2
) AS
BEGIN
    -- SA-ORA004: SELECT INTO will raise NO_DATA_FOUND if no row matches
    -- but there is no handler for it
    SELECT customer_id, customer_name
    INTO p_customer_id, p_name
    FROM customers
    WHERE email = p_email;
    -- No EXCEPTION block at all!
END find_customer_by_email;
/

-- ============================================================================
-- PROCEDURE 5: create_customer (VARCHAR instead of VARCHAR2, LONG data type)
-- Violations: SA-ORA002 (VARCHAR), SA-ORA005 (LONG data type)
-- ============================================================================
CREATE OR REPLACE PROCEDURE create_customer(
    p_name    IN VARCHAR,              -- SA-ORA002: VARCHAR instead of VARCHAR2
    p_email   IN VARCHAR,              -- SA-ORA002: VARCHAR instead of VARCHAR2
    p_phone   IN VARCHAR,              -- SA-ORA002: VARCHAR instead of VARCHAR2
    p_notes   IN LONG                  -- SA-ORA005: LONG is deprecated, use CLOB
) AS
BEGIN
    INSERT INTO customers (customer_name, email, phone, notes)
    VALUES (p_name, p_email, p_phone, p_notes);

    -- Missing COMMIT - DML without explicit transaction control
END create_customer;
/

-- ============================================================================
-- PROCEDURE 6: expire_old_orders (Cursor FOR loop instead of set-based)
-- Violations: Cursor FOR loop anti-pattern, missing COMMIT/ROLLBACK
-- ============================================================================
CREATE OR REPLACE PROCEDURE expire_old_orders AS
BEGIN
    -- Cursor FOR loop: row-by-row processing instead of single UPDATE
    FOR rec IN (
        SELECT order_id, status
        FROM orders
        WHERE status = 'pending'
          AND order_date < SYSDATE - 30
    ) LOOP
        -- Individual UPDATE per row - very slow on large datasets
        UPDATE orders
        SET status = 'expired',
            last_modified = SYSDATE
        WHERE order_id = rec.order_id;

        -- Individual INSERT per row
        INSERT INTO order_history (order_id, old_status, new_status, changed_date)
        VALUES (rec.order_id, rec.status, 'expired', SYSDATE);
    END LOOP;

    -- Missing COMMIT after DML
END expire_old_orders;
/

-- ============================================================================
-- PROCEDURE 7: dynamic_search (SQL injection + SELECT *)
-- Violations: SA0002 (SQL injection), SA0001 (SELECT *)
-- ============================================================================
CREATE OR REPLACE PROCEDURE dynamic_search(
    p_table_name IN VARCHAR2,
    p_filter     IN VARCHAR2,
    p_cursor     OUT SYS_REFCURSOR
) AS
    v_sql VARCHAR2(4000);
BEGIN
    -- SA0002: SQL injection - user controls table name and filter
    -- SA0001: SELECT *
    v_sql := 'SELECT * FROM ' || p_table_name || ' WHERE ' || p_filter;
    OPEN p_cursor FOR v_sql;
EXCEPTION
    WHEN OTHERS THEN NULL;  -- SA-ORA001: Swallows all exceptions
END dynamic_search;
/

-- ============================================================================
-- PROCEDURE 8: get_report_data (Multiple non-SARGable predicates)
-- Violations: SA0003 (non-SARGable TO_CHAR, UPPER), leading wildcard
-- ============================================================================
CREATE OR REPLACE PROCEDURE get_report_data(
    p_year          IN NUMBER,
    p_month         IN NUMBER,
    p_search        IN VARCHAR2,
    p_cursor        OUT SYS_REFCURSOR
) AS
BEGIN
    -- SA0003: Non-SARGable - TO_CHAR and UPPER on columns prevent index usage
    -- Leading wildcard on LIKE
    OPEN p_cursor FOR
        SELECT o.order_id, o.order_date, o.total_amount, c.customer_name
        FROM orders o
        INNER JOIN customers c ON o.customer_id = c.customer_id
        WHERE TO_CHAR(o.order_date, 'YYYY') = TO_CHAR(p_year)
          AND TO_CHAR(o.order_date, 'MM') = LPAD(TO_CHAR(p_month), 2, '0')
          AND UPPER(c.customer_name) LIKE '%' || UPPER(p_search) || '%';
EXCEPTION
    WHEN OTHERS THEN
        -- SA-ORA001: Logging but then silently continuing
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
END get_report_data;
/

-- ============================================================================
-- PROCEDURE 9: process_payment (Missing ROLLBACK, WHEN OTHERS THEN NULL)
-- Violations: Missing ROLLBACK on error, SA-ORA001
-- ============================================================================
CREATE OR REPLACE PROCEDURE process_payment(
    p_order_id       IN NUMBER,
    p_payment_amount IN NUMBER,
    p_payment_method IN VARCHAR2
) AS
BEGIN
    UPDATE orders
    SET status = 'processing',
        last_modified = SYSDATE
    WHERE order_id = p_order_id;

    INSERT INTO order_history (order_id, old_status, new_status, changed_date)
    VALUES (p_order_id, 'pending', 'processing', SYSDATE);

    COMMIT;  -- COMMIT here, but no ROLLBACK on error path

EXCEPTION
    WHEN OTHERS THEN
        -- SA-ORA001: Swallowing exception after partial COMMIT is dangerous
        NULL;
END process_payment;
/

-- ============================================================================
-- PROCEDURE 10: get_order_total (SELECT INTO without exception handler)
-- Violations: SA-ORA004 (SELECT INTO without NO_DATA_FOUND),
--             SA0001 (SELECT *)
-- ============================================================================
CREATE OR REPLACE PROCEDURE get_order_total(
    p_order_id IN  NUMBER,
    p_total    OUT NUMBER,
    p_status   OUT VARCHAR2
) AS
    v_order orders%ROWTYPE;
BEGIN
    -- SA0001: SELECT * into ROWTYPE - still bad practice
    -- SA-ORA004: No NO_DATA_FOUND or TOO_MANY_ROWS handler
    SELECT *
    INTO v_order
    FROM orders
    WHERE order_id = p_order_id;

    p_total  := v_order.total_amount;
    p_status := v_order.status;
END get_order_total;
/

-- ============================================================================
-- PROCEDURE 11: unsafe_update (EXECUTE IMMEDIATE with user input)
-- Violations: SA0002 (SQL injection via := assignment to EXECUTE IMMEDIATE)
-- ============================================================================
CREATE OR REPLACE PROCEDURE unsafe_update(
    p_table_name  IN VARCHAR2,
    p_column_name IN VARCHAR2,
    p_new_value   IN VARCHAR2,
    p_where       IN VARCHAR2
) AS
    v_sql VARCHAR2(4000);
BEGIN
    -- SA0002: Catastrophic SQL injection - all parameters concatenated
    v_sql := 'UPDATE ' || p_table_name
          || ' SET ' || p_column_name || ' = ''' || p_new_value || ''''
          || ' WHERE ' || p_where;
    EXECUTE IMMEDIATE v_sql;
    COMMIT;
END unsafe_update;
/

-- ============================================================================
-- PROCEDURE 12: bulk_insert_customers (Cursor loop + VARCHAR + no error handling)
-- Violations: Cursor FOR loop, SA-ORA002 (VARCHAR), no error handling
-- ============================================================================
CREATE OR REPLACE PROCEDURE bulk_insert_customers AS
    v_name  VARCHAR(200);              -- SA-ORA002: VARCHAR instead of VARCHAR2
    v_email VARCHAR(200);              -- SA-ORA002: VARCHAR instead of VARCHAR2
BEGIN
    -- Cursor FOR loop for bulk insert instead of INSERT ... SELECT
    FOR rec IN (
        SELECT prospect_name, prospect_email
        FROM prospect_staging
        WHERE processed_flag = 'N'
    ) LOOP
        v_name  := rec.prospect_name;
        v_email := rec.prospect_email;

        INSERT INTO customers (customer_name, email, is_active)
        VALUES (v_name, v_email, 1);

        UPDATE prospect_staging
        SET processed_flag = 'Y'
        WHERE prospect_name = rec.prospect_name
          AND prospect_email = rec.prospect_email;
    END LOOP;

    COMMIT;
    -- No EXCEPTION handler at all - if any row fails, partial commit is lost
END bulk_insert_customers;
/

-- ============================================================================
-- PROCEDURE 13: customer_count_check (COUNT instead of EXISTS)
-- Violations: SA0005 (COUNT(*) > 0 instead of EXISTS)
-- ============================================================================
CREATE OR REPLACE PROCEDURE customer_count_check(
    p_customer_id IN  NUMBER,
    p_has_orders  OUT NUMBER   -- 1 or 0
) AS
    v_count NUMBER;
BEGIN
    -- SA0005: COUNT(*) > 0 instead of EXISTS - scans all matching rows
    SELECT COUNT(*)
    INTO v_count
    FROM orders
    WHERE customer_id = p_customer_id;

    IF v_count > 0 THEN
        p_has_orders := 1;
    ELSE
        p_has_orders := 0;
    END IF;
END customer_count_check;
/

-- ============================================================================
-- PROCEDURE 14: insert_order_no_columns (INSERT without column list)
-- Violations: SA0006 (INSERT without column list)
-- ============================================================================
CREATE OR REPLACE PROCEDURE insert_order_no_columns(
    p_customer_id IN NUMBER,
    p_total       IN NUMBER
) AS
BEGIN
    -- SA0006: INSERT without explicit column list
    INSERT INTO orders
    VALUES (order_seq.NEXTVAL, p_customer_id, SYSDATE, 'pending', p_total, 0, NULL, SYSDATE);

    COMMIT;
END insert_order_no_columns;
/
