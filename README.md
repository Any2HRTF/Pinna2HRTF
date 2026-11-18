# Pinna2HRTF

<img src="website/assets/app-icon.webp" alt="Pinna2HRTF app icon" width="96">

Calculate individualized HRTFs and HRIRs from pinna meshes and export them as SOFA files. Available as a macOS or Windows app and a Python CLI.

[Download](https://github.com/Any2HRTF/Pinna2HRTF/releases) · [Documentation](https://any2hrtf.github.io/Pinna2HRTF/docs/)

## Command line

Install the Python project with its Python 3.11 dependencies to use `Pinna2HRTF`. A packaged Mac release provides `Pinna2HRTF.app/Contents/Resources/bin/Pinna2HRTF`. The Windows portable release provides `Pinna2HRTF-CLI.cmd` beside the app. These launchers use the bundled runtime, models, and external tools and accept paths relative to the calling directory. A standalone installation using converted Core ML models needs the matching compiled model and the executable `ppm_predict` on PATH.

```sh
Pinna2HRTF run-config --config "Project Settings.yaml" --stage preprocessing
Pinna2HRTF project duplicate --source ./Listener01 --parent ./Copies --name Listener01-copy
```

Native clients and scripts can pass a JSON object on stdin. One-shot commands emit one JSON reply on stdout. A failed command returns a nonzero exit code and reports diagnostics on stderr. For example, to validate settings without writing them:

```sh
printf '%s\n' '{"config":{}}' | Pinna2HRTF project validate
```

| Command | Request |
|---|---|
| `project load` / `project read` | A settings file `path`. Load returns validated settings and migration warnings. Read returns the original mapping. |
| `project prepare-folder` | An absolute project `path`. Returns whether the folder was created. |
| `project recycle-plan` / `project recycle` | A project `path` and protected locations. Pass the identity returned by the plan when confirming a move to the system Trash. |
| `project save` | A destination `path` and a `config` mapping. |
| `project copy-input` | Input `source` and destination `folder`. The reply contains the selected copy path. |
| `project publish-editor` | Project `root`, a list of `files` with source and destination paths, optional protected paths and expected input SHA-256 hashes. |
| `project stage-status` / `project record-stage` | Current `config` and an inference, preprocessing or postprocessing `stage`. Legacy receipts use their original client for verification. |
| `outputs` | Project `root`, protected `inputs`, optional `output_folder`, and `action` of status, record or reset. Record takes `paths`. Reset accepts a starting `stage`. |
| `output-worker` | Send one JSON line with a root, inputs and stage. After the ready reply, run the stage and send `{"action":"complete"}`. The worker holds the output lock between replies. |
| `mesh` / `pressure` | A single editor or pressure-field request with its `action`. |
| `fit-worker` | One fitting request and reply per line. Send `{"action":"shutdown"}` to close the session. |

## Numerical conventions

The rotation utilities use Shepperd's largest-component pivot near 180 degrees and return quaternions with a nonnegative scalar component. The legacy elliptical ear cut applies the clearance factor twice along x and once along z. Existing meshes and HRTFs depend on that convention.

Spatial interpolation includes the modelled time of arrival in the HRIR samples. The SOFA delay is zero and the report stores arrival times in seconds. Spatial normalization uses frontal RMS 0.01 when enabled. With normalization disabled, interpolation preserves the export level. The LocaDyn implementation retains the MATLAB reference's outlier threshold and least-squares tolerances for reproducibility.

Developers can find coordinate conventions, project and receipt formats, output ownership rules and platform workarounds in [Implementation Notes](docs/Implementation%20Notes.md).

## Citation

If you find our work valuable, please cite:

```bibtex
@inproceedings{PerflerPinna2HRTF2026,
  title={{Pinna2HRTF}: A Pipeline for Automatic Calculation of Head-Related Transfer Functions from Pinna Meshes},
  author={Perfler, Felix and Thalhammer, Lukas and Majdak, Piotr},
  booktitle={Proceedings of Forum Acusticum 2026},
  year={2026},
  address={Graz, Austria},
  url={https://dael.euracoustics.org/confs/fa2026/data/articles/000324.pdf}
}
```

[European Union Public Licence 1.2](LICENSE). Bundled dependencies retain their own licences.
