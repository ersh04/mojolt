"""Run each compiled Mojo regression as an independent unittest case."""
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MojoRegressionTests(unittest.TestCase):
    pass


def make_case(executable, name):
    def run(self):
        result = subprocess.run([str(ROOT / "build" / executable), name], capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ok " + name, result.stdout)
    return run


for executable in ("unit", "protocol", "libc", "workers"):
    source = ROOT / "tests" / (executable + ".mojo")
    for name in re.findall(r"^def (test_\w+)\(", source.read_text(), re.MULTILINE):
        setattr(MojoRegressionTests, "test_" + executable + "_" + name[5:], make_case(executable, name))
