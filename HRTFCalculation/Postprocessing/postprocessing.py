import os
import shutil
import argparse
import glob

import pandas as pd
import mesh2hrtf as m2h
import numpy as np
import sofar as sf


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

    ids = os.listdir(f"{args.data_dir}/Target Left/")
    
    failed_ids = []
    all_ids = []
    
    for id in ids:
        all_ids.append(id)
        for scan_type in ["Target", "Prediction"]:
            try:
                for direction in ["Left", "Right"]:
                    print(f"-------------------------------")
                    print(f"Processing {direction} for {id} of {scan_type}")
                    print(f"-------------------------------")
                    try:
                        path = f"{args.data_dir}/{scan_type} {direction}"
                        m2h.output2hrtf(f"{path}/{id}")
                        if args.normalize:
                            normalize_sofa_files(f"{path}/{id}/Output2HRTF", args.level_offset_db)
                        if os.path.isfile(f'{path}/{id}/Output2HRTF/report_issues.txt'):
                            failed_ids.append(
                            {
                                "id": id,
                                "direction": direction,
                                "scan_type": scan_type,
                                "reason": "NumCalc non convergence"
                            }
                        )
                    except:
                        print(f"{direction} for {id} could not be calculated")
                        failed_ids.append(
                            {
                                "id": id,
                                "direction": direction,
                                "scan_type": scan_type,
                                "reason": "other"
                            }
                        )
                        
                export_dir = f"{args.data_dir}/{scan_type} HRTF/{id}"
                os.mkdir(export_dir)
                m2h.merge_sofa_files(
                        [f"{args.data_dir}/{scan_type} Left/{id}", f"{args.data_dir}/{scan_type} Right/{id}"],
                        savedir=export_dir
                    )
                for plane in ["horizontal", "median"]:
                    m2h.inspect_sofa_files(export_dir, pattern="HRIR", plot="3D", plane=plane)
            except:
                print(f"ID: {id} could not be calculated")
    
    failed_ids_df = pd.DataFrame(failed_ids)
    failed_ids_df.to_csv(f"{args.data_dir}/failed.csv")

    successfull_ids = []
    try:
        failed_ids = list(set(list(failed_ids_df["id"])))
    except:
        print("No failed calculations 🐩")
        failed_ids = []
    for id in all_ids:
        if id in failed_ids:
            continue
        else:
            successfull_ids.append({"id": id})
    
    pd.DataFrame(successfull_ids).to_csv(f"{args.data_dir}/successfull.csv")
    print(f"------------------------------------------------------------------------------")
    print(f"\nPreprocessing completed for data in: {args.data_dir}\n")
    print(f"------------------------------------------------------------------------------")

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument('--data_dir', required=True)
    parser.add_argument('--normalize', action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument('--level-offset-db', type=float, default=-30)
    return parser.parse_args()

def cli():
    args = parse_args()
    main(args)

if __name__ == '__main__':
    cli()
