# Inspecting the binaries

Each section asks one question about the built programs and answers it with
the tool suited to it. All output is real. The static tools (`file`,
`readelf`, `nm`, `objdump`) were run inside `build/` after `make`, with the
Ubuntu 24.04 toolchain. `strace` and `gdb` need a native x86-64 kernel, so
their output comes from the GitHub Actions runner; long paths in it are the
runner's checkout directory.

## What kind of file is this? (`file`)

```
$ file asm-hexdump add
asm-hexdump: ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), static-pie linked, not stripped
add:         ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2, BuildID[sha1]=9f091533759e5a80a2cd15f600bda77cd0e31eaa, for GNU/Linux 3.2.0, not stripped
```

Both are PIEs. `asm-hexdump` has no interpreter: the kernel jumps straight
to `_start`, with no dynamic loader and no libc.

## How will it be mapped into memory? (`readelf -l`)

```
$ readelf -lW asm-hexdump

Elf file type is DYN (Position-Independent Executable file)
Entry point 0x1000
There are 6 program headers, starting at offset 64

Program Headers:
  Type           Offset   VirtAddr           PhysAddr           FileSiz  MemSiz   Flg Align
  LOAD           0x000000 0x0000000000000000 0x0000000000000000 0x0001d9 0x0001d9 R   0x1000
  LOAD           0x001000 0x0000000000001000 0x0000000000001000 0x0003b7 0x0003b7 R E 0x1000
  LOAD           0x002000 0x0000000000002000 0x0000000000002000 0x0001f0 0x0001f0 R   0x1000
  LOAD           0x0021f0 0x00000000000031f0 0x00000000000031f0 0x0000e0 0x0020f8 RW  0x1000
  DYNAMIC        0x0021f0 0x00000000000031f0 0x00000000000031f0 0x0000e0 0x0000e0 RW  0x8
  GNU_STACK      0x000000 0x0000000000000000 0x0000000000000000 0x000000 0x000000 RW  0x10

 Section to Segment mapping:
  Segment Sections...
   00     .hash .gnu.hash .dynsym .dynstr
   01     .text
   02     .rodata
   03     .dynamic .bss
   04     .dynamic
   05
```

What to read from it:

- **Addresses start at 0.** The binary is position independent; the kernel picks the base address.
- **Code and data are never mapped together.** Code (`.text`) is `R E`, constants (`.rodata`) are `R`, and data is `RW`. No segment is both writable and executable.
- **`.bss` occupies no file space.** The last `LOAD` has `FileSiz 0xe0` but `MemSiz 0x20f8`. The extra memory is the zero-filled `.bss`, which holds the 4 KiB input and output buffers.
- **The stack is not executable.** `GNU_STACK` is `RW`, which is what `scripts/check-elf.sh` enforces.

## What does the dynamic linker need to do? (`readelf -d`)

```
$ readelf -dW add | grep -E "NEEDED|FLAGS"
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
 0x000000000000001e (FLAGS)              BIND_NOW
 0x000000006ffffffb (FLAGS_1)            Flags: NOW PIE
```

`BIND_NOW` makes the loader resolve every libc symbol at startup. Combined with
`PT_GNU_RELRO`, the GOT is then read-only for the rest of the run (full
RELRO), so a memory-corruption bug cannot redirect a later `printf` call by
overwriting its GOT entry.

## What functions and data are in it? (`nm`)

```
$ nm -n asm-hexdump | grep -v '\.'
0000000000000006 a unknown_len
000000000000000d a prog_prefix_len
000000000000001a a usage_len
0000000000001000 T _start
0000000000001129 t usage
000000000000114b t emit_line
000000000000120e t reserve_line
0000000000001218 t write_pending
000000000000122c t flush
000000000000124e t die
0000000000001350 T write_all
000000000000137d T put_hex
0000000000002000 r prog_prefix
000000000000200d r usage_msg
0000000000002027 r stdin_name
0000000000002036 r write_ctx
0000000000002042 r unknown_err
0000000000002048 r errno_table
00000000000021e0 R hex_digits
00000000000031f0 d _DYNAMIC
00000000000032d0 B __bss_start
00000000000032d0 B _edata
00000000000032d0 b inbuf
00000000000042d0 b outbuf
00000000000052d0 b line
00000000000052e0 b path
00000000000052e8 B _end
```

Upper case means global, lower case means local. `T`/`t` is code, `R`/`r` is
read-only data, `b` is `.bss`, and `a` is an absolute value (assembler
constants such as string lengths). `inbuf` and `outbuf` are 0x1000 apart: the
4 KiB buffers. The `grep` hides NASM's local labels (`emit_line.hex_slot` and
so on). The binaries are not stripped on purpose, so these names show up in
gdb and objdump. A release build would usually be stripped.

