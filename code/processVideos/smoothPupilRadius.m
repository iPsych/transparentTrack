function [pupilData] = smoothPupilRadius(perimeterFileName, pupilFileName, sceneGeometryFileName, varargin)
% Empirical Bayes smoothing of pupil radius in the scene
%
% Description:
%   This routine implements a smoothing operation upon pupil radius using
%   an empirical Bayes approach. A non-causal, exponentially weighted
%   window of surrounding radius values serves as a prior. The posterior
%   value of the radius is then used as a constraint and the ellipse in the
%   image plane is re-fit.
%
% Notes:
%   Parallel pool - Controlled by the key/value pair 'useParallel'. The
%   routine should gracefully fall-back on serial processing if the
%   parallel pool is unavailable. Each worker requires ~8 GB of memory to
%   operate. It is important to keep total RAM usage below the physical
%   memory limit to prevent swapping and a dramatic slow down in
%   processing. To use the parallel pool with TbTb, provide the identity of
%   the repo name in the 'tbtbRepoName', which is then used to configure
%   the workers.
%
% Inputs:
%   perimeterFileName     - Full path to a .mat file that contains the
%                           perimeter data.
%   pupilFileName         - Full path to the .mat file that contains the
%                           pupil data to be smoothed. This file will be
%                           over-written by the output.
%   sceneGeometryFileName - Full path to the .mat file that contains the
%                           sceneGeometry to be used.
%
% Optional key/value pairs (display and I/O):
%  'verbosity'            - Level of verbosity. [none, full]
%
% Optional key/value pairs (flow control)
%  'nFrames'              - Analyze fewer than the total number of frames.
%  'useParallel'          - If set to true, use the Matlab parallel pool
%  'nWorkers'             - Specify the number of workers in the parallel
%                           pool. If undefined the default number will be
%                           used.
%  'tbtbProjectName'      - The workers in the parallel pool are configured
%                           by issuing a tbUseProject command for the
%                           project specified here.
%
% Optional key/value pairs (environment)
%  'tbSnapshot'           - This should contain the output of the
%                           tbDeploymentSnapshot performed upon the result
%                           of the tbUse command. This documents the state
%                           of the system at the time of analysis.
%  'timestamp'            - AUTOMATIC; The current time and date
%  'username'             - AUTOMATIC; The user
%  'hostname'             - AUTOMATIC; The host
%
% Optional key/value pairs (fitting)
%  'eyeParamsLB'          - Lower bound on the eyeParams
%  'eyeParamsUB'          - Upper bound on the eyeParams
%  'exponentialTauParam'  - The time constant (in video frames) of the
%                           decaying exponential weighting function for
%                           pupil radius.
%  'likelihoodErrorExponent' - The SD of the parameters estimated for each
%                           frame are raised to this exponent, to either to
%                           weaken (>1) or strengthen (<1) the influence of
%                           the current measure on the posterior.
%  'badFrameErrorThreshold' - Frames with RMSE fitting error above this
%                           threshold have their posterior values
%                           determined entirely by the prior. Additionally,
%                           these frames do not contribue to the prior.
%  'ellipseFitLabel'      - Identifies the field in pupilData that contains
%                           the ellipse fit params for which the search
%                           will be conducted.
%
% Outputs:
%   pupilData             - A structure with multiple fields corresponding
%                           to the parameters, SDs, and errors of the
%                           initial and final ellipse fits.
%

%% Parse vargin for options passed here
p = inputParser; p.KeepUnmatched = true;

% Required
p.addRequired('perimeterFileName',@ischar);
p.addRequired('pupilFileName',@ischar);
p.addRequired('sceneGeometryFileName',@ischar);

% Optional display and I/O params
p.addParameter('verbosity','none',@ischar);

% Optional flow control params
p.addParameter('nFrames',Inf,@isnumeric);
p.addParameter('useParallel',false,@islogical);
p.addParameter('nWorkers',[],@(x)(isempty(x) | isnumeric(x)));
p.addParameter('tbtbRepoName','transparentTrack',@ischar);

% Optional environment parameters
p.addParameter('tbSnapshot',[],@(x)(isempty(x) | isstruct(x)));
p.addParameter('timestamp',char(datetime('now')),@ischar);
p.addParameter('hostname',char(java.lang.System.getProperty('user.name')),@ischar);
p.addParameter('username',char(java.net.InetAddress.getLocalHost.getHostName),@ischar);

