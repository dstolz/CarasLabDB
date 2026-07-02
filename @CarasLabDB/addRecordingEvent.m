function eventId = addRecordingEvent(obj, opts)
%ADDRECORDINGEVENT Insert a recording event (base + ephys.recording_event).
%
%   A recording event MUST reference a session: the database rejects the
%   insert if event.session_id is null. Pass SessionId=.
%
%   eventId = addRecordingEvent(db, OccurredAt=t, SubjectId="G-0421", ...
%                   SessionId=sid, AcquisitionSystemCode="intan_rhx", ...
%                   SampleRateHz=30000, NChannels=64, DurationS=1800)
%
%   Required:
%       OccurredAt   - datetime the recording occurred (timestamptz)
%   Common event Name=Value:
%       SubjectId, SessionId (required in practice), Notes, Attributes,
%       RecordedBy, RecordedAt, Supersedes
%   Recording-specific Name=Value:
%       AcquisitionSystemCode, ProbeId,
%       Modality ("ephys"|"video"|"behavior"|"multimodal"),
%       SampleRateHz, NChannels, DurationS, StimulusProtocol, HardwareConfig (jsonb)
%
%   Returns the generated event_id (uuid string).
%
%   See also CARASLABDB, ADDSESSION, ADDARTIFACT.

    arguments
        obj (1,1) CarasLabDB
        % --- base event ---
        opts.OccurredAt (1,1) datetime
        opts.SubjectId (1,1) string = string(missing)
        opts.SessionId (1,1) string = string(missing)
        opts.Notes (1,1) string = string(missing)
        opts.Attributes = []
        opts.RecordedBy (1,1) string = string(missing)
        opts.RecordedAt (1,1) datetime = NaT
        opts.Supersedes (1,1) string = string(missing)
        % --- recording detail ---
        opts.AcquisitionSystemCode (1,1) string = string(missing)
        opts.ProbeId (1,1) string = string(missing)
        opts.Modality (1,1) string = string(missing)
        opts.SampleRateHz (1,1) double = NaN
        opts.NChannels double {mustBeInteger, mustBeScalarOrEmpty} = []
        opts.DurationS (1,1) double = NaN
        opts.StimulusProtocol (1,1) string = string(missing)
        opts.HardwareConfig = []
    end

    obj.pCheckMember(opts.Modality, ["ephys", "video", "behavior", "multimodal"], "Modality");

    base = obj.pEventBase("recording", opts);

    detail = struct();
    detail = obj.pSet(detail, "acquisition_system_code", opts.AcquisitionSystemCode);
    detail = obj.pSet(detail, "probe_id",                opts.ProbeId);
    detail = obj.pSet(detail, "modality",                opts.Modality);
    detail = obj.pSet(detail, "sample_rate_hz",          opts.SampleRateHz);
    detail = obj.pSet(detail, "n_channels",              opts.NChannels);
    detail = obj.pSet(detail, "duration_s",              opts.DurationS);
    detail = obj.pSet(detail, "stimulus_protocol",       opts.StimulusProtocol);
    detail = obj.pSet(detail, "hardware_config",         opts.HardwareConfig);

    eventId = obj.pInsertEvent(base, obj.pT("recording_event"), detail);
end
