# connection-pooling
**Priority:** HIGH
**Category:** Connection
**Applies to:** MSSQL, PostgreSQL, Oracle, MySQL

## Why It Matters

Opening a database connection is expensive: TCP handshake, TLS negotiation, authentication, and session setup cost 20-100 ms per connection. Without pooling, every request pays this cost. Under load, the database hits its max-connections limit and starts rejecting new requests. Connection pooling reuses open connections, reducing latency to sub-millisecond and preventing exhaustion.

## Incorrect Code

### MSSQL

```sql
-- N/A at the SQL level; this is an application-tier concern.
```

### PostgreSQL

```sql
-- PostgreSQL forks a new backend process per connection (expensive).
-- Without pooling, 500 concurrent requests = 500 OS processes.
```

### Oracle

```sql
-- Oracle dedicated-server mode spawns a process per connection.
-- Without pooling, connection storms can exhaust OS resources.
```

### MySQL

```sql
-- MySQL creates a thread per connection.
-- Without pooling, thread_cache_size is quickly exceeded.
```

## Correct Code

### MSSQL

```sql
-- No SQL-side configuration needed. Pooling is managed by the application driver.
-- Verify with:
SELECT login_name, host_name, program_name,
       COUNT(*) AS connection_count,
       SUM(CASE WHEN status = 'sleeping' THEN 1 ELSE 0 END) AS idle
FROM sys.dm_exec_sessions
WHERE is_user_process = 1
GROUP BY login_name, host_name, program_name
ORDER BY connection_count DESC;
```

### PostgreSQL

```sql
-- Use PgBouncer or pgpool-II as an external connection pooler.
-- pgbouncer.ini example:
-- [databases]
-- mydb = host=127.0.0.1 dbname=mydb
-- [pgbouncer]
-- pool_mode = transaction
-- max_client_conn = 500
-- default_pool_size = 25

-- Verify with:
SELECT usename, application_name, state, COUNT(*)
FROM pg_stat_activity
GROUP BY usename, application_name, state
ORDER BY count DESC;
```

### Oracle

```sql
-- Database Resident Connection Pooling (DRCP) -- enable server-side:
EXEC DBMS_CONNECTION_POOL.START_POOL;

-- Configure pool size:
EXEC DBMS_CONNECTION_POOL.CONFIGURE_POOL(
    minsize => 10,
    maxsize => 100,
    incrsize => 5,
    session_cached_cursors => 50
);

-- Verify with:
SELECT num_open_servers, num_busy_servers, num_auth_servers
FROM v$cpool_stats;
```

### MySQL

```sql
-- MySQL 8.0+ thread pool plugin (Enterprise) or ProxySQL:
-- my.cnf:
-- [mysqld]
-- thread_handling = pool-of-threads
-- thread_pool_size = 16
-- max_connections = 500

-- Verify connections:
SELECT user, host, db, command, COUNT(*) AS cnt
FROM information_schema.processlist
GROUP BY user, host, db, command
ORDER BY cnt DESC;
```

## Application Code Detection

### Python

```python
# --- MSSQL (SQLAlchemy + pyodbc) ---
# Bad
from sqlalchemy import create_engine
from sqlalchemy.pool import NullPool
engine = create_engine(conn_str, poolclass=NullPool)  # pooling disabled

# Good
engine = create_engine(
    "mssql+pyodbc://user:pass@server/db?driver=ODBC+Driver+18+for+SQL+Server",
    pool_size=10,
    max_overflow=20,
    pool_timeout=30,
    pool_recycle=1800,
    pool_pre_ping=True
)

# --- PostgreSQL (psycopg2) ---
# Bad
import psycopg2
conn = psycopg2.connect(dsn)  # new connection every call

# Good
from psycopg2 import pool
pg_pool = pool.ThreadedConnectionPool(
    minconn=5,
    maxconn=20,
    dsn="host=localhost dbname=mydb user=app"
)
conn = pg_pool.getconn()
try:
    cur = conn.cursor()
    cur.execute("SELECT 1")
finally:
    pg_pool.putconn(conn)

# --- Oracle (oracledb) ---
# Bad
import oracledb
conn = oracledb.connect(user="app", password="pass", dsn="host/db")

# Good
pool = oracledb.create_pool(
    user="app",
    password="pass",
    dsn="host/db",
    min=5,
    max=20,
    increment=1
)
with pool.acquire() as conn:
    cur = conn.cursor()
    cur.execute("SELECT 1 FROM DUAL")

# --- MySQL (mysql-connector-python) ---
# Bad
import mysql.connector
conn = mysql.connector.connect(host="localhost", database="mydb", user="app", password="pass")

# Good
from mysql.connector import pooling
mysql_pool = pooling.MySQLConnectionPool(
    pool_name="app_pool",
    pool_size=10,
    host="localhost",
    database="mydb",
    user="app",
    password="pass"
)
conn = mysql_pool.get_connection()
try:
    cur = conn.cursor()
    cur.execute("SELECT 1")
finally:
    conn.close()  # returns to pool
```

### Node.js

