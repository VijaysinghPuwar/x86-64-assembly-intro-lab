# Hand-written vs compiler-generated assembly

[`add.c`](add.c) is the C version of [`src/add.asm`](../src/add.asm). It is
split into a `print_sum(a, b)` function plus `main`, so the output shows both a
function that receives arguments and one that works on constants. Reading
output like this is the everyday version of reverse engineering: you see
machine code without the source and have to recover what it does.

```sh
gcc -O2 -S -masm=intel -fno-asynchronous-unwind-tables -fcf-protection=none docs/add.c -o -
```

The two `-f` flags only remove unwind directives and `endbr64` landing pads to
keep the listing short. Output below is from GCC 13.3.0 (Ubuntu 24.04), with
assembler directives trimmed.

## `-O2`

```asm
print_sum:
        lea     r8d, [rdi+rsi]
        mov     edx, edi
        mov     ecx, esi
        mov     edi, 2
        lea     rsi, .LC0[rip]
        xor     eax, eax
        jmp     __printf_chk@PLT

main:
        sub     rsp, 8
        xor     eax, eax
        mov     ecx, 5
        mov     edx, 7
        mov     r8d, 12
        lea     rsi, .LC0[rip]
        mov     edi, 2
        call    __printf_chk@PLT
        test    eax, eax
        js      .L6
        xor     edi, edi
        call    fflush@PLT
        test    eax, eax
        jne     .L6
.L3:
        add     rsp, 8
        ret
main.cold:                              ; placed in .text.unlikely
.L6:
        lea     rdi, .LC1[rip]
        call    perror@PLT
        mov     eax, 1
        jmp     .L3
```

## What to notice

| Topic | Compiler (`-O2`) | Hand-written `src/add.asm` |
|---|---|---|
| Stack alignment | `main` starts with `sub rsp, 8`, the same fix applied to the original lab code. | `sub rsp, 8`, now checked by `tests/abi_probe.asm`. |
| `print_sum` frame | None. It ends in `jmp` (a tail call), so `printf` returns straight to `print_sum`'s caller and no alignment adjustment is needed. | Not applicable (single function). |
| Constants | `num1 + num2` folded to `mov r8d, 12` at compile time because both are `const`. | Loaded and added at run time. |
| Addition | `lea r8d, [rdi+rsi]`: adds and writes a third register in one instruction without touching flags. | `mov ecx, esi` / `add ecx, edx`. |
| Variadic call | `xor eax, eax`: al = number of vector registers carrying arguments. | Same. |
| Hardening | `printf` became `__printf_chk`. Ubuntu enables `_FORTIFY_SOURCE` at `-O2`, and the extra flag argument (`edi = 2`) shifts every other argument one register to the right: format in `rsi`, values in `edx`, `ecx`, `r8d`. | Calls plain `printf`; there is no compiler to add fortification. |
| Cold path | The error branch moved to `main.cold` in `.text.unlikely` to keep the hot path compact. | Inline. |
| Stack note | Emitted automatically: `.section .note.GNU-stack,"",@progbits`. | Must be written by hand (`NONEXEC_STACK` macro). Forgetting it is how the original lab ended up with an executable stack. |

## `-O0` for contrast

Unoptimized code builds a frame, spills every argument to the stack and
reloads it. It is easy to map back to source, which is why debug builds are
easier to reverse than release builds:

```asm
print_sum:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 16
        mov     DWORD PTR -4[rbp], edi
        mov     DWORD PTR -8[rbp], esi
        mov     edx, DWORD PTR -4[rbp]
        mov     eax, DWORD PTR -8[rbp]
        lea     ecx, [rdx+rax]
        mov     edx, DWORD PTR -8[rbp]
        mov     eax, DWORD PTR -4[rbp]
        mov     esi, eax
        lea     rax, .LC0[rip]
        mov     rdi, rax
        mov     eax, 0
        call    printf@PLT
        leave
        ret
```

`_FORTIFY_SOURCE` is inactive at `-O0`, so this version calls plain `printf`.
