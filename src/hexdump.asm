; hexdump.asm - asm-hexdump: canonical hex + ASCII dump using only Linux syscalls.
;
;   usage: asm-hexdump [FILE]      no FILE, or "-", reads standard input
;
; Output is byte-for-byte the same as `hexdump -C -v`:
;
;   00000000  48 65 6c 6c 6f 0a                                 |Hello.|
;   00000006
;
; Exit status: 0 success, 1 open/read/write error (message on stderr),
; 2 usage error. Empty input produces no output.
;
; Input is read in IN_SIZE chunks. A 16-byte output line can span two reads
; (or many short reads from a pipe), so bytes are collected in `line` and a
; line is formatted only when it has 16 bytes or input ends.

%include "linux.inc"
default rel

%define IN_SIZE     4096
%define OUT_SIZE    4096
%define LINE_MAX    96          ; longest line: 16-digit offset + 2 + 49 + 2 + 16 + 2 = 87

section .bss
inbuf:      resb IN_SIZE
outbuf:     resb OUT_SIZE
line:       resb 16
path:       resq 1              ; name used in error messages

section .rodata
prog_prefix:    db "asm-hexdump: "
prog_prefix_len equ $ - prog_prefix
usage_msg:      db "usage: asm-hexdump [FILE]", 10
usage_len       equ $ - usage_msg
stdin_name:     db "standard input", 0
write_ctx:      db "write error", 0
unknown_err:    db "error "
unknown_len     equ $ - unknown_err

; errno -> message, as packed records: errno byte, length byte, text.
; Offsets instead of pointers keep .rodata free of relocations, which a
; static PIE has no dynamic loader to apply. Texts match glibc strerror().
%macro ERRNO_MSG 2
    db %1, %strlen(%2), %2
%endmacro
errno_table:
    ERRNO_MSG EPERM,        "Operation not permitted"
    ERRNO_MSG ENOENT,       "No such file or directory"
    ERRNO_MSG EIO,          "Input/output error"
    ERRNO_MSG ENXIO,        "No such device or address"
    ERRNO_MSG EBADF,        "Bad file descriptor"
    ERRNO_MSG EAGAIN,       "Resource temporarily unavailable"
    ERRNO_MSG ENOMEM,       "Cannot allocate memory"
    ERRNO_MSG EACCES,       "Permission denied"
    ERRNO_MSG EFAULT,       "Bad address"
    ERRNO_MSG ENODEV,       "No such device"
    ERRNO_MSG ENOTDIR,      "Not a directory"
    ERRNO_MSG EISDIR,       "Is a directory"
    ERRNO_MSG EINVAL,       "Invalid argument"
    ERRNO_MSG EFBIG,        "File too large"
    ERRNO_MSG ENOSPC,       "No space left on device"
    ERRNO_MSG EPIPE,        "Broken pipe"
    ERRNO_MSG ENAMETOOLONG, "File name too long"
    ERRNO_MSG ELOOP,        "Too many levels of symbolic links"
    ERRNO_MSG EDQUOT,       "Disk quota exceeded"
    db 0                        ; end of table

section .text
global _start
extern write_all, put_hex, hex_digits

; Register roles while dumping (callee-saved, so they survive helper calls):
;   rbx  read cursor in inbuf          r13  file offset of the current line
;   rbp  bytes left in inbuf           r14  bytes collected in `line` (0..16)
;   r12  input fd                      r15  bytes pending in outbuf

_start:
    lea     rax, [stdin_name]
    mov     [path], rax
    xor     r12d, r12d                  ; STDIN_FILENO

    mov     rax, [rsp]                  ; argc
    cmp     rax, 1
    je      .dump
    cmp     rax, 2
    jne     usage

    mov     rdi, [rsp + 16]             ; argv[1]
    cmp     word [rdi], '-'             ; exactly "-" (dash + NUL) means stdin
    je      .dump
    mov     [path], rdi
    mov     eax, SYS_open
    mov     esi, O_RDONLY
    syscall
    test    rax, rax
    js      .open_failed
    mov     r12, rax

.dump:
    xor     r13d, r13d
    xor     r14d, r14d
    xor     r15d, r15d

.read:
    mov     eax, SYS_read
    mov     rdi, r12
    lea     rsi, [inbuf]
    mov     edx, IN_SIZE
    syscall
    test    rax, rax
    jz      .eof
    js      .read_failed
    lea     rbx, [inbuf]
    mov     rbp, rax
    lea     rcx, [line]                 ; rcx is clobbered by emit_line, reload after
.next_byte:
    movzx   eax, byte [rbx]
    mov     [rcx + r14], al
    inc     rbx
    inc     r14
    cmp     r14, 16
    jne     .byte_done
    call    emit_line
    lea     rcx, [line]
.byte_done:
    dec     rbp
    jnz     .next_byte
    jmp     .read

.read_failed:
    cmp     rax, -EINTR
    je      .read
    ; Keep everything read before the error: finish the partial line and
    ; write out what is buffered, then report the read error.
    mov     rbp, rax                    ; -errno (rbp is free here)
    test    r14, r14
    jz      .write_before_error
    call    emit_line
.write_before_error:
    call    write_pending               ; best effort: the read error is reported either way
    mov     rsi, rbp
    mov     rdi, [path]
    jmp     die

.open_failed:
    mov     rsi, rax
    jmp     die                         ; rdi still holds argv[1]

.eof:
    test    r14, r14
    jz      .final_offset
    call    emit_line                   ; partial last line
.final_offset:
    test    r13, r13                    ; empty input: print nothing
    jz      .finish
    call    reserve_line
    lea     rsi, [outbuf]
    add     rsi, r15
    mov     rdi, r13
    mov     edx, 8
    call    put_hex
    add     r15, rax
    lea     rcx, [outbuf]
    mov     byte [rcx + r15], 10
    inc     r15
