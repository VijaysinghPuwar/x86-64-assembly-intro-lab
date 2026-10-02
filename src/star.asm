; star.asm - prints a three-line star pattern with a single write.
;
;   *
;   **
;   ***

%include "linux.inc"
default rel

section .rodata
stars:      db "*", 10
            db "**", 10
            db "***", 10
stars_len   equ $ - stars           ; 9 bytes

section .text
global _start
extern write_all

_start:
    mov     edi, STDOUT_FILENO
    lea     rsi, [stars]
    mov     edx, stars_len
    call    write_all

    mov     edi, EXIT_OK
    test    rax, rax
    jz      .exit
    mov     edi, EXIT_FAILURE
.exit:
    mov     eax, SYS_exit
    syscall

NONEXEC_STACK
