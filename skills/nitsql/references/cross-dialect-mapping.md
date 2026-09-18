# Cross-Dialect SQL Feature Mapping

A comprehensive reference for translating SQL patterns between MSSQL, PostgreSQL, Oracle, and MySQL. Use this when migrating code, writing cross-platform applications, or reviewing SQL from an unfamiliar dialect.

## Parameter Placeholders

| Context | MSSQL | PostgreSQL | Oracle | MySQL |
|---------|-------|-----------|--------|-------|
| Native SQL | `@param` | `$1`, `$2` | `:param` | `?` |
| Python driver | `?` (pyodbc) | `%s` (psycopg2) | `:param` (oracledb) | `%s` (pymysql) |
| Node.js driver | `@param` (mssql) | `$1` (pg) | `:param` (oracledb) | `?` (mysql2) |
| .NET driver | `@param` (SqlClient) | `@param` (Npgsql) | `:param` (ODP.NET) | `@param` (MySqlConnector) |
| SQLAlchemy | `:param` | `:param` | `:param` | `:param` |

### Example: Same Query in All Dialects

**MSSQL (pyodbc)**
```python
cursor.execute("SELECT * FROM Users WHERE UserID = ? AND Status = ?", user_id, status)
```

**PostgreSQL (psycopg2)**
```python
cursor.execute("SELECT * FROM users WHERE user_id = %s AND status = %s", (user_id, status))
```

**Oracle (oracledb)**
```python
cursor.execute("SELECT * FROM users WHERE user_id = :id AND status = :status", {"id": user_id, "status": status})
```

**MySQL (pymysql)**
```python
cursor.execute("SELECT * FROM users WHERE user_id = %s AND status = %s", (user_id, status))
```

## Auto-Generated Keys

| Feature | MSSQL | PostgreSQL | Oracle | MySQL |
|---------|-------|-----------|--------|-------|
| Auto-increment | `IDENTITY(1,1)` | `GENERATED ALWAYS AS IDENTITY` | `GENERATED ALWAYS AS IDENTITY` (12c+) | `AUTO_INCREMENT` |
| Legacy auto-inc | N/A | `SERIAL` | Sequence + trigger | N/A |
| Get last ID | `SCOPE_IDENTITY()` | `RETURNING id` | `RETURNING id INTO :var` | `LAST_INSERT_ID()` |
| Sequences | `CREATE SEQUENCE` | `CREATE SEQUENCE` | `CREATE SEQUENCE` | N/A (table-based workaround) |
| Sequence usage | `NEXT VALUE FOR seq` | `nextval('seq')` | `seq.NEXTVAL` | N/A |

### Example: Insert and Retrieve ID

**MSSQL**
```sql
INSERT INTO dbo.Orders (CustomerID) VALUES (42);
SELECT SCOPE_IDENTITY() AS NewID;
-- Or use OUTPUT clause:
INSERT INTO dbo.Orders (CustomerID) OUTPUT inserted.OrderID VALUES (42);
```

**PostgreSQL**
```sql
INSERT INTO app.orders (customer_id) VALUES (42) RETURNING order_id;
```

**Oracle**
```sql
INSERT INTO app_schema.orders (customer_id) VALUES (42)
RETURNING order_id INTO :new_id;
```

**MySQL**
```sql
INSERT INTO app_db.orders (customer_id) VALUES (42);
SELECT LAST_INSERT_ID();
```

## String Functions

