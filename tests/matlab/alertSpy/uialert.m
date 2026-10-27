function uialert(fig, message, title, varargin)
%UIALERT Test double used by TAGGUITESTS: records each alert, then shows it.
%
%   This folder is on the path only while TagGuiTests runs, so that it
%   shadows MATLAB's uialert for the app's code. Each call appends a struct
%   (Figure, Message, Title) to the groot appdata "TagGuiTests_alerts" and
%   then calls the real uialert, whose handle TagGuiTests stores in the
%   groot appdata "TagGuiTests_realUialert" before this folder is added --
%   so the alert really appears, and the tests can also read its text.
%
%   See also TAGGUITESTS.

    entry = struct("Figure", fig, "Message", string(message), "Title", string(title));
    log = getappdata(groot, "TagGuiTests_alerts");
    if isempty(log)
        log = entry;
    else
        log(end+1) = entry;
    end
    setappdata(groot, "TagGuiTests_alerts", log);

    real = getappdata(groot, "TagGuiTests_realUialert");
    if ~isempty(real)
        real(fig, message, title, varargin{:});
    end
end
