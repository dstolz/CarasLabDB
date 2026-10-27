function namespace = addTagNamespace(obj, opts)
%ADDTAGNAMESPACE Create a tag namespace and the policy its tags obey.
%
%   ns = addTagNamespace(db, Namespace="probe_site", Mutability="immutable", ...
%            Cardinality="single", AppliesTo=["session", "event"], ...
%            OpenVocabulary=true, Description="Recording site of the probe")
%
%   Required:
%       Namespace    - the name, as stored: a lower-case letter followed by at
%                      most 31 of a-z, 0-9 and _ (^[a-z][a-z0-9_]{0,31}$).
%                      Namespace names are not normalised -- "Probe_Site" is
%                      rejected here rather than silently lower-cased.
%       Mutability   - "mutable"   : a tag of this namespace can later be
%                                    removed or replaced (history is kept);
%                      "immutable" : once on an entity it is permanent.
%       Cardinality  - "single"    : at most one current tag of the namespace
%                                    per entity (stage:raw XOR stage:sorted);
%                      "multi"     : any number (topic:*).
%       AppliesTo    - the entity kinds its tags may be put on, any of
%                      "event", "artifact", "subject", "session", "project".
%   Optional Name=Value:
%       OpenVocabulary - true (default): addTag/setTag may create a new value
%                        on first use; false: values must be registered first
%                        with REGISTERTAG, so a typo cannot become vocabulary.
%       Description, CreatedBy
%
%   Choose the policy carefully: once any tag of the namespace has been
%   assigned, the database freezes Mutability and Cardinality and lets
%   AppliesTo only grow (see UPDATETAGNAMESPACE).
%
%   Returns the namespace name.
%
%   See also CARASLABDB, REGISTERTAG, ADDTAG, SETTAG, GETTAGNAMESPACES.

    arguments
        obj (1,1) CarasLabDB
        opts.Namespace (1,1) string
        opts.Mutability (1,1) string {mustBeMember(opts.Mutability, ["mutable", "immutable"])}
        opts.Cardinality (1,1) string {mustBeMember(opts.Cardinality, ["single", "multi"])}
        opts.AppliesTo string {mustBeNonempty}
        opts.OpenVocabulary (1,1) logical = true
        opts.Description (1,1) string = string(missing)
        opts.CreatedBy (1,1) string = string(missing)
    end

    if ismissing(opts.Namespace) || ...
            isempty(regexp(char(opts.Namespace), '^[a-z][a-z0-9_]{0,31}$', 'once'))
        error("CarasLabDB:invalidValue", ...
            "Namespace '%s' must be a lower-case letter followed by at most 31 " + ...
            "of a-z, 0-9 and _.", opts.Namespace);
    end

    s = struct( ...
        "namespace",       opts.Namespace, ...
        "mutability",      opts.Mutability, ...
        "cardinality",     opts.Cardinality, ...
        "open_vocabulary", opts.OpenVocabulary, ...
        "applies_to",      obj.pAppliesToLiteral(opts.AppliesTo));
    s = obj.pSet(s, "description", opts.Description);
    s = obj.pSet(s, "created_by",  obj.pCreatedBy(opts.CreatedBy));
    obj.pInsert(obj.pT("tag_namespace"), s);
    namespace = opts.Namespace;
end
