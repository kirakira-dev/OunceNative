#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check scheduled uniform clamps through native jump tables and Metal execution."""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile


def native_jobs():
    control = bytearray(256)
    control[86] = 5
    jobs = []
    for test in range(1, 4):
        code = [
            (0x00007AB9, 0, 0xA00, 0),  # Output pointer in UR0:1.
            (0x00027919, 0, 0x2500, 0),  # Workgroup X in R2.
            (0x02037824, 8, 0x078E00FF, 0),  # Output byte offset in R3.
            (0x000479C3, 0, 0x2500, 0),  # Workgroup X in UR4.
            (0x0400788C, 3, 0x0BF01070, 0),  # UP0 = UR4 < 3, unsigned.
            (0x02057810, 0xFFFFFFF9 if test == 2 else 256, 0x07FFE0FF, 0),
            (0x04047887, 3, 0x08000000, 0),  # UR4 = UP0 ? UR4 : 3.
            (0x04047899, 2, 0x0800063F, 0),  # Table byte offset.
            (0x04047ABB, 0x00400000, 0x08000800, 0),  # ULDC UR4, c1[UR4].
        ]
        branch = len(code)
        relative = -(branch + 1) * 16
        code.append((0x04007958, relative & 0xFFFFFFFF,
                     0x0B800000 | ((relative >> 32) & 0x3FFFF), 0))
        entries, branches = [], []
        for case in range(4):
            entries.append(len(code) * 16)
            code.append((0x00047802, 100 * (case + 1), 0xF00, 0))
            branches.append(len(code))
            code.append((0, 0, 0, 0))
        end = len(code)
        code.extend([
            (0x03007986, 4, 0x0810AB00, 0),  # Store choice and independent R5 side effect.
            (0x0000794D, 0, 0x03800000, 0),
            (0x00007947, 0xFFFFFFF0, 0x0383FFFF, 0),  # Closing self-branch.
        ])
        for index in branches:
            code[index] = (0x00007947, (end - index - 1) * 16, 0x03800000, 0)
        if test == 3:
            code[3] = (0x00047AB9, 0x00401000, 0x800, 0)  # Unsigned UINT_MAX input.
        c1 = bytearray(68)
        struct.pack_into("<4I", c1, 0, *entries)
        struct.pack_into("<I", c1, 64, 0xFFFFFFFF)
        jobs.append({
            "key": f"{test:016x}", "control_hex": control.hex(),
            "code_hex": b"".join(struct.pack("<4I", *op) for op in code).hex(),
            "c1_hex": c1.hex(), "local": [1, 1, 1], "shared": 0, "local_memory": 0,
            "cbuf": {}, "textures": {}, "root_constants": {}, "native_root_tables": True,
        })
    return jobs


def run(source, compiler, output):
    output.mkdir(parents=True, exist_ok=True)
    cpu = output / "test_uniform_clamp"
    subprocess.run(["clang++", "-std=c++20", "-O2", "-DAMPERE_UNIFORM_CLAMP_STANDALONE",
                    "-I", str(source / "src"),
                    str(source / "src/tests/video_core/ampere_uniform_clamp.cpp"),
                    "-o", str(cpu)], check=True)
    subprocess.run([str(cpu)], check=True)
    cases = native_jobs()
    jobs = output / "jobs.json"
    jobs.write_text(json.dumps(cases, indent=2) + "\n")
    shaders = output / "shaders"
    subprocess.run([str(compiler), str(jobs), str(shaders)], check=True)
    report = [json.loads(line) for line in (shaders / "compile-report.jsonl").read_text().splitlines()]
    if len(report) != 3 or any(item["status"] != "ok" for item in report):
        raise RuntimeError("Expected three successfully compiled native jump-table programs")
    for case in cases:
        path = shaders / f"{case['key']}.spv"
        path.with_suffix(".c1").write_bytes(bytes.fromhex(case["c1_hex"]))
        subprocess.run(["spirv-val", "--target-env", "vulkan1.2", str(path)], check=True)
        subprocess.run(["spirv-cross", str(path), "--msl", "--msl-version", "20300",
                        "--output", str(path.with_suffix(".metal"))], check=True)
    gpu = output / "test_uniform_clamp_gpu"
    subprocess.run(["clang", "-O2", "-fobjc-arc", str(Path(__file__).with_name("uniform_clamp.m")),
                    "-framework", "Foundation", "-framework", "Metal", "-o", str(gpu)], check=True)
    subprocess.run([str(gpu), str(shaders)], check=True, env=dict(os.environ, MTL_DEBUG_LAYER="1"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Patched PokeDinner source root")
    parser.add_argument("compiler", type=Path, help="Built nx2-offline executable")
    parser.add_argument("--output", type=Path, help="Retain generated fixtures and results here")
    args = parser.parse_args()
    if args.output:
        run(args.source.resolve(), args.compiler.resolve(), args.output.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix="ampere-clamp-") as directory:
            run(args.source.resolve(), args.compiler.resolve(), Path(directory))


if __name__ == "__main__":
    main()