% Optional fitting params
p.addParameter('eyeParamsLB',[-35,-25,0.5],@isnumeric);
p.addParameter('eyeParamsUB',[35,25,4],@isnumeric);
p.addParameter('exponentialTauParam',3,@isnumeric);
p.addParameter('likelihoodErrorExponent',1.0,@isnumeric);
p.addParameter('badFrameErrorThreshold',2, @isnumeric);
p.addParameter('ellipseFitLabel','sceneConstrained',@ischar);

%% Parse and check the parameters
p.parse(perimeterFileName, pupilFileName, sceneGeometryFileName, varargin{:});

nEllipseParams=5; % 5 params in the transparent ellipse form
nEyeParams=3; % 3 values (azimuth, elevation, pupil radius) for eyeParams

% Load the pupil perimeter data. It will be a structure variable
% "perimeter", with the fields .data and .meta
dataLoad=load(perimeterFileName);
perimeter=dataLoad.perimeter;
clear dataLoad

% Load the pupil data. It will be a structure variable "pupilData"
dataLoad=load(pupilFileName);
pupilData=dataLoad.pupilData;
clear dataLoad

% load the sceneGeometry structure
dataLoad=load(p.Results.sceneGeometryFileName);
sceneGeometry=dataLoad.sceneGeometry;
clear dataLoad

% determine how many frames we will process
if p.Results.nFrames == Inf
    nFrames=size(perimeter.data,1);
else
    nFrames = p.Results.nFrames;
end

% Check that the needed fields in the pupilData structure are present
if ~isfield(pupilData,(p.Results.ellipseFitLabel))
    error('The requested fit field is not available in pupilData');
end
if ~isfield(pupilData.(p.Results.ellipseFitLabel).ellipse,'RMSE')
    error('This fit field does not have the required subfield: ellipse.RMSE');
end
if ~isfield(pupilData.(p.Results.ellipseFitLabel).eyeParams,'splitsSD')
    error('This fit field does not have the required subfield: eyeParams.splitsSD');
end


%% Set up the parallel pool
if p.Results.useParallel
    if strcmp(p.Results.verbosity,'full')
        tic
        fprintf(['Opening parallel pool. Started ' char(datetime('now')) '\n']);
    end
    if isempty(p.Results.nWorkers)
        parpool;
    else
        parpool(p.Results.nWorkers);
    end
    poolObj = gcp;
    if isempty(poolObj)
        nWorkers=0;
    else
        nWorkers = poolObj.NumWorkers;
        % Use TbTb to configure the workers.
        if ~isempty(p.Results.tbtbRepoName)
            spmd
                tbUse(p.Results.tbtbRepoName,'reset','full','verbose',false,'online',false);
            end
            if strcmp(p.Results.verbosity,'full')
                fprintf('CAUTION: Any TbTb messages from the workers will not be shown.\n');
            end
        end
    end
    if strcmp(p.Results.verbosity,'full')
        toc
        fprintf('\n');
    end
else
    nWorkers=0;
end

% Recast perimeter.data into a sliced cell array to reduce parfor
% broadcast overhead
frameCellArray = perimeter.data(1:nFrames);
clear perimeter

% Set-up other variables to be non-broadcast
verbosity = p.Results.verbosity;
likelihoodErrorExponent = p.Results.likelihoodErrorExponent;
eyeParamsLB = p.Results.eyeParamsLB;
eyeParamsUB = p.Results.eyeParamsUB;
badFrameErrorThreshold = p.Results.badFrameErrorThreshold;
ellipseFitLabel = p.Results.ellipseFitLabel;

%% Conduct empirical Bayes smoothing

% Set up the decaying exponential weighting function. The relatively large
% window (10 times the time constant) is used to handle the case in which
% there is a stretch of missing data, in which case the long tails of the
% exponential can provide the prior.
window=ceil(max([p.Results.exponentialTauParam*10,10]));
windowSupport=1:1:window;
baseExpFunc=exp(-1/p.Results.exponentialTauParam*windowSupport);

% The weighting function is symmetric about the current time point. The
% current time point is excluded (set to nan)
exponentialWeights=[fliplr(baseExpFunc) NaN baseExpFunc];

