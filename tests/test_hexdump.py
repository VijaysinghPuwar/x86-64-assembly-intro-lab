"""asm-hexdump: output against independent references, boundaries, and error paths."""

import os
import random
import re
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

from support import (BUILD, C_LOCALE, FLUSH_LINES, HEXDUMP, IN_SIZE, ROOT,
                     SYSTEM_HEXDUMP, emulated, reference_hexdump, requires, run)


def boundary_sizes():
    """Input sizes where off-by-one bugs would show up."""
    sizes = {0, 1, 2, 7, 8, 9, 15, 16, 17, 31, 32, 33}
    for edge in (IN_SIZE, 2 * IN_SIZE, 3 * IN_SIZE):
        sizes.update({edge - 1, edge, edge + 1, edge - 16, edge + 16})
    # Inputs whose formatted lines land around the output flush threshold.
    for lines in (FLUSH_LINES - 1, FLUSH_LINES, FLUSH_LINES + 1):
        for extra in (-1, 0, 1):
            sizes.add(lines * 16 + extra)
    return sorted(s for s in sizes if s >= 0)


class TempDirTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)

    def tearDown(self):
        for path in self.dir.rglob("*"):         # undo chmod 000 so cleanup works
            if not path.is_symlink():
                path.chmod(0o700)
        self._tmp.cleanup()

    def write(self, name, data):
        path = self.dir / name
        path.write_bytes(data)
        return path

    def assert_dump(self, data, args=None, **kwargs):
        if args is None:
            args = [HEXDUMP, self.write("input.bin", data)]
        result = run(args, **kwargs)
        self.assertEqual(result.stderr, b"")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, reference_hexdump(data),
                         f"output differs from reference for {len(data)} input bytes")
        return result


class Output(TempDirTest):
    def test_known_text(self):
        result = run([HEXDUMP, self.write("hello.txt", b"Hello, hexdump!\n")])
        self.assertEqual(result.stdout, (
            b"00000000  48 65 6c 6c 6f 2c 20 68  65 78 64 75 6d 70 21 0a  |Hello, hexdump!.|\n"
            b"00000010\n"))
        self.assertEqual(result.returncode, 0)

    def test_empty_file_prints_nothing(self):
        self.assert_dump(b"")

    def test_single_byte(self):
        self.assert_dump(b"A")

    def test_every_byte_value(self):
        self.assert_dump(bytes(range(256)))

    def test_printable_edges(self):
        # 0x1f/0x7f are '.', 0x20/0x7e are printed as-is.
        self.assert_dump(bytes([0x1F, 0x20, 0x7E, 0x7F, 0x80, 0xFF]))

    def test_repeated_zero_and_ff_bytes(self):
        # hexdump without -v would collapse these into '*'; -v format never does.
        self.assert_dump(bytes(1000))
        self.assert_dump(b"\xff" * 1000)

    def test_boundary_sizes(self):
        rng = random.Random(1)
        for size in boundary_sizes():
            with self.subTest(size=size):
                self.assert_dump(rng.randbytes(size))

    def test_seeded_random_inputs(self):
        rng = random.Random(20250723)
        for _ in range(150):
            data = rng.randbytes(rng.randrange(0, 3 * IN_SIZE))
            with self.subTest(size=len(data)):
                self.assert_dump(data)

    @requires(SYSTEM_HEXDUMP, "system hexdump not installed")
    def test_matches_system_hexdump(self):
        rng = random.Random(7)
        for size in (0, 1, 16, 17, IN_SIZE + 3, 50_000):
            path = self.write(f"in{size}", rng.randbytes(size))
            with self.subTest(size=size):
                ours = run([HEXDUMP, path])
                theirs = run([SYSTEM_HEXDUMP, "-C", "-v", path], env=C_LOCALE)
                self.assertEqual(theirs.returncode, 0)
                self.assertEqual(ours.stdout, theirs.stdout)


