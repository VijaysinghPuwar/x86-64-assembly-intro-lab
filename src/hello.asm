; hello.asm - prints "Hello, World!" using raw Linux syscalls (no libc).
;
; Differences from the original lab version:
;   - RIP-relative `lea` instead of an absolute `mov rsi, msg`, so the binary
;     can be linked as a position-independent executable (PIE).
;   - write_all handles short writes, and the exit status reports failure
;     (the original exited 0 even when stdout was full or closed).
;   - explicit .note.GNU-stack, so the stack is never executable.

%include "linux.inc"
default rel

section .rodata
msg:        db "Hello, World!", 10
msg_len     equ $ - msg

section .text
global _start
extern write_all

_start:
    mov     edi, STDOUT_FILENO
    lea     rsi, [msg]
    mov     edx, msg_len
    call    write_all

    mov     edi, EXIT_OK
    test    rax, rax
    jz      .exit
    mov     edi, EXIT_FAILURE
.exit:
    mov     eax, SYS_exit
    syscall

NONEXEC_STACK
