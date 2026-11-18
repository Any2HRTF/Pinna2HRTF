import contextlib
import json
import sys

from .Project import execute


def main():
    with contextlib.redirect_stdout(sys.stderr):
        result = execute(json.load(sys.stdin))
    print(json.dumps(result, allow_nan=False))


if __name__ == "__main__":
    main()