class StandardInput(TempDirTest):
    def test_no_argument_reads_stdin(self):
        self.assert_dump(b"from stdin\n", args=[HEXDUMP], input=b"from stdin\n")

    def test_dash_reads_stdin(self):
        self.assert_dump(b"dash", args=[HEXDUMP, "-"], input=b"dash")

    def test_file_named_dash_via_path(self):
        self.write("-", b"a file called dash")
        self.assert_dump(b"a file called dash", args=[HEXDUMP, "./-"], cwd=self.dir)

    def test_short_reads_from_pipe(self):
        """Feed stdin in 1..700 byte writes. read() then returns short counts
        that split 16-byte lines at varying points. The exact split pattern
        depends on scheduling (writes can merge), so this is a fuzz test:
        the output must match the reference whatever the pattern was."""
        rng = random.Random(99)
        data = rng.randbytes(200_000)
        with subprocess.Popen([HEXDUMP], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as proc:
            # Drain stdout concurrently so the child never blocks on output
            # and keeps reading whatever small chunk is in the pipe.
            output = []
            reader = threading.Thread(target=lambda: output.append(proc.stdout.read()))
            reader.start()
            pos = 0
            while pos < len(data):
                step = rng.randint(1, 700)
                proc.stdin.write(data[pos:pos + step])
                proc.stdin.flush()
                pos += step
                if rng.random() < 0.02:
                    time.sleep(0.001)
            proc.stdin.close()
            reader.join(timeout=60)
            stderr = proc.stderr.read()
            proc.wait(timeout=30)
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(stderr, b"")
        self.assertEqual(output, [reference_hexdump(data)])

    # Rosetta opens the emulated executable on the lowest free fd, so a closed
    # stdin becomes fd 0 = the binary itself. Only meaningful natively.
    @requires(not emulated(), "emulator reuses fd 0")
    def test_closed_stdin_is_read_error(self):
        result = run([HEXDUMP], stdin=None, preexec_fn=lambda: os.close(0))
        self.assertEqual(result.stderr,
                         b"asm-hexdump: standard input: Bad file descriptor\n")
        self.assertEqual(result.returncode, 1)


class FileNames(TempDirTest):
    def test_spaces_and_unicode_in_name(self):
        path = self.write("my file é (copy).bin", b"\x00\x01spaces")
        self.assert_dump(b"\x00\x01spaces", args=[HEXDUMP, path])

    def test_leading_dash_is_a_filename(self):
        self.write("-v", b"not an option")
        self.assert_dump(b"not an option", args=[HEXDUMP, "-v"], cwd=self.dir)

    def test_longest_valid_name(self):
        path = self.write("n" * 255, b"NAME_MAX")
        self.assert_dump(b"NAME_MAX", args=[HEXDUMP, path])


class Errors(TempDirTest):
    def assert_error(self, args, message, status=1, **kwargs):
        result = run(args, **kwargs)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, message)
        self.assertEqual(result.returncode, status)

    def test_missing_file(self):
        self.assert_error([HEXDUMP, "does-not-exist"],
                          b"asm-hexdump: does-not-exist: " +
                          os.strerror(2).encode() + b"\n")

    def test_empty_path(self):
        self.assert_error([HEXDUMP, ""], b"asm-hexdump: : No such file or directory\n")

    def test_directory(self):
        self.assert_error([HEXDUMP, self.dir], f"asm-hexdump: {self.dir}: Is a directory\n".encode())

    def test_path_through_a_file(self):
        path = self.write("plain", b"x")
        self.assert_error([HEXDUMP, f"{path}/child"],
                          f"asm-hexdump: {path}/child: Not a directory\n".encode())

    def test_name_too_long(self):
        self.assert_error([HEXDUMP, "n" * 256],
                          b"asm-hexdump: " + b"n" * 256 + b": File name too long\n")

    def test_symlink_loop(self):
        (self.dir / "loop").symlink_to("loop")
        self.assert_error([HEXDUMP, "loop"],
                          b"asm-hexdump: loop: Too many levels of symbolic links\n",
                          cwd=self.dir)

    @requires(os.geteuid() != 0, "root bypasses file permissions")
    def test_permission_denied(self):
        path = self.write("secret", b"x")
        path.chmod(0)
        self.assert_error([HEXDUMP, path],
                          f"asm-hexdump: {path}: Permission denied\n".encode())

    def test_too_many_arguments(self):
        self.assert_error([HEXDUMP, "a", "b"], b"usage: asm-hexdump [FILE]\n", status=2)

    def test_write_to_full_device(self):
        path = self.write("data", bytes(range(256)) * 64)
        with open("/dev/full", "wb") as full:
            result = run([HEXDUMP, path], stdout=full)
        self.assertEqual(result.stderr,
                         b"asm-hexdump: write error: No space left on device\n")
        self.assertEqual(result.returncode, 1)

    def test_closed_stdout(self):
        path = self.write("data", b"abc")
        result = run([HEXDUMP, path], stdout=None, preexec_fn=lambda: os.close(1))
        self.assertEqual(result.stderr, b"asm-hexdump: write error: Bad file descriptor\n")
        self.assertEqual(result.returncode, 1)

    def test_socket_inode(self):
        # open(2) on a UNIX socket inode fails with ENXIO.
        sock_path = self.dir / "sock"
        server = socket.socket(socket.AF_UNIX)
        server.bind(str(sock_path))
        try:
            self.assert_error([HEXDUMP, sock_path],
                              f"asm-hexdump: {sock_path}: {os.strerror(6)}\n".encode())
        finally:
            server.close()

    def test_unlisted_errno_is_printed_as_number(self):
        # read(2) on an unconnected stream socket fails with ENOTCONN (107),
        # which is not in the message table.
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            self.assert_error([HEXDUMP], b"asm-hexdump: standard input: error 107\n",
                              stdin=sock.fileno())

    def test_read_error_keeps_earlier_output(self):
        """A read that fails mid-stream (connection reset) must not discard
        the bytes already read: they are dumped, then the error is reported."""
        data = bytes(range(100))
        with socket.socket() as server:
            server.bind(("127.0.0.1", 0))
            server.listen(1)
            client = socket.create_connection(server.getsockname())
            conn, _ = server.accept()
            with client, conn:
                proc = subprocess.Popen([HEXDUMP], stdin=client.fileno(),
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                conn.sendall(data)
                time.sleep(0.5)             # let the child read the data and block again
                conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                                struct.pack("ii", 1, 0))
                conn.close()                # linger 0: close sends RST, not FIN
                stdout, stderr = proc.communicate(timeout=30)
        self.assertEqual(stdout, reference_hexdump(data)[:-len(b"00000064\n")])
        self.assertEqual(stderr, b"asm-hexdump: standard input: error 104\n")
        self.assertEqual(proc.returncode, 1)


class ErrorMessages(unittest.TestCase):
    def test_table_matches_strerror(self):
        """Every errno message compiled into asm-hexdump equals glibc strerror()."""
        inc = (ROOT / "include" / "linux.inc").read_text()
        errno = dict(re.findall(r"^%define\s+(E[A-Z]+)\s+(\d+)", inc, re.M))
        asm = (ROOT / "src" / "hexdump.asm").read_text()
        table = re.findall(r'^\s+ERRNO_MSG\s+(E[A-Z]+),\s+"([^"]+)"', asm, re.M)
        self.assertGreater(len(table), 10)
        for name, text in table:
            with self.subTest(errno=name):
                self.assertEqual(text, os.strerror(int(errno[name])))


class PutHex(unittest.TestCase):
    def test_offsets_beyond_32_bits(self):
        # Same list as tests/put_hex_check.asm.
        values = [0, 1, 0xABC, 0xFFFFFFFF, 0x100000000, 0xFFFFFFFFF,
                  0x123456789ABCDEF0, 0xFFFFFFFFFFFFFFFF]
        result = run([BUILD / "test" / "put-hex"])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.decode().splitlines(),
                         [f"{v:08x}" for v in values])

if __name__ == "__main__":
    unittest.main()
