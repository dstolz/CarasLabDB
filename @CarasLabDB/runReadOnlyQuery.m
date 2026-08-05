function T = runReadOnlyQuery(obj, sql)
%RUNREADONLYQUERY Execute a row-returning statement inside a READ ONLY transaction.
%
%   T = runReadOnlyQuery(db, sql) runs SQL exactly like RUNQUERY, but wraps it
%   in a Postgres "READ ONLY" transaction so any write (INSERT/UPDATE/DELETE/
%   DDL) in the statement is rejected by the database itself. The transaction
%   is always rolled back, so nothing is committed regardless of content.
%
%   This is the safe execution path for user-supplied SQL (e.g. the Custom SQL
%   panel of @CarasLabDBApp), complementing any caller-side syntactic guard.
%
%   Scope of the guarantee -- read this before relying on it:
%     * It stops writes on THIS connection's transaction. It does not stop a
%       statement that opens its own connection (dblink, postgres_fdw), and it
%       does not stop resource exhaustion, hence the statement_timeout below.
%     * A payload containing COMMIT would end this transaction and start a
%       fresh read-write one. The driver is not expected to pass multiple
%       statements, but the durable fix is a Postgres role with no write
%       grants; treat this wrapper as defence in depth, not a boundary.
%
%   Returns the result as a MATLAB table.
%
%   See also CARASLABDB, CARASLABDB/RUNQUERY.

    arguments
        obj (1,1) CarasLabDB
        sql (1,1) string
    end

    conn = obj.Connection;
    priorAutoCommit = conn.AutoCommit;
    % Refuse to run inside a caller's transaction: the rollback below would
    % silently discard their uncommitted work.
    if strcmpi(string(priorAutoCommit), "off")
        error("CarasLabDB:transactionInProgress", ...
            "AutoCommit is already off: another transaction is in progress " + ...
            "on this connection. Commit or roll it back first.");
    end
    restore = onCleanup(@() obj.pRestoreAutoCommit(conn, priorAutoCommit));
    conn.AutoCommit = 'off';
    try
        % START TRANSACTION rather than SET TRANSACTION: the latter errors if
        % no transaction block is open yet, and whether the native postgresql()
        % interface has already opened one is driver-dependent.
        execute(conn, "START TRANSACTION READ ONLY;");
        % An unbounded query from the Custom SQL panel (a cartesian product, a
        % catastrophic regex, pg_sleep) would otherwise pin a backend and block
        % MATLAB in fetch() with no way to cancel.
        execute(conn, "SET LOCAL statement_timeout = '60s';");
        T = fetch(conn, sql);
        rollback(conn);
    catch ME
        try
            rollback(conn);
        catch
        end
        rethrow(ME);
    end
end
