# The Database Toolbox's PostgreSQL connection: what it does, and what the class does about it

`@CarasLabDB` talks to PostgreSQL through the native `postgresql()` connection
of MATLAB's Database Toolbox. This page records how that connection behaves
where it matters for correctness, and the rules the class follows as a result.

**How this was established.** Each behaviour below was observed by running
statements from MATLAB in CI with the server's `log_statement = all`, and
reading what reached the server, on MATLAB R2024b, R2025a and R2026b (Linux,
PostgreSQL 16, November 2026). The three releases behaved identically. None of
it is documented by MathWorks, and it has not been observed on Windows. The
class does not rely on these behaviours staying the same: where one of them is
a hazard, the class checks the outcome instead (see "Rules").

## What the driver does

1. **`fetch` is preceded by a metadata probe.** With AutoCommit on, before
   running `fetch(conn, sql)` the driver sends
   `SELECT * FROM (<sql>) as temp LIMIT 0` to learn the column types. If that
   fails, it runs `<sql>` anyway. So a statement ending in a semicolon, an
   `INSERT ... RETURNING` and a `SHOW` each put a syntax error in the server
   log before they run. The driver's own `SHOW max_connections` at connection
   time does the same, once per connection; that one cannot be avoided.
   `execute` sends no probe.
2. **A valid probe runs nothing.** PostgreSQL does not evaluate the inner
   query of a `LIMIT 0`, so a probe around `SELECT lab.fn_tag(...)` writes
   nothing (`tests/schema_test.sql` asserts this on every supported
   PostgreSQL version).
3. **AutoCommit off sends `BEGIN` at once**, and `commit` / `rollback` send
   `COMMIT` / `ROLLBACK`. Multi-statement writes are real transactions: a
   second connection sees nothing until the commit.
4. **Inside a transaction the probe is sent only for the first statement.**
   Once a statement has been executed in the transaction, later `fetch` calls
   are sent as written, with no probe. If the first statement is a `fetch`
   whose probe fails, the driver sends `ROLLBACK`, `BEGIN` and then the
   statement.
5. **On a statement error inside a transaction the driver rolls back by
   itself.** It sends `ROLLBACK` immediately and `BEGIN` again before the
   next statement. MATLAB code that catches the error and carries on is then
   working in a new transaction: what it did before the error is gone, and
   what it does afterwards will be committed.
6. **A failed `fetch` is run a second time.** The driver sends the same
   statement again; inside a transaction it does so after the `ROLLBACK` and
   `BEGIN` of point 5. If the statement succeeds this time (the first failure
   was a deadlock, a lock timeout, or anything else that does not repeat),
   `fetch` returns normally and no error reaches MATLAB, although everything
   earlier in the transaction has been rolled back. `execute` does not do
   this: it raises the error.

Points 5 and 6 together mean that a multi-statement transaction can commit its
second half without its first, with no error. PostgreSQL itself never does
this (after an error it refuses everything until the transaction ends); it is
the driver's recovery that makes it possible.

## Rules the class follows

- **`pTransact` marks its transaction and checks the mark before `COMMIT`.**
  Its first statement is `SET LOCAL caraslabdb.txn = '<unique value>'`, which
  lasts exactly as long as the transaction. Before committing it reads the
  value back; if the driver has rolled the transaction back in the meantime
  the value is gone, the commit is refused with
  `CarasLabDB:transactionInterrupted`, and nothing is written. The caller
  repeats the whole operation. `TagTests/retriedStatementCannotHalfCommit`
  exercises this against the real driver with a statement that fails once.
- **Never catch a database error inside a `pTransact` body and continue.**
  The mark would refuse the commit, but the code after the catch would be
  running against a database that no longer holds what it wrote.
- **A read goes through `pSelect`** (or the public `runQuery`), which removes
  a trailing semicolon so that the probe is valid.
- **A statement that writes and returns rows goes through `pWrite`**
  (`INSERT`/`UPDATE ... RETURNING`, `SELECT lab.fn_...()`). It always runs
  inside `pTransact`, after the mark, where the driver sends no probe; the
  statement keeps its semicolon, so that if a probe were ever sent it would
  fail rather than be evaluated.
- **A statement that returns nothing goes through `pExec`** (`execute`).
- **`runReadOnlyQuery`** sets `SET TRANSACTION READ ONLY` and a statement
  timeout, runs the statement, and then checks that the transaction is still
  read-only before returning the result (`CarasLabDB:notReadOnly` otherwise),
  for the same reason: the settings last only as long as the transaction they
  were made in.

`VariableTests/fetchedWritesAreInTransactionsAndReadsAreBare` checks the
`pSelect` / `pWrite` split for the class's public methods without a database.

## What remains in the server log

With these rules a normal session leaves one `syntax error` per connection in
the PostgreSQL log (the driver's `SHOW max_connections` probe), plus the
errors the database raises on purpose: a refused tag, a constraint violation.
The app's Custom SQL panel goes through `runReadOnlyQuery`, where the typed
statement is never the first of its transaction, so it is not probed either.

## Running system commands from MATLAB on Linux

The test fixture runs `psql` through `system()`. Two things were needed there,
both specific to Linux: MATLAB puts its own library folders on
`LD_LIBRARY_PATH`, and they hold a `libpq` the system's `psql` cannot use; and
MATLAB runs the command on a pseudo-terminal, where `psql` starts its pager
and waits for a key. The fixture therefore runs `psql` with that variable
removed, with `-P pager=off`, and with its input closed. It also restores an
unset `PG*` environment variable as unset rather than empty, because the
Database Toolbox reads the same variables and an empty `PGCONNECT_TIMEOUT` is
an error.
