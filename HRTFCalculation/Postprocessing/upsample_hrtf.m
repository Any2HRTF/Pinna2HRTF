function result = upsample_hrtf(inputFile, outputDir, varargin)
% Single-file local runner for original ExpSuite LocaDyn processing.
% Usage: addpath('/Users/felixperfler/Documents/EvaPPM/Scripts/_support'); upsample_hrtf
% Or: result=upsample_hrtf('/path/input.sofa','/path/output');
% All LocaDyn helpers are local functions below; AMT/SOFA remain dependencies.
% Original normalization and Data.Delay behavior are preserved.
% Source: https://sourceforge.net/p/expsuite/code/1948/tree/LocaDyn/MATLAB/
% Downloaded 2026-10-07. Helper function names/end delimiters adapted for one file.
% ExpSuite code and local wrapper: EUPL 1.2. TriQuad retains its BSD notice below.
% Verified 2026-10-07: exact IR, position, sampling-rate and delay equality to
% the prior original-code runner for both Piotr conditions (all four outputs).
% Historical Piotr outputs retain documented small nonzero numerical differences.
%UPSAMPLE_HRTF Spatially densify a SOFA HRTF with the LocaDyn method.
%   upsample_hrtf opens a SOFA file picker and writes beside the input.
%   result = upsample_hrtf(inputFile, outputDir, 'Ndivide', 3)
%   Options: Ndivide (0..5; default 3), TOAremoval (1,2; default 2),
%   Normalize (default true: original LocaDyn normalization), Plot (false),
%   SymmetricReceivers (true: renderer-compatible receiver metadata),
%   AMTPath (local AMT installation), Overwrite (false), DenseOnly (false).
%   Compatible Pinna2HRTF GeneralFIR exports are converted without changing IRs.
%   Sampling rate and IR length are preserved. This is spatial interpolation.
%   Original ExpSuite/LocaDyn revision 1948 processing; helpers included below.

if nargin < 1 || isempty(inputFile)
    [name, folder] = uigetfile('*.sofa', 'Choose the HRTFs to upsample');
    if isequal(name, 0), result = []; return; end
    inputFile = fullfile(folder, name);
end
inputFile = char(inputFile);
if ~isfile(inputFile), error('HRTFUpsampling:Input', 'File not found: %s', inputFile); end
[ok, attr] = fileattrib(inputFile);
if ok, inputFile = attr.Name; end
if nargin < 2 || isempty(outputDir)
    [folder, name] = fileparts(inputFile);
    outputDir = fullfile(folder, [name '_upsampled']);
end
outputDir = char(outputDir);
p = inputParser;
addParameter(p, 'Ndivide', 3, @(x) isnumeric(x) && isscalar(x) && ismember(x,0:5));
addParameter(p, 'TOAremoval', 2, @(x) isnumeric(x) && isscalar(x) && ismember(x,1:2));
addParameter(p, 'Normalize', true, @(x) islogical(x) && isscalar(x));
addParameter(p, 'Plot', false, @(x) islogical(x) && isscalar(x));
addParameter(p, 'Overwrite', false, @(x) islogical(x) && isscalar(x));
addParameter(p, 'SymmetricReceivers', true, @(x) islogical(x) && isscalar(x));
addParameter(p, 'DenseOnly', false, @(x) islogical(x) && isscalar(x));
addParameter(p, 'AMTPath', fullfile(getenv('HOME'),'Documents','Uni','MATLAB','amtoolbox'), @(x) ischar(x) || isstring(x));
parse(p, varargin{:}); opt = p.Results;

required = {'SOFAload','SOFAsave','SOFAupdateDimensions','SOFAaddVariable', ...
    'SOFAremoveVariable','ziegelwanger2014_onaxis','ziegelwanger2014_offaxis', ...
    'ltfatarghelper','deleteoutliers','hilbert','xcorr','lsqcurvefit','tinv'};
if any(cellfun(@(f) isempty(which(f)), required))
    if ~isfile(fullfile(opt.AMTPath,'amt_start.m'))
        error('HRTFUpsampling:AMT', 'AMT was not found. Supply ''AMTPath'', ''/path/to/amtoolbox''.');
    end
    oldFolder = pwd; restoreFolder = onCleanup(@() cd(oldFolder));
    addpath(char(opt.AMTPath)); amt_start('silent');
    clear restoreFolder
end
for k = 1:numel(required)
    if isempty(which(required{k}))
        error('HRTFUpsampling:Dependency', 'Missing dependency: %s. Check AMT and MATLAB Signal Processing, Optimization and Statistics toolboxes.', required{k});
    end
end

X = SOFAload(inputFile);
if strcmp(X.GLOBAL_SOFAConventions, 'GeneralFIR')
    X = experiment_general_fir(X);
end
originalReceivers = X.ReceiverPosition;
outputReceivers = originalReceivers;
if opt.SymmetricReceivers
    if ~strcmpi(X.ReceiverPosition_Type,'cartesian') || ...
            ~any(strcmpi(strtrim(X.ReceiverPosition_Units), {'meter','metre'})) || ...
            size(originalReceivers,1)~=2 || size(originalReceivers,2)~=3 || ...
            numel(originalReceivers)~=6 || any(~isfinite(originalReceivers(:))) || ...
            originalReceivers(1,2)<=0 || originalReceivers(2,2)>=0
        error('HRTFUpsampling:Receivers', ...
            'Expected fixed left/right Cartesian receivers in metres, with left +y and right -y.');
    end
    % Same metadata-only approximation as the Piotr SOFAlizer copy.
    distance = mean(abs(originalReceivers(:,2)));
    outputReceivers = zeros(size(originalReceivers),'like',originalReceivers);
    outputReceivers(1,2) = distance;
    outputReceivers(2,2) = -distance;
end
if ~strcmp(X.GLOBAL_SOFAConventions, 'SimpleFreeFieldHRIR')
    error('HRTFUpsampling:Convention', 'Input must use the SimpleFreeFieldHRIR convention.');
end
if ~strcmpi(X.SourcePosition_Type,'spherical') || ...
        ~contains(lower(X.SourcePosition_Units),'degree') || ...
        ~(contains(lower(X.SourcePosition_Units),'metre') || contains(lower(X.SourcePosition_Units),'meter'))
    error('HRTFUpsampling:Coordinates', 'SourcePosition must be spherical, in degrees and metres.');
end
if size(X.Data.IR,2) ~= 2 || size(X.Data.IR,3)<8 || size(X.Data.IR,3)>16384
    error('HRTFUpsampling:Shape', 'Expected two receivers and 8..16384 IR samples.');
end
if ~isscalar(X.Data.SamplingRate) || ~isfinite(X.Data.SamplingRate) || X.Data.SamplingRate<=0
    error('HRTFUpsampling:SamplingRate','Expected a positive, fixed sampling rate.');
end
if any(~isfinite(X.Data.IR(:))) || any(~isfinite(X.SourcePosition(:)))
    error('HRTFUpsampling:Nonfinite','Input contains nonfinite values.');
end
if any(X.Data.Delay(:) ~= 0)
    error('HRTFUpsampling:Delay', 'Input has external Data.Delay. Embed those sample delays in the IRs before using this method.');
end
radius = X.SourcePosition(:,3);
if any(radius<=0) || max(radius)-min(radius)>1e-6*mean(radius)
    error('HRTFUpsampling:Radius','LocaDyn requires a single positive source radius.');
end
[a,b,c] = sph2cart(deg2rad(X.SourcePosition(:,1)),deg2rad(X.SourcePosition(:,2)),ones(size(radius)));
xyz = [a,b,c];
if size(unique(round(xyz,10),'rows'),1) ~= size(xyz,1)
    error('HRTFUpsampling:Duplicates','Input contains duplicate spatial directions.');
end
if size(xyz,1)<8 || rank(xyz-mean(xyz))<3
    error('HRTFUpsampling:Coverage','Input needs at least eight directions with 3-D coverage.');
end
if any(reshape(sum(X.Data.IR.^2,3),[],1)==0)
    error('HRTFUpsampling:SilentInput','Input contains a silent IR, which cannot be used to fit the TOA model.');
end

