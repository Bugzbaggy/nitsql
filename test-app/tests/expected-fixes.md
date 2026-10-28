# Expected Fixes for Test Application (Multi-Dialect)

This document describes the expected fixes for each violation across all four supported SQL dialects.

---

## MSSQL (SQL Server 2019+) - bad_procedures.sql

### GetCustomerOrders (SA0001: SELECT *, missing SET NOCOUNT ON)
**Before:**
```sql
CREATE PROCEDURE GetCustomerOrders
    @CustomerID INT
AS
BEGIN
    SELECT * FROM Orders WHERE CustomerID = @CustomerID;
END;
```

**After:**
```sql
CREATE PROCEDURE dbo.GetCustomerOrders
    @CustomerID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT OrderID, CustomerID, OrderDate, TotalAmount, Status
    FROM dbo.Orders
    WHERE CustomerID = @CustomerID;
END;
```

### SearchProducts (SA0002: SQL Injection)
**Before:**
```sql
SET @SQL = N'SELECT * FROM Products WHERE ProductName LIKE ''%' + @SearchTerm + '%''';
EXEC(@SQL);
```

**After:**
```sql
SET @SQL = N'SELECT ProductID, ProductName, Price, CategoryID
             FROM dbo.Products
             WHERE ProductName LIKE @SearchPattern';
SET @Params = N'@SearchPattern NVARCHAR(102)';
EXEC sp_executesql @SQL, @Params,
    @SearchPattern = N'%' + @SearchTerm + N'%';
```

### UpdateOrderStatuses (SA0007: Cursor to Set-based)
**Before:**
```sql
DECLARE order_cursor CURSOR FOR ...
WHILE @@FETCH_STATUS = 0
BEGIN
    UPDATE Orders SET Status = 'expired' WHERE OrderID = @OrderID;
END
```

**After:**
```sql
SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    UPDATE dbo.Orders
    SET Status = 'expired', LastModified = GETDATE()
    WHERE Status = 'pending'
      AND OrderDate < DATEADD(DAY, -30, GETDATE());

    INSERT INTO dbo.OrderHistory (OrderID, OldStatus, NewStatus, ChangedDate)
    SELECT OrderID, 'pending', 'expired', GETDATE()
    FROM dbo.Orders WHERE Status = 'expired';

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH
```

### GetReportData (SA0003: Non-SARGable)
**Before:**
```sql
WHERE YEAR(o.OrderDate) = @Year
  AND MONTH(o.OrderDate) = @Month
```

**After:**
```sql
DECLARE @StartDate DATE = DATEFROMPARTS(@Year, @Month, 1);
DECLARE @EndDate DATE = DATEADD(MONTH, 1, @StartDate);

WHERE o.OrderDate >= @StartDate
  AND o.OrderDate < @EndDate
```

---

## PostgreSQL - bad_procedures_postgresql.sql

### get_customer_orders (SA0001: SELECT *, SA0008: No schema qualifier)
**Before:**
```sql
CREATE OR REPLACE FUNCTION get_customer_orders(p_customer_id INTEGER)
RETURNS SETOF RECORD AS $$
BEGIN
    RETURN QUERY SELECT * FROM orders WHERE customer_id = p_customer_id;
END;
$$ LANGUAGE plpgsql;
```

**After:**
```sql
CREATE OR REPLACE FUNCTION public.get_customer_orders(p_customer_id INTEGER)
RETURNS TABLE (
    order_id INTEGER,
    customer_id INTEGER,
    order_date TIMESTAMP,
    total_amount NUMERIC,
    status TEXT
) AS $$
BEGIN
    RETURN QUERY
        SELECT o.order_id, o.customer_id, o.order_date, o.total_amount, o.status
        FROM public.orders o
        WHERE o.customer_id = p_customer_id;
END;
$$ LANGUAGE plpgsql;
```

### search_products (SA0002: SQL Injection via EXECUTE without USING)
**Before:**
```sql
RETURN QUERY EXECUTE 'SELECT * FROM products WHERE product_name = ''' || p_name || '''';
```

**After:**
```sql
RETURN QUERY EXECUTE
    'SELECT product_id, product_name, price, category_id
     FROM public.products WHERE product_name = $1'
    USING p_name;
```

