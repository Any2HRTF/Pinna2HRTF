"""File fingerprints used by geometry provenance records."""
import hashlib
import json
import os
import sys
import uuid
from pathlib import Path


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


_sha256_cache = None
_CACHE_LIMIT = 4096


def _cache_file():
    if os.name == "nt":
        base = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local")
    elif sys.platform == "darwin":
        base = Path.home() / "Library" / "Caches"
    else:
        base = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
    return base / "Pinna2HRTF" / "sha256-cache.json"


def _load_cache():
    global _sha256_cache
    if _sha256_cache is None:
        try:
            loaded = json.loads(_cache_file().read_text(encoding="utf-8"))
            _sha256_cache = loaded if isinstance(loaded, dict) else {}
        except (OSError, ValueError):
            _sha256_cache = {}
    return _sha256_cache


def _store_cache(cache):
    path = _cache_file()
    entries = dict(list(cache.items())[-_CACHE_LIMIT:])
    staged = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        staged.write_text(json.dumps(entries), encoding="utf-8")
        os.replace(staged, path)
    except OSError:
        pass
    finally:
        staged.unlink(missing_ok=True)


def cached_sha256(path):
    """sha256 reused across processes while path, inode, size, mtime and ctime are unchanged."""
    resolved = Path(path).resolve()
    def identity():
        info = resolved.stat()
        return f"{resolved}|{info.st_ino}|{info.st_size}|{info.st_mtime_ns}|{info.st_ctime_ns}"
    key = identity()
    cache = _load_cache()
    digest = cache.get(key)
    if not isinstance(digest, str):
        digest = sha256(resolved)
        if identity() == key:
            cache[key] = digest
            _store_cache(cache)
    return digest


def file_identity(path):
    stat = Path(path).stat()
    return {"size": stat.st_size, "mtime": stat.st_mtime}
