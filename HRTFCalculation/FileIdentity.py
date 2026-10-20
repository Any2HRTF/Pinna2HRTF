"""File fingerprints used by geometry provenance records."""
import hashlib
from pathlib import Path


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_identity(path):
    stat = Path(path).stat()
    return {"size": stat.st_size, "mtime": stat.st_mtime}
