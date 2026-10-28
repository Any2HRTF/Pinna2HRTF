function X = experiment_general_fir(X)
% Lossless convention conversion for fixed, free-field Pinna2HRTF HRIRs.
% Reject moving listeners, multiple emitters, and unfamiliar coordinate frames.
if ~strcmp(X.GLOBAL_DataType,'FIR') || size(X.Data.IR,2)~=2 || ...
        ndims(X.Data.IR)~=3 || ~strcmpi(X.GLOBAL_RoomType,'free field')
    error('MainExperiment:GeneralFIR','Expected binaural free-field FIR data.');
end
fields = {'ListenerPosition','ListenerView','ListenerUp','EmitterPosition'};
expected = {[0 0 0],[1 0 0],[0 0 1],[0 0 0]};
% Mesh2HRTF omits optional ListenerUp: its documented frame is x forward,
% y left, z up. Make that implicit standard frame explicit in the HRIR file.
if ~isfield(X,'ListenerUp') && isfield(X,'GLOBAL_ApplicationName') && ...
        strcmp(X.GLOBAL_ApplicationName,'Mesh2HRTF')
    X=SOFAaddVariable(X,'ListenerUp','IC',[0 0 1]);
end
for k=1:numel(fields)
    name=fields{k};
    if ~isfield(X,name) || numel(X.(name))~=3 || ...
            any(abs(reshape(X.(name),1,3)-expected{k})>1e-12)
        error('MainExperiment:Frame','Expected fixed standard %s.',name);
    end
end
for name={'ListenerPosition','ListenerView','EmitterPosition'}
    if ~strcmpi(X.([name{1} '_Type']),'cartesian') || ...
            ~any(strcmpi(strtrim(X.([name{1} '_Units'])),{'metre','meter'}))
        error('MainExperiment:Frame','Expected Cartesian metres for %s.',name{1});
    end
end
original=X;
X=SOFAconvertConventions(X,'SimpleFreeFieldHRIR');
defaults=SOFAgetConventions('SimpleFreeFieldHRIR');
% GeneralFIR does not require these descriptive HRIR attributes.
for name={'GLOBAL_DatabaseName','GLOBAL_ListenerShortName'}
    if ~isfield(X,name{1}), X.(name{1})=defaults.(name{1}); end
end
if ~isequal(X.Data,original.Data) || ...
        ~isequal(X.SourcePosition,original.SourcePosition) || ...
        ~isequal(X.ReceiverPosition,original.ReceiverPosition)
    error('MainExperiment:Conversion','Convention conversion changed numerical data.');
end
X.GLOBAL_History=[X.GLOBAL_History ' Lossless GeneralFIR to SimpleFreeFieldHRIR conversion for LocaDyn.'];
end
