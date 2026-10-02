; hello.asm  - 64-bit "Hello, World!" for Linux

section .data
    msg     db  "Hello, World!", 10     ; string + newline
    len     equ $ - msg                 ; length of the string

section .text
    global _start

_start:
    mov     rax, 1      ; sys_write
    mov     rdi, 1      ;   stdout
    mov     rsi, msg    ;   buffer
    mov     rdx, len    ;   length
    syscall

    mov     rax, 60     ; sys_exit
    xor     rdi, rdi    ;   status 0
    syscall
