function T = artifactLineage(obj, artifactId, opts)
%ARTIFACTLINEAGE Walk the provenance DAG from an artifact.
%
%   Wraps lab.fn_artifact_lineage(). Direction "up" returns ancestors
%   (the events and artifacts this one was derived from); "down" returns
%   descendants (what was derived from it).
%
%   T = artifactLineage(db, artifactId)                 % ancestors (up)
%   T = artifactLineage(db, artifactId, Direction="down")
%
%   Returns a table with columns depth, event_id, artifact_id ordered by
%   depth (0 = the artifact itself).
%
%   See also CARASLABDB, GETPROVENANCEEDGES, ADDEVENTINPUT.

    arguments
        obj (1,1) CarasLabDB
        artifactId (1,1) string
        opts.Direction (1,1) string {mustBeMember(opts.Direction, ["up", "down"])} = "up"
    end

    fn = obj.pT("fn_artifact_lineage");
    sql = "SELECT depth, event_id, artifact_id FROM " + fn + "(" + ...
        obj.sqlLiteral(artifactId) + "::uuid, " + obj.sqlLiteral(opts.Direction) + ") " + ...
        "ORDER BY depth;";
    T = obj.runQuery(sql);
end