% Per-measurement acquisition variables have no meaning at new directions.
for name = {'MeasurementSourceAudioChannel','MeasurementAudioLatency'}
    if isfield(X,name{1}), X = SOFAremoveVariable(X,name{1}); end
end
if isfield(X,'GLOBAL__NCProperties'), X = rmfield(X,'GLOBAL__NCProperties'); end
gain = 1;
if opt.Normalize
    front = find(X.SourcePosition(:,1)==0 & X.SourcePosition(:,2)==0);
    if numel(front)~=1
        error('HRTFUpsampling:Front','Normalization requires one frontal (0,0) direction; use ''Normalize'',false to preserve level.');
    end
    % Keep the exact original expression and operation order.
    Eold = mean(rms(squeeze(X.Data.IR(front,:,:))));
    gain = 10^(-40/20)/Eold;
    X.Data.IR = X.Data.IR/Eold*(10^(-40/20));
end

names = {'hrtf_Nd=0.sofa', 'hrtf_Nd=0_TA.sofa', ...
    sprintf('hrtf_Nd=%d_TA.sofa',opt.Ndivide), sprintf('hrtf_Nd=%d.sofa',opt.Ndivide)};
if opt.Ndivide==0
    names{3}='hrtf_Nd=0_dense_TA.sofa'; names{4}='hrtf_Nd=0_dense.sofa';
end
names = [names, {'upsampling_report.mat','upsampling_report.txt'}];
for k = 1:numel(names)
    target = fullfile(outputDir,names{k});
    if strcmp(target,inputFile) || (~opt.Overwrite && isfile(target))
        error('HRTFUpsampling:Exists','Refusing to overwrite %s. Choose another output folder.',target);
    end
end
fprintf('LocaDyn spatial interpolation: %d input directions, %d subdivisions.\n',size(X.Data.IR,1),opt.Ndivide);
[sets, toaCheck] = local_locadyn_interpolate(X,opt.Ndivide,opt.TOAremoval,opt.Plot);
for k = 1:numel(sets)
    if any(~isfinite(sets(k).Data.IR(:))) || any(~isfinite(sets(k).Data.Delay(:)))
        error('HRTFUpsampling:Output','Interpolation produced nonfinite data. No output was saved.');
    end
    if sets(k).Data.SamplingRate ~= X.Data.SamplingRate || size(sets(k).Data.IR,3)~=size(X.Data.IR,3)
        error('HRTFUpsampling:Output','Sampling rate or IR length changed unexpectedly.');
    end
end
if ~isfolder(outputDir), mkdir(outputDir); end
allSets = [X,sets];
saveIndices = 1:4;
if opt.DenseOnly, saveIndices = 4; end
for k = saveIndices
    % Apply after the original scientific processing; never alter its inputs.
    allSets(k).ReceiverPosition = outputReceivers;
    target = fullfile(outputDir,names{k});
    SOFAsave(target,allSets(k));
    saved = SOFAload(target);
    if ~isequal(size(saved.Data.IR),size(allSets(k).Data.IR)) || ...
            any(~isfinite(saved.Data.IR(:))) || ...
            ~isequal(saved.Data.IR,allSets(k).Data.IR) || ...
            ~isequal(saved.SourcePosition,allSets(k).SourcePosition) || ...
            ~isequal(saved.Data.Delay,allSets(k).Data.Delay) || ...
            ~isequal(saved.Data.SamplingRate,allSets(k).Data.SamplingRate) || ...
            ~isequal(saved.ReceiverPosition,outputReceivers)
        error('HRTFUpsampling:RoundTrip','Saved output did not match: %s',target);
    end
end
result = struct('inputFile',inputFile,'outputDir',outputDir,'options',opt, ...
    'normalizationGain',gain,'inputDirections',size(X.Data.IR,1), ...
    'outputDirections',size(sets(3).Data.IR,1),'samplingRate',X.Data.SamplingRate, ...
    'irSamples',size(X.Data.IR,3),'toaCheck',toaCheck,'upstreamRevision',1948, ...
    'originalReceiverPosition',originalReceivers,'outputReceiverPosition',outputReceivers, ...
    'receiverMetadataChanged',~isequal(originalReceivers,outputReceivers), ...
    'files',{cellfun(@(n) fullfile(outputDir,n),names(saveIndices),'UniformOutput',false)});
save(fullfile(outputDir,names{5}),'result');
fid = fopen(fullfile(outputDir,names{6}),'w');
if fid<0, error('HRTFUpsampling:Report','Could not write the text report.'); end
closeReport = onCleanup(@() fclose(fid));
fprintf(fid,'Source: %s\nDirections: %d -> %d\nSampling rate: %g Hz\nIR length: %d\nSubdivisions: %d\nTOAremoval: %d\nNormalization gain: %.17g\n\n%s\n', ...
    inputFile,result.inputDirections,result.outputDirections,result.samplingRate,result.irSamples,opt.Ndivide,opt.TOAremoval,gain,toaCheck);
fprintf(fid,'Symmetric receiver metadata: %d\nReceiver metadata changed: %d\nOriginal ReceiverPosition (m):\n%s\nOutput ReceiverPosition (m):\n%s\n', ...
    opt.SymmetricReceivers,result.receiverMetadataChanged,mat2str(originalReceivers,17),mat2str(outputReceivers,17));
fprintf('Saved and verified %d directions in:\n%s\n',result.outputDirections,outputDir);
end


% ========================================================================
function [Xreturn, TOAcheck] = local_locadyn_interpolate(X,Ndivide,TOAremoval,fig,dirs)
% function Xrec = LocaDyn_InterpolateHRTFs(X,Ndivide,TOAremoval,fig)
%
%  Post process input HRTF by interpolating to a denser grid and creating a
%  copy with smoothed spectral content. 
%  TOA estimation % Based on TOA Model (Ziegelwanger and Majdak, 2014)
%
%  input:	X: reference SOFA object
%           Ndivide: number of times to interpolate to smaller face
%           TOAremoval: 0 .. no removal; 1: .. circshift; 2: .. minimum phase
%           fig: plot figures (true/false)
%
%  output:	Xreturn: Four sofa objects:
%                       1) time-aligned original set with added silent pole, 
%                       2) time-aligned dense grid, 
%                       3) time reconstructed dense grid, 
%                       4) frozen spectrum dense grid
%
%  #Author: Piotr Majdak (01.2022), edited by Glen McLachlan (04.2023)

% ExpSuite - software framework for applications to perform experiments (related but not limited to psychoacoustics).
% Copyright (C) 2003-2022 Acoustics Research Institute - Austrian Academy of Sciences; Piotr Majdak and Michael Mihocic
% Licensed under the EUPL, Version 1.2 or � as soon they will be approved by the European Commission - subsequent versions of the EUPL (the "Licence")
% You may not use this work except in compliance with the Licence. 
% You may obtain a copy of the Licence at: https://joinup.ec.europa.eu/software/page/eupl
% Unless required by applicable law or agreed to in writing, software distributed under the Licence is distributed on an "AS IS" basis, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
% See the Licence for the specific language governing  permissions and limitations under the Licence. 


 if ~exist('fig','var')
     % third parameter does not exist, so default it to something
      fig=false;
 end
fs=X.Data.SamplingRate; 

%% Plot Original HRTFs
if fig
  figure('Position',[ 73       386.14       1164.6       333.71]);
  subplot(1,2,1); 
  SOFAplotHRTF(X,'etchorizontal',1);
  title('Original HRIRs, left');
  subplot(1,2,2); 
  SOFAplotHRTF(X,'etchorizontal',2);
  title('Original HRIRs, right');

  figure('Position',[ 73       386.14       1164.6       333.71]);
  subplot(1,2,1); 
  SOFAplotHRTF(X,'magmedian',1); ylim([-90 270]);
  title('Original HRIRs, left');
  subplot(1,2,2); 
  SOFAplotHRTF(X,'magmedian',2); ylim([-90 270]);
  title('Original HRIRs, right');
end


%% Fit the TOA model

