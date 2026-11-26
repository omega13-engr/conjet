/* ARM64 Linux ABI. Check identity and isolation, retain 8 MiB across a delay,
 * then write 96 KiB to each stream to exercise bounded output capture. */
.text
.globl _start
_start:
    mov x8, #174                 // getuid
    svc #0
    mov x9, #65532
    cmp x0, x9
    b.ne fail
    mov x8, #198                 // socket; prohibited in the no-network profile
    mov x0, #2
    mov x1, #1
    mov x2, #0
    svc #0
    cmn x0, #1                   // -EPERM
    b.ne fail

    mov x8, #56                  // openat
    mov x0, #-100                // AT_FDCWD
    adr x1, escaped_path
    mov x2, #0
    svc #0
    cmn x0, #2                   // ENOENT: the guest control file is hidden
    b.ne fail
    mov x8, #56
    mov x0, #-100
    adr x1, private_file
    mov x2, #193                 // O_WRONLY | O_CREAT | O_EXCL
    mov x3, #384                 // 0600
    svc #0
    cmp x0, #0                   // each execution starts with a new upper root
    b.lt fail
    mov x8, #57
    svc #0

    mov x8, #222                 // mmap
    mov x0, #0
    mov x1, #0x800000
    mov x2, #3
    mov x3, #0x22
    mov x4, #-1
    mov x5, #0
    svc #0
    cmp x0, #0
    b.lt fail
    mov x19, x0
    mov x20, #2048
    mov x9, x19
    mov w10, #90
write_pages:
    strb w10, [x9], #1
    add x9, x9, #4095
    subs x20, x20, #1
    b.ne write_pages

    mov x8, #101                 // nanosleep
    adr x0, delay
    mov x1, #0
    svc #0
    cbnz x0, fail

    mov x20, #2048
    mov x9, x19
read_pages:
    ldrb w10, [x9], #1
    cmp w10, #90
    b.ne fail
    add x9, x9, #4095
    subs x20, x20, #1
    b.ne read_pages

    mov x21, #1
write_stream:
    mov x20, #24
write_chunk:
    mov x8, #64                  // write
    mov x0, x21
    mov x1, x19
    mov x2, #4096
    svc #0
    cmp x0, #4096
    b.ne fail
    subs x20, x20, #1
    b.ne write_chunk
    add x21, x21, #1
    cmp x21, #3
    b.ne write_stream

    mov x0, #0
    b exit
fail:
    mov x0, #23
exit:
    mov x8, #93
    svc #0
.p2align 3
delay:
    .quad 2, 0
escaped_path:
    .asciz "/etc/conjet/launch.key"
private_file:
    .asciz "private-proof"
