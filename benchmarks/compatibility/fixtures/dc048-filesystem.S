// Stable Linux AArch64 metadata probe. All operations are relative to the
// private fixture directory opened with O_DIRECTORY.
.equ SYS_FSETXATTR, 7
.equ SYS_FGETXATTR, 10
.equ SYS_FLOCK, 32
.equ SYS_LINKAT, 37
.equ SYS_OPENAT, 56
.equ SYS_LSEEK, 62
.equ SYS_WRITE, 64
.equ SYS_FSYNC, 82
.equ SYS_EXIT, 93
.text
.global _start
_start:
    ldr x1, [sp, #16]
    mov x0, #-100
    mov x2, #0x4000
    mov x3, #0
    mov x8, #SYS_OPENAT
    svc #0
    mov x19, x0
    mov x21, #1
    tbnz x0, #63, fail

    mov x0, x19
    adr x1, payload
    mov x2, #194
    mov x3, #384
    mov x8, #SYS_OPENAT
    svc #0
    mov x20, x0
    mov x21, #2
    tbnz x0, #63, fail

    mov x0, x20
    mov x1, #1048576
    mov x2, #0
    mov x8, #SYS_LSEEK
    svc #0
    mov x21, #3
    cmp x0, #256, lsl #12
    b.ne fail

    mov x0, x20
    adr x1, content
    mov x2, #2
    mov x8, #SYS_WRITE
    svc #0
    mov x21, #4
    cmp x0, #2
    b.ne fail

    mov x0, x20
    adr x1, attr_name
    adr x2, content
    mov x3, #2
    mov x4, #1
    mov x8, #SYS_FSETXATTR
    svc #0
    mov x21, #5
    mov x23, #0
    cbz x0, make_link
    cmn x0, #95                   // EOPNOTSUPP from pre-v6.6 tmpfs
    b.ne fail
    mov x23, #1

make_link:

    mov x0, x19
    adr x1, payload
    mov x2, x19
    adr x3, linked
    mov x4, #0
    mov x8, #SYS_LINKAT
    svc #0
    mov x21, #6
    cbnz x0, fail

    mov x0, x19
    adr x1, linked
    mov x2, #0
    mov x3, #0
    mov x8, #SYS_OPENAT
    svc #0
    mov x22, x0
    mov x21, #7
    tbnz x0, #63, fail

    sub sp, sp, #16
    mov x0, x22
    adr x1, attr_name
    mov x2, sp
    mov x3, #2
    mov x8, #SYS_FGETXATTR
    svc #0
    mov x21, #8
    cbz x23, compare_value
    cmn x0, #95
    b.ne fail
    b lock_file
compare_value:
    cmp x0, #2
    b.ne fail
    ldrh w0, [sp]
    mov w1, #0x6b6f
    cmp w0, w1
    b.ne fail

lock_file:
    mov x0, x20
    mov x1, #6
    mov x8, #SYS_FLOCK
    svc #0
    mov x21, #9
    cbnz x0, fail

    mov x0, x22
    mov x1, #6
    mov x8, #SYS_FLOCK
    svc #0
    mov x21, #10
    cmn x0, #11
    b.ne fail

    mov x0, x20
    mov x1, #8
    mov x8, #SYS_FLOCK
    svc #0
    mov x21, #11
    cbnz x0, fail

    mov x0, x22
    mov x1, #6
    mov x8, #SYS_FLOCK
    svc #0
    mov x21, #12
    cbnz x0, fail

    mov x0, x20
    mov x8, #SYS_FSYNC
    svc #0
    mov x21, #13
    cbnz x0, fail

    mov x0, x19
    mov x8, #SYS_FSYNC
    svc #0
    mov x21, #14
    cbnz x0, fail
    mov x21, #0
    cbz x23, fail
    mov x21, #20                   // all other metadata checks passed
fail:
    mov x0, x21
    mov x8, #SYS_EXIT
    svc #0

payload: .asciz "metadata-sparse"
linked: .asciz "metadata-link"
attr_name: .asciz "user.conjet.compat"
content: .ascii "ok"
