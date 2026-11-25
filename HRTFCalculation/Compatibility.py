"""Version compatibility only; remove in a future release."""
from __future__ import annotations

import codecs
import copy
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

import yaml

DEPRECATION = "Deprecated; use ear_distance. Will be removed in a future version."
LEGACY_DISTANCE_IMPORTED = "Imported legacy preprocessing.head_radius as ear_distance. Save the project or run Pinna2HRTF migrate-settings to update the file."


def import_legacy_distance(data):
    """Version compatibility only; remove in a future release."""
    result = copy.deepcopy(data)
    settings = result.get("preprocessing", {})
    if isinstance(settings, dict) and "head_radius" in settings:
        legacy = settings.pop("head_radius")
        if "ear_distance" not in settings:
            settings["ear_distance"] = legacy
    return result



REMOVED_HEAD_SETTINGS = {
    "head_adaptive_ovalness", "head_ovalness_strength", "head_min_width_scale", "head_max_height_scale",
    "headAdaptiveOvalness", "headOvalnessStrength", "headMinWidthScale", "headMaxHeightScale",
    "HeadAdaptiveOvalness", "HeadOvalnessStrength", "HeadMinWidthScale", "HeadMaxHeightScale",
}
LEGACY_HEAD_TAPER = {
    "head_y_deformation": "head_taper_percent",
    "headYDeformation": "headTaperPercent",
    "HeadYDeformation": "HeadTaperPercent",
}


def migrate_head_settings(value):
    import math
    notices = set()

    def migrate(item):
        if isinstance(item, list):
            return [migrate(child) for child in item]
        if not isinstance(item, dict):
            return item
        result = {}
        for key, child in item.items():
            if key in REMOVED_HEAD_SETTINGS:
                notices.add("Removed retired adaptive head-shape settings; head adaptation is no longer applied.")
                continue
            if key in LEGACY_HEAD_TAPER:
                continue
            if key in ("PreservedConfigJSON", "preservedConfigJSON") and isinstance(child, str) and child.strip():
                parsed = json.loads(child)
                updated = migrate(parsed)
                result[key] = json.dumps(updated, ensure_ascii=False, allow_nan=False) if updated != parsed else child
            else:
                result[key] = migrate(child)
        for legacy, current in LEGACY_HEAD_TAPER.items():
            if legacy not in item:
                continue
            if current not in result:
                raw = item[legacy]
                if isinstance(raw, bool) or not isinstance(raw, (str, int, float)):
                    raise ValueError("Legacy head deformation must be a finite number.")
                number = float(raw) * 10000
                if not math.isfinite(number):
                    raise ValueError("Legacy head deformation must be a finite number.")
                result[current] = format(number, ".15g") if isinstance(raw, str) else number
            notices.add("Converted legacy head deformation to Head taper (%): 0.01 per mm equals 100%.")
        return result

    return migrate(value), sorted(notices)


def import_legacy_head_settings(value):
    import warnings
    migrated, notices = migrate_head_settings(value)
    for notice in notices:
        warnings.warn(notice, UserWarning, stacklevel=2)
    return migrated

def read_settings(path):
    return decode_settings(Path(path).read_bytes())


def decode_settings(raw):
    if raw.startswith(codecs.BOM_UTF8):
        encoding = "utf-8-sig"
    elif raw.startswith(codecs.BOM_UTF16_LE):
        encoding = "utf-16-le"
    elif raw.startswith(codecs.BOM_UTF16_BE):
        encoding = "utf-16-be"
    else:
        try:
            raw.decode("utf-8")
            encoding = "utf-8"
        except UnicodeDecodeError:
            try:
                raw.decode("cp1252")
                encoding = "cp1252"
            except UnicodeDecodeError:
                encoding = "latin-1"
    return raw, raw.decode(encoding), encoding


