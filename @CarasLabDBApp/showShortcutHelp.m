function showShortcutHelp(fig, context)
%SHOWSHORTCUTHELP Show the keyboard shortcuts for one of the app's windows.
%
%   CarasLabDBApp.showShortcutHelp(fig, context) displays the shortcut list for
%   the window FIG, where CONTEXT is one of:
%       "main"   - the Explorer window
%       "form"   - the generic add/edit form (pFormDialog)
%       "login"  - the connection dialog
%       "export" - the export-to-workspace prompt
%
%   Every window binds Ctrl+? to this method, so the lists have to live in one
%   place; kept apart they drift out of step with the callbacks they document.
%
%   See also CARASLABDBAPP, CARASLABDBAPP/BUILDUI, CARASLABDBAPP/PFORMDIALOG.

    arguments
        fig (1,1) matlab.ui.Figure
        context (1,1) string = "main"
    end

    switch context
        case "main"
            lines = [ ...
                "Ctrl+R           Refresh the current tab"; ...
                "Ctrl+E           Export the current table to the workspace"; ...
                "Ctrl+D           Edit / supersede the selected row"; ...
                "Ctrl+Shift+E     Add event"; ...
                "Ctrl+Shift+S     Add subject"; ...
                "Ctrl+Shift+N     Add session"; ...
                "Enter            Apply filters (browse tabs)"; ...
                "Ctrl+Enter       Run the query (Custom SQL tab)"; ...
                "Esc              Clear all filters"];
        case "form"
            lines = [ ...
                "Enter            OK (unless the form has a multi-line field)"; ...
                "Esc              Cancel"];
        case "login"
            lines = [ ...
                "Enter            Connect"; ...
                "Esc              Cancel"];
        case "export"
            lines = [ ...
                "Enter            Export"; ...
                "Esc              Cancel"];
        otherwise
            lines = strings(0, 1);
    end

    lines = [lines; "Ctrl+?           Show this list"];
    uialert(fig, strjoin(lines, newline), "Keyboard shortcuts", "Icon", "info");
end
