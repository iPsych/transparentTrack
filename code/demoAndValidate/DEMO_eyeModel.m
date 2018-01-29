% DEMO_eyeModel
%
% Demonstrate the forward model of the eye

clear all

%% set paths and make directories
% create test sandbox on desktop
sandboxDir = '~/Desktop/eyeModelDEMO';
if ~exist(sandboxDir,'dir')
    mkdir(sandboxDir)
end
acquisitionName = 'eyeModelDemo';

pupilFileName = fullfile(sandboxDir,[acquisitionName '_pupil.mat']);
sceneGeometryFileName = fullfile(sandboxDir,[acquisitionName '_sceneGeometry.mat']);
videoOutFileName = fullfile(sandboxDir,[acquisitionName '_eyeModel.avi']);

% define full paths for input and output
pathParams.dataSourceDirFull = fullfile(sandboxDir);
pathParams.dataOutputDirFull = fullfile(sandboxDir);


%% Create a pupilData file with simulated eye positions

idx = 1;
thisTorsion = 0;
azimuthFlip=1;
elevationFlip=1;
for thisPupilRadius = 1:0.5:3
    for thisElevation = -25:5:25
        for thisAzimuth = -35:5:35
            eyeParams=[thisAzimuth*azimuthFlip,thisElevation*elevationFlip,thisTorsion,thisPupilRadius];
            pupilData.radiusSmoothed.eyeParams.values(idx,:)= eyeParams;
            idx = idx+1;
        end
        azimuthFlip = azimuthFlip*-1;
    end
    elevationFlip = elevationFlip*-1;
end
save(pupilFileName,'pupilData')


%% Create and save the default sceneGeometry file
sceneGeometry = estimateSceneGeometry('','');
save(sceneGeometryFileName,'sceneGeometry')

%% Create the eyeModel video
makeEyeModelVideo(videoOutFileName,pupilFileName, sceneGeometryFileName, 'verbosity','full')
