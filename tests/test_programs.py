"""Behavior of the three original lab programs: output, exit status, error paths."""

import os
import unittest

from support import BUILD, run

EXPECTED = {
    "hello": b"Hello, World!\n",
    "star": b"*\n**\n***\n",
    "add": b"7 + 5 = 12\n",
}


class OriginalPrograms(unittest.TestCase):
    def test_exact_output_and_status(self):
        for name, expected in EXPECTED.items():
            with self.subTest(program=name):
                result = run([BUILD / name])
                self.assertEqual(result.stdout, expected)
                self.assertEqual(result.stderr, b"")
                self.assertEqual(result.returncode, 0)

    def test_output_is_deterministic_across_runs(self):
        for name, expected in EXPECTED.items():
            with self.subTest(program=name):
                outputs = {run([BUILD / name]).stdout for _ in range(25)}
                self.assertEqual(outputs, {expected})

    def test_ignores_arguments_and_stdin(self):
        for name, expected in EXPECTED.items():
            with self.subTest(program=name):
                result = run([BUILD / name, "extra", "args"], input=b"ignored")
                self.assertEqual((result.stdout, result.returncode), (expected, 0))

    # The original versions exited 0 in both of the following cases.

    def test_full_device_is_reported_as_failure(self):
        for name in EXPECTED:
            with self.subTest(program=name):
                with open("/dev/full", "wb") as full:
                    result = run([BUILD / name], stdout=full)
                self.assertEqual(result.returncode, 1)
                if name == "add":
                    self.assertEqual(result.stderr, b"add: No space left on device\n")

    def test_closed_stdout_is_reported_as_failure(self):
        for name in EXPECTED:
            with self.subTest(program=name):
                # Child starts with fd 1 closed (like `prog >&-`).
                result = run([BUILD / name], stdout=None,
                             preexec_fn=lambda: os.close(1))
                self.assertEqual(result.returncode, 1)
                if name == "add":
                    self.assertEqual(result.stderr, b"add: Bad file descriptor\n")


class StackAlignmentProbe(unittest.TestCase):
    """add.o linked with tests/abi_probe.asm, which checks rsp at every libc call."""

    def test_fixed_add_keeps_stack_aligned(self):
        result = run([BUILD / "test" / "add-probed"])
        self.assertEqual(result.stderr, b"")
        self.assertEqual((result.stdout, result.returncode), (EXPECTED["add"], 0))

    def test_fixed_add_error_path_keeps_stack_aligned(self):
        with open("/dev/full", "wb") as full:
            result = run([BUILD / "test" / "add-probed"], stdout=full)
        # Reaching perror() through the probe proves that call was aligned too.
        self.assertEqual(result.stderr, b"add: No space left on device\n")
        self.assertEqual(result.returncode, 1)

    def test_original_add_is_caught(self):
        result = run([BUILD / "test" / "misaligned-probed"])
        self.assertEqual(result.stderr, b"abi-probe: libc call with misaligned stack\n")
        self.assertEqual(result.returncode, 70)
        self.assertEqual(result.stdout, b"")


if __name__ == "__main__":
    unittest.main()
