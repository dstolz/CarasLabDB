classdef Lamp < handle
    % labclient.Lamp  The lab database's state in an app's status bar; a click opens the Database window.
    %   lamp = labclient.Lamp(grid, Row=1, Column=3, Parent=fig)
    %   puts a small button in cell (Row, Column) of the uigridlayout GRID.
    %   It shows labclient.DB's state and follows it (the StateChanged event):
    %
    %     Database: off          not set up or turned off here (grey)
    %     Database: connected    (green)
    %     Database: offline      the server is out of reach; the apps keep
    %                            working and what they record waits here (orange)
    %     Database: attention    something on this computer must be fixed (red)
    %
    %   followed, while the database is on, by what waits in the outbox
    %   (labclient.Outbox): "· 3 to send", or "· 2 need you" (held or failed
    %   records, shown red) . The tooltip says why. Clicking opens
    %   labclient.Panel over PARENT. Creating a lamp starts the sending
    %   (labclient.Sync.start) when the database is turned on here.
    %
    %   See also labclient.DB, labclient.Panel.

    properties (SetAccess = private)
        Button = []
        Parent = []
    end

    properties (Access = private)
        Listener = []
        OutboxListener = []
    end

    methods
        function obj = Lamp(grid, opts)
            arguments
                grid
                opts.Row (1,1) double = 1
                opts.Column (1,1) double = 1
                opts.Parent = []
            end
            obj.Parent = opts.Parent;
            obj.Button = uibutton(grid, "Text", "Database: off", "FontSize", 11, ...
                "Tag", "LabClientLamp", "ButtonPushedFcn", @(~, ~) obj.openPanel());
            obj.Button.Layout.Row = opts.Row;
            obj.Button.Layout.Column = opts.Column;
            obj.Listener = listener(labclient.DB.instance(), "StateChanged", @(~, ~) obj.refresh());
            obj.OutboxListener = listener(labclient.DB.instance(), "OutboxChanged", @(~, ~) obj.refresh());
            addlistener(obj.Button, "ObjectBeingDestroyed", @(~, ~) obj.delete());
            obj.refresh();
            labclient.Sync.start(Parent=opts.Parent, IfEnabled=true);
        end

        function refresh(obj)
            %refresh  Show labclient.DB's current state.
            if isempty(obj.Button) || ~isvalid(obj.Button)
                return
            end
            st = labclient.DB.status();
            [label, color] = labclient.Lamp.look(st.State);
            tip = st.Message;
            [extra, need] = labclient.Lamp.outboxText();
            if need
                color = [0.75 0.10 0.10];
                tip = tip + " Some records wait for you: see the outbox in the Database window.";
            end
            obj.Button.Text = "Database: " + label + extra;
            obj.Button.FontColor = color;
            obj.Button.Tooltip = char(tip + " (click for the Database window)");
        end

        function delete(obj)
            if ~isempty(obj.Listener) && isvalid(obj.Listener)
                delete(obj.Listener);
            end
            if ~isempty(obj.OutboxListener) && isvalid(obj.OutboxListener)
                delete(obj.OutboxListener);
            end
        end
    end

    methods (Static)
        function [t, need] = outboxText()
            %outboxText  " · N to send" / " · N need you" while the database is on, "" otherwise.
            t = "";
            need = false;
            try
                if ~labclient.Sync.enabled(); return; end
                c = labclient.Outbox.counts();
            catch
                return
            end
            n = c.held + c.failed;
            if n > 0
                t = " · " + n + " need you";
                need = true;
            elseif c.pending + c.claimed > 0
                t = " · " + (c.pending + c.claimed) + " to send";
            end
        end

        function [label, color] = look(state)
            %look  The lamp's text and colour for STATE.
            switch state
                case "connected"
                    label = "connected"; color = [0.10 0.50 0.20];
                case "offline"
                    label = "offline";   color = [0.75 0.45 0.00];
                case "attention"
                    label = "attention"; color = [0.75 0.10 0.10];
                otherwise
                    label = "off";       color = [0.45 0.45 0.45];
            end
        end
    end

    methods (Access = private)
        function openPanel(obj)
            p = obj.Parent;
            if isempty(p) || ~isvalid(p)
                labclient.Panel.open();
            else
                labclient.Panel.open(Parent=p);
            end
        end
    end
end
