# Pinna2HRTF

<img src="website/assets/app-icon.webp" alt="Pinna2HRTF app icon" width="96">

Calculate individualized HRTFs and HRIRs from pinna meshes and export them as SOFA files. Available as a macOS or Windows app and a Python CLI.

[Download](https://github.com/Any2HRTF/Pinna2HRTF/releases) · [Documentation](https://any2hrtf.github.io/Pinna2HRTF/docs/)

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

## Desktop default operations

The public machine command `Pinna2HRTF project new-defaults` accepts JSON on stdin with `parent`, `index`, and a `defaults` object containing integer `minimum_frequency`, `maximum_frequency`, `frequency_steps`, `max_instances`, `max_cpu_load`, and optional `evaluation_grid`. It returns a unique `save_location` and validated `preprocessing` and `numcalc` defaults without creating a project folder.

`Pinna2HRTF project validate-grid` accepts `{"path":"..."}` and returns the resolved folder when it contains Nodes.txt and Elements.txt. Both commands return JSON errors and nonzero status on failure.
