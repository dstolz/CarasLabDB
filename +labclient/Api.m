classdef Api
    % labclient.Api  The version of this package's interface, for the toolboxes that record through it.
    %   The package and the toolboxes that use it are separate checkouts, so
    %   a computer can have a toolbox that calls what its copy of the package
    %   does not have yet. A toolbox asks once, where it decides whether the
    %   lab database can be used here:
    %
    %     [ok, why] = labclient.Api.atLeast(3)   % WHY says what to do when it is older
    %     v = labclient.Api.Version              % a whole number
    %
    %   A package from before this class has no version to ask for (it is
    %   version 1 or 2), so a toolbox looks for the class first:
    %
    %     ok = exist("labclient.Api", "class") == 8 && labclient.Api.atLeast(3);
    %
    %   Version goes up by one whenever something a toolbox can call, or the
    %   meaning of something it calls, changes. It does not go up for a
    %   change no toolbox can see. What each version added:
    %
    %     1  The package as first shared: Bundles, Outbox, Sync, DB, Settings,
    %        Secrets, Roots, Hasher, Lamp, Panel, SubjectCache, the backends;
    %        records of no dataset that name their subject, husbandry events,
    %        tool hooks (Sync.registerTool), replacement files (Bundles.files
    %        with an item's Replaces).
    %     2  A dataset record that names no tool belongs to no toolbox by
    %        default: Bundles.toolOf gives Bundles.Untagged, and such records
    %        are sent only through the tool registered with
    %        Sync.registerTool(..., TakesUntagged=true); Sync.untaggedTool.
    %     3  This class. A replacement file may name ANY earlier version of
    %        the file (Sync.replaceFile follows it to the one at the path, in
    %        whatever order the records arrive). Bundles.problems says what
    %        the database would refuse in a record, and Outbox.put keeps such
    %        a record held, with the reason, instead of sending it to fail;
    %        Bundles.isTimeText is the one test of a time in a record.
    %        FakeBackend holds a record to the database's rules: the Detail
    %        fields of every event type, when a disposition happened, and the
    %        policy for a replaced file.
    %
    %   The version is about what toolboxes call. The format of a record
    %   (labclient.Bundles.Format) and the schema of the database
    %   (CarasLabDB.SchemaVersionExpected) have their own.
    %
    %   See also labclient.Bundles, labclient.Sync, labclient.CarasBackend.

    properties (Constant)
        Version = 3   % see the list above when this changes, and add to it
    end

    methods (Static)
        function [ok, why] = atLeast(needed)
            %atLeast  Whether this package's interface is version NEEDED or later; WHY is "" or what to do.
            arguments
                needed (1,1) double {mustBeInteger, mustBePositive}
            end
            ok = labclient.Api.Version >= needed;
            why = "";
            if ~ok
                why = sprintf("The labclient package on the MATLAB path is version %d of its interface; " + ...
                    "version %d or later is needed. Update the CarasLabDB checkout (git pull).", ...
                    labclient.Api.Version, needed);
            end
        end
    end
end
