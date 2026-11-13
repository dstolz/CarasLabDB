function checksum = fileChecksum(filePath, opts)
%FILECHECKSUM Checksum of a file's contents as lower-case hex (static).
%
%   c = CarasLabDB.fileChecksum("Z:\data\G-0421\raw.dat")            % SHA-256, 64 chars
%   c = CarasLabDB.fileChecksum("Z:\data\G-0421\raw.dat", Algo="md5")  % 32 chars
%
%   Reads the file in chunks (8 MiB at a time, so a recording of any size
%   fits in memory) and digests it with java.security.MessageDigest. The
%   result is the form lab.artifact.checksum stores: lower-case hex of the
%   exact width of the algorithm.
%
%   NOT YET RUN. This function was written where no MATLAB was available and
%   has never been executed. Before relying on it, compare its result for a
%   few files -- including an empty one and one larger than 8 MiB -- with a
%   known-good tool and make sure they are identical:
%       Windows:  certutil -hashfile "Z:\data\G-0421\raw.dat" SHA256
%       macOS:    shasum -a 256 /Volumes/data/G-0421/raw.dat
%       Linux:    sha256sum /mnt/data/G-0421/raw.dat
%   (certutil prints upper- or lower-case hex depending on the Windows
%   version; compare ignoring case.) A wrong checksum registered here would
%   make every later integrity check of the file report a mismatch.
%
%   Requires the Java virtual machine (MATLAB not started with -nojvm).
%
%   Name=Value:
%       Algo - "sha256" (default) or "md5"
%
%   See also CARASLABDB, ADDARTIFACTFROMFILE, ADDARTIFACT, ADDARTIFACTVERIFICATION.

    arguments
        filePath (1,1) string
        opts.Algo (1,1) string {mustBeMember(opts.Algo, ["sha256", "md5"])} = "sha256"
    end

    if ~usejava('jvm')
        error("CarasLabDB:noJava", ...
            "fileChecksum needs the Java virtual machine (MATLAB was started without it).");
    end
    if ismissing(filePath) || ~isfile(filePath)
        error("CarasLabDB:fileNotFound", "No file at %s.", filePath);
    end

    if opts.Algo == "sha256"
        javaName = 'SHA-256';
    else
        javaName = 'MD5';
    end
    digester = java.security.MessageDigest.getInstance(javaName);

    fid = fopen(char(filePath), 'r');
    if fid < 0
        error("CarasLabDB:fileNotReadable", "Could not open %s for reading.", filePath);
    end
    closeFile = onCleanup(@() fclose(fid)); %#ok<NASGU>

    chunkBytes = 8 * 2^20;
    while true
        bytes = fread(fid, chunkBytes, '*uint8');
        if isempty(bytes)
            break
        end
        % update(byte[] input, int offset, int len): the three-argument form,
        % so that a one-byte chunk cannot be taken for update(byte).
        digester.update(bytes, 0, numel(bytes));
    end

    % digest() returns Java bytes, which arrive as SIGNED int8 (-128..127).
    % typecast reinterprets the same bits as 0..255; a plain uint8() would
    % saturate every negative byte to 0 and corrupt the hash.
    raw = typecast(digester.digest(), 'uint8');
    % dec2hex gives one row of two hex digits per byte; read row by row.
    hexDigits = dec2hex(raw, 2);
    checksum = string(lower(reshape(hexDigits', 1, [])));
end
