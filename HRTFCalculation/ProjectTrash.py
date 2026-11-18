import os
import subprocess
import sys
from pathlib import Path


def execute(command):
    path = Path(command["path"])
    if not path.is_absolute() or not path.is_dir() or path.is_symlink():
        raise ValueError("Choose an existing project folder")
    path = path.resolve()
    protected = [Path.home(), Path(__file__).resolve().parent, *(Path(item).resolve() for item in command.get("protected", []) if item)]
    protected.extend(Path.home() / name for name in ("Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Library"))
    if path == path.parent or path.is_mount() or any(item.is_relative_to(path) for item in protected):
        raise ValueError("This folder contains a protected location")
    if not command.get("owned") and not any((path / name).exists() for name in (".pinna2hrtf", "Project Settings.yaml", ".pinna2hrtf_native_run.yaml", ".pinna2hrtf-preprocessing-signature")):
        raise ValueError("The folder has no project ownership information")
    stat = path.stat()
    identity = f"{stat.st_dev:08X}:{stat.st_ino:016X}"
    if command["action"] == "recycle-plan":
        return {"path": str(path), "identity": identity}
    if command["identity"] != identity:
        raise ValueError("The project folder changed after confirmation")
    if os.name == "nt":
        from ctypes import windll
        if windll.kernel32.GetDriveTypeW(path.anchor) != 3:
            raise ValueError("Recycling needs a local fixed drive")
        system = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        env = dict(os.environ, PINNA_RECYCLE_PATH=str(path), PINNA_RECYCLE_ID=identity,
                   PINNA_RECYCLE_HELPER=str(Path(__file__).with_name("ShellRecycle.cs")))
        script = "$ErrorActionPreference = 'Stop'; Add-Type -Path $env:PINNA_RECYCLE_HELPER; [ShellRecycle]::Recycle($env:PINNA_RECYCLE_PATH, $env:PINNA_RECYCLE_ID)"
        subprocess.run([system, "-NoProfile", "-NonInteractive", "-STA", "-Command", script], env=env, check=True)
    elif sys.platform == "darwin":
        script = """function run(args) {
            ObjC.import('Foundation')
            const error = Ref()
            if (!$.NSFileManager.defaultManager.trashItemAtURLResultingItemURLError($.NSURL.fileURLWithPath(args[0]), null, error))
                throw Error(ObjC.unwrap(error[0].localizedDescription))
        }"""
        subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", script, str(path)], stdout=subprocess.DEVNULL, check=True)
    else:
        raise ValueError("System Trash requires macOS or Windows")
    return {"recycled": str(path)}
