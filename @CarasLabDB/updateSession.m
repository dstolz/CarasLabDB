function updateSession(obj, sessionId, opts)
%UPDATESESSION In-place update of a session dimension row.
%
%   updateSession(db, sessionId, Name=Value) updates the mutable columns of
%   lab.session for the given session_id (uuid). Like the subject dimension,
%   session is NOT append-only, so corrections are ordinary UPDATEs. The
%   database records the previous row, the new row and the login that
%   changed it in lab.row_history.
%
%   Only the arguments you supply are changed; omitted ones are left untouched
%   (they are not set to NULL -- use Clear= for that). The primary key
%   session_id and the owning subject_id are never changed.
%
%   Name=Value:
%       Label         - session label (unique per subject)
%       StorageRootId - storage root id (integer)
%       RelativePath  - path relative to the storage root
%       StartedAt, EndedAt - datetime bounds of the session
%       Rig, Notes    - free text
%       Clear         - database column names to set to NULL, any of
%                       "started_at", "ended_at", "rig", "notes". (label,
%                       storage_root_id and relative_path cannot be NULL.)
%                       A column cannot be both cleared and set: that raises
%                       CarasLabDB:clearAndSet.
%
%   Example:
%       db.updateSession(sid, Rig="rig-B");
%       db.updateSession(sid, Clear="ended_at");     % logged by mistake
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
        opts.Clear (1,:) string = strings(1, 0)
    end

    s = struct();
    s = obj.pSet(s, "label", opts.Label);
    s = obj.pSet(s, "storage_root_id", opts.StorageRootId);
    s = obj.pSet(s, "relative_path", opts.RelativePath);
    s = obj.pSet(s, "started_at", opts.StartedAt);
    s = obj.pSet(s, "ended_at", opts.EndedAt);
    s = obj.pSet(s, "rig", opts.Rig);
    s = obj.pSet(s, "notes", opts.Notes);
    % Clear= names columns; pApplyClear admits only this fixed list of the
    % nullable ones, so the names never reach the SQL as caller text.
    s = obj.pApplyClear(s, opts.Clear, ["started_at", "ended_at", "rig", "notes"]);

    % A wrong session_id would otherwise update zero rows and report success;
    % RETURNING reports the row count.
    n = obj.pUpdate(obj.pT("session"), s, "session_id = " + obj.sqlLiteral(sessionId), "session_id");
    if n == 0
        error("CarasLabDB:sessionNotFound", "No session with id %s.", sessionId);
    end
end
