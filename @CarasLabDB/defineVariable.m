function name = defineVariable(obj, name, opts)
%DEFINEVARIABLE Define a variable without setting it on anything.
%
%   n = defineVariable(db, "Probe Depth", Units="um", ...
%           Description="Depth of the probe tip below the pia")
%   n = defineVariable(db, "housing", ValueType="text", AppliesTo="subject")
%
%   SETVARIABLE defines a variable on first use, so this is only needed to
%   fix a variable's meaning ahead of the data: its value type, its units,
%   and the kinds of row it may be set on. The name is canonicalised and
%   validated locally (CarasLabDB.normalizeVariableName), then
%   lab.fn_define_variable creates the definition.
%
%   Defining a variable that already exists changes nothing and returns its
%   name, provided the ValueType and Units asked for are the ones it has;
%   otherwise the database raises an error rather than let two meanings
%   share a name. (Label and Description of an existing variable are edited
%   with UPDATEVARIABLEDEFINITION.)
%
%   Name=Value:
%       ValueType   - "number" (default) or "text"
%       Units       - units of every value ('um', 'g', 'dB SPL'); omit for none
%       Label       - common name shown to people (default: the name)
%       Description - what the variable means
%       AppliesTo   - the kinds of row it may be set on, any of "event",
%                     "artifact", "subject", "session", "project"
%                     (default: all five)
%       CreatedBy   - person_id (default: the current person)
%
%   Once the variable has a value, its value type and units are frozen and
%   AppliesTo may only grow. Returns the canonical name.
%
%   See also CARASLABDB, SETVARIABLE, GETVARIABLEDEFINITIONS,
%   UPDATEVARIABLEDEFINITION, RETIREVARIABLE.

    arguments
        obj (1,1) CarasLabDB
        name (1,1) string
        opts.ValueType (1,1) string {mustBeMember(opts.ValueType, ["number", "text"])} = "number"
        opts.Units (1,1) string = string(missing)
        opts.Label (1,1) string = string(missing)
        opts.Description (1,1) string = string(missing)
        opts.AppliesTo string = strings(1, 0)
        opts.CreatedBy (1,1) string = string(missing)
    end

    name = CarasLabDB.normalizeVariableName(name);

    % NULL means "all five kinds" to lab.fn_define_variable. A list is
    % validated against the five known words (pAppliesToLiteral), so the
    % array literal can only ever contain those.
    appliesTo = "NULL::text[]";
    if ~isempty(opts.AppliesTo)
        appliesTo = obj.sqlLiteral(obj.pAppliesToLiteral(opts.AppliesTo)) + "::text[]";
    end

    obj.pSelect("SELECT " + obj.pT("fn_define_variable") + "(" + ...
        obj.sqlLiteral(name) + ", " + obj.sqlLiteral(opts.ValueType) + ...
        ", p_units => " + obj.sqlLiteral(opts.Units) + ...
        ", p_label => " + obj.sqlLiteral(opts.Label) + ...
        ", p_description => " + obj.sqlLiteral(opts.Description) + ...
        ", p_applies_to => " + appliesTo + ...
        ", p_by => " + obj.sqlLiteral(obj.pCreatedBy(opts.CreatedBy)) + "::uuid) AS name;");
end
