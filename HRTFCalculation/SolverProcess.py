"""Keep a NumCalc child attached to the lifetime of its pipeline parent."""
from __future__ import annotations

import signal
import subprocess
import sys
import time

import psutil


def main() -> int:
    parent_pid = int(sys.argv[1])
    parent_created = float(sys.argv[2])
    command = sys.argv[3:]
    child = None

    def parent_alive():
        try:
            parent = psutil.Process(parent_pid)
            return parent.create_time() == parent_created and parent.status() != psutil.STATUS_ZOMBIE
        except psutil.Error:
            return False

    def stop(signum, frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, stop)
    try:
        if not parent_alive():
            return 1
        child = subprocess.Popen(command)
        while child.poll() is None:
            if not parent_alive():
                return 1
            time.sleep(0.2)
        return child.returncode
    finally:
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()


if __name__ == "__main__":
    raise SystemExit(main())