def annotate_legacy_distance(path, text, encoding, raw):
    """Version compatibility only; remove in a future release.

    Called only after the full settings file has passed model validation.
    Edit YAML nodes in place so unrelated comments and formatting survive.
    """
    tree = yaml.compose(text)
    if not isinstance(tree, yaml.MappingNode):
        return False
    settings = next((v for k, v in tree.value if k.value == "preprocessing"), None)
    if not isinstance(settings, yaml.MappingNode):
        return False
    legacy = next(((k, v) for k, v in settings.value if k.value == "head_radius"), None)
    if legacy is None:
        return False
    has_distance = any(k.value == "ear_distance" for k, _ in settings.value)
    key, value = legacy
    newline = "\r\n" if "\r\n" in text else "\r" if "\r" in text else "\n"
    lines = text.splitlines(keepends=True)
    if settings.flow_style:
        entries = []
        for k, v in settings.value:
            entry = text[k.start_mark.index:v.end_mark.index]
            if k.value == "head_radius":
                entry += " # " + DEPRECATION
            entries.append(entry)
        settings_key = next(k for k, v in tree.value if v is settings)
        indent = " " * (settings_key.start_mark.column + 2)
        entries = [indent + entry for entry in entries]
        if not has_distance:
            entries.append(indent + "ear_distance: " + text[value.start_mark.index:value.end_mark.index])
        replacement = newline + newline.join(entries) + newline
        updated = text[:settings.start_mark.index] + replacement + text[settings.end_mark.index:]
    else:
        index = key.start_mark.line
        if key.start_mark.line != value.end_mark.line:
            raise ValueError("Legacy head_radius must be a scalar on one line.")
        line = lines[index]
        if DEPRECATION not in line:
            ending = line[len(line.rstrip("\r\n")):]
            lines[index] = line.rstrip("\r\n") + ("; " if "#" in line[value.end_mark.column:] else " # ") + DEPRECATION + ending
        if not has_distance:
            scalar = text[value.start_mark.index:value.end_mark.index]
            if not lines[index].endswith(("\r", "\n")):
                lines[index] += newline
            lines.insert(index + 1, " " * key.start_mark.column + "ear_distance: " + scalar + newline)
        updated = "".join(lines)
    if updated == text:
        return False
    if import_legacy_distance(yaml.safe_load(updated)) != import_legacy_distance(yaml.safe_load(text)):
        raise ValueError("Compatibility annotation changed settings unexpectedly.")
    path = Path(path)
    backup = path.with_name(path.name + ".head-radius-compat.bak")
    temporary = None
    try:
        if path.read_bytes() != raw:
            raise OSError("Settings changed while loading; original file was preserved.")
        if not path.stat().st_mode & 0o222:
            raise PermissionError("Settings file is read-only.")
        if not backup.exists():
            with backup.open("xb") as file:
                file.write(raw)
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=path.name + ".", suffix=".tmp", delete=False) as file:
            temporary = Path(file.name)
            file.write(updated.encode(encoding))
        shutil.copymode(path, temporary)
        if path.read_bytes() != raw:
            raise OSError("Settings changed while loading; original file was preserved.")
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()
    return True


def main():
    import argparse
    from .Config import PipelineConfig
    parser = argparse.ArgumentParser(description="Rewrite a legacy preprocessing.head_radius setting as ear_distance. The original file is kept as <name>.head-radius-compat.bak.")
    parser.add_argument("path")
    args = parser.parse_args()
    path = Path(args.path).expanduser().resolve()
    try:
        raw, text, encoding = read_settings(path)
        config = PipelineConfig.model_validate(import_legacy_distance(yaml.safe_load(text) or {}))
        migrated = annotate_legacy_distance(path, text, encoding, raw)
    except (OSError, ValueError, yaml.YAMLError) as error:
        print(json.dumps({"error": type(error).__name__, "message": str(error)}), file=sys.stderr)
        raise SystemExit(1) from None
    print(json.dumps({"path": str(path), "migrated": migrated, "ear_distance": config.preprocessing.ear_distance}))


if __name__ == "__main__":
    main()