% [~,res]=LocaDyn_ziegelwanger2014_adapt(X,4,1,1);
[~,res]=LocaDyn_ziegelwanger2014_adapt(X,4,1,1); % use thr method on lp-filtered IRs, AMT 1.1.1
p=res.p_offaxis(:,1);
leftEar = sprintf(' Left: r=%0.3g cm; M=[%5.3g, %5.3g, %5.3g] cm; tau=%5.3g ms; phi=%5.3g�; theta=%5.3g�\n', ...
   p(1)*100, p(2)*100, p(3)*100, p(4)*100, p(5)*1000, rad2deg(p(6)), rad2deg(p(7)));
p=res.p_offaxis(:,2);
rightEar = sprintf(' Left: r=%0.3g cm; M=[%5.3g, %5.3g, %5.3g] cm; tau=%5.3g ms; phi=%5.3g�; theta=%5.3g�\n', ...
   p(1)*100, p(2)*100, p(3)*100, p(4)*100, p(5)*1000, rad2deg(p(6)), rad2deg(p(7)));

TOAcheck = ['TOA model sanity check:' 10 leftEar rightEar];
disp(TOAcheck);

X = SOFAaddVariable(X,'TOAModel','NR',[res.p_offaxis; zeros(X.API.N-size(res.p_offaxis,1),X.API.R)]);

%% remove the TOA: Xnd
switch TOAremoval, 
  case 0 % No removal
    Xnd=X;
  case 1 % Circular shift
    Xnd=X;
    toa=zeros(X.API.M, X.API.R); 
    for r=1:X.API.R
      toa(:,r)=ziegelwanger2014_offaxis(res.p_offaxis(:,r),[deg2rad(X.SourcePosition(:,1)) deg2rad(X.SourcePosition(:,2)) deg2rad(X.SourcePosition(:,3))]);
      for ii=1:X.API.M
        Xnd.Data.IR(ii,r,:)=circshift(squeeze(X.Data.IR(ii,r,:)),round((-toa(ii,r)+res.p_offaxis(5,r))*fs)); % res.p_offaxis(5,r) == tau
      end
    end
  case 2 % Minimum-phase
    Xnd=X;
    Xnd.Data.IR=shiftdim(LocaDyn_MinimalPhase(shiftdim(Xnd.Data.IR,2)),1);
    toa=zeros(X.API.M, X.API.R); 
    for r=1:X.API.R
      toa(:,r)=ziegelwanger2014_offaxis(res.p_offaxis(:,r),[deg2rad(X.SourcePosition(:,1)) deg2rad(X.SourcePosition(:,2)) deg2rad(X.SourcePosition(:,3))]);
      for ii=1:X.API.M
        Xnd.Data.IR(ii,r,:)=circshift(squeeze(Xnd.Data.IR(ii,r,:)),round((res.p_offaxis(5,r))*fs)); % res.p_offaxis(5,r) == tau
      end
    end
  otherwise
    disp('Selected TOAremoval does not exist');
    return
end
Xnd=SOFAupdateDimensions(Xnd);

if fig
  figure('Position',[ 73       386.14       1164.6       333.71]);
  subplot(1,2,1); 
  SOFAplotHRTF(Xnd,'etchorizontal',1);
  title('No-Delay HRIRs, left');
  subplot(1,2,2); 
  SOFAplotHRTF(Xnd,'etchorizontal',2);
  title('No-Delay HRIRs, right');
end

%% Add a silent pole at the bottom
Xsp=Xnd; 
Xsp.Data.IR(end+1,:,:)=zeros(1,X.API.R,X.API.N);
Xsp.SourcePosition(end+1,:)=[0,-90,Xsp.SourcePosition(1,3)];
Xsp.API.M=X.API.M+1;
Xsp.Data.Delay=[toa;0,0];
Xsp=SOFAupdateDimensions(Xsp);

%% Subdivide the grid: Xsp --> Xnew
[Pnew, ~, P, T] = LocaDyn_Subdivide(Xsp, Ndivide);
Xnew=Xsp;
Xnew.Data.IR=zeros(length(Pnew),Xsp.API.R,Xsp.API.N); 
[a,e,r]=cart2sph(Pnew(:,1),Pnew(:,2),Pnew(:,3));
Xnew.SourcePosition=[mod(rad2deg(a)+360,360), rad2deg(e), r];
MInspect=NaN; % stop at MInspect measurement for inspection
tic
for ii=1:length(Pnew)  
  [g,Tidx] = VBAPgain(Pnew(ii,:), P, T);
  if isnan(g), error('face for VBAPing not found'); end
  for r=1:Xsp.API.R
    A=squeeze(Xsp.Data.IR(T(Tidx,:),r,:))'; % A: three IRs from the face around the new position
    Xnew.Data.IR(ii,r,:)=A*g'; % matrix-vector product
  end
  if mod(ii,500)==0, disp([num2str(ii) '/' num2str(length(Pnew))]); end
  if ii==MInspect
    S1=Xsp.SourcePosition(T(Tidx,1),:);
    S2=Xsp.SourcePosition(T(Tidx,2),:);
    S3=Xsp.SourcePosition(T(Tidx,3),:);
    disp(S1); disp(S2); disp(S3); 
    disp(Xnew.SourcePosition(ii,:)); 
    disp('---'); 
    figure(1);
    plot(A); hold on;
    plot(squeeze(Xnew.Data.IR(ii,r,:)),'R');
    legend({['Gain: ' num2str(g(1))], ...
            ['Gain: ' num2str(g(2))], ...
            ['Gain: ' num2str(g(3))], ...
            'New'});
    title(['#' num2str(ii) ' of ' num2str(length(Pnew))]);
    waitforbuttonpress;
    close(1);
  end
end
toc
Xnew.Data.Delay=zeros(1,Xsp.API.R);
Xnew=SOFAupdateDimensions(Xnew);

if fig
  figure('Position',[ 73       386.14       1164.6       333.71]);
  subplot(1,2,1); 
  SOFAplotHRTF(Xnew,'etchorizontal',1);
  title('Subdivided HRIRs, left');
  subplot(1,2,2); 
  SOFAplotHRTF(Xnew,'etchorizontal',2);
  title('Subdivided HRIRs, right');
end

%% reconstruct the TOA in the HRIRs

Xrec=Xnew;
if TOAremoval,
  toa=zeros(Xrec.API.M, Xrec.API.R); 
  for r=1:X.API.R
    toa(:,r)=ziegelwanger2014_offaxis(Xrec.TOAModel(:,r), [deg2rad(Xrec.SourcePosition(:,1)) deg2rad(Xrec.SourcePosition(:,2)) Xrec.SourcePosition(:,3)]);
    for ii=1:Xrec.API.M
      Xrec.Data.IR(ii,r,:)=circshift(squeeze(Xrec.Data.IR(ii,r,:)),round(-(-toa(ii,r)+Xrec.TOAModel(5,r))*fs));
    end
  end
end
Xrec.Data.Delay=toa;
Xnew.Data.Delay=toa;
Xsp=SOFAremoveVariable(Xsp,'TOAModel');
Xnew=SOFAremoveVariable(Xnew,'TOAModel');
Xrec=SOFAremoveVariable(Xrec,'TOAModel');
Xsp=SOFAupdateDimensions(Xsp);
Xnew=SOFAupdateDimensions(Xnew);
Xrec=SOFAupdateDimensions(Xrec);

Xreturn =[Xsp, Xnew, Xrec]; %TA silent pole, TA dense, reconstructed dense

if fig
  figure('Position',[ 73       386.14       1164.6       333.71]);
  subplot(1,2,1); 
  SOFAplotHRTF(Xrec,'etchorizontal',1);
  title('Reconstructed HRIRs, left');
  subplot(1,2,2); 
  SOFAplotHRTF(Xrec,'etchorizontal',2);
  title('Reconstructed HRIRs, right');

  figure('Position',[ 73       386.14       1164.6       333.71]);
  subplot(1,2,1); 
  SOFAplotHRTF(Xrec,'magmedian',1); ylim([-90 270]);
  title('Reconstructed HRIRs, left');
  subplot(1,2,2); 
  SOFAplotHRTF(Xrec,'magmedian',2); ylim([-90 270]);
  title('Reconstructed HRIRs, right');
end

  %% make spectral cues & ILD static
