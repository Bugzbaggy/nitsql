# Database Connection Patterns by Language and Dialect

Production-grade connection patterns for Python, Node.js, and C#/.NET across MSSQL, PostgreSQL, Oracle, and MySQL. Each example includes connection pooling, parameterized queries, transaction handling, and error handling with retry logic.

---

## Python

### MSSQL (pyodbc + SQLAlchemy)

```python
import pyodbc
import time
from contextlib import contextmanager
from sqlalchemy import create_engine, text
from sqlalchemy.pool import QueuePool
from urllib.parse import quote_plus

# === Connection Pool via SQLAlchemy ===

CONNECTION_STRING = (
    "Driver={ODBC Driver 18 for SQL Server};"
    "Server=myserver.database.windows.net;"
    "Database=mydb;"
    "Encrypt=yes;"
    "TrustServerCertificate=no;"
)

# For Windows Authentication:
# CONNECTION_STRING += "Trusted_Connection=yes;"

# For SQL Authentication:
# CONNECTION_STRING += "UID=myuser;PWD=mypassword;"

# For Azure AD Token (Managed Identity):
# CONNECTION_STRING += "Authentication=ActiveDirectoryMsi;"

engine = create_engine(
    "mssql+pyodbc:///?odbc_connect=" + quote_plus(CONNECTION_STRING),
    pool_size=10,           # Steady-state pool size
    max_overflow=20,        # Additional connections under load
    pool_timeout=30,        # Wait time for available connection
    pool_recycle=3600,      # Recycle connections after 1 hour
    pool_pre_ping=True,     # Validate connections before use
)


# === Parameterized Query ===

def get_user_orders(user_id: int, status: str = "active"):
    with engine.connect() as conn:
        result = conn.execute(
            text("""
                SELECT OrderID, OrderDate, TotalAmount
                FROM dbo.Orders
                WHERE CustomerID = :user_id AND Status = :status
                ORDER BY OrderDate DESC
            """),
            {"user_id": user_id, "status": status}
        )
        return [dict(row._mapping) for row in result]


# === Transaction Handling ===

def transfer_funds(from_account: int, to_account: int, amount: float):
    with engine.begin() as conn:  # auto-commits on success, auto-rollbacks on exception
        conn.execute(
            text("UPDATE dbo.Accounts SET Balance = Balance - :amount WHERE AccountID = :id"),
            {"amount": amount, "id": from_account}
        )
        conn.execute(
            text("UPDATE dbo.Accounts SET Balance = Balance + :amount WHERE AccountID = :id"),
            {"amount": amount, "id": to_account}
        )
        # Commit happens automatically when the `with` block exits without error


# === Raw pyodbc (without SQLAlchemy) ===

@contextmanager
def get_connection():
    conn = pyodbc.connect(CONNECTION_STRING, timeout=30)
    conn.autocommit = False
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

def get_user_by_id(user_id: int):
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT UserID, UserName, Email FROM dbo.Users WHERE UserID = ?", user_id)
        row = cursor.fetchone()
        if row:
            return {"user_id": row.UserID, "name": row.UserName, "email": row.Email}
        return None
```

### PostgreSQL (psycopg2 / asyncpg)

```python
import psycopg2
from psycopg2 import pool, extras
from contextlib import contextmanager

# === Connection Pool ===

connection_pool = psycopg2.pool.ThreadedConnectionPool(
    minconn=5,
    maxconn=20,
    host="db.example.com",
    port=5432,
    dbname="mydb",
    user="appuser",
    password="secret",
    sslmode="require",
    options="-c search_path=app,public",
    connect_timeout=10,
)


# === Parameterized Query ===

def get_user_orders(user_id: int, status: str = "active"):
    conn = connection_pool.getconn()
    try:
        with conn.cursor(cursor_factory=extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT order_id, order_date, total_amount
                FROM app.orders
                WHERE customer_id = %s AND status = %s
                ORDER BY order_date DESC
                """,
                (user_id, status)
            )
            return cur.fetchall()
    finally:
        connection_pool.putconn(conn)


# === Transaction Handling ===

def transfer_funds(from_account: int, to_account: int, amount: float):
    conn = connection_pool.getconn()
    try:
        with conn:  # Context manager: auto-commit on success, auto-rollback on exception
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE app.accounts SET balance = balance - %s WHERE account_id = %s",
                    (amount, from_account)
                )
                cur.execute(
                    "UPDATE app.accounts SET balance = balance + %s WHERE account_id = %s",
                    (amount, to_account)
                )
    finally:
        connection_pool.putconn(conn)


# === Savepoint Example ===

def process_order_with_optional_items(order_data: dict, items: list):
    conn = connection_pool.getconn()
    try:
        with conn:
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO app.orders (customer_id) VALUES (%s) RETURNING order_id",
                    (order_data["customer_id"],)
                )
                order_id = cur.fetchone()[0]

                # Savepoint before items (items are optional)
                cur.execute("SAVEPOINT before_items")
                try:
                    for item in items:
                        cur.execute(
                            "INSERT INTO app.order_items (order_id, product_id, qty) VALUES (%s, %s, %s)",
                            (order_id, item["product_id"], item["qty"])
                        )
                except Exception as e:
                    cur.execute("ROLLBACK TO SAVEPOINT before_items")
                    # Order header is preserved, items are rolled back
    finally:
        connection_pool.putconn(conn)


# === asyncpg (Async, High Performance) ===

import asyncpg
import asyncio

async def setup_async_pool():
    pool = await asyncpg.create_pool(
        host="db.example.com",
        port=5432,
        database="mydb",
        user="appuser",
        password="secret",
        ssl="require",
        min_size=5,
        max_size=20,
        command_timeout=30,
    )
    return pool

async def get_user_orders_async(pool, user_id: int):
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            "SELECT order_id, order_date, total_amount FROM app.orders WHERE customer_id = $1",
            user_id
        )
        return [dict(row) for row in rows]
```

