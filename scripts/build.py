"""Build the Mojo package and executables using an explicit, reproducible SDK."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"


def run(command):
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    if result.returncode:
        print(result.stdout + result.stderr, file=sys.stderr)
        raise SystemExit(result.returncode)
    # Successful compiler warnings remain visible; they must not hide build errors.
    if result.stderr:
        print(result.stderr, file=sys.stderr)


def main():
    BUILD.mkdir(exist_ok=True)
    compiler = os.environ.get("MOJO") or str(ROOT / ".venv/bin/mojo")
    if not Path(compiler).exists():
        compiler = shutil.which("mojo")
    if not compiler:
        raise SystemExit("Run uv sync first, or set MOJO to a Mojo 1.2.0 executable")
    version = subprocess.check_output([compiler, "--version"], text=True)
    if not version.startswith("Mojo 1.2.0 "):
        raise SystemExit(f"Expected Mojo 1.2.0, got {version.strip()}")
    bridge = BUILD / "transport.o"
    native_objects = []
    for name in ("transport", "threading", "control"):
        output = BUILD / (name + "-native.o")
        run([os.environ.get("CC", "cc"), "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic", "-pthread", "-fPIC", "-c", str(ROOT / "native" / (name + ".c")), "-o", str(output)])
        native_objects.append(str(output))
    # Keep the public link command stable by combining the platform bridges.
    run([os.environ.get("CC", "cc"), "-r", *native_objects, "-o", str(bridge)])
    # Present the existing src/websockets tree under its public package name.
    # main.mojo stays outside the package: executables cannot be precompiled as
    # package members. The symlink tracks source edits without copying a cache.
    source_root = BUILD / "source"
    package = source_root / "mojolt"
    package.mkdir(parents=True, exist_ok=True)
    link = package / "websockets"
    if link.is_symlink() and link.resolve() != (ROOT / "src/websockets").resolve():
        link.unlink()
    if not link.exists():
        link.symlink_to(ROOT / "src/websockets", target_is_directory=True)
    elif not link.is_symlink():
        raise SystemExit(f"Unexpected file at generated package path: {link}")
    (package / "__init__.mojo").write_text((ROOT / "src/__init__.mojo").read_text())
    run([compiler, "precompile", "-I", str(source_root), str(package), "-o", str(BUILD / "mojolt.mojoc")])
    targets = {
        "unit": "tests/unit.mojo", "protocol": "tests/protocol.mojo",
        "libc": "tests/libc.mojo",
        "thread-interop": "tests/thread_interop.mojo",
        "worker-fixture": "tests/worker_fixture.mojo",
        "workers": "tests/workers.mojo",
        "server-fixture": "tests/server_fixture.mojo",
        "client-fixture": "tests/client_fixture.mojo", "echo": "src/main.mojo",
        "example-client": "examples/client.mojo",
        "example-multithreaded": "examples/multithreaded_server.mojo",
    }
    requested = sys.argv[1:] or list(targets)
    for target in requested:
        run([compiler, "build", "-I", str(BUILD), str(ROOT / targets[target]), "-Xlinker", str(bridge), "-o", str(BUILD / target)])
        print(f"Built {target}")


if __name__ == "__main__":
    main()