%   Xstat = LocaDyn_StaticSpectrum(Xnew,dirs,toa);
%   Xreturn =[Xsp, Xrec, Xnew, Xstat]; %TA silent pole, TA dense, reconstructed dense, frozen spectrum
% 
%   if fig
%       figure('Position',[ 73       386.14       1164.6       333.71]);
%       subplot(1,2,1); 
%       SOFAplotHRTF(Xstat(1),'etchorizontal',1);
%       title('Reconstructed HRIRs (stat_spec), left');
%       subplot(1,2,2); 
%       SOFAplotHRTF(Xstat(1),'etchorizontal',2);
%       title('Reconstructed HRIRs (stat_spec), right');
% 
%       figure('Position',[ 73       386.14       1164.6       333.71]);
%       subplot(1,2,1); 
%       SOFAplotHRTF(Xstat,'magmedian',1); ylim([-90 270]);
%       title('Reconstructed HRIRs, left');
%       subplot(1,2,2); 
%       SOFAplotHRTF(Xstat,'magmedian',2); ylim([-90 270]);
%       title('Reconstructed HRIRs, right');
%   end

end


% ========================================================================
function [Obj,results]=LocaDyn_ziegelwanger2014_adapt(Obj,varargin)
%ZIEGELWANGER2014 Time of arrival estimates
%   Usage: [Obj,results]=ziegelwanger2014(data,estimation,outlierDetection,model,p0_onaxis) 
%
%   Estimates the Time-of-Arrival for each measurement in Obj (SOFA) and
%   corrects the results with a geometrical model of the head.
%
%   Input parameters:
%
%      Obj: SOFA object
%
%      estimation: (optional) TOA estimation method:
%
%                   [TOAest]:	pre-estimated TOAs
%                   1: 			Built-in maximum detection
%                   2: 			Built-in centroid of squared IR,
%                   3: 			Built-in mean group delay,
%                   4: 			Built-in maximum of the minimum-phase cross-correlation (default)
%                   5:      Built-in maxium detection after 3k-low-pass filtering (similar to Andreopoulou and Katz, 2017)
%                   String:	(Experimental) Estimator from the 'itdestimator' function, requires further parameters
%
%      outlierDetection: (optional) detect outliers in estimated TOAs
%
%                   0:	off
%                   1:	on (default values: [0.05;0.01])
%                   [alpha r]: reject outliers using the extreme Studentized deviance test with 
%                   the significance level of ALPHA and upper bound of outlier rate R
%
%      model: (optional) correct estimated toa, using geometrical TOA-Model
%
%                    0: no model, just estimate the TOAs
%                    1: (default) off-axis TOA modeled
%                    2: on-axis TOA modeled
%
%      p0_onaxis: (optional) startvalues for lsqcurvefit
%
%      lowpass:   (optional) bandwidth setting when used with the estimator from 'itdestimator' ('lp' for lowpass, 'bb' for broadband)
%
%      upper_cutfreq: (optional) lowpass cutoff (Hz) when used with the estimator from 'itdestimator'
%
%      threshlvl: (optional) threshold level (dB) when used with the 'Threshold' estimator from 'itdestimator'
%   
%   Output parameters:
%
%      Obj: SOFA Object
%
%      results.toa: data matrix with time of arrival (TOA) for each impulse response (IR)
%
%      results.p_onaxis: estimated on-axis model-parameters
%
%      results.p_offaxis: estimated off-axis model-parameters
%
%   Requirements: 
%   -------------
%
%   1) SOFA API from http://sourceforge.net/projects/sofacoustics for Matlab (in e.g. thirdparty/SOFA)
% 
%   2) Optimization Toolbox for Matlab
%
%   Examples:
%   ---------
% 
%   To calculate the model parameters for the on-axis time-of-arrival model
%   (p_onaxis) and for the off-axis time-of-arrival model (p_offaxis) for a
%   given HRTF set (SOFA object, 'Obj') with the minimum-phase
%   cross-correlation estimation, use::
%
%       [Obj,results]=ziegelwanger2014(Obj,4,1);
%
%   See also: ziegelwanger2014_onaxis, ziegelwanger2014_offaxis,
%             data_ziegelwanger2014, exp_ziegelwanger2014, itdestimator
%
%   References: ziegelwanger2014
%

% AUTHOR: Harald Ziegelwanger, Acoustics Research Institute, Vienna, Austria
% 2018/04/05, Robert Baumgartner: modified to incorporate ltfatarghelper
% 2018/04/16, Laurin Steidle: modified to incorporate itdestimator


%% ----------------------------convert to SOFA-----------------------------
if ~isfield(Obj,'GLOBAL_Version')
    Obj=SOFAconvertARI2SOFA(Obj.hM,Obj.meta,Obj.stimPar);
end

%% ----------------------------check variables-----------------------------

definput.flags.lowpass = {'lp','bb'};
definput.flags.peak = {'hp','fp'};
definput.flags.disp = {'no_debug','debug'};
    
definput.keyvals.estimation = 4;
definput.keyvals.outlierDetection = [0.05;0.01];
definput.keyvals.model=1e-6;
definput.keyvals.p0_onaxis=[[0.0875; pi/2; 0; 0] [0.0875; -pi/2; 0; 0]];

definput.keyvals.threshlvl = -10;
definput.keyvals.upper_cutfreq = 3000;
definput.keyvals.butterpoly = 10;

[flags,kv]=ltfatarghelper({'estimation','outlierDetection','model','p0_onaxis'},definput,varargin);



estimation = kv.estimation;
outlierDetection = prod(kv.outlierDetection);

%% -------------------------initialize variables---------------------------
p0_onaxis=transpose(kv.p0_onaxis);
p_onaxis=zeros(size(p0_onaxis));
p0_offaxis=zeros(2,7);
p_offaxis=p0_offaxis;

toa=zeros(Obj.API.M,Obj.API.R);
toa_onaxis=toa;
toa_offaxis=toa;
indicator=zeros(Obj.API.M,Obj.API.R);

pos(:,1:2)=Obj.SourcePosition(:,1:2);

%% -----------------------estimate time-of-arrival-------------------------
if isscalar(estimation)
    hM=Obj.Data.IR;
    
    toaEst=zeros(Obj.API.M,Obj.API.R);
    switch estimation
        case 1 %---------------------------Threshold---------------------------
            for ii=1:Obj.API.M
                for jj=1:Obj.API.R
                    toaEst(ii,jj)=find(abs(hM(ii,jj,:))==max(abs(hM(ii,jj,:))),1);
                end
            end
        case 2 %---------------------------Centroid----------------------------
            for ii=1:Obj.API.M
                for jj=1:Obj.API.R
                    toaEst(ii,jj)=find(cumsum(hM(ii,jj,:).^2)>(sum(hM(ii,jj,:).^2)/2),1);
                end
            end
        case 3 %---------------------------Groupdelay--------------------------
            for ii=1:Obj.API.M
                for jj=1:Obj.API.R
                    [Gd,F]=grpdelay(transpose(double(squeeze(hM(ii,jj,:)))),...
                        1,Obj.API.N*4,Obj.Data.SamplingRate*4);
                    toaEst(ii,jj)=mean(Gd(find(F>1000):find(F>5000)));
                end
            end
        case 4 %---------------------------Minimal-Phase-----------------------
            hMmin=ARI_MinimalPhase(Obj);
            corrcoeff=zeros(Obj.API.M,Obj.API.R);
            for ii=1:Obj.API.M
                for jj=1:Obj.API.R
                    [c,lag]=xcorr(squeeze(hM(ii,jj,:)),squeeze(hMmin(ii,jj,:)),...
                        Obj.API.N*4-1,'none');
                    [corrcoeff(ii,jj),idx]=max(abs(c));
                    corrcoeff(ii,jj)=corrcoeff(ii,jj)/sum(hM(ii,jj,:).^2);
                    toaEst(ii,jj)=lag(idx);
                end
            end
      case 5 % ------------ Threshold on low-passed IRs

        amt_disp('  Applying Butterworth low pass',flags.disp)
        amt_disp(strcat('  Polynomial order of Butterworth filter: ',num2str(kv.butterpoly)),flags.disp)
        amt_disp(strcat('  Cut-off frequency is: ',num2str(kv.upper_cutfreq),' Hz'),flags.disp)
        cut_off_freq_norm = kv.upper_cutfreq/(Obj.Data.SamplingRate/2);
        [lp_a,lp_b] = butter(kv.butterpoly,cut_off_freq_norm);
