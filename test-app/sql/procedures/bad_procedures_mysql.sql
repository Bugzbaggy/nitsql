-- ============================================================================
-- BAD_PROCEDURES_MYSQL.SQL
-- This file contains MySQL stored procedures with INTENTIONAL violations
-- Use this to test if the skill can identify and fix these issues
-- Target: MySQL 8.0+
-- ============================================================================

-- Violations Summary:
-- CRITICAL: SELECT * usage (SA0001)
-- CRITICAL: SQL injection via CONCAT in PREPARE (SA0002)
-- HIGH: Non-SARGable WHERE YEAR(date_col) (SA0003)
-- HIGH: Leading wildcard LIKE '%value' (SA0004)
-- HIGH: COUNT(*) > 0 instead of EXISTS (SA0005)
-- HIGH: INSERT without column list (SA0006)
-- HIGH: Cursor loop instead of set-based UPDATE (SA0007)
-- MEDIUM: MyISAM engine instead of InnoDB (SA-MY001)
-- MEDIUM: FLOAT for currency values (SA-MY002)
-- MEDIUM: ENUM for changeable values (SA-MY004)
-- MEDIUM: Missing error handler (DECLARE ... HANDLER)
-- MEDIUM: No START TRANSACTION around multi-statement updates
-- LOW: Unnecessary backtick quoting of regular identifiers

-- ============================================================================
-- TABLE SETUP (with violations)
-- Violations: SA-MY001 (MyISAM), SA-MY002 (FLOAT for money), SA-MY004 (ENUM)
-- ============================================================================

CREATE TABLE IF NOT EXISTS orders (
    order_id INT AUTO_INCREMENT PRIMARY KEY,
    customer_id INT NOT NULL,
    order_date DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status ENUM('pending', 'processing', 'shipped', 'delivered', 'expired'),  -- SA-MY004: ENUM for changeable values
    total_amount FLOAT,                    -- SA-MY002: FLOAT for currency - use DECIMAL
    shipping_cost FLOAT,                   -- SA-MY002: FLOAT for currency
    notes TEXT,
    last_modified DATETIME,
    INDEX idx_customer (customer_id),
    INDEX idx_date (order_date)
) ENGINE=MyISAM;                           -- SA-MY001: MyISAM instead of InnoDB

CREATE TABLE IF NOT EXISTS customers (
    customer_id INT AUTO_INCREMENT PRIMARY KEY,
    customer_name VARCHAR(255) NOT NULL,
    email VARCHAR(255),
    phone VARCHAR(50),
    is_active TINYINT(1) DEFAULT 1
) ENGINE=MyISAM;                           -- SA-MY001: MyISAM instead of InnoDB

