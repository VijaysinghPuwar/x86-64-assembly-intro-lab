; put_hex_check.asm - test harness: prints put_hex(value, min_digits=8) for a
; fixed list of values, one per line. Covers offsets above 4 GiB (9+ digits),
; which asm-hexdump would only reach on inputs too large to test directly.
; tests/test_hexdump.py holds the same list and compares against Python.

%include "linux.inc"
default rel

section .rodata
values:     dq 0, 1, 0xabc, 0xffffffff, 0x100000000, 0xfffffffff
            dq 0x123456789abcdef0, 0xffffffffffffffff
count       equ ($ - values) / 8

section .bss
buf:        resb 17

section .text
global _start
extern put_hex, write_all

_start:
    xor     ebx, ebx
.next:
    lea     rax, [values]
    mov     rdi, [rax + rbx * 8]
    lea     rsi, [buf]
    mov     edx, 8
    call    put_hex
    lea     rsi, [buf]
    mov     byte [rsi + rax], 10
    lea     rdx, [rax + 1]
    mov     edi, STDOUT_FILENO
    call    write_all
    test    rax, rax
    jnz     .failed
    inc     ebx
    cmp     ebx, count
    jb      .next

    mov     edi, EXIT_OK
    mov     eax, SYS_exit
    syscall
.failed:
    mov     edi, EXIT_FAILURE
    mov     eax, SYS_exit
    syscall

NONEXEC_STACK
