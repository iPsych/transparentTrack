function syncSceneGeometry(sceneGeometryFileName, pupilFileName, varargin)
% The change in camera position between a sceneGeometry and an acquisition
%
% Syntax:
%
%
% Description:
%   A sceneGeometry file is created for a given acquisition. Included in
%   the sceneGeometry is a specification of properties of the extrinsic
%   camera matrix, including the position of the camera in space relative
%   to the coordinates, which have as their origin the anterior surface of
%   the cornea along the optical axis of the eye. If we wish to use this
%   sceneGeometry file for the analysis of data from other acqusitions for
%   a given subject, we need to deal with the possibility that the subject
%   has moved their head between acquisitions. As the coordinate system is
%   based upon a fixed anatomical landmark of the eye, the effect of head
%   translation in this system is to change the camera position. This
%   routine assists in calculating an updated camera position for a given
%   acquisition.
%
%   Select a sceneGeometry with the UI file picker, then select the
%   acquisitions to which you would like to align the sceneGeometry.
%   An image derived from the sceneGeometry and the acquisition is shown,
%   and controls are used to adjust the acquisition to match the
%   sceneGeometry.
%
% Inputs:
%   sceneGeometryFileName - Full path to the .mat file that contains the
%                           sceneGeometry to be used.
%   pupilFileName         - Full path to the .mat file that contains the
%                           pupil data to which the sceneGeometry should be
%                           synced.
%
% Examples:
%{
    % Invoke the file picker GUI
    syncSceneGeometry('','');
%}


%% Parse vargin for options passed here
p = inputParser; p.KeepUnmatched = true;

% Required
p.addRequired('sceneGeometryFileName',@ischar);
p.addRequired('pupilFileName',@ischar);

% Optional display and I/O params
p.addParameter('verbose',false,@islogical);
p.addParameter('displayMode',false,@islogical);
p.addParameter('saveAdjustedSceneGeome',true,@islogical);

% Optional fitting params
p.addParameter('alignMethod','gazePre',@ischar);
p.addParameter('adjustedCameraPositionTranslation',[],@isnumeric);
p.addParameter('adjustedCameraPositionTorsion',[],@isnumeric);
p.addParameter('adjustedCameraPositionFixationAngles',[],@isnumeric);
p.addParameter('eyePositionTargetLength',30,@isscalar);


%% Parse and check the parameters
p.parse(sceneGeometryFileName, pupilFileName, varargin{:});


%% Load the sceneGeometry file
if isempty(sceneGeometryFileName)
    % Open a file picker UI to select a sceneGeometry
    [file,path] = uigetfile(fullfile('.','*_sceneGeometry.mat'),'Choose a sceneGeometry file');
    sceneGeometryIn = fullfile(path,file);
else
    sceneGeometryIn = sceneGeometryFileName;
    tmp = strsplit(sceneGeometryIn,filesep);
    file = tmp{end};
    path = strcat(tmp(1:end-1));
end

% Load the selected sceneGeometry file
dataLoad=load(sceneGeometryIn);
sceneGeometrySource=dataLoad.sceneGeometry;
clear dataLoad


%% Derive pupil properties from the sceneGeometry
% Find the scene geometry video frames that correspond to fixation at the
% [0 0] screen position, and the eye at a neutral (zero azimuth and
% elevation) position

% Load the pupil data file associated with the sceneGeometry
fileParts = strsplit(file,'_sceneGeometry.mat');
fileStem = fileParts{1};
fileIn = fullfile(path,[fileStem,'_pupil.mat']);
load(fileIn,'pupilData');

