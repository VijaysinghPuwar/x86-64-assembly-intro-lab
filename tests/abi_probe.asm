; abi_probe.asm - test-only shim that checks stack alignment at libc calls.
;
; Linked with -Wl,--wrap=printf,--wrap=fflush,--wrap=perror, so the program's
; calls land here first. The SysV AMD64 ABI requires rsp % 16 == 0 at the
; call instruction, i.e. rsp % 16 == 8 on entry to the callee. If that holds,
; jump to the real libc function with every argument register (including al)
; untouched. Otherwise report and exit 70 (EX_SOFTWARE).
;
; This checks the property directly instead of hoping a misaligned call
; crashes, which depends on the libc build.

%include "linux.inc"
default rel

section .rodata
msg:        db "abi-probe: libc call with misaligned stack", 10
msg_len     equ $ - msg

section .text

%macro CHECKED 1
global __wrap_%1
extern __real_%1
__wrap_%1:
    lea     r11, [rsp + 8]              ; r11: caller-saved, never an argument
    test    r11b, 15
    jnz     misaligned
    jmp     __real_%1 wrt ..plt
%endmacro

CHECKED printf
CHECKED fflush
CHECKED perror

misaligned:
    mov     eax, SYS_write
    mov     edi, STDERR_FILENO
    lea     rsi, [msg]
    mov     edx, msg_len
    syscall
    mov     eax, SYS_exit
    mov     edi, 70
    syscall

NONEXEC_STACK
