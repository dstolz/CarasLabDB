function namespace = addTagNamespace(obj, namespace, opts)
%ADDTAGNAMESPACE Create a tag namespace (the part of a tag before the colon).
%
%   ns = addTagNamespace(db, "stage", Mutability="mutable", ...
%            Cardinality="single", AppliesTo="artifact", ...
%            OpenVocabulary=false, Description="Processing stage")
%
%   A namespace declares the policy for every tag in it:
%       Mutability     - "mutable": a tag of this namespace may later be
%                        removed or replaced on an entity (the log keeps the
%                        history). "immutable": once applied it is permanent.
%       Cardinality    - "single": an entity carries at most one current tag
%                        of this namespace ("stage:raw" OR "stage:sorted").
%                        "multi": any number ("topic:a" AND "topic:b").
%       AppliesTo      - string array of entity kinds the namespace may be
%                        applied to: "event", "artifact", "subject",
%                        "session", "project".
%       OpenVocabulary - true (default): addTag registers a value it has not
%                        seen before. false: only values registered
%                        deliberately with registerTag may be used.
%       Description    - free text.
%
%   Mutability, Cardinality and AppliesTo are frozen by the database once any
%   tag of the namespace has been applied (AppliesTo may still grow); see
%   UPDATETAGNAMESPACE. Names are lower-cased and trimmed; anything else that
%   does not match ^[a-z][a-z0-9_]{0,31}$ is rejected. The namespace "tag" is
%   reserved for tags written without a namespace ("auditory_cortex").
%
%   Returns the canonical namespace name.
%
%   See also CARASLABDB, UPDATETAGNAMESPACE, REGISTERTAG, ADDTAG, GETTAGNAMESPACES.

    arguments
        obj (1,1) CarasLabDB
        namespace (1,1) string
        opts.Mutability (1,1) string
        opts.Cardinality (1,1) string
        opts.AppliesTo (1,:) string
        opts.OpenVocabulary (1,1) logical = true
        opts.Description (1,1) string = string(missing)
        opts.CreatedBy (1,1) string = string(missing)
    end

    obj.pCheckMember(opts.Mutability, ["mutable", "immutable"], "Mutability");
    obj.pCheckMember(opts.Cardinality, ["single", "multi"], "Cardinality");
    s = struct("namespace", namespace, ...
               "mutability", opts.Mutability, ...
               "cardinality", opts.Cardinality, ...
               "applies_to", CarasLabDB.pAppliesToLiteral(opts.AppliesTo), ...
               "open_vocabulary", opts.OpenVocabulary);
    s = obj.pSet(s, "description", opts.Description);
    s = obj.pSet(s, "created_by", obj.pCreatedBy(opts.CreatedBy));
    namespace = obj.pInsertReturning(obj.pT("tag_namespace"), s, "namespace");
end
