; add.asm - prints "7 + 5 = 12" with libc printf.
;
; Fixes over the original lab version:
;   - Stack alignment: the SysV AMD64 ABI requires rsp to be a multiple of 16
;     at every `call`. main is entered with rsp % 16 == 8 (the caller's call
;     pushed an 8-byte return address), so main must adjust rsp before calling
;     printf. The original did not; it worked only because nothing on that
;     code path in this glibc build happened to depend on the alignment.
;   - Operand size: num1/num2 are 32-bit (dd), so they are loaded with 32-bit
;     moves. The original `mov rax, [num1]` read 8 bytes (num1 and num2).
;   - PIE: `call printf wrt ..plt` goes through the PLT, so no -no-pie needed.
;   - Errors: output is flushed before returning, so a failed write (full
;     disk, closed stdout) is reported and turns into exit status 1.

%include "linux.inc"
default rel

section .rodata
fmt:        db "%d + %d = %d", 10, 0
progname:   db "add", 0
num1:       dd 7
num2:       dd 5

section .text
global main
extern printf, fflush, perror

main:
    sub     rsp, 8                  ; rsp % 16: 8 -> 0, aligned for the calls below

    mov     esi, [num1]             ; printf(fmt, num1, num2, num1 + num2)
    mov     edx, [num2]
    mov     ecx, esi
    add     ecx, edx
    lea     rdi, [fmt]
    xor     eax, eax                ; al = vector registers used (variadic call)
    call    printf wrt ..plt
    test    eax, eax
    js      .failed

    ; stdout is fully buffered when it is a file or pipe, so a write error
    ; would otherwise only happen inside exit() and be silently ignored.
    xor     edi, edi                ; fflush(NULL): flush all output streams
    call    fflush wrt ..plt
    test    eax, eax
    jnz     .failed

    xor     eax, eax                ; return 0
    add     rsp, 8
    ret

.failed:
    lea     rdi, [progname]         ; perror("add") -> "add: <strerror(errno)>"
    call    perror wrt ..plt
    mov     eax, EXIT_FAILURE
    add     rsp, 8
    ret

NONEXEC_STACK
