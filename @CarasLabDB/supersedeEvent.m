function newEventId = supersedeEvent(obj, oldEventId, opts)
%SUPERSEDEEVENT Correct an event by inserting a superseding copy.
%
%   The schema is append-only. To "edit" an event you insert a new event of
%   the same type whose supersedes column points at the row being replaced;
%   the event_active view then hides the old row. This helper reads the old
%   base + detail rows, applies your overrides, and inserts the new pair in
%   one transaction.
%
%   newId = supersedeEvent(db, oldEventId)                       % exact re-log
%   newId = supersedeEvent(db, oldEventId, Notes="corrected weight")
%   newId = supersedeEvent(db, oldEventId, ...
%               DetailOverrides=struct("weight_g", 71.9))
%   newId = supersedeEvent(db, oldEventId, ...
%               EventOverrides=struct("session_id", sid), OccurredAt=t)
%
%   Name=Value:
%       OccurredAt      - override the base occurred_at (datetime)
%       Notes           - override the base notes
%       EventOverrides  - struct of lab.event column -> new value
%       DetailOverrides - struct of detail-table column -> new value
%
%   Override struct field names must be actual database column names (e.g.
%   "subject_id", "weight_g"). Any column not overridden is carried forward
%   from the superseded row. recorded_by is set to the current person.
%
%   The event's event_input edges (the artifacts it consumed) are copied to
%   the new event in the same transaction. Note the converse is NOT done:
%   artifacts the old event *produced* keep pointing at the superseded
%   event_id, since artifact rows are themselves immutable -- use
%   supersedeArtifact if those need to be re-pointed.
%
%   Returns the new event_id (uuid string).
%
%   See also CARASLABDB, SUPERSEDEARTIFACT.

    arguments
        obj (1,1) CarasLabDB
        oldEventId (1,1) string
        opts.OccurredAt (1,1) datetime = NaT
        opts.Notes (1,1) string = string(missing)
        opts.EventOverrides (1,1) struct = struct()
        opts.DetailOverrides (1,1) struct = struct()
    end

    if isfield(opts.EventOverrides, "supersedes")
        error("CarasLabDB:supersedesNotOverridable", ...
            "supersedes is set by this method and cannot be overridden.");
    end

    litId = obj.sqlLiteral(oldEventId);

    % occurred_at is read back as an explicit UTC text literal rather than as a
    % datetime. The Database Toolbox returns timestamptz as an *unzoned*
    % datetime, and sqlLiteral tags an unzoned datetime as "local" -- so a
    % round-trip through MATLAB shifts the instant by the UTC offset whenever
    % the server session zone is not the workstation's zone (a UTC server and
    % an Eastern workstation move every corrected event by 4-5 hours, and each
    % further correction moves it again). Text with an explicit offset also
    % preserves Postgres's microseconds, which the datetime format string
    % truncates to milliseconds.
    E = obj.pSelect("SELECT event_type, subject_id, session_id, " + ...
        "to_char(occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') " + ...
        "  || '+00' AS occurred_at_txt, " + ...
        "notes, attributes FROM " + obj.pT("event") + " WHERE event_id = " + litId + ";");
    if height(E) == 0
        error("CarasLabDB:eventNotFound", "No event with id %s.", oldEventId);
    end
    eventType = string(E.event_type(1));
    detailTable = obj.pT(obj.pDetailTable(eventType));

    D = obj.pSelect("SELECT * FROM " + detailTable + " WHERE event_id = " + litId + ";");
    if height(D) == 0
        error("CarasLabDB:detailNotFound", ...
            "No %s detail row for event %s.", eventType, oldEventId);
    end

    % --- assemble the new base event from the old row + overrides ---
    base = struct("event_type", eventType);
    if obj.pIsProvided(opts.OccurredAt)
        base.occurred_at = opts.OccurredAt;
    else
        base.occurred_at = local_scalar(E.occurred_at_txt);
    end
    base = obj.pSet(base, "subject_id", local_scalar(E.subject_id));
    base = obj.pSet(base, "session_id", local_scalar(E.session_id));
    if obj.pIsProvided(opts.Notes)
        base.notes = opts.Notes;
    else
        base = obj.pSet(base, "notes", local_scalar(E.notes));
    end
    base = obj.pSet(base, "attributes", local_scalar(E.attributes));
    base = obj.pSet(base, "recorded_by", obj.pCreatedBy(string(missing)));
    base = obj.pMergeOverrides(base, opts.EventOverrides);
    base.supersedes = oldEventId;   % always point at the row we replace

    % --- assemble the new detail row, carrying every column forward ---
    detail = struct();
    dcols = string(D.Properties.VariableNames);
    for i = 1:numel(dcols)
        c = dcols(i);
        if ismember(c, ["event_id", "event_type"])
            continue    % set by pInsertEvent
        end
        detail = obj.pSet(detail, c, local_scalar(D.(c)));
    end
    detail = obj.pMergeOverrides(detail, opts.DetailOverrides);

    % Carry the provenance edges forward. Without this the correction silently
    % orphans the DAG: event_input rows still point at the superseded event, so
    % fn_artifact_lineage(...,'up') from anything this event produced walks into
    % a node with no inputs and reports no ancestry -- while event_active hides
    % the old event that still holds them. pInsertEvent writes them inside the
    % same transaction as the base and detail rows.
    IN = obj.pSelect("SELECT artifact_id, role FROM " + obj.pT("event_input") + ...
        " WHERE event_id = " + litId + ";");

    newEventId = obj.pInsertEvent(base, detailTable, detail, IN);
end

function v = local_scalar(colvals)
%LOCAL_SCALAR Extract row-1 of a fetched table column as an insertable scalar.
    if isempty(colvals)
        v = string(missing);
        return
    end
    if iscell(colvals)
        v = colvals{1};
    else
        v = colvals(1);
    end
    if ischar(v)
        if isempty(v)
            v = string(missing);
        else
            v = string(v);
        end
    end
end