| Operation | MSSQL | PostgreSQL | Oracle | MySQL |
|-----------|-------|-----------|--------|-------|
| Concatenate | `+` or `CONCAT()` | `\|\|` or `CONCAT()` | `\|\|` or `CONCAT()` | `CONCAT()` (only) |
| Length | `LEN()` | `LENGTH()` | `LENGTH()` | `CHAR_LENGTH()` |
| Byte length | `DATALENGTH()` | `OCTET_LENGTH()` | `LENGTHB()` | `LENGTH()` |
| Substring | `SUBSTRING(s,start,len)` | `SUBSTRING(s,start,len)` | `SUBSTR(s,start,len)` | `SUBSTRING(s,start,len)` |
| Left/Right | `LEFT(s,n)` / `RIGHT(s,n)` | `LEFT(s,n)` / `RIGHT(s,n)` | `SUBSTR(s,1,n)` / `SUBSTR(s,-n)` | `LEFT(s,n)` / `RIGHT(s,n)` |
| Trim | `TRIM()` (2017+) | `TRIM()` | `TRIM()` | `TRIM()` |
| LTrim/RTrim | `LTRIM()` / `RTRIM()` | `LTRIM()` / `RTRIM()` | `LTRIM()` / `RTRIM()` | `LTRIM()` / `RTRIM()` |
| Upper/Lower | `UPPER()` / `LOWER()` | `UPPER()` / `LOWER()` | `UPPER()` / `LOWER()` | `UPPER()` / `LOWER()` |
| Replace | `REPLACE(s,old,new)` | `REPLACE(s,old,new)` | `REPLACE(s,old,new)` | `REPLACE(s,old,new)` |
| Position | `CHARINDEX(sub,s)` | `POSITION(sub IN s)` | `INSTR(s,sub)` | `LOCATE(sub,s)` |
| String agg | `STRING_AGG()` (2017+) | `STRING_AGG()` | `LISTAGG()` | `GROUP_CONCAT()` |
| Repeat | `REPLICATE(s,n)` | `REPEAT(s,n)` | `RPAD('',n,s)` | `REPEAT(s,n)` |
| Reverse | `REVERSE()` | `REVERSE()` | `REVERSE()` | `REVERSE()` |
| Pad | `FORMAT()` or manual | `LPAD()` / `RPAD()` | `LPAD()` / `RPAD()` | `LPAD()` / `RPAD()` |

## NULL Handling

| Operation | MSSQL | PostgreSQL | Oracle | MySQL |
|-----------|-------|-----------|--------|-------|
| Replace NULL | `ISNULL(a,b)` | `COALESCE(a,b)` | `NVL(a,b)` | `IFNULL(a,b)` or `COALESCE(a,b)` |
| Multi-arg coalesce | `COALESCE(a,b,c)` | `COALESCE(a,b,c)` | `COALESCE(a,b,c)` | `COALESCE(a,b,c)` |
| NULL-safe equals | `IS NOT DISTINCT FROM` (2022) | `IS NOT DISTINCT FROM` | `DECODE(a,b,1,0)=1` | `<=>` |
| NULLIF | `NULLIF(a,b)` | `NULLIF(a,b)` | `NULLIF(a,b)` | `NULLIF(a,b)` |

### Cross-Dialect Recommendation
Always use `COALESCE()` — it is SQL standard and works across every dialect this reference covers (MSSQL, PostgreSQL, Oracle, MySQL) as well as SQLite.

## Date and Time Functions

| Operation | MSSQL | PostgreSQL | Oracle | MySQL |
|-----------|-------|-----------|--------|-------|
| Current timestamp | `SYSDATETIME()` | `NOW()` / `CURRENT_TIMESTAMP` | `SYSTIMESTAMP` | `NOW()` / `CURRENT_TIMESTAMP` |
| Current date | `CAST(GETDATE() AS DATE)` | `CURRENT_DATE` | `TRUNC(SYSDATE)` | `CURDATE()` |
| Date diff | `DATEDIFF(day,a,b)` | `a - b` (returns interval) | `a - b` (returns days) | `DATEDIFF(a,b)` (days only) |
| Date add | `DATEADD(day,n,d)` | `d + INTERVAL 'n days'` | `d + n` (days) or `ADD_MONTHS()` | `DATE_ADD(d, INTERVAL n DAY)` |
| Extract part | `DATEPART(year,d)` | `EXTRACT(YEAR FROM d)` | `EXTRACT(YEAR FROM d)` | `EXTRACT(YEAR FROM d)` |
| Format date | `FORMAT(d,'yyyy-MM-dd')` | `TO_CHAR(d,'YYYY-MM-DD')` | `TO_CHAR(d,'YYYY-MM-DD')` | `DATE_FORMAT(d,'%Y-%m-%d')` |
| Parse string to date | `CONVERT(DATE,'2024-01-15')` | `'2024-01-15'::DATE` | `TO_DATE('2024-01-15','YYYY-MM-DD')` | `STR_TO_DATE('2024-01-15','%Y-%m-%d')` |
| Truncate to day | `CAST(d AS DATE)` | `DATE_TRUNC('day',d)` | `TRUNC(d)` | `DATE(d)` |

