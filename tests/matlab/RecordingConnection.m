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
%   See also TAGTESTS, VARIABLETESTS.

    properties
        AutoCommit = 'on'
        Message = ""
        SchemaVersion = CarasLabDB.SchemaVersionExpected   % reported by the version query
        TagFilterProblems = table()     % reported by lab.fn_tag_filter_problems (token, problem)
        LoginPersonId (1,1) string = string(missing)   % reported by lab.fn_current_person()
    end

    properties (SetAccess = private)
        Log string = strings(0, 1)
    end

    methods
        function tf = isopen(~)
            tf = true;
        end

        function T = fetch(obj, sql)
            obj.Log(end+1, 1) = string(sql);
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
            obj.Log(end+1, 1) = string(sql);
        end

        function commit(~)
        end

        function rollback(~)
        end

        function close(~)
        end

        function clearLog(obj)
            obj.Log = strings(0, 1);
        end
    end
end