% Alert the user
if strcmp(p.Results.verbosity,'full')
    tic
    fprintf(['Bayesian smoothing. Started ' char(datetime('now')) '\n']);
    fprintf('| 0                      50                   100%% |\n');
    fprintf('.\n');
end

% Loop through the frames
parfor (ii = 1:nFrames, nWorkers)
    
    % update progress
    if strcmp(verbosity,'full')
        if mod(ii,round(nFrames/50))==0
            fprintf('\b.\n');
        end
    end
    
    % initialize some variables so that their use is transparent to the
    % parfor loop
    posteriorEllipseParams = NaN(1,nEllipseParams);
    posteriorEyeParamsObjectiveError = NaN;
    posteriorEyeParams = NaN(1,nEyeParams);
    posteriorPupilRadiusSD = NaN;
    
    % get the boundary points
    Xp = frameCellArray{ii}.Xp;
    Yp = frameCellArray{ii}.Yp;
    
    % if this frame has data, and eyeParam radius is not nan, then proceed
    % to calculate the posterior
    if ~isempty(Xp) &&  ~isempty(Yp) && ~isnan(pupilData.(ellipseFitLabel).eyeParams.values(ii,3))
        % Calculate the pupil radius prior. The prior mean is given by the
        % surrounding radius values, weighted by a decaying exponential in
        % time and the inverse of the standard deviation of each measure.
        % The prior standard deviation is weighted only by time.
        
        % A bit of fussing with the range here to handle the start and the
        % end of the data vector
        rangeLowSignal=max([ii-window,1]);
        rangeHiSignal=min([ii+window,nFrames]);
        restrictLowWindow= max([(ii-window-1)*-1,0]);
        restrictHiWindow = max([(nFrames-ii-window)*-1,0]);
        
        % Get the dataVector, restricted to the window range
        dataVector=squeeze(pupilData.(ellipseFitLabel).eyeParams.values(rangeLowSignal:rangeHiSignal,3))';
        
        % Build the precisionVector as the inverse of the measurement SD on
        % each frame, scaled to range within the window from zero to unity.
        % Thus, the noisiest measurement will not influence the prior.
        precisionVector = squeeze(pupilData.(ellipseFitLabel).eyeParams.splitsSD(:,3))';
        precisionVector = precisionVector+realmin;
        precisionVector=precisionVector.^(-1);
        precisionVector=precisionVector(rangeLowSignal:rangeHiSignal);
        precisionVector=precisionVector-nanmin(precisionVector);
        precisionVector=precisionVector/nanmax(precisionVector);
        
        % Identify any time points within the window for which the fit RMSE
        % was greater than threshold, and therefore should not contribute
        % to the prior. We detect the edge case in which every frame in the
        % window is "bad", in which case we retain them all.
        rmseVector = pupilData.(ellipseFitLabel).ellipse.RMSE(rangeLowSignal:rangeHiSignal)';
        badFrameIdx = rmseVector > badFrameErrorThreshold;
        if sum(badFrameIdx) > 0 && sum(badFrameIdx) < length(badFrameIdx)
            precisionVector(badFrameIdx)=0;
        end
        
        % The temporal weight vector is simply the exponential weights,
        % restricted to the available data widow
        temporalWeightVector = ...
            exponentialWeights(1+restrictLowWindow:end-restrictHiWindow);
        
        % Combine the precision and time weights, and calculate the
        % prior mean
        combinedWeightVector=precisionVector.*temporalWeightVector;
        priorPupilRadius = nansum(dataVector.*combinedWeightVector,2)./ ...
            nansum(combinedWeightVector(~isnan(dataVector)),2);
        
        % Obtain the standard deviation of the prior
        priorPupilRadiusSD = nanstd(dataVector,temporalWeightVector);
        
        % Retrieve the initialFit for this frame
        likelihoodPupilRadiusMean = pupilData.(ellipseFitLabel).eyeParams.values(ii,3);
        likelihoodPupilRadiusSD = pupilData.(ellipseFitLabel).eyeParams.splitsSD(ii,3);
        
        % Raise the estimate of the SD from the initial fit to an
        % exponent. This is used to adjust the relative weighting of
        % the current frame realtive to the prior
        likelihoodPupilRadiusSD = likelihoodPupilRadiusSD .^ likelihoodErrorExponent;
        
        % Check if the RMSE for the likelihood fit was above the bad
        % threshold. If so, inflate the SD for the likelihood so that the
        % prior dictates the value of the posterior
        if pupilData.(ellipseFitLabel).ellipse.RMSE(ii) > badFrameErrorThreshold
            likelihoodPupilRadiusSD = likelihoodPupilRadiusSD .* 1e20;
        end
        
        % Calculate the posterior values for the pupil fits, given the
        % likelihood and the prior
        posteriorPupilRadius = priorPupilRadiusSD.^2.*likelihoodPupilRadiusMean./(priorPupilRadiusSD.^2+likelihoodPupilRadiusSD.^2) + ...
            likelihoodPupilRadiusSD.^2.*priorPupilRadius./(priorPupilRadiusSD.^2+likelihoodPupilRadiusSD.^2);
        
        % Calculate the SD of the posterior of the pupil radius
        posteriorPupilRadiusSD = sqrt((priorPupilRadiusSD.^2.*likelihoodPupilRadiusSD.^2) ./ ...
            (priorPupilRadiusSD.^2+likelihoodPupilRadiusSD.^2));
        
        % Re-fit the ellipse with the radius constrained to the posterior
        % value. Pass the prior azimuth and elevation as x0.
        lb_pin = eyeParamsLB;
        ub_pin = eyeParamsUB;
        lb_pin(3)=posteriorPupilRadius;
        ub_pin(3)=posteriorPupilRadius;
        x0 = pupilData.(ellipseFitLabel).eyeParams.values(ii,:);
        x0(3)=posteriorPupilRadius;
        [posteriorEyeParams, posteriorEyeParamsObjectiveError] = ...
            eyeParamEllipseFit(Xp, Yp, sceneGeometry, 'eyeParamsLB', lb_pin, 'eyeParamsUB', ub_pin, 'x0', x0 );
        posteriorEllipseParams = pupilProjection_fwd(posteriorEyeParams, sceneGeometry);
        
    end % check if there are any perimeter points to fit
    
    % store results
    loopVar_posteriorEllipseParams(ii,:) = posteriorEllipseParams';
    loopVar_posteriorEyeParamsObjectiveError(ii) = posteriorEyeParamsObjectiveError;
    loopVar_posteriorEyeParams(ii,:) = posteriorEyeParams;
    loopVar_posteriorPupilRadiusSD(ii) = posteriorPupilRadiusSD;
    
