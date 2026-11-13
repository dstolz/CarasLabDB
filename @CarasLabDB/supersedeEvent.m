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
%   newId = supersedeEvent(db, oldEventId, ...
%               DetailOverrides=struct("water_ml", missing))     % clear a value
%   newId = supersedeEvent(db, oldEventId, CarryInputs=false)    % then addEventInput
%
%   Name=Value:
%       OccurredAt      - override the base occurred_at (datetime)
%       Notes           - override the base notes
%       EventOverrides  - struct of lab.event column -> new value
%       DetailOverrides - struct of detail-table column -> new value
%       CarryInputs     - true (default): copy the old event's event_input
%                         edges to the new event. false: copy none, because
%                         the inputs themselves were wrong; declare the right
%                         ones on the returned event with ADDEVENTINPUT.
%
%   Override struct field names must be actual database column names (e.g.
%   "subject_id", "weight_g"). A field holding missing, string(missing), NaN,
%   NaT or [] sets that column to NULL. Every column not overridden is
%   carried forward from the superseded row exactly as stored -- read as the
%   text Postgres prints for it and written back as that text, so numbers
%   keep their digits and timestamps their instant and microseconds (see
%   pRowsAsText). recorded_by is set to the current person; recorded_at is
%   regenerated, and recorded_login is stamped by the database.
%
%   In the same transaction the correction also takes over the event's
%   provenance (the same carry-forward as Supersedes= on an addXEvent method):
%     * its event_input edges (the artifacts it consumed) are copied to the
%       new event, unless CarryInputs=false. A correction that declares no
%       inputs where the old event had some is reported by
%       lab.fn_check_integrity() as input_not_carried_forward;
%     * every active artifact it produced is superseded by a copy whose
%       produced_by_event_id is the new event, so the corrected event lists
%       its files. The copy is filed under the new event's subject_id and
%       session_id wherever the new event has one, so a correction that
%       moves the event to another animal or session moves its files with
%       it (the database rejects a file left under the old one);
%     * the event's current tags, and each re-pointed artifact's, are
%       copied onto the new rows (new 'add' rows in lab.tag_assignment
%       noted "carried forward from <old id>"), so the correction matches
%       the same tag filters. Retired tags cannot be assigned and are
%       skipped with a CarasLabDB:retiredTagsNotCarried warning
%       (fn_check_integrity then reports tag_not_carried_forward).
%
%   Returns the new event_id (uuid string).
%
%   See also CARASLABDB, SUPERSEDEARTIFACT, ADDEVENTINPUT, ARTIFACTLINEAGE.

    arguments
        obj (1,1) CarasLabDB
        oldEventId (1,1) string
        opts.OccurredAt (1,1) datetime = NaT
        opts.Notes (1,1) string = string(missing)
        opts.EventOverrides (1,1) struct = struct()
        opts.DetailOverrides (1,1) struct = struct()
        opts.CarryInputs (1,1) logical = true
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
    % regenerated for the new row (recorded_login is stamped by the
    % database), then the overrides ---
    base = rmfield(E, intersect(fieldnames(E), ...
        {'event_id', 'recorded_at', 'recorded_by', 'recorded_login', 'supersedes'}));
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

    % base.supersedes makes pInsertEvent carry the old event's provenance
    % forward -- its input edges (unless CarryInputs=false), the files it
    % produced and the tags -- in the same transaction as the two inserts.
    % Without that the correction silently orphans the DAG: the edges and
    % files stay on a row event_active hides.
    newEventId = obj.pInsertEvent(base, detailTable, detail, CarryInputs=opts.CarryInputs);
end
