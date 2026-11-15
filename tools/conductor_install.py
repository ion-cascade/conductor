#!/usr/bin/env python3
"""Install and run a versioned, per-user Conductor shared bridge on macOS."""
import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile


IDENTITY = "ion-cascade-conductor"
RELEASE = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)")
DEFAULT_PREFIX = Path.home() / "Library/Application Support/Ion Cascade Conductor"
BRIDGE_TOOLS = ("logic_bridge_server.py", "logic_bridge_relay.py")
SHARE_FILES = (
    "install-keycmds.sh", "uninstall-keycmds.sh", "keycmd-preset.plist",
    "LogicProMCP-Scripter.js", "logic_bounce.py", "logic_bounce_ui.py",
    "logic_ui_jxa.py", "logic_input_source.py", "logic_variants.py",
)
PYTHON = "/usr/bin/python3"


class InstallError(Exception):
    pass


def check_folder(path):
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise InstallError(f"Use a folder you own with mode 700: {path}")


def make_folder(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    check_folder(path)


@contextmanager
def lock_file(path, busy):
    flags = os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW
    with os.fdopen(os.open(path, flags, 0o600), "r+") as file:
        info = os.fstat(file.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise InstallError(f"Unexpected lock file: {path}")
        try:
            fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise InstallError(busy) from exc
        yield file


def version(value):
    if not isinstance(value, str) or not RELEASE.fullmatch(value):
        raise InstallError("Expected a stable release version such as 1.0.0.")
    return value


def read_manifest(directory):
    manifest = json.loads((directory / "manifest.json").read_text())
    if manifest["name"] != IDENTITY:
        raise InstallError("This source tree does not identify itself as Ion Cascade Conductor.")
    return version(manifest["version"])


def read_state(root, missing_ok=False):
    try:
        state = json.loads((root / "selection.json").read_text())
    except FileNotFoundError:
        if missing_ok:
            return {"current": None, "previous": None}
        raise InstallError("No release is selected. Run Scripts/install.sh from the release source.")
    current, previous = version(state["current"]), state["previous"]
    if previous is not None:
        previous = version(previous)
    return {"current": current, "previous": previous}


def release_directory(root, release):
    directory = root / "releases" / version(release)
    check_folder(root / "releases")
    check_folder(directory)
    if read_manifest(directory) != release or not (
        directory / "bin/LogicProMCP"
    ).is_file():
        raise InstallError(f"Installed release {release} is incomplete.")
    return directory


def atomic_write(path, contents, mode=0o600):
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}-", delete=False) as file:
        temporary = Path(file.name)
    try:
        temporary.write_bytes(contents)
        temporary.chmod(mode)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def select_release(root, selected, state):
    release_directory(root, selected)
    if selected != state["current"]:
        selection = {"current": selected, "previous": state["current"]}
        atomic_write(root / "selection.json", (json.dumps(selection) + "\n").encode())
    print(f"Conductor {selected} selected.")


def install(root, source, scratch):
    release = read_manifest(source)
    state = read_state(root, missing_ok=True)
    releases = root / "releases"
    make_folder(releases)
    destination = releases / release
    if destination.exists() or destination.is_symlink():
        raise InstallError(f"Conductor {release} is already installed. Run conductor use {release}.")
    for relative in ["docs/SETUP.md", *(f"tools/{name}" for name in BRIDGE_TOOLS),
                     *(f"Scripts/{name}" for name in SHARE_FILES)]:
        if not (source / relative).is_file():
            raise InstallError(f"The source distribution is missing {relative}.")
    command = ["/usr/bin/xcrun", "swift", "build", "--disable-automatic-resolution", "-c", "release"]
    if scratch:
        command += ["--scratch-path", str(scratch)]
    print(f"Building Conductor {release} from the supplied source.", flush=True)
    subprocess.run(command, cwd=source, check=True)
    binary_directory = Path(subprocess.check_output(command + ["--show-bin-path"], cwd=source, text=True).strip())
    binary = binary_directory / "LogicProMCP"
    built_version = subprocess.check_output([binary, "--version"], text=True, timeout=15).strip()
    if built_version != release:
        raise InstallError(f"The build identifies itself as {built_version}, expected {release}.")
    with tempfile.TemporaryDirectory(prefix=".install-", dir=releases) as staging:
        staged = Path(staging) / release
        staged.mkdir(mode=0o700)
        for name in ["bin", "share", "tools"]:
            (staged / name).mkdir()
        shutil.copy2(binary, staged / "bin/LogicProMCP")
        shutil.copyfile(source / "manifest.json", staged / "manifest.json")
        for name in BRIDGE_TOOLS:
            shutil.copyfile(source / "tools" / name, staged / "tools" / name)
        shutil.copyfile(source / "docs/SETUP.md", staged / "share/SETUP.md")
        for name in SHARE_FILES:
            shutil.copy2(source / "Scripts" / name, staged / "share" / name)
        with lock_file(root / "bridge.lock", "Stop the running bridge before selecting an installed release."):
            atomic_write(root / "conductor", Path(__file__).read_bytes(), 0o700)
            staged.rename(destination)
            try:
                select_release(root, release, state)
            except (InstallError, OSError):
                if read_state(root, missing_ok=True)["current"] != release:
                    destination.rename(staged)
                raise
    print(f'Start in Mac Terminal with "{root / "conductor"}" start')


def runtime_environment(root, directory):
    flags = ("DIRECT_TOOLBAR", "BOUNDED_MIXER_POLL", "DIRECT_MIXER_PANEL", "LOGIC13_TRACKS", "COHERENT_READS")
    return dict(os.environ,
                **{f"LOGIC_MCP_{flag}": "1" for flag in flags},
                LOGIC_MCP_BRIDGE_DIR=str(root),
                LOGIC_MCP_EXECUTABLE=str(directory / "bin/LogicProMCP"),
                LOGIC_PRO_BUNDLE_ID="com.apple.logic10",
                LOGIC_PRO_MCP_SHARE_DIR=str(directory / "share"))


def exec_runtime(root, action, held_lock=None):
    release = read_state(root)["current"]
    directory = release_directory(root, release)
    environment = runtime_environment(root, directory)
    if action == "doctor":
        binary = str(directory / "bin/LogicProMCP")
        os.execve(binary, [binary, "doctor"], environment)
    tool = "logic_bridge_server.py" if action == "start" else "logic_bridge_relay.py"
    if held_lock is not None:
        # Hold the selection lock for the lifetime of the broker. Relay clients
        # resolve only the socket and do not acquire this lock.
        os.set_inheritable(held_lock.fileno(), True)
    os.execve(PYTHON, [PYTHON, str(directory / "tools" / tool)], environment)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    setup = actions.add_parser("install", help="Build, install and select a source release")
    setup.add_argument("--source", type=Path, required=True)
    setup.add_argument("--prefix", type=Path, default=DEFAULT_PREFIX)
    setup.add_argument("--scratch-path", type=Path)
    actions.add_parser("start", help="Run the bridge in Mac Terminal")
    actions.add_parser("relay", help="Connect MCP over stdio to the running bridge")
    actions.add_parser("status", help="Show the selected and previous release")
    actions.add_parser("doctor", help="Check permissions from the current launch context")
    actions.add_parser("rollback", help="Select the previous release")
    use = actions.add_parser("use", help="Select an already installed version")
    use.add_argument("release")
    args = parser.parse_args()
    action = args.action
    if sys.platform != "darwin":
        raise InstallError("Install and run this launcher on the Mac that runs Logic Pro.")
    root = args.prefix.expanduser().absolute() if action == "install" else Path(__file__).resolve().parent
    if len(os.fsencode(root / "bridge.sock")) >= 104:
        raise InstallError("The install path is too long for the bridge socket. Choose a shorter --prefix.")
    if action == "install":
        make_folder(root)
    else:
        check_folder(root)
    if action in ("relay", "doctor"):
        exec_runtime(root, action)
    if action == "status":
        state = read_state(root)
        release_directory(root, state["current"])
        print(f'Selected {state["current"]}')
        print(f'Previous {state["previous"] or "none"}')
        return

    with lock_file(root / "selection.lock", "Stop the running bridge or wait for the current install to finish.") as held:
        if action == "start":
            exec_runtime(root, action, held_lock=held)
        elif action == "install":
            with lock_file(root / "bridge.lock", "Stop the running bridge before installing."):
                pass
            install(root, args.source.resolve(), args.scratch_path.expanduser().resolve() if args.scratch_path else None)
        else:
            with lock_file(root / "bridge.lock", "Stop the running bridge before selecting another release."):
                state = read_state(root)
                selected = state["previous"] if action == "rollback" else args.release
                if selected is None:
                    raise InstallError("There is no previous release to roll back to.")
                select_release(root, selected, state)


if __name__ == "__main__":
    try:
        main()
    except (InstallError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        raise SystemExit(f"Conductor: {error}")
