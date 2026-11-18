function h = fileSha256(file, opts)
%labclient.fileSha256  SHA-256 of a file (or of text) as 64 lowercase hexadecimal digits.
%   H = labclient.fileSha256(FILE) reads FILE in 64 MB chunks and returns its SHA-256
%   as a string of 64 lowercase hexadecimal digits, the form certutil,
%   Get-FileHash and sha256sum print (lower case).
%   H = labclient.fileSha256(TEXT, Text=true) hashes the UTF-8 bytes of the string
%   TEXT instead of a file.
%
%   It uses Java's java.security.MessageDigest, so it runs in the MATLAB
%   client and in process-based workers, not in thread-based workers
%   (backgroundPool), which cannot run Java: there it errors with
%   labclient:fileSha256:NoJava. A file that cannot be opened is labclient:fileSha256:CannotRead.
%   Large files are better hashed out of process (labclient.Hasher), so the
%   caller does not wait.
%
%   See also labclient.Hasher.

arguments
    file (1,1) string
    opts.Text (1,1) logical = false
end

try
    md = java.security.MessageDigest.getInstance('SHA-256');
catch ME
    error('labclient:fileSha256:NoJava', 'SHA-256 needs Java, which is not available here: %s', ME.message);
end
if opts.Text
    b = unicode2native(char(file), 'UTF-8');
    if ~isempty(b)
        md.update(typecast(uint8(b(:)), 'int8'));
    end
else
    fid = fopen(file, 'r');
    if fid < 0
        error('labclient:fileSha256:CannotRead', 'Cannot open %s to hash it.', file);
    end
    closer = onCleanup(@() fclose(fid));
    while true
        b = fread(fid, 64 * 2^20, '*uint8');
        if isempty(b); break; end
        md.update(typecast(b, 'int8'));
    end
end
h = string(lower(reshape(dec2hex(typecast(md.digest(), 'uint8'), 2).', 1, [])));
end
