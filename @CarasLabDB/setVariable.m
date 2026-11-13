function valueId = setVariable(obj, kind, entityId, name, value, opts)
%SETVARIABLE Set a named value on an event, artifact, subject, session or project.
%
%   id = setVariable(db, "session", sid, "Probe Depth", 1200, Units="um", ...
%            Description="Depth of the probe tip below the pia")
%   id = setVariable(db, "session", sid, "probe depth", 1350)     % an update
%   id = setVariable(db, "subject", "G-0421", "housing", "pair")  % a string
%
%   A variable is a user-defined, named value for what the schema has no
%   column for. KIND is "event", "artifact", "subject", "session" or
%   "project" and ENTITYID that row's id (a uuid, or the subject_id). NAME is
%   canonicalised and validated locally (CarasLabDB.normalizeVariableName:
%   lower case, single spaces), so "Probe  Depth" and "probe depth" are one
%   variable. VALUE is one finite number or one non-blank string; NaN, Inf,
%   arrays and blank text raise CarasLabDB:invalidVariableValue (to clear a
%   value use UNSETVARIABLE).
%
%   The write goes through lab.fn_set_variable, so the database applies the
%   same rules as for psql or the GUI:
%     * a variable used for the first time is defined on the spot -- as a
%       number or as text according to VALUE -- with the Units, Label and
%       Description given here (see DEFINEVARIABLE to define it ahead);
%     * for a variable that already exists those three are not changed by
%       this call (use UPDATEVARIABLEDEFINITION), a number where it holds
%       text (or the reverse) is an error, and Units that differ from its
%       definition are an error: a value in mm cannot be filed under a
%       variable recorded in um. Omit Units to use the variable's own;
%     * a retired variable, or a kind outside its applies_to, is refused.
%   Setting a variable again is how it is updated: each call appends a row
%   to the value log (nothing is overwritten), GETVARIABLES shows the latest
%   and, with History=true, every earlier one.
%
%   A number is sent as the shortest decimal that reads back as the same
%   double (71.9 is stored as 71.9), and stored as numeric, not floating
%   point.
%
%   Name=Value:
%       Units       - units of the value ('um', 'g', 'dB SPL'); see above
%       Label       - common name shown to people, on first use ('Probe Depth')
%       Description - what the variable means, on first use
%       Note        - free text stored on this value's log row
%       SetBy       - person_id (default: the current person)
%
%   Returns the value_id of the log row written.
%
%   When an event or artifact is superseded, the database copies its current
%   variables to the successor; nothing needs to be done here.
%
%   See also CARASLABDB, UNSETVARIABLE, GETVARIABLES, GETVARIABLEVALUES,
%   DEFINEVARIABLE, GETVARIABLEDEFINITIONS.

    arguments
        obj (1,1) CarasLabDB
        kind (1,1) string {mustBeMember(kind, ["event", "artifact", "subject", "session", "project"])}
        entityId (1,1) string
        name (1,1) string
        value
        opts.Units (1,1) string = string(missing)
        opts.Label (1,1) string = string(missing)
        opts.Description (1,1) string = string(missing)
        opts.Note (1,1) string = string(missing)
        opts.SetBy (1,1) string = string(missing)
    end

    name = CarasLabDB.normalizeVariableName(name);
    % "p_number => 1200" or "p_text => 'pair'": exactly one of the two.
    valueArg = obj.pVariableValueArg(name, value);

    R = obj.pWrite("SELECT " + obj.pT("fn_set_variable") + "(" + ...
        obj.sqlLiteral(kind) + ", " + obj.sqlLiteral(entityId) + ", " + ...
        obj.sqlLiteral(name) + ", " + valueArg + ...
        ", p_units => " + obj.sqlLiteral(opts.Units) + ...
        ", p_label => " + obj.sqlLiteral(opts.Label) + ...
        ", p_description => " + obj.sqlLiteral(opts.Description) + ...
        ", p_note => " + obj.sqlLiteral(opts.Note) + ...
        ", p_by => " + obj.sqlLiteral(obj.pCreatedBy(opts.SetBy)) + "::uuid) AS value_id;");
    valueId = double(R.value_id(1));
end
