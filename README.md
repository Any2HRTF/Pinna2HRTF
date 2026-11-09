# Pinna2HRTF

Calculate individualized HRTFs and HRIRs from pinna meshes and export them as SOFA files. Available as a macOS or Windows app and a Python CLI.

[Download](https://github.com/Any2HRTF/Pinna2HRTF/releases) · [Documentation](https://any2hrtf.github.io/Pinna2HRTF/docs/)

## Mac development

Open `Pinna2HRTF.xcodeproj` in Xcode and run the `Pinna2HRTF` scheme. The app uses the Python environment and external tools in the checkout. Set them up with `uv sync --locked --no-dev` and `bash Scripts/prepare_external_tools.sh` when needed.

Build the self-contained app with `bash Scripts/build_release_app.sh`. The script uses the Xcode project when full Xcode is available and supports the Command Line Tools build as a fallback.

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
