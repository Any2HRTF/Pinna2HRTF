"""Generate synthetic MATLAB goldens for the Python LocaDyn port.

Usage: python Tests/generate_locadyn_reference.py --amt /path/to/amtoolbox
Requires MATLAB Optimization/Signal/Statistics toolboxes. AMT is used only
for the original on/off-axis models and deleteoutliers. No personal HRIRs
are included in these deterministic synthetic fixtures.
"""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

import numpy as np
from scipy.io import loadmat, savemat


def generate(matlab, amt, destination):
    root = Path(__file__).resolve().parents[1]
    reference = root/'HRTFCalculation/Postprocessing/upsample_hrtf.m'
    text = reference.read_text(errors='replace')
    helpers = text[text.index('function [Xreturn, TOAcheck]'):text.index('% Original downloaded source hashes')]
    # The wrapper always passes these three positional arguments. Substitute
    # only argument parsing so a full LTFAT installation is unnecessary.
    helpers = helpers.replace("[flags,kv]=ltfatarghelper({'estimation','outlierDetection','model','p0_onaxis'},definput,varargin);",
                              'kv=definput.keyvals;kv.estimation=4;kv.outlierDetection=1;kv.model=1;')
    # Fibonacci sampling avoids Qhull ambiguities from cospherical rectangles.
    n = 90
    z = 1-2*(np.arange(n)+.5)/n
    az = (np.arange(n)*137.50776405003785) % 360
    positions = np.column_stack((az, np.arcsin(z)*180/np.pi, np.ones(n)))
    positions = np.concatenate(([[0,0,1]], positions))
    data = {'positions': positions}
    for length in (64,65):
        signals = np.empty((91,2,length))
        for i, (a,e,_) in enumerate(positions):
            for ch in range(2):
                lag = int(12+7*(1-(-1)**ch*np.sin(a*np.pi/180)*np.cos(e*np.pi/180)))
                t = np.arange(length)-lag
                signals[i,ch] = np.where(t>=0, .7**np.maximum(t,0)*(1+.15*np.sin(t*1.7+i*.1)),0)
                signals[i,ch] += 1e-5*np.cos(np.arange(length)*.37+i+ch)
        data[f'ir{length}'] = signals
    with tempfile.TemporaryDirectory(prefix='pinna-matlab-reference-') as temp:
        temp = Path(temp)
        savemat(temp/'input.mat',data)
        q = lambda p: "'"+str(p).replace("'","''")+"'"
        script = f"""function reference_run()
load({q(temp/'input.mat')});
cases=struct([]);k=0;
for n=[64 65]
 if n==64, input=ir64;fs=48000;else,input=ir65;fs=44100;end
 for normalize=[false true]
  ir=input;
  if normalize, old=mean(rms(squeeze(ir(1,:,:))));ir=ir/old*.01;end
  Obj.GLOBAL_Version='1';Obj.Data.IR=ir;Obj.Data.SamplingRate=fs;
  Obj.API.M=size(ir,1);Obj.API.R=2;Obj.API.N=n;Obj.SourcePosition=positions;
  for level=[0 1]
   [all,~]=local_locadyn_interpolate(Obj,level,2,false,[]);
   k=k+1;cases(k).ir=input;cases(k).fs=fs;cases(k).normalize=normalize;
   cases(k).level=level;cases(k).output=all(3).Data.IR;
   cases(k).positions=all(3).SourcePosition;cases(k).delay=all(3).Data.Delay;
  end
 end
end
save({q(temp/'output.mat')},'cases','positions','-v7');
end
"""
        stubs = '''
function obj=SOFAaddVariable(obj,name,dims,value)
obj.(name)=value;
end
function obj=SOFAremoveVariable(obj,name)
obj=rmfield(obj,name);
end
function obj=SOFAupdateDimensions(obj)
obj.API.M=size(obj.Data.IR,1);obj.API.R=size(obj.Data.IR,2);obj.API.N=size(obj.Data.IR,3);
end
'''
        (temp/'reference_run.m').write_text(script+helpers+stubs)
        command = f"restoredefaultpath;addpath({q(temp)},{q(amt/'modelstages')},{q(amt/'thirdparty')});reference_run"
        subprocess.run([str(matlab),'-batch',command],check=True)
        result = loadmat(temp/'output.mat',simplify_cells=True)
        archive = {'positions': result['positions'], 'reference_sha256':hashlib.sha256(reference.read_bytes()).hexdigest()}
        for i,case in enumerate(result['cases']):
            archive.update({f'case{i}_{key}':value for key,value in case.items()})
        np.savez_compressed(destination,**archive)


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--matlab',type=Path,default=Path('/Applications/MATLAB_R2024b.app/bin/matlab'))
    parser.add_argument('--amt',type=Path,required=True)
    parser.add_argument('--output',type=Path,default=Path(__file__).parent/'fixtures/locadyn_matlab_reference.npz')
    args=parser.parse_args()
    generate(args.matlab,args.amt,args.output)
