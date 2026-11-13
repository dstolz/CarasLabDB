function run_matlab_tests()
%RUN_MATLAB_TESTS Run every test under tests/matlab and fail unless they pass.
%
%   The entry point of the "MATLAB tests" CI job, and usable by hand:
%
%       addpath("tests"); run_matlab_tests
%
%   It puts the repository root on the path (so the @CarasLabDB and
%   @CarasLabDBApp class folders are visible), runs the suite, prints one
%   line per test, and raises an error if any test failed.
%
%   The database tests are opt-in through CARASLABDB_MTEST_ADMIN (see
%   tests/matlab/LabScratchDb.m). When that variable is set -- as it is in
%   CI, where a PostgreSQL service is running -- a database test that did
%   not run means the scratch database could not be set up, and that is
%   reported as a failure too: otherwise a broken fixture would look like a
%   passing run.

    here = fileparts(mfilename("fullpath"));
    repoRoot = fileparts(here);
    addpath(repoRoot);

    results = runtests(fullfile(here, "matlab"), "OutputDetail", "Detailed");
    if isempty(results)
        error("run_matlab_tests:noTests", "No tests were found under %s.", fullfile(here, "matlab"));
    end

    T = table(results);
    disp(T(:, ["Name", "Passed", "Failed", "Incomplete", "Duration"]));

    nPassed = nnz([results.Passed]);
    nFailed = nnz([results.Failed]);
    incomplete = [results.Incomplete] & ~[results.Failed];
    fprintf("MATLAB %s: %d passed, %d failed, %d not run, of %d tests\n", ...
        version("-release"), nPassed, nFailed, nnz(incomplete), numel(results));

    problems = strings(1, 0);
    if nFailed > 0
        problems(end+1) = sprintf("%d test(s) failed: %s", nFailed, ...
            strjoin(string({results([results.Failed]).Name}), ", "));
    end
    if strlength(string(getenv("CARASLABDB_MTEST_ADMIN"))) > 0 && any(incomplete)
        problems(end+1) = sprintf(["%d test(s) did not run although a database was " ...
            "configured: %s"], nnz(incomplete), ...
            strjoin(string({results(incomplete).Name}), ", "));
    end
    if ~isempty(problems)
        error("run_matlab_tests:failed", "%s", strjoin(problems, newline));
    end
end
