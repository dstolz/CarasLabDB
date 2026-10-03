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
%   "subject_id", "weight_g"). Every column not overridden is carried forward
%   from the superseded row exactly as stored -- read as the text Postgres
%   prints for it and written back as that text, so numbers keep their digits
%   and timestamps their instant and microseconds (see pRowsAsText).
%   recorded_by is set to the current person; recorded_at is regenerated.
%
%   In the same transaction the correction also carries over the event's
%   provenance:
%     * its event_input edges (the artifacts it consumed) are copied to the
%       new event;
%     * every active artifact it produced is superseded by a copy whose
%       produced_by_event_id is the new event, so the corrected event lists
%       its files. Without this the files stay attached to the hidden row
%       and lab.fn_check_integrity() reports them as
%       artifact_producer_superseded.
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

    where = "r.event_id = " + obj.sqlLiteral(oldEventId);

    E = obj.pRowsAsText(obj.pT("event"), where, "event_id");
    if isempty(E)
        error("CarasLabDB:eventNotFound", "No event with id %s.", oldEventId);
    end
    E = E{1};
    eventType = E.event_type;
    detailTable = obj.pT(obj.pDetailTable(eventType));

    D = obj.pRowsAsText(detailTable, where, "event_id");
    if isempty(D)
        error("CarasLabDB:detailNotFound", ...
            "No %s detail row for event %s.", eventType, oldEventId);
    end
    D = D{1};

    % --- the new base event: every column carried forward except the ones
    % regenerated for the new row, then the overrides ---
    base = rmfield(E, intersect(fieldnames(E), ...
        {'event_id', 'recorded_at', 'recorded_by', 'supersedes'}));
    if obj.pIsProvided(opts.OccurredAt)
        base.occurred_at = opts.OccurredAt;
    end
    if obj.pIsProvided(opts.Notes)
        base.notes = opts.Notes;
    end
    base = obj.pSet(base, "recorded_by", obj.pCreatedBy(string(missing)));
    base = obj.pMergeOverrides(base, opts.EventOverrides);
    base.supersedes = oldEventId;   % always point at the row we replace

    % --- the new detail row: every column carried forward, then overrides
    % (event_id and event_type are set by pInsertEvent) ---
    detail = rmfield(D, intersect(fieldnames(D), {'event_id', 'event_type'}));
    detail = obj.pMergeOverrides(detail, opts.DetailOverrides);

    % Carry the provenance edges forward. Without this the correction silently
    % orphans the DAG: event_input rows still point at the superseded event, so
    % fn_artifact_lineage(...,'up') from anything this event produced walks into
    % a node with no inputs and reports no ancestry -- while event_active hides
    % the old event that still holds them.
    inputs = obj.pRowsAsText(obj.pT("event_input"), where, "artifact_id");
    for k = 1:numel(inputs)
        inputs{k} = rmfield(inputs{k}, "event_id");   % set by pInsertEvent
    end

    % Re-point the files this event produced at the corrected event.
    produced = obj.pRowsAsText(obj.pT("artifact_active"), ...
        "r.produced_by_event_id = " + obj.sqlLiteral(oldEventId), "artifact_id");
    for k = 1:numel(produced)
        produced{k} = obj.pArtifactSuccessor(produced{k});
    end

    newEventId = obj.pInsertEvent(base, detailTable, detail, inputs, produced);
end