% Obtain the eye rotation values from the pupilData, and convert these into
% gaze position on the screen.
eyeRotation = pupilData.radiusSmoothed.eyePoses.values(:,1:2)';
gazePosition = (sceneGeometrySource.screenPosition.R * eyeRotation + sceneGeometrySource.screenPosition.fixationAngles(1:2)')';

% Find the minimum fixation error threshold that results in a run of
% consecutive frames at fixation of the target length.
targetLength = p.Results.eyePositionTargetLength;
runStarts = @(thresh) find(diff([0,(sqrt(sum(gazePosition.^2,2)) < thresh)',0]==1));
pullStartIndices = @(vec) vec(1:2:end-1);
pullRunLengths = @(vec) vec(2:2:end)-pullStartIndices(vec);
myObj = @(thresh) targetLength - max( pullRunLengths(runStarts(thresh)) );
threshVal = fzero(myObj,0.5);

% Find the start point of this run of frames
runLengths = pullRunLengths(runStarts(threshVal));
runIndices = pullStartIndices(runStarts(threshVal));
runLength = targetLength-myObj(threshVal);
startIndex = runIndices(runLengths == runLength);

% Load in the median image from the period of fixation for the
% sceneGeometry file. This is the "fixed" frame.
videoInFileName = fullfile(path,[fileStem '_gray.avi']);
fixedFrame = makeMedianVideoImage(videoInFileName,'startFrame',startIndex,'nFrames',runLength,'chunkSizeSecs',1/60);

% Find the median pupil center for these frames
fixFramePupilCenterFixation = [ ...
    nanmedian(pupilData.radiusSmoothed.ellipses.values(startIndex:startIndex+runLength,1)), ...
    nanmedian(pupilData.radiusSmoothed.ellipses.values(startIndex:startIndex+runLength,2)) ];

% Find the median theta and rho value for these frames (SEE:
% csaEllipseError)
fixFramePupilRhoShape = nanmedian(pupilData.radiusSmoothed.ellipses.values(startIndex:startIndex+runLength,4));
fixFramePupilRhoShape = 1-sqrt(1-fixFramePupilRhoShape^2);
fixFramePupilThetaShape = nanmedian(pupilData.radiusSmoothed.ellipses.values(startIndex:startIndex+runLength,5));
fixFramePupilThetaShape = fixFramePupilThetaShape*2;

% Load the perimter for this sceneGeometry file
perimeterFileName = fullfile(path,[fileStem '_correctedPerimeter.mat']);
load(perimeterFileName,'perimeter');

% Find the frame with the lowest ellipse RMSE during this period
rmseVals = pupilData.radiusSmoothed.ellipses.RMSE(startIndex:startIndex+runLength);
bestFrameFixed = startIndex + find(rmseVals == min(rmseVals)) - 1;
Xpf = perimeter.data{bestFrameFixed}.Xp;
Ypf = perimeter.data{bestFrameFixed}.Yp;

% Get the camera offset point
cameraOffsetPoint = [sceneGeometrySource.cameraIntrinsic.matrix(1,3), ...
    sceneGeometrySource.cameraIntrinsic.matrix(2,3)];


%% Load the acquisition to which the sceneGeometry is to be synced
% If the pupilFileName is not defined, offer some choices
if isempty(pupilFileName)
    % Get a list of all gray.avi videos in this directory
    fileList = dir(fullfile(path,'*_pupil.mat'));
    
    % Exclude the video that is the source of the fixed image
    keep=cellfun(@(x) ~strcmp(x,[fileStem '_pupil.mat']),extractfield(fileList,'name'));
    fileList = fileList(keep);
    
    % Ask the operator which of the videos we wish to adjust
    fprintf('\n\nSelect the pupil data to adjust:\n')
    for pp=1:length(fileList)
        optionName=['\t' num2str(pp) '. ' fileList(pp).name '\n'];
        fprintf(optionName);
    end
    fprintf('\nYou can enter a single acquisition number (e.g. 4),\n  a range defined with a colon (e.g. 4:7),\n  or a list within square brackets (e.g., [4 5 7]):\n')
    choice = input('\nYour choice: ','s');
    fileList = fileList(eval(choice));
    
    pupilFileName = fullfile(path,fileList(1).name);
end

% Load the timebase, pupilData, and perimeter for this acquisition
tmp = strsplit(pupilFileName,filesep);
tmp = strsplit(tmp{end},'_pupil.mat');
acqFileStem = tmp{1};

timebaseFileName = fullfile(path,[acqFileStem '_timebase.mat']);
load(timebaseFileName,'timebase');
pupilFileName =  fullfile(path,[acqFileStem '_pupil.mat']);
load(pupilFileName,'pupilData');
perimeterFileName =  fullfile(path,[acqFileStem '_correctedPerimeter.mat']);
load(perimeterFileName,'perimeter');

% Identify the startFrame, which is the time point at which the fMRI
% acquisition began
[~, frameTimeZero] = min(abs(timebase.values));

% Set the target length
targetLength = p.Results.eyePositionTargetLength;

% Identify a target period for the moving image, with the approach varying
% based upon the alignMethod flag.
switch p.Results.alignMethod
    case 'gazePre'
        % Find the period prior to the start of the scan
        % when the eye was in the most consistent position, and closest
        % to the median position
        windowStart = 1;
        windowEnd = frameTimeZero;
        gazeX = pupilData.initial.ellipses.values(windowStart:windowEnd,1);
        gazeY = pupilData.initial.ellipses.values(windowStart:windowEnd,2);
        medianX = nanmedian(gazeX);
        medianY = nanmedian(gazeY);
        gazePosition = [gazeX-medianX; gazeY-medianY];
        
        runStarts = @(thresh) find(diff([0,(sqrt(sum(gazePosition.^2,2)) < thresh)',0]==1));
        pullStartIndices = @(vec) vec(1:2:end-1);
        pullRunLengths = @(vec) vec(2:2:end)-pullStartIndices(vec);
        myObj = @(thresh) targetLength - max( pullRunLengths(runStarts(thresh)) );
        threshVal = fzero(myObj,0.5);
    case 'gazePost'
        % Find the period after to the start of the scan when the eye was
        % in the most consistent position, and closest to the median
        % position. This is used for retinotopic mapping runs which did not
        % include a fixation target prior to the start of the scan.
        windowStart = frameTimeZero;
        windowEnd = frameTimeZero+600;
        gazeX = pupilData.initial.ellipses.values(windowStart:windowEnd,1);
        gazeY = pupilData.initial.ellipses.values(windowStart:windowEnd,2);
        medianX = nanmedian(gazeX);
        medianY = nanmedian(gazeY);
        gazePosition = [gazeX-medianX; gazeY-medianY];
        
        runStarts = @(thresh) find(diff([0,(sqrt(sum(gazePosition.^2,2)) < thresh)',0]==1));
        pullStartIndices = @(vec) vec(1:2:end-1);
        pullRunLengths = @(vec) vec(2:2:end)-pullStartIndices(vec);
        myObj = @(thresh) targetLength - max( pullRunLengths(runStarts(thresh)) );
        threshVal = fzero(myObj,0.5);        
    case 'shape'
        % Find the period after the start of the scan when
        % the pupil has a shape most similar to the shape from the
        % sceneGeometry file for gaze [0 0]
        windowStart = frameTimeZero;
        windowEnd = size(pupilData.initial.ellipses.values,1);
        rho = pupilData.initial.ellipses.values(windowStart:windowEnd,4);
        rho = 1-sqrt(1-rho.^2);
        theta = pupilData.initial.ellipses.values(windowStart:windowEnd,5);
        theta = theta.*2;
        
        shapeError = ...
            sqrt(fixFramePupilRhoShape^2 + rho.^2 - 2*fixFramePupilRhoShape.*rho.*cos(fixFramePupilThetaShape-theta))./2;
        
        runStarts = @(thresh) find(diff([0,(sqrt(sum(shapeError.^2,2)) < thresh)',0]==1));
        pullStartIndices = @(vec) vec(1:2:end-1);
        pullRunLengths = @(vec) vec(2:2:end)-pullStartIndices(vec);
        % This min([1e6 obj]) trick is to handle the objective otherwise
        % returning an empty value for a threshold of zero.
        myObj = @(thresh) min([1e6, targetLength - max( pullRunLengths(runStarts(thresh)) )]);
        threshVal = fzero(myObj,0.05);
        
end

% Find the start point of this run of frames
runLengths = pullRunLengths(runStarts(threshVal));
runIndices = pullStartIndices(runStarts(threshVal))+windowStart-1;
runLength = targetLength-myObj(threshVal);
startIndex = runIndices(runLengths == runLength);

% Find the frame with the lowest ellipse RMSE during this period, and then
% load the perimeter for that frame.
rmseVals = pupilData.initial.ellipses.RMSE(startIndex:startIndex+runLength);
bestFrameMoving = startIndex + find(rmseVals == min(rmseVals)) - 1;
Xpm = perimeter.data{bestFrameMoving}.Xp;
Ypm = perimeter.data{bestFrameMoving}.Yp;

% Obtain the median [x y] position of the pupil center during the target
% period of the moving image, and use this to determine the displacement
% (in pixels) from the [x y] position of the pupil center during the
% corresponding target period from the fixed (sceneGeometry) image.

% Get the pupil center for the fames from the moving video
movingFramePupilCenterFixation = [ ...
    nanmedian(pupilData.initial.ellipses.values(startIndex:startIndex+runLength,1)), ...
    nanmedian(pupilData.initial.ellipses.values(startIndex:startIndex+runLength,2)) ];
% The adjustment is the difference in pupil centers from the fixed
% and moving videos
x = fixFramePupilCenterFixation - movingFramePupilCenterFixation;

% Define the video file name
videoInFileName = fullfile(path,[acqFileStem '_gray.avi']);

% Load the moving frame
movingFrame = makeMedianVideoImage(videoInFileName,'startFrame',startIndex,'nFrames',runLength,'chunkSizeSecs',1/60);

% No change is made to the torsion unless we are in display mode
torsion = 0;

%% Display mode
% If we are in display mode, offer an interface for the user to manually
% adjust the sceneGeometry alignment

if p.Results.displayMode
    % Create a figure
    figHandle = figure();
    imshow(fixedFrame,[],'Border','tight');
    ax = gca;
    ax.Toolbar = [];
    hold on
    text(20,30,'FIXED', 'Color', 'g','Fontsize',16);
    
    % Provide some instructions for the operator
    fprintf('Adjust horizontal and vertical camera translation with the arrow keys.\n');
    fprintf('Adjust camera torsion with j and k.\n');
    fprintf('Switch between moving and fixed image by pressing a.\n');
    fprintf('Turn on and off perimeter display with p.\n');
    fprintf('Turn on and off model display with m.\n');
    fprintf('Press esc to exit.\n\n');
    fprintf([path '\n']);
    
    % Prepare for the loop
    showMoving = true;
    showPerimeter=false;
    showModel=false;
    stillWorking = true;
    
    % Enter the while stillWorking loop
    while stillWorking
        
        % Prepare to update the image
        hold off
        
        if showMoving
            % Work with the moving frame
            displayImage = updateMovingFrame(movingFrame,x,torsion,cameraOffsetPoint);
            
            % Update the perimeter points
            [Xpa, Ypa] = updatePerimeter(Xpm,Ypm,x,-torsion,cameraOffsetPoint);
            
            % Display the perimeter points
            if showPerimeter
                idx = sub2ind(size(displayImage),round(Ypa),round(Xpa));
                displayImage(idx)=255;
            end
            
            % Display the image
            imshow(displayImage,[],'Border','tight');
            ax = gca;
            ax.Toolbar = [];
            hold on
            text(20,30,'MOVING', 'Color', 'r','Fontsize',16);
            
        else
            displayImage = fixedFrame;
            
            % Update the perimeter
            Xpa = Xpf; Ypa = Ypf;
            
            % Display the perimeter points
            if showPerimeter
                idx = sub2ind(size(displayImage),round(Ypa),round(Xpa));
                displayImage(idx)=255;
            end
            
            imshow(displayImage,[],'Border','tight');
            ax = gca;
            ax.Toolbar = [];
            hold on
            text(20,30,'FIXED', 'Color', 'g','Fontsize',16);
        end
        
        % Show the eye model
        if showModel
            % Let the user know this will take a few seconds
            text_str = 'Updating model...';
            annotHandle = addAnnotation(text_str);
            % Obtain the eye pose from the adjusted perimeter
            eyePose = eyePoseEllipseFit(Xpa, Ypa, sceneGeometrySource);
            % Render the eye model
            renderEyePose(eyePose, sceneGeometrySource, ...
                'newFigure', false, 'visible', true, ...
                'showAzimuthPlane', true, ...
                'modelEyeLabelNames', {'retina' 'pupilEllipse' 'cornea'}, ...
                'modelEyePlotColors', {'.w' '-g' '.y'}, ...
                'modelEyeSymbolSizeScaler',1.5,...
                'modelEyeAlpha', 0.25);
            hold on
            % Remove the updating annotation
            delete(annotHandle);
        end
        
        % Add a marker for the camera CoP
        plot(cameraOffsetPoint(1),cameraOffsetPoint(2),'+c');
        
        keyAction = waitforbuttonpress;
        if keyAction
            keyChoiceValue = double(get(gcf,'CurrentCharacter'));
            switch keyChoiceValue
                case 28
                    x(1)=x(1)-1;
                case 29
                    x(1)=x(1)+1;
                case 30
                    x(2)=x(2)-1;
                case 31
                    x(2)=x(2)+1;
                case 97
                    showMoving = ~showMoving;
                case 106
                    torsion = torsion - 1;
                case 107
                    torsion = torsion + 1;
                case 112
                    showPerimeter = ~showPerimeter;
                case 109
                    showModel = ~showModel;
                case 27
                    text_str = 'finishing...';
                    annotHandle = addAnnotation(text_str);
                    stillWorking = false;
                otherwise
                    text_str = 'unrecognized command';
            end
            
        end
    end
    
    %    close(figHandle);
end


%% Create the adjusted sceneGeometry
% Obtain the eye pose from the adjusted perimeter
[Xpa, Ypa] = updatePerimeter(Xpm,Ypm,x,-torsion,cameraOffsetPoint);
eyePose = eyePoseEllipseFit(Xpa, Ypa, sceneGeometrySource);

% Calculate the updated camera rotation
newCameraTorsion = sceneGeometrySource.cameraPosition.torsion - torsion;

% Update the sceneGeometry torsion
sceneGeometryAdjusted = sceneGeometrySource;
sceneGeometryAdjusted.cameraPosition.torsion = newCameraTorsion;

% Find the change in the extrinsic camera translation needed to shift
% the eye model the observed number of pixels
adjTranslation = calcCameraTranslationPixels(sceneGeometryAdjusted,eyePose,x);

% Update the sceneGeometry translation
sceneGeometryAdjusted.cameraPosition.translation = adjTranslation;

% Obtain the eye pose for the adjusted sceneGeometry
eyePoseAcq = eyePoseEllipseFit(Xpm, Ypm, sceneGeometryAdjusted);
sceneGeometryAdjusted.screenPosition.fixationAngles = -eyePoseAcq(1:3);

% Save the adjusted sceneGeometry


%% Create and save a diagnostic figure
saveDiagnosticPlot=true;
if saveDiagnosticPlot

    % Fixed frame
    displayImage = fixedFrame;
    idx = sub2ind(size(displayImage),round(Ypf),round(Xpf));
    displayImage(idx)=255;
    eyePoseSource = eyePoseEllipseFit(Xpf, Ypf, sceneGeometrySource);
    tmpFig = figure('visible','off');
    renderEyePose(eyePoseSource, sceneGeometrySource, ...
        'newFigure', false, 'visible', false, ...
        'backgroundImage',displayImage, ...
        'showAzimuthPlane', true, ...
        'modelEyeLabelNames', {'retina' 'pupilEllipse' 'cornea'}, ...
        'modelEyePlotColors', {'.w' '-g' '.y'}, ...
        'modelEyeSymbolSizeScaler',1.5,...
        'modelEyeAlpha', 0.25);
    text(20,30,fileStem, 'Color', 'r','Fontsize',16,'Interpreter','none');
    msg = ['frame ' num2str(bestFrameFixed)];
    addAnnotation(msg);
    % Add cross hairs
    hold on
    plot([size(displayImage,2)/2, size(displayImage,2)/2],[0 size(displayImage,2)],'-b');
    plot([0 size(displayImage,1)],[size(displayImage,1)/2, size(displayImage,1)/2],'-b');
    tmpFrame = getframe(gcf);
    imageSet(1) = {tmpFrame.cdata};
    close(tmpFig);
    
    % Moving frame
    displayImage = movingFrame;
    idx = sub2ind(size(displayImage),round(Ypm),round(Xpm));
    displayImage(idx)=255;
    eyePoseAcq = eyePoseEllipseFit(Xpm, Ypm, sceneGeometryAdjusted);
    tmpFig = figure('visible','off');
    renderEyePose(eyePoseAcq, sceneGeometryAdjusted, ...
        'newFigure', false, 'visible', false, ...
        'backgroundImage',displayImage, ...
        'showAzimuthPlane', true, ...
        'modelEyeLabelNames', {'retina' 'pupilEllipse' 'cornea'}, ...
        'modelEyePlotColors', {'.w' '-g' '.y'}, ...
        'modelEyeSymbolSizeScaler',1.5,...
        'modelEyeAlpha', 0.25);
    text(20,30,acqFileStem, 'Color', 'g','Fontsize',16,'Interpreter','none');
    msg = ['frame ' num2str(bestFrameMoving)];
    addAnnotation(msg);
    hold on
    plot([size(displayImage,2)/2, size(displayImage,2)/2],[0 size(displayImage,2)],'-b');
    plot([0 size(displayImage,1)],[size(displayImage,1)/2, size(displayImage,1)/2],'-b');
    tmpFrame = getframe(gcf);
    imageSet(2) = {tmpFrame.cdata};
    close(tmpFig);
    
    % Difference image
    adjMovingFrame = updateMovingFrame(movingFrame,x,torsion,cameraOffsetPoint);
    displayImage = fixedFrame - adjMovingFrame;
    tmpFig = figure('visible','off');
    imshow(displayImage,[], 'Border', 'tight');
    text(20,30,'Difference', 'Color', 'w','Fontsize',16,'Interpreter','none');
    tmpFrame = getframe(gcf);
    imageSet(3) = {tmpFrame.cdata};
    close(tmpFig);
    
    % Prepare the figure
    figHandle=figure('visible','on');
    set(gcf,'PaperOrientation','landscape');
    
    set(figHandle, 'Units','inches')
    height = 12;
    width = 30;
    
    % The last two parameters of 'Position' define the figure size
    set(figHandle, 'Position',[25 5 width height],...
        'PaperSize',[width height],...
        'PaperPositionMode','auto',...
        'Color','w',...
        'Renderer','painters'...
        );
    montage(imageSet,'Size', [1 3]);
    
    % Post the title
    pathParts = strsplit(path,filesep);
    titleString = [fullfile(pathParts{end-4:end-2}) '; alignMethod: ' p.Results.alignMethod];
    title(titleString,'Interpreter','none')
    
    % Add a text summary below
    % Report the values
    msg = sprintf('delta translation [x; y; z] = [%2.3f; %2.3f; %2.3f]',adjTranslation - sceneGeometrySource.cameraPosition.translation);
    annotation('textbox', [0.5, .2, 0, 0], 'string', msg,'FitBoxToText','on','LineStyle','none','HorizontalAlignment','center','Interpreter','none')
    msg = sprintf('delta torsion [deg] = %2.3f',torsion);
    annotation('textbox', [0.5, .15, 0, 0], 'string', msg,'FitBoxToText','on','LineStyle','none','HorizontalAlignment','center','Interpreter','none')
    msg = sprintf('delta fixation agles [azi, ele, tor] = [%2.3f; %2.3f; %2.3f]',eyePoseSource(1:3)-eyePoseAcq(1:3));
    annotation('textbox', [0.5, .1, 0, 0], 'string', msg,'FitBoxToText','on','LineStyle','none','HorizontalAlignment','center','Interpreter','none')

    % Save the figure
    figFileOut = fullfile(path);
    
    foo = 1;
end


end % Main function





%% LOCAL FUNCTIONS

function [Xp, Yp] = updatePerimeter(Xp,Yp,x,torsion,cameraOffsetPoint)

% Create a matrix of the perimeter points
v = [Xp';Yp'];

% Create the translation matrix
t = repmat([x(1); x(2)], 1, length(Xp));

% Translate the points
v = v+t;

% Set up the rotation matrix
center = repmat([cameraOffsetPoint(1); cameraOffsetPoint(2)], 1, length(Xp));
theta = deg2rad(-torsion);
R = [cos(theta) -sin(theta); sin(theta) cos(theta)];

% Apply the rotation
v = R*(v - center) + center;

% Extract the Xp and Yp vectors
Xp = v(1,:)';
Yp = v(2,:)';

end


function p = calcCameraTranslationPixels(sceneGeometrySource,eyePose,x)

% Find the change in the extrinsic camera translation needed to shift
% the eye model the observed number of pixels for an eye with zero rotation

p0 = sceneGeometrySource.cameraPosition.translation;
ub = sceneGeometrySource.cameraPosition.translation + [10; 10; 0];
lb = sceneGeometrySource.cameraPosition.translation - [10; 10; 0];
place = {'cameraPosition' 'translation'};
mySG = @(p) setfield(sceneGeometrySource,place{:},p);
pupilCenter = @(k) k(1:2);
targetPupilCenter = pupilCenter(pupilProjection_fwd(eyePose,sceneGeometrySource)) - x;
myError = @(p) norm(targetPupilCenter-pupilCenter(pupilProjection_fwd(eyePose,mySG(p))));
options = optimoptions(@fmincon,'Diagnostics','off','Display','off');
p = fmincon(myError,p0,[],[],[],[],lb,ub,[],options);
end


function annotHandle = addAnnotation(text_str)

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

end


function displayImage = updateMovingFrame(movingFrame,x,torsion,cameraOffsetPoint)

            % Embed the movingFrame within a larger image that is padded
            % with mid-point background values
            padVals = round(size(movingFrame)./2);
            displayImagePad = zeros(size(movingFrame)+padVals.*2)+125;
            displayImagePad(padVals(1)+1:padVals(1)+size(movingFrame,1), ...
                padVals(2)+1:padVals(2)+size(movingFrame,2) ) = movingFrame;
            displayImage = displayImagePad;
            % Apply the x and y translation
            displayImage = imtranslate(displayImage,x,'method','cubic');
            % Crop out the padding
            displayImage = displayImage(padVals(1)+1:padVals(1)+size(movingFrame,1), ...
                padVals(2)+1:padVals(2)+size(movingFrame,2));
            % Rotate the image
            displayImage = imrotateAround(displayImage, cameraOffsetPoint(2), cameraOffsetPoint(1), -torsion, 'bicubic');
            
end


function output = imrotateAround(image, pointY, pointX, angle, varargin)
% ROTATEAROUND rotates an image.
%   ROTATED=ROTATEAROUND(IMAGE, POINTY, POINTX, ANGLE) rotates IMAGE around
%   the point [POINTY, POINTX] by ANGLE degrees. To rotate the image
%   clockwise, specify a negative value for ANGLE.
%
%   ROTATED=ROTATEAROUND(IMAGE, POINTY, POINTX, ANGLE, METHOD) rotates the
%   image with specified method:
%       'nearest'       Nearest-neighbor interpolation
%       'bilinear'      Bilinear interpolation
%       'bicubic'       Bicubic interpolation
%    The default is fast 'nearest'. Switch to 'bicubic' for nicer results.
%
%   Example
%   -------
%       imshow(rotateAround(imread('eight.tif'), 1, 1, 10));
%
%   See also IMROTATE, PADARRAY.
%   Contributed by Jan Motl (jan@motl.us)
%   $Revision: 1.2 $  $Date: 2014/05/01 12:08:01 $
% Parameter checking.
numvarargs = length(varargin);
if numvarargs > 1
    error('myfuns:somefun2Alt:TooManyInputs', ...
        'requires at most 1 optional input');
end
optargs = {'nearest'};    % Set defaults for optional inputs
optargs(1:numvarargs) = varargin;
[method] = optargs{:};    % Place optional args in memorable variable names
% Initialization.
[imageHeight, imageWidth, ~] = size(image);
centerX = floor(imageWidth/2+1);
centerY = floor(imageHeight/2+1);
dy = centerY-pointY;
dx = centerX-pointX;
% How much would the "rotate around" point shift if the
% image was rotated about the image center.
[theta, rho] = cart2pol(-dx,dy);
[newX, newY] = pol2cart(theta+angle*(pi/180), rho);
shiftX = round(pointX-(centerX+newX));
shiftY = round(pointY-(centerY-newY));
% Pad the image to preserve the whole image during the rotation.
padX = imageHeight;
padY = imageWidth;
padded = padarray(image, [padY padX],125);
% Rotate the image around the center.
rot = imrotate(padded, angle, method, 'crop');
% Crop the image.
output = rot(padY+1-shiftY:end-padY-shiftY, padX+1-shiftX:end-padX-shiftX, :);

end
