-- ============================================================================
-- BAD_QUERIES_MYSQL.SQL
-- This file contains ad-hoc MySQL queries with INTENTIONAL violations
-- Use this to test if the skill can identify and fix these issues
-- Target: MySQL 8.0+
-- ============================================================================

-- ============================================================================
-- QUERY 1: Customer Search
-- Violations: SELECT *, non-SARGable UPPER on column
-- ============================================================================

-- SA0001: SELECT * instead of explicit columns
-- SA0003: Non-SARGable - function on column
SELECT *
FROM customers
WHERE UPPER(customer_name) = 'SMITH';

-- ============================================================================
-- QUERY 2: Order Report by Year
-- Violations: SELECT *, non-SARGable YEAR() on column
-- ============================================================================

-- SA0001: SELECT *
-- SA0003: Non-SARGable - YEAR() and MONTH() on columns prevent index usage
SELECT *
FROM orders o
INNER JOIN customers c ON o.customer_id = c.customer_id
WHERE YEAR(o.order_date) = 2024
  AND MONTH(o.order_date) = 3
ORDER BY o.order_date;

-- ============================================================================
-- QUERY 3: Leading Wildcard Search
-- Violations: Leading wildcard LIKE '%value'
-- ============================================================================

-- SA0004: Leading wildcard prevents index usage
SELECT customer_id, customer_name, email
FROM customers
WHERE customer_name LIKE '%smith';

-- ============================================================================
-- QUERY 4: COUNT(*) > 0 Instead of EXISTS
-- Violations: COUNT(*) > 0 anti-pattern
-- ============================================================================

-- SA0005: Full count when we only need existence check
SELECT c.customer_id, c.customer_name
FROM customers c
WHERE (SELECT COUNT(*) FROM orders WHERE customer_id = c.customer_id) > 0;

-- ============================================================================
-- QUERY 5: No LIMIT on SELECT
-- Violations: Missing LIMIT on potentially large result set
-- ============================================================================

-- No LIMIT clause - could return millions of rows
SELECT order_id, customer_id, order_date, total_amount, status
FROM orders
WHERE status = 'pending'
ORDER BY order_date DESC;

-- ============================================================================
-- QUERY 6: Using != Instead of <>
-- Violations: != works but is not ANSI SQL standard
-- ============================================================================

-- != is MySQL-specific; <> is the ANSI SQL standard operator
SELECT order_id, status, total_amount
FROM orders
WHERE status != 'cancelled'
  AND total_amount != 0;

-- ============================================================================
-- QUERY 7: Implicit Conversion
-- Violations: Comparing VARCHAR column to unquoted number
-- ============================================================================

-- Implicit conversion: comparing VARCHAR column to numeric literal
-- MySQL converts ALL varchar values to numbers for comparison, preventing index usage
SELECT order_id, customer_id, status
FROM orders
WHERE status = 0;  -- status is VARCHAR/ENUM, comparing to INT

-- ============================================================================
-- QUERY 8: Correlated Subquery Instead of JOIN
-- Violations: Correlated subquery in SELECT
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
-- Violations: NOT IN with potentially NULL values
-- ============================================================================

-- If inactive_customers has any NULL customer_id, this returns NO rows
SELECT *
FROM customers
WHERE customer_id NOT IN (
    SELECT customer_id FROM inactive_customers  -- May contain NULLs!
);

-- ============================================================================
-- QUERY 10: SELECT DISTINCT *
-- Violations: DISTINCT on all columns is almost always wrong
-- ============================================================================

-- SA0001: SELECT * with DISTINCT
SELECT DISTINCT *
FROM orders o
INNER JOIN order_history oh ON o.order_id = oh.order_id;

-- ============================================================================
-- QUERY 11: Non-SARGable DATE() on Column
-- Violations: DATE() function on column prevents index usage
-- ============================================================================

-- SA0003: DATE() on column prevents index usage
SELECT order_id, order_date, total_amount
FROM orders
WHERE DATE(order_date) = '2024-03-15';

-- ============================================================================
-- QUERY 12: INSERT without Column List
-- Violations: SA0006 - INSERT without explicit column list
-- ============================================================================

-- SA0006: Breaks when table schema changes
INSERT INTO order_history VALUES (NULL, 1001, 'pending', 'shipped', NOW());

-- ============================================================================
-- QUERY 13: Unnecessary Backtick Quoting
-- Violations: Backtick quoting on regular identifiers
-- ============================================================================

-- Unnecessary backticks on identifiers that do not require quoting
SELECT `order_id`, `customer_id`, `order_date`, `total_amount`
FROM `orders`
WHERE `status` = 'pending';