## Pagination

| Approach | MSSQL | PostgreSQL | Oracle | MySQL |
|----------|-------|-----------|--------|-------|
| Standard | `OFFSET @skip ROWS FETCH NEXT @take ROWS ONLY` (2012+) | `LIMIT n OFFSET m` | `OFFSET n ROWS FETCH NEXT m ROWS ONLY` (12c+) | `LIMIT n OFFSET m` |
| Top N | `SELECT TOP N` | `LIMIT N` | `FETCH FIRST N ROWS ONLY` | `LIMIT N` |
| Legacy | `TOP + ROW_NUMBER()` | N/A | `WHERE ROWNUM <= N` (legacy) | N/A |

### Example: Page 3, 20 Rows Per Page

**MSSQL**
```sql
SELECT OrderID, CustomerID, OrderDate
FROM dbo.Orders
ORDER BY OrderDate DESC
OFFSET 40 ROWS FETCH NEXT 20 ROWS ONLY;
```

**PostgreSQL**
```sql
SELECT order_id, customer_id, order_date
FROM app.orders
ORDER BY order_date DESC
LIMIT 20 OFFSET 40;
```

**Oracle**
```sql
SELECT order_id, customer_id, order_date
FROM app_schema.orders
ORDER BY order_date DESC
OFFSET 40 ROWS FETCH NEXT 20 ROWS ONLY;
```

**MySQL**
```sql
SELECT order_id, customer_id, order_date
FROM app_db.orders
ORDER BY order_date DESC
LIMIT 20 OFFSET 40;
```

## Conditional Logic / UPSERT

| Feature | MSSQL | PostgreSQL | Oracle | MySQL |
|---------|-------|-----------|--------|-------|
| IF EXISTS check | `IF EXISTS (SELECT 1 ...)` | `IF EXISTS (SELECT 1 ...)` | PL/SQL only: `SELECT COUNT(*) INTO v` | `IF EXISTS (SELECT 1 ...)` |
| UPSERT | `MERGE` | `INSERT ... ON CONFLICT DO UPDATE` | `MERGE` | `INSERT ... ON DUPLICATE KEY UPDATE` |
| Conditional insert | `IF NOT EXISTS ... INSERT` | `INSERT ... ON CONFLICT DO NOTHING` | `MERGE WHEN NOT MATCHED` | `INSERT IGNORE` |
| IIF / ternary | `IIF(cond, true, false)` | N/A (use `CASE`) | N/A (use `CASE` or `DECODE`) | `IF(cond, true, false)` |
| CASE expression | `CASE WHEN ... THEN ... END` | `CASE WHEN ... THEN ... END` | `CASE WHEN ... THEN ... END` | `CASE WHEN ... THEN ... END` |

### Example: UPSERT

**MSSQL**
```sql
MERGE dbo.Inventory AS tgt
USING (SELECT @ProductID AS ProductID, @Quantity AS Quantity) AS src
ON tgt.ProductID = src.ProductID
WHEN MATCHED THEN UPDATE SET Quantity = src.Quantity
WHEN NOT MATCHED THEN INSERT (ProductID, Quantity) VALUES (src.ProductID, src.Quantity);
```

**PostgreSQL**
```sql
INSERT INTO app.inventory (product_id, quantity) VALUES (42, 100)
ON CONFLICT (product_id) DO UPDATE SET quantity = EXCLUDED.quantity;
```

**Oracle**
```sql
MERGE INTO app_schema.inventory tgt
USING (SELECT 42 AS product_id, 100 AS quantity FROM DUAL) src
ON (tgt.product_id = src.product_id)
WHEN MATCHED THEN UPDATE SET quantity = src.quantity
WHEN NOT MATCHED THEN INSERT (product_id, quantity) VALUES (src.product_id, src.quantity);
```

**MySQL**
```sql
INSERT INTO app_db.inventory (product_id, quantity) VALUES (42, 100)
ON DUPLICATE KEY UPDATE quantity = VALUES(quantity);
```

## Error Handling