### get_orders_by_year (SA0003: Non-SARGable EXTRACT)
**Before:**
```sql
WHERE EXTRACT(YEAR FROM order_date) = p_year
```

**After:**
```sql
WHERE order_date >= make_date(p_year, 1, 1)::timestamp
  AND order_date < make_date(p_year + 1, 1, 1)::timestamp
```

### find_customers_by_name (SA0004: Leading Wildcard ILIKE)
**Before:**
```sql
WHERE customer_name ILIKE '%' || p_search
```

**After:**
```sql
-- Use pg_trgm extension for trigram index support
WHERE customer_name ILIKE '%' || p_search
-- With: CREATE INDEX idx_customers_name_trgm ON customers USING gin (customer_name gin_trgm_ops);
```

### customer_has_orders (SA0005: COUNT > 0 instead of EXISTS)
**Before:**
```sql
SELECT COUNT(*) INTO v_count FROM orders WHERE customer_id = p_customer_id;
RETURN v_count > 0;
```

**After:**
```sql
RETURN EXISTS (SELECT 1 FROM orders WHERE customer_id = p_customer_id);
```

### insert_order_quick (SA0006: INSERT without column list)
**Before:**
```sql
INSERT INTO orders VALUES (DEFAULT, p_customer_id, now(), 'pending', p_total, 0.00, NULL, now());
```

**After:**
```sql
INSERT INTO public.orders (customer_id, order_date, status, total_amount, shipping_cost, last_modified)
VALUES (p_customer_id, now(), 'pending', p_total, 0.00, now());
```

### expire_old_orders (SA0007: Cursor Loop to Set-based)
**Before:**
```sql
OPEN cur_orders;
LOOP
    FETCH cur_orders INTO v_order;
    EXIT WHEN NOT FOUND;
    UPDATE orders SET status = 'expired' WHERE order_id = v_order.order_id;
    ...
END LOOP;
```

**After:**
```sql
WITH expired AS (
    UPDATE public.orders
    SET status = 'expired', last_modified = now()
    WHERE status = 'pending'
      AND order_date < now() - INTERVAL '30 days'
    RETURNING order_id, 'pending' AS old_status
)
INSERT INTO public.order_history (order_id, old_status, new_status, changed_date)
SELECT order_id, old_status, 'expired', now()
FROM expired;
```

### admin_get_all_users (SA-PG004: SECURITY DEFINER without search_path)
**Before:**
```sql
CREATE OR REPLACE FUNCTION admin_get_all_users()
RETURNS SETOF RECORD
SECURITY DEFINER
AS $$ ...
```

**After:**
```sql
CREATE OR REPLACE FUNCTION public.admin_get_all_users()
RETURNS TABLE (customer_id INTEGER, customer_name TEXT, email TEXT)
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$ ...
```

### Table Definitions (SA-PG001: SERIAL, SA-PG002: VARCHAR(255))
**Before:**
```sql
CREATE TABLE orders (
    order_id SERIAL PRIMARY KEY,
    status VARCHAR(255),
    ...
);
```

**After:**
```sql
CREATE TABLE public.orders (
    order_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    status TEXT,
    ...
);
```

---

## Oracle (PL/SQL) - bad_procedures_oracle.sql

### get_customer_orders (SA0001: SELECT *, SA-ORA001: WHEN OTHERS THEN NULL)
**Before:**
```sql
OPEN p_cursor FOR SELECT * FROM orders WHERE customer_id = p_customer_id;
EXCEPTION
    WHEN OTHERS THEN NULL;
```

**After:**
```sql
OPEN p_cursor FOR
    SELECT order_id, customer_id, order_date, total_amount, status
    FROM orders
    WHERE customer_id = p_customer_id;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error in get_customer_orders: ' || SQLERRM);
        RAISE;
```

### search_products (SA0002: SQL Injection via EXECUTE IMMEDIATE ||)
**Before:**
```sql
v_sql := 'SELECT * FROM products WHERE product_name = ''' || p_name || '''';
EXECUTE IMMEDIATE v_sql;
```

**After:**
```sql
v_sql := 'SELECT product_id, product_name, price, category_id
           FROM products WHERE product_name = :1';
OPEN v_cursor FOR v_sql USING p_name;
```

