#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check Ampere scalar modes through lowering, SPIR-V, MSL and Metal execution."""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile


def native_jobs():
    """Synthetic instructions only; no game dump or captured resources required."""
    control = bytearray(256)
    control[86] = 5  # Compute stage in the native control header.
    jobs = []
    for test in range(1, 11):
        code = [
            (0x00007AB9, 0, 0x00000A00, 0),  # ULDC.64 UR0, c0[0]: output pointer.
            (0x00027919, 0, 0x00002500, 0),  # S2R R2, CTAID.X: input value.
            (0x02037824, 4, 0x078E00FF, 0),  # IMAD R3, R2, 4, RZ: byte offset.
        ]
        if test in (5, 6):
            if test == 5:
                code.append((0x00067AB9, 0x004000C0, 0, 0))  # ULDC.U8 UR6, c1[3].
            else:
                code.extend([
                    (0x000279C3, 0, 0x00002500, 0),  # S2UR UR2, CTAID.X.
                    (0x02067ABB, 0x00400000, 0x08000000, 0),  # ULDC.U8 c1[UR2].
                ])
            code.append((0x00047C45, 6, 0x08201000, 0))  # I2FP.F32.U32 R4, UR6.
        else:
            uniform = test >= 7
            high = test in (2, 4, 8, 10)
            signed = test in (3, 4, 9, 10)
            if uniform:
                code.append((0x000279C3, 0, 0x00002500, 0))
            if high:
                code.append((0x02027899, 16, 0x0800063F, 0) if uniform else
                            (0x02027824, 65536, 0x078E00FF, 0))  # Shift to high half.
            code.append((0x00047D06 if uniform else 0x00047306,
                         2 | (int(high) << 28),
                         0x00101000 | (int(signed) << 10) | (int(uniform) << 27), 0))
        code.extend([
            (0x03007986, 4, 0x0810A900, 0),  # STG [UR0 + R3], R4.
            (0x0000794D, 0, 0x03800000, 0),  # EXIT.
        ])
        jobs.append({
            "key": f"{test:016x}", "control_hex": control.hex(),
            "code_hex": b"".join(struct.pack("<4I", *op) for op in code).hex(),
            "local": [1, 1, 1], "shared": 0, "local_memory": 0,
            "cbuf": {}, "textures": {}, "root_constants": {}, "native_root_tables": True,
        })
    return jobs


def run(source, compiler, output):
    output.mkdir(parents=True, exist_ok=True)
    cpu = output / "test_scalar_modes"
    subprocess.run(["clang++", "-std=c++20", "-O2", "-DAMPERE_SCALAR_MODES_STANDALONE",
                    "-I", str(source / "src"),
                    str(source / "src/tests/video_core/ampere_scalar_modes.cpp"),
                    "-o", str(cpu)], check=True)
    subprocess.run([str(cpu)], check=True)
    jobs = output / "jobs.json"
    jobs.write_text(json.dumps(native_jobs(), indent=2) + "\n")
    spirv = output / "shaders"
    subprocess.run([str(compiler), str(jobs), str(spirv)], check=True)
    report = [json.loads(line) for line in (spirv / "compile-report.jsonl").read_text().splitlines()]
    if len(report) != 10 or any(item["status"] != "ok" for item in report):
        raise RuntimeError("Expected ten successfully compiled native programs")
    for test in range(1, 11):
        path = spirv / f"{test:016x}.spv"
        subprocess.run(["spirv-val", "--target-env", "vulkan1.2", str(path)], check=True)
        subprocess.run(["spirv-cross", str(path), "--msl", "--msl-version", "20300",
                        "--output", str(path.with_suffix(".metal"))], check=True)
    gpu = output / "test_scalar_gpu"
    subprocess.run(["clang", "-O2", "-fobjc-arc", str(Path(__file__).with_name("scalar_modes.m")),
                    "-framework", "Foundation", "-framework", "Metal", "-o", str(gpu)], check=True)
    subprocess.run([str(gpu), str(spirv)], check=True, env=dict(os.environ, MTL_DEBUG_LAYER="1"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Patched PokeDinner source root")
    parser.add_argument("compiler", type=Path, help="Built nx2-offline executable")
    parser.add_argument("--output", type=Path, help="Retain generated fixtures and results here")
    args = parser.parse_args()
    if args.output:
        run(args.source.resolve(), args.compiler.resolve(), args.output.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix="ampere-scalar-") as directory:
            run(args.source.resolve(), args.compiler.resolve(), Path(directory))


if __name__ == "__main__":
    main()