| Feature | MSSQL | PostgreSQL | Oracle | MySQL |
|---------|-------|-----------|--------|-------|
| Try-catch | `BEGIN TRY...END TRY BEGIN CATCH...END CATCH` | `EXCEPTION WHEN...THEN` | `EXCEPTION WHEN...THEN` | `DECLARE HANDLER FOR` |
| Raise error | `THROW 50001, 'msg', 1` | `RAISE EXCEPTION 'msg'` | `RAISE_APPLICATION_ERROR(-20001, 'msg')` | `SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='msg'` |
| Re-raise | `THROW` (no args) | `RAISE` (no args) | `RAISE` (no args in handler) | `RESIGNAL` |
| Error code | `ERROR_NUMBER()` | `SQLSTATE` | `SQLCODE` | `GET DIAGNOSTICS CONDITION 1 @errno = MYSQL_ERRNO` |
| Error message | `ERROR_MESSAGE()` | `SQLERRM` | `SQLERRM` | `GET DIAGNOSTICS CONDITION 1 @msg = MESSAGE_TEXT` |
| Error line | `ERROR_LINE()` | (in context) | `DBMS_UTILITY.FORMAT_ERROR_BACKTRACE` | N/A |

## Transaction Control

| Feature | MSSQL | PostgreSQL | Oracle | MySQL |
|---------|-------|-----------|--------|-------|
| Begin | `BEGIN TRANSACTION` | `BEGIN` | (implicit) | `START TRANSACTION` |
| Commit | `COMMIT` | `COMMIT` | `COMMIT` | `COMMIT` |
| Rollback | `ROLLBACK` | `ROLLBACK` | `ROLLBACK` | `ROLLBACK` |
| Savepoint | `SAVE TRANSACTION name` | `SAVEPOINT name` | `SAVEPOINT name` | `SAVEPOINT name` |
| Rollback to SP | `ROLLBACK TRANSACTION name` | `ROLLBACK TO SAVEPOINT name` | `ROLLBACK TO SAVEPOINT name` | `ROLLBACK TO SAVEPOINT name` |
| Auto-abort on error | `SET XACT_ABORT ON` | Default behavior (aborts transaction) | DDL auto-commits | DDL auto-commits |
| Auto-commit | Off in transaction | Off in transaction | Always (implicit txns) | `SET autocommit=0` |
| DDL transactional | Yes | Yes | No (auto-commits) | No (auto-commits) |

### Critical Transaction Differences
- **MSSQL**: Must set `XACT_ABORT ON` for auto-rollback on timeout. DDL is transactional.
- **PostgreSQL**: Any error aborts the entire transaction (must use savepoints for partial recovery). DDL is transactional.
- **Oracle**: DDL causes implicit COMMIT. No explicit `BEGIN` statement. Transactions start with first DML.
- **MySQL**: DDL causes implicit COMMIT. Only InnoDB supports transactions (not MyISAM).

## Index Types

| Type | MSSQL | PostgreSQL | Oracle | MySQL |
|------|-------|-----------|--------|-------|
| Default | B-tree (clustered or NC) | B-tree | B-tree | B-tree (InnoDB) |
| Clustered data | Clustered index | `CLUSTER` command (one-time) | IOT (Index-Organized Table) | PRIMARY KEY (InnoDB auto-clusters) |
| Covering / Include | `INCLUDE (cols)` | `INCLUDE (cols)` (11+) | Composite only | PK auto-included in secondary |
| Partial / Filtered | `WHERE` clause | `WHERE` clause | Function-based workaround | N/A |
| Full-text | `FULLTEXT INDEX` | GIN + `tsvector` | Oracle Text | `FULLTEXT INDEX` |
| Expression | Computed column + index | Expression index | Function-based index | Functional index (8.0+) |
| JSON | Computed column + index | GIN on `jsonb` | JSON search index | Multi-valued index (8.0.17+) |
| Hash | N/A | Hash index | Hash cluster | N/A (InnoDB adaptive hash is internal) |
| Bitmap | N/A | N/A | Bitmap index | N/A |
| Spatial | Spatial index | GiST / SP-GiST | Spatial index (SDO_GEOMETRY) | Spatial index (R-tree) |
| BRIN | N/A | BRIN (large sequential data) | N/A | N/A |
| Invisible | N/A | N/A | Invisible index | Invisible index (8.0+) |

## Schema Qualification

