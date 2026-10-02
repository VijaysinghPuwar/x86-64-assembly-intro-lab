#!/usr/bin/env python3
"""Stress test for asm-hexdump: many sizes, byte patterns and repeated runs,
each compared against an independent reference. Deterministic for a given seed.

    python3 tests/stress.py [--seed N] [--large-mib N]

Every failure prints the seed, size and pattern needed to reproduce it.
"""

import argparse
import random
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from support import (C_LOCALE, FLUSH_LINES, HEXDUMP, IN_SIZE, SYSTEM_HEXDUMP,
                     reference_hexdump)

PATTERNS = {
    "zeros": lambda rng, n: bytes(n),
    "ff": lambda rng, n: b"\xff" * n,
    "high-bit": lambda rng, n: bytes(rng.randrange(0x80, 0x100) for _ in range(n)),
    "cycle": lambda rng, n: bytes(i & 0xFF for i in range(n)),
    "ascii": lambda rng, n: bytes(rng.randrange(0x20, 0x7F) for _ in range(n)),
    "random": lambda rng, n: rng.randbytes(n),
}


class Stress:
    def __init__(self, seed, workdir):
        self.seed = seed
        self.dir = workdir
        self.runs = 0
        self.failures = []

    def check(self, label, data, path=None, args=(), stdin=None):
        """Run asm-hexdump on data (as a file, or stdin) and compare."""
        if path is None and stdin is None:
            path = self.dir / "input.bin"
        if path is not None:
            path.write_bytes(data)
        cmd = [str(HEXDUMP), *args] + ([str(path)] if path is not None else [])
        self.runs += 1
        try:
            result = subprocess.run(cmd, input=stdin, capture_output=True, timeout=120)
        except subprocess.TimeoutExpired:
            return self.fail(label, len(data), "timed out (hang?)")
        if result.returncode < 0:
            return self.fail(label, len(data), f"killed by signal {-result.returncode}")
        if result.returncode != 0 or result.stderr:
            return self.fail(label, len(data),
                             f"exit {result.returncode}, stderr {result.stderr[:200]!r}")
        expected = reference_hexdump(data)
        if result.stdout != expected:
            n = next((i for i, (a, b) in enumerate(zip(result.stdout, expected)) if a != b),
                     min(len(result.stdout), len(expected)))
            return self.fail(label, len(data),
                             f"output differs at byte {n} (got {len(result.stdout)} bytes, "
                             f"expected {len(expected)})")
        return result.stdout

    def fail(self, label, size, why):
        self.failures.append(f"seed={self.seed} pattern={label} size={size}: {why}")
        print(f"FAIL {self.failures[-1]}", flush=True)
        return None


def sizes_to_test():
    sizes = set(range(0, 2 * FLUSH_LINES * 16 + 64))   # every size through two flushes
    for k in range(1, 9):                 # around each read-buffer multiple
        for d in (-17, -16, -15, -1, 0, 1, 15, 16, 17):
            sizes.add(k * IN_SIZE + d)
    for lines in range(1, 8 * FLUSH_LINES):            # every line count up to 8 flushes
        sizes.add(lines * 16)
    return sorted(s for s in sizes if s >= 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--seed", type=int, default=20250723)
    parser.add_argument("--large-mib", type=int, default=16)
    args = parser.parse_args()

    if not HEXDUMP.exists():
        sys.exit(f"{HEXDUMP} not built; run `make` first")

    rng = random.Random(args.seed)
    start = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="asm-hexdump-stress-") as tmp:
        s = Stress(args.seed, Path(tmp))

        sizes = sizes_to_test()
        for size in sizes:
            name = rng.choice(list(PATTERNS))
            s.check(name, PATTERNS[name](rng, size))
        print(f"sizes: {len(sizes)} distinct input sizes, 0..{sizes[-1]} bytes")

        for name, make in PATTERNS.items():
            for size in (IN_SIZE - 1, IN_SIZE, IN_SIZE + 1, 5 * IN_SIZE + 7):
                s.check(name, make(rng, size))
        print(f"patterns: {len(PATTERNS)} byte patterns at buffer boundaries")

        for _ in range(300):
            data = rng.randbytes(rng.randrange(0, 64 * 1024))
            s.check("random-stdin", data, stdin=data)
        print("stdin: 300 random inputs up to 64 KiB through a pipe")

        data = rng.randbytes(3000)
        first = s.check("repeat", data)
        for _ in range(500):
            if s.check("repeat", data) != first:
                s.fail("repeat", len(data), "output changed between runs")
                break
        print("repeat: 501 runs on the same input, identical output")

        for name in ("with space.bin", "x" * 255, "-dash", "ünicode-é.bin",
                     "tab\there", "new\nline"):
            s.check(f"name:{name!r}", rng.randbytes(100), path=s.dir / name)
        deep = s.dir.joinpath(*["d" * 200] * 15)
        deep.mkdir(parents=True)
        s.check("deep-path", rng.randbytes(100), path=deep / "f.bin")
        print(f"paths: unusual names and a {len(str(deep))}-byte path")

        big = rng.randbytes(args.large_mib * 1024 * 1024)
        out = s.check("large-random", big)
        if out is not None and SYSTEM_HEXDUMP:
            path = s.dir / "input.bin"
            theirs = subprocess.run([SYSTEM_HEXDUMP, "-C", "-v", str(path)],
                                    capture_output=True, env=C_LOCALE)
            if theirs.returncode != 0 or theirs.stdout != out:
                s.fail("large-random", len(big), "differs from system hexdump -C -v")
        print(f"large: {args.large_mib} MiB random file"
              + (" (also checked against system hexdump)" if SYSTEM_HEXDUMP else ""))

    elapsed = time.monotonic() - start
    print(f"\n{s.runs} runs in {elapsed:.1f}s, {len(s.failures)} failures (seed {args.seed})")
    sys.exit(1 if s.failures else 0)


if __name__ == "__main__":
    main()
