; misaligned_call.asm - the original lab's add.asm main, kept as a known-bad
; example for the ABI alignment check.
;
; It calls printf with rsp % 16 == 8, violating the SysV AMD64 rule that rsp
; is 16-byte aligned at each call. It usually still prints "7 + 5 = 12",
; which is why the bug went unnoticed: misalignment only faults when the
; callee executes an instruction that requires alignment (e.g. movaps).
;
; Changes from the original, both needed to link under the repo's hardened
; flags so the test isolates the alignment bug: the .note.GNU-stack line, and
; `wrt ..plt` on the call so it links as a PIE.

default rel
section .data
    fmt   db  "%d + %d = %d", 10, 0
    num1  dd  7
    num2  dd  5

section .text
    global  main
    extern  printf

main:
    mov     rax, [rel num1]
    mov     esi, eax
    mov     eax, [rel num2]
    mov     edx, eax
    mov     eax, [rel num1]
    add     eax, [rel num2]
    mov     ecx, eax
    lea     rdi, [rel fmt]
    xor     eax, eax
    call    printf wrt ..plt            ; original: `call printf` (non-PIE only)

    xor     eax, eax
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