### Oracle (oracledb)

```python
import oracledb

# === Connection Pool ===

# Thin mode (no Oracle Client required, Python 3.9+)
oracledb.init_oracle_client()  # Only needed for thick mode

pool = oracledb.create_pool(
    user="appuser",
    password="secret",
    dsn="db.example.com:1521/ORCL",  # Or use TNS alias
    min=5,
    max=20,
    increment=1,
    timeout=60,         # Idle connection timeout (seconds)
    getmode=oracledb.POOL_GETMODE_TIMEDWAIT,
    wait_timeout=10000, # Wait up to 10 seconds for available connection (ms)
)


# === Parameterized Query ===

def get_user_orders(user_id: int, status: str = "ACTIVE"):
    with pool.acquire() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT order_id, order_date, total_amount
                FROM app_schema.orders
                WHERE customer_id = :id AND status = :status
                ORDER BY order_date DESC
                """,
                {"id": user_id, "status": status}
            )
            columns = [col[0].lower() for col in cur.description]
            return [dict(zip(columns, row)) for row in cur.fetchall()]


# === Transaction Handling ===

def transfer_funds(from_account: int, to_account: int, amount: float):
    with pool.acquire() as conn:
        # autocommit is False by default in oracledb
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE app_schema.accounts SET balance = balance - :amount WHERE account_id = :id",
                    {"amount": amount, "id": from_account}
                )
                cur.execute(
                    "UPDATE app_schema.accounts SET balance = balance + :amount WHERE account_id = :id",
                    {"amount": amount, "id": to_account}
                )
            conn.commit()
        except Exception:
            conn.rollback()
            raise


# === Calling Stored Procedure with OUT Parameter ===

def create_order(customer_id: int, product_id: int, quantity: int):
    with pool.acquire() as conn:
        with conn.cursor() as cur:
            order_id_var = cur.var(oracledb.NUMBER)
            cur.callproc(
                "app_schema.upsert_customer_order",
                [customer_id, product_id, quantity, None, order_id_var]
            )
            return int(order_id_var.getvalue())
```

### MySQL (mysql-connector-python / pymysql)

```python
import mysql.connector
from mysql.connector import pooling

# === Connection Pool ===

pool = pooling.MySQLConnectionPool(
    pool_name="myapp_pool",
    pool_size=10,
    pool_reset_session=True,
    host="db.example.com",
    port=3306,
    database="app_db",
    user="appuser",
    password="secret",
    charset="utf8mb4",
    collation="utf8mb4_unicode_ci",
    ssl_ca="/path/to/ca.pem",
    ssl_verify_cert=True,
    connect_timeout=10,
    autocommit=False,
)


# === Parameterized Query ===

def get_user_orders(user_id: int, status: str = "active"):
    conn = pool.get_connection()
    try:
        cursor = conn.cursor(dictionary=True)
        cursor.execute(
            """
            SELECT order_id, order_date, total_amount
            FROM orders
            WHERE customer_id = %s AND status = %s
            ORDER BY order_date DESC
            """,
            (user_id, status)
        )
        return cursor.fetchall()
    finally:
        cursor.close()
        conn.close()  # Returns to pool


# === Transaction Handling ===

def transfer_funds(from_account: int, to_account: int, amount: float):
    conn = pool.get_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(
            "UPDATE accounts SET balance = balance - %s WHERE account_id = %s",
            (amount, from_account)
        )
        cursor.execute(
            "UPDATE accounts SET balance = balance + %s WHERE account_id = %s",
            (amount, to_account)
        )
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        cursor.close()
        conn.close()


# === Batch Insert ===

def insert_order_items(order_id: int, items: list):
    conn = pool.get_connection()
    try:
        cursor = conn.cursor()
        cursor.executemany(
            "INSERT INTO order_items (order_id, product_id, quantity) VALUES (%s, %s, %s)",
            [(order_id, item["product_id"], item["quantity"]) for item in items]
        )
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        cursor.close()
        conn.close()
```

---

## Node.js

### MSSQL (mssql / tedious)

