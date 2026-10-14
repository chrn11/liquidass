#!/usr/bin/env python3
"""Run shared production C/C++ validators and bounded file transport on Linux."""
from pathlib import Path
import os
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="lg-surface-tests-") as d:
    for test in ("test_surface_contract", "test_surface_diagnostics"):
        binary = Path(d)/test
        subprocess.run([os.environ.get("CC", "clang"), "-std=c11", "-D_GNU_SOURCE",
                        "-Wall", "-Wextra", "-Werror", "-I", str(ROOT/"Shared"),
                        str(ROOT/"scripts"/(test+".c")), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
    src = Path(d)/"abi.cpp"
    src.write_text('#include "LGSurfaceDiagnostics.h"\n#include "LGSurfaceDiagnosticIO.h"\n'
                   'int main(){ LGSurfaceDiagnosticCursor c={}; return c.epoch; }\n')
    subprocess.run(["clang++", "-std=c++17", "-D_GNU_SOURCE", "-Wall", "-Wextra", "-Werror",
                    "-Wno-missing-field-initializers", "-I", str(ROOT/"Shared"),
                    str(src), "-o", str(Path(d)/"abi")], check=True)
for script in ("test_surface_generation.c.py", "test_registry_first_host_generation.py",
               "test_surface_diagnostic_isolation.py"):
    subprocess.run(["python3", str(ROOT/"scripts"/script)], check=True)
print("PASS: all executable surface contract/transport and source guard checks")
