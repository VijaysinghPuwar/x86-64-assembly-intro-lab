; execstack.asm - prints this process's own memory map (/proc/self/maps).
;
; Built twice from this one file:
;   execstack-bad   assembled with -DOMIT_STACK_NOTE and linked like the
;                   original lab's add.asm. ld warns, then marks the stack
;                   executable (PT_GNU_STACK RWE).
;   execstack-good  the same code with the note. Stack is RW only.
;
; The [stack] line in the output is the kernel's view of the result:
; "rwxp" for the bad build, "rw-p" for the good one.

%include "linux.inc"
default rel

section .rodata
maps_path:  db "/proc/self/maps", 0

section .bss
buf:        resb 4096

section .text
global main
extern write_all

main:
    push    rbx                         ; rbx holds the fd; push also aligns rsp

    mov     eax, SYS_open
    lea     rdi, [maps_path]
    mov     esi, O_RDONLY
    syscall
    test    rax, rax
    js      .failed
    mov     rbx, rax

.copy:
    mov     eax, SYS_read
    mov     rdi, rbx
    lea     rsi, [buf]
    mov     edx, 4096
    syscall
    test    rax, rax
    jz      .done
    js      .failed
    mov     edi, STDOUT_FILENO
    lea     rsi, [buf]
    mov     rdx, rax
    call    write_all
    test    rax, rax
    jnz     .failed
    jmp     .copy

.done:
    xor     eax, eax
    pop     rbx
    ret
.failed:
    mov     eax, EXIT_FAILURE
    pop     rbx
    ret

%ifndef OMIT_STACK_NOTE
NONEXEC_STACK
%endif
