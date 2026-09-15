-- ============================================================================
-- BAD_PROCEDURES.SQL
-- This file contains stored procedures with INTENTIONAL violations
-- Use this to test if the skill can identify and fix these issues
-- ============================================================================

-- Violations Summary:
-- 🔴 CRITICAL: SELECT * usage (SR0001)
-- 🔴 CRITICAL: SQL injection vulnerability
-- 🔴 CRITICAL: Implicit type conversion data loss (SR0014)
-- 🟡 HIGH: Missing SET NOCOUNT ON
-- 🟡 HIGH: Cursor instead of set-based operation
-- 🟡 HIGH: No error handling
-- 🟡 HIGH: Leading wildcard LIKE (SR0005)
-- 🔵 MEDIUM: @@IDENTITY instead of SCOPE_IDENTITY (SR0008)
-- 🔵 MEDIUM: VARCHAR(1) or VARCHAR(2) types (SR0009)
-- 🔵 MEDIUM: Old-style *= join syntax (SR0010)
-- 🔵 MEDIUM: Output param not always set (SR0013)
-- 🔵 MEDIUM: sp_ prefix on stored procedure (SR0016)
-- 🔵 MEDIUM: ISNULL not used on nullable columns (SR0007)
-- ⚪ LOW: Special characters in object names (SR0011)
-- ⚪ LOW: Reserved words as identifiers (SR0012)
-- 🔵 MEDIUM: No schema qualification

-- ============================================================================
-- PROCEDURE 1: GetCustomerOrders (SR0001 - SELECT *)
-- Violations: SELECT *, missing SET NOCOUNT ON, no schema qualification
-- ============================================================================
CREATE PROCEDURE GetCustomerOrders
    @CustomerID INT
AS
BEGIN
    -- Missing SET NOCOUNT ON
    
    -- SR0001: Using SELECT * instead of explicit columns
    SELECT * 
    FROM Orders 
    WHERE CustomerID = @CustomerID;
END;
GO

-- ============================================================================
-- PROCEDURE 2: SearchProducts (SQL INJECTION)
-- Violations: SQL INJECTION, dynamic SQL without parameters
-- ============================================================================
CREATE PROCEDURE SearchProducts
    @SearchTerm NVARCHAR(100),
    @CategoryName NVARCHAR(50)
