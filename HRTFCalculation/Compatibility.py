"""Version compatibility only; remove with v2.0.0."""
from __future__ import annotations

import codecs
import copy
import json
import os
from pathlib import Path
import shutil
import tempfile
import warnings

import yaml

DEPRECATION = "Deprecated; use ear_distance. Will be removed in a future version."


def import_legacy_distance(data):
    """Version compatibility only; remove with v2.0.0."""
    result = copy.deepcopy(data)
    settings = result.get("preprocessing", {})
    if isinstance(settings, dict) and "head_radius" in settings:
        # Version compatibility only; remove with v2.0.0.
        legacy = settings.pop("head_radius")
        if "ear_distance" not in settings:
            settings["ear_distance"] = legacy
    return result


def read_settings(path):
    raw = Path(path).read_bytes()
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
            encoding = "cp1252"
    return raw, raw.decode(encoding), encoding


def annotate_legacy_distance(path, text, encoding, raw):
    """Version compatibility only; remove with v2.0.0.

    Called only after the full settings file has passed model validation.
    Edit YAML nodes in place so unrelated comments and formatting survive.
    """
    tree = yaml.compose(text)
    if not isinstance(tree, yaml.MappingNode):
        return
    settings = next((v for k, v in tree.value if k.value == "preprocessing"), None)
    if not isinstance(settings, yaml.MappingNode):
        return
    legacy = next(((k, v) for k, v in settings.value if k.value == "head_radius"), None)
    if legacy is None:
        return
    has_distance = any(k.value == "ear_distance" for k, _ in settings.value)
    key, value = legacy
    newline = "\r\n" if "\r\n" in text else "\r" if "\r" in text else "\n"
    lines = text.splitlines(keepends=True)
    if settings.flow_style:
        # Expand only this mapping: an inline YAML comment would swallow its
        # closing brace and following members.
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
        return
    # Never replace a concurrently edited file or write unparseable YAML.
    if import_legacy_distance(yaml.safe_load(updated)) != import_legacy_distance(yaml.safe_load(text)):
        raise ValueError("Compatibility annotation changed settings unexpectedly.")
    path = Path(path)
    backup = path.with_name(path.name + ".head-radius-compat.bak")
    temporary = None
    try:
        if path.read_bytes() != raw:
            raise OSError("Settings changed while loading; original file was preserved.")
        # Respect read-only files even where directory replacement is permitted.
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


def main():
    """Native apps use this loader so compatibility edits share one implementation."""
    import argparse
    from .Config import load_config
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path")
    args = parser.parse_args()
    with warnings.catch_warnings(record=True) as notices:
        warnings.simplefilter("always")
        config = load_config(args.path)
    print(json.dumps({"ear_distance": config.preprocessing.ear_distance,
                      "warnings": [str(item.message) for item in notices]}))


if __name__ == "__main__":
    main()
