function updateSubject(obj, subjectId, opts)
%UPDATESUBJECT In-place update of a subject dimension row.
%
%   updateSubject(db, subjectId, Name=Value) updates the mutable descriptive
%   columns of lab.subject for the given natural-key SubjectId. Unlike events
%   and artifacts, the subject dimension is NOT append-only (no immutability
%   trigger), so corrections are ordinary UPDATEs. The database records the
%   previous row, the new row and the login that changed it in
%   lab.row_history.
%
%   Only the arguments you supply are changed; omitted ones are left untouched
%   (they are not set to NULL -- use Clear= for that). The natural key
%   subject_id is never changed here: renaming an animal is identity
%   maintenance, done by an administrator with lab.fn_rename_subject.
%
%   Name=Value:
%       ProjectId    - project the subject belongs to (uuid)
%       SpeciesCode  - species lookup code
%       Sex          - "M" | "F" | "U"
%       Strain, Genotype, Source, Notes - free text
%       DateOfBirth  - datetime (date part is stored)
%       Clear        - database column names to set to NULL, any of
%                      "species_code", "strain", "genotype", "source",
%                      "date_of_birth", "notes". (project_id and sex cannot
%                      be NULL.) A column cannot be both cleared and set:
%                      that raises CarasLabDB:clearAndSet.
%
%   Example:
%       db.updateSubject("G-0421", Strain="Long-Evans", Notes="re-typed");
%       db.updateSubject("G-0421", Clear=["genotype", "notes"]);
%       db.updateSubject("G-0421", ProjectId=newProjectId);
%
%   See also CARASLABDB, ADDSUBJECT, UPDATESESSION.

    arguments
        obj (1,1) CarasLabDB
        subjectId (1,1) string
        opts.ProjectId (1,1) string = string(missing)
        opts.SpeciesCode (1,1) string = string(missing)
        opts.Sex (1,1) string = string(missing)
        opts.Strain (1,1) string = string(missing)
        opts.Genotype (1,1) string = string(missing)
        opts.Source (1,1) string = string(missing)
        opts.DateOfBirth (1,1) datetime = NaT
        opts.Notes (1,1) string = string(missing)
        opts.Clear (1,:) string = strings(1, 0)
    end

    obj.pCheckMember(opts.Sex, ["M", "F", "U"], "Sex");

    s = struct();
    s = obj.pSet(s, "project_id", opts.ProjectId);
    s = obj.pSet(s, "species_code", opts.SpeciesCode);
    s = obj.pSet(s, "sex", opts.Sex);
    s = obj.pSet(s, "strain", opts.Strain);
    s = obj.pSet(s, "genotype", opts.Genotype);
    s = obj.pSet(s, "source", opts.Source);
    if obj.pIsProvided(opts.DateOfBirth)
        s.date_of_birth = string(opts.DateOfBirth, "yyyy-MM-dd");
    end
    s = obj.pSet(s, "notes", opts.Notes);
    % Clear= names columns; pApplyClear admits only this fixed list of the
    % nullable ones, so the names never reach the SQL as caller text.
    s = obj.pApplyClear(s, opts.Clear, ...
        ["species_code", "strain", "genotype", "source", "date_of_birth", "notes"]);

    % subject_id is a hand-typed natural key, so a typo here would otherwise
    % update zero rows and report success; RETURNING reports the row count.
    n = obj.pUpdate(obj.pT("subject"), s, "subject_id = " + obj.sqlLiteral(subjectId), "subject_id");
    if n == 0
        error("CarasLabDB:subjectNotFound", "No subject with id %s.", subjectId);
    end
end
