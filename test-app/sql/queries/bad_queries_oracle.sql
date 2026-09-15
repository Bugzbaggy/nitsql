-- ============================================================================
-- BAD_QUERIES_ORACLE.SQL
-- This file contains ad-hoc Oracle SQL queries with INTENTIONAL violations
-- Use this to test if the skill can identify and fix these issues
-- Target: Oracle 19c+
-- ============================================================================

-- ============================================================================
-- QUERY 1: Customer Search
-- Violations: SELECT *, non-SARGable UPPER on column
-- ============================================================================

-- SA0001: SELECT * instead of explicit columns
-- SA0003: Non-SARGable - UPPER on column prevents index usage
SELECT *
FROM customers
WHERE UPPER(customer_name) = 'SMITH';

-- ============================================================================
-- QUERY 2: ROWNUM Pagination Anti-pattern
-- Violations: ROWNUM pagination (should use FETCH FIRST / OFFSET-FETCH)
-- ============================================================================

-- Old-style ROWNUM pagination - inefficient for deep pages
-- Should use Oracle 12c+ FETCH FIRST syntax
SELECT *
FROM (
    SELECT o.*, ROWNUM AS rn
    FROM (
        SELECT *
        FROM orders
        ORDER BY order_date DESC
    ) o
    WHERE ROWNUM <= 40
)
WHERE rn > 20;

-- ============================================================================
-- QUERY 3: Non-SARGable TO_CHAR on Date
-- Violations: SA0003 (non-SARGable TO_CHAR on date column)
-- ============================================================================

-- SA0003: TO_CHAR on column prevents index usage
SELECT order_id, customer_id, order_date, total_amount
FROM orders
WHERE TO_CHAR(order_date, 'YYYY') = '2024'
  AND TO_CHAR(order_date, 'MM') = '03';

-- ============================================================================
-- QUERY 4: Leading Wildcard LIKE
-- Violations: Leading wildcard prevents index usage
-- ============================================================================

-- SA0004: Leading wildcard on LIKE prevents index scan
SELECT customer_id, customer_name, email
FROM customers
WHERE email LIKE '%@gmail.com';

-- ============================================================================
-- QUERY 5: COUNT(*) > 0 Instead of EXISTS
-- Violations: COUNT(*) > 0 anti-pattern
-- ============================================================================

-- SA0005: Full table count when we only need existence check
SELECT c.customer_id, c.customer_name
FROM customers c
WHERE (SELECT COUNT(*) FROM orders WHERE customer_id = c.customer_id) > 0;

-- ============================================================================
-- QUERY 6: Implicit Conversion
-- Violations: Comparing NUMBER column to VARCHAR literal
-- ============================================================================

-- Implicit conversion: Oracle will convert '123' to NUMBER, but if the column
-- is VARCHAR2 and literal is NUMBER, it converts all column values instead
SELECT order_id, customer_id, total_amount
FROM orders
WHERE customer_id = '123';  -- Implicit conversion from VARCHAR2 to NUMBER

-- ============================================================================
-- QUERY 7: Correlated Subquery Instead of JOIN
-- Violations: Correlated subquery in SELECT executes per row
-- ============================================================================

-- Correlated subqueries execute once per row in the outer query
SELECT
    o.order_id,
    o.order_date,
    o.customer_id,
    (SELECT customer_name FROM customers WHERE customer_id = o.customer_id) AS customer_name,
    (SELECT SUM(total_amount) FROM orders o2 WHERE o2.customer_id = o.customer_id) AS customer_total
FROM orders o
WHERE o.order_date > DATE '2024-01-01';

-- ============================================================================
-- QUERY 8: SELECT * with DISTINCT
-- Violations: DISTINCT on all columns is almost always a design smell
-- ============================================================================

-- SA0001: SELECT * with DISTINCT
SELECT DISTINCT *
FROM orders o
INNER JOIN order_history oh ON o.order_id = oh.order_id;

-- ============================================================================
-- QUERY 9: Non-SARGable TRUNC on Date
-- Violations: TRUNC on column prevents index usage
-- ============================================================================

-- SA0003: TRUNC on date column prevents index usage
SELECT order_id, order_date, total_amount
FROM orders
WHERE TRUNC(order_date) = DATE '2024-03-15';

-- ============================================================================
-- QUERY 10: NOT IN with Nullable Subquery
-- Violations: NOT IN with potentially NULL values
-- ============================================================================

-- If inactive_customers has any NULL customer_id, this returns NO rows
SELECT *
FROM customers
WHERE customer_id NOT IN (
    SELECT customer_id FROM inactive_customers  -- May contain NULLs!
);

-- ============================================================================
-- QUERY 11: INSERT without Column List
-- Violations: SA0006 - INSERT without explicit column list
-- ============================================================================

-- SA0006: Breaks when table schema changes
INSERT INTO order_history VALUES (order_history_seq.NEXTVAL, 1001, 'pending', 'shipped', SYSDATE);

-- ============================================================================
-- QUERY 12: Scalar Function in WHERE (non-SARGable)
-- Violations: NVL on column in WHERE prevents index usage
-- ============================================================================

-- SA0003: NVL on column prevents index usage
SELECT order_id, total_amount, shipping_cost
FROM orders
WHERE NVL(shipping_cost, 0) > 10;
