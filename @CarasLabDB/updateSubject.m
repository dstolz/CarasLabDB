function updateSubject(obj, subjectId, opts)
%UPDATESUBJECT In-place update of a subject dimension row.
%
%   updateSubject(db, subjectId, Name=Value) updates the mutable descriptive
%   columns of ephys.subject for the given natural-key SubjectId. Unlike events
%   and artifacts, the subject dimension is NOT append-only (no immutability
%   trigger), so corrections are ordinary UPDATEs.
%
%   Only the arguments you supply are changed; omitted ones are left untouched
%   (they are not set to NULL). The natural key subject_id is never changed.
%
%   Name=Value:
%       SpeciesCode  - species lookup code
%       Sex          - "M" | "F" | "U"
%       Strain, Genotype, Source, Notes - free text
%       DateOfBirth  - datetime (date part is stored)
%
%   Example:
%       db.updateSubject("G-0421", Strain="Long-Evans", Notes="re-typed");
%
%   See also CARASLABDB, ADDSUBJECT, UPDATESESSION.

    arguments
        obj (1,1) CarasLabDB
        subjectId (1,1) string
        opts.SpeciesCode (1,1) string = string(missing)
        opts.Sex (1,1) string = string(missing)
        opts.Strain (1,1) string = string(missing)
        opts.Genotype (1,1) string = string(missing)
        opts.Source (1,1) string = string(missing)
        opts.DateOfBirth (1,1) datetime = NaT
        opts.Notes (1,1) string = string(missing)
    end

    obj.pCheckMember(opts.Sex, ["M", "F", "U"], "Sex");

    s = struct();
    s = obj.pSet(s, "species_code", opts.SpeciesCode);
    s = obj.pSet(s, "sex", opts.Sex);
    s = obj.pSet(s, "strain", opts.Strain);
    s = obj.pSet(s, "genotype", opts.Genotype);
    s = obj.pSet(s, "source", opts.Source);
    if obj.pIsProvided(opts.DateOfBirth)
        s.date_of_birth = string(opts.DateOfBirth, "yyyy-MM-dd");
    end
    s = obj.pSet(s, "notes", opts.Notes);

    obj.pUpdate(obj.pT("subject"), s, "subject_id = " + obj.sqlLiteral(subjectId));
end