.finish:
    call    flush
    mov     edi, EXIT_OK
    mov     eax, SYS_exit
    syscall

usage:
    mov     edi, STDERR_FILENO
    lea     rsi, [usage_msg]
    mov     edx, usage_len
    call    write_all
    mov     edi, EXIT_USAGE
    mov     eax, SYS_exit
    syscall

; emit_line: format `line` (r14 bytes, 1..16) at offset r13 into outbuf.
; Advances r13 by r14 and resets r14 to 0.
emit_line:
    push    rbx                         ; also realigns rsp for the calls below
    call    reserve_line
    lea     rbx, [outbuf]               ; rbx = output cursor
    add     rbx, r15

    mov     rdi, r13                    ; offset, at least 8 hex digits
    mov     rsi, rbx
    mov     edx, 8
    call    put_hex
    add     rbx, rax
    mov     word [rbx], '  '
    add     rbx, 2

    lea     r8, [line]
    lea     r9, [hex_digits]
    xor     ecx, ecx                    ; 16 slots of "xx ", extra space after slot 7
.hex_slot:
    cmp     rcx, r14
    jae     .pad_slot
    movzx   eax, byte [r8 + rcx]
    mov     edx, eax
    shr     eax, 4
    and     edx, 0x0f
    movzx   eax, byte [r9 + rax]
    movzx   edx, byte [r9 + rdx]
    mov     [rbx], al
    mov     [rbx + 1], dl
    jmp     .slot_sep
.pad_slot:                              ; keep the ASCII column aligned on short lines
    mov     word [rbx], '  '
.slot_sep:
    mov     byte [rbx + 2], ' '
    add     rbx, 3
    cmp     ecx, 7
    jne     .slot_done
    mov     byte [rbx], ' '
    inc     rbx
.slot_done:
    inc     ecx
    cmp     ecx, 16
    jb      .hex_slot

    mov     word [rbx], ' |'
    add     rbx, 2
    xor     ecx, ecx
.ascii:                                 ; printable ASCII as-is, everything else '.'
    movzx   eax, byte [r8 + rcx]
    cmp     al, 0x20
    jb      .unprintable
    cmp     al, 0x7e
    jbe     .store_char
.unprintable:
    mov     al, '.'
.store_char:
    mov     [rbx], al
    inc     rbx
    inc     rcx
    cmp     rcx, r14
    jb      .ascii
    mov     word [rbx], `|\n`
    add     rbx, 2

    lea     rax, [outbuf]
    sub     rbx, rax
    mov     r15, rbx
    add     r13, r14
    xor     r14d, r14d
    pop     rbx
    ret

; reserve_line: flush outbuf unless there is room for one more full line.
reserve_line:
    cmp     r15, OUT_SIZE - LINE_MAX
    ja      flush
    ret

; write_pending: write outbuf to stdout. rax = 0 or -errno.
write_pending:
    mov     edi, STDOUT_FILENO
    lea     rsi, [outbuf]
    mov     rdx, r15
    jmp     write_all                   ; tail call

; flush: write outbuf to stdout and empty it. Exits with status 1 on failure.
flush:
    sub     rsp, 8
    call    write_pending
    test    rax, rax
    jnz     .failed
    xor     r15d, r15d
    add     rsp, 8
    ret
.failed:
    mov     rsi, rax
    lea     rdi, [write_ctx]
    jmp     die

; die(context: rdi, -errno: rsi): print "asm-hexdump: <context>: <reason>"
; to stderr and exit 1. Reached by jmp from any depth, so it realigns rsp.
die:
    and     rsp, -16
    mov     r12, rdi
    mov     r13, rsi
    neg     r13                         ; positive errno

    mov     edi, STDERR_FILENO
    lea     rsi, [prog_prefix]
    mov     edx, prog_prefix_len
    call    write_all

    mov     rdi, r12                    ; context string, NUL-terminated
    xor     edx, edx
.strlen:
    cmp     byte [rdi + rdx], 0
    je      .have_len
    inc     rdx
    jmp     .strlen
.have_len:
    mov     rsi, r12
    mov     edi, STDERR_FILENO
    call    write_all

    sub     rsp, 32                     ; scratch: ": " + reason or "error <n>" + "\n"
    mov     word [rsp], ': '
    mov     edi, STDERR_FILENO
    mov     rsi, rsp
    mov     edx, 2
    call    write_all

    lea     rsi, [errno_table]
.find:
    movzx   eax, byte [rsi]
    test    eax, eax
    jz      .unknown
    movzx   edx, byte [rsi + 1]
    cmp     rax, r13
    je      .found
    lea     rsi, [rsi + rdx + 2]
    jmp     .find
.found:
    add     rsi, 2
    mov     edi, STDERR_FILENO
    call    write_all
    jmp     .newline

.unknown:                               ; "error <decimal errno>"
    mov     edi, STDERR_FILENO
    lea     rsi, [unknown_err]
    mov     edx, unknown_len
    call    write_all
    lea     rsi, [rsp + 32]             ; build digits backwards into the scratch area
    mov     rax, r13
    mov     ecx, 10
.digit:
    xor     edx, edx
    div     rcx
    add     dl, '0'
    dec     rsi
    mov     [rsi], dl
    test    rax, rax
    jnz     .digit
    lea     rdx, [rsp + 32]
    sub     rdx, rsi
    mov     edi, STDERR_FILENO
    call    write_all

.newline:
    mov     byte [rsp], 10
    mov     edi, STDERR_FILENO
    mov     rsi, rsp
    mov     edx, 1
    call    write_all
    mov     edi, EXIT_FAILURE
    mov     eax, SYS_exit
    syscall

NONEXEC_STACK
