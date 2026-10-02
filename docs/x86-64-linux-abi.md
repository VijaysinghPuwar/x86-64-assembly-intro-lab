# x86-64 Linux calling conventions (quick reference)

The code in this repo relies on two different conventions: one for system
calls and one for function calls (the SysV AMD64 ABI). Mixing them up is a
classic source of bugs.

## System calls vs function calls

| | Linux syscall (`syscall`) | Function call (`call`, SysV AMD64) |
|---|---|---|
| Number / target | `rax` = syscall number | address of the function |
| Arguments 1 to 6 | `rdi`, `rsi`, `rdx`, `r10`, `r8`, `r9` | `rdi`, `rsi`, `rdx`, `rcx`, `r8`, `r9` |
| More arguments | not possible | on the stack |
| Return value | `rax`; `-4095..-1` means failure, returned as `-errno` | `rax` (and `rdx` for 128-bit values) |
| Clobbered | only `rax`, `rcx`, `r11` | all caller-saved registers (below) |
| Stack alignment | not required | `rsp % 16 == 0` at the `call` |

The 4th argument differs (`r10` vs `rcx`) because `syscall` itself overwrites
`rcx` (with the return address) and `r11` (with the flags).

Syscall numbers are architecture-specific. On x86-64, `write` is 1 and `exit`
is 60. On 32-bit x86 (`int 0x80`) they are 4 and 1. They are defined once in
[`include/linux.inc`](../include/linux.inc).

## Register preservation

| Callee-saved (must be restored before `ret`) | Caller-saved (may be destroyed by any call) |
|---|---|
| `rbx`, `rbp`, `r12`, `r13`, `r14`, `r15`, `rsp` | `rax`, `rcx`, `rdx`, `rsi`, `rdi`, `r8` to `r11` |

`src/hexdump.asm` keeps all of its long-lived state (file descriptor, offset,
buffer positions) in callee-saved registers, so it survives calls to
`write_all` and `put_hex`. Values in caller-saved registers, such as the
`line` pointer in `rcx`, are reloaded after every call.

## Stack alignment

```
caller: rsp = ...0   (16-byte aligned)
        call f       pushes 8-byte return address
f:      rsp = ...8   <- every function starts misaligned by 8
        sub rsp, 8   (or push one register)
        rsp = ...0   <- now f may call other functions
```

Calling another function while `rsp` is still at `...8` is the bug the
original `add.asm` had. `_start` is different: the kernel enters it with
`rsp` 16-byte aligned and nothing pushed, so `_start` can `call` immediately.

## Variadic functions

For calls like `printf(fmt, ...)`, `al` must hold the number of vector
registers (`xmm0` to `xmm7`) that carry arguments. With integer-only
arguments it is 0, hence `xor eax, eax` before `call printf`.

## Addressing in position-independent code

| Form | Meaning | PIE-safe |
|---|---|---|
| `lea rsi, [rel msg]` | address computed from `rip` at run time | yes |
| `mov rsi, msg` | 64-bit address fixed at link time | no: needs a text relocation |
| `call printf wrt ..plt` | call through the procedure linkage table | yes |
| `[buf + rcx]` | label plus an index register | no: see below |

With `default rel` at the top of a file, NASM makes `[label]` RIP-relative
automatically. The exception is an index register: x86-64 cannot encode
RIP-relative addressing with an index, so under `default rel` NASM silently
falls back to a 32-bit absolute address. The mistake only shows up at link
time:

```
ld: a.o: relocation R_X86_64_32S against `.bss' can not be used when making a PIE object; recompile with -fPIE
```

The fix is `lea rax, [buf]` followed by `[rax + rcx]`, which is how
`src/hexdump.asm` indexes its buffers.
