`locadyn_matlab_reference.npz` contains synthetic HRIRs and outputs from the
unchanged ExpSuite/LocaDyn revision 1948 MATLAB scientific functions bundled
in `HRTFCalculation/Postprocessing/upsample_hrtf.m`. It contains no participant
data. Regenerate with `Tests/generate_locadyn_reference.py` and MATLAB R2024b
plus AMT 1.6.0 (Optimization, Signal Processing, Statistics toolboxes).

Cases cover 64/65 samples, 48/44.1 kHz, normalization off/on and subdivision
levels 0/1. Each contains input IRs, output IRs, positions, and TOA delays.
The archive also records the SHA-256 of the reference MATLAB source.

AMT code-only reference archive SHA-256:
`d6a4395561f79a2470b5cb0bc93323d956a56266a02190824a9d5a1bed0a9fb3`.
Original archive: https://sourceforge.net/projects/amtoolbox/files/AMT%201.x/amtoolbox-1.6.0.zip/download

The generator replaces the argument parser with the three fixed arguments
used by the EvaPPM wrapper and supplies SOFA metadata helpers for an in-memory
struct. It runs the original normalization expression, TOA functions,
minimum-phase transform, subdivision, VBAP interpolation and reconstruction.
MATLAB and Python outputs are compared numerically; bitwise equality is not
expected between their FFT/optimizer implementations.
