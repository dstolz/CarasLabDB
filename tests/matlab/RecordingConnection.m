classdef RecordingConnection < handle
%RECORDINGCONNECTION Test double for a Database Toolbox connection: records SQL.
%
%   conn = RecordingConnection();
%   db   = CarasLabDB(Connection=conn, PersonId="00000000-0000-0000-0000-000000000001");
%   conn.clearLog();
%   ... call db methods ...
%   conn.Log          % every statement sent, in order
%
%   It answers the queries CarasLabDB's constructor sends -- the
%   schema_version probe, the version (SchemaVersion, by default the one the
%   class expects), the check that a supplied PersonId exists, and
%   lab.fn_current_person() (LoginPersonId, by default missing: the login is
%   mapped to nobody) -- and lab.fn_tag_filter_problems (TagFilterProblems,
%   by default no rows: every filter is sound). Every other fetch returns an
%   empty table, so a method that reaches the database gets as far as its
%   first use of a result. No server is involved, so the tests that use it
%   run without the Database Toolbox -- on any release the class supports.
%
%   The statements CarasLabDB.pTransact adds around a write (the SET LOCAL
%   that marks the transaction, the query that reads the mark back before
%   COMMIT, and the SELECT 1 before a ROLLBACK) are kept out of Log, in
%   Control, so Log holds what the method under test asked for; LogVia and
%   LogInTransaction say, entry by entry, whether it came through fetch or
%   execute and whether AutoCommit was off at the time. Commits and
%   Rollbacks count the calls. Results maps a piece of SQL text to the table
%   a fetch containing it returns. Set LoseTransaction to make the mark read
%   back empty, as it does when the driver has rolled the transaction back
%   part-way.
%
%   See also TAGTESTS, VARIABLETESTS.

    properties
        AutoCommit = 'on'
        Message = ""
        SchemaVersion = CarasLabDB.SchemaVersionExpected   % reported by the version query
        TagFilterProblems = table()     % reported by lab.fn_tag_filter_problems (token, problem)
        LoginPersonId (1,1) string = string(missing)   % reported by lab.fn_current_person()
        Results                         % containers.Map: SQL fragment -> table a fetch containing it returns
        LoseTransaction (1,1) logical = false   % the transaction mark reads back empty
    end

    properties (SetAccess = private)
        Log string = strings(0, 1)
        LogVia string = strings(0, 1)   % "fetch" or "execute", one per Log entry
        LogInTransaction logical = false(0, 1)   % AutoCommit was off when the entry was sent
        Control string = strings(0, 1)  % the statements pTransact adds, in order
        Commits (1,1) double = 0
        Rollbacks (1,1) double = 0
    end

    properties (Access = private)
        Marker (1,1) string = ""
    end

    methods
        function obj = RecordingConnection()
            % A containers.Map written as a property default would be one
            % map shared by every instance.
            obj.Results = containers.Map();
        end

        function tf = isopen(~)
            tf = true;
        end

        function T = fetch(obj, sql)
            if contains(sql, "current_setting('caraslabdb.txn'")
                obj.Control(end+1, 1) = string(sql);
                if obj.LoseTransaction
                    T = table("", 'VariableNames', {'marker'});
                else
                    T = table(obj.Marker, 'VariableNames', {'marker'});
                end
                return
            end
            obj.record(sql, "fetch");
            for key = string(keys(obj.Results))
                if contains(sql, key)
                    T = obj.Results(char(key));
                    return
                end
            end
            if contains(sql, "to_regclass")
                T = table(true, 'VariableNames', {'present'});
            elseif contains(sql, "max(version)")
                T = table(obj.SchemaVersion, 'VariableNames', {'v'});
            elseif contains(sql, "fn_current_person()")
                % The person the login is mapped to: one row, NULL for nobody.
                T = table(obj.LoginPersonId, 'VariableNames', {'person_id'});
            elseif contains(sql, "person WHERE person_id = ")
                % The check that a supplied PersonId exists: it does.
                T = table("00000000-0000-0000-0000-000000000001", 'VariableNames', {'person_id'});
            elseif contains(sql, "fn_tag_filter_problems")
                T = obj.TagFilterProblems;
            else
                T = table();
            end
        end

        function execute(obj, sql)
            mark = extractBetween(string(sql), "SET LOCAL caraslabdb.txn = '", "'");
            if startsWith(string(sql), "SET LOCAL caraslabdb.txn = ") && ~isempty(mark)
                obj.Control(end+1, 1) = string(sql);
                obj.Marker = mark(1);
            elseif strtrim(string(sql)) == "SELECT 1;"
                obj.Control(end+1, 1) = string(sql);
            else
                obj.record(sql, "execute");
            end
        end

        function commit(obj)
            obj.Commits = obj.Commits + 1;
            obj.Marker = "";
        end

        function rollback(obj)
            obj.Rollbacks = obj.Rollbacks + 1;
            obj.Marker = "";
        end

        function close(~)
        end

        function clearLog(obj)
            obj.Log = strings(0, 1);
            obj.LogVia = strings(0, 1);
            obj.LogInTransaction = false(0, 1);
            obj.Control = strings(0, 1);
            obj.Commits = 0;
            obj.Rollbacks = 0;
        end
    end

    methods (Access = private)
        function record(obj, sql, via)
            obj.Log(end+1, 1) = string(sql);
            obj.LogVia(end+1, 1) = via;
            obj.LogInTransaction(end+1, 1) = strcmpi(string(obj.AutoCommit), "off");
        end
    end
end
