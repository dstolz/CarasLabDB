function updateTagNamespace(obj, namespace, opts)
%UPDATETAGNAMESPACE Edit a tag namespace's description, vocabulary flag or kinds.
%
%   updateTagNamespace(db, "cohort", Description="Breeding cohort")
%   updateTagNamespace(db, "cohort", AppliesTo=["subject","session","event"])
%   updateTagNamespace(db, "stage", OpenVocabulary=true)
%
%   Mutability and Cardinality are deliberately not editable here: the
%   database freezes them (and forbids shrinking AppliesTo) once a tag of the
%   namespace has been applied, because relaxing a policy after the fact
%   would silently void the guarantee every existing tag was given. A
%   namespace that is not yet in use can be dropped and re-created instead.
%   Every change is recorded in lab.row_history.
%
%   See also CARASLABDB, ADDTAGNAMESPACE, GETTAGNAMESPACES.

    arguments
        obj (1,1) CarasLabDB
        namespace (1,1) string
        opts.Description (1,1) string = string(missing)
        opts.OpenVocabulary = []          % logical scalar or [] to leave as is
        opts.AppliesTo (1,:) string = strings(1, 0)
    end

    s = struct();
    s = obj.pSet(s, "description", opts.Description);
    s = obj.pSet(s, "open_vocabulary", opts.OpenVocabulary);
    if ~isempty(opts.AppliesTo)
        s.applies_to = CarasLabDB.pAppliesToLiteral(opts.AppliesTo);
    end
    n = obj.pUpdate(obj.pT("tag_namespace"), s, ...
        "namespace = " + obj.sqlLiteral(lower(strtrim(namespace))), "namespace");
    if n == 0
        error("CarasLabDB:tagNamespaceNotFound", "No tag namespace '%s'.", namespace);
    end
end