```javascript
const sql = require('mssql');

// === Connection Pool ===

const poolConfig = {
    user: 'appuser',
    password: 'secret',
    server: 'myserver.database.windows.net',
    database: 'mydb',
    pool: {
        max: 20,
        min: 5,
        idleTimeoutMillis: 30000,
        acquireTimeoutMillis: 30000,
    },
    options: {
        encrypt: true,
        trustServerCertificate: false,
        enableArithAbort: true,
        connectTimeout: 30000,
        requestTimeout: 30000,
    },
};

// Create a shared pool (initialize once at app startup)
const pool = new sql.ConnectionPool(poolConfig);
const poolConnect = pool.connect();

// Ensure pool is connected before using
async function getPool() {
    await poolConnect;
    return pool;
}


// === Parameterized Query ===

async function getUserOrders(userId, status = 'active') {
    const pool = await getPool();
    const result = await pool.request()
        .input('userId', sql.Int, userId)
        .input('status', sql.NVarChar(20), status)
        .query(`
            SELECT OrderID, OrderDate, TotalAmount
            FROM dbo.Orders
            WHERE CustomerID = @userId AND Status = @status
            ORDER BY OrderDate DESC
        `);
    return result.recordset;
}


// === Transaction Handling ===

async function transferFunds(fromAccount, toAccount, amount) {
    const pool = await getPool();
    const transaction = new sql.Transaction(pool);

    try {
        await transaction.begin();

        const request = new sql.Request(transaction);
        await request
            .input('amount', sql.Decimal(18, 2), amount)
            .input('fromId', sql.Int, fromAccount)
            .query('UPDATE dbo.Accounts SET Balance = Balance - @amount WHERE AccountID = @fromId');

        const request2 = new sql.Request(transaction);
        await request2
            .input('amount', sql.Decimal(18, 2), amount)
            .input('toId', sql.Int, toAccount)
            .query('UPDATE dbo.Accounts SET Balance = Balance + @amount WHERE AccountID = @toId');

        await transaction.commit();
    } catch (err) {
        await transaction.rollback();
        throw err;
    }
}


// === Stored Procedure Call ===

async function createOrder(customerId, productId, quantity) {
    const pool = await getPool();
    const result = await pool.request()
        .input('CustomerID', sql.Int, customerId)
        .input('ProductID', sql.Int, productId)
        .input('Quantity', sql.Int, quantity)
        .output('OrderID', sql.Int)
        .execute('dbo.UpsertCustomerOrder');
    return result.output.OrderID;
}


// === Cleanup on shutdown ===
process.on('SIGINT', async () => {
    await pool.close();
    process.exit(0);
});
```

### PostgreSQL (pg)

```javascript
const { Pool } = require('pg');

// === Connection Pool ===

const pool = new Pool({
    host: 'db.example.com',
    port: 5432,
    database: 'mydb',
    user: 'appuser',
    password: 'secret',
    ssl: { rejectUnauthorized: true },
    max: 20,
    min: 5,
    idleTimeoutMillis: 30000,
    connectionTimeoutMillis: 10000,
    statement_timeout: 30000,
});

// Log pool errors
pool.on('error', (err) => {
    console.error('Unexpected pool error:', err);
});


// === Parameterized Query ===

async function getUserOrders(userId, status = 'active') {
    const result = await pool.query(
        `SELECT order_id, order_date, total_amount
         FROM app.orders
         WHERE customer_id = $1 AND status = $2
         ORDER BY order_date DESC`,
        [userId, status]
    );
    return result.rows;
}


// === Transaction Handling ===

async function transferFunds(fromAccount, toAccount, amount) {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        await client.query(
            'UPDATE app.accounts SET balance = balance - $1 WHERE account_id = $2',
            [amount, fromAccount]
        );
        await client.query(
            'UPDATE app.accounts SET balance = balance + $1 WHERE account_id = $2',
            [amount, toAccount]
        );
        await client.query('COMMIT');
    } catch (err) {
        await client.query('ROLLBACK');
        throw err;
    } finally {
        client.release();
    }
}


// === Insert with RETURNING ===

async function createOrder(customerId) {
    const result = await pool.query(
        'INSERT INTO app.orders (customer_id) VALUES ($1) RETURNING order_id, created_at',
        [customerId]
    );
    return result.rows[0];
}


// === Cleanup ===
process.on('SIGINT', async () => {
    await pool.end();
    process.exit(0);
});
```

### Oracle (oracledb)

```javascript
const oracledb = require('oracledb');

// === Connection Pool ===

let pool;

async function initPool() {
    pool = await oracledb.createPool({
        user: 'appuser',
        password: 'secret',
        connectString: 'db.example.com:1521/ORCL',
        poolMin: 5,
        poolMax: 20,
        poolIncrement: 1,
        poolTimeout: 60,
        queueTimeout: 10000,
        enableStatistics: true,
    });
    // Use objects instead of arrays
    oracledb.outFormat = oracledb.OUT_FORMAT_OBJECT;
}


// === Parameterized Query ===

async function getUserOrders(userId, status = 'ACTIVE') {
    const conn = await pool.getConnection();
    try {
        const result = await conn.execute(
            `SELECT order_id, order_date, total_amount
             FROM app_schema.orders
             WHERE customer_id = :id AND status = :status
             ORDER BY order_date DESC`,
            { id: userId, status: status },
            { outFormat: oracledb.OUT_FORMAT_OBJECT }
        );
        return result.rows;
    } finally {
        await conn.close();  // Returns to pool
    }
}


// === Transaction Handling ===

async function transferFunds(fromAccount, toAccount, amount) {
    const conn = await pool.getConnection();
    try {
        await conn.execute(
            'UPDATE app_schema.accounts SET balance = balance - :amount WHERE account_id = :id',
            { amount, id: fromAccount }
        );
        await conn.execute(
            'UPDATE app_schema.accounts SET balance = balance + :amount WHERE account_id = :id',
            { amount, id: toAccount }
        );
        await conn.commit();
    } catch (err) {
        await conn.rollback();
        throw err;
    } finally {
        await conn.close();
    }
}


// === Stored Procedure with OUT Parameter ===

async function createOrder(customerId, productId, quantity) {
    const conn = await pool.getConnection();
    try {
        const result = await conn.execute(
            `BEGIN app_schema.upsert_customer_order(:cust, :prod, :qty, SYSDATE, :order_id); END;`,
            {
                cust: customerId,
                prod: productId,
                qty: quantity,
                order_id: { dir: oracledb.BIND_OUT, type: oracledb.NUMBER },
            }
        );
        await conn.commit();
        return result.outBinds.order_id;
    } catch (err) {
        await conn.rollback();
        throw err;
    } finally {
        await conn.close();
    }
}
```

