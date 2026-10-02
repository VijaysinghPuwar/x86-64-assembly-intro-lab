"""ELF hardening: the check-elf gate itself, plus runtime checks against the kernel."""

import os
import re
import shutil
import subprocess
import unittest

from support import BUILD, HEXDUMP, ROOT, emulated, ptrace_works, requires, run

CHECK_ELF = ROOT / "scripts" / "check-elf.sh"
SECURITY = BUILD / "security"
NATIVE_ONLY = "needs a native x86-64 kernel (emulators fake this)"


def check_elf(policy, binary):
    return run([CHECK_ELF, policy, binary])


class HardeningGate(unittest.TestCase):
    """The gate must pass hardened binaries and fail each known-bad one."""

    def test_programs_pass(self):
        for policy, name in [("static-pie", "hello"), ("static-pie", "star"),
                             ("static-pie", "asm-hexdump"), ("dynamic-pie", "add")]:
            with self.subTest(binary=name):
                result = check_elf(policy, BUILD / name)
                self.assertEqual(result.returncode, 0, result.stdout.decode())
                self.assertNotIn(b"FAIL", result.stdout)

    def test_executable_stack_is_rejected(self):
        result = check_elf("dynamic-pie", SECURITY / "execstack-bad")
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"FAIL  stack flags are RWE, expected RW", result.stdout)

    def test_non_pie_is_rejected(self):
        result = check_elf("static-pie", SECURITY / "whereami-nopie")
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"FAIL  not a PIE: Type: EXEC (Executable file)", result.stdout)

    def test_lazy_binding_is_rejected(self):
        # Without BIND_NOW the GOT stays writable for the whole run (partial RELRO).
        out = BUILD / "test" / "partial-relro"
        link = run(["gcc", "-pie", "-Wl,-z,lazy", BUILD / "obj" / "add.o", "-o", out])
        self.assertEqual(link.returncode, 0, link.stderr.decode())
        result = check_elf("dynamic-pie", out)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"FAIL  missing full RELRO", result.stdout)

    def test_wrong_policy_is_rejected(self):
        result = check_elf("static-pie", BUILD / "add")
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"FAIL  has a program interpreter", result.stdout)

    def test_non_elf_and_bad_usage(self):
        result = check_elf("static-pie", ROOT / "Makefile")
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"FAIL  not a readable ELF file", result.stdout)
        self.assertEqual(run([CHECK_ELF, "pie", BUILD / "hello"]).returncode, 2)
        self.assertEqual(run([CHECK_ELF]).returncode, 2)


class LinkerGuards(unittest.TestCase):
    """The hardened link flags refuse insecure code at build time."""

    def test_absolute_address_cannot_link_as_pie(self):
        target = SECURITY / "whereami-abs-pie"
        # Drop the parent make's jobserver settings; their fds are not inherited.
        env = {k: v for k, v in os.environ.items() if k not in ("MAKEFLAGS", "MFLAGS")}
        result = run(["make", "-s", f"BUILD={BUILD}", target], cwd=ROOT, env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"read-only segment has dynamic relocations", result.stderr)
        self.assertFalse(target.exists())

    def test_missing_stack_note_cannot_link(self):
        out = BUILD / "test" / "execstack-guarded"
        result = run(["gcc", "-pie", "-Wl,--error-execstack",
                      BUILD / "obj" / "security" / "execstack-bad.o",
                      BUILD / "obj" / "io.o", "-o", out])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"does not have a .note.GNU-stack section", result.stderr)


@requires(not emulated(), NATIVE_ONLY)
class RuntimeProperties(unittest.TestCase):
    """What the kernel actually does with the ELF headers."""

    def stack_permissions(self, binary):
        maps = run([binary]).stdout.decode()
        line = next(l for l in maps.splitlines() if l.endswith("[stack]"))
        return line.split()[1]

    def test_execstack_bad_gets_executable_stack(self):
        self.assertEqual(self.stack_permissions(SECURITY / "execstack-bad"), "rwxp")

    def test_execstack_good_gets_non_executable_stack(self):
        self.assertEqual(self.stack_permissions(SECURITY / "execstack-good"), "rw-p")

    def test_hexdump_stack_not_executable(self):
        # Our own tool dumps its own memory map; decode the ASCII column back.
        out = run([HEXDUMP, "/proc/self/maps"]).stdout.decode()
        raw = bytes.fromhex("".join(
            l[10:59].replace(" ", "") for l in out.splitlines() if len(l) > 10))
        stack = next(l for l in raw.decode().splitlines() if l.endswith("[stack]"))
        self.assertEqual(stack.split()[1], "rw-p")

    def addresses(self, binary, runs=5):
        out = [run([binary]).stdout.decode() for _ in range(runs)]
        return [int(re.fullmatch(r"_start is at 0x([0-9a-f]{16})\n", o).group(1), 16)
                for o in out]

    def entry_point(self, binary):
        header = run(["readelf", "-hW", binary]).stdout.decode()
        return int(re.search(r"Entry point address:\s+0x([0-9a-f]+)", header).group(1), 16)

    def test_non_pie_loads_at_link_time_address(self):
        binary = SECURITY / "whereami-nopie"
        self.assertEqual(set(self.addresses(binary)), {self.entry_point(binary)})

    def test_pie_is_randomized(self):
        with open("/proc/sys/kernel/randomize_va_space") as f:
            if f.read().strip() == "0" and os.environ.get("REQUIRE_ALL_TESTS") != "1":
                self.skipTest("ASLR disabled on this host")
        binary = SECURITY / "whereami-pie"
        addrs = self.addresses(binary)
        self.assertGreater(len(set(addrs)), 1, f"same address every run: {addrs}")
        # Base moves in whole pages; _start keeps its offset within the page.
        entry = self.entry_point(binary)
        self.assertEqual({a & 0xFFF for a in addrs}, {entry & 0xFFF})


@requires(ptrace_works(), "strace/ptrace unavailable (emulated or restricted)")
class SyscallSurface(unittest.TestCase):
    """The syscall-only programs make exactly the syscalls their source shows."""

    def syscalls(self, *args, **kwargs):
        result = run(["strace", "-f", "-qq", "-o", "/dev/stderr", *args],
                     stdout=subprocess.DEVNULL, **kwargs)
        return {m.group(1) for m in re.finditer(rb"^(?:\d+ +)?(\w+)\(", result.stderr, re.M)}

    def test_hello(self):
        self.assertEqual(self.syscalls(BUILD / "hello"), {b"execve", b"write", b"exit"})

    def test_hexdump_file(self):
        self.assertEqual(self.syscalls(HEXDUMP, ROOT / "Makefile"),
                         {b"execve", b"open", b"read", b"write", b"exit"})

    def test_hexdump_stdin(self):
        self.assertEqual(self.syscalls(HEXDUMP, input=b"abc"),
                         {b"execve", b"read", b"write", b"exit"})


@requires(ptrace_works() and shutil.which("gdb"), "gdb/ptrace unavailable")
class CallBoundary(unittest.TestCase):
    def test_rsp_at_printf_entry(self):
        """Second, independent check of the ABI rule: stop in gdb at printf's
        entry in the real (unwrapped) add binary and inspect rsp."""
        result = run(["gdb", "-q", "-nx", "-batch",
                      "-ex", "break main", "-ex", "run",
                      "-ex", "break *printf", "-ex", "continue",
                      "-ex", 'printf "rsp%%16=%d\\n", (long)$rsp % 16',
                      BUILD / "add"])
        out = result.stdout.decode()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertIn("rsp%16=8", out, out)


if __name__ == "__main__":
    unittest.main()
