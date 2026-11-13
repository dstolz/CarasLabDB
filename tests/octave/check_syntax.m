function check_syntax(root)
%CHECK_SYNTAX Parse every MATLAB file of a prepared copy of the repository with Octave.
%
%   Called by tests/check_matlab_syntax.py on the copy that script prepares
%   (see there for what is rewritten and why). Octave cannot RUN this code --
%   it has no string type, datetime, table, Database Toolbox or
%   matlab.unittest -- so this checks one thing only: that every file is
%   syntactically well formed. A file counts as failed only when Octave
%   reports a parse error; an error raised after parsing (an unknown
%   MATLAB-only base class or function met while loading a class) means the
%   file parsed.
  warning('off', 'all');
  files = [glob(fullfile(root, '@CarasLabDB', '*.m')); glob(fullfile(root, '@CarasLabDBApp', '*.m')); ...
           glob(fullfile(root, 'tests', '*.m')); glob(fullfile(root, 'tests', 'matlab', '*.m')); ...
           glob(fullfile(root, 'tests', 'matlab', '*', '*.m')); glob(fullfile(root, 'examples', '*.m'))];
  classes = {'CarasLabDB', 'CarasLabDBApp'};
  nbad = 0;
  nchecked = 0;
  addpath(root);
  for i = 1:numel(files)
    f = files{i};
    [~, base] = fileparts(f);
    msg = '';
    try
      if any(strcmp(base, classes)) && ~isempty(strfind(f, ['@' base]))
        % A classdef that declares methods kept in other files of its
        % @-folder can only be parsed as a class on the path.
        meta.class.fromName(base);
      else
        __parse_file__(f);
      end
    catch err
      msg = regexprep(err.message, '\s+', ' ');
    end
    nchecked++;
    if ~isempty(strfind(msg, 'parse error'))
      nbad++;
      msg = strrep(msg, [root filesep], '');
      printf('SYNTAX ERROR %s\n    %s\n', strrep(f, [root filesep], ''), msg(1:min(end, 300)));
    end
  end
  printf('check_matlab_syntax: %d files parsed by Octave %s, %d with syntax errors\n', ...
         nchecked, version(), nbad);
  if nchecked == 0 || nbad > 0
    exit(1);
  end
end
