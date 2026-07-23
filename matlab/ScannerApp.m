classdef ScannerApp < matlab.apps.AppBase

    % Properties that correspond to app components
    properties (Access = public)
        SweepDuration = 2510  % ms, match scanner.ino SCAN/RETURN_DURATION_MS
        UIFigure               matlab.ui.Figure
        COMPortDropDown        matlab.ui.control.DropDown
        COMPortDropDownLabel   matlab.ui.control.Label
        StartButton            matlab.ui.control.Button
        StopButton             matlab.ui.control.Button
        RefreshButton          matlab.ui.control.Button
        TemperatureLabel       matlab.ui.control.Label
        TemperatureValue       matlab.ui.control.NumericEditField
        LatestDistanceLabel    matlab.ui.control.Label
        LatestDistanceValue    matlab.ui.control.NumericEditField
        ScanStatusLabel        matlab.ui.control.Label
        ScanStatusValue        matlab.ui.control.Label
        StatusLabel            matlab.ui.control.Label
        PolarAxes              matlab.graphics.axis.PolarAxes
        ExportButton           matlab.ui.control.Button
        ClearButton            matlab.ui.control.Button
        ThemeToggleButton      matlab.ui.control.Button
        HoverText              matlab.graphics.primitive.Text
        SerialObj              % Serial port object
        IsConnected = false    % Tracks whether serial link is active
        UseLightTheme = false  % Tracks theme state
        DataTable              table % To store data
        TimerObj               timer % For reading serial
        SweepAnimAngle = 0    % Current sweep animation angle (deg)
        SweepAnimTimer        % Timer for sweep line animation
        PlotLine               matlab.graphics.chart.primitive.Line
        SweepLine              matlab.graphics.chart.primitive.Line
        ReturnSweepLine        matlab.graphics.chart.primitive.Line
        IsReturning = false    
        ReturnStartTime
        MaxDistance = 0        % Running max distance for auto-scale
        DistMax = 0            % Maximum valid distance seen (mm), for auto-scale
        CtrlDown = false
    end

    % Callbacks that handle component events
    methods (Access = private)

        % Code that executes after component creation
        function startupFcn(app)
            app.DataTable = table('Size', [0 4], 'VariableTypes', {'double', 'double', 'double', 'datetime'}, ...
                'VariableNames', {'Angle', 'Distance', 'Temperature', 'Timestamp'});
            app.TimerObj = timer('ExecutionMode', 'fixedRate', 'Period', 0.05, 'TimerFcn', @(~,~) app.readSerialData(), 'BusyMode', 'drop');
            app.SweepAnimTimer = timer('ExecutionMode', 'fixedRate', 'Period', 0.016, 'TimerFcn', @(~,~) app.sweepAnimCallback(), 'BusyMode', 'drop');

            app.applyTheme();
            app.createPlotObjects();
            app.clearScanData();
            app.TemperatureValue.ValueDisplayFormat = '%.3f';
            app.LatestDistanceValue.ValueDisplayFormat = '%.3f';
            app.updateStatus('Ready');
            app.updateScanStatus('Idle');
            pause(0.5);
            app.updateCOMPorts();
            datacursormode(app.UIFigure, 'on');
        end

        % Button pushed function: StartButton
        function StartButtonPushed(app, ~)
            if ~isempty(app.SerialObj) && isvalid(app.SerialObj)
                try
                    flush(app.SerialObj);
                    if app.SerialObj.NumBytesAvailable > 0
                        readline(app.SerialObj);
                    end
                catch
                    app.disconnectSerial();
                    app.updateCOMPorts();
                    if isequal(app.COMPortDropDown.Value, '-- select --')
                        uialert(app.UIFigure, 'Serial port was lost. Refresh and try again.', 'Connection Error');
                        return;
                    end
                    port = app.COMPortDropDown.Value;
                    app.connectToPort(port);
                    return;
                end
                app.clearScanData();
                app.IsConnected = true;
                writeline(app.SerialObj, 'START');
                start(app.TimerObj);
                start(app.SweepAnimTimer);
                app.StartButton.Enable = 'off';
                app.StopButton.Enable = 'on';
                app.COMPortDropDown.Enable = 'off';
                app.updateStatus('Scanning');
                app.updateScanStatus('Scanning');
                return;
            end

            app.updateCOMPorts();
            if isempty(app.COMPortDropDown.Items) || isequal(app.COMPortDropDown.Value, '-- select --')
                for i = 1:5
                    pause(0.3);
                    drawnow('nocallbacks');
                    app.updateCOMPorts();
                    if ~isempty(app.COMPortDropDown.Items) && ~isequal(app.COMPortDropDown.Value, '-- select --')
                        break;
                    end
                end
            end
            if isempty(app.COMPortDropDown.Items) || isequal(app.COMPortDropDown.Value, '-- select --')
                uialert(app.UIFigure, 'No available COM ports found. Try Refresh button.', 'Connection Error');
                return;
            end

            port = app.COMPortDropDown.Value;
            app.connectToPort(port);
        end

        function connectToPort(app, port)
            try
                app.SerialObj = serialport(port, 250000);
                configureTerminator(app.SerialObj, "LF");
                app.SerialObj.Timeout = 1;
                pause(0.5);
                app.updateStatus(['Waiting for READY from ' port '...']);

                timeoutSeconds = 5.0;
                startTime = tic;
                readyReceived = false;
                while toc(startTime) < timeoutSeconds
                    if app.SerialObj.NumBytesAvailable > 0
                        line = strtrim(readline(app.SerialObj));
                        if isempty(line)
                            continue;
                        end
                        if strcmpi(line, 'READY')
                            readyReceived = true;
                            break;
                        end
                    end
                    pause(0.05);
                end

                if ~readyReceived
                    app.disconnectSerial();
                    error('Arduino READY handshake not received.');
                end

                while app.SerialObj.NumBytesAvailable > 0
                    readline(app.SerialObj);
                end

                app.clearScanData();
                app.IsConnected = true;
                writeline(app.SerialObj, 'START');
                start(app.TimerObj);
                start(app.SweepAnimTimer);
                app.StartButton.Enable = 'off';
                app.StopButton.Enable = 'on';
                app.COMPortDropDown.Enable = 'off';
                app.updateStatus(['Connected to ' port]);
                app.updateScanStatus('Scanning');
            catch e
                if ~isempty(app.SerialObj) && isvalid(app.SerialObj)
                    app.disconnectSerial();
                end
                uialert(app.UIFigure, ['Error connecting to ' port ': ' e.message], 'Connection Error');
                app.updateStatus('Connection failed');
                app.updateScanStatus('Idle');
            end
        end

        % Button pushed function: StopButton
        function StopButtonPushed(app, ~)
            try
                if app.IsConnected && ~isempty(app.SerialObj) && isvalid(app.SerialObj)
                    writeline(app.SerialObj, 'STOP');
                end
            catch
            end
            app.disconnectSerial();
            app.resetToIdle();
            app.updateStatus('Disconnected');
            app.updateScanStatus('Stopped');
        end

        % Button pushed function: RefreshButton
        function RefreshButtonPushed(app, ~)
            app.updateCOMPorts();
            app.updateStatus('COM ports refreshed');
        end

        % Button pushed function: ExportButton
        function ExportButtonPushed(app, ~)
            if isempty(app.DataTable) || height(app.DataTable) == 0
                uialert(app.UIFigure, 'No data to export.', 'Export Error');
                return;
            end
            [file, path] = uiputfile('*.pdf', 'Save Polar Map as PDF');
            if file ~= 0
                exportgraphics(app.PolarAxes, fullfile(path, file), 'ContentType', 'vector');
                app.updateStatus(['Exported to ' fullfile(path, file)]);
            end
        end

        % Update COM ports
        function updateCOMPorts(app)
            ports = serialportlist("available");
            if isempty(ports)
                app.COMPortDropDown.Items = {'-- select --'};
                app.COMPortDropDown.Value = '-- select --';
            else
                app.COMPortDropDown.Items = ports;
                app.COMPortDropDown.Value = ports{1};
            end
        end

        % Read serial data
        function readSerialData(app)
            if ~isvalid(app) || ~app.IsConnected || isempty(app.SerialObj) || ~isvalid(app.SerialObj) || ~isvalid(app.UIFigure)
                return;
            end

            try
                for k = 1:10
                    if app.SerialObj.NumBytesAvailable <= 0
                        break;
                    end
                    line = readline(app.SerialObj);
                    line = strtrim(line);
                    if isempty(line)
                        continue;
                    end

                    if strcmpi(line, 'SCAN_COMPLETE')
                        app.SweepAnimAngle = 360;
                        app.updatePlot(0, 0);
                        if isvalid(app.SweepLine)
                            app.SweepLine.ThetaData = [deg2rad(360) deg2rad(360)];
                            app.SweepLine.RData = [0 max(app.PolarAxes.RLim)];
                        end
                        app.updateStatus('Sweeping back to 0°');
                        app.updateScanStatus('Complete');
                        app.SweepLine.Visible = 'off';
                        app.ReturnSweepLine.Visible = 'on';
                        app.IsReturning = true;
                        app.ReturnStartTime = tic;
                        continue;
                    end

                    if strcmpi(line, 'DONE')
                        app.updateStatus('Scan complete');
                        app.ReturnSweepLine.Visible = 'off';
                        app.SweepLine.Visible = 'on';
                        app.IsReturning = false;
                        if ~isempty(app.TimerObj) && isvalid(app.TimerObj) && strcmp(app.TimerObj.Running, 'on')
                            stop(app.TimerObj);
                        end
                        if ~isempty(app.SweepAnimTimer) && isvalid(app.SweepAnimTimer) && strcmp(app.SweepAnimTimer.Running, 'on')
                            stop(app.SweepAnimTimer);
                        end
                        app.StartButton.Enable = 'on';
                        app.StopButton.Enable = 'off';
                        app.COMPortDropDown.Enable = 'on';
                        continue;
                    end

                    data = strsplit(line, ',');
                    if numel(data) ~= 3
                        continue;
                    end

                    angle = str2double(strtrim(data{1}));
                    distance = str2double(strtrim(data{2}));
                    temperature = str2double(strtrim(data{3}));
                    if isnan(angle) || isnan(distance) || isnan(temperature)
                        continue;
                    end
                    if angle < 0 || angle > 360 || distance < 0 || distance > 10000
                        continue;
                    end

                    timestamp = datetime('now');
                    newRow = {angle, distance, temperature, timestamp};
                    app.DataTable = [app.DataTable; newRow];
                    app.updateDisplays(angle, distance, temperature);
                    if isvalid(app.SweepLine)
                        app.SweepAnimAngle = min(angle, 360);
                    end
                    if mod(height(app.DataTable), 10) == 1
                        app.updatePlot(angle, distance);
                    end
                end
            catch e
                app.updateStatus(['Serial error: ' e.message]);
            end
        end

        function sweepAnimCallback(app)
            if ~isvalid(app) || ~isvalid(app.PolarAxes)
                return;
            end
            if app.IsReturning
                if ~isvalid(app.ReturnSweepLine)
                    return;
                end
                elapsed = toc(app.ReturnStartTime) * 1000;
                progress = min(elapsed / app.SweepDuration, 1);
                theta = deg2rad(360 - progress * 360);
                app.ReturnSweepLine.ThetaData = [theta theta];
                app.ReturnSweepLine.RData = [0 max(app.PolarAxes.RLim)];
            else
                if ~isvalid(app.SweepLine)
                    return;
                end
                theta = deg2rad(app.SweepAnimAngle);
                app.SweepLine.ThetaData = [theta theta];
                app.SweepLine.RData = [0 max(app.PolarAxes.RLim)];
            end
            drawnow('limitrate');
        end

        % Update displays
        function updateDisplays(app, angle, distance, temperature)
            app.TemperatureValue.Value = temperature;
            app.LatestDistanceValue.Value = distance;
            app.updateStatus(sprintf('Angle %.1f°, %.3f mm, %.3f °C', angle, distance, temperature));
        end

        % Update polar plot
        function updatePlot(app, ~, ~)
            if height(app.DataTable) == 0
                return;
            end
            theta = deg2rad(app.DataTable.Angle);
            r = app.DataTable.Distance;

            lastDistance = app.DataTable.Distance(end);
            if lastDistance >= 20 && lastDistance > app.DistMax
                app.DistMax = lastDistance;
            end
            targetRLim = max(app.DistMax * 1.3, 50);

            if isvalid(app.PlotLine)
                app.PlotLine.ThetaData = theta;
                app.PlotLine.RData = r;
            else
                app.PlotLine = polarplot(app.PolarAxes, theta, r, 'o', ...
                    'MarkerFaceColor', [0 0.7 1], 'MarkerEdgeColor', 'w', ...
                    'MarkerSize', 6, 'LineStyle', 'none');
                try
                    app.PlotLine.DataTipTemplate.DataTipRows(1).Label = '\theta (°)';
                    app.PlotLine.DataTipTemplate.DataTipRows(2).Label = 'R (mm)';
                    app.PlotLine.DataTipTemplate.DataTipRows(2).Format = '%.0f';
                catch
                end
            end

            app.PolarAxes.RLim = [0 targetRLim];
            app.updateRadialLabels();
            if isvalid(app.SweepLine)
                app.SweepLine.RData = [0 max(app.PolarAxes.RLim)];
            end
            if isvalid(app.ReturnSweepLine)
                app.ReturnSweepLine.RData = [0 max(app.PolarAxes.RLim)];
            end
            bringGridLabelsToFront(app);
        end

        function bringGridLabelsToFront(app)
            if ~isvalid(app.PolarAxes)
                return;
            end
            try
                kids = findobj(app.PolarAxes, 'Type', 'text');
                for i = 1:length(kids)
                    uistack(kids(i), 'top');
                end
            catch
            end
        end

        % Configure plot objects on the existing polar axes
        function createPlotObjects(app)
            app.PolarAxes.Visible = 'on';
            app.PolarAxes.Position = [0.35 0.15 0.6 0.8];
            app.PolarAxes.ThetaZeroLocation = 'top';
            app.PolarAxes.ThetaDir = 'clockwise';
            app.PolarAxes.GridAlpha = 0.8;
            app.PolarAxes.ThetaTick = 0:45:315;
            app.PolarAxes.Title.String = '2D Scan Map';
            app.PolarAxes.RLim = [0 50];

            app.PlotLine = polarplot(app.PolarAxes, [], [], 'o', 'MarkerFaceColor', [0 0.7 1], ...
                'MarkerEdgeColor', 'w', 'MarkerSize', 6, 'LineStyle', 'none');
            try
                app.PlotLine.DataTipTemplate.DataTipRows(1).Label = '\theta (°)';
                app.PlotLine.DataTipTemplate.DataTipRows(2).Label = 'R (mm)';
                app.PlotLine.DataTipTemplate.DataTipRows(2).Format = '%.0f';
            catch
            end
            hold(app.PolarAxes, 'on');
            app.SweepLine = polarplot(app.PolarAxes, [0 0], [0 max(app.PolarAxes.RLim)], '--y', 'LineWidth', 2);
            app.ReturnSweepLine = polarplot(app.PolarAxes, [0 0], [0 1], '--m', 'LineWidth', 2);
            app.ReturnSweepLine.Visible = 'off';
            app.updateRadialLabels();
            bringGridLabelsToFront(app);
        end

        % Update status label
        function updateStatus(app, message)
            app.StatusLabel.Text = ['Status: ' message];
        end

        function updateRadialLabels(app)
            if ~isvalid(app.PolarAxes)
                return;
            end
            rLim = app.PolarAxes.RLim;
            if rLim(2) <= 0
                return;
            end
            rMaxMm = rLim(2);
            rawStep = rMaxMm / 6;
            exp = 10^floor(log10(rawStep));
            niceSteps = [1, 2, 2.5, 5, 10] * exp;
            [~, idx] = min(abs(niceSteps - rawStep));
            step = niceSteps(idx);
            ticksMm = 0:step:rMaxMm;
            if rMaxMm - ticksMm(end) > step * 0.3
                nextTick = ticksMm(end) + step;
                ticksMm = [ticksMm, nextTick];
                app.PolarAxes.RLim(2) = max(app.PolarAxes.RLim(2), nextTick);
            end
            app.PolarAxes.RTick = ticksMm;
            labels = arrayfun(@(x) sprintf('%d', round(x)), ticksMm, 'UniformOutput', false);
            labels{end} = [labels{end} ' mm'];
            app.PolarAxes.RTickLabel = labels;
        end

        % Update scan status field
        function updateScanStatus(app, message)
            app.ScanStatusValue.Text = message;
            switch lower(message)
                case 'idle'
                    app.ScanStatusValue.FontColor = [0.8 0.8 0.8];
                case 'scanning'
                    app.ScanStatusValue.FontColor = [0 0.8 0];
                case 'stopped'
                    app.ScanStatusValue.FontColor = [1 0.6 0];
                case 'complete'
                    app.ScanStatusValue.FontColor = [0 0.6 1];
                otherwise
                    app.ScanStatusValue.FontColor = [1 1 1];
            end
        end

        function disconnectSerial(app)
            app.IsConnected = false;
            if ~isempty(app.TimerObj) && isvalid(app.TimerObj) && strcmp(app.TimerObj.Running, 'on')
                stop(app.TimerObj);
            end
            if ~isempty(app.SweepAnimTimer) && isvalid(app.SweepAnimTimer) && strcmp(app.SweepAnimTimer.Running, 'on')
                stop(app.SweepAnimTimer);
            end
            if ~isempty(app.SerialObj) && isvalid(app.SerialObj)
                drawnow('nocallbacks');
                warning('off', 'all');
                delete(app.SerialObj);
                warning('on', 'all');
                drawnow('nocallbacks');
            end
            app.SerialObj = [];
        end

        function clearScanData(app)
            app.DataTable = table('Size', [0 4], 'VariableTypes', {'double', 'double', 'double', 'datetime'}, ...
                'VariableNames', {'Angle', 'Distance', 'Temperature', 'Timestamp'});
            if ~isempty(app.PlotLine) && isvalid(app.PlotLine)
                app.PlotLine.ThetaData = [];
                app.PlotLine.RData = [];
            end
            if ~isempty(app.SweepLine) && isvalid(app.SweepLine)
                app.SweepLine.ThetaData = [0 0];
                app.SweepLine.RData = [0 max(app.PolarAxes.RLim)];
                app.SweepLine.Visible = 'on';
            end
            if ~isempty(app.ReturnSweepLine) && isvalid(app.ReturnSweepLine)
                app.ReturnSweepLine.ThetaData = [0 0];
                app.ReturnSweepLine.RData = [0 max(app.PolarAxes.RLim)];
                app.ReturnSweepLine.Visible = 'off';
            end
            app.MaxDistance = 0;
            app.DistMax = 0;
            app.SweepAnimAngle = 0;
            app.IsReturning = false;
            if isvalid(app.PolarAxes)
                app.PolarAxes.RLim = [0 50];
            end
        end

        function resetToIdle(app)
            app.StartButton.Enable = 'on';
            app.StopButton.Enable = 'off';
            app.COMPortDropDown.Enable = 'on';
            app.IsConnected = false;
        end

        function applyTheme(app)
            if app.UseLightTheme
                bg = [250 249 245] / 255;
                fg = [20 20 19] / 255;
                axesBg = [255 255 255] / 255;
                axesGrid = [108 106 100] / 255;
                axesFg = [20 20 19] / 255;
                startBg = [93 184 114] / 255;
                stopBg = [198 69 69] / 255;
                secBg = [230 223 216] / 255;
                secFg = [20 20 19] / 255;
                sweepColor = [0.7 0.5 0];
                returnColor = [0.8 0 0.5];
            else
                bg = [24 23 21] / 255;
                fg = [250 249 245] / 255;
                axesBg = [31 30 27] / 255;
                axesGrid = [108 106 100] / 255;
                axesFg = [250 249 245] / 255;
                startBg = [93 184 114] / 255;
                stopBg = [198 69 69] / 255;
                secBg = [61 61 58] / 255;
                secFg = [250 249 245] / 255;
                sweepColor = [1 1 0];
                returnColor = [1 0 1];
            end

            app.UIFigure.Position = [100 100 1000 650];
            app.UIFigure.Color = bg;

            app.COMPortDropDownLabel.FontColor = fg;
            app.COMPortDropDownLabel.FontSize = 14;
            app.TemperatureLabel.FontColor = fg;
            app.TemperatureLabel.FontSize = 14;
            app.LatestDistanceLabel.FontColor = fg;
            app.LatestDistanceLabel.FontSize = 14;
            app.ScanStatusLabel.FontColor = fg;
            app.ScanStatusLabel.FontSize = 14;

            app.ScanStatusValue.FontColor = fg;
            app.ScanStatusValue.FontSize = 14;

            app.StatusLabel.FontColor = fg;
            app.StatusLabel.FontSize = 13;

            app.TemperatureValue.FontSize = 14;
            app.LatestDistanceValue.FontSize = 14;

            app.StartButton.BackgroundColor = startBg;
            app.StartButton.FontColor = [1 1 1];
            app.StartButton.FontWeight = 'bold';
            app.StartButton.FontSize = 14;

            app.StopButton.BackgroundColor = stopBg;
            app.StopButton.FontColor = [1 1 1];
            app.StopButton.FontWeight = 'bold';
            app.StopButton.FontSize = 14;

            app.ExportButton.BackgroundColor = secBg;
            app.ExportButton.FontColor = secFg;
            app.ExportButton.FontSize = 13;

            app.ClearButton.BackgroundColor = secBg;
            app.ClearButton.FontColor = secFg;
            app.ClearButton.FontSize = 13;

            app.RefreshButton.BackgroundColor = secBg;
            app.RefreshButton.FontColor = secFg;
            app.RefreshButton.FontSize = 13;

            app.ThemeToggleButton.BackgroundColor = secBg;
            app.ThemeToggleButton.FontColor = secFg;
            app.ThemeToggleButton.FontSize = 13;

            app.COMPortDropDown.FontSize = 13;

            if isvalid(app.PolarAxes)
                app.PolarAxes.Color = axesBg;
                app.PolarAxes.GridColor = axesGrid;
                app.PolarAxes.ThetaColor = axesFg;
                app.PolarAxes.RColor = axesFg;
                app.PolarAxes.Title.Color = axesFg;
            end

            if ~isempty(app.SweepLine) && isvalid(app.SweepLine)
                app.SweepLine.Color = sweepColor;
            end
            if ~isempty(app.ReturnSweepLine) && isvalid(app.ReturnSweepLine)
                app.ReturnSweepLine.Color = returnColor;
            end

            if ~isempty(app.StatusLabel)
                app.updateScanStatus(app.ScanStatusValue.Text);
            end
        end

        function ClearButtonPushed(app, ~)
            app.clearScanData();
            app.updateStatus('Scan data cleared');
        end

        function ThemeToggleButtonPushed(app, ~)
            app.UseLightTheme = ~app.UseLightTheme;
            app.applyTheme();
            if app.UseLightTheme
                app.ThemeToggleButton.Text = 'Dark Theme';
            else
                app.ThemeToggleButton.Text = 'Light Theme';
            end
        end

        function UIFigureScrollWheel(app, event)
            if ~app.CtrlDown
                return;
            end
            if ~strcmp(app.ScanStatusValue.Text, 'Complete')
                return;
            end
            factor = 1.3;
            rlim = app.PolarAxes.RLim;
            if event.VerticalScrollCount > 0
                newMax = rlim(2) / factor;
            else
                newMax = rlim(2) * factor;
            end
            newMax = max(newMax, 10);
            app.PolarAxes.RLim = [0 newMax];
            app.updateRadialLabels();
            if isvalid(app.SweepLine)
                app.SweepLine.RData = [0 max(app.PolarAxes.RLim)];
            end
            if isvalid(app.ReturnSweepLine)
                app.ReturnSweepLine.RData = [0 max(app.PolarAxes.RLim)];
            end
        end

        function UIFigureKeyPress(app, event)
            if strcmp(event.Key, 'control')
                app.CtrlDown = true;
            end
        end

        function UIFigureKeyRelease(app, event)
            if strcmp(event.Key, 'control')
                app.CtrlDown = false;
            end
        end

        function UIFigureCloseRequest(app, ~)
            if ~isempty(app.TimerObj) && isvalid(app.TimerObj) && strcmp(app.TimerObj.Running, 'on')
                stop(app.TimerObj);
            end
            if ~isempty(app.SweepAnimTimer) && isvalid(app.SweepAnimTimer) && strcmp(app.SweepAnimTimer.Running, 'on')
                stop(app.SweepAnimTimer);
            end
            app.IsConnected = false;
            drawnow('nocallbacks');
            try
                delete(app);
            catch
                delete(app);
            end
        end
    end

    % Component initialization
    methods (Access = private)

        % Create UIFigure and components
        function createComponents(app)

            % Create UIFigure and hide until all components are created
            app.UIFigure = uifigure('Visible', 'off');
            app.UIFigure.Position = [100 100 900 620];
            app.UIFigure.Name = '2D Scanner GUI';
            app.UIFigure.CloseRequestFcn = createCallbackFcn(app, @UIFigureCloseRequest, true);
            app.UIFigure.WindowScrollWheelFcn = createCallbackFcn(app, @UIFigureScrollWheel, true);
            app.UIFigure.KeyPressFcn = createCallbackFcn(app, @UIFigureKeyPress, true);
            app.UIFigure.KeyReleaseFcn = createCallbackFcn(app, @UIFigureKeyRelease, true);

            % Create COMPortDropDownLabel
            app.COMPortDropDownLabel = uilabel(app.UIFigure);
            app.COMPortDropDownLabel.HorizontalAlignment = 'right';
            app.COMPortDropDownLabel.Position = [30 560 70 22];
            app.COMPortDropDownLabel.Text = 'COM Port';

            % Create COMPortDropDown
            app.COMPortDropDown = uidropdown(app.UIFigure);
            app.COMPortDropDown.Position = [110 560 120 22];
            app.COMPortDropDown.Items = {'-- select --'};
            app.COMPortDropDown.Value = '-- select --';

            % Create RefreshButton
            app.RefreshButton = uibutton(app.UIFigure, 'push');
            app.RefreshButton.ButtonPushedFcn = createCallbackFcn(app, @RefreshButtonPushed, true);
            app.RefreshButton.Position = [240 560 80 22];
            app.RefreshButton.Text = 'Refresh';

            % Create StartButton
            app.StartButton = uibutton(app.UIFigure, 'push');
            app.StartButton.ButtonPushedFcn = createCallbackFcn(app, @StartButtonPushed, true);
            app.StartButton.Position = [30 510 100 30];
            app.StartButton.Text = 'Start Scan';

            % Create StopButton
            app.StopButton = uibutton(app.UIFigure, 'push');
            app.StopButton.ButtonPushedFcn = createCallbackFcn(app, @StopButtonPushed, true);
            app.StopButton.Enable = 'off';
            app.StopButton.Position = [150 510 100 30];
            app.StopButton.Text = 'Stop Scan';

            % Create TemperatureLabel
            app.TemperatureLabel = uilabel(app.UIFigure);
            app.TemperatureLabel.Position = [30 450 140 22];
            app.TemperatureLabel.Text = 'Temperature (°C):';

            % Create TemperatureValue
            app.TemperatureValue = uieditfield(app.UIFigure, 'numeric');
            app.TemperatureValue.Position = [180 450 100 22];
            app.TemperatureValue.Editable = 'off';

            % Create LatestDistanceLabel
            app.LatestDistanceLabel = uilabel(app.UIFigure);
            app.LatestDistanceLabel.Position = [30 410 140 22];
            app.LatestDistanceLabel.Text = 'Latest Distance (mm):';

            % Create LatestDistanceValue
            app.LatestDistanceValue = uieditfield(app.UIFigure, 'numeric');
            app.LatestDistanceValue.Position = [180 410 100 22];
            app.LatestDistanceValue.Editable = 'off';

            % Create ScanStatusLabel
            app.ScanStatusLabel = uilabel(app.UIFigure);
            app.ScanStatusLabel.Position = [30 380 100 22];
            app.ScanStatusLabel.Text = 'Scan status:';

            % Create ScanStatusValue
            app.ScanStatusValue = uilabel(app.UIFigure);
            app.ScanStatusValue.Position = [140 380 140 22];
            app.ScanStatusValue.Text = 'Idle';

            % Create StatusLabel
            app.StatusLabel = uilabel(app.UIFigure);
            app.StatusLabel.Position = [30 350 300 22];
            app.StatusLabel.Text = 'Status: Initializing';

            % Create PolarAxes placeholder (will be configured in createPlotObjects)
            app.PolarAxes = polaraxes(app.UIFigure);
            app.PolarAxes.Position = [320 90 540 520];
            app.PolarAxes.Visible = 'off';

            % Create ExportButton
            app.ExportButton = uibutton(app.UIFigure, 'push');
            app.ExportButton.ButtonPushedFcn = createCallbackFcn(app, @ExportButtonPushed, true);
            app.ExportButton.Position = [30 320 110 30];
            app.ExportButton.Text = 'Export PDF';

            % Create ClearButton
            app.ClearButton = uibutton(app.UIFigure, 'push');
            app.ClearButton.ButtonPushedFcn = createCallbackFcn(app, @ClearButtonPushed, true);
            app.ClearButton.Position = [150 320 110 30];
            app.ClearButton.Text = 'Clear Data';

            % Create ThemeToggleButton
            app.ThemeToggleButton = uibutton(app.UIFigure, 'push');
            app.ThemeToggleButton.ButtonPushedFcn = createCallbackFcn(app, @ThemeToggleButtonPushed, true);
            app.ThemeToggleButton.Position = [30 280 230 30];
            app.ThemeToggleButton.Text = 'Light Theme';

            % Show the figure after all components are created
            app.UIFigure.Visible = 'on';
        end
    end

    % App creation and deletion
    methods (Access = public)

        % Construct app
        function app = ScannerApp()
            createComponents(app)
            registerApp(app, app.UIFigure)
            runStartupFcn(app, @startupFcn)
            if nargout == 0
                clear app
            end
        end

        % Code that executes before app deletion
        function delete(app)
            if ~isempty(app.TimerObj) && isvalid(app.TimerObj)
                stop(app.TimerObj);
                delete(app.TimerObj);
            end
            if ~isempty(app.SweepAnimTimer) && isvalid(app.SweepAnimTimer)
                stop(app.SweepAnimTimer);
                delete(app.SweepAnimTimer);
            end
            app.disconnectSerial();
            delete(app.UIFigure)
        end
    end
end