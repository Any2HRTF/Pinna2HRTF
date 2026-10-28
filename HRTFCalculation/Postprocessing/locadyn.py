"""Python translation of ExpSuite/LocaDyn revision 1948.

Copyright (C) 2003–2022 Acoustics Research Institute, Austrian Academy of
Sciences; Piotr Majdak and Michael Mihocic. Licensed under EUPL 1.2.
The unmodified source and full license are retained in upsample_hrtf.m.
The on/off-axis models derive from AMT (Harald Ziegelwanger, Robert
Baumgartner, Laurin Steidle), GPL-3.0-or-later:
https://amtoolbox.org/amt-1.6.0/doc/modelstages/ziegelwanger2014_offaxis_code.php
TriQuad subdivision: Anton Semechko (2015), BSD notice in upsample_hrtf.m.
This combined translation is distributed under GPL-3.0, using the EUPL
compatibility provision. See AMT-GPL-3.0.txt for the full license.

Numerical comparisons against MATLAB are covered by the reference fixtures.
Floating-point results are numerically equivalent, not bitwise identical.
"""
from __future__ import annotations

import numpy as np
from scipy.signal import hilbert, correlate
from scipy.optimize import least_squares
from scipy.spatial import ConvexHull


def matlab_round(x):
    """MATLAB round: halfway values away from zero (not NumPy's ties-to-even)."""
    x = np.asarray(x)
    magnitude = np.abs(x)
    whole = np.floor(magnitude)
    return np.copysign(whole + (magnitude - whole >= .5), x)


