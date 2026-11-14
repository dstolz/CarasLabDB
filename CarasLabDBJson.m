classdef CarasLabDBJson
%CARASLABDBJSON JSON text for a jsonb column, passed to PostgreSQL as written.
%
%   j = CarasLabDB.jsonText('{"Th": [9, 3], "fs": 30000.0}')
%
%   CarasLabDB.sqlLiteral sends a struct to a jsonb column through
%   jsonencode, which turns every number into a MATLAB double first. A
%   CarasLabDBJson value holds the JSON text itself and is sent unchanged,
%   so a document read from a file (a pipeline's options record, say) is
%   stored with the digits it was written with. The text is checked to
%   parse as JSON (jsondecode) when the value is made; nothing is
%   re-encoded.
%
%   withMember adds one member to a JSON object by editing the text, so the
%   rest of the document is still sent as written.
%
%   See also CARASLABDB, CARASLABDB.JSONTEXT, CARASLABDB.SQLLITERAL.

    properties (SetAccess = immutable)
        Text (1,1) string = "{}"     % the JSON text, as given
    end

    methods
        function obj = CarasLabDBJson(text)
            %CARASLABDBJSON JSON text, checked to parse.
            arguments
                text (1,1) string
            end
            if ismissing(text) || strlength(strip(text)) == 0
                error("CarasLabDB:invalidJson", "JSON text is missing or blank.");
            end
            try
                jsondecode(char(text));
            catch ME
                error("CarasLabDB:invalidJson", "The text is not valid JSON: %s", ME.message);
            end
            obj.Text = text;
        end

        function tf = isObject(obj)
            %ISOBJECT True if the text is a JSON object ({...}).
            tf = startsWith(strip(obj.Text), "{") && isstruct(jsondecode(char(obj.Text)));
        end

        function obj = withMember(obj, name, value, opts)
            %WITHMEMBER The object with member NAME = VALUE added at the front.
            %   j2 = j.withMember("client_digest", "9f86d0...")         % a JSON string
            %   j2 = j.withMember("unchanged_outputs", ids, Array=true)  % a JSON array
            %   NAME is a lower-case identifier. VALUE is a string scalar,
            %   sent as a JSON string, or with Array=true a string array of
            %   any length (also one or none), sent as a JSON array of
            %   strings. Only the text is edited: the member is inserted after
            %   the opening brace and the rest is kept character for
            %   character. The text must be an object that does not have the
            %   member already (CarasLabDB:invalidJson).
            arguments
                obj (1,1) CarasLabDBJson
                name (1,1) string
                value string
                opts.Array (1,1) logical = false
            end
            if isempty(regexp(char(name), '^[a-z_][a-z0-9_]*$', 'once'))
                error("CarasLabDB:invalidValue", ...
                    "A member name must be a lower-case identifier, not '%s'.", name);
            end
            if any(ismissing(value(:)))
                error("CarasLabDB:invalidValue", "Member %s has a missing value.", name);
            end
            if ~opts.Array && ~isscalar(value)
                error("CarasLabDB:invalidValue", ...
                    "Member %s takes one string; pass Array=true for a list.", name);
            end
            text = strip(obj.Text);
            decoded = jsondecode(char(text));
            if ~startsWith(text, "{") || ~isstruct(decoded) || ~isscalar(decoded)
                error("CarasLabDB:invalidJson", ...
                    "Member %s can only be added to a JSON object.", name);
            end
            % jsondecode makes each key a valid MATLAB name, and a valid
            % identifier stays as it is, so an existing member NAME shows up
            % as a field. (A key that only becomes NAME after that renaming
            % is refused too: better refused than stored twice.)
            if isfield(decoded, name)
                error("CarasLabDB:invalidJson", "The JSON object already has a member %s.", name);
            end
            if opts.Array
                % jsonencode writes a cell array as a JSON array whatever its length.
                valueText = string(jsonencode(cellstr(reshape(value, 1, []))));
            else
                valueText = string(jsonencode(value));
            end
            member = string(jsonencode(name)) + ":" + valueText;
            rest = extractAfter(text, 1);          % everything after the "{"
            if isempty(fieldnames(decoded))
                obj = CarasLabDBJson("{" + member + rest);
            else
                obj = CarasLabDBJson("{" + member + "," + rest);
            end
        end
    end
end
