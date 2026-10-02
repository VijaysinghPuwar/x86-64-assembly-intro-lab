; linux.inc - x86-64 Linux ABI constants used by the programs in this repo.
; Values come from <asm/unistd_64.h>, <asm-generic/errno-base.h> and <fcntl.h>.

%ifndef LINUX_INC
%define LINUX_INC

; Syscall numbers (x86-64 only: they differ on i386 and arm64)
%define SYS_read        0
%define SYS_write       1
%define SYS_open        2
%define SYS_close       3
%define SYS_exit        60

; Standard file descriptors
%define STDIN_FILENO    0
%define STDOUT_FILENO   1
%define STDERR_FILENO   2

%define O_RDONLY        0

; errno values (syscalls return -errno in rax on failure)
%define EPERM           1
%define ENOENT          2
%define EINTR           4
%define EIO             5
%define ENXIO           6
%define EBADF           9
%define EAGAIN          11
%define ENOMEM          12
%define EACCES          13
%define EFAULT          14
%define ENODEV          19
%define ENOTDIR         20
%define EISDIR          21
%define EINVAL          22
%define EFBIG           27
%define ENOSPC          28
%define EPIPE           32
%define ENAMETOOLONG    36
%define ELOOP           40
%define EDQUOT          122

; Process exit statuses used by this repo
%define EXIT_OK         0
%define EXIT_FAILURE    1   ; runtime error (I/O failure, missing file, ...)
%define EXIT_USAGE      2   ; bad command line

; Mark the stack non-executable. Without this note, GNU ld may emit an
; RWE PT_GNU_STACK header (or none at all), so every object file needs it.
%macro NONEXEC_STACK 0
    section .note.GNU-stack noalloc noexec nowrite progbits
%endmacro

%endif
