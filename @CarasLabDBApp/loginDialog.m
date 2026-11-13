function db = loginDialog(obj)
%LOGINDIALOG Modal connection dialog; returns a connected CarasLabDB or [].
%
%   Prefills the non-secret connection fields remembered in preferences; the
%   password field is always blank and is never persisted. Loops until a
%   connection succeeds or the user cancels.
%
%   The person email is optional. CarasLabDB resolves the person from the
%   database login (lab.person.db_login, through lab.fn_current_person())
%   when none is given, so a lab member whose login is linked to them only
%   types a user name and a password. Only if, after connecting, the session
%   still has no person (db.CurrentPersonId is missing) does the dialog ask
%   for an explicit confirmation that entries will carry no person; "Go
%   back" closes that connection and returns to the form.
%
%   See also CARASLABDBAPP, CARASLABDB.

    db = [];
    c = obj.Prefs.Connection;

    f = uifigure("Name", "Connect to CarasLabDB", ...
        "Position", local_center(420, 320), "WindowStyle", "modal", "Resize", "off", ...
        "KeyPressFcn", @(~,e) onKeyPress(e));
    g = uigridlayout(f, [7 2]);
    g.RowHeight = repmat({30}, 1, 7);
    g.ColumnWidth = {150, '1x'};
    g.Padding = [15 15 15 15];
    g.RowSpacing = 8;

    local_label(g, "Server");
    hServer = uieditfield(g, "text", "Value", char(c.Server));
    local_label(g, "Port");
    hPort = uieditfield(g, "numeric", "Value", double(c.Port), ...
        "Limits", [1 65535], "RoundFractionalValues", "on");
    local_label(g, "Database");
    hDb = uieditfield(g, "text", "Value", char(c.DatabaseName));
    local_label(g, "Username");
    hUser = uieditfield(g, "text", "Value", char(c.Username));
    local_label(g, "Password");
    % Masked entry is a uieditfield *type*, not a property; assigning a
    % "Password" property silently fails and shows the password in the clear.
    passWarning = "";
    try
        hPass = uieditfield(g, "password");
    catch ME
        hPass = uieditfield(g, "text", "Value", "");
        passWarning = "Masked password entry is unavailable in this MATLAB " + ...
            "release (" + string(ME.message) + "). Your password will be " + ...
            "visible on screen as you type.";
    end
    % Who is making the entries: what fills recorded_by / created_by. Left
    % blank, the person is the one the database login is linked to; a
    % session that ends up with no person needs an explicit confirmation
    % (see onConnect).
    local_label(g, "Your email (person)");
    hEmail = uieditfield(g, "text", "Value", char(c.PersonEmail), ...
        "Placeholder", "optional if your login is linked to you", ...
        "Tooltip", "Your email as registered in lab.person. Entries you make " + ...
            "are recorded under this person. Leave it blank to be recognised " + ...
            "by your database login.");

    btnRow = uigridlayout(g, [1 2]);
    btnRow.Layout.Row = 7;
    btnRow.Layout.Column = [1 2];
    btnRow.ColumnWidth = {'1x', '1x'};
    btnRow.Padding = [0 0 0 0];
    uibutton(btnRow, "Text", "Cancel", "ButtonPushedFcn", @(~,~) onCancel());
    uibutton(btnRow, "Text", "Connect", "ButtonPushedFcn", @(~,~) onConnect());

    if strlength(passWarning) > 0
        uialert(f, passWarning, "Password not masked", "Icon", "warning");
    end

    uiwait(f);
    if isvalid(f)
        delete(f);
    end
    return

    % ---- nested callbacks (share workspace with the parent) -------------
    function onKeyPress(e)
        %ONKEYPRESS Enter connects, Escape cancels (all fields are
        %   single-line); Ctrl+? lists the shortcuts.
        mods = string(e.Modifier);
        ctrl = any(mods == "control") || any(mods == "command");
        key  = string(e.Key);
        if ctrl && (ismember(key, ["slash", "questionmark", "help"]) || ...
                string(e.Character) == "?")
            CarasLabDBApp.showShortcutHelp(f, "login");
        elseif key == "return"
            onConnect();
        elseif key == "escape"
            onCancel();
        end
    end

    function onCancel()
        uiresume(f);
    end

    function onConnect()
        server = string(hServer.Value);
        port   = double(hPort.Value);
        dbname = string(hDb.Value);
        user   = string(hUser.Value);
        pass   = string(hPass.Value);
        email  = strtrim(string(hEmail.Value));

        if strlength(user) == 0 || strlength(pass) == 0
            uialert(f, "Username and password are required.", "Connect");
            return
        end

        % CarasLabDB resolves the person from the email if one was typed,
        % else from the database login. When it resolves nobody it warns
        % CarasLabDB:noCurrentPerson; this dialog asks instead (below), so
        % the warning is silenced for the duration of the call.
        newDb = [];
        failure = "";
        warnState = warning("off", "CarasLabDB:noCurrentPerson");
        try
            args = {"Username", user, "Password", pass, ...
                    "Server", server, "Port", port, "DatabaseName", dbname, ...
                    "UseActiveViews", obj.Prefs.UseActiveViews};
            if strlength(email) > 0
                args = [args, {"PersonEmail", email}];
            end
            newDb = CarasLabDB(args{:});
        catch ME
            failure = string(ME.message);
        end
        warning(warnState);

        % Drop the plaintext password as soon as it has been used, whether or
        % not the connection succeeded — it is never needed again here.
        pass = ""; %#ok<NASGU>
        args = {}; %#ok<NASGU>

        if strlength(failure) > 0
            uialert(f, "Connection failed: " + failure, "Connect");
            return
        end

        % A session with no person records nobody on what it writes. That is
        % allowed (the database still stores the login name), but only as a
        % deliberate choice: it is asked here, once the connection has shown
        % that the login is not linked to a person either.
        if ismissing(newDb.CurrentPersonId)
            answer = uiconfirm(f, ...
                "No person is set for this session: no email was entered, and " + ...
                "the login '" + user + "' is not linked to a person in the database." + ...
                newline + newline + ...
                "Everything you add or correct will be recorded with no person " + ...
                "attached; the database still records the login name. Go back " + ...
                "to enter your email, or ask the database administrator to link " + ...
                "your login to you (lab.person.db_login)." + ...
                newline + newline + ...
                "Continue without a person?", ...
                "No person set", ...
                "Options", {'Go back', 'Continue without a person'}, ...
                "DefaultOption", 1, "CancelOption", 1, "Icon", "warning");
            if ~strcmp(answer, 'Continue without a person')
                try
                    delete(newDb);          % close the connection just opened
                catch
                end
                try
                    focus(hEmail);
                catch
                end
                return
            end
        end
        hPass.Value = '';

        % Success: remember non-secret fields and hand back the handle.
        obj.Prefs.Connection = struct("Server", server, "Port", port, ...
            "Username", user, "DatabaseName", dbname, "PersonEmail", email);
        db = newDb;
        uiresume(f);
    end
end

% ---- local helpers -----------------------------------------------------------

function local_label(g, txt)
    lbl = uilabel(g, "Text", txt, "HorizontalAlignment", "right");
    lbl.FontWeight = "bold";
end

function pos = local_center(w, h)
    su = get(groot, "ScreenSize");
    pos = [su(3)/2 - w/2, su(4)/2 - h/2, w, h];
end
