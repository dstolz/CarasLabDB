function T = artifactLineage(obj, artifactId, opts)
%ARTIFACTLINEAGE Walk the provenance DAG from an artifact.
%
%   Wraps lab.fn_artifact_lineage(). Direction "up" returns ancestors
%   (the events and artifacts this one was derived from); "down" returns
%   descendants (what was derived from it).
%
%   T = artifactLineage(db, artifactId)                 % ancestors (up)
%   T = artifactLineage(db, artifactId, Direction="down")
%   T = artifactLineage(db, artifactId, FollowCorrections=false)
%
%   Name=Value:
%       Direction         - "up" (default) or "down"
%       FollowCorrections - true (default): corrections are followed. The
%                           walk is over current rows, whichever version
%                           artifactId names, and every event_id and
%                           artifact_id returned is the CURRENT version of
%                           that node -- so the ids can be passed straight
%                           to getEventDetail / getArtifacts, and a file
%                           derived from a since-corrected recording leads
%                           to the corrected recording.
%                           false: the rows exactly as they were recorded,
%                           superseded ones included (the audit view); an
%                           id returned may then be hidden by the *_active
%                           views (read it with ActiveOnly=false).
%
%   Returns a table with columns depth, event_id, artifact_id ordered by
%   depth (0 = the artifact itself).
%
%   See also CARASLABDB, GETPROVENANCEEDGES, ADDEVENTINPUT, SUPERSEDEEVENT.

    arguments
        obj (1,1) CarasLabDB
        artifactId (1,1) string
        opts.Direction (1,1) string {mustBeMember(opts.Direction, ["up", "down"])} = "up"
        opts.FollowCorrections (1,1) logical = true
    end

    fn = obj.pT("fn_artifact_lineage");
    sql = "SELECT depth, event_id, artifact_id FROM " + fn + "(" + ...
        obj.sqlLiteral(artifactId) + "::uuid, " + obj.sqlLiteral(opts.Direction) + ", " + ...
        obj.sqlLiteral(opts.FollowCorrections) + ") " + ...
        "ORDER BY depth, artifact_id, event_id;";
    T = obj.runQuery(sql);
end
