;--------------------------------------------------------------
; add.asm - prints "7 + 5 = 12" using libc printf
;--------------------------------------------------------------
default rel
section .data
    fmt   db  "%d + %d = %d", 10, 0     ; "%d + %d = %d\n"
    num1  dd  7
    num2  dd  5

section .text
    global  main
    extern  printf

main:
    ; load arguments for printf(format, n1, n2, sum)
    mov     rax, [rel num1]   ; rax = num1
    mov     esi, eax          ; 2nd arg  (rsi) = num1
    mov     eax, [rel num2]
    mov     edx, eax          ; 3rd arg  (rdx) = num2
    mov     eax, [rel num1]
    add     eax, [rel num2]   ; eax = num1 + num2
    mov     ecx, eax          ; 4th arg  (rcx) = sum
    lea     rdi, [rel fmt]    ; 1st arg  (rdi) = format string
    xor     eax, eax          ; SysV ABI: rax = 0 for variadic funcs
    call    printf

    ; return 0
    xor     eax, eax
    ret