| Dialect | Pattern | Default | Example |
|---------|---------|---------|---------|
| MSSQL | `database.schema.object` or `schema.object` | `dbo` | `dbo.Orders`, `MyDB.dbo.Orders` |
| PostgreSQL | `schema.object` | `public` | `public.orders`, `app.orders` |
| Oracle | `schema.object` | User's own schema | `HR.EMPLOYEES`, `APP_SCHEMA.ORDERS` |
| MySQL | `database.table` | Current database (`USE db`) | `app_db.orders` |

### Key Differences
- **MSSQL**: Has 3-part naming (`db.schema.table`). Cross-database queries are native.
- **PostgreSQL**: No cross-database queries (use foreign data wrappers). Schemas within a database.
- **Oracle**: Schema = user. Cross-schema access via grants. No cross-database without DB links.
- **MySQL**: Database = schema (they are synonyms). Cross-database queries are native.

## Data Type Mapping

| Concept | MSSQL | PostgreSQL | Oracle | MySQL |
|---------|-------|-----------|--------|-------|
| Tiny integer | `TINYINT` (0-255) | `SMALLINT` | `NUMBER(3)` | `TINYINT` |
| Small integer | `SMALLINT` | `SMALLINT` | `NUMBER(5)` | `SMALLINT` |
| Integer | `INT` | `INTEGER` | `NUMBER(10)` | `INT` |
| Big integer | `BIGINT` | `BIGINT` | `NUMBER(19)` | `BIGINT` |
| Decimal | `DECIMAL(p,s)` | `NUMERIC(p,s)` | `NUMBER(p,s)` | `DECIMAL(p,s)` |
| Float | `FLOAT` | `DOUBLE PRECISION` | `BINARY_DOUBLE` | `DOUBLE` |
| Money | `MONEY` / `DECIMAL(19,4)` | `NUMERIC(19,4)` | `NUMBER(19,4)` | `DECIMAL(19,4)` |
| Boolean | `BIT` | `BOOLEAN` | `NUMBER(1)` | `TINYINT(1)` / `BOOLEAN` |
| Variable string | `VARCHAR(n)` / `NVARCHAR(n)` | `VARCHAR(n)` / `TEXT` | `VARCHAR2(n)` | `VARCHAR(n)` |
| Fixed string | `CHAR(n)` / `NCHAR(n)` | `CHAR(n)` | `CHAR(n)` | `CHAR(n)` |
| Large text | `VARCHAR(MAX)` / `NVARCHAR(MAX)` | `TEXT` | `CLOB` | `LONGTEXT` |
| Binary | `VARBINARY(MAX)` | `BYTEA` | `BLOB` | `LONGBLOB` |
| Date only | `DATE` | `DATE` | `DATE` (includes time!) | `DATE` |
| Date + time | `DATETIME2` | `TIMESTAMP` | `TIMESTAMP` | `DATETIME` / `TIMESTAMP` |
| Date + time + TZ | `DATETIMEOFFSET` | `TIMESTAMPTZ` | `TIMESTAMP WITH TIME ZONE` | N/A (store as UTC) |
| Time only | `TIME` | `TIME` | `INTERVAL DAY TO SECOND` | `TIME` |
| UUID / GUID | `UNIQUEIDENTIFIER` | `UUID` | `RAW(16)` | `CHAR(36)` or `BINARY(16)` |
| JSON | `NVARCHAR(MAX)` + JSON functions | `JSONB` (preferred) / `JSON` | `JSON` (21c+) / `CLOB` | `JSON` |
| XML | `XML` | `XML` | `XMLTYPE` | N/A (use `TEXT`) |
| Auto-increment | `INT IDENTITY(1,1)` | `INT GENERATED ALWAYS AS IDENTITY` | `NUMBER GENERATED ALWAYS AS IDENTITY` | `INT AUTO_INCREMENT` |
| Interval | N/A | `INTERVAL` | `INTERVAL YEAR TO MONTH` / `INTERVAL DAY TO SECOND` | N/A |
| Array | N/A | `INTEGER[]`, `TEXT[]` | `VARRAY` / nested table | N/A (use JSON) |
| Enum | N/A (use CHECK) | `CREATE TYPE ... AS ENUM` | N/A (use CHECK) | `ENUM('a','b','c')` |

