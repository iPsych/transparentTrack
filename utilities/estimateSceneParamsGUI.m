function [ x, candidateSceneGeometry ] = estimateSceneParamsGUI(sceneGeometryFileName, varargin)
% Adjust scene parameter values
%
% Syntax:
%  [ initialParams ] = estimateSceneParamsGUI(grayVideoName)
%
% Description:
%
% Examples:
%{
    % ETTBSkip -- This is an idiosyncratic example.
    sceneGeometryFileName = '~/Dropbox (Aguirre-Brainard Lab)/TOME_processing/session1_restAndStructure/TOME_3038/071118/EyeTracking/GazeCal_sceneGeometry.mat';
    load(sceneGeometryFileName)
    ellipseArrayList = sceneGeometry.meta.estimateSceneParams.ellipseArrayList;
    grayVideoName = '~/Dropbox (Aguirre-Brainard Lab)/TOME_processing/session1_restAndStructure/TOME_3038/071118/EyeTracking/GazeCal_gray.avi';
    initialParams = estimateSceneParamsGUI(sceneGeometryFileName, 'grayVideoName', grayVideoName, 'ellipseArrayList',ellipseArrayList)
%}


%% Input parser
p = inputParser; p.KeepUnmatched = true;

% Required
p.addOptional('sceneGeometryFileName', [], @(x)(isempty(x) || ischar(x)));

% Optional
p.addParameter('perimeterFileName',[], @(x)(isempty(x) || ischar(x)));
p.addParameter('grayVideoName',[], @(x)(isempty(x) || ischar(x)));
p.addParameter('videoSuffix', '_gray.avi', @(x)(isempty(x) || ischar(x)));
p.addParameter('ellipseArrayList',[], @(x)(isempty(x) || isnumeric(x)));

% parse
p.parse(sceneGeometryFileName, varargin{:})

% offer a file picker dialog if needed
if isempty(sceneGeometryFileName)
    [fileName, path] = uigetfile({'*_sceneGeometry.mat'});
    if isempty(fileName)
        return
    end
    sceneGeometryFileName = [path, fileName];
end

% Load the sceneGeometry
dataLoad=load(sceneGeometryFileName);
sceneGeometry=dataLoad.sceneGeometry;
clear dataLoad

% Identify the video file
if ~isempty(p.Results.grayVideoName)
    grayVideoName = p.Results.grayVideoName;
else
    grayVideoName = strrep(sceneGeometryFileName,'_sceneGeometry.mat',p.Results.videoSuffix);
end

% Identify the frames of the ellipse array
if ~isempty(p.Results.ellipseArrayList)
    ellipseArrayList = p.Results.ellipseArrayList;
else
    % No frames specified. See if there is a list of frames from estimation
    % of sceneGeometry
    if issubfield(sceneGeometry, 'meta.estimateSceneParams.search.ellipseArrayList')
        ellipseArrayList = sceneGeometry.meta.estimateSceneParams.search.ellipseArrayList;
    else
        % No frames specified. Try to find the time zero frame
        timebaseFileName = strrep(grayVideoName,p.Results.videoSuffix,'_timebase.mat');
        if exist(timebaseFileName, 'file')==2
            dataLoad=load(timebaseFileName);
            timebase=dataLoad.timebase;
            clear dataLoad
            [~,ellipseArrayList] = min(abs(timebase.values));
        else
            % Just show the first frame;
            ellipseArrayList = 1;
        end
    end
end

% Get the video properties
videoInObj = videoIOWrapper(grayVideoName,'ioAction','read');
videoSizeX = videoInObj.Width;
videoSizeY = videoInObj.Height;

% Pre-load the video frames we will use
% Define a variable to hold the selected frames
sourceFrames = zeros(videoSizeY,videoSizeX,3,length(ellipseArrayList),'uint8');
for ii = 1:length(ellipseArrayList)
    frameIdx = ellipseArrayList(ii);
    % Obtain and render the frame
    videoInObj.CurrentTime = (frameIdx - 1)/(videoInObj.FrameRate);
    sourceFrames(:,:,:,ii) = readFrame(videoInObj);
end

% close the video object
clear videoInObj

% Load the pupil perimeter data. It will be a structure variable
% "perimeter", with the fields .data and .meta
if isempty(p.Results.perimeterFileName)
    perimeterFileName = strrep(grayVideoName,p.Results.videoSuffix,'_correctedPerimeter.mat');
else
    perimeterFileName = p.Results.perimeterFileName;
end
dataLoad=load(perimeterFileName);
perimeter=dataLoad.perimeter;
clear dataLoad

% Load the relativeCameraPosition file if it exists.
relativeCameraPositionFileName = strrep(grayVideoName,p.Results.videoSuffix,'_relativeCameraPosition.mat');
if exist(relativeCameraPositionFileName, 'file')==2
    dataLoad=load(relativeCameraPositionFileName);
    relativeCameraPosition=dataLoad.relativeCameraPosition;
    clear dataLoad
else
    relativeCameraPosition=[];
end


% Provide some instructions for the operator
fprintf('Adjust horizontal /vertical camera translation with the arrow keys.\n');
fprintf('Adjust depth camera translation with + and -.\n');
fprintf('Adjust camera torsion with j and k.\n');
fprintf('Move forward and backward in the ellipse frames with a and s\n')
fprintf('Press return to be prompted to enter scene param values as text.\n');
fprintf('Press r to be prompted to enter eye rotation params.\n');
fprintf('Press esc to exit.\n');

% Set the current index and scene params
arrayIdx = 1;
if isfield(sceneGeometry.meta,'estimateSceneParams')
    x = sceneGeometry.meta.estimateSceneParams.search.x;