AS
BEGIN
    DECLARE @SQL NVARCHAR(MAX);
    
    -- CRITICAL: SQL Injection vulnerability - string concatenation
    SET @SQL = N'SELECT * FROM Products WHERE ProductName LIKE ''%' + @SearchTerm + '%''';
    
    IF @CategoryName IS NOT NULL
        SET @SQL = @SQL + N' AND CategoryName = ''' + @CategoryName + '''';
    
    -- Using EXEC instead of sp_executesql
    EXEC(@SQL);
END;
GO

-- ============================================================================
-- PROCEDURE 3: UpdateOrderStatuses (CURSORS)
-- Violations: Cursor usage, no SET NOCOUNT, poor transaction handling
-- ============================================================================
CREATE PROCEDURE UpdateOrderStatuses
AS
BEGIN
    DECLARE @OrderID INT;
    DECLARE @CurrentStatus VARCHAR(20);
    
    -- Using cursor instead of set-based UPDATE
    DECLARE order_cursor CURSOR FOR
        SELECT OrderID, Status 
        FROM Orders 
        WHERE Status = 'pending'
          AND OrderDate < DATEADD(DAY, -30, GETDATE());
    
    OPEN order_cursor;
    FETCH NEXT FROM order_cursor INTO @OrderID, @CurrentStatus;
    
    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Individual UPDATE per row - inefficient
        UPDATE Orders 
        SET Status = 'expired', 
            LastModified = GETDATE()
        WHERE OrderID = @OrderID;
        
        -- Individual INSERT per row - inefficient
        INSERT INTO OrderHistory (OrderID, OldStatus, NewStatus, ChangedDate)
        VALUES (@OrderID, @CurrentStatus, 'expired', GETDATE());
        
        FETCH NEXT FROM order_cursor INTO @OrderID, @CurrentStatus;
    END;
    
    CLOSE order_cursor;
    DEALLOCATE order_cursor;
END;
GO

-- ============================================================================
-- PROCEDURE 4: ProcessPayment (TRANSACTIONS WITHOUT TRY-CATCH)
-- Violations: Transaction without TRY-CATCH, no XACT_ABORT, SELECT *
-- ============================================================================
CREATE PROCEDURE ProcessPayment
    @OrderID INT,
    @PaymentAmount DECIMAL(10,2),
    @PaymentMethod VARCHAR(50)
AS
BEGIN
    -- Missing SET XACT_ABORT ON
    -- Missing TRY-CATCH
    
    BEGIN TRANSACTION;
    
    -- SR0001: Using SELECT * 
    SELECT * FROM Orders WHERE OrderID = @OrderID;
    
    UPDATE Orders
    SET PaymentStatus = 'processing',
        LastModified = GETDATE()
    WHERE OrderID = @OrderID;
    
    INSERT INTO Payments (OrderID, Amount, Method, ProcessedDate)
    VALUES (@OrderID, @PaymentAmount, @PaymentMethod, GETDATE());
    
    UPDATE Orders
    SET PaymentStatus = 'paid'
    WHERE OrderID = @OrderID;
    
    COMMIT TRANSACTION;
    -- No ROLLBACK on error!
END;
GO

-- ============================================================================
-- PROCEDURE 5: GetReportData (NON-SARGABLE PREDICATES, SR0005)
-- Violations: Functions on columns in WHERE (non-SARGable), NOLOCK hints
-- ============================================================================
CREATE PROCEDURE GetReportData
    @Year INT,
    @Month INT,
    @SearchPattern NVARCHAR(100)
AS
BEGIN
    -- Non-SARGable predicates - functions on columns prevent index usage
    SELECT 
        o.OrderID,
        o.OrderDate,
        o.TotalAmount,
        c.CustomerName
    FROM Orders o WITH (NOLOCK)  -- NOLOCK can cause dirty reads
    INNER JOIN Customers c WITH (NOLOCK) ON o.CustomerID = c.CustomerID
    WHERE YEAR(o.OrderDate) = @Year           -- Non-SARGable!
      AND MONTH(o.OrderDate) = @Month         -- Non-SARGable!
      AND ISNULL(o.Status, 'unknown') = 'completed'  -- Non-SARGable! (SR0007 violation)
      AND LEFT(c.CustomerName, 1) = 'A'       -- Non-SARGable!
      -- SR0005: Leading wildcard prevents index usage
      AND c.Email LIKE '%' + @SearchPattern;
END;
GO

-- ============================================================================
-- PROCEDURE 6: InsertMultipleItems (LOOP INSERTS)
-- Violations: Loop INSERT instead of batch, no parameterization
-- ============================================================================
CREATE PROCEDURE InsertMultipleItems
    @Items NVARCHAR(MAX)  -- Comma-separated values (anti-pattern)
AS
BEGIN
    DECLARE @ItemName NVARCHAR(100);
    DECLARE @Pos INT;
    
    -- Splitting string in a loop - inefficient
    WHILE LEN(@Items) > 0
    BEGIN
        SET @Pos = CHARINDEX(',', @Items);
        IF @Pos = 0
        BEGIN
            SET @ItemName = @Items;
            SET @Items = '';
        END
        ELSE
        BEGIN
            SET @ItemName = LEFT(@Items, @Pos - 1);
            SET @Items = SUBSTRING(@Items, @Pos + 1, LEN(@Items));
        END;
        
        -- Individual INSERT per item - should use bulk insert
        INSERT INTO Items (ItemName, CreatedDate)
        VALUES (@ItemName, GETDATE());
    END;
END;
GO

-- ============================================================================
-- PROCEDURE 7: GetUserByEmail (SR0014 - IMPLICIT CONVERSION)
-- Violations: Implicit conversion, type mismatch
-- ============================================================================
CREATE PROCEDURE GetUserByEmail
    @Email VARCHAR(100)  -- Should be NVARCHAR to match column type
AS
BEGIN
    -- SR0014: Implicit conversion from VARCHAR to NVARCHAR can hurt performance
    -- and potentially cause data loss
    SELECT *
    FROM Users
    WHERE Email = @Email;  -- If Email column is NVARCHAR, this causes implicit conversion
END;
GO

-- ============================================================================
-- PROCEDURE 8: InsertOrder (SR0008 - @@IDENTITY)
-- Violations: Using @@IDENTITY instead of SCOPE_IDENTITY()
-- ============================================================================
CREATE PROCEDURE InsertOrder
    @CustomerID INT,
    @TotalAmount DECIMAL(10,2),
    @NewOrderID INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    INSERT INTO Orders (CustomerID, TotalAmount, OrderDate)
    VALUES (@CustomerID, @TotalAmount, GETDATE());
    
    -- SR0008: @@IDENTITY can return wrong value if trigger inserts into another table
    SET @NewOrderID = @@IDENTITY;  -- Should use SCOPE_IDENTITY()
END;
GO

-- ============================================================================
-- PROCEDURE 9: CreateCustomer (SR0009 - VARCHAR(1) and VARCHAR(2))
-- Violations: Using VARCHAR(1) or VARCHAR(2) instead of CHAR
-- ============================================================================
CREATE PROCEDURE CreateCustomer
    @FirstName NVARCHAR(50),
    @LastName NVARCHAR(50),
    @MiddleInitial VARCHAR(1),     -- SR0009: Should use CHAR(1)
    @StateCode VARCHAR(2),          -- SR0009: Should use CHAR(2)
    @Status NVARCHAR(1)            -- SR0009: Should use NCHAR(1)
AS
BEGIN
    SET NOCOUNT ON;
    
    INSERT INTO Customers (FirstName, LastName, MiddleInitial, StateCode, Status)
    VALUES (@FirstName, @LastName, @MiddleInitial, @StateCode, @Status);
END;
GO

-- ============================================================================
-- PROCEDURE 10: GetOrdersOldJoin (SR0010 - DEPRECATED JOIN SYNTAX)
-- Violations: Using *= or =* old-style join syntax
-- ============================================================================
CREATE PROCEDURE GetOrdersOldJoin
    @CustomerID INT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- SR0010: Deprecated join syntax - should use LEFT OUTER JOIN
    SELECT o.OrderID, o.OrderDate, c.CustomerName
    FROM Orders o, Customers c
    WHERE o.CustomerID *= c.CustomerID  -- Old-style LEFT JOIN
      AND o.CustomerID = @CustomerID;
END;
GO

-- ============================================================================
-- PROCEDURE 11: GetOrderWithDiscount (SR0013 - OUTPUT PARAM NOT ALWAYS SET)
-- Violations: Output parameter not populated in all code paths
-- ============================================================================
CREATE PROCEDURE GetOrderWithDiscount
    @OrderID INT,
    @DiscountPercent DECIMAL(5,2) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @OrderTotal DECIMAL(10,2);
    
    SELECT @OrderTotal = TotalAmount
    FROM Orders
    WHERE OrderID = @OrderID;
    
    -- SR0013: Output parameter only set in one branch
    IF @OrderTotal > 1000
    BEGIN
        SET @DiscountPercent = 10.00;
    END
    ELSE IF @OrderTotal > 500
    BEGIN
        SET @DiscountPercent = 5.00;
    END
    -- ELSE branch missing! @DiscountPercent not set for orders <= 500
END;
GO

-- ============================================================================
-- PROCEDURE 12: sp_GetCustomers (SR0016 - sp_ PREFIX)
-- Violations: Using sp_ prefix for stored procedure
-- ============================================================================
CREATE PROCEDURE sp_GetCustomers  -- SR0016: sp_ prefix reserved for system procs
    @ActiveOnly BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    
    SELECT CustomerID, CustomerName, Email
    FROM Customers
    WHERE @ActiveOnly = 0 OR IsActive = 1;
END;
GO

-- ============================================================================
-- PROCEDURE 13: BadNamingExample (SR0011 - SPECIAL CHARACTERS, SR0012 - RESERVED WORDS)
-- Violations: Special characters in names, reserved words as identifiers
-- ============================================================================
CREATE PROCEDURE [Bad-Naming_Example$Proc]  -- SR0011: Special characters require escaping
AS
BEGIN
    SET NOCOUNT ON;
    
    -- SR0012: Using reserved words as column aliases
    SELECT 
        CustomerID AS [Order],     -- 'Order' is a reserved word
        CustomerName AS [Select],   -- 'Select' is a reserved word
        Email AS [Index],           -- 'Index' is a reserved word
        CreatedDate AS [Table]      -- 'Table' is a reserved word
    FROM Customers;
END;
GO

-- ============================================================================
-- PROCEDURE 14: ReportWithNullableColumns (SR0007 - ISNULL ON NULLABLE)
-- Violations: Not using ISNULL on nullable columns in expressions
-- ============================================================================
CREATE PROCEDURE ReportWithNullableColumns
    @MinAmount DECIMAL(10,2)
AS
BEGIN
    SET NOCOUNT ON;
    
    -- SR0007: Should use ISNULL on nullable columns in expressions
    SELECT 
        OrderID,
        CustomerID,
        -- These calculations will return NULL if any component is NULL
        TotalAmount + ShippingCost + TaxAmount AS GrandTotal,  -- No ISNULL
        TotalAmount * DiscountPercent / 100 AS DiscountAmount  -- No ISNULL
    FROM Orders
    WHERE TotalAmount > @MinAmount
      -- SR0007: Comparison with nullable column without ISNULL
      AND ShippingCost > 0;  -- Will exclude NULL shipping costs unintentionally
END;
GO

-- ============================================================================
-- PROCEDURE 15: CastingDataLoss (SR0014 - DATA LOSS FROM CASTING)
-- Violations: Potential data loss from type conversions
-- ============================================================================
CREATE PROCEDURE CastingDataLoss
    @InputValue FLOAT,
    @LargeNumber BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @SmallInt SMALLINT;
    DECLARE @TinyInt TINYINT;
    DECLARE @SmallDecimal DECIMAL(5,2);
    
    -- SR0014: Potential data loss - BIGINT to SMALLINT
    SET @SmallInt = @LargeNumber;
    
    -- SR0014: Potential data loss - FLOAT to TINYINT
    SET @TinyInt = CAST(@InputValue AS TINYINT);
    
    -- SR0014: Potential data loss - FLOAT to small DECIMAL
    SET @SmallDecimal = @InputValue;
    
    SELECT @SmallInt AS SmallIntValue, 
           @TinyInt AS TinyIntValue, 
           @SmallDecimal AS SmallDecimalValue;
END;
GO

-- ============================================================================
-- PROCEDURE 16: DeterministicFunctionInWhere (SR0015)
-- Violations: Deterministic function call in WHERE that could be extracted
-- ============================================================================
CREATE PROCEDURE DeterministicFunctionInWhere
    @DaysBack INT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- SR0015: GETDATE() is called for every row comparison
    -- Should extract to a variable
    SELECT OrderID, OrderDate, TotalAmount
    FROM Orders
    WHERE OrderDate > DATEADD(DAY, -@DaysBack, GETDATE())  -- GETDATE called per row
      AND CreatedDate > DATEADD(MONTH, -1, GETDATE());     -- GETDATE called again per row
END;
GO

-- ============================================================================
-- PROCEDURE 17: ColumnOnBothSidesOfOperator (SR0006)
-- Violations: Column reference on both sides of comparison
-- ============================================================================
CREATE PROCEDURE ColumnOnBothSidesOfOperator
    @Multiplier INT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- SR0006: Column arithmetic on left side prevents index usage
    SELECT OrderID, TotalAmount, Quantity
    FROM Orders
    WHERE TotalAmount / Quantity > 100           -- Move column to one side
      AND TotalAmount - DiscountAmount > 500     -- Column math prevents index
      AND Quantity * @Multiplier = 1000;         -- Could be rewritten as Quantity = 1000/@Multiplier
END;
GO
