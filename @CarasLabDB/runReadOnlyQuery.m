function T = runReadOnlyQuery(obj, sql)
%RUNREADONLYQUERY Execute a row-returning statement inside a READ ONLY transaction.
%
%   T = runReadOnlyQuery(db, sql) runs SQL exactly like RUNQUERY, but wraps it
%   in a Postgres "READ ONLY" transaction so any write (INSERT/UPDATE/DELETE/
%   DDL) in the statement is rejected by the database itself. The transaction
%   is always rolled back, so nothing is committed regardless of content.
%   After the statement it checks that the transaction is still the
%   read-only one; if it is not, the result is withheld
%   (CarasLabDB:notReadOnly).
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
    readOnly = false;
    try
        % The driver opens the transaction itself when AutoCommit is turned
        % off, so this is SET TRANSACTION, not START TRANSACTION (a second
        % START draws "there is already a transaction in progress").
        execute(conn, "SET TRANSACTION READ ONLY;");
        % An unbounded query from the Custom SQL panel (a cartesian product, a
        % catastrophic regex, pg_sleep) would otherwise pin a backend and block
        % MATLAB in fetch() with no way to cancel.
        execute(conn, "SET LOCAL statement_timeout = '60s';");
        T = fetch(conn, sql);
        % Both settings last only as long as the transaction they were made
        % in. If the driver ended that transaction and ran the statement in
        % another, this says so.
        R = fetch(conn, "SELECT current_setting('transaction_read_only') AS read_only");
        readOnly = height(R) == 1 && isequal(CarasLabDB.pColText(R.read_only(1)), "on");
        rollback(conn);
    catch ME
        % After a failed statement the driver has already rolled back and
        % has no transaction open; the SELECT gives ROLLBACK one to end, so
        % the server does not log "there is no transaction in progress".
        try
            execute(conn, "SELECT 1;");
        catch
        end
        try
            rollback(conn);
        catch
        end
        rethrow(ME);
    end
    if ~readOnly
        error("CarasLabDB:notReadOnly", ...
            "The statement did not run inside the read-only transaction, so its " + ...
            "result is withheld. Anything it changed has been rolled back.");
    end
end