### MySQL (mysql2)

```javascript
const mysql = require('mysql2/promise');

// === Connection Pool ===

const pool = mysql.createPool({
    host: 'db.example.com',
    port: 3306,
    database: 'app_db',
    user: 'appuser',
    password: 'secret',
    charset: 'utf8mb4',
    ssl: { ca: require('fs').readFileSync('/path/to/ca.pem') },
    waitForConnections: true,
    connectionLimit: 20,
    queueLimit: 0,
    connectTimeout: 10000,
    enableKeepAlive: true,
    keepAliveInitialDelay: 30000,
});


// === Parameterized Query ===

async function getUserOrders(userId, status = 'active') {
    const [rows] = await pool.execute(
        `SELECT order_id, order_date, total_amount
         FROM orders
         WHERE customer_id = ? AND status = ?
         ORDER BY order_date DESC`,
        [userId, status]
    );
    return rows;
}


// === Transaction Handling ===

async function transferFunds(fromAccount, toAccount, amount) {
    const conn = await pool.getConnection();
    try {
        await conn.beginTransaction();
        await conn.execute(
            'UPDATE accounts SET balance = balance - ? WHERE account_id = ?',
            [amount, fromAccount]
        );
        await conn.execute(
            'UPDATE accounts SET balance = balance + ? WHERE account_id = ?',
            [amount, toAccount]
        );
        await conn.commit();
    } catch (err) {
        await conn.rollback();
        throw err;
    } finally {
        conn.release();
    }
}


// === Insert and Get ID ===

async function createOrder(customerId) {
    const [result] = await pool.execute(
        'INSERT INTO orders (customer_id, order_date) VALUES (?, NOW())',
        [customerId]
    );
    return result.insertId;  // LAST_INSERT_ID() equivalent
}


// === Cleanup ===
process.on('SIGINT', async () => {
    await pool.end();
    process.exit(0);
});
```

---

## C# / .NET

### MSSQL (Microsoft.Data.SqlClient)

```csharp
using Microsoft.Data.SqlClient;
using System.Data;

public class MssqlRepository : IDisposable
{
    private readonly string _connectionString;

    public MssqlRepository(string server, string database)
    {
        // SqlClient uses built-in connection pooling (enabled by default)
        _connectionString = new SqlConnectionStringBuilder
        {
            DataSource = server,
            InitialCatalog = database,
            IntegratedSecurity = true,        // Windows Auth
            // Or: UserID = "user", Password = "pass",
            Encrypt = SqlConnectionEncryptOption.Mandatory,
            TrustServerCertificate = false,
            ConnectTimeout = 30,
            MinPoolSize = 5,
            MaxPoolSize = 100,
            MultipleActiveResultSets = false,  // MARS: keep false unless needed
            ApplicationName = "MyApp",
        }.ConnectionString;
    }

    // === Parameterized Query ===
    public async Task<List<Order>> GetUserOrdersAsync(int userId, string status = "active")
    {
        var orders = new List<Order>();
        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync();

        await using var cmd = new SqlCommand(
            @"SELECT OrderID, OrderDate, TotalAmount
              FROM dbo.Orders
              WHERE CustomerID = @userId AND Status = @status
              ORDER BY OrderDate DESC", conn);

        cmd.Parameters.Add("@userId", SqlDbType.Int).Value = userId;
        cmd.Parameters.Add("@status", SqlDbType.NVarChar, 20).Value = status;

        await using var reader = await cmd.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            orders.Add(new Order
            {
                OrderId = reader.GetInt32(0),
                OrderDate = reader.GetDateTime(1),
                TotalAmount = reader.GetDecimal(2),
            });
        }
        return orders;
    }

    // === Transaction Handling ===
    public async Task TransferFundsAsync(int fromAccount, int toAccount, decimal amount)
    {
        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync();
        await using var txn = (SqlTransaction)await conn.BeginTransactionAsync();

        try
        {
            await using var cmd1 = new SqlCommand(
                "UPDATE dbo.Accounts SET Balance = Balance - @amount WHERE AccountID = @id", conn, txn);
            cmd1.Parameters.Add("@amount", SqlDbType.Decimal).Value = amount;
            cmd1.Parameters.Add("@id", SqlDbType.Int).Value = fromAccount;
            await cmd1.ExecuteNonQueryAsync();

            await using var cmd2 = new SqlCommand(
                "UPDATE dbo.Accounts SET Balance = Balance + @amount WHERE AccountID = @id", conn, txn);
            cmd2.Parameters.Add("@amount", SqlDbType.Decimal).Value = amount;
            cmd2.Parameters.Add("@id", SqlDbType.Int).Value = toAccount;
            await cmd2.ExecuteNonQueryAsync();

            await txn.CommitAsync();
        }
        catch
        {
            await txn.RollbackAsync();
            throw;
        }
    }

    public void Dispose()
    {
        SqlConnection.ClearAllPools();
    }
}
```