CREATE TABLE IF NOT EXISTS order_history (
    history_id INT AUTO_INCREMENT PRIMARY KEY,
    order_id INT NOT NULL,
    old_status VARCHAR(50),
    new_status VARCHAR(50),
    changed_date DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=MyISAM;                           -- SA-MY001: MyISAM instead of InnoDB

CREATE TABLE IF NOT EXISTS products (
    product_id INT AUTO_INCREMENT PRIMARY KEY,
    product_name VARCHAR(255) NOT NULL,
    price FLOAT,                           -- SA-MY002: FLOAT for currency
    category_id INT,
    product_type ENUM('physical', 'digital', 'subscription')  -- SA-MY004: ENUM
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS order_totals (
    id INT AUTO_INCREMENT PRIMARY KEY,
    order_id INT NOT NULL,
    total FLOAT,                           -- SA-MY002: FLOAT for currency
    tax FLOAT,                             -- SA-MY002: FLOAT for currency
    discount FLOAT                         -- SA-MY002: FLOAT for currency
) ENGINE=MyISAM;                           -- SA-MY001: MyISAM

DELIMITER //

-- ============================================================================
-- PROCEDURE 1: get_customer_orders
-- Violations: SA0001 (SELECT *), SA0002 (SQL injection via CONCAT + PREPARE)
-- ============================================================================
CREATE PROCEDURE get_customer_orders(IN p_customer_id INT)
BEGIN
    -- SA0002: SQL injection - CONCAT with user input in PREPARE
    SET @sql = CONCAT('SELECT * FROM orders WHERE customer_id = ', p_customer_id);
    PREPARE stmt FROM @sql;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
END //

-- ============================================================================
-- PROCEDURE 2: search_products (SQL INJECTION)
-- Violations: SA0002 (SQL injection), SA0001 (SELECT *)
-- ============================================================================
CREATE PROCEDURE search_products(IN p_name VARCHAR(255))
BEGIN
    -- SA0002: SQL injection - concatenating user input
    -- SA0001: SELECT *
    SET @sql = CONCAT('SELECT * FROM products WHERE product_name = ''', p_name, '''');
    PREPARE stmt FROM @sql;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
END //

-- ============================================================================
-- PROCEDURE 3: get_orders_by_year (NON-SARGABLE)
-- Violations: SA0003 (non-SARGable YEAR() on column)
-- ============================================================================
CREATE PROCEDURE get_orders_by_year(IN p_year INT)
BEGIN
    -- SA0003: Non-SARGable - YEAR() function on column prevents index usage
    SELECT `order_id`, `customer_id`, `order_date`, `total_amount`
    FROM `orders`                          -- Unnecessary backtick quoting
    WHERE YEAR(`order_date`) = p_year      -- Non-SARGable!
      AND MONTH(`order_date`) >= 1;        -- Non-SARGable!
END //

-- ============================================================================
-- PROCEDURE 4: find_customers_by_name (LEADING WILDCARD)
-- Violations: SA0004 (leading wildcard), SA0001 (SELECT *)
-- ============================================================================
CREATE PROCEDURE find_customers_by_name(IN p_search VARCHAR(255))
BEGIN
    -- SA0004: Leading wildcard prevents index usage
    -- SA0001: SELECT *
    SELECT *
    FROM customers
    WHERE customer_name LIKE CONCAT('%', p_search);
END //

-- ============================================================================
-- PROCEDURE 5: customer_has_orders (COUNT > 0 instead of EXISTS)
-- Violations: SA0005 (COUNT(*) > 0 instead of EXISTS)
-- ============================================================================
CREATE PROCEDURE customer_has_orders(
    IN p_customer_id INT,
    OUT p_has_orders TINYINT
)
BEGIN
    DECLARE v_count INT;

    -- SA0005: COUNT(*) > 0 instead of EXISTS
    SELECT COUNT(*) INTO v_count
    FROM orders
    WHERE customer_id = p_customer_id;

    IF v_count > 0 THEN
        SET p_has_orders = 1;
    ELSE
        SET p_has_orders = 0;
    END IF;
END //

-- ============================================================================
-- PROCEDURE 6: insert_order_quick (INSERT without column list)
-- Violations: SA0006 (INSERT without column list)
-- ============================================================================
CREATE PROCEDURE insert_order_quick(
    IN p_customer_id INT,
    IN p_total FLOAT                       -- SA-MY002: FLOAT parameter for money
)
BEGIN
    -- SA0006: INSERT without explicit column list
    INSERT INTO orders VALUES (NULL, p_customer_id, NOW(), 'pending', p_total, 0.00, NULL, NOW());
END //

-- ============================================================================
-- PROCEDURE 7: expire_old_orders (CURSOR loop)
-- Violations: SA0007 (cursor loop instead of set-based UPDATE),
--             Missing error handler, no transaction
-- ============================================================================
CREATE PROCEDURE expire_old_orders()
BEGIN
    DECLARE v_order_id INT;
    DECLARE v_status VARCHAR(50);
    DECLARE v_done INT DEFAULT FALSE;
    DECLARE cur_orders CURSOR FOR
        SELECT order_id, status
        FROM orders
        WHERE status = 'pending'
          AND order_date < DATE_SUB(NOW(), INTERVAL 30 DAY);
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = TRUE;

    -- No DECLARE ... HANDLER FOR SQLEXCEPTION (missing error handler)
    -- No START TRANSACTION

    -- SA0007: Cursor loop instead of single set-based UPDATE
    OPEN cur_orders;
    read_loop: LOOP
        FETCH cur_orders INTO v_order_id, v_status;
        IF v_done THEN
            LEAVE read_loop;
        END IF;

        -- Individual UPDATE per row
        UPDATE orders
        SET status = 'expired',
            last_modified = NOW()
        WHERE order_id = v_order_id;

        -- Individual INSERT per row
        INSERT INTO order_history (order_id, old_status, new_status, changed_date)
        VALUES (v_order_id, v_status, 'expired', NOW());
    END LOOP;
    CLOSE cur_orders;

    -- No COMMIT/ROLLBACK
END //

-- ============================================================================
-- PROCEDURE 8: get_report_data (Multiple non-SARGable + leading wildcard)
-- Violations: SA0003 (non-SARGable), SA0004 (leading wildcard)
-- ============================================================================
CREATE PROCEDURE get_report_data(
    IN p_year INT,
    IN p_month INT,
    IN p_search VARCHAR(255)
)
BEGIN
    -- SA0003: Non-SARGable - YEAR() and MONTH() on columns
    -- SA0004: Leading wildcard on LIKE
    SELECT o.order_id, o.order_date, o.total_amount, c.customer_name
    FROM orders o
    INNER JOIN customers c ON o.customer_id = c.customer_id
    WHERE YEAR(o.order_date) = p_year
      AND MONTH(o.order_date) = p_month
      AND c.email LIKE CONCAT('%', p_search, '%');
END //

-- ============================================================================
-- PROCEDURE 9: process_payment (No transaction, no error handler)
-- Violations: No START TRANSACTION, no DECLARE HANDLER for errors
-- ============================================================================
CREATE PROCEDURE process_payment(
    IN p_order_id INT,
    IN p_payment_amount FLOAT,             -- SA-MY002: FLOAT for money
    IN p_payment_method VARCHAR(50)
)
BEGIN
    -- No START TRANSACTION around multi-statement DML
    -- No DECLARE ... HANDLER FOR SQLEXCEPTION

    UPDATE orders
    SET status = 'processing',
        last_modified = NOW()
    WHERE order_id = p_order_id;

    INSERT INTO order_history (order_id, old_status, new_status, changed_date)
    VALUES (p_order_id, 'pending', 'processing', NOW());

    -- If second statement fails, first is already committed (autocommit)
END //

-- ============================================================================
-- PROCEDURE 10: dynamic_search (SQL injection + SELECT *)
-- Violations: SA0002 (SQL injection), SA0001 (SELECT *)
-- ============================================================================
CREATE PROCEDURE dynamic_search(
    IN p_table_name VARCHAR(255),
    IN p_filter VARCHAR(1000)
)
BEGIN
    -- SA0002: SQL injection - user controls table and filter
    -- SA0001: SELECT *
    SET @sql = CONCAT('SELECT * FROM ', p_table_name, ' WHERE ', p_filter);
    PREPARE stmt FROM @sql;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
END //

-- ============================================================================
-- PROCEDURE 11: update_prices_bad (Cursor + FLOAT arithmetic)
-- Violations: SA0007 (cursor loop), SA-MY002 (FLOAT arithmetic for money)
-- ============================================================================
CREATE PROCEDURE update_prices_bad(IN p_increase_pct FLOAT)
BEGIN
    DECLARE v_product_id INT;
    DECLARE v_price FLOAT;                 -- SA-MY002: FLOAT for money
    DECLARE v_done INT DEFAULT FALSE;
    DECLARE cur_products CURSOR FOR
        SELECT product_id, price FROM products;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = TRUE;

    -- SA0007: Cursor loop instead of single UPDATE
    OPEN cur_products;
    price_loop: LOOP
        FETCH cur_products INTO v_product_id, v_price;
        IF v_done THEN
            LEAVE price_loop;
        END IF;

        -- FLOAT arithmetic causes rounding errors for money!
        UPDATE products
        SET price = v_price * (1 + p_increase_pct / 100)
        WHERE product_id = v_product_id;
    END LOOP;
    CLOSE cur_products;
END //

-- ============================================================================
-- PROCEDURE 12: bulk_insert_no_transaction (Missing transaction + error handler)
-- Violations: No transaction, no error handler, INSERT without column list
-- ============================================================================
CREATE PROCEDURE bulk_insert_no_transaction(
    IN p_customer_id INT,
    IN p_count INT
)
BEGIN
    DECLARE v_i INT DEFAULT 0;

    -- No START TRANSACTION
    -- No DECLARE ... HANDLER FOR SQLEXCEPTION
    WHILE v_i < p_count DO
        -- SA0006: INSERT without column list
        INSERT INTO orders
        VALUES (NULL, p_customer_id, NOW(), 'pending', ROUND(RAND() * 1000, 2), 0.00, NULL, NOW());

        SET v_i = v_i + 1;
    END WHILE;
    -- No COMMIT - relies on autocommit
END //

-- ============================================================================
-- PROCEDURE 13: get_all_data_bad (SELECT * on multiple tables)
-- Violations: SA0001 (SELECT * everywhere), unnecessary backticks
-- ============================================================================
CREATE PROCEDURE get_all_data_bad()
BEGIN
    -- SA0001: SELECT * on every table, unnecessary backtick quoting
    SELECT * FROM `orders`;
    SELECT * FROM `customers`;
    SELECT * FROM `products`;
    SELECT * FROM `order_history`;
END //

DELIMITER ;
