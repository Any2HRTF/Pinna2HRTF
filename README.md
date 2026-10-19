<p align="center">
  <img src="icon.png" alt="Pinna2HRTF icon" width="192">
</p>

# Pinna2HRTF

Calculate individualized head-related transfer functions (HRTFs) and impulse responses (HRIRs) from one or two pinna meshes. Available as a macOS or Windows desktop app and a Python CLI.

The pipeline supports optional Mesh2PPM inference, full-head scan preparation and manual ear review, acoustic simulation with Mesh2HRTF and NumCalc, and SOFA export.

## Get the app

Download the latest published desktop installers and checksums from [GitHub Releases](https://github.com/Any2HRTF/Pinna2HRTF/releases).

## Documentation

The [Pinna2HRTF user guide](https://any2hrtf.github.io/Pinna2HRTF/docs/) covers the desktop app, scan preparation and ear editing, CLI setup and YAML configuration, and building from source.

## CLI quick start

Install [uv](https://docs.astral.sh/uv/getting-started/installation/), then clone the repository and sync its locked Python environment:

```sh
git clone https://github.com/Any2HRTF/Pinna2HRTF.git
cd Pinna2HRTF
uv sync --locked --python 3.11
```

Follow the [CLI guide](https://any2hrtf.github.io/Pinna2HRTF/docs/cli.html) to install native tools and run a pipeline.

## License

[European Union Public Licence 1.2](LICENSE). Bundled dependencies retain their own licenses.
