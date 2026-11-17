function writeJsonFile(file, s, opts)
%writeJsonFile  Write a struct as pretty-printed JSON, atomically.
%   writeJsonFile(file, s) encodes S with jsonencode, writes it to a
%   temporary file next to FILE and renames it into place, so a crash
%   mid-write never leaves a truncated file, and two processes writing one
%   file never share a temporary name. Text=true: S is JSON text already
%   (a string or char row), written as it is with the same atomic rename.
%
%   A private copy of the helper of the same name in the ephys_analysis
%   toolbox, so the package needs nothing outside itself. Error identifier
%   labclient:writeJsonFile:CannotWrite.

arguments
    file (1,1) string
    s
    opts.Pretty (1,1) logical = true
    opts.Text (1,1) logical = false
end

if opts.Text
    txt = char(s);
    if ~isrow(txt)
        error('labclient:writeJsonFile:CannotWrite', 'Text must be one string or char row of JSON.');
    end
elseif opts.Pretty
    try
        txt = jsonencode(s, 'PrettyPrint', true);
    catch
        txt = jsonencode(s);   % releases before PrettyPrint support
    end
else
    txt = jsonencode(s);
end

file = char(file);
[outDir, base, ext] = fileparts(file);
if outDir == ""
    outDir = pwd;
end
if ~isfolder(outDir)
    [ok, msg] = mkdir(outDir);
    if ~ok
        error('labclient:writeJsonFile:CannotWrite', 'Cannot create %s: %s', outDir, msg);
    end
end
[~, uid] = fileparts(tempname);   % a name of this write's own
tmp = fullfile(outDir, ['~' base ext '.' uid '.partial']);

fid = fopen(tmp, 'w');
if fid < 0
    error('labclient:writeJsonFile:CannotWrite', 'Cannot open %s for writing.', tmp);
end
try
    fwrite(fid, txt, 'char');
    fclose(fid);
catch ME
    fclose(fid);
    if isfile(tmp); delete(tmp); end
    error('labclient:writeJsonFile:CannotWrite', 'Cannot write %s: %s', tmp, ME.message);
end

[ok, msg] = movefile(tmp, file, 'f');
if ~ok
    if isfile(tmp); delete(tmp); end
    error('labclient:writeJsonFile:CannotWrite', 'Cannot move %s to %s: %s', tmp, file, msg);
end
end
