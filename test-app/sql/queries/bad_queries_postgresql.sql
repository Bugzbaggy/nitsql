-- ============================================================================
-- BAD_QUERIES_POSTGRESQL.SQL
-- This file contains ad-hoc PostgreSQL queries with INTENTIONAL violations
-- Use this to test if the skill can identify and fix these issues
-- Target: PostgreSQL 13+
-- ============================================================================

-- ============================================================================
-- QUERY 1: Customer Search
-- Violations: SELECT *, non-SARGable (UPPER on column)
-- ============================================================================

-- SA0001: SELECT * instead of explicit columns
SELECT *
FROM customers
WHERE UPPER(customer_name) = 'SMITH';  -- SA0003: Non-SARGable

-- ============================================================================
-- QUERY 2: Order Report by Year
-- Violations: SELECT *, non-SARGable EXTRACT on column
-- ============================================================================

-- SA0001: SELECT *
-- SA0003: Non-SARGable - EXTRACT on column prevents index usage
SELECT *
FROM orders o
INNER JOIN customers c ON o.customer_id = c.customer_id
WHERE EXTRACT(YEAR FROM o.order_date) = 2024
  AND EXTRACT(QUARTER FROM o.order_date) = 1
ORDER BY o.order_date;

-- ============================================================================
-- QUERY 3: Leading Wildcard Search
-- Violations: Leading wildcard ILIKE
-- ============================================================================

-- SA0004: Leading wildcard prevents index usage on customer_name
SELECT customer_id, customer_name, email
FROM customers
WHERE customer_name ILIKE '%smith';

-- ============================================================================
-- QUERY 4: COUNT(*) > 0 Instead of EXISTS
-- Violations: COUNT(*) > 0 anti-pattern
-- ============================================================================

-- SA0005: Full count when we only need to know if any exist
SELECT c.customer_id, c.customer_name
FROM customers c
WHERE (SELECT COUNT(*) FROM orders WHERE customer_id = c.customer_id) > 0;

-- ============================================================================
-- QUERY 5: Implicit Cast
-- Violations: Implicit cast from text to integer
-- ============================================================================

-- Implicit cast: comparing integer column to string literal
SELECT order_id, customer_id, total_amount
FROM orders
WHERE customer_id = '123';  -- Implicit cast from text to integer

-- ============================================================================
-- QUERY 6: Missing LIMIT on Large Table Scan
-- Violations: No LIMIT clause on potentially large result set
-- ============================================================================

-- No LIMIT - could return millions of rows
SELECT order_id, customer_id, order_date, total_amount, status
FROM orders
WHERE status = 'pending'
ORDER BY order_date DESC;

-- ============================================================================
-- QUERY 7: Large OFFSET Pagination Anti-pattern
-- Violations: Large OFFSET causes PostgreSQL to scan and discard rows
-- ============================================================================

-- OFFSET 10000 means PG must scan and skip 10000 rows before returning results
SELECT order_id, customer_id, order_date, total_amount
FROM orders
ORDER BY order_date DESC
LIMIT 20 OFFSET 10000;

-- ============================================================================
-- QUERY 8: Correlated Subquery Instead of JOIN
-- Violations: Correlated subquery in SELECT (runs per row)
-- ============================================================================

-- Correlated subqueries execute once per row in the outer query
SELECT
    o.order_id,
    o.order_date,
    o.customer_id,
    (SELECT customer_name FROM customers WHERE customer_id = o.customer_id) AS customer_name,
    (SELECT SUM(total_amount) FROM orders o2 WHERE o2.customer_id = o.customer_id) AS customer_total
FROM orders o
WHERE o.order_date > '2024-01-01';

-- ============================================================================
-- QUERY 9: NOT IN with Nullable Subquery
-- Violations: NOT IN with potentially NULL values returns unexpected results
-- ============================================================================

-- If inactive_customers has any NULL customer_id, this returns NO rows
SELECT *
FROM customers
WHERE customer_id NOT IN (
    SELECT customer_id FROM inactive_customers  -- May contain NULLs!
);

-- ============================================================================
-- QUERY 10: DISTINCT with SELECT *
-- Violations: DISTINCT on all columns is almost always wrong
-- ============================================================================

-- SA0001: SELECT * with DISTINCT - usually indicates a JOIN issue
SELECT DISTINCT *
FROM orders o
INNER JOIN order_history oh ON o.order_id = oh.order_id;

-- ============================================================================
-- QUERY 11: Non-SARGable date_trunc
-- Violations: Function on column in WHERE
-- ============================================================================

-- SA0003: date_trunc on column prevents index usage
SELECT order_id, order_date, total_amount
FROM orders
WHERE date_trunc('month', order_date) = '2024-03-01'::timestamp;

-- ============================================================================
-- QUERY 12: INSERT without Column List
-- Violations: INSERT without explicit column list
-- ============================================================================

-- SA0006: Breaks when table schema changes (columns added/reordered)
INSERT INTO order_history VALUES (DEFAULT, 1001, 'pending', 'shipped', NOW());
