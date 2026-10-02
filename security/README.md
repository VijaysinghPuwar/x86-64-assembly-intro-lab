# Binary-hardening lab

Each demo here builds the same code two ways, one insecure and one hardened,
so the difference is visible in the ELF headers and in what the kernel does at
run time. Build and compare them with:

```sh
make security-demo
```

Output below is from the CI runner (Ubuntu 24.04, kernel 6.17, x86-64). On
Apple Silicon under Docker, the runtime columns are wrong: the emulator does
not reproduce stack permissions or ASLR.

## 1. Executable stack (NX)

[`execstack.asm`](execstack.asm) prints its own `/proc/self/maps`. The only
difference between the two builds is the `.note.GNU-stack` section. That is
the mistake in the original lab's `add.asm`.

```
$ readelf -lW build/security/execstack-bad | grep GNU_STACK
  GNU_STACK      0x000000 0x0000000000000000 0x0000000000000000 0x000000 0x000000 RWE 0x10
$ readelf -lW build/security/execstack-good | grep GNU_STACK
  GNU_STACK      0x000000 0x0000000000000000 0x0000000000000000 0x000000 0x000000 RW  0x10

$ build/security/execstack-bad | grep stack
7ffdb334f000-7ffdb3371000 rwxp 00000000 00:00 0                          [stack]
$ build/security/execstack-good | grep stack
7fff8f0ab000-7fff8f0cd000 rw-p 00000000 00:00 0                          [stack]
```

**Why it matters.** With an executable stack, any bytes an attacker gets onto
the stack (through a buffer overflow, for example) can be run as code. NX (the
no-execute page bit) blocks that and pushes attackers toward harder techniques
such as ROP. When a single object file lacks the note, GNU ld silently
re-enables an executable stack for the whole program.

**Detection and prevention in this repo:**

- `scripts/check-elf.sh` fails any binary whose `PT_GNU_STACK` is not exactly `RW`, or that has no `PT_GNU_STACK` at all.
- The hardened link flags include `--error-execstack`, so a missing note is a build error, not a warning.
- `tests/test_hardening.py` reads `[stack]` from `/proc/self/maps` to check what the kernel actually mapped, not just the header.

## 2. PIE and ASLR

[`whereami.asm`](whereami.asm) prints the run-time address of its own
`_start`. With `-DABSOLUTE` it loads the address as a 64-bit constant fixed at
link time (`mov rdi, _start`), the same pattern as the original `hello.asm`'s
`mov rsi, msg`. Without it, the address comes from `lea rdi, [rel _start]`,
which is computed from `rip` at run time.

```
$ readelf -h build/security/whereami-nopie | grep Type
  Type:                              EXEC (Executable file)
$ readelf -h build/security/whereami-pie | grep Type
  Type:                              DYN (Position-Independent Executable file)

$ for i in 1 2 3; do build/security/whereami-nopie; done
_start is at 0x0000000000401000
_start is at 0x0000000000401000
_start is at 0x0000000000401000
$ for i in 1 2 3; do build/security/whereami-pie; done
_start is at 0x00007f0a22a06000
_start is at 0x00007fd37ed90000
_start is at 0x00007fe8af293000
```

**Why it matters.** A non-PIE executable is mapped at the same address every
time, so its code is always where an attacker expects it, ready for
return-oriented programming. ASLR randomizes the load base of a PIE on every
run.

The absolute-address version cannot be made into a PIE. The 64-bit constant
needs a load-time relocation inside `.text`, and the hardened link flags
(`-z text`) refuse it:

```
ld: build/obj/security/whereami-abs.o: warning: relocation in read-only section `.text'
ld: read-only segment has dynamic relocations
```

That is why the original `add` needed `-no-pie`. A related trap is indexing a
buffer as `[outbuf + r15]`. RIP-relative addressing cannot take an index
register, so NASM quietly emits an absolute address instead, and the link
fails. See [docs/x86-64-linux-abi.md](../docs/x86-64-linux-abi.md#addressing-in-position-independent-code).

## 3. Stack alignment at calls (SysV AMD64 ABI)

The ABI requires `rsp` to be a multiple of 16 at every `call`, so the callee
sees `rsp % 16 == 8` on entry (the return address takes 8 bytes). A function
that is itself entered that way must move `rsp` by 8 more (or by 24, 40, ...)
before it calls anything.

The original `add.asm` did not. Stopping gdb at the first instruction of
`printf` (`break *printf`) and printing `(long)$rsp % 16` gives, for the
original code:

```
Breakpoint 2, 0x00007ffff7c60100 in printf () from /lib/x86_64-linux-gnu/libc.so.6
rsp % 16 at printf entry: 0
```

and for the fixed `src/add.asm`:

```
Breakpoint 2, 0x00007ffff7c60100 in printf () from /lib/x86_64-linux-gnu/libc.so.6
rsp % 16 at printf entry: 8
```

The full session is in [docs/inspecting-binaries.md](../docs/inspecting-binaries.md).

It still printed `7 + 5 = 12`, because misalignment only faults when the
callee executes an instruction that needs it (such as `movaps` on an SSE
register). Whether that happens depends on the libc build and the arguments,
so a test that waits for a crash proves nothing. Instead,
[`tests/abi_probe.asm`](../tests/abi_probe.asm) is linked in front of `printf`,
`fflush` and `perror` with `ld --wrap`. It checks `rsp` on every call and
exits 70 on a violation. It passes the fixed `src/add.asm` and catches
[`misaligned_call.asm`](misaligned_call.asm), which is the original code.

## What the gate checks, and what it does not

`make check-hardening` runs [`scripts/check-elf.sh`](../scripts/check-elf.sh)
with a policy per binary. It only checks properties that apply to that kind
of binary:

| Property | Syscall-only programs (static PIE) | `add` (libc, dynamic PIE) |
|---|---|---|
| ELF64, x86-64 | checked | checked |
| PIE (`ET_DYN` + `DF_1_PIE`) | checked | checked |
| `PT_GNU_STACK` is `RW` | checked | checked |
| No writable+executable `LOAD` segment | checked | checked |
| No text relocations | checked | checked |
| Program interpreter | must be absent | must be present |
| Dynamic relocations | must be none (no loader would apply them) | allowed |
| RELRO | must be absent (inert without a loader) | full: `PT_GNU_RELRO` + `BIND_NOW` |

Not checked, on purpose:

- **Stack canaries and `_FORTIFY_SOURCE`.** These are compiler instrumentation. Hand-written assembly has no compiler to insert them, so reporting them as missing would be noise.
- **CET (IBT/shadow stack).** It would need `endbr64` at every indirect branch target and `.note.gnu.property` markers in every object. It is out of scope for this lab.

The gate is tested too: `tests/test_hardening.py` runs it against each
known-bad binary and checks that it fails for the right reason.
