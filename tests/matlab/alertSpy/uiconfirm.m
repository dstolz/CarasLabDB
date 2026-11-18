function answer = uiconfirm(fig, message, title, varargin)
%UICONFIRM Test double used by TAGGUITESTS: records each confirmation, answers it when told to.
%
%   This folder is on the path only while TagGuiTests runs, so that it
%   shadows MATLAB's uiconfirm for the app's code. Each call appends a
%   struct (Figure, Message, Title) to the groot appdata
%   "TagGuiTests_confirms". When the groot appdata
%   "TagGuiTests_confirmAnswer" holds an option text, that is the answer and
%   no dialog is shown (matlab.uitest cannot answer a uiconfirm from inside
%   the timer callback that drives a modal window). Otherwise the real
%   uiconfirm, whose handle TagGuiTests stores in the groot appdata
%   "TagGuiTests_realUiconfirm" before this folder is added, is shown and
%   its answer returned, as without this folder.
%
%   See also TAGGUITESTS, UIALERT (in this folder).

    entry = struct("Figure", fig, "Message", string(message), "Title", string(title));
    log = getappdata(groot, "TagGuiTests_confirms");
    if isempty(log)
        log = entry;
    else
        log(end+1) = entry;
    end
    setappdata(groot, "TagGuiTests_confirms", log);

    preset = getappdata(groot, "TagGuiTests_confirmAnswer");
    if ~isempty(preset)
        answer = char(preset);
        return
    end
    real = getappdata(groot, "TagGuiTests_realUiconfirm");
    answer = real(fig, message, title, varargin{:});
end
