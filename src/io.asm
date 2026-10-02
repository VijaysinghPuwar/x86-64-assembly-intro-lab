; io.asm - small I/O helpers shared by the syscall-only programs.
;
; Both routines follow the SysV AMD64 calling convention: arguments in
; rdi, rsi, rdx; result in rax; only caller-saved registers are clobbered.
; They are leaf functions with no stack frame and no alignment requirement.

%include "linux.inc"
default rel

section .rodata
global hex_digits
hex_digits: db "0123456789abcdef"

section .text
global write_all
global put_hex

; write_all(fd: rdi, buf: rsi, len: rdx) -> rax = 0 on success, -errno on failure
;
; write(2) may write fewer bytes than requested (pipes, sockets, signals), so
; keep writing until everything is out. EINTR is retried. A zero-byte result
; for a non-empty request is reported as -EIO instead of looping forever.
write_all:
.loop:
    test    rdx, rdx
    jz      .done
    mov     eax, SYS_write
    syscall                     ; kernel preserves rdi/rsi/rdx (clobbers rcx, r11)
    test    rax, rax
    js      .failed
    jz      .no_progress
    add     rsi, rax            ; skip what was written
    sub     rdx, rax
    jmp     .loop
.failed:
    cmp     rax, -EINTR
    je      .loop
    ret                         ; rax = -errno
.no_progress:
    mov     rax, -EIO
    ret
.done:
    xor     eax, eax
    ret

; put_hex(value: rdi, dest: rsi, min_digits: edx) -> rax = digits written
;
; Writes `value` as lowercase hex, zero-padded to at least `min_digits`
; (at most 16). No NUL terminator.
put_hex:
    mov     ecx, 1              ; digits needed for value 0
    bsr     rax, rdi            ; index of highest set bit, ZF=1 if rdi == 0
    jz      .have_width
    shr     eax, 2
    lea     ecx, [rax + 1]
.have_width:
    cmp     ecx, edx
    cmovb   ecx, edx
    mov     eax, ecx            ; return value
    lea     r8, [hex_digits]
.next_digit:                    ; fill from the least significant digit backwards
    dec     ecx
    mov     r9d, edi
    and     r9d, 0x0f
    movzx   r9d, byte [r8 + r9]
    mov     [rsi + rcx], r9b
    shr     rdi, 4
    test    ecx, ecx
    jnz     .next_digit
    ret

NONEXEC_STACK
