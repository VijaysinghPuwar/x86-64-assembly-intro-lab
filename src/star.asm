; star.asm  - prints:
; *
; **
; ***

default rel                         ; RIP-relative addressing

section .data
    stars db "*",10                 ; "*\n"
          db "**",10                ; "**\n"
          db "***",10               ; "***\n"
    stars_len equ $ - stars         ; total length = 1+1 + 2+1 + 3+1 = 9

section .text
    global  _start

; ----- pure syscalls: no printf, no GCC hardening flags -----
_start:
    mov     rax, 1          ; sys_write
    mov     rdi, 1          ;   fd = stdout
    lea     rsi, [rel stars];   buffer
    mov     rdx, stars_len  ;   length
    syscall

    mov     rax, 60         ; sys_exit
    xor     rdi, rdi        ;   status = 0
    syscall

section .note.GNU-stack progbits alloc noexec
