import os
import shutil
import argparse
import glob
import logging
from pathlib import Path

import pandas as pd
import mesh2hrtf as m2h
import numpy as np
import sofar as sf


logger = logging.getLogger(__name__)


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


def main(args):
    print(f"------------------------------------------------------------------------------")
    print(f"\nRunning postprocessing.py for data in: {args.data_dir}\n")
    print(f"------------------------------------------------------------------------------")


    if not os.path.isdir(f"{args.data_dir}/Target HRTF/"):
        os.mkdir(f"{args.data_dir}/Target HRTF/")
    else:
        shutil.rmtree(f"{args.data_dir}/Target HRTF/")
        os.mkdir(f"{args.data_dir}/Target HRTF/")

    if not os.path.isdir(f"{args.data_dir}/Prediction HRTF/"):
        os.mkdir(f"{args.data_dir}/Prediction HRTF/")
    else:
        shutil.rmtree(f"{args.data_dir}/Prediction HRTF/")
        os.mkdir(f"{args.data_dir}/Prediction HRTF/")

    ids = [
        entry for entry in os.listdir(f"{args.data_dir}/Target Left/")
        if os.path.isdir(f"{args.data_dir}/Target Left/{entry}")
    ]

    failed_ids = []
    all_ids = []

    for id in ids:
        all_ids.append(id)
        for scan_type in ["Target", "Prediction"]:
            direction_failed = False
            try:
                for direction in ["Left", "Right"]:
                    print(f"-------------------------------")
                    print(f"Processing {direction} for {id} of {scan_type}")
                    print(f"-------------------------------")
                    try:
                        path = f"{args.data_dir}/{scan_type} {direction}"
                        project_path = f"{path}/{id}"
                        m2h.output2hrtf(project_path)
                        if args.resample_hrirs:
                            resample_hrir_files(f"{project_path}/Output2HRTF", args.sampling_rate)
                        if args.normalize:
                            normalize_sofa_files(f"{path}/{id}/Output2HRTF", args.level_offset_db)
                        if os.path.isfile(f'{path}/{id}/Output2HRTF/report_issues.txt'):
                            direction_failed = True
                            failed_ids.append(
                                {
                                    "id": id,
                                    "direction": direction,
                                    "scan_type": scan_type,
                                    "reason": "NumCalc non convergence"
                                }
                            )
                    except Exception as exc:
                        direction_failed = True
                        logger.exception("%s for %s (%s) could not be calculated", direction, id, scan_type)
                        failed_ids.append(
                            {
                                "id": id,
                                "direction": direction,
                                "scan_type": scan_type,
                                "reason": f"{type(exc).__name__}: {exc}"
                            }
                        )
                if direction_failed:
                    continue

                export_dir = f"{args.data_dir}/{scan_type} HRTF/{id}"
                os.mkdir(export_dir)
                m2h.merge_sofa_files(
                        [f"{args.data_dir}/{scan_type} Left/{id}", f"{args.data_dir}/{scan_type} Right/{id}"],
                        savedir=export_dir
                    )
                for plane in ["horizontal", "median"]:
                    m2h.inspect_sofa_files(export_dir, pattern="HRIR", plot="3D", plane=plane)
            except Exception as exc:
                logger.exception("ID %s (%s) could not be merged", id, scan_type)
                failed_ids.append(
                    {
                        "id": id,
                        "direction": "Binaural",
                        "scan_type": scan_type,
                        "reason": f"{type(exc).__name__}: {exc}"
                    }
                )

    failed_ids_df = pd.DataFrame(failed_ids)
    failed_ids_df.to_csv(f"{args.data_dir}/failed.csv")

    successfull_ids = []
    failed_ids = set(failed_ids_df["id"]) if not failed_ids_df.empty else set()
    for id in all_ids:
        if id in failed_ids:
            continue
        else:
            successfull_ids.append({"id": id})

    pd.DataFrame(successfull_ids).to_csv(f"{args.data_dir}/successfull.csv")
    print(f"------------------------------------------------------------------------------")
    print(f"\nPostprocessing completed for data in: {args.data_dir}\n")
    print(f"------------------------------------------------------------------------------")

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument('--data_dir', required=True)
    parser.add_argument('--normalize', action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument('--level-offset-db', type=float, default=-30)
    parser.add_argument('--resample-hrirs', action=argparse.BooleanOptionalAction, default=False)
    parser.add_argument('--sampling-rate', type=int, default=48000)
    return parser.parse_args()

def cli():
    args = parse_args()
    main(args)

if __name__ == '__main__':
    cli()