def minimum_phase(ir, fft_length=None):
    """ARI/LocaDyn Hilbert minimum phase, preserving native-length truncation."""
    ir = np.asarray(ir, dtype=np.float64)
    n = ir.shape[-1] if fft_length is None else fft_length
    amp = np.abs(np.fft.fft(ir, n=n, axis=-1))
    if np.any(amp == 0):
        raise ValueError('Minimum-phase transform requires nonzero FFT magnitudes.')
    phase = -hilbert(np.log(amp), axis=-1).imag[..., :n//2+1]
    stop = -1 if n % 2 == 0 else None
    phase = np.concatenate((phase, -phase[..., 1:stop][..., ::-1]), axis=-1)
    phase = phase - matlab_round(phase / 2 / np.pi) * 2 * np.pi
    half = amp[..., :n//2+1]
    amp = np.concatenate((half, half[..., 1:stop][..., ::-1]), axis=-1)
    return np.fft.ifft(amp * np.exp(1j * phase), axis=-1).real[..., :ir.shape[-1]]


def estimate_toa(ir):
    minimum = minimum_phase(ir, 16384)
    n = ir.shape[-1]
    return np.array([[np.argmax(np.abs(correlate(a, b, mode='full'))) - n + 1
                      for a, b in zip(row, mrow)] for row, mrow in zip(ir, minimum)])


def _ear_distance(phi, theta, x):
    return (np.sin(theta)*np.sin(x[:, 1]) + np.cos(theta)*np.cos(x[:, 1])
            * np.cos(phi-x[:, 0]))


def onaxis(p, x):
    r, phi, theta, delay = p
    d = _ear_distance(phi, theta, x)
    return r/340*((np.sign(d)/2+.5)*(1-d) + (-np.sign(d)/2+.5)
                 *(1+np.arccos(np.clip(d, -1, 1))-np.pi/2)) + delay-r/340


def offaxis(p, x):
    r, xm, ym, zm, delay, phi, theta = p[:7]
    m = np.sqrt(xm*xm+ym*ym+zm*zm)
    beta = np.arccos(-np.cos(x[:, 1])*(xm*np.cos(x[:, 0])+ym*np.sin(x[:, 0]))
                     - zm*np.sin(x[:, 1]))
    s2 = -r+m*np.cos(beta)+np.sqrt(r*r+m*m*np.cos(beta)**2+2*m*r)
    if m == 0:
        s1 = np.zeros(len(x))
    else:
        gamma = np.pi-beta-np.arccos((2*m*m+2*m*r-2*r*s2-s2*s2)/(2*m*m+2*m*r))
        s1 = m*np.cos(beta)/(2*(m+r)*np.tan(gamma/2))
    d = _ear_distance(phi, theta, x)
    return (r*((np.sign(d)/2+.5)*(1-d)+(-np.sign(d)/2+.5)
               *(1+np.arccos(np.clip(d, -1, 1))-np.pi/2))+s1+s2)/340+delay-(m+r)/340


def _curvefit(model, p, offset, x, y, ftol=1e-6):
    # Legacy optimset TolFun sets BOTH function and optimality tolerances.
    # In particular, the reference off-axis fit passes TolFun=1.
    # MATLAB accepts equal bounds (fixed parameters), SciPy requires strict
    # bounds. Eliminate fixed parameters without changing the model.
    free = offset > 0
    def unpack(values):
        full = p.copy()
        full[free] = values
        return full
    result = least_squares(lambda values: model(unpack(values), x)-y, p[free],
                           bounds=((p-offset)[free], (p+offset)[free]),
                           ftol=ftol, xtol=1e-6, gtol=ftol)
    return unpack(result.x)


def fit_onaxis(toa, positions, fs):
    """Bounded TRF fit with the reference MATLAB tolerances."""
    x = positions[:, :2]*np.pi/180
    fitted = []
    for ch in range(2):
        p = np.array([.0875, (-1)**ch*np.pi/2, 0, np.min(toa[:, ch])/fs])
        offset = np.array([.06, np.pi, np.pi/2, .001])
        fitted.append(_curvefit(onaxis, p, offset, x, toa[:, ch]/fs))
    return np.asarray(fitted)


def spherical_to_cartesian(pos):
    a, e = (pos[:, :2]*np.pi/180).T
    r = pos[:, 2]
    return np.column_stack((r*np.cos(e)*np.cos(a), r*np.cos(e)*np.sin(a), r*np.sin(e)))


def subdivide(points, faces, levels, radius):
    """TriQuad stable midpoint order and four interleaved children per face."""
    p, t = points.copy(), faces.copy()
    for _ in range(levels):
        vertices = np.concatenate([(p[t[:, i]]+p[t[:, j]])/2 for i, j in [(0,1),(1,2),(2,0)]])
        lookup, unique, indices = {}, [], []
        for v in vertices:
            key = tuple(v)
            if key not in lookup:
                lookup[key] = len(unique)+len(p)
                unique.append(v)
            indices.append(lookup[key])
        v1, v2, v3 = np.asarray(indices).reshape(3, -1)
        children = [np.column_stack(c) for c in [(t[:,0],v1,v3),(t[:,1],v2,v1),
                                                (t[:,2],v3,v2),(v1,v2,v3)]]
        t = np.stack(children, axis=1).reshape(-1, 3)
        p = np.concatenate((p, np.asarray(unique)))
        # MATLAB cart2sph/sph2cart projection, rather than norm division.
        a = np.arctan2(p[:,1], p[:,0])
        e = np.arctan2(p[:,2], np.hypot(p[:,0], p[:,1]))
        p = np.column_stack((radius*np.cos(e)*np.cos(a),radius*np.cos(e)*np.sin(a),radius*np.sin(e)))
    return p, t


def outlier_mask(residual, alpha):
    """AMT deleteoutliers Grubbs loop, including LocaDyn's alpha=M argument."""
    from scipy.stats import t
    b = residual.copy()
    while True:
        finite = b[~np.isnan(b)]
        n = len(finite)
        deviation = np.abs(finite-np.mean(finite))
        value = finite[np.argmax(deviation)]
        sd = np.std(finite, ddof=1)
        critical_t = t.ppf(alpha/(2*n), n-2)
        with np.errstate(invalid='ignore', divide='ignore'):
            critical = (n-1)/np.sqrt(n)*np.sqrt(critical_t**2/(n-2+critical_t**2))
            score = abs((value-np.mean(finite))/sd)
        if not score > critical:
            return np.isnan(b)
        b[residual == value] = np.nan


def fit_toa(ir, positions, fs):
    estimated = estimate_toa(ir)
    x = positions[:, :2]*np.pi/180
    initial = fit_onaxis(estimated, positions, fs)
    excluded = np.column_stack([outlier_mask(estimated[:,ch]-onaxis(initial[ch],x)*fs, len(ir))
                                for ch in range(2)])
    on = []
    for ch in range(2):
        keep = ~excluded[:,ch]
        p = np.array([.0875,(-1)**ch*np.pi/2,0,np.min(estimated[keep,ch])/fs])
        offset = np.array([.06,np.pi,np.pi/2,.001])
        on.append(_curvefit(onaxis, p, offset, x[keep], estimated[keep,ch]/fs))
    on=np.asarray(on)
    fitted=[]
    for ch in range(2):
        keep=~excluded[:,ch]
        p=np.array([np.mean(on[:,0]),.001,-np.diff(on[:,0])[0]/2,.001,
                    np.mean(on[:,3]),on[ch,1],on[ch,2]])
        offset=np.array([abs(np.diff(on[:,0])[0]/4),.1,.1,.1,.001,np.pi/4,np.pi/4])
        fitted.append(_curvefit(offaxis, p, offset, x[keep], estimated[keep,ch]/fs, ftol=1))
    return np.asarray(fitted), {'toaEst':estimated,'outliers':excluded,'p_onaxis':on}


def boundary_faces(points):
    faces=ConvexHull(points).simplices.copy()
    # freeBoundary uses outward orientation, lowest index first, lexical rows.
    normal=np.cross(points[faces[:,1]]-points[faces[:,0]],points[faces[:,2]]-points[faces[:,0]])
    inward=np.sum(normal*points[faces[:,0]],axis=1)<0
    faces[inward]=faces[inward][:,[0,2,1]]
    faces=np.array([np.roll(row,-np.argmin(row)) for row in faces])
    return faces[np.lexsort((faces[:,2],faces[:,1],faces[:,0]))]


def vbap_weights(point, points, faces, inverse=None):
    eps=np.finfo(float).eps
    candidates = range(len(faces))
    if inverse is not None:
        gains = np.einsum("fij,j->fi", inverse, point)
        with np.errstate(divide="ignore", invalid="ignore"):
            weights = gains / np.sum(gains, axis=1)[:, None]
        candidates = np.flatnonzero(np.all(weights >= -1e-12, axis=1))
    for index in candidates:
        face = faces[index]
        triangle=points[face]
        for i in range(3):
            if np.array_equal(point,triangle[i]):
                return face,np.eye(3)[i]
        matrix=np.array([point,triangle[1]-triangle[0],triangle[2]-triangle[0]])
        if np.linalg.cond(matrix)>1e10:
            continue
        a=np.linalg.solve(matrix.T,point-triangle[0])
        if (-2*eps<=a[1]<=1+eps and -2*eps<=a[2]<=1+eps
                and a[1]+a[2]<=1+eps and a[0]<=1+eps):
            return face,np.array([1-a[2]-a[1],a[1],a[2]])
    if inverse is not None:
        return vbap_weights(point, points, faces)
    raise ValueError('No enclosing VBAP face found.')


def interpolate(ir, positions, fs, subdivisions=3, normalize=True, logger=print):
    ir=np.array(ir,dtype=float,copy=True)
    gain=1.
    if normalize:
        front=np.flatnonzero(np.all(positions[:,:2]==0,axis=1))
        if len(front)!=1:
            raise ValueError('LocaDyn normalization requires one exact frontal direction (0°, 0°).')
        energy=np.mean(np.sqrt(np.mean(ir[front[0]]**2,axis=0)))
        ir=ir/energy*.01
        gain=.01/energy
    parameters,diagnostics=fit_toa(ir,positions,fs)
    aligned=minimum_phase(ir)
    for ch in range(2):
        aligned[:,ch]=np.roll(aligned[:,ch],int(matlab_round(parameters[ch,4]*fs)),axis=-1)
    aligned=np.concatenate((aligned,np.zeros((1,2,ir.shape[-1]))))
    pos=np.concatenate((positions,[[0,-90,positions[0,2]]]))
    points=spherical_to_cartesian(pos)
    faces=boundary_faces(points)
    dense,_=subdivide(points,faces,subdivisions,np.mean(pos[:,2]))
    az=np.arctan2(dense[:,1],dense[:,0]);el=np.arctan2(dense[:,2],np.hypot(dense[:,0],dense[:,1]))
    source=np.column_stack(((az*180/np.pi+360)%360,el*180/np.pi,np.linalg.norm(dense,axis=1)))
    delays=np.column_stack([offaxis(p,source[:,:2]*np.pi/180) for p in parameters])
    inverse = np.linalg.inv(points[faces].transpose(0,2,1))
    output=np.empty((len(dense),2,ir.shape[-1]))
    for i,point in enumerate(dense):
        face,weights=vbap_weights(point,points,faces,inverse)
        for ch in range(2):
            values=aligned[face,ch,:].T@weights
            shift=int(matlab_round((delays[i,ch]-parameters[ch,4])*fs))
            output[i,ch]=np.roll(values,shift)
        if (i+1)%500==0:
            logger(f'Spatially interpolated {i+1}/{len(dense)} directions.')
    diagnostics.update(parameters=parameters,normalization_gain=gain)
    return output,source,delays,diagnostics

# AMT deleteoutliers: Brett Shoelson, Ph.D. (2003). Original MATLAB routine
# distributed with AMT 1.6.0; see the reference archive and GPL notice above.
