function s = readJsonFile(file, opts)
%readJsonFile  Read and decode a JSON file (S = jsondecode(fileread(file))).
%   ErrorOnFail=false returns [] for a missing or unparsable file instead of
%   raising. Error identifiers: labclient:readJsonFile:NotFound, :BadJson.
%
%   Private to the package, so it needs nothing outside itself.

arguments
    file (1,1) string
    opts.ErrorOnFail (1,1) logical = true
end

s = [];
if ~isfile(file)
    if opts.ErrorOnFail
        error('labclient:readJsonFile:NotFound', 'JSON file not found: %s', file);
    end
    return
end
try
    s = jsondecode(fileread(file));
catch ME
    if opts.ErrorOnFail
        error('labclient:readJsonFile:BadJson', 'Cannot parse %s: %s', file, ME.message);
    end
    s = [];
end
end