```javascript
// --- MSSQL (mssql) ---
// Bad: new pool per request
async function getUser(id) {
    const pool = await sql.connect(config);  // new pool
    const result = await pool.request().input('id', sql.Int, id)
        .query('SELECT Name FROM dbo.Users WHERE UserID = @id');
    pool.close();
    return result.recordset[0];
}

// Good: singleton pool
const poolPromise = new sql.ConnectionPool({
    server: 'server', database: 'db', user: 'user', password: 'pass',
    pool: { max: 20, min: 5, idleTimeoutMillis: 30000 }
}).connect();

async function getUser(id) {
    const pool = await poolPromise;
    return (await pool.request().input('id', sql.Int, id)
        .query('SELECT Name FROM dbo.Users WHERE UserID = @id')).recordset[0];
}

// --- PostgreSQL (pg) ---
// Bad
const { Client } = require('pg');
async function query() {
    const client = new Client();  // new connection per call
    await client.connect();
    const res = await client.query('SELECT 1');
    await client.end();
}

// Good
const { Pool } = require('pg');
const pgPool = new Pool({ max: 20, idleTimeoutMillis: 30000 });
async function query() {
    const res = await pgPool.query('SELECT 1');
    return res.rows;
}

// --- Oracle (oracledb) ---
// Good
const oracledb = require('oracledb');
await oracledb.createPool({
    user: 'app', password: 'pass', connectString: 'host/db',
    poolMin: 5, poolMax: 20, poolIncrement: 1
});
const conn = await oracledb.getConnection();
try {
    const result = await conn.execute('SELECT 1 FROM DUAL');
} finally {
    await conn.close();  // returns to pool
}

// --- MySQL (mysql2) ---
// Good
const mysql = require('mysql2/promise');
const mysqlPool = mysql.createPool({
    host: 'localhost', database: 'mydb', user: 'app', password: 'pass',
    waitForConnections: true, connectionLimit: 20, queueLimit: 0
});
const [rows] = await mysqlPool.execute('SELECT 1');
```

### C#

```csharp
// --- MSSQL (Microsoft.Data.SqlClient) ---
// Bad
var cs = "Server=srv;Database=db;User Id=user;Password=pass;Pooling=false";

// Good -- pooling is ON by default; tune the pool
var cs = "Server=srv;Database=db;User Id=user;Password=pass;"
       + "Min Pool Size=5;Max Pool Size=100;Connection Timeout=30;";
using var conn = new SqlConnection(cs);
await conn.OpenAsync();
// conn.Dispose() returns it to the pool

// --- PostgreSQL (Npgsql) ---
// Good
var cs = "Host=localhost;Database=mydb;Username=app;Password=pass;"
       + "Minimum Pool Size=5;Maximum Pool Size=20;Connection Idle Lifetime=300;";
using var conn = new NpgsqlConnection(cs);
await conn.OpenAsync();

// --- Oracle (Oracle.ManagedDataAccess.Core) ---
// Good
var cs = "User Id=app;Password=pass;Data Source=host/db;"
       + "Min Pool Size=5;Max Pool Size=20;Connection Timeout=30;";
using var conn = new OracleConnection(cs);
await conn.OpenAsync();

// --- MySQL (MySqlConnector) ---
// Good
var cs = "Server=localhost;Database=mydb;User=app;Password=pass;"
       + "MinimumPoolSize=5;MaximumPoolSize=20;ConnectionIdleTimeout=300;";
using var conn = new MySqlConnection(cs);
await conn.OpenAsync();
```

## Pool Sizing Guidelines

The optimal pool size depends on the number of concurrent database operations, not the number of application threads. A common starting point:

| Scenario | Min Pool | Max Pool | Notes |
|----------|----------|----------|-------|
| Web app (low traffic) | 5 | 20 | Most connections idle |
| Web app (moderate) | 10 | 50 | Monitor active vs idle ratio |
| Web app (high traffic) | 20 | 100 | Consider read replicas to reduce primary load |
| Background workers | 2 | 10 | Workers are usually serialized |
| Microservice (per instance) | 5 | 20 | Multiply by number of instances for total DB connections |

**Formula:** `max_pool_size = (core_count * 2) + effective_spindle_count` (HikariCP recommendation). For SSDs, start with `core_count * 2` and load-test.

**Warning signs of pool misconfiguration:**
- All connections in "active" state → pool too small, queries queuing
- Most connections in "idle" state → pool too large, wasting server resources
- `max_connections` errors → pool too large or connections leaking (not returned to pool)

## Exceptions

- **Short-lived scripts or CLI tools** that run a single query and exit do not benefit from pooling; the overhead of pool setup exceeds the savings.
- **Database migration runners** typically need a single long-lived connection with DDL privileges. Pooling is unnecessary.
- **Connection-per-tenant architectures** (one database per tenant) may need a pool per tenant; monitor total connection count across all pools.

## How to Detect

### MSSQL
```sql
SELECT login_name, program_name,
       COUNT(*) AS total,
       SUM(CASE WHEN status = 'sleeping' THEN 1 ELSE 0 END) AS idle,
       SUM(CASE WHEN status = 'running' THEN 1 ELSE 0 END) AS active
FROM sys.dm_exec_sessions
WHERE is_user_process = 1
GROUP BY login_name, program_name
ORDER BY total DESC;
```

### PostgreSQL
```sql
SELECT usename, application_name, state, COUNT(*)
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY usename, application_name, state
ORDER BY count DESC;
```

### Oracle
```sql
SELECT username, program, status, COUNT(*)
FROM v$session
WHERE type = 'USER'
GROUP BY username, program, status
ORDER BY COUNT(*) DESC;
```

### MySQL
```sql
SELECT user, host, db, command, COUNT(*) AS cnt
FROM information_schema.processlist
GROUP BY user, host, db, command
ORDER BY cnt DESC;
```
