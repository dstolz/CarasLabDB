function diag_tx_probe()
%DIAG_TX_PROBE TEMPORARY CI diagnostic: transactions on the native PostgreSQL connection.
%   Runs the statement patterns of CarasLabDB.pTransact on connection A with
%   log_statement = all (so the server log shows everything the driver
%   sends for A's backend pid), while connection B reports what is
%   committed. Every line printed starts with DIAGTX.
    a = local_connect();
    b = local_connect();
    closer = onCleanup(@() local_close(a, b)); %#ok<NASGU>
    execute(b, "DROP TABLE IF EXISTS diag_tx");
    execute(b, "CREATE TABLE diag_tx (x int)");
    p = fetch(a, "SELECT pg_backend_pid() AS pid");
    fprintf("DIAGTX backend pid of A = %s\n", string(p.pid));
    execute(a, "SET log_statement = 'all'");

    local_mark(a, "S0 autocommit on: fetch with and without a trailing semicolon");
    fetch(a, "SELECT 1 AS one;");
    fetch(a, "SELECT 2 AS two");
    fetch(a, "INSERT INTO diag_tx VALUES (100) RETURNING x");
    execute(b, "DELETE FROM diag_tx");

    local_mark(a, "S1 failure path");
    a.AutoCommit = 'off';
    local_mark(a, "S1 AutoCommit is off");
    execute(a, "INSERT INTO diag_tx VALUES (1);");
    local_say("S1 after execute INSERT 1: B sees %s row(s)", local_count(b));
    T = fetch(a, "SELECT count(*) AS n FROM diag_tx;");
    local_say("S1 A counts %s; B sees %s", string(T.n), local_count(b));
    R = fetch(a, "INSERT INTO diag_tx VALUES (2) RETURNING x;");
    local_say("S1 fetch INSERT 2 RETURNING gave %s; B sees %s", string(R.x), local_count(b));
    x1 = fetch(a, "SELECT txid_current()::text AS x");
    x2 = fetch(a, "SELECT txid_current()::text AS x;");
    local_say("S1 txid before/after a failed probe: %s / %s", string(x1.x), string(x2.x));
    try
        execute(a, "INSERT INTO diag_tx VALUES ('bad');");
        local_say("S1 the bad INSERT did not raise");
    catch ME
        local_say("S1 bad INSERT raised: %s", strtrim(string(ME.message)));
    end
    local_say("S1 after the error: B sees %s", local_count(b));
    try
        T = fetch(a, "SELECT count(*) AS n FROM diag_tx");
        local_say("S1 after the error A can still query and counts %s", string(T.n));
    catch ME
        local_say("S1 after the error A cannot query: %s", strtrim(string(ME.message)));
    end
    local_mark(a, "S1 calling rollback");
    rollback(a);
    local_say("S1 after rollback: B sees %s", local_count(b));
    a.AutoCommit = 'on';
    local_say("S1 after AutoCommit on: B sees %s (0 means the transaction was atomic)", local_count(b));
    execute(b, "DELETE FROM diag_tx");

    local_mark(a, "S2 success path");
    a.AutoCommit = 'off';
    execute(a, "INSERT INTO diag_tx VALUES (10);");
    R = fetch(a, "INSERT INTO diag_tx VALUES (11) RETURNING x;");
    T = fetch(a, "SELECT count(*) AS n FROM diag_tx;");
    local_say("S2 before commit: returned %s, A counts %s, B sees %s (0 means nothing committed early)", ...
        string(R.x), string(T.n), local_count(b));
    local_mark(a, "S2 calling commit");
    commit(a);
    local_say("S2 after commit: B sees %s", local_count(b));
    a.AutoCommit = 'on';
    execute(b, "DELETE FROM diag_tx");

    local_mark(a, "S3 an error that the caller catches, then more work, then commit");
    a.AutoCommit = 'off';
    execute(a, "INSERT INTO diag_tx VALUES (20);");
    try
        fetch(a, "SELECT 1/0 AS boom");
    catch ME
        local_say("S3 caught: %s", strtrim(string(ME.message)));
    end
    local_say("S3 after the caught error: B sees %s", local_count(b));
    try
        execute(a, "INSERT INTO diag_tx VALUES (21);");
        local_say("S3 INSERT 21 after the caught error succeeded; B sees %s", local_count(b));
    catch ME
        local_say("S3 INSERT 21 after the caught error raised: %s", strtrim(string(ME.message)));
    end
    try
        commit(a);
        local_say("S3 commit succeeded");
    catch ME
        local_say("S3 commit raised: %s", strtrim(string(ME.message)));
    end
    a.AutoCommit = 'on';
    T = fetch(b, "SELECT coalesce(string_agg(x::text, ',' ORDER BY x), '(none)') AS xs FROM diag_tx");
    local_say("S3 committed rows: %s (20 and 21 both, or neither, is atomic; 21 alone is not)", string(T.xs));

    execute(b, "DELETE FROM diag_tx");
    execute(b, "DROP SEQUENCE IF EXISTS diag_seq CASCADE");
    execute(b, "CREATE SEQUENCE diag_seq");
    execute(b, "CREATE OR REPLACE FUNCTION diag_flaky() RETURNS int LANGUAGE plpgsql AS $f$ " + ...
        "BEGIN IF nextval('diag_seq') % 2 = 1 THEN RAISE EXCEPTION 'flaky failure'; END IF; RETURN 42; END $f$");

    local_mark(a, "S4 in a transaction: a fetch that fails on its first run and would succeed on a second");
    a.AutoCommit = 'off';
    execute(a, "INSERT INTO diag_tx VALUES (30);");
    try
        R = fetch(a, "SELECT diag_flaky() AS v;");
        local_say("S4 the flaky fetch RETURNED %s without an error", string(R.v));
    catch ME
        local_say("S4 the flaky fetch raised: %s", strtrim(string(ME.message)));
    end
    local_say("S4 the function ran %s time(s)", local_calls(b));
    try
        commit(a);
    catch ME
        local_say("S4 commit raised: %s", strtrim(string(ME.message)));
    end
    a.AutoCommit = 'on';
    local_say("S4 committed rows: %s", local_rows(b));
    execute(b, "DELETE FROM diag_tx");

    local_mark(a, "S5 autocommit: the same flaky fetch, then a flaky execute");
    execute(b, "ALTER SEQUENCE diag_seq RESTART");
    try
        R = fetch(a, "SELECT diag_flaky() AS v");
        local_say("S5 the flaky fetch RETURNED %s without an error", string(R.v));
    catch ME
        local_say("S5 the flaky fetch raised: %s", strtrim(string(ME.message)));
    end
    local_say("S5 after the fetch the function had run %s time(s)", local_calls(b));
    execute(b, "ALTER SEQUENCE diag_seq RESTART");
    try
        execute(a, "SELECT diag_flaky()");
        local_say("S5 the flaky execute returned without an error");
    catch ME
        local_say("S5 the flaky execute raised: %s", strtrim(string(ME.message)));
    end
    local_say("S5 after the execute the function had run %s time(s)", local_calls(b));

    local_mark(a, "S6 a marked transaction (SET LOCAL first), then fetch INSERT RETURNING twice");
    a.AutoCommit = 'off';
    execute(a, "SET LOCAL caraslabdb.txn = 'probe-mark';");
    fetch(a, "INSERT INTO diag_tx VALUES (40) RETURNING x;");
    fetch(a, "INSERT INTO diag_tx VALUES (41) RETURNING x;");
    M = fetch(a, "SELECT current_setting('caraslabdb.txn', true) AS marker");
    local_say("S6 mark read back before commit: '%s'; B sees %s", string(M.marker), local_count(b));
    commit(a);
    a.AutoCommit = 'on';
    local_say("S6 committed rows: %s", local_rows(b));
    execute(b, "DELETE FROM diag_tx");

    local_mark(a, "S7 an unmarked transaction that starts with fetch INSERT RETURNING, twice");
    a.AutoCommit = 'off';
    fetch(a, "INSERT INTO diag_tx VALUES (50) RETURNING x;");
    fetch(a, "INSERT INTO diag_tx VALUES (51) RETURNING x;");
    commit(a);
    a.AutoCommit = 'on';
    local_say("S7 committed rows: %s", local_rows(b));

    local_mark(a, "END");
    execute(b, "DROP FUNCTION diag_flaky()");
    execute(b, "DROP SEQUENCE diag_seq");
    execute(b, "DROP TABLE diag_tx");
end

function conn = local_connect()
    conn = postgresql("postgres", "postgres", Server="localhost", PortNumber=5432, ...
        DatabaseName="postgres");
end

function local_close(a, b)
    try, close(a); catch, end
    try, close(b); catch, end
end

function local_mark(conn, text)
    fprintf("DIAGTX ---- %s\n", text);
    execute(conn, "SELECT 'DIAGTX MARK " + text + "'");
end

function local_say(fmt, varargin)
    fprintf("DIAGTX " + fmt + "\n", varargin{:});
end

function n = local_calls(conn)
    T = fetch(conn, "SELECT CASE WHEN is_called THEN last_value ELSE 0 END AS n FROM diag_seq");
    n = string(T.n);
end

function xs = local_rows(conn)
    T = fetch(conn, "SELECT coalesce(string_agg(x::text, ',' ORDER BY x), '(none)') AS xs FROM diag_tx");
    xs = string(T.xs);
end

function n = local_count(conn)
    T = fetch(conn, "SELECT count(*) AS n FROM diag_tx");
    n = string(T.n);
end
