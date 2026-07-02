function updateSession(obj, sessionId, opts)
%UPDATESESSION In-place update of a session dimension row.
%
%   updateSession(db, sessionId, Name=Value) updates the mutable columns of
%   ephys.session for the given session_id (uuid). Like the subject dimension,
%   session is NOT append-only, so corrections are ordinary UPDATEs.
%
%   Only the arguments you supply are changed; omitted ones are left untouched.
%   The primary key session_id and the owning subject_id are never changed.
%
%   Name=Value:
%       Label         - session label (unique per subject)
%       StorageRootId - storage root id (integer)
%       RelativePath  - path relative to the storage root
%       StartedAt, EndedAt - datetime bounds of the session
%       Rig, Notes    - free text
%
%   See also CARASLABDB, ADDSESSION, UPDATESUBJECT.

    arguments
        obj (1,1) CarasLabDB
        sessionId (1,1) string
        opts.Label (1,1) string = string(missing)
        opts.StorageRootId double {mustBeInteger, mustBeScalarOrEmpty} = []
        opts.RelativePath (1,1) string = string(missing)
        opts.StartedAt (1,1) datetime = NaT
        opts.EndedAt (1,1) datetime = NaT
        opts.Rig (1,1) string = string(missing)
        opts.Notes (1,1) string = string(missing)
    end

    s = struct();
    s = obj.pSet(s, "label", opts.Label);
    s = obj.pSet(s, "storage_root_id", opts.StorageRootId);
    s = obj.pSet(s, "relative_path", opts.RelativePath);
    s = obj.pSet(s, "started_at", opts.StartedAt);
    s = obj.pSet(s, "ended_at", opts.EndedAt);
    s = obj.pSet(s, "rig", opts.Rig);
    s = obj.pSet(s, "notes", opts.Notes);

    obj.pUpdate(obj.pT("session"), s, "session_id = " + obj.sqlLiteral(sessionId));
end