### PostgreSQL (Npgsql)

```csharp
using Npgsql;
using NpgsqlTypes;

public class PostgresRepository
{
    private readonly NpgsqlDataSource _dataSource;

    public PostgresRepository(string host, string database, string user, string password)
    {
        // NpgsqlDataSource (Npgsql 7+): recommended connection management
        var builder = new NpgsqlConnectionStringBuilder
        {
            Host = host,
            Port = 5432,
            Database = database,
            Username = user,
            Password = password,
            SslMode = SslMode.Require,
            MinPoolSize = 5,
            MaxPoolSize = 20,
            ConnectionIdleLifetime = 300,
            Timeout = 30,
            CommandTimeout = 30,
            SearchPath = "app,public",
        };

        _dataSource = NpgsqlDataSource.Create(builder);
    }

    // === Parameterized Query ===
    public async Task<List<Order>> GetUserOrdersAsync(int userId, string status = "active")
    {
        var orders = new List<Order>();
        await using var cmd = _dataSource.CreateCommand(
            @"SELECT order_id, order_date, total_amount
              FROM app.orders
              WHERE customer_id = @userId AND status = @status
              ORDER BY order_date DESC");

        cmd.Parameters.AddWithValue("@userId", NpgsqlDbType.Integer, userId);
        cmd.Parameters.AddWithValue("@status", NpgsqlDbType.Text, status);

        await using var reader = await cmd.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            orders.Add(new Order
            {
                OrderId = reader.GetInt32(0),
                OrderDate = reader.GetDateTime(1),
                TotalAmount = reader.GetDecimal(2),
            });
        }
        return orders;
    }

    // === Transaction Handling ===
    public async Task TransferFundsAsync(int fromAccount, int toAccount, decimal amount)
    {
        await using var conn = await _dataSource.OpenConnectionAsync();
        await using var txn = await conn.BeginTransactionAsync();

        try
        {
            await using var cmd1 = new NpgsqlCommand(
                "UPDATE app.accounts SET balance = balance - @amount WHERE account_id = @id", conn, txn);
            cmd1.Parameters.AddWithValue("@amount", NpgsqlDbType.Numeric, amount);
            cmd1.Parameters.AddWithValue("@id", NpgsqlDbType.Integer, fromAccount);
            await cmd1.ExecuteNonQueryAsync();

            await using var cmd2 = new NpgsqlCommand(
                "UPDATE app.accounts SET balance = balance + @amount WHERE account_id = @id", conn, txn);
            cmd2.Parameters.AddWithValue("@amount", NpgsqlDbType.Numeric, amount);
            cmd2.Parameters.AddWithValue("@id", NpgsqlDbType.Integer, toAccount);
            await cmd2.ExecuteNonQueryAsync();

            await txn.CommitAsync();
        }
        catch
        {
            await txn.RollbackAsync();
            throw;
        }
    }

    // === Insert with RETURNING ===
    public async Task<int> CreateOrderAsync(int customerId)
    {
        await using var cmd = _dataSource.CreateCommand(
            "INSERT INTO app.orders (customer_id) VALUES (@id) RETURNING order_id");
        cmd.Parameters.AddWithValue("@id", NpgsqlDbType.Integer, customerId);
        var result = await cmd.ExecuteScalarAsync();
        return (int)result!;
    }
}
```

### Oracle (ODP.NET / Oracle.ManagedDataAccess.Core)

```csharp
using Oracle.ManagedDataAccess.Client;

public class OracleRepository
{
    private readonly string _connectionString;

    public OracleRepository(string host, string serviceName, string user, string password)
    {
        _connectionString = new OracleConnectionStringBuilder
        {
            DataSource = $"{host}:1521/{serviceName}",
            UserID = user,
            Password = password,
            MinPoolSize = 5,
            MaxPoolSize = 20,
            ConnectionTimeout = 30,
            Pooling = true,
        }.ConnectionString;
    }

    // === Parameterized Query ===
    public async Task<List<Order>> GetUserOrdersAsync(int userId, string status = "ACTIVE")
    {
        var orders = new List<Order>();
        await using var conn = new OracleConnection(_connectionString);
        await conn.OpenAsync();

        await using var cmd = new OracleCommand(
            @"SELECT order_id, order_date, total_amount
              FROM app_schema.orders
              WHERE customer_id = :userId AND status = :status
              ORDER BY order_date DESC", conn);

        // ODP.NET binds by position by default — set BindByName!
        cmd.BindByName = true;
        cmd.Parameters.Add(new OracleParameter("userId", userId));
        cmd.Parameters.Add(new OracleParameter("status", status));

        await using var reader = await cmd.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            orders.Add(new Order
            {
                OrderId = reader.GetInt32(0),
                OrderDate = reader.GetDateTime(1),
                TotalAmount = reader.GetDecimal(2),
            });
        }
        return orders;
    }

    // === Transaction Handling ===
    public async Task TransferFundsAsync(int fromAccount, int toAccount, decimal amount)
    {
        await using var conn = new OracleConnection(_connectionString);
        await conn.OpenAsync();
        await using var txn = conn.BeginTransaction();

        try
        {
            await using var cmd1 = new OracleCommand(
                "UPDATE app_schema.accounts SET balance = balance - :amount WHERE account_id = :id", conn);
            cmd1.BindByName = true;
            cmd1.Parameters.Add("amount", amount);
            cmd1.Parameters.Add("id", fromAccount);
            cmd1.Transaction = txn;
            await cmd1.ExecuteNonQueryAsync();

            await using var cmd2 = new OracleCommand(
                "UPDATE app_schema.accounts SET balance = balance + :amount WHERE account_id = :id", conn);
            cmd2.BindByName = true;
            cmd2.Parameters.Add("amount", amount);
            cmd2.Parameters.Add("id", toAccount);
            cmd2.Transaction = txn;
            await cmd2.ExecuteNonQueryAsync();

            txn.Commit();
        }
        catch
        {
            txn.Rollback();
            throw;
        }
    }
}
```

