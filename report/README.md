# Original lab report (July 2025)

[`assembly-programming-lab-report.pdf`](assembly-programming-lab-report.pdf) is
the coursework submission this repository started from, kept unchanged. It
covers installing NASM on Ubuntu 24.04 (WSL 2) and building three programs:
`hello`, `add` and `star`.

The rest of the repository revisits that work. Re-building the programs exactly
as written in the report (same NASM 2.16.01, GCC 13.3 and binutils 2.42)
showed the following problems, which the current sources fix.

## Errata

| Report says | What actually happens | Fixed in |
|---|---|---|
| Build table: `star` prints `******` | It prints three lines: `*`, `**`, `***`. | (documentation only) |
| Troubleshooting: garbage output caused by a "missing NUL terminator" | `write(2)` takes an explicit length and never looks for a NUL byte. Garbage output comes from a wrong length or buffer address. | (documentation only) |
| `add` builds with only a "deprecated behaviour" note | The linker warning `missing .note.GNU-stack section implies executable stack` (visible in the report's screenshot) means the binary's stack is executable: `PT_GNU_STACK RWE`. | `src/add.asm`, enforced by `--error-execstack` |
| `hello` needs no stack note | Linked with plain `ld`, it has no `PT_GNU_STACK` header at all, so stack permissions fall back to kernel defaults. Kernels before 5.8 treat that as "everything readable is executable". | `src/hello.asm` |
| `add` works | `main` calls `printf` with `rsp % 16 == 8`, violating the SysV AMD64 ABI. It prints the right answer by luck. | `src/add.asm`, checked by `tests/abi_probe.asm` |
| `mov rax, [rel num1]` loads `num1` | `num1` is a 4-byte `dd`; the 8-byte load also reads `num2`. | `src/add.asm` |
| `-no-pie` resolves the PIE link error | It works around non-PIC code rather than fixing it, and gives up ASLR for the binary. `call printf wrt ..plt` links as a normal PIE. | `src/add.asm` |
| "All programs execute with ... zero exit status" | True, including when output fails: all three exit 0 with stdout full (`>/dev/full`) or closed. | all three, see `tests/test_programs.py` |

The report's screenshots include the lab machine's shell prompt. They are left
as they were, since the report is a historical record.