### get_orders_by_year (SA0003: Non-SARGable TO_CHAR)
**Before:**
```sql
WHERE TO_CHAR(order_date, 'YYYY') = TO_CHAR(p_year)
```

**After:**
```sql
WHERE order_date >= TO_DATE(TO_CHAR(p_year) || '-01-01', 'YYYY-MM-DD')
  AND order_date < TO_DATE(TO_CHAR(p_year + 1) || '-01-01', 'YYYY-MM-DD')
```

### find_customer_by_email (SA-ORA004: SELECT INTO without NO_DATA_FOUND)
**Before:**
```sql
SELECT customer_id, customer_name INTO p_customer_id, p_name
FROM customers WHERE email = p_email;
-- No EXCEPTION block!
```

**After:**
```sql
BEGIN
    SELECT customer_id, customer_name INTO p_customer_id, p_name
    FROM customers WHERE email = p_email;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_customer_id := NULL;
        p_name := NULL;
    WHEN TOO_MANY_ROWS THEN
        RAISE_APPLICATION_ERROR(-20001, 'Multiple customers found for email: ' || p_email);
END;
```

### create_customer (SA-ORA002: VARCHAR, SA-ORA005: LONG)
**Before:**
```sql
CREATE OR REPLACE PROCEDURE create_customer(
    p_name  IN VARCHAR,
    p_notes IN LONG
) AS
```

**After:**
```sql
CREATE OR REPLACE PROCEDURE create_customer(
    p_name  IN VARCHAR2,
    p_notes IN CLOB
) AS
```

### expire_old_orders (Cursor FOR Loop to Set-based)
**Before:**
```sql
FOR rec IN (SELECT order_id, status FROM orders WHERE ...) LOOP
    UPDATE orders SET status = 'expired' WHERE order_id = rec.order_id;
END LOOP;
```

**After:**
```sql
UPDATE orders
SET status = 'expired', last_modified = SYSDATE
WHERE status = 'pending'
  AND order_date < SYSDATE - 30;

INSERT INTO order_history (order_id, old_status, new_status, changed_date)
SELECT order_id, 'pending', 'expired', SYSDATE
FROM orders
WHERE status = 'expired'
  AND last_modified >= TRUNC(SYSDATE);

COMMIT;
```

### process_payment (Missing ROLLBACK, SA-ORA001)
**Before:**
```sql
BEGIN
    UPDATE orders SET status = 'processing' ...;
    INSERT INTO order_history ...;
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN NULL;
END;
```

**After:**
```sql
BEGIN
    SAVEPOINT before_payment;

    UPDATE orders SET status = 'processing' ...;
    INSERT INTO order_history ...;
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK TO before_payment;
        DBMS_OUTPUT.PUT_LINE('Payment error: ' || SQLERRM);
        RAISE;
END;
```

---

## MySQL - bad_procedures_mysql.sql

### get_customer_orders (SA0001: SELECT *, SA0002: SQL Injection)
**Before:**
```sql
SET @sql = CONCAT('SELECT * FROM orders WHERE customer_id = ', p_customer_id);
PREPARE stmt FROM @sql;
EXECUTE stmt;
```

**After:**
```sql
SELECT order_id, customer_id, order_date, total_amount, status
FROM orders
WHERE customer_id = p_customer_id;
-- No dynamic SQL needed for simple queries!
```

### search_products (SA0002: SQL Injection via CONCAT)
**Before:**
```sql
SET @sql = CONCAT('SELECT * FROM products WHERE product_name = ''', p_name, '''');
PREPARE stmt FROM @sql;
EXECUTE stmt;
```

**After:**
```sql
SET @sql = 'SELECT product_id, product_name, price, category_id
            FROM products WHERE product_name = ?';
PREPARE stmt FROM @sql;
SET @p_name = p_name;
EXECUTE stmt USING @p_name;
DEALLOCATE PREPARE stmt;
```

### get_orders_by_year (SA0003: Non-SARGable YEAR())
**Before:**
```sql
WHERE YEAR(order_date) = p_year
  AND MONTH(order_date) >= 1
```

**After:**
```sql
SET @start_date = CONCAT(p_year, '-01-01');
SET @end_date = CONCAT(p_year + 1, '-01-01');

WHERE order_date >= @start_date
  AND order_date < @end_date
```

