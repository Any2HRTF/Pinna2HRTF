import glob
from pathlib import Path

import mesh2hrtf as m2h
import numpy as np
import sofar as sf


def resample_hrir_files(output_dir, sampling_rate=48000):
    """Resample generated HRIR SOFA files to an optional output rate."""
    try:
        rate = int(sampling_rate)
    except (TypeError, ValueError) as error:
        raise ValueError("Sampling rate must be a positive integer divisible by 10 Hz.") from error
    if rate <= 0 or rate % 10:
        raise ValueError("Sampling rate must be a positive integer divisible by 10 Hz.")

    for hrir_path in sorted(Path(output_dir).glob("HRIR_*.sofa")):
        hrir = sf.read_sofa(str(hrir_path))
        current_rate = float(np.asarray(hrir.Data_SamplingRate).reshape(-1)[0])
        if np.isclose(current_rate, rate):
            continue
        resampled = m2h.resample_sofa_file(hrir, rate)
        sf.write_sofa(str(hrir_path), resampled)


def normalize_sofa_files(output_dir, level_offset_db):
    gain = 10 ** (level_offset_db / 20)
    for sofa_path in glob.glob(f"{output_dir}/*.sofa"):
        sofa = sf.read_sofa(sofa_path)
        if hasattr(sofa, "Data_IR"):
            sofa.Data_IR = np.asarray(sofa.Data_IR) * gain
        if hasattr(sofa, "Data_Real"):
            sofa.Data_Real = np.asarray(sofa.Data_Real) * gain
        if hasattr(sofa, "Data_Imag"):
            sofa.Data_Imag = np.asarray(sofa.Data_Imag) * gain
        sofa.GLOBAL_Comment = f"{getattr(sofa, 'GLOBAL_Comment', '')} Broadband level offset of {level_offset_db:g} dB applied during Pinna2HRTF postprocessing.".strip()
        sf.write_sofa(sofa_path, sofa)


def cli():
    """Postprocessing runs only from a pipeline YAML (RunConfig).

    The former standalone mode for the research folder layout
    ("Target Left"/"Prediction Left", deleting "Target HRTF"/"Prediction HRTF")
    was removed; it had no remaining caller.
    """
    raise SystemExit("Use `Pinna2HRTF postprocessing --config <pipeline.yaml>` (or `Pinna2HRTF sofa --config ...`).")


if __name__ == '__main__':
    cli()