### MySQL (MySqlConnector)

```csharp
using MySqlConnector;

public class MysqlRepository
{
    private readonly MySqlDataSource _dataSource;

    public MysqlRepository(string host, string database, string user, string password)
    {
        var builder = new MySqlConnectionStringBuilder
        {
            Server = host,
            Port = 3306,
            Database = database,
            UserID = user,
            Password = password,
            CharacterSet = "utf8mb4",
            SslMode = MySqlSslMode.Required,
            MinimumPoolSize = 5,
            MaximumPoolSize = 20,
            ConnectionTimeout = 30,
            DefaultCommandTimeout = 30,
            Pooling = true,
        };

        _dataSource = new MySqlDataSource(builder.ConnectionString);
    }

    // === Parameterized Query ===
    public async Task<List<Order>> GetUserOrdersAsync(int userId, string status = "active")
    {
        var orders = new List<Order>();
        await using var conn = await _dataSource.OpenConnectionAsync();
        await using var cmd = new MySqlCommand(
            @"SELECT order_id, order_date, total_amount
              FROM orders
              WHERE customer_id = @userId AND status = @status
              ORDER BY order_date DESC", conn);

        cmd.Parameters.AddWithValue("@userId", userId);
        cmd.Parameters.AddWithValue("@status", status);

        await using var reader = await cmd.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            orders.Add(new Order
            {
                OrderId = reader.GetInt32(0),
                OrderDate = reader.GetDateTime(1),
                TotalAmount = reader.GetDecimal(2),
            });
        }
        return orders;
    }

    // === Transaction Handling ===
    public async Task TransferFundsAsync(int fromAccount, int toAccount, decimal amount)
    {
        await using var conn = await _dataSource.OpenConnectionAsync();
        await using var txn = await conn.BeginTransactionAsync();

        try
        {
            await using var cmd1 = new MySqlCommand(
                "UPDATE accounts SET balance = balance - @amount WHERE account_id = @id", conn, txn);
            cmd1.Parameters.AddWithValue("@amount", amount);
            cmd1.Parameters.AddWithValue("@id", fromAccount);
            await cmd1.ExecuteNonQueryAsync();

            await using var cmd2 = new MySqlCommand(
                "UPDATE accounts SET balance = balance + @amount WHERE account_id = @id", conn, txn);
            cmd2.Parameters.AddWithValue("@amount", amount);
            cmd2.Parameters.AddWithValue("@id", toAccount);
            await cmd2.ExecuteNonQueryAsync();

            await txn.CommitAsync();
        }
        catch
        {
            await txn.RollbackAsync();
            throw;
        }
    }

    // === Insert and Get ID ===
    public async Task<long> CreateOrderAsync(int customerId)
    {
        await using var conn = await _dataSource.OpenConnectionAsync();
        await using var cmd = new MySqlCommand(
            "INSERT INTO orders (customer_id, order_date) VALUES (@id, NOW())", conn);
        cmd.Parameters.AddWithValue("@id", customerId);
        await cmd.ExecuteNonQueryAsync();
        return cmd.LastInsertedId;
    }
}
```

---

## Retry Logic Pattern (Universal)

### Python — Exponential Backoff with Dialect-Specific Transient Errors

