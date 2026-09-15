-- ============================================================================
-- BAD_QUERIES.SQL
-- This file contains ad-hoc queries with INTENTIONAL violations
-- ============================================================================

-- ============================================================================
-- QUERY 1: Customer Search
-- Violations: SELECT *, non-parameterized (for app code), function on column
-- ============================================================================

-- This would be called from application code with string concatenation
-- Expected fix: Use parameterized query with explicit columns
SELECT * 
FROM Customers 
WHERE UPPER(CustomerName) LIKE '%SMITH%';  -- Non-SARGable


-- ============================================================================
-- QUERY 2: Order Report
-- Violations: SELECT *, multiple function calls on columns
-- ============================================================================

SELECT *
FROM Orders o
INNER JOIN Customers c ON o.CustomerID = c.CustomerID
WHERE YEAR(o.OrderDate) = 2024
  AND DATEPART(QUARTER, o.OrderDate) = 1
  AND CONVERT(VARCHAR, o.TotalAmount) LIKE '1%'  -- Terrible!
ORDER BY o.OrderDate;


-- ============================================================================
-- QUERY 3: Count Check (Inefficient EXISTS)
-- Violation: Using COUNT(*) > 0 instead of EXISTS
-- ============================================================================

-- ❌ BAD: Full count when we only need to know if any exist
IF (SELECT COUNT(*) FROM Orders WHERE CustomerID = 12345) > 0
BEGIN
    PRINT 'Customer has orders';
END;


-- ============================================================================
-- QUERY 4: Pagination (Old Style)
-- Violation: Using ROW_NUMBER with subquery instead of OFFSET-FETCH
-- ============================================================================

-- ❌ BAD: Old-style pagination
SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (ORDER BY OrderDate DESC) AS RowNum
    FROM Orders
) AS OrdersWithRowNum
WHERE RowNum BETWEEN 21 AND 40;


-- ============================================================================
-- QUERY 5: DISTINCT with SELECT *
-- Violations: DISTINCT on all columns is usually wrong
-- ============================================================================

SELECT DISTINCT *
FROM OrderDetails od
INNER JOIN Products p ON od.ProductID = p.ProductID;


-- ============================================================================
-- QUERY 6: Subquery that should be JOIN
-- Violation: Correlated subquery in SELECT (runs per row)
-- ============================================================================

SELECT 
    o.OrderID,
    o.OrderDate,
    o.CustomerID,
    (SELECT CustomerName FROM Customers WHERE CustomerID = o.CustomerID) AS CustomerName,
    (SELECT SUM(Quantity * UnitPrice) FROM OrderDetails WHERE OrderID = o.OrderID) AS OrderTotal
FROM Orders o
WHERE o.OrderDate > '2024-01-01';


-- ============================================================================
-- QUERY 7: OR conditions that could be UNION
-- Violation: OR on different columns prevents index usage
-- ============================================================================

SELECT *
FROM Products
WHERE CategoryID = 5
   OR SupplierID = 10
   OR ProductName LIKE '%widget%';  -- This prevents any single index from being used


-- ============================================================================
-- QUERY 8: NOT IN with nullable column
-- Violation: NOT IN with NULLs returns unexpected results
-- ============================================================================

-- If there's any NULL in SubQuery, this returns no rows!
SELECT *
FROM Customers
WHERE CustomerID NOT IN (
    SELECT CustomerID FROM InactiveCustomers  -- May contain NULLs
);


-- ============================================================================
-- QUERY 9: Scalar function in WHERE
-- Violation: Scalar UDF prevents parallelism and runs per-row
-- ============================================================================

SELECT *
FROM Orders
WHERE dbo.fn_GetDiscountedPrice(TotalAmount, CustomerID) > 100;


-- ============================================================================
-- QUERY 10: Implicit conversion in JOIN
-- Violation: Different data types cause implicit conversion
-- ============================================================================

-- Assume Orders.OrderCode is VARCHAR and OrderLookup.Code is NVARCHAR
SELECT o.*, ol.Description
FROM Orders o
INNER JOIN OrderLookup ol ON o.OrderCode = ol.Code;  -- Implicit conversion!


-- ============================================================================
-- QUERY 11: COUNT(*) for existence check
-- Violation: COUNT scans all rows; EXISTS stops at first match
-- ============================================================================

IF (SELECT COUNT(*) FROM Orders WHERE CustomerID = @CustomerID) > 0
BEGIN
    PRINT 'Customer has orders';
END

-- ============================================================================
-- QUERY 12: INSERT without explicit column list
-- Violation: Breaks when columns are added or reordered
-- ============================================================================

INSERT INTO OrderHistory VALUES (1001, 'Shipped', GETDATE(), 'System');
