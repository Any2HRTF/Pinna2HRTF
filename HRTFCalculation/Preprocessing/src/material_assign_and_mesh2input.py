"""
Estimates the ear canal position for a .ply graded head mesh located in --head,
applies the materials with corresponding naming (check the mesh2hrtf documentation / tutorials for more details),
and uses the mesh2input add-on to export the head and create a project folder in --filepath which is ready for NumCalc.

Lukas Thalhammer, Acoustics Research Institute
September 2024
"""

import argparse
import bpy
import bmesh # type: ignore
import numpy as np


# Check for the mesh2input add-on which is needed for export
def check_addon():
    import addon_utils # type: ignore

    addon_name = 'mesh2input'

    success = addon_utils.enable(addon_name)
    if success:
        print("enabled", success.bl_info['name'])
    else:
        print(addon_name, "is not found")

    return success

def install_addon(path):
    bpy.ops.preferences.addon_install(filepath=path)
    bpy.ops.preferences.addon_enable(module='mesh2input')
    bpy.ops.wm.save_userpref()


def main(head, source_type=None, filepath=None, mesh2hrtf_path=None,
         min_frequency=0, max_frequency=24000, frequency_vector_type="Num steps", frequency_step_count=129, 
         title='PPM model generated HRTF', method='ML-FMM BEM',
         pictures=False, reference=True, computeHRIRs=True, unit='mm', speedOfSound='346.18',
         densityOfMedium='1.1839', evaluationGrids='/Users/felixperfler/Documents/ISF/2026/Pipeline Paper/Paper/Data/Resources/EvalGrid', materialSearchPaths="None",
         tolerance=2, sourceType=None, programPath=None, minFrequency=None, maxFrequency=None, frequencyVectorType=None, frequencyVectorValue=None):
    source_type = source_type or sourceType
    mesh2hrtf_path = mesh2hrtf_path or programPath
    if minFrequency is not None:
        min_frequency = minFrequency
    if maxFrequency is not None:
        max_frequency = maxFrequency
    if frequencyVectorType is not None:
        frequency_vector_type = frequencyVectorType
    if frequencyVectorValue is not None:
        frequency_step_count = frequencyVectorValue
    
    bpy.ops.wm.read_factory_settings(use_empty=True)

    if not check_addon():
        install_addon(mesh2hrtf_path+"/Mesh2Input/mesh2input.py")

    bpy.ops.wm.ply_import(filepath=head)

    me = bpy.context.object.data
    bpy.context.object.name = 'Reference'

    bm = bmesh.new()
    bm.from_mesh(me)
    bm.faces.ensure_lookup_table()

    m_skin = bpy.data.materials.new("Skin")
    m_skin.diffuse_color = (1,1,0,1)
    m_le = bpy.data.materials.new("Left ear")
    m_le.diffuse_color = (0,0,1,1)
    m_re = bpy.data.materials.new("Right ear")
    m_re.diffuse_color = (1,0,0,1)
    me.materials.append(m_skin)
    me.materials.append(m_le)
    me.materials.append(m_re)

    left_index = None
    right_index = None
    left_y = -np.inf
    right_y = np.inf

    for f in bm.faces:
        med = f.calc_center_median()
        f_dist = np.sqrt(med.x**2 + med.z**2)
        if f_dist < tolerance:
            if med.y > left_y:
                left_y = med.y
                left_index = f.index
            if med.y < right_y:
                right_y = med.y
                right_index = f.index

    if left_index is None or right_index is None:
        for f in bm.faces:
            med = f.calc_center_median()
            if med.y > left_y:
                left_y = med.y
                left_index = f.index
            if med.y < right_y:
                right_y = med.y
                right_index = f.index

    bm.faces[left_index].material_index = 1
    bm.faces[right_index].material_index = 2

    bm.to_mesh(me)
    bm.free()

    bpy.ops.mesh2input.inp(
        title=title,
        method=method,
        sourceType=source_type,
        filepath=filepath,
        programPath=mesh2hrtf_path,
        pictures=pictures,
        reference=reference,
        computeHRIRs=computeHRIRs,
        unit=unit,
        speedOfSound=speedOfSound,
        densityOfMedium=densityOfMedium,
        evaluationGrids=evaluationGrids,
        materialSearchPaths=materialSearchPaths,
        minFrequency=min_frequency,
        maxFrequency=max_frequency,
        frequencyVectorType=frequency_vector_type,
        frequencyVectorValue=frequency_step_count
        )

    print("done. ready for NumCalc")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()

    parser.add_argument('--head', type=str, required=True, help='Path to the graded head mesh')
    parser.add_argument('--title', type=str, required=False, default='PPM model generated HRTF', help='Title for the project')
    parser.add_argument('--method', type=str, required=False, default='ML-FMM BEM', help='Method used for the HRTF generation')
    parser.add_argument('--sourceType', type=str, required=True, help='Source type (e.g., Both ears)')
    parser.add_argument('--filepath', type=str, required=True, help='File path to the project')
    parser.add_argument('--programPath', type=str, required=True, help='Path to the mesh2hrtf program')
    parser.add_argument('--pictures', type=str, required=False, default='false', help='Whether to generate pictures')
    parser.add_argument('--reference', type=str, required=False, default='true', help='Whether to include reference')
    parser.add_argument('--computeHRIRs', type=str, required=False, default='true', help='Whether to compute HRIRs')
    parser.add_argument('--unit', type=str, required=False, default='mm', help='Unit of measurement')
    parser.add_argument('--speedOfSound', type=str, required=False, default='346.18', help='Speed of sound in the medium')
    parser.add_argument('--densityOfMedium', type=str, required=False, default='1.1839', help='Density of the medium')
    parser.add_argument('--evaluationGrids', type=str, required=False, default='/Users/felixperfler/Documents/ISF/2026/Pipeline Paper/Paper/Data/Resources/EvalGrid', help='Evaluation grids to use')
    parser.add_argument('--materialSearchPaths', type=str, required=False, default="None", help='Material search paths')
    parser.add_argument('--minFrequency', type=int, required=True, help='Minimum frequency')
    parser.add_argument('--maxFrequency', type=int, required=True, help='Maximum frequency')
    parser.add_argument('--frequencyVectorType', type=str, required=True, help='Type of frequency vector')
    parser.add_argument('--frequencyVectorValue', type=int, required=True, help='Value of frequency vector steps')
    parser.add_argument('--tolerance', type=float, required=False, default=3.5, help='Radius of tolerance for ear canal selection')

    args = parser.parse_args()

    main(head=args.head, title=args.title, method=args.method, sourceType=args.sourceType, filepath=args.filepath, programPath=args.programPath,
         pictures=args.pictures.lower()=='true', reference=args.reference.lower()=='true', computeHRIRs=args.computeHRIRs.lower()=='true',
         unit=args.unit, speedOfSound=args.speedOfSound, densityOfMedium=args.densityOfMedium, evaluationGrids=args.evaluationGrids,
         materialSearchPaths=args.materialSearchPaths, minFrequency=int(args.minFrequency), maxFrequency=int(args.maxFrequency),
         frequencyVectorType=args.frequencyVectorType, frequencyVectorValue=int(args.frequencyVectorValue),
         tolerance=args.tolerance)