%         f_ir = zeros(pos,ear,Ns);
        for ii=1:Obj.API.M
            for jj=1:Obj.API.R
                sir = squeeze( hM(ii,jj,:) );
                f_sir = filter(lp_a,lp_b,sir);
%                 f_ir(ii,jj,:) = f_sir;
                toaEst(ii,jj)=(find(abs(f_sir)==max(abs(f_sir)),1))-round(0.4e-3*Obj.Data.SamplingRate); % compensate for the delay of the filter, estimated for default parameters
            end
        end
    end
elseif ischar(estimation)
    [~,toaEst] = itdestimator(Obj,estimation,flags.lowpass,flags.peak,'guesstoa');
    toaEst = toaEst*Obj.Data.SamplingRate;
    
else
    toaEst=estimation;
end

%% --------------------Detect-Outliers-in-estimated-TOA--------------------
if outlierDetection>0
    for ch=1:Obj.API.R
        p0_onaxis(ch,4) = min(toaEst(indicator(:,ch)==0,ch))/Obj.Data.SamplingRate;
        p0offset_onaxis = [0.06 pi pi/2 0.001];
        x               = pos(:,1:2)*pi/180;
        y               = toaEst(:,ch)/Obj.Data.SamplingRate;

            tmp=lsqcurvefit(@ziegelwanger2014_onaxis,p0_onaxis(ch,:),...
                x,y,p0_onaxis(ch,:)-p0offset_onaxis,...
                p0_onaxis(ch,:)+p0offset_onaxis,...
                optimset('Display','off','TolFun',1e-6));

        outliers = toaEst(:,ch)-ziegelwanger2014_onaxis(tmp,pos(:,1:2)*pi/180)*Obj.Data.SamplingRate;
        [~,idx]=deleteoutliers(outliers, outlierDetection*Obj.API.M);
        indicator(idx,ch)=ones(length(idx),1);
    end
end
    
%% ----------------------Fit-Models-to-estimated-TOA-----------------------
if kv.model>0
    % Fit on-axis model to outlier adjusted set of estimated TOAs
    for ch=1:Obj.API.R
        p0_onaxis(ch,4) = min(toaEst(indicator(:,ch)==0,ch))/Obj.Data.SamplingRate;
        p0offset_onaxis = [0.06 pi pi/2 0.001];
        idx             = find(indicator(:,ch)==0);
        x               = pos(idx,1:2)*pi/180;
        y               = toaEst(idx,ch)/Obj.Data.SamplingRate;

            [p_onaxis(ch,:),performance.on_axis{ch}.resnormS,...
             performance.on_axis{ch}.residualS,...
             performance.on_axis{ch}.exitflag,...
             performance.on_axis{ch}.output] =...
                lsqcurvefit(@ziegelwanger2014_onaxis,p0_onaxis(ch,:),x,y,...
                    p0_onaxis(ch,:)-p0offset_onaxis,...
                    p0_onaxis(ch,:)+p0offset_onaxis,...
                    optimset('Display','off','TolFun',1e-6));
            toa(:,ch)=ziegelwanger2014_onaxis(p_onaxis(ch,:),pos(:,1:2)*pi/180)*Obj.Data.SamplingRate;

        performance.on_axis{ch}.resnormS = ...
            sqrt(performance.on_axis{ch}.resnormS/(Obj.API.M-sum(indicator(:,ch))));
        performance.on_axis{ch}.resnormP = ...
            norm((toaEst(:,ch)-toa(:,ch))/Obj.Data.SamplingRate)/sqrt(Obj.API.M);
    end
    toa_onaxis=toa;

    % Fit off-axis model to outlier adjusted set of estimated TOAs
    if kv.model~=2
        for ch=1:Obj.API.R
            idx = find(indicator(:,ch)==0);
            x   = pos(idx,1:2)*pi/180;
            y   = toaEst(idx,ch)/Obj.Data.SamplingRate;
            p0_offaxis(ch,:) = [mean(p_onaxis(:,1)) 0.001 ...
                                -diff(p_onaxis(:,1))/2 0.001 ...
                                mean(p_onaxis(:,4)) ...
                                p_onaxis(ch,2) ...
                                p_onaxis(ch,3)];
            p0offset_offaxis = [abs(diff(p_onaxis(:,1))/4) 0.1 0.1 0.1 0.001 pi/4 pi/4];
 
                [p_offaxis(ch,:),performance.off_axis{ch}.resnormS,...
                 performance.off_axis{ch}.residualS,...
                 performance.off_axis{ch}.exitflag,...
                 performance.off_axis{ch}.output] = ...
                    lsqcurvefit(@ziegelwanger2014_offaxis,...
                        p0_offaxis(ch,:),x,y,...
                        p0_offaxis(ch,:)-p0offset_offaxis,...
                        p0_offaxis(ch,:)+p0offset_offaxis,...
                        optimset('Display','off','TolFun',kv.model));
                toa(:,ch)=ziegelwanger2014_offaxis(p_offaxis(ch,:),pos(:,1:2)*pi/180)*Obj.Data.SamplingRate;

            performance.off_axis{ch}.resnormS = ...
                sqrt(performance.off_axis{ch}.resnormS/(Obj.API.M-sum(indicator(:,ch))));
            performance.off_axis{ch}.resnormP = ...
                norm((toaEst(:,ch)-toa(:,ch))/Obj.Data.SamplingRate)/sqrt(Obj.API.M);
        end
        toa_offaxis=toa;
    end
else
    toa=toaEst;
    p_offaxis=p0_offaxis;
end

%Save to output variables
performance.outliers=indicator;
for ii=1:size(indicator,2)
  performance.outlierRate(ii)=sum(indicator(:,ii))/Obj.API.M*100;
end
results.toa=toa;
results.toaEst=toaEst;
results.toa_onaxis=toa_onaxis;
results.toa_offaxis=toa_offaxis;
results.p_onaxis=transpose(p_onaxis);
results.p_offaxis=transpose(p_offaxis);
results.performance=performance;
if exist('corrcoeff','var')
    results.performance.corrcoeff=corrcoeff;
end

end %of function

function hMmin=ARI_MinimalPhase(Obj)
    hM=Obj.Data.IR;
    hMmin=hM;

    for jj=1:Obj.API.R
        for ii=1:Obj.API.M
            h=[squeeze(hM(ii,jj,:)); zeros(4096*4-size(hM,3),1)];
            amp1=abs(fft(h));
            amp2=amp1;
            an2u=-imag(hilbert(log(amp1)));
            an2u=an2u(1:floor(length(h)/2)+1);
            an3u=[an2u; -flipud(an2u(2:end+mod(length(h),2)-1))];
            an3=an3u-round(an3u/2/pi)*2*pi;
            amp2=amp2(1:floor(length(h)/2)+1);
            amp3=[amp2; flipud(amp2(2:end+mod(length(h),2)-1))];
            h2=real(ifft(amp3.*exp(1i*an3)));
            hMmin(ii,jj,:)=h2(1:Obj.API.N);
        end
    end
end


% ========================================================================
function hM2=LocaDyn_MinimalPhase(hM,opt)

% AA_MinimalPhase               - Replace the phase by minimal phase
%
% hM2=AA_MinimalPhase(hM);
%
% Replace the phase spectrum of hM by the minimal phase. The minimal phase
% is calculated using hilbert transformation.
%
% Input:
%  hM: data matrix with impulse respnoses (IR): 
%      dim 1: time in samples
%      dim 2: each IR
%      dim 3: each record channel
%  opt: IR (0, default), Amplitudespectrum (1)
%
% Output:
%  hM2: hM with minimal phase
%
% Piotr Majdak, 26.5.2006

if ~exist('opt','var')
    opt=0;
end

n=size(hM,1);
itnr=size(hM,2);
rec=size(hM,3);
hM2=zeros(size(hM));

