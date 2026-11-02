"""File fingerprints used by geometry provenance records."""
import hashlib
from pathlib import Path


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


_sha256_cache = {}


def cached_sha256(path):
    """sha256 reused within this process while path, size and mtime are unchanged."""
    resolved = Path(path).resolve()
    stat = resolved.stat()
    key = (str(resolved), stat.st_size, stat.st_mtime_ns)
    if key not in _sha256_cache:
        _sha256_cache[key] = sha256(resolved)
    return _sha256_cache[key]


def file_identity(path):
    stat = Path(path).stat()
    return {"size": stat.st_size, "mtime": stat.st_mtime}
