function db = loginDialog(obj)
%LOGINDIALOG Modal connection dialog; returns a connected CarasLabDB or [].
%
%   Prefills the non-secret connection fields remembered in preferences; the
%   password field is always blank and is never persisted. Loops until a
%   connection succeeds or the user cancels.
%
%   See also CARASLABDBAPP, CARASLABDB.

    db = [];
    c = obj.Prefs.Connection;

    f = uifigure("Name", "Connect to CarasLabDB", ...
        "Position", local_center(420, 320), "WindowStyle", "modal", "Resize", "off", ...
        "KeyPressFcn", @(~,e) onKeyPress(e));
    g = uigridlayout(f, [7 2]);
    g.RowHeight = repmat({30}, 1, 7);
    g.ColumnWidth = {130, '1x'};
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
    local_label(g, "Person email");
    hEmail = uieditfield(g, "text", "Value", char(c.PersonEmail));

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
        email  = string(hEmail.Value);

        if strlength(user) == 0 || strlength(pass) == 0
            uialert(f, "Username and password are required.", "Connect");
            return
        end

        try
            args = {"Username", user, "Password", pass, ...
                    "Server", server, "Port", port, "DatabaseName", dbname, ...
                    "UseActiveViews", obj.Prefs.UseActiveViews};
            if strlength(email) > 0
                args = [args, {"PersonEmail", email}];
            end
            newDb = CarasLabDB(args{:});
            failure = "";
        catch ME
            failure = string(ME.message);
        end

        % Drop the plaintext password as soon as it has been used, whether or
        % not the connection succeeded — it is never needed again here.
        pass = ""; %#ok<NASGU>
        args = {}; %#ok<NASGU>

        if strlength(failure) > 0
            uialert(f, "Connection failed: " + failure, "Connect");
            return
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
