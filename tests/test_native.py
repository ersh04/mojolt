"""Compile native platform boundaries with strict C11 diagnostics."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NativeThreadingTests(unittest.TestCase):
    def test_native_lifecycle_and_notifications(self):
        with tempfile.TemporaryDirectory(prefix="mojolt-native-") as directory:
            target = str(Path(directory) / "native-test")
            subprocess.run([
                os.environ.get("CC", "cc"), "-std=c11", "-Wall", "-Wextra",
                "-Werror", "-pedantic", "-pthread", "-I", str(ROOT / "native"),
                str(ROOT / "tests/native_threading.c"),
                str(ROOT / "native/threading.c"), str(ROOT / "native/control.c"),
                "-o", target,
            ], check=True, timeout=30)
            subprocess.run([target], check=True, timeout=15)

    def test_mojo_native_interoperability(self):
        result = subprocess.run([str(ROOT / "build/thread-interop")],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ok native Mojo interoperability", result.stdout)