```python
import time
import random
import logging
from functools import wraps

logger = logging.getLogger(__name__)

# Dialect-specific transient error codes
TRANSIENT_ERRORS = {
    "mssql": {
        # pyodbc error codes (SQL Server)
        4060,   # Cannot open database
        40197,  # Service encountered an error processing request
        40501,  # Service is busy
        40613,  # Database not currently available
        49918,  # Not enough resources to process request
        49919,  # Cannot process create/update request (too many operations)
        49920,  # Cannot process request (too many operations)
        1205,   # Deadlock victim
        -2,     # Timeout expired
        10928,  # Resource ID limit reached
        10929,  # Resource ID limit reached (minimum guarantee)
    },
    "postgresql": {
        # psycopg2 error classes
        "08000",  # connection_exception
        "08001",  # sqlclient_unable_to_establish_sqlconnection
        "08003",  # connection_does_not_exist
        "08004",  # sqlserver_rejected_establishment_of_sqlconnection
        "08006",  # connection_failure
        "40001",  # serialization_failure
        "40P01",  # deadlock_detected
        "57P01",  # admin_shutdown
        "57P02",  # crash_shutdown
        "57P03",  # cannot_connect_now
    },
    "oracle": {
        # ORA error numbers
        3113,   # end-of-file on communication channel
        3114,   # not connected to ORACLE
        3135,   # connection lost contact
        12170,  # TNS:Connect timeout occurred
        12541,  # TNS:no listener
        12543,  # TNS:destination host unreachable
        25408,  # can not safely replay call (safe to retry)
        60,     # deadlock detected
        4068,   # existing state of packages has been discarded
    },
    "mysql": {
        # MySQL error numbers
        1040,   # Too many connections
        1205,   # Lock wait timeout exceeded
        1213,   # Deadlock found when trying to get lock
        2002,   # Can't connect to local MySQL server through socket
        2003,   # Can't connect to MySQL server
        2006,   # MySQL server has gone away
        2013,   # Lost connection to MySQL server during query
        4031,   # Client interaction timeout
    },
}


def is_transient_error(dialect: str, exception) -> bool:
    """Check if an exception is a transient (retryable) error."""
    error_codes = TRANSIENT_ERRORS.get(dialect, set())
    error_code = None

    if dialect == "mssql":
        # pyodbc stores the error code in args[0] or the SQL Server error in args[1]
        if hasattr(exception, 'args') and len(exception.args) >= 1:
            error_code = getattr(exception, 'args', [None])[0]
            if isinstance(error_code, str) and len(error_code) == 5:
                # SQLSTATE
                pass
            else:
                # Try to extract the native error number
                error_str = str(exception)
                for code in error_codes:
                    if str(code) in error_str:
                        return True
    elif dialect == "postgresql":
        # psycopg2 stores SQLSTATE in pgcode
        error_code = getattr(exception, 'pgcode', None)
    elif dialect == "oracle":
        # oracledb stores code in args[0].code
        if hasattr(exception, 'args') and len(exception.args) > 0:
            error_obj = exception.args[0]
            error_code = getattr(error_obj, 'code', None)
    elif dialect == "mysql":
        error_code = getattr(exception, 'errno', None)

    if error_code is not None and error_code in error_codes:
        return True

    return False


def retry_on_transient(
    dialect: str,
    max_retries: int = 3,
    base_delay: float = 1.0,
    max_delay: float = 30.0,
    exponential_base: float = 2.0,
):
    """Decorator that retries a function on transient database errors."""
    def decorator(func):
        @wraps(func)
        def wrapper(*args, **kwargs):
            last_exception = None
            for attempt in range(max_retries + 1):
                try:
                    return func(*args, **kwargs)
                except Exception as e:
                    last_exception = e
                    if attempt == max_retries or not is_transient_error(dialect, e):
                        raise
                    # Exponential backoff with jitter
                    delay = min(
                        base_delay * (exponential_base ** attempt) + random.uniform(0, 1),
                        max_delay
                    )
                    logger.warning(
                        "Transient error on attempt %d/%d: %s. Retrying in %.1fs...",
                        attempt + 1, max_retries, str(e)[:200], delay
                    )
                    time.sleep(delay)
            raise last_exception
        return wrapper
    return decorator


# === Usage Examples ===

@retry_on_transient(dialect="mssql", max_retries=3, base_delay=1.0)
def get_orders_mssql(user_id):
    with engine.connect() as conn:
        return conn.execute(text("SELECT * FROM dbo.Orders WHERE CustomerID = :id"), {"id": user_id}).fetchall()


@retry_on_transient(dialect="postgresql", max_retries=3, base_delay=0.5)
def get_orders_pg(user_id):
    conn = connection_pool.getconn()
    try:
        with conn.cursor(cursor_factory=extras.RealDictCursor) as cur:
            cur.execute("SELECT * FROM app.orders WHERE customer_id = %s", (user_id,))
            return cur.fetchall()
    finally:
        connection_pool.putconn(conn)


@retry_on_transient(dialect="oracle", max_retries=3, base_delay=1.0)
def get_orders_oracle(user_id):
    with pool.acquire() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM app_schema.orders WHERE customer_id = :id", {"id": user_id})
            return cur.fetchall()


@retry_on_transient(dialect="mysql", max_retries=3, base_delay=0.5)
def get_orders_mysql(user_id):
    conn = pool.get_connection()
    try:
        cursor = conn.cursor(dictionary=True)
        cursor.execute("SELECT * FROM orders WHERE customer_id = %s", (user_id,))
        return cursor.fetchall()
    finally:
        cursor.close()
        conn.close()
```

### Node.js — Retry Helper

