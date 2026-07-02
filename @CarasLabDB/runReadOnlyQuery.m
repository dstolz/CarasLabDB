function T = runReadOnlyQuery(obj, sql)
%RUNREADONLYQUERY Execute a row-returning statement inside a READ ONLY transaction.
%
%   T = runReadOnlyQuery(db, sql) runs SQL exactly like RUNQUERY, but wraps it
%   in a Postgres "READ ONLY" transaction so any write (INSERT/UPDATE/DELETE/
%   DDL) in the statement is rejected by the database itself. The transaction
%   is always rolled back, so nothing is committed regardless of content.
%
%   This is the safe execution path for user-supplied SQL (e.g. the Custom SQL
%   panel of @CarasLabDBApp), complementing any caller-side syntactic guard: a
%   query that slips past the guard still cannot mutate the database.
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
    restore = onCleanup(@() obj.pRestoreAutoCommit(conn, priorAutoCommit));
    conn.AutoCommit = 'off';
    try
        % Must be the first statement of the transaction to take effect.
        execute(conn, "SET TRANSACTION READ ONLY;");
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