for jj=1:rec
    for ii=1:itnr
        if ~opt
            h=squeeze(hM(:,ii,jj));
            % decompose signal
            amp1=abs(fft(h));
        else
            amp1=squeeze(hM(:,ii,jj));
        end

        % transform
        amp2=amp1;
        an2u=-imag(hilbert(log(amp1))); % minimal phase

        % reconstruct signal from amp2 and an2u
        % build a symmetrical phase 
        an2u=an2u(1:floor(n/2)+1);
        an2u=[an2u; -flipud(an2u(2:end+mod(n,2)-1))];
        an2=an2u-round(an2u/2/pi)*2*pi;  % wrap around +/-pi: wrap(x)=x-round(x/2/pi)*2*pi
        % amplitude
        amp2=amp2(1:floor(n/2)+1);
        amp2=[amp2; flipud(amp2(2:end+mod(n,2)-1))];
        % back to time domain
        h2=real(ifft(amp2.*exp(1i*an2)));
        hM2(:,ii,jj)=h2;
    end
end
end


% ========================================================================
function [Px, Tx, P, T] = LocaDyn_Subdivide(X, N, display)
% X: SOFA Object
% N: number of subdivisions (1=subdivide once)
% display: set to true for creating figures
%
% Px: coordinates of the subdivided positions (cartesian)
% Tx: list of subdivided faces
% P: coordinates of the original grid
% T: faces of the original grid

if ~exist('display','var'), display=0; end

azi=X.SourcePosition(:,1);
ele=X.SourcePosition(:,2);
r=X.SourcePosition(:,3);
[x,y,z]=sph2cart(deg2rad(azi),deg2rad(ele),r);
rmean=mean(r);
P=[x y z];
T = freeBoundary(delaunayTriangulation(P));
if display,
  figure;
  trisurf(T, P(:,1), P(:,2), P(:,3), 'FaceColor', 'w','EdgeColor','b', 'FaceAlpha',0.5);
  title('Subdivision: original'); 
  axis equal
  view(75,10);
end
%%
Tx=T; Px=P;
for ii=1:N
  tmp = TriQuad({Tx Px});
  Tx=tmp{1}; Px=tmp{2};
  [azi,ele]=cart2sph(Px(:,1),Px(:,2),Px(:,3));
  [Px(:,1),Px(:,2),Px(:,3)]=sph2cart(azi,ele,rmean);
  if display,
    figure; 
    trisurf(Tx, Px(:,1), Px(:,2), Px(:,3), 'FaceColor', 'w','EdgeColor','b', 'FaceAlpha',0.5);
    title(['Subdivision iteration #' num2str(ii)]); 
    axis equal
    view(75,10);
  end
end
  
end


