"""Windows filename compatibility for sofar's netCDF context manager.

libnetcdf's Windows narrow-path check uses the active code page, even when
Python's filesystem encoding is UTF-8 (Unidata/netcdf4-python#1482).
"""
from contextlib import contextmanager
import os
from pathlib import Path
import tempfile

_installed = False


def install_windows_paths():
    global _installed
    if os.name != "nt" or _installed:
        return
    import sofar.io
    import importlib
    from netCDF4 import Dataset

    @contextmanager
    def windows_dataset(filename, mode="r", *args, **kwargs):
        path = Path(filename)
        try:
            str(path).encode("mbcs", errors="strict")
            native_path = True
        except UnicodeEncodeError:
            native_path = False
        if native_path:
            kwargs.setdefault("encoding", "mbcs")
            with Dataset(str(path), mode, *args, **kwargs) as dataset:
                yield dataset
            return
        # Names outside the active Windows code page use native Python file I/O
        # and netCDF's in-memory API. No system locale or process cwd is changed.
        if mode == "r":
            with Dataset("Pinna2HRTF-memory.sofa", mode, *args, memory=path.read_bytes(), **kwargs) as dataset:
                yield dataset
            return
        if mode != "w":
            raise ValueError("Unsupported SOFA open mode: " + mode)
        dataset = Dataset("Pinna2HRTF-memory.sofa", mode, *args, memory=1024, **kwargs)
        payload = None
        temporary = None
        try:
            yield dataset
            payload = dataset.close()
            dataset = None
            with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".pinna-sofa-", suffix=".tmp", delete=False) as stream:
                temporary = Path(stream.name)
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
        finally:
            if dataset is not None:
                data = dataset.close()
                if data is not None: data.release()
            if payload is not None: payload.release()
            if temporary is not None and temporary.exists(): temporary.unlink()

    sofar.io.Dataset = windows_dataset
    def windows_reader(filename, mode="r", *args, **kwargs):
        if mode != "r":
            raise ValueError("SOFA streaming is read-only.")
        try:
            str(filename).encode("mbcs", errors="strict")
        except UnicodeEncodeError:
            return Dataset("Pinna2HRTF-memory.sofa", mode, *args, memory=Path(filename).read_bytes(), **kwargs)
        kwargs.setdefault("encoding", "mbcs")
        return Dataset(str(filename), mode, *args, **kwargs)
    importlib.import_module("sofar.sofastream").Dataset = windows_reader
    importlib.import_module("mesh2hrtf.Output2HRTF.inspect_sofa_files").Dataset = windows_reader
    _installed = True
