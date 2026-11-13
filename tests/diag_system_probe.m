function diag_system_probe()
%DIAG_SYSTEM_PROBE TEMPORARY CI diagnostic: what system() gives a child process.
%   Every command is bounded by timeout(1), so a command that would wait for
%   ever reports exit status 124 instead.
    psqlArgs = "psql -X -q -A -t -w -h localhost -U postgres -d postgres -c ""select 41 + 1""";
    cmds = [ ...
        "echo hello"
        "test -t 0 && echo stdin-is-a-tty || echo stdin-is-not-a-tty; test -t 1 && echo stdout-is-a-tty || echo stdout-is-not-a-tty; ls -l /proc/self/fd"
        "echo SHELL=$SHELL; echo LD_LIBRARY_PATH=$LD_LIBRARY_PATH; command -v psql; ls -l $(command -v psql)"
        "timeout 20 psql --version < /dev/null 2>&1"
        "timeout 20 env -u LD_LIBRARY_PATH psql --version < /dev/null 2>&1"
        "timeout 20 env -u LD_LIBRARY_PATH " + psqlArgs + " < /dev/null 2>&1"
        "timeout 20 env -u LD_LIBRARY_PATH " + psqlArgs + " -P pager=off 2>&1"
        "timeout 20 env -u LD_LIBRARY_PATH " + psqlArgs + " 2>&1"
        "timeout 20 env -u LD_LIBRARY_PATH -u DYLD_LIBRARY_PATH " + psqlArgs + " 2>&1"
        ];
    for i = 1:numel(cmds)
        t = tic;
        [status, out] = system(cmds(i));
        fprintf("---- %s\nexit %d after %.1f s\n%s\n", cmds(i), status, toc(t), out);
    end
end
