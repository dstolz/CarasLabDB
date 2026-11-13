function T = getVariables(obj, kind, entityId, opts)
%GETVARIABLES The variables of one event, artifact, subject, session or project.
%
%   T = getVariables(db, "session", sid)                 % current values
%   H = getVariables(db, "session", sid, History=true)   % the full log
%
%   History=false (default) reads lab.variable_current: one row per variable
%   the row has a value for now, ordered by variable, with columns
%       variable    the canonical name ('probe depth')
%       label       the common name shown to people ('Probe Depth')
%       value       the value as text, whichever kind it is (exact digits)
%       value_num   the number (NaN for a text variable)
%       value_text  the string (missing for a number variable)
%       units       from the variable's definition (missing = none)
%       value_type  'number' or 'text'
%       note        the note stored with this value
%       set_at      when this value was set -- its "last updated" time
%       set_by      person_id of who set it
%       set_login   the database login that wrote the row
%
%   History=true reads the lab.variable_value log: every 'set' and 'unset'
%   ever written for the row, oldest first, with columns value_id, variable,
%   op, value_num, value_text, note, set_at, set_by, set_login.
%
%   An event or artifact that corrects another starts with its predecessor's
%   current variables (copied by the database, noted "carried forward from
%   <old id>", keeping each value's set_at and set_by).
%
%   Example:
%       T = db.getVariables("session", sid);
%       depth = T.value_num(T.variable == "probe depth");
%
%   See also CARASLABDB, SETVARIABLE, UNSETVARIABLE, GETVARIABLEVALUES,
%   GETVARIABLEDEFINITIONS.

    arguments
        obj (1,1) CarasLabDB
        kind (1,1) string {mustBeMember(kind, ["event", "artifact", "subject", "session", "project"])}
        entityId (1,1) string
        opts.History (1,1) logical = false
    end

    % The id column of a kind has the same name in the variable tables as in
    % the tag tables, so the fixed kind -> column map is shared.
    [~, pk] = obj.pTagEntity(kind);
    where = " WHERE x.entity_kind = " + obj.sqlLiteral(kind) + ...
        " AND x." + pk + " = " + obj.sqlLiteral(entityId);

    if opts.History
        sql = "SELECT x.value_id, x.variable, x.op, x.value_num, x.value_text, " + ...
            "x.note, x.set_at, x.set_by, x.set_login FROM " + obj.pT("variable_value") + ...
            " x" + where + " ORDER BY x.value_id;";
    else
        sql = "SELECT x.variable, x.label, x.value, x.value_num, x.value_text, " + ...
            "x.units, x.value_type, x.note, x.set_at, x.set_by, x.set_login FROM " + ...
            obj.pT("variable_current") + " x" + where + " ORDER BY x.variable;";
    end
    T = obj.pSelect(sql);
end
