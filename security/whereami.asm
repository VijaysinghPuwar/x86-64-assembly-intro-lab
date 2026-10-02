; whereami.asm - prints the runtime address of its own _start.
;
;   whereami-nopie  -DABSOLUTE, linked as a classic ET_EXEC at a fixed address.
;                   Prints the same address on every run.
;   whereami-pie    RIP-relative, linked as a static PIE (ET_DYN). The kernel
;                   picks a random base, so the address changes per run (ASLR).
;
; The -DABSOLUTE variant cannot be linked as a PIE: the 64-bit immediate needs a
; load-time relocation inside .text (a text relocation), which `-z text` rejects
; and which nothing would apply anyway in a binary without a dynamic loader.

%include "linux.inc"
default rel

section .rodata
label:      db "_start is at 0x"
label_len   equ $ - label

section .bss
digits:     resb 17

section .text
global _start
extern write_all, put_hex

_start:
%ifdef ABSOLUTE
    mov     rdi, _start                 ; address fixed at link time
%else
    lea     rdi, [rel _start]           ; address computed from rip at run time
%endif
    lea     rsi, [digits]
    mov     edx, 16
    call    put_hex
    mov     byte [digits + 16], 10

    mov     edi, STDOUT_FILENO
    lea     rsi, [label]
    mov     edx, label_len
    call    write_all
    test    rax, rax
    jnz     .failed
    mov     edi, STDOUT_FILENO
    lea     rsi, [digits]
    mov     edx, 17
    call    write_all
    test    rax, rax
    jnz     .failed

    mov     edi, EXIT_OK
    mov     eax, SYS_exit
    syscall
.failed:
    mov     edi, EXIT_FAILURE
    mov     eax, SYS_exit
    syscall

NONEXEC_STACK
