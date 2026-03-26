# HRTF Calculation Pipeline

## Project Structure
All the scripts require the data to be present in a particular structure. If the root directory is e.g. `Data` the following subdirecties with matching names have to be present:
```
Target STL Left
Target STL Right
```
In `Target STL Left` and `Target STL Right` the cut out ears of the subjects with matching ids should be put in `stl` file format.

### Installation
Create a Python 3.11 environmnet with all the dependencies listed in `pyproject.toml` installed. If using uv run:
```
$ uv sync
```
Moreover, install [hrtf_mesh_grading](https://github.com/cg-tub/hrtf_mesh_grading) and [Mesh2HRTF](https://github.com/Any2HRTF/Mesh2HRTF).

## Inference
### Run
With the environment mentioned above activated, run the inference script and pass it the path to the directory with the directories mentioned above.
```
$ uv run hrtf-inference --data_dir /path/to/Data
```
### Output
The inference script performs the automated registration of the scanned ears and creates the following directories:
```
Prediction Parameters Left
Prediction Parameters Right
Prediction STL Left
Prediction STL Right
```
## Calculation of the HRTFs
### Run the Preprocessing

To run the full preprocessing pipeline in one command:
```
$ uv run hrtf-preprocessing --left-path "path/to/left/ear.stl" --right-path "path/to/right/ear.stl" --export-path "path/to/export/project" --mesh-grading-executable "path/to/hrtf_mesh_grading" --Mesh2HRTF-path "path/to/Mesh2HRTF/mesh2hrtf"
```

First, create the heads:
```
$ uv run python HRTFCalculation/Preprocessing/src/create_head.py --left_path "path/to/left/ear.stl" --right_path "path/to/right/ear.stl" --export_path "path/to/export.stl"
```
Then perform for both sides and target as well as prediction data individually:
(Note that closing the ear canal is necessary for the predicted PPM ears, it might not be necessary for the target ears)
```
$ uv run python HRTFCalculation/Preprocessing/src/ear_canal_closer.py --ear_path "path/to/ear.stl" --export_path "path/to/export.stl"
$ uv run python HRTFCalculation/Preprocessing/src/cut_eararea.py --head_path "path/to/head.stl" --ear_path "path/to/closed/ear.stl" --export_path "path/to/export.stl"
$ uv run python HRTFCalculation/Preprocessing/src/head_stitcher.py --head_path "path/to/cut/head.stl" --ear_path "path/to/closed/ear.stl" --export_path "path/to/export.stl"
```
Then run `hrtf_mesh_grading` for the left and right sides of the resulting mesh.
The script `Preprocessing/src/material_assign_and_mesh2input.py` will set microphone positions and export the project for NumCalc calculations.
Please refere to the [mesh2hrtf documentation](https://github.com/Any2HRTF/Mesh2HRTF/wiki/Basic_Project_export#final-export-from-blender) for detailed information about the arguments. Though, strictly necessary are the following:
```
head: "path/to/graded/head.ply"
sourceType: "Left ear" or "Right ear"
filepath: p.ex. "Target Left", i.e. output path
programPath: "path/to/Mesh2HRTF/mesh2hrtf"
minFrequency: p.ex. 0
maxFrequency: p.ex. 24000
frequencyVectorType: "Step size" or "Num steps"
frequencyVectorValue: int for Step size or Num steps
```
Next, run NumCalc on the project foldes created in filepath to calculate the HRTFs.
To finalize the projects, use the [mesh2hrtf python API](https://mesh2hrtf.readthedocs.io/en/latest/mesh2hrtf.html):
'''
mesh2hrtf.output2hrtf(/path/to/projectfolder)
mesh2hrtf.merge_sofa_files(/paths/to/projectfolders)
'''

### Output
The preprocessing script will, for all subject codes found in "Target STL Left":
1. create an accurately sized dummy head,
2. close the ear canals of the prediction ears,
3. for target and prediction ears and each side respectively, cut an area around the ear and stitch the ear to it,
4. perform the hrtf-mesh-grading algorithm,
5. pick microphone positions, assign the corresponding materials, create according NumCalc projects and start the NumCalc computation.
After this script, four new folders will have been created and filled:
```
Target Left
Target Right
Prediction Left
Prediction Right
```

### Run the Postprocessing
To finalize the project, with the Python environment activated please run 
```
$ uv run hrtf-postprocessing --data_dir /path/to/Data
```
This will create the `SOFA` files in the seperate left and right project folders, potential error results and left & right merged `SOFA` HRTF files in the created folders 
```
Target HRTF
Prediction HRTF
```

## Citation

If you find our work valuable, please cite

```
@article{
}
```
