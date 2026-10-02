"""Shared helpers for the test suite: binary paths, process runner, reference hexdump."""

import os
import re
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / os.environ.get("BUILD", "build")
HEXDUMP = BUILD / "asm-hexdump"


def _asm_define(name):
    text = (ROOT / "src" / "hexdump.asm").read_text()
    return int(re.search(rf"^%define\s+{name}\s+(\d+)", text, re.M).group(1))


# Buffer sizes are read from the source so boundary tests follow any change.
IN_SIZE = _asm_define("IN_SIZE")
OUT_SIZE = _asm_define("OUT_SIZE")
LINE_MAX = _asm_define("LINE_MAX")

# asm-hexdump flushes before formatting a line once more than
# OUT_SIZE - LINE_MAX bytes are pending. Full lines are 79 bytes, so this is
# the number of 16-byte input lines that fit in one flush.
FLUSH_LINES = (OUT_SIZE - LINE_MAX) // 79 + 1


# Pin the C locale so the system hexdump's isprint() treats bytes >= 0x80 as
# unprintable, the same as asm-hexdump and the reference.
C_LOCALE = {**os.environ, "LC_ALL": "C"}


def run(args, stdin=None, input=None, stdout=subprocess.PIPE, timeout=60, **kwargs):
    """Run a command and capture bytes. A hang fails the test via TimeoutExpired."""
    return subprocess.run(
        [str(a) for a in args], stdin=stdin, input=input, stdout=stdout,
        stderr=subprocess.PIPE, timeout=timeout, **kwargs)


def reference_hexdump(data: bytes) -> bytes:
    """Independent Python implementation of `hexdump -C -v` output."""
    out = []
    for offset in range(0, len(data), 16):
        chunk = data[offset:offset + 16]
        hex_cols = "".join(
            f"{b:02x} " + (" " if i == 7 else "") for i, b in enumerate(chunk))
        text = "".join(chr(b) if 0x20 <= b <= 0x7E else "." for b in chunk)
        out.append(f"{offset:08x}  {hex_cols:<49} |{text}|\n")
    if data:
        out.append(f"{len(data):08x}\n")
    return "".join(out).encode()


SYSTEM_HEXDUMP = shutil.which("hexdump")


def emulated() -> bool:
    """True when x86-64 code runs under a user-mode emulator (Rosetta, QEMU).

    Emulators do not reproduce kernel-level behavior such as stack page
    permissions, ASLR of static PIEs, or ptrace, so tests of those skip.
    """
    maps = Path("/proc/self/maps").read_text()
    return "rosetta" in maps or "qemu" in maps


def ptrace_works() -> bool:
    if emulated() or not shutil.which("strace"):
        return False
    probe = run(["strace", "-qq", "-o", "/dev/null", "true"])
    return probe.returncode == 0


def requires(condition, reason):
    """skipUnless, except under REQUIRE_ALL_TESTS=1 (set in CI on native
    x86-64), where an unmet requirement must fail instead of hiding as a skip."""
    if os.environ.get("REQUIRE_ALL_TESTS") == "1":
        return lambda test: test
    return unittest.skipUnless(condition, reason)
