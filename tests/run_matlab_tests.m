function run_matlab_tests()
%RUN_MATLAB_TESTS Run every test under tests/matlab and fail unless they pass.
%
%   The entry point of the "MATLAB tests" CI job, and usable by hand:
%
%       addpath("tests"); run_matlab_tests
%
%   It puts the repository root on the path (so the @CarasLabDB and
%   @CarasLabDBApp class folders are visible), runs the suite, prints the
%   diagnostics of the tests that did not pass once more at the end (each
%   distinct one once), and raises an error if any test failed.
%
%   The database tests are opt-in through CARASLABDB_MTEST_ADMIN (see
%   tests/matlab/LabScratchDb.m). When that variable is set -- as it is in
%   CI, where a PostgreSQL service is running -- a database test that did
%   not run means the scratch database could not be set up, and that is
%   reported as a failure too: otherwise a broken fixture would look like a
%   passing run. So is a test file that runtests could not load (it only
%   warns and leaves the file out): every *Tests.m file must contribute
%   results.

    here = fileparts(mfilename("fullpath"));
    repoRoot = fileparts(here);
    addpath(repoRoot);

    results = runtests(fullfile(here, "matlab"), "OutputDetail", "Detailed");
    if isempty(results)
        error("run_matlab_tests:noTests", "No tests were found under %s.", fullfile(here, "matlab"));
    end
    % runtests leaves out a test file it cannot load (a syntax error, two
    % methods with one name) with only a warning, and the run then passes
    % without its tests. Every *Tests.m file must have contributed results.
    files = dir(fullfile(here, "matlab", "*Tests.m"));
    names = string({results.Name});
    excluded = strings(1, 0);
    for k = 1:numel(files)
        [~, cls] = fileparts(files(k).name);
        if ~any(startsWith(names, cls + "/"))
            excluded(end+1) = string(cls); %#ok<AGROW>
        end
    end

    nPassed = nnz([results.Passed]);
    nFailed = nnz([results.Failed]);
    incomplete = [results.Incomplete] & ~[results.Failed];

    % The runner has already printed each diagnostic where it happened. Print
    % them again together, each distinct one once, so the end of the log is
    % enough to see what went wrong.
    try
        printDigest(results(~[results.Passed]));
    catch ME
        fprintf("(The failure digest could not be written: %s)\n", ME.message);
    end
    fprintf("MATLAB %s: %d passed, %d failed, %d not run, of %d tests\n", ...
        version("-release"), nPassed, nFailed, nnz(incomplete), numel(results));

    problems = strings(1, 0);
    if ~isempty(excluded)
        problems(end+1) = sprintf("%d test file(s) could not be loaded and did not run: %s " + ...
            "(see the warnings at the start of the log).", numel(excluded), strjoin(excluded, ", "));
    end
    if nFailed > 0
        problems(end+1) = sprintf("%d test(s) failed.", nFailed);
    end
    if strlength(string(getenv("CARASLABDB_MTEST_ADMIN"))) > 0 && any(incomplete)
        problems(end+1) = sprintf("%d test(s) did not run although a database was configured.", ...
            nnz(incomplete));
    end
    if ~isempty(problems)
        error("run_matlab_tests:failed", "%s", strjoin(problems, " "));
    end
end

function printDigest(bad)
%PRINTDIGEST The recorded diagnostics of the tests that did not pass, grouped.
%   Tests whose diagnostics are the same text, apart from the test's own
%   name, are listed under one copy of it.
    if isempty(bad)
        return
    end
    maxLines = 80;
    texts = strings(1, numel(bad));
    for i = 1:numel(bad)
        report = "(no diagnostic was recorded for this test; see the output above)";
        details = bad(i).Details;
        if isstruct(details) && isfield(details, "DiagnosticRecord") ...
                && ~isempty(details.DiagnosticRecord)
            parts = strings(1, numel(details.DiagnosticRecord));
            for k = 1:numel(details.DiagnosticRecord)
                parts(k) = string(details.DiagnosticRecord(k).Report);
            end
            report = strjoin(parts, newline);
        end
        texts(i) = replace(report, string(bad(i).Name), "<test>");
    end
    [distinct, ~, group] = unique(texts, "stable");
    fprintf("\n==== %d test(s) did not pass; %d distinct diagnostic(s) ====\n", ...
        numel(bad), numel(distinct));
    for g = 1:numel(distinct)
        names = string({bad(group == g).Name});
        fprintf("\n---- diagnostic %d of %d, %d test(s) ----\n", g, numel(distinct), numel(names));
        fprintf("%s\n", strjoin(names, newline));
        lines = splitlines(distinct(g));
        if numel(lines) > maxLines
            lines = [lines(1:maxLines); "... (" + (numel(lines) - maxLines) + " more lines above in the log)"];
        end
        fprintf("%s\n", strjoin(lines, newline));
    end
    fprintf("\n");
end