```javascript
// Transient error codes by dialect
const TRANSIENT_ERRORS = {
    mssql:      [4060, 40197, 40501, 40613, 1205, 49918, 49919, 49920, 10928, 10929],
    postgresql: ['08000', '08001', '08003', '08006', '40001', '40P01', '57P01', '57P03'],
    oracle:     [3113, 3114, 3135, 12170, 12541, 12543, 60, 4068],
    mysql:      [1040, 1205, 1213, 2002, 2003, 2006, 2013],
};

function isTransientError(dialect, error) {
    const codes = TRANSIENT_ERRORS[dialect] || [];
    const errorCode = error.number || error.code || error.errno || error.errorNum;

    if (errorCode && codes.includes(errorCode)) return true;

    // Check string representation as fallback
    const errorStr = String(error);
    return codes.some(code => errorStr.includes(String(code)));
}

async function withRetry(dialect, fn, { maxRetries = 3, baseDelay = 1000, maxDelay = 30000 } = {}) {
    let lastError;
    for (let attempt = 0; attempt <= maxRetries; attempt++) {
        try {
            return await fn();
        } catch (error) {
            lastError = error;
            if (attempt === maxRetries || !isTransientError(dialect, error)) {
                throw error;
            }
            const delay = Math.min(
                baseDelay * Math.pow(2, attempt) + Math.random() * 1000,
                maxDelay
            );
            console.warn(
                `Transient error (attempt ${attempt + 1}/${maxRetries}): ${error.message}. ` +
                `Retrying in ${Math.round(delay)}ms...`
            );
            await new Promise(resolve => setTimeout(resolve, delay));
        }
    }
    throw lastError;
}

// === Usage ===

// MSSQL
async function getOrdersWithRetry(userId) {
    return withRetry('mssql', async () => {
        const pool = await getPool();
        const result = await pool.request()
            .input('userId', sql.Int, userId)
            .query('SELECT * FROM dbo.Orders WHERE CustomerID = @userId');
        return result.recordset;
    });
}

// PostgreSQL
async function getOrdersPgWithRetry(userId) {
    return withRetry('postgresql', async () => {
        const result = await pool.query(
            'SELECT * FROM app.orders WHERE customer_id = $1',
            [userId]
        );
        return result.rows;
    });
}
```

### C# — Retry with Polly (Recommended)

```csharp
using Polly;
using Polly.Retry;
using Microsoft.Data.SqlClient;

public static class DbRetryPolicy
{
    // MSSQL transient error numbers
    private static readonly HashSet<int> MssqlTransientErrors = new()
    {
        4060, 40197, 40501, 40613, 49918, 49919, 49920, 1205, 10928, 10929, -2,
    };

    public static AsyncRetryPolicy CreateMssqlRetryPolicy(int maxRetries = 3)
    {
        return Policy
            .Handle<SqlException>(ex => ex.Errors.Cast<SqlError>()
                .Any(e => MssqlTransientErrors.Contains(e.Number)))
            .Or<TimeoutException>()
            .WaitAndRetryAsync(
                maxRetries,
                retryAttempt => TimeSpan.FromSeconds(Math.Pow(2, retryAttempt))
                    + TimeSpan.FromMilliseconds(Random.Shared.Next(0, 1000)),
                onRetry: (exception, timeSpan, retryCount, context) =>
                {
                    Console.WriteLine(
                        $"Transient error (attempt {retryCount}/{maxRetries}): " +
                        $"{exception.Message}. Retrying in {timeSpan.TotalSeconds:F1}s...");
                }
            );
    }

    // === Usage ===
    public static async Task<List<Order>> GetOrdersWithRetryAsync(string connStr, int userId)
    {
        var retryPolicy = CreateMssqlRetryPolicy();

        return await retryPolicy.ExecuteAsync(async () =>
        {
            var orders = new List<Order>();
            await using var conn = new SqlConnection(connStr);
            await conn.OpenAsync();

            await using var cmd = new SqlCommand(
                "SELECT OrderID, OrderDate, TotalAmount FROM dbo.Orders WHERE CustomerID = @id", conn);
            cmd.Parameters.AddWithValue("@id", userId);

            await using var reader = await cmd.ExecuteReaderAsync();
            while (await reader.ReadAsync())
            {
                orders.Add(new Order
                {
                    OrderId = reader.GetInt32(0),
                    OrderDate = reader.GetDateTime(1),
                    TotalAmount = reader.GetDecimal(2),
                });
            }
            return orders;
        });
    }
}
```

---

## Connection String Security Best Practices

### All Dialects
1. **Never hardcode credentials** in source code. Use environment variables, secrets managers, or config files outside of source control.
2. **Always use encrypted connections**: `Encrypt=yes` (MSSQL), `sslmode=require` (PostgreSQL), TLS for Oracle, `ssl_ca` (MySQL).
3. **Use connection pooling** in every environment. Connection creation is expensive (TCP handshake, auth, TLS negotiation).
4. **Set connection timeouts** to avoid hanging on network issues. 10-30 seconds is typical.
5. **Set command/query timeouts** to prevent runaway queries. 30 seconds for OLTP, longer for batch.
6. **Implement retry logic** for transient errors, especially in cloud environments.
7. **Monitor pool usage**: Watch for pool exhaustion (all connections in use, queue growing). This usually indicates connection leaks or long-running transactions.
8. **Close/release connections promptly**: Use `using`/`with`/`try-finally` to ensure connections return to the pool even on error.

### Managed Identity / Token-Based Authentication (Cloud)
```python
# Azure SQL with Managed Identity (Python)
import struct
from azure.identity import DefaultAzureCredential

credential = DefaultAzureCredential()
token = credential.get_token("https://database.windows.net/.default")
token_bytes = token.token.encode("UTF-16-LE")
token_struct = struct.pack(f'<I{len(token_bytes)}s', len(token_bytes), token_bytes)

conn = pyodbc.connect(CONNECTION_STRING, attrs_before={1256: token_struct})
```

```csharp
// Azure SQL with Managed Identity (C#)
var conn = new SqlConnection(connectionString);
conn.AccessToken = new DefaultAzureCredential()
    .GetToken(new TokenRequestContext(new[] { "https://database.windows.net/.default" }))
    .Token;
await conn.OpenAsync();
```