else
    x = [sceneGeometry.cameraPosition.torsion; ...
        sceneGeometry.cameraPosition.translation; ...
        1; ...
        1 ];
end

% Calculate eye rotatiom centers that correspond to x(5:6) = [1 1]
defaultAziRotCenter = sceneGeometry.eye.rotationCenters.azi ./ x(5) ./ x(6);
defaultEleRotCenter = sceneGeometry.eye.rotationCenters.ele ./ x(5) .* x(6);

% Prepare the main figure
figHandle=figure('Visible','on');
annotHandle=[];

% Enter a while loop
notDoneFlag = true;

while notDoneFlag
    
    % Update the scene parameters
    candidateSceneGeometry = sceneGeometry;
    candidateSceneGeometry.cameraPosition.torsion = x(1);
    candidateSceneGeometry.cameraPosition.translation = x(2:4);
    candidateSceneGeometry.eye.rotationCenters.azi = defaultAziRotCenter .* x(5) .* x(6);
    candidateSceneGeometry.eye.rotationCenters.ele = defaultEleRotCenter .* x(5) ./ x(6);
    
    % Identify the frame to display
    frameIdx = ellipseArrayList(arrayIdx);
    
    % Adjust for relative camera position
    adjustedSceneGeometry = candidateSceneGeometry;
    if ~isempty(relativeCameraPosition)
        cameraPosition = candidateSceneGeometry.cameraPosition.translation;
        cameraPosition = cameraPosition - relativeCameraPosition.values(:,frameIdx);
        adjustedSceneGeometry.cameraPosition.translation = cameraPosition;
    end
    
    % Obtain the eye pose from the boundary points from the perimeter
    Xp = perimeter.data{frameIdx}.Xp;
    Yp = perimeter.data{frameIdx}.Yp;
    eyePose = eyePoseEllipseFit(Xp, Yp, adjustedSceneGeometry);
    
    % Show this video frame
    thisFrame = sourceFrames(:,:,:,arrayIdx);
    frameLabel = sprintf('frame: %d',frameIdx);
    thisFrame = insertText(thisFrame,[20 20],frameLabel,'FontSize',30);
    imshow(squeeze(thisFrame));
    
    % Add the rendered eye model
    if ~any(isnan(eyePose))
        renderEyePose(eyePose, adjustedSceneGeometry, ...
            'newFigure', false, 'visible', true, ...
            'showAzimuthPlane', true, ...
            'modelEyeLabelNames', {'retina' 'irisPerimeter' 'pupilEllipse' 'cornea' 'aziRotationCenter'}, ...
            'modelEyePlotColors', {'.w' '.b' '-g' '.y' '+c'}, ...
            'modelEyeSymbolSizeScaler',1.5,...
            'modelEyeAlpha', 0.25);
    end
    
    if ~isempty(annotHandle)
        delete(annotHandle)
    end
    
    % Wait for operator input
    fprintf('torsion: %0.2f, translation [%0.2f; %0.2f; %0.2f], eye rotation [%0.2f; %0.2f]\n',x(1),x(2),x(3),x(4),x(5),x(6));
    waitforbuttonpress
    keyChoiceValue = double(get(gcf,'CurrentCharacter'));
    switch keyChoiceValue
        case 28
            text_str = 'translate left';
            x(2)=x(2)-0.5;
        case 29
            text_str = 'translate right';
            x(2)=x(2)+0.5;
        case 30
            text_str = 'translate up';
            x(3)=x(3)+0.5;
        case 31
            text_str = 'translate down';
            x(3)=x(3)-0.5;
        case {45 95}
            text_str = 'translate closer in';
            x(4)=x(4)-1;
        case {61 43}
            text_str = 'translate farther away';
            x(4)=x(4)+1;
        case 97
            text_str = 'prior frame';
            arrayIdx = arrayIdx-1;
            if arrayIdx == 0
                arrayIdx = length(ellipseArrayList);
            end
        case 115
            text_str = 'next frame';
            arrayIdx = arrayIdx+1;
            if arrayIdx > length(ellipseArrayList)
                arrayIdx = 1;
            end
        case 106
            text_str = 'counter-clockwise torsion';
            x(1)=x(1)-1;
        case 107
            text_str = 'clockwise torsion';
            x(1)=x(1)+1;
        case 13
            x(1:4) = input('Enter values in square brackets, separated by semi-colons [tor;x;y;z]:');
            text_str = 'manual param entry';
        case 114
            x(5:6) = input('Enter rotation scale values in square brackets, separated by semi-colons [joint;diff]:');
            text_str = 'manual param entry';
        case 27
            notDoneFlag = false;
        otherwise
            text_str = 'unrecognized command';
    end
    
    if notDoneFlag
        annotHandle = annotation('textbox',...
            [.80 .85 .1 .1],...
            'HorizontalAlignment','center',...
            'VerticalAlignment','middle',...
            'Margin',1,...
            'String',text_str,...
            'FontSize',9,...
            'FontName','Helvetica',...
            'EdgeColor',[1 1 1],...
            'LineWidth',1,...
            'BackgroundColor',[0.9  0.9 0.9],...
            'Color',[1 0 0]);
        drawnow
        hold off
    end
end

% Clean up
close(figHandle)
fprintf('\n');
fprintf('scene parameters = [%0.2f; %0.2f; %0.2f; %0.2f; %0.2f; %0.2f]\n',x(1),x(2),x(3),x(4),x(5),x(6));

end % Main function



%% LOCAL FUNCTION

function r = issubfield(s, f)
if isempty(f) || isempty(s)
    r = false;
else
    t = textscan(f,'%s','delimiter','.');
    t = t{1};
    r = true;
    for k = 1:numel(t)
        if isfield(s, t{k})
            s = s.(t{k});
        else
            r = false;
            return;
        end
    end
end
end % issubfield
