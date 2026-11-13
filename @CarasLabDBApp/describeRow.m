function s = describeRow(db, kind, entityId)
%DESCRIBEROW One line naming a row in a way a person can check.
%
%   s = CarasLabDBApp.describeRow(db, kind, entityId) returns "kind id"
%   followed by what identifies the row to a person:
%
%       event     type, subject, occurred_at
%       artifact  relative path
%       session   subject, label
%       project   name
%
%   so that the tag editor, the variables editor and the retraction dialog
%   all show which row they act on, to be checked against the row selected
%   in the main window. Events and artifacts are looked up in full history
%   (ActiveOnly=false), so a superseded or retracted row is still described.
%   A lookup that fails or finds nothing leaves the plain "kind id"; this
%   function never throws.
%
%   See also CARASLABDBAPP/SHOWTAGEDITOR, CARASLABDBAPP/SHOWVARIABLEEDITOR,
%   CARASLABDBAPP/SHOWRETRACTDIALOG.

    arguments
        db
        kind (1,1) string
        entityId (1,1) string
    end

    s = kind + " " + entityId;
    extra = strings(0, 1);
    try
        switch kind
            case "event"
                R = db.getEvents(EventId=entityId, ActiveOnly=false);
                if height(R) > 0
                    extra = [local_text(R.event_type(1)); local_text(R.subject_id(1)); ...
                             local_when(R.occurred_at(1))];
                end
            case "artifact"
                R = db.getArtifacts(ArtifactId=entityId, ActiveOnly=false);
                if height(R) > 0
                    extra = local_text(R.relative_path(1));
                end
            case "session"
                R = db.getSessions(SessionId=entityId);
                if height(R) > 0
                    extra = [local_text(R.subject_id(1)); local_text(R.label(1))];
                end
            case "project"
                R = db.getProjects(ProjectId=entityId);
                if height(R) > 0
                    extra = local_text(R.name(1));
                end
        end
        extra = extra(~ismissing(extra));
        extra = extra(strlength(extra) > 0);
        if ~isempty(extra)
            s = s + "  ·  " + strjoin(reshape(extra, 1, []), "  ·  ");
        end
    catch
        s = kind + " " + entityId;
    end
end

% =============================================================================
function s = local_text(col)
    %LOCAL_TEXT A fetched text value as a string column vector (NULL -> missing).
    if iscell(col)
        s = strings(numel(col), 1);
        for i = 1:numel(col)
            v = col{i};
            if (isstring(v) && isscalar(v)) || ischar(v)
                s(i) = string(v);
            else
                s(i) = string(missing);
            end
        end
    else
        s = reshape(string(col), [], 1);
    end
end

function s = local_when(col)
    %LOCAL_WHEN A timestamp as "yyyy-MM-dd HH:mm" text (the session zone is local).
    if isdatetime(col)
        col.Format = "yyyy-MM-dd HH:mm";
        s = reshape(string(col), [], 1);
    else
        s = local_text(col);
    end
    s(ismissing(s)) = "";
end
