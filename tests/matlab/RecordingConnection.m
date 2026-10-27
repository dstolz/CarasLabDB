classdef RecordingConnection < handle
%RECORDINGCONNECTION Test double for a Database Toolbox connection: records SQL.
%
%   conn = RecordingConnection();
%   db   = CarasLabDB(Connection=conn, PersonId="00000000-0000-0000-0000-000000000001");
%   conn.clearLog();
%   ... call db methods ...
%   conn.Log          % every statement sent, in order
%
%   It answers the two queries CarasLabDB's constructor sends (the
%   schema_version probe and version, reported as the version the class
%   expects) and returns an empty table for every other fetch, so a method
%   that reaches the database gets as far as its first use of a result.
%   No server is involved, so the tests that use it run without the
%   Database Toolbox -- on any release the class supports.
%
%   See also TAGTESTS.

    properties
        AutoCommit = 'on'
        Message = ""
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
                T = table(CarasLabDB.SchemaVersionExpected, 'VariableNames', {'v'});
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
