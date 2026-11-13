function tf = confirmChanges(fig, what, changes, note)
%CONFIRMCHANGES Show what an edit is about to write and ask before writing it.
%
%   tf = CarasLabDBApp.confirmChanges(fig, what, changes) shows one
%   confirmation on the window FIG that lists every changed field as
%
%       Label:  old value  →  new value
%
%   and returns true only if the user chooses Save. WHAT is the first line
%   (which row is being changed). CHANGES is a struct array with the string
%   fields Label, Old and New, as the editors build it from
%   CarasLabDBApp.fieldChange and CarasLabDBApp.formatValue; New is
%   "(cleared)" for a field the user emptied.
%
%   tf = CarasLabDBApp.confirmChanges(fig, what, changes, note) adds NOTE as
%   a last paragraph (for example what a correction does to the original).
%
%   The subject, session and event editors call this from pFormDialog's
%   accept hook, i.e. while the form is still open: "Go back" returns to the
%   form with everything the user typed, and nothing has been written.
%
%   See also CARASLABDBAPP/PFORMDIALOG, CARASLABDBAPP/FORMATVALUE,
%   CARASLABDBAPP/SHOWSUBJECTEDITOR, CARASLABDBAPP/SHOWSESSIONEDITOR,
%   CARASLABDBAPP/SHOWEVENTEDITOR.

    arguments
        fig (1,1) matlab.ui.Figure
        what (1,1) string
        changes struct
        note (1,1) string = ""
    end

    lines = strings(1, 0);
    for i = 1:numel(changes)
        lines(end+1) = string(changes(i).Label) + ":  " + string(changes(i).Old) + ...
            "  →  " + string(changes(i).New); %#ok<AGROW>
    end

    n = numel(changes);
    if n == 1
        count = "1 field will change:";
    else
        count = string(n) + " fields will change:";
    end
    msg = what + newline + count + newline + newline + strjoin(lines, newline);
    if strlength(note) > 0
        msg = msg + newline + newline + note;
    end

    answer = uiconfirm(fig, msg, "Confirm changes", ...
        "Options", {'Save', 'Go back'}, ...
        "DefaultOption", 1, "CancelOption", 2, "Icon", "question");
    tf = strcmp(answer, 'Save');
end
