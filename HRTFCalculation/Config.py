from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Any, Literal

import yaml
from pydantic import BaseModel, ConfigDict, Field


def worktree_root() -> Path:
    candidates = []
    env_root = os.environ.get("PINNA2HRTF_ROOT")
    if env_root:
        candidates.append(Path(env_root).expanduser())
    if getattr(sys, "frozen", False):
        candidates.append(Path(sys.executable).resolve())
    candidates.extend([Path.cwd().resolve(), Path(__file__).resolve()])
    for candidate in candidates:
        start = candidate if candidate.is_dir() else candidate.parent
        for root in (start, *start.parents):
            if (root / "Paper").exists() and (root / "External").exists():
                return root
            if root.name == "Pinna2HRTF" and (root.parent / "Paper").exists() and (root.parent / "External").exists():
                return root.parent
    return Path(__file__).resolve().parents[2]


def default_resource(name: str) -> Path:
    return Path(__file__).resolve().parent / "Inference" / "resources" / name


class PathsConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    left_ear: Path = Field(default_factory=lambda: worktree_root() / "Paper" / "Data" / "03 Automatic Stitching" / "Input" / "Target STL Left" / "NH130.stl")
    right_ear: Path = Field(default_factory=lambda: worktree_root() / "Paper" / "Data" / "03 Automatic Stitching" / "Input" / "Target STL Right" / "NH130.stl")
    output_dir: Path = Field(default_factory=lambda: worktree_root() / "Paper" / "Data" / "temp" / "GuiRun")
    external_deps_dir: Path = Field(default_factory=lambda: worktree_root() / "External")
    mesh2hrtf_path: Path | None = None
    numcalc_executable: Path | None = None
    mesh_grading_executable: Path | None = None
    evaluation_grid: str = "Default"


class InferenceConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    enabled: bool = False
    model_config_file: Path = Field(default_factory=lambda: default_resource("Local 9 Views.yaml"))
    model_checkpoint: Path = Field(default_factory=lambda: default_resource("Local 9 Views.pth"))
    target_left_folder: str = "Target STL Left"
    target_right_folder: str = "Target STL Right"
    prediction_left_folder: str = "Prediction STL Left"
    prediction_right_folder: str = "Prediction STL Right"
    prediction_parameters_left_folder: str = "Prediction Parameters Left"
    prediction_parameters_right_folder: str = "Prediction Parameters Right"
    use_predictions_for_preprocessing: bool = True


class PreprocessingConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    enabled: bool = True
    write_intermediates: bool = True
    head_radius_scale: float = 1.01
    head_width_scale: float = 1.5
    head_height_scale: float = 1.5
    head_y_deformation: float = 0.005
    ear_cut_clearance_scale: float = 1.3
    mesh_min_edge_length: float = 0.5
    mesh_max_edge_length: float = 10.0
    mesh_max_error: float = 0.5
    mesh_gamma_left: float = 0.15
    mesh_gamma_right: float = 0.2
    mesh_hole_size: float = 0.2
    source_type_left: str = "Left ear"
    source_type_right: str = "Right ear"
    title: str = "HRTF Simulation"
    method: str = "ML-FMM BEM"
    min_frequency: int = 0
    max_frequency: int = 24000
    frequency_vector_type: str = "Num steps"
    frequency_step_count: int = 129
    compute_hrirs: bool = True
    pictures: bool = False
    reference: bool = True
    unit: str = "mm"
    speed_of_sound: str = "346.18"
    air_density: str = "1.1839"
    material_search_paths: str = "None"
    source_assignment_tolerance: float = 2.0
    source_assignment_mode: Literal["landmark", "legacy_axis"] = "landmark"


class NumCalcConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    enabled: bool = False
    mode: Literal["local", "slurm"] = "local"
    max_instances: int = 1
    max_cpu_load: int = 90
    memory: str = "64G"
    partition: str = "c"
    qos: str = "c_medium"
    time_limit: str = "24:00:00"
    array_concurrency: int = 4


class PostprocessingConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    enabled: bool = False
    output_sofa_dir: Path | None = None
    overwrite: bool = True


class UIConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    last_opened_config: Path | None = None
    last_opened_project: Path | None = None
    mesh_background: str = "white"
    show_axes: bool = True


class PipelineConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    paths: PathsConfig = Field(default_factory=PathsConfig)
    inference: InferenceConfig = Field(default_factory=InferenceConfig)
    preprocessing: PreprocessingConfig = Field(default_factory=PreprocessingConfig)
    numcalc: NumCalcConfig = Field(default_factory=NumCalcConfig)
    postprocessing: PostprocessingConfig = Field(default_factory=PostprocessingConfig)
    ui: UIConfig = Field(default_factory=UIConfig)

    def resolved(self, base_dir: Path | None = None) -> "PipelineConfig":
        clone = self.model_copy(deep=True)
        base = Path(base_dir or Path.cwd()).resolve()
        for section_name in ("paths", "inference", "postprocessing", "ui"):
            section = getattr(clone, section_name)
            for name, value in section:
                if isinstance(value, Path):
                    setattr(section, name, resolve_path(value, base))
                elif value is not None and name.endswith(("_file", "_checkpoint", "_dir", "_project", "_config")) and isinstance(value, Path):
                    setattr(section, name, resolve_path(value, base))
        if clone.paths.mesh2hrtf_path is None:
            clone.paths.mesh2hrtf_path = clone.paths.external_deps_dir / "src" / "Mesh2HRTF" / "mesh2hrtf"
        if clone.paths.numcalc_executable is None:
            clone.paths.numcalc_executable = clone.paths.external_deps_dir / "bin" / "NumCalc"
        if clone.paths.mesh_grading_executable is None:
            clone.paths.mesh_grading_executable = clone.paths.external_deps_dir / "bin" / "hrtf_mesh_grading"
        if clone.postprocessing.output_sofa_dir is None:
            clone.postprocessing.output_sofa_dir = clone.paths.output_dir / "HRTF"
        return clone

    def yaml_dict(self) -> dict[str, Any]:
        return self.model_dump(mode="json", exclude_none=True)


def resolve_path(path: Path, base: Path) -> Path:
    expanded = Path(path).expanduser()
    if expanded.is_absolute():
        return expanded
    return (base / expanded).resolve()


def load_config(path: str | Path) -> PipelineConfig:
    config_path = Path(path).expanduser().resolve()
    with config_path.open("r", encoding="utf-8") as file:
        data = yaml.safe_load(file) or {}
    return PipelineConfig.model_validate(data).resolved(config_path.parent)


def save_config(config: PipelineConfig, path: str | Path) -> None:
    config_path = Path(path).expanduser().resolve()
    config_path.parent.mkdir(parents=True, exist_ok=True)
    with config_path.open("w", encoding="utf-8") as file:
        yaml.safe_dump(config.yaml_dict(), file, sort_keys=False)


def default_config() -> PipelineConfig:
    return PipelineConfig().resolved(worktree_root())