## What does the machine code look like? (`objdump -d`)

```
$ objdump -d -M intel --no-show-raw-insn add
0000000000001160 <main>:
    1160:	sub    rsp,0x8
    1164:	mov    esi,DWORD PTR [rip+0xeac]        # 2016 <num1>
    116a:	mov    edx,DWORD PTR [rip+0xeaa]        # 201a <num2>
    1170:	mov    ecx,esi
    1172:	add    ecx,edx
    1174:	lea    rdi,[rip+0xe89]        # 2004 <fmt>
    117b:	xor    eax,eax
    117d:	call   1030 <printf@plt>
    1182:	test   eax,eax
    1184:	js     1198 <main.failed>
    1186:	xor    edi,edi
    1188:	call   1040 <fflush@plt>
    118d:	test   eax,eax
    118f:	jne    1198 <main.failed>
    1191:	xor    eax,eax
    1193:	add    rsp,0x8
    1197:	ret
```

Every data reference is `[rip+offset]`, which is what makes the code position
independent. `DWORD PTR` confirms the 32-bit loads of `num1`/`num2` (the
original read a `QWORD`). Calls go through the PLT (`printf@plt`).

## Which system calls does it make? (`strace`)

```
$ strace ./hello
execve("./hello", ["./hello"], 0x7fffdd98bcd0 /* 115 vars */) = 0
Hello, World!
write(1, "Hello, World!\n", 14)         = 14
exit(0)                                 = ?
+++ exited with 0 +++

$ strace ./asm-hexdump /tmp/in.txt
execve("./asm-hexdump", ["./asm-hexdump", "/tmp/in.txt"], 0x7fff4b24c2d8 /* 115 vars */) = 0
open("/tmp/in.txt", O_RDONLY)           = 3
read(3, "hi\n", 4096)                   = 3
read(3, "", 4096)                       = 0
write(1, "00000000  68 69 0a              "..., 75) = 75
exit(0)                                 = ?
00000000  68 69 0a                                          |hi.|
00000003
+++ exited with 0 +++
```

The syscall-only programs make exactly the calls in their source and nothing
else: no loader, no libc setup. `asm-hexdump` buffers its output, so the whole
dump goes out in one `write`. For comparison, `strace -c ./add` counts
34 syscalls for the libc version (`mmap`, `mprotect`, `openat` of `libc.so.6`,
and so on), almost all of them dynamic loading and libc start-up.
`tests/test_hardening.py` asserts these syscall sets.

## What happens at the call boundary? (`gdb`)

The SysV ABI says `rsp` must be 16-byte aligned at a `call`, so the callee
sees `rsp % 16 == 8`. Check it at `main` and at the first instruction of
`printf`:

```
$ gdb -q -nx -batch -ex 'break main' -ex run \
      -ex 'printf "rsp %% 16 at main entry: %d\n", (long)$rsp % 16' \
      -ex 'break *printf' -ex continue \
      -ex 'printf "rsp %% 16 at printf entry: %d\n", (long)$rsp % 16' \
      -ex 'info registers rdi rsi rdx rcx rax' -ex 'x/s $rdi' \
      -ex 'x/gx $rsp' -ex 'info symbol *(long*)$rsp' build/add
Breakpoint 1 at 0x1160
[Thread debugging using libthread_db enabled]
Using host libthread_db library "/lib/x86_64-linux-gnu/libthread_db.so.1".

Breakpoint 1, 0x0000555555555160 in main ()
rsp % 16 at main entry: 8
Breakpoint 2 at 0x7ffff7c60100

Breakpoint 2, 0x00007ffff7c60100 in printf () from /lib/x86_64-linux-gnu/libc.so.6
rsp % 16 at printf entry: 8
rdi            0x555555556004      93824992239620
rsi            0x7                 7
rdx            0x5                 5
rcx            0xc                 12
rax            0x0                 0
0x555555556004: "%d + %d = %d\n"
0x7fffffffd4a8: 0x0000555555555182
main + 34 in section .text of /home/runner/work/x86-64-assembly-intro-lab/x86-64-assembly-intro-lab/build/add
```

Reading the stop at `printf`:

- `rdi`, `rsi`, `rdx`, `rcx` hold the format string, 7, 5 and 12: the first four integer arguments, in ABI order.
- `rax` is 0, the number of vector registers used by this variadic call.
- The 8 bytes at `rsp` are the return address. `main + 34` is offset `0x1182`, the `test eax, eax` right after `call printf@plt` in the objdump listing above.
- `rsp % 16` is 8 at `printf` entry, as the ABI requires, because `main` executed `sub rsp, 8`. In the original code the same command prints `rsp % 16 at printf entry: 0`.
