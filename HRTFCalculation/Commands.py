import argparse
import contextlib
import importlib
import json
import sys


def project():
    parser = argparse.ArgumentParser(prog="Pinna2HRTF project")
    commands = parser.add_subparsers(dest="action", required=True)
    duplicate = commands.add_parser("duplicate")
    for option in ("source", "parent", "name"):
        duplicate.add_argument("--" + option)
    for action in ("new-defaults", "validate-grid", "load", "save", "validate", "validate_outputs", "validate-prepared", "read", "copy-input", "publish-editor", "stage-status", "record-stage", "prepare-folder", "recycle-plan", "recycle"):
        commands.add_parser(action)
    args = vars(parser.parse_args())
    action = args.pop("action")
    if any(args.values()):
        if not all(args.values()):
            parser.error("--source, --parent and --name must be supplied together")
        request = args
    else:
        request = json.load(sys.stdin)
    from .Project import execute
    return execute(dict(request, action=action))


def run_command(command):
    if command == "output-worker":
        argparse.ArgumentParser(prog="Pinna2HRTF output-worker").parse_args()
        from .Outputs import serve
        serve()
        return
    if command == "fit-worker":
        if sys.argv[1:]:
            argparse.ArgumentParser(prog="Pinna2HRTF fit-worker").parse_args()
        with contextlib.redirect_stdout(sys.stderr):
            from .ManualPPMFitting import serve
        serve()
        return
    with contextlib.redirect_stdout(sys.stderr):
        if command == "project":
            result = project()
        else:
            argparse.ArgumentParser(prog=f"Pinna2HRTF {command}").parse_args()
            module = {"mesh": "MeshEditing", "pressure": "PressureField", "outputs": "Outputs"}[command]
            execute = importlib.import_module("." + module, __package__).execute
            result = execute(json.load(sys.stdin))
    print(json.dumps(result, allow_nan=False))


def machine_command(command):
    try:
        run_command(command)
    except Exception as error:
        print(json.dumps({"error": type(error).__name__, "message": str(error)}), file=sys.stderr)
        raise SystemExit(1) from None
