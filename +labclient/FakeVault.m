classdef FakeVault < handle
    % labclient.FakeVault  The in-memory password store labclient.Secrets.useFake switches to (tests).
    %   See also labclient.Secrets.
    properties
        Active (1,1) logical = false
        Map = containers.Map()
    end
end