### Important Type Gotchas
- **Oracle DATE includes time**: Oracle's `DATE` stores date AND time (to the second). Use `TIMESTAMP` if you need fractional seconds.
- **MSSQL DATETIME vs DATETIME2**: Always use `DATETIME2` (higher precision, wider range, SQL standard). `DATETIME` is legacy.
- **PostgreSQL TEXT vs VARCHAR**: No performance difference. `TEXT` is unlimited, `VARCHAR(n)` has a constraint but no speed benefit.
- **MySQL TIMESTAMP vs DATETIME**: `TIMESTAMP` auto-converts to UTC and has a range limit (up to 2038). `DATETIME` stores as-is with wider range.
- **Boolean**: Only PostgreSQL has a true `BOOLEAN`. MSSQL uses `BIT`, Oracle uses `NUMBER(1)`, MySQL uses `TINYINT(1)`.

## Window Functions

| Feature | MSSQL | PostgreSQL | Oracle | MySQL |
|---------|-------|-----------|--------|-------|
| ROW_NUMBER | `ROW_NUMBER() OVER(...)` | `ROW_NUMBER() OVER(...)` | `ROW_NUMBER() OVER(...)` | `ROW_NUMBER() OVER(...)` (8.0+) |
| RANK / DENSE_RANK | Supported | Supported | Supported | Supported (8.0+) |
| LEAD / LAG | Supported | Supported | Supported | Supported (8.0+) |
| NTILE | Supported | Supported | `NTILE()` | Supported (8.0+) |
| FIRST_VALUE | Supported | Supported | Supported | Supported (8.0+) |
| Named WINDOW | `WINDOW w AS (...)` (2022) | `WINDOW w AS (...)` | N/A | `WINDOW w AS (...)` (8.0+) |
| Running total | `SUM() OVER(ORDER BY ...)` | `SUM() OVER(ORDER BY ...)` | `SUM() OVER(ORDER BY ...)` | `SUM() OVER(ORDER BY ...)` (8.0+) |

## Temporary Tables

| Feature | MSSQL | PostgreSQL | Oracle | MySQL |
|---------|-------|-----------|--------|-------|
| Session temp | `#TempTable` | `CREATE TEMP TABLE` | `CREATE GLOBAL TEMPORARY TABLE` | `CREATE TEMPORARY TABLE` |
| Global temp | `##GlobalTemp` | N/A (use unlogged) | GTT with `ON COMMIT PRESERVE ROWS` | N/A |
| Scope | Session (auto-drop on disconnect) | Session (auto-drop) | Definition persists, data is session-scoped | Session (auto-drop) |
| Table variable | `DECLARE @t TABLE (...)` | N/A (use temp table) | N/A (use PL/SQL collection) | N/A |

## JSON Operations

| Operation | MSSQL | PostgreSQL | Oracle (21c+) | MySQL |
|-----------|-------|-----------|---------------|-------|
| Extract value | `JSON_VALUE(col,'$.key')` | `col->>'key'` or `col->'key'` | `JSON_VALUE(col,'$.key')` | `col->>'$.key'` or `JSON_EXTRACT(col,'$.key')` |
| Extract object | `JSON_QUERY(col,'$.obj')` | `col->'obj'` | `JSON_QUERY(col,'$.obj')` | `JSON_EXTRACT(col,'$.obj')` |
| Check exists | `ISJSON(col)` | `col ? 'key'` | `JSON_EXISTS(col,'$.key')` | `JSON_CONTAINS_PATH(col,'one','$.key')` |
| Modify | `JSON_MODIFY(col,'$.key',val)` | `jsonb_set(col,'{key}','val')` | `JSON_TRANSFORM(col, SET '$.key'=val)` | `JSON_SET(col,'$.key',val)` |
| Array to rows | `OPENJSON(col)` | `jsonb_array_elements(col)` | `JSON_TABLE(col,'$[*]' ...)` | `JSON_TABLE(col,'$[*]' ...)` |
| Build object | `(SELECT ... FOR JSON PATH)` | `jsonb_build_object('k',v)` | `JSON_OBJECT('k':v)` | `JSON_OBJECT('k',v)` |
| Build array | `(SELECT ... FOR JSON PATH)` | `jsonb_agg(col)` | `JSON_ARRAYAGG(col)` | `JSON_ARRAYAGG(col)` |