% ========================================================================
function [g,TRidx,par,Pi] = VBAPgain(P, X, TR)
% [g,TRidx,par,Pi] = VBAPgain(P, X, TR)
%   P: requested position (cartesian)
%   X: coordinates of the available grid
%   TR: faces of the grid (can be obtained by TR=freeBoundary(delaunayTriangulation(LS)); 
%   
%   g: vector with gains
%   TRidx: index of the face found for the calculations
%   par: vector with the plane parameters 
%   Pi: intersection of (O,P) with the plane (P1,P2,P3)
%
%   #Author: Piotr Majdak (2017): Initial implementation for spatial reverb in the LAS
%   #Author: Piotr Majdak (2021): Error robustness improved for LocaDyn


for ii=1:size(TR,1)
    P1=X(TR(ii,1),:);
    if prod(prod(P==P1)), g=[1 0 0]; TRidx=ii; par=g; Pi=P1; return; end
    P2=X(TR(ii,2),:);
    if prod(prod(P==P2)), g=[0 1 0]; TRidx=ii; par=g; Pi=P2; return; end
    P3=X(TR(ii,3),:);
    if prod(prod(P==P3)), g=[0 0 1]; TRidx=ii; par=g; Pi=P3; return; end
    if cond([P; P2-P1; P3-P1])>1e10,
%         warning('eeee');
    else
      a=[P; P2-P1; P3-P1]'\(P-P1)'; % https://en.wikipedia.org/wiki/Line%E2%80%93plane_intersection
      if a(2)>=-2*eps && a(2)<=1+eps && a(3)>=-2*eps && a(3)<=1+eps && (a(2)+a(3))<=1+eps && a(1)<=1+eps, 
        TRidx=ii;
        par=a';
        Pi=P-par(1)*P; % Pi: intersection of (O,P) with the plane (P1,P2,P3)
        g=[1-par(3)-par(2) par(2) par(3)]; % loudspeaker gains
        return;
      end
    end
end
% warning on
warning('Face surrounding the requested direction not found!');
g=NaN; TRidx=NaN; par=NaN; Pi=NaN; 

end


% ========================================================================
function [TR,W]=TriQuad(TR,W)
% Subdivide a triangular surface mesh using generalized triangular 
% quadrisection. Triangular quadrisection is a linear subdivision procedure
% which inserts new vertices into the input mesh at the edge midpoints 
% thereby producing four new faces for every face of the original mesh. 
% Illustration of this operation is provided below:
% 
%                     x3                        x3
%                    /  \      subdivision     /  \
%                   /    \         -->        v3__v2
%                  /      \                  / \  / \
%                x1________x2              x1___v1___x2
%
%                   Original vertices:    x1, x2, x3
%                   New vertices:         v1, v2, v3
% 
% In case of generalized triangular quadrisection, positions of the newly
% inserted vertices do not necessarily have to correspond to edge 
% midpoints, and could be varied by assigning weights to the vertices of 
% the original mesh. For example, let xi and xj be two vertices connected 
% by an edge, and suppose that Wi and Wj are the corresponding vertex 
% weights. The position of the new point on the edge (xi,xj) would be 
% defined as (Wi*xi+Wj*xj)/(Wi+Wj). Note that in order to avoid 
% degeneracies and self-intersections, all weights must be real numbers 
% greater than zero.
%
% INPUT ARGUMENTS:
%   - TR   : input mesh. TR can be specified as a TriRep object, structure
%            with fields 'faces' and 'vertices', or a cell so that 
%            TR={Tri X}, where X is a list of vertex co-ordinates and Tri 
%            is a list of faces.
%   - W    : optional input argument. N-by-1 array of NON-ZERO, POSITIVE 
%            vertex weights used during interpolation of the new vertices, 
%            where N is the total number of the original mesh vertices. 
%
% OUTPUT:
%   - TR  : subdivided mesh. Same format as the input.
%   - W   : new set of vertex weights.
%
% AUTHOR: Anton Semechko (a.semechko@gmail.com)
% DATE: May.2012
%
%
% This file is part of the S2 Sampling Toolbox, Copyright (c) 2015, Anton Semechko
%
% Redistribution and use in source and binary forms, with or without
% modification, are permitted provided that the following conditions are
% met:
% 
%     * Redistributions of source code must retain the above copyright
%       notice, this list of conditions and the following disclaimer.
%     * Redistributions in binary form must reproduce the above copyright
%       notice, this list of conditions and the following disclaimer in
%       the documentation and/or other materials provided with the distribution
% 
% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
% AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
% ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
% LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
% CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
% SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
% INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
% CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
% ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
% POSSIBILITY OF SUCH DAMAGE.

% Get the list of vertex co-ordinates and list of faces
fmt=1;
if isa(TR,'TriRep')
    Tri=TR.Triangulation;
    X=TR.X;
elseif isstruct(TR) && sum(isfield(TR,{'vertices' 'faces'}))==2
    Tri=TR.faces;
    X=TR.vertices;
    fmt=2;
elseif iscell(TR) && numel(TR)==2
    Tri=TR{1};
    X=TR{2};
    fmt=3;
else
    error('Unrecognized input format')
end

% Make sure that the mesh is composed entirely of triangles 
if size(Tri,2)~=3 || ~isequal(round(Tri),Tri)
        error('Invalid entry for the list of faces')
end

% Check vertex weights
flag=false;
if nargin<2 || isempty(W), flag=true; end

if ~flag && (numel(W)~=size(X,1) || sum(W<=eps))
    error('W must be a N-by-1 array with non-negative entries, where N is the # of mesh vertices')
end
if ~flag, W=W(:)+eps; end

% Compute new vertex positions
if ~flag
    w=bsxfun(@rdivide,[W(Tri(:,1)),W(Tri(:,2))],W(Tri(:,1))+W(Tri(:,2)));
    V1=bsxfun(@times,X(Tri(:,1),:),w(:,1))+bsxfun(@times,X(Tri(:,2),:),w(:,2));
    w1=W(Tri(:,1)).*w(:,1)+W(Tri(:,2)).*w(:,2);
    
    w=bsxfun(@rdivide,[W(Tri(:,2)),W(Tri(:,3))],W(Tri(:,2))+W(Tri(:,3)));
    V2=bsxfun(@times,X(Tri(:,2),:),w(:,1))+bsxfun(@times,X(Tri(:,3),:),w(:,2));
    w2=W(Tri(:,2)).*w(:,1)+W(Tri(:,3)).*w(:,2);
    
    w=bsxfun(@rdivide,[W(Tri(:,3)),W(Tri(:,1))],W(Tri(:,3))+W(Tri(:,1)));
    V3=bsxfun(@times,X(Tri(:,3),:),w(:,1))+bsxfun(@times,X(Tri(:,1),:),w(:,2));
    w3=W(Tri(:,3)).*w(:,1)+W(Tri(:,1)).*w(:,2);
    
    W_new=[w1;w2;w3];
else
    V1=(X(Tri(:,1),:)+X(Tri(:,2),:))/2;
    V2=(X(Tri(:,2),:)+X(Tri(:,3),:))/2;
    V3=(X(Tri(:,3),:)+X(Tri(:,1),:))/2;
end
V=[V1;V2;V3];

% Remove repeating vertices 
[V,idx_unq,idx]=unique(V,'rows','stable'); % setOrder='stable' ensures that identical results (in terms of face connectivity) will be obtained for meshes with same topology
if ~flag
    W=[W;W_new(idx_unq)]; 
end

% Assign indices to the new triangle vertices
Nx=size(X,1);   % # of vertices
Nt=size(Tri,1); % # of faces

V1= Nx + idx(1:Nt);
V2= Nx + idx((Nt+1):2*Nt);
V3= Nx + idx((2*Nt+1):3*Nt);
clear idx

% Define new faces
T1= [Tri(:,1) V1 V3];
T2= [Tri(:,2) V2 V1];
T3= [Tri(:,3) V3 V2];
T4= [V1       V2 V3];
clear V1 V2 V3

T1=permute(T1,[3 1 2]);
T2=permute(T2,[3 1 2]);
T3=permute(T3,[3 1 2]);
T4=permute(T4,[3 1 2]);

Tri=cat(1,T1,T2,T3,T4);
Tri=reshape(Tri,[],3,1);

% New mesh
X=[X;V]; 
if fmt==1
    TR=TriRep(Tri,X);
elseif fmt==2
    TR.faces=Tri;
    TR.vertices=X;
else
    TR={Tri,X};
end
if nargout>1 && flag, W=ones(size(X,1),1); end


end

% Original downloaded source hashes (SHA-256):
% LocaDyn_InterpolateHRTFs.m 24cde19f6e3949f0affb8cda4c23e624b9859868b55e16678e893fa865829aaa
% LocaDyn_MinimalPhase.m 3c790c0178d75133572166936ade0f511e673199e363e0a7fe3cee78c4e1c5d0
% LocaDyn_PostProcHRTFs.m 2ba8046f4c1bf881a2800c96d7099e6a379ca193fb6089c73c13c18bd2fd1d95
% LocaDyn_StaticSpectrum.m 8d87d3da4cd2965782b3b858b6ec0becef1bd372ae8c6076e662c7e96107aa3f
% LocaDyn_Subdivide.m d08d9e18c9991d381ea740ddfc15136b5490f34dd8c0d20d0d737fb02ec022fe
% LocaDyn_ziegelwanger2014_adapt.m ecb13d01d0caf05812fa2ddc356a03c286befaadde9695261d5c3ba05910122f
% TriQuad.m 1a6586ae32b61094a48d9b1abd15310b08473bf3a287d6cf51f03dd73cff5478
% VBAPgain.m 2c5ae14d2a005a18290b83236fc6788d4c90a962440017782e9a951337aafdb9

% EUPL 1.2 license text:
% EUROPEAN UNION PUBLIC LICENCE v. 1.2
% EUPL © the European Union 2007, 2016
% 
% This European Union Public Licence (the ‘EUPL’) applies to the Work (as defined
% below) which is provided under the terms of this Licence. Any use of the Work,
% other than as authorised under this Licence is prohibited (to the extent such
% use is covered by a right of the copyright holder of the Work).
% 
% The Work is provided under the terms of this Licence when the Licensor (as
% defined below) has placed the following notice immediately following the
% copyright notice for the Work:
% 
%         Licensed under the EUPL
% 
% or has expressed by any other means his willingness to license under the EUPL.
% 
% 1. Definitions
% 
% In this Licence, the following terms have the following meaning:
% 
% - ‘The Licence’: this Licence.
% 
% - ‘The Original Work’: the work or software distributed or communicated by the
%   Licensor under this Licence, available as Source Code and also as Executable
%   Code as the case may be.
% 
% - ‘Derivative Works’: the works or software that could be created by the
%   Licensee, based upon the Original Work or modifications thereof. This Licence
%   does not define the extent of modification or dependence on the Original Work
%   required in order to classify a work as a Derivative Work; this extent is
%   determined by copyright law applicable in the country mentioned in Article 15.
% 
% - ‘The Work’: the Original Work or its Derivative Works.
% 
% - ‘The Source Code’: the human-readable form of the Work which is the most
%   convenient for people to study and modify.
% 
% - ‘The Executable Code’: any code which has generally been compiled and which is
%   meant to be interpreted by a computer as a program.
% 
% - ‘The Licensor’: the natural or legal person that distributes or communicates
%   the Work under the Licence.
% 
% - ‘Contributor(s)’: any natural or legal person who modifies the Work under the
%   Licence, or otherwise contributes to the creation of a Derivative Work.
% 
% - ‘The Licensee’ or ‘You’: any natural or legal person who makes any usage of
%   the Work under the terms of the Licence.
% 
% - ‘Distribution’ or ‘Communication’: any act of selling, giving, lending,
%   renting, distributing, communicating, transmitting, or otherwise making
%   available, online or offline, copies of the Work or providing access to its
%   essential functionalities at the disposal of any other natural or legal
%   person.
% 
% 2. Scope of the rights granted by the Licence
% 
% The Licensor hereby grants You a worldwide, royalty-free, non-exclusive,
% sublicensable licence to do the following, for the duration of copyright vested
% in the Original Work:
% 
% - use the Work in any circumstance and for all usage,
% - reproduce the Work,
% - modify the Work, and make Derivative Works based upon the Work,
% - communicate to the public, including the right to make available or display
%   the Work or copies thereof to the public and perform publicly, as the case may
%   be, the Work,
% - distribute the Work or copies thereof,
% - lend and rent the Work or copies thereof,
% - sublicense rights in the Work or copies thereof.
% 
% Those rights can be exercised on any media, supports and formats, whether now
% known or later invented, as far as the applicable law permits so.
% 
% In the countries where moral rights apply, the Licensor waives his right to
% exercise his moral right to the extent allowed by law in order to make effective
% the licence of the economic rights here above listed.
% 
% The Licensor grants to the Licensee royalty-free, non-exclusive usage rights to
% any patents held by the Licensor, to the extent necessary to make use of the
% rights granted on the Work under this Licence.
% 
% 3. Communication of the Source Code
% 
% The Licensor may provide the Work either in its Source Code form, or as
% Executable Code. If the Work is provided as Executable Code, the Licensor
% provides in addition a machine-readable copy of the Source Code of the Work
% along with each copy of the Work that the Licensor distributes or indicates, in
% a notice following the copyright notice attached to the Work, a repository where
% the Source Code is easily and freely accessible for as long as the Licensor
% continues to distribute or communicate the Work.
% 
% 4. Limitations on copyright
% 
% Nothing in this Licence is intended to deprive the Licensee of the benefits from
% any exception or limitation to the exclusive rights of the rights owners in the
% Work, of the exhaustion of those rights or of other applicable limitations
% thereto.
% 
% 5. Obligations of the Licensee
% 
% The grant of the rights mentioned above is subject to some restrictions and
% obligations imposed on the Licensee. Those obligations are the following:
% 
% Attribution right: The Licensee shall keep intact all copyright, patent or
% trademarks notices and all notices that refer to the Licence and to the
% disclaimer of warranties. The Licensee must include a copy of such notices and a
% copy of the Licence with every copy of the Work he/she distributes or
% communicates. The Licensee must cause any Derivative Work to carry prominent
% notices stating that the Work has been modified and the date of modification.
% 
% Copyleft clause: If the Licensee distributes or communicates copies of the
% Original Works or Derivative Works, this Distribution or Communication will be
% done under the terms of this Licence or of a later version of this Licence
% unless the Original Work is expressly distributed only under this version of the
% Licence — for example by communicating ‘EUPL v. 1.2 only’. The Licensee
% (becoming Licensor) cannot offer or impose any additional terms or conditions on
% the Work or Derivative Work that alter or restrict the terms of the Licence.
% 
% Compatibility clause: If the Licensee Distributes or Communicates Derivative
% Works or copies thereof based upon both the Work and another work licensed under
% a Compatible Licence, this Distribution or Communication can be done under the
% terms of this Compatible Licence. For the sake of this clause, ‘Compatible
% Licence’ refers to the licences listed in the appendix attached to this Licence.
% Should the Licensee's obligations under the Compatible Licence conflict with
% his/her obligations under this Licence, the obligations of the Compatible
% Licence shall prevail.
% 
% Provision of Source Code: When distributing or communicating copies of the Work,
% the Licensee will provide a machine-readable copy of the Source Code or indicate
% a repository where this Source will be easily and freely available for as long
% as the Licensee continues to distribute or communicate the Work.
% 
% Legal Protection: This Licence does not grant permission to use the trade names,
% trademarks, service marks, or names of the Licensor, except as required for
% reasonable and customary use in describing the origin of the Work and
% reproducing the content of the copyright notice.
% 
% 6. Chain of Authorship
% 
% The original Licensor warrants that the copyright in the Original Work granted
% hereunder is owned by him/her or licensed to him/her and that he/she has the
% power and authority to grant the Licence.
% 
% Each Contributor warrants that the copyright in the modifications he/she brings
% to the Work are owned by him/her or licensed to him/her and that he/she has the
% power and authority to grant the Licence.
% 
% Each time You accept the Licence, the original Licensor and subsequent
% Contributors grant You a licence to their contributions to the Work, under the
% terms of this Licence.
% 
% 7. Disclaimer of Warranty
% 
% The Work is a work in progress, which is continuously improved by numerous
% Contributors. It is not a finished work and may therefore contain defects or
% ‘bugs’ inherent to this type of development.
% 
% For the above reason, the Work is provided under the Licence on an ‘as is’ basis
% and without warranties of any kind concerning the Work, including without
% limitation merchantability, fitness for a particular purpose, absence of defects
% or errors, accuracy, non-infringement of intellectual property rights other than
% copyright as stated in Article 6 of this Licence.
% 
% This disclaimer of warranty is an essential part of the Licence and a condition
% for the grant of any rights to the Work.
% 
% 8. Disclaimer of Liability
% 
% Except in the cases of wilful misconduct or damages directly caused to natural
% persons, the Licensor will in no event be liable for any direct or indirect,
% material or moral, damages of any kind, arising out of the Licence or of the use
% of the Work, including without limitation, damages for loss of goodwill, work
% stoppage, computer failure or malfunction, loss of data or any commercial
% damage, even if the Licensor has been advised of the possibility of such damage.
% However, the Licensor will be liable under statutory product liability laws as
% far such laws apply to the Work.
% 
% 9. Additional agreements
% 
% While distributing the Work, You may choose to conclude an additional agreement,
% defining obligations or services consistent with this Licence. However, if
% accepting obligations, You may act only on your own behalf and on your sole
% responsibility, not on behalf of the original Licensor or any other Contributor,
% and only if You agree to indemnify, defend, and hold each Contributor harmless
% for any liability incurred by, or claims asserted against such Contributor by
% the fact You have accepted any warranty or additional liability.
% 
% 10. Acceptance of the Licence
% 
% The provisions of this Licence can be accepted by clicking on an icon ‘I agree’
% placed under the bottom of a window displaying the text of this Licence or by
% affirming consent in any other similar way, in accordance with the rules of
% applicable law. Clicking on that icon indicates your clear and irrevocable
% acceptance of this Licence and all of its terms and conditions.
% 
% Similarly, you irrevocably accept this Licence and all of its terms and
% conditions by exercising any rights granted to You by Article 2 of this Licence,
% such as the use of the Work, the creation by You of a Derivative Work or the
% Distribution or Communication by You of the Work or copies thereof.
% 
% 11. Information to the public
% 
% In case of any Distribution or Communication of the Work by means of electronic
% communication by You (for example, by offering to download the Work from a
% remote location) the distribution channel or media (for example, a website) must
% at least provide to the public the information requested by the applicable law
% regarding the Licensor, the Licence and the way it may be accessible, concluded,
% stored and reproduced by the Licensee.
% 
% 12. Termination of the Licence
% 
% The Licence and the rights granted hereunder will terminate automatically upon
% any breach by the Licensee of the terms of the Licence.
% 
% Such a termination will not terminate the licences of any person who has
% received the Work from the Licensee under the Licence, provided such persons
% remain in full compliance with the Licence.
% 
% 13. Miscellaneous
% 
% Without prejudice of Article 9 above, the Licence represents the complete
% agreement between the Parties as to the Work.
% 
% If any provision of the Licence is invalid or unenforceable under applicable
% law, this will not affect the validity or enforceability of the Licence as a
% whole. Such provision will be construed or reformed so as necessary to make it
% valid and enforceable.
% 
% The European Commission may publish other linguistic versions or new versions of
% this Licence or updated versions of the Appendix, so far this is required and
% reasonable, without reducing the scope of the rights granted by the Licence. New
% versions of the Licence will be published with a unique version number.
% 
% All linguistic versions of this Licence, approved by the European Commission,
% have identical value. Parties can take advantage of the linguistic version of
% their choice.
% 
% 14. Jurisdiction
% 
% Without prejudice to specific agreement between parties,
% 
% - any litigation resulting from the interpretation of this License, arising
%   between the European Union institutions, bodies, offices or agencies, as a
%   Licensor, and any Licensee, will be subject to the jurisdiction of the Court
%   of Justice of the European Union, as laid down in article 272 of the Treaty on
%   the Functioning of the European Union,
% 
% - any litigation arising between other parties and resulting from the
%   interpretation of this License, will be subject to the exclusive jurisdiction
%   of the competent court where the Licensor resides or conducts its primary
%   business.
% 
% 15. Applicable Law
% 
% Without prejudice to specific agreement between parties,
% 
% - this Licence shall be governed by the law of the European Union Member State
%   where the Licensor has his seat, resides or has his registered office,
% 
% - this licence shall be governed by Belgian law if the Licensor has no seat,
%   residence or registered office inside a European Union Member State.
% 
% Appendix
% 
% ‘Compatible Licences’ according to Article 5 EUPL are:
% 
% - GNU General Public License (GPL) v. 2, v. 3
% - GNU Affero General Public License (AGPL) v. 3
% - Open Software License (OSL) v. 2.1, v. 3.0
% - Eclipse Public License (EPL) v. 1.0
% - CeCILL v. 2.0, v. 2.1
% - Mozilla Public Licence (MPL) v. 2
% - GNU Lesser General Public Licence (LGPL) v. 2.1, v. 3
% - Creative Commons Attribution-ShareAlike v. 3.0 Unported (CC BY-SA 3.0) for
%   works other than software
% - European Union Public Licence (EUPL) v. 1.1, v. 1.2
% - Québec Free and Open-Source Licence — Reciprocity (LiLiQ-R) or Strong
%   Reciprocity (LiLiQ-R+).
% 
% The European Commission may update this Appendix to later versions of the above
% licences without producing a new version of the EUPL, as long as they provide
% the rights granted in Article 2 of this Licence and protect the covered Source
% Code from exclusive appropriation.
% 
% All other changes or additions to this Appendix require the production of a new
% EUPL version.