### customer_has_orders (SA0005: COUNT > 0 instead of EXISTS)
**Before:**
```sql
SELECT COUNT(*) INTO v_count FROM orders WHERE customer_id = p_customer_id;
IF v_count > 0 THEN ...
```

**After:**
```sql
SET p_has_orders = EXISTS (SELECT 1 FROM orders WHERE customer_id = p_customer_id);
```

### expire_old_orders (SA0007: Cursor Loop to Set-based)
**Before:**
```sql
OPEN cur_orders;
read_loop: LOOP
    FETCH cur_orders INTO v_order_id, v_status;
    IF v_done THEN LEAVE read_loop; END IF;
    UPDATE orders SET status = 'expired' WHERE order_id = v_order_id;
END LOOP;
```

**After:**
```sql
DECLARE EXIT HANDLER FOR SQLEXCEPTION
BEGIN
    ROLLBACK;
    RESIGNAL;
END;

START TRANSACTION;

UPDATE orders
SET status = 'expired', last_modified = NOW()
WHERE status = 'pending'
  AND order_date < DATE_SUB(NOW(), INTERVAL 30 DAY);

INSERT INTO order_history (order_id, old_status, new_status, changed_date)
SELECT order_id, 'pending', 'expired', NOW()
FROM orders
WHERE status = 'expired'
  AND last_modified >= CURDATE();

COMMIT;
```

### Table Definitions (SA-MY001: MyISAM, SA-MY002: FLOAT, SA-MY004: ENUM)
**Before:**
```sql
CREATE TABLE orders (
    ...
    status ENUM('pending', 'processing', 'shipped', 'delivered', 'expired'),
    total_amount FLOAT,
    shipping_cost FLOAT,
    ...
) ENGINE=MyISAM;
```

**After:**
```sql
CREATE TABLE orders (
    ...
    status_id TINYINT NOT NULL DEFAULT 1,  -- FK to order_statuses lookup table
    total_amount DECIMAL(10,2),
    shipping_cost DECIMAL(10,2),
    ...
    CONSTRAINT fk_order_status FOREIGN KEY (status_id) REFERENCES order_statuses(id)
) ENGINE=InnoDB;

CREATE TABLE order_statuses (
    id TINYINT PRIMARY KEY,
    status_name VARCHAR(50) NOT NULL UNIQUE
);
```

### process_payment (No Transaction, No Error Handler)
**Before:**
```sql
BEGIN
    UPDATE orders SET status = 'processing' ...;
    INSERT INTO order_history ...;
    -- If second fails, first is auto-committed
END
```

**After:**
```sql
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    UPDATE orders SET status = 'processing' ...;
    INSERT INTO order_history ...;

    COMMIT;
END
```

---

## Validation Criteria (All Dialects)

For each fix, validate:

1. SQL injection removed -- parameterized queries or bind variables used
2. Explicit column lists -- no SELECT *
3. SARGable predicates -- no functions on indexed columns in WHERE
4. No leading wildcards without trigram/full-text index support
5. EXISTS instead of COUNT(*) > 0 for existence checks
6. INSERT always includes explicit column list
7. Set-based operations instead of cursor/row-by-row loops
8. Proper error/exception handling per dialect
9. Transaction management with rollback on error
10. Schema-qualified object names

### Dialect-Specific Checks

| Check | MSSQL | PostgreSQL | Oracle | MySQL |
|-------|-------|------------|--------|-------|
| Error handling | TRY-CATCH | EXCEPTION block | EXCEPTION block | DECLARE HANDLER |
| Parameterized SQL | sp_executesql | EXECUTE...USING | EXECUTE IMMEDIATE...USING | PREPARE...USING |
| Identity columns | IDENTITY | GENERATED AS IDENTITY | SEQUENCE | AUTO_INCREMENT |
| String type | NVARCHAR | TEXT | VARCHAR2 | VARCHAR |
| Transaction | BEGIN TRY/BEGIN TRAN | implicit (function) | COMMIT/ROLLBACK | START TRANSACTION |
| No deprecated types | TEXT->VARCHAR(MAX) | SERIAL->IDENTITY | LONG->CLOB, VARCHAR->VARCHAR2 | MyISAM->InnoDB, FLOAT->DECIMAL |