end % loop over frames to calculate the posterior

% report completion of Bayesian analysis
if strcmp(p.Results.verbosity,'full')
    toc
    fprintf('\n');
end

%% Clean up and save the fit results

% gather the loop vars into the ellipse structure
pupilData.radiusSmoothed.ellipse.values=loopVar_posteriorEllipseParams;
pupilData.radiusSmoothed.ellipse.RMSE=loopVar_posteriorEyeParamsObjectiveError';
pupilData.radiusSmoothed.ellipse.meta.ellipseForm = 'transparent';
pupilData.radiusSmoothed.ellipse.meta.labels = {'x','y','area','eccentricity','theta'};
pupilData.radiusSmoothed.ellipse.meta.units = {'pixels','pixels','squared pixels','non-linear eccentricity','rads'};
pupilData.radiusSmoothed.ellipse.meta.coordinateSystem = 'intrinsic image';

pupilData.radiusSmoothed.eyeParams.values=loopVar_posteriorEyeParams;
pupilData.radiusSmoothed.eyeParams.radiusSD=loopVar_posteriorPupilRadiusSD';
pupilData.radiusSmoothed.eyeParams.meta.labels = {'azimuth','elevation','pupil radius'};
pupilData.radiusSmoothed.eyeParams.meta.units = {'deg','deg','mm'};
pupilData.radiusSmoothed.eyeParams.meta.coordinateSystem = 'head fixed (extrinsic)';

% add a meta field with analysis details
pupilData.radiusSmoothed.meta.smoothPupilArea = p.Results;

% save the pupilData
save(p.Results.pupilFileName,'pupilData')


%% Delete the parallel pool
if p.Results.useParallel
    if strcmp(p.Results.verbosity,'full')
        tic
        fprintf(['Closing parallel pool. Started ' char(datetime('now')) '\n']);
    end
    poolObj = gcp;
    if ~isempty(poolObj)
        delete(poolObj);
    end
    if strcmp(p.Results.verbosity,'full')
        toc
        fprintf('\n');
    end
end


end % function
